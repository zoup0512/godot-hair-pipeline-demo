extends Node3D
##
## 桌面萌宠（完整版）：透明置顶窗口里的毛绒小熊
##
## - 桌面模式：全屏透明无边框置顶窗口，鼠标点击穿透（只有萌宠区域可交互），
##   左键拖拽、右键菜单、待机呼吸/眨眼/抖耳、散步、蹦跳
## - 移动端（Android 导出或 PET_FORCE_MOBILE=1）：普通全屏窗口 + 触摸拖动，
##   画质自动降档（毛簇/外壳层数/引导丝减半，MSAA 关闭）
## - 头顶呆毛：发丝管线 + Verlet 引导丝物理，走路/拖拽/蹦跳时甩动
##
## 测试辅助：PET_SHOT=<png>（截图并退出，打印 alpha 采样）、PET_SHOT_DELAY=秒、
##           PET_FORCE_MOBILE=1、PET_FORCE_WALK=1（强制散步便于位移验证）

enum Mode { DESKTOP, MOBILE }
enum State { IDLE, WALK, HOP, DRAG, FALL }

const HairStrandBuilder := preload("res://scripts/hair_strand_builder.gd")
const FurShellBuilder := preload("res://scripts/fur_shell_builder.gd")
const HairPhysics := preload("res://scripts/hair_physics.gd")

const HEAD_LOCAL := Vector3(0, 1.02, 0)   # 头球心（萌宠局部）
const GROUND_OFFSET := 0.64               # 身体中心到脚底
const FOV := 40.0

var mode := Mode.DESKTOP
var state := State.IDLE
var state_time := 0.0
var state_dur := 2.0
var walk_dir := 1.0
var walk_speed := 0.9
var hop_vy := 0.0

var tuft_strands := 4000
var fur_layers := 36
var tuft_guides := 96

var doll: Node3D
var body_mesh: MeshInstance3D
var eye_l: MeshInstance3D
var eye_r: MeshInstance3D
var ear_l: MeshInstance3D
var ear_r: MeshInstance3D
var shadow_quad: MeshInstance3D
var tuft_instance: MeshInstance3D
var mouth_interior: MeshInstance3D
var mouth_tongue: MeshInstance3D
var mouth_arcs: Array = []        # [{side, node}] ω 嘴的两段弧
var mouth_open := 0.0             # 0 闭合 → 1 张大
var camera: Camera3D
var fur_material: ShaderMaterial
var cream_material: ShaderMaterial   # 口鼻/脸部的奶油色毛皮
var fur_materials: Array = []        # 需要同步风摆的毛皮材质
var tuft_material: ShaderMaterial
var physics
var menu: PopupMenu

var pet_pos := Vector3.ZERO
var drag_offset := Vector3.ZERO
var half_h := 4.7
var half_w := 8.0
var px_per_world := 100.0

var blink_t := -1.0
var next_blink := 2.5
var twitch_t := -1.0
var next_twitch := 4.0

var _shot_path := ""
var _shot_delay := 2.2
var _shot_done := false
var _elapsed := 0.0

func _ready() -> void:
	_shot_path = OS.get_environment("PET_SHOT")
	var d := OS.get_environment("PET_SHOT_DELAY")
	if d != "":
		_shot_delay = float(d)
	if OS.get_environment("PET_FORCE_MOBILE") == "1" or OS.has_feature("mobile"):
		mode = Mode.MOBILE
	if mode == Mode.MOBILE:
		tuft_strands = 1200
		fur_layers = 18
		tuft_guides = 48

	_setup_window()
	_setup_env()
	_setup_camera()
	_build_pet()
	_compute_layout()
	pet_pos = Vector3(0, _ground_y(), 0)
	doll.position = pet_pos
	if OS.get_environment("PET_FORCE_WALK") == "1":
		state = State.WALK
		state_dur = 1e9
	if OS.get_environment("PET_FORCE_HOP") == "1":
		state = State.HOP
		hop_vy = 2.4
		state_time = 0.0

# ---------------------------------------------------------------- 搭建

func _setup_window() -> void:
	if mode == Mode.DESKTOP:
		var wid := get_window().get_window_id()
		var screen := DisplayServer.window_get_current_screen(wid)
		get_window().borderless = true
		get_window().always_on_top = true
		get_window().size = DisplayServer.screen_get_size(screen)
		get_window().position = DisplayServer.screen_get_position(screen)
		get_viewport().transparent_bg = true

func _setup_env() -> void:
	var env := Environment.new()
	# 桌面模式：clear color 透明（配合 transparent_bg）；移动模式：纯色底
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.82, 0.88)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	if mode == Mode.MOBILE:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.12, 0.15, 0.21)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, 35, 0)
	key.light_energy = 2.2
	key.light_color = Color(1.0, 0.96, 0.9)
	add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-10, -140, 0)
	rim.light_energy = 0.9
	rim.light_color = Color(0.75, 0.83, 1.0)
	add_child(rim)

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.fov = FOV
	add_child(camera)

func _compute_layout() -> void:
	var ss := get_window().size
	var aspect := float(ss.x) / float(ss.y)
	# 萌宠实际高度约 1.1 世界单位，默认占屏幕高度 20%（PET_SIZE 可覆盖，调试用）
	var frac := 0.20
	var fe := OS.get_environment("PET_SIZE")
	if fe != "":
		frac = float(fe)
	half_h = 1.1 / (2.0 * frac)
	half_w = half_h * aspect
	camera.position = Vector3(0, 0, half_h / tan(deg_to_rad(FOV / 2.0)))
	px_per_world = ss.y / (2.0 * half_h)

func _ground_y() -> float:
	return -half_h + GROUND_OFFSET

func _build_pet() -> void:
	doll = Node3D.new()
	add_child(doll)

	fur_material = ShaderMaterial.new()
	fur_material.shader = load("res://shaders/fur_shells.gdshader")
	var fur_defaults := {
		"base_color": Color(0.50, 0.34, 0.20),
		"tip_color": Color(0.85, 0.68, 0.46),
		"fur_length": 0.07,
		"droop": 0.5,
		"fur_density": 120.0,
		"fiber_radius": 0.27,
		"cutout": 0.32,
		"ao_strength": 0.3,
		"spec_strength": 0.4,
		"wrap_diffuse": 0.45,
		"wind_amplitude": 0.005,
	}
	for k in fur_defaults:
		fur_material.set_shader_parameter(k, fur_defaults[k])
	fur_materials = [fur_material]

	# 口鼻/脸部：奶油色毛皮（博美式双层毛色）
	cream_material = fur_material.duplicate()
	cream_material.set_shader_parameter("base_color", Color(0.93, 0.87, 0.74))
	cream_material.set_shader_parameter("tip_color", Color(1.0, 0.97, 0.88))
	cream_material.set_shader_parameter("fur_length", 0.055)
	cream_material.set_shader_parameter("ao_strength", 0.22)
	fur_materials.append(cream_material)

	# 五官遮罩：这些球域内的毛变短变稀（真实动物口鼻部/眼周毛更短），让脸露出来
	var feature_masks := [
		[Vector3(-0.155, 1.16, 0.385), 0.14],
		[Vector3(0.155, 1.16, 0.385), 0.14],
		[Vector3(0, 0.985, 0.50), 0.13],
		[Vector3(0, 0.91, 0.50), 0.15],
		[Vector3(-0.215, 1.02, 0.385), 0.09],
		[Vector3(0.215, 1.02, 0.385), 0.09],
	]

	# 身体 + 尾巴（焦糖色，合并为一个毛皮网格）
	var fur_res: Dictionary = FurShellBuilder.build([
		{"center": Vector3(0, 1.02, 0.0), "radius": 0.42, "radial": 44, "rings": 22,
			"masks": feature_masks},
		{"center": Vector3(0, 0.92, -0.40), "radius": 0.13, "radial": 20, "rings": 10},
	], fur_layers)
	body_mesh = MeshInstance3D.new()
	body_mesh.mesh = fur_res.mesh
	body_mesh.material_override = fur_material
	doll.add_child(body_mesh)

	# 口鼻 + 脸颊毛（奶油色）
	var muzzle_res: Dictionary = FurShellBuilder.build([
		{"center": Vector3(0, 0.93, 0.30), "radius": 0.17, "radial": 24, "rings": 12,
			"masks": feature_masks},
		{"center": Vector3(0, 0.99, 0.22), "radius": 0.24, "radial": 28, "rings": 14,
			"masks": feature_masks},
	], fur_layers)
	var muzzle := MeshInstance3D.new()
	muzzle.mesh = muzzle_res.mesh
	muzzle.material_override = cream_material
	doll.add_child(muzzle)

	# 耳朵（独立节点，便于抖耳动画）+ 粉色内耳（内耳区域毛也遮罩掉）
	for side in [-1.0, 1.0]:
		var ear_res: Dictionary = FurShellBuilder.build([
			{"center": Vector3(0, 0, 0), "radius": 0.14, "radial": 20, "rings": 10,
				"masks": [[Vector3(side * 0.20, 1.42, 0.17), 0.13]]},
		], fur_layers)
		var ear := MeshInstance3D.new()
		ear.mesh = ear_res.mesh
		ear.material_override = fur_material
		ear.position = Vector3(side * 0.20, 1.42, 0.02)
		ear.rotation.z = side * -0.16
		doll.add_child(ear)
		var inner := MeshInstance3D.new()
		var im := SphereMesh.new()
		im.radius = 0.095
		im.height = 0.1
		inner.mesh = im
		inner.scale = Vector3(0.95, 1.15, 0.5)
		inner.position = Vector3(0, 0, 0.15)
		inner.material_override = _flat_material(Color(0.96, 0.62, 0.62))
		ear.add_child(inner)
		if side < 0:
			ear_l = ear
		else:
			ear_r = ear

	# 眼睛（黑豆 + 白色高光点）与鼻子
	var bead := StandardMaterial3D.new()
	bead.albedo_color = Color(0.05, 0.04, 0.04)
	bead.roughness = 0.15
	var glint := StandardMaterial3D.new()
	glint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glint.albedo_color = Color(1, 1, 1)
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.06
		m.height = 0.12
		eye.mesh = m
		eye.material_override = bead
		eye.position = Vector3(side * 0.155, 1.16, 0.385)
		var hl := MeshInstance3D.new()
		var hm := SphereMesh.new()
		hm.radius = 0.018
		hm.height = 0.036
		hl.mesh = hm
		hl.material_override = glint
		hl.position = Vector3(side * 0.022, 0.026, 0.045)
		eye.add_child(hl)
		doll.add_child(eye)
		if side < 0:
			eye_l = eye
		else:
			eye_r = eye
	var nose := MeshInstance3D.new()
	var nm := SphereMesh.new()
	nm.radius = 0.045
	nm.height = 0.09
	nose.mesh = nm
	nose.material_override = bead
	nose.position = Vector3(0, 0.985, 0.50)
	doll.add_child(nose)

	# 猫式 ω 嘴：两段下弧管在中点相接拼成 "ω"（自定义弧形网格，无需遮挡上半截）
	for side in [-1.0, 1.0]:
		var mouth := MeshInstance3D.new()
		mouth.mesh = _arc_tube_mesh(0.026, 0.010, 180.0, 360.0)
		mouth.material_override = _flat_material(Color(0.30, 0.15, 0.10))
		mouth.position = Vector3(side * 0.024, 0.928, 0.505)
		doll.add_child(mouth)
		mouth_arcs.append({"side": side, "node": mouth})

	# 张嘴时的口腔与舌头（默认缩为 0，随 mouth_open 展开）
	mouth_interior = MeshInstance3D.new()
	var mi := SphereMesh.new()
	mi.radius = 0.055
	mi.height = 0.11
	mouth_interior.mesh = mi
	mouth_interior.material_override = _flat_material(Color(0.22, 0.08, 0.07))
	mouth_interior.position = Vector3(0, 0.885, 0.50)
	mouth_interior.scale = Vector3.ONE * 0.001
	doll.add_child(mouth_interior)
	mouth_tongue = MeshInstance3D.new()
	var tg := SphereMesh.new()
	tg.radius = 0.03
	tg.height = 0.06
	mouth_tongue.mesh = tg
	mouth_tongue.material_override = _flat_material(Color(0.93, 0.45, 0.45))
	mouth_tongue.position = Vector3(0, 0.862, 0.505)
	mouth_tongue.scale = Vector3.ONE * 0.001
	doll.add_child(mouth_tongue)

	# 腮红
	for side in [-1.0, 1.0]:
		var blush := MeshInstance3D.new()
		var bm := SphereMesh.new()
		bm.radius = 0.06
		bm.height = 0.12
		blush.mesh = bm
		blush.scale = Vector3(1.1, 0.55, 0.35)
		blush.position = Vector3(side * 0.215, 1.02, 0.385)
		blush.material_override = _flat_material(Color(0.98, 0.55, 0.55, 0.55))
		doll.add_child(blush)

	# 头顶呆毛：球冠采样 + Verlet 引导丝
	var strands := HairStrandBuilder.sample_cap_strands(0.42, tuft_strands, 11, 0.45)
	var guides := HairStrandBuilder.sample_cap_strands(0.42, tuft_guides, 12, 0.45)
	_place_cap(strands)
	_place_cap(guides)
	tuft_material = ShaderMaterial.new()
	tuft_material.shader = load("res://shaders/hair_strands.gdshader")
	var tuft_defaults := {
		"root_color": Color(0.45, 0.34, 0.22),
		"tip_color": Color(0.96, 0.88, 0.72),
		"length_min": 0.07,
		"length_max": 0.2,
		"droop": 0.3,
		"clump": 0.3,
		"curl_amount": 0.05,
		"curl_freq": 3.0,
		"wind_amplitude": 0.004,
		"wind_frequency": 2.0,
		"width_root": 0.008,
		"width_tip": 0.0015,
		"cutout": 0.35,
		"u_physics_blend": 1.0,
		"u_dom_strength": 0.0,
		"u_head_radius": 0.44,
	}
	for k in tuft_defaults:
		tuft_material.set_shader_parameter(k, tuft_defaults[k])
	var tuft_res: Dictionary = HairStrandBuilder.build_from_params(strands, guides)
	tuft_instance = MeshInstance3D.new()
	tuft_instance.mesh = tuft_res.mesh
	tuft_instance.material_override = tuft_material
	doll.add_child(tuft_instance)
	print("[pet] tuft strands=", tuft_res.strands, " verts=", tuft_res.vertices)
	physics = HairPhysics.new()
	physics.set_shape_params_from(tuft_material)
	physics.setup(guides, doll.global_transform)
	tuft_material.set_shader_parameter("u_guide_count", float(guides.size()))
	tuft_material.set_shader_parameter("u_guide_tex", physics.texture)

	# 接触阴影：径向渐变贴图 + 公告板，贴在脚边
	shadow_quad = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1.5, 0.9)
	shadow_quad.mesh = qm
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var gt := GradientTexture2D.new()
	gt.width = 256
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 1.0)
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(0, 0, 0, 0.4), Color(0, 0, 0, 0)])
	g.offsets = PackedFloat32Array([0.0, 1.0])
	gt.gradient = g
	sm.albedo_texture = gt
	shadow_quad.material_override = sm
	shadow_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shadow_quad)

	# 右键菜单
	menu = PopupMenu.new()
	menu.add_item("切换物理", 0)
	menu.add_item("退出", 1)
	add_child(menu)
	menu.id_pressed.connect(_on_menu)

func _place_cap(entries: Array) -> void:
	var tilt := Basis(Vector3.RIGHT, 0.32)  # 呆毛略向前倾
	for e in entries:
		e.root = tilt * (e.root as Vector3) + HEAD_LOCAL
		e.dir = (tilt * (e.dir as Vector3)).normalized()
		e.a_axis = (tilt * (e.a_axis as Vector3)).normalized()
		e.b_axis = (tilt * (e.b_axis as Vector3)).normalized()

## 五官用的小平面材质（内耳/嘴/腮红）
func _flat_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if c.a < 0.99:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

## 生成 XY 平面内的圆弧管网格（角度 180→360 即开口朝上的下弧），用于 ω 嘴
func _arc_tube_mesh(radius: float, tube: float, from_deg: float,
		to_deg: float, segs := 16) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev := PackedVector3Array()
	for s in segs + 1:
		var a := deg_to_rad(lerpf(from_deg, to_deg, float(s) / float(segs)))
		var radial := Vector3(cos(a), sin(a), 0.0)
		var center := radial * radius
		var binormal := Vector3(0, 0, 1)
		var ring := PackedVector3Array()
		for k in 9:
			var t := TAU * float(k) / 8.0
			ring.append(center + (radial * cos(t) + binormal * sin(t)) * tube)
		if s > 0:
			for k in 8:
				var k2 := (k + 1) % 8
				st.add_vertex(prev[k])
				st.add_vertex(prev[k2])
				st.add_vertex(ring[k])
				st.add_vertex(prev[k2])
				st.add_vertex(ring[k2])
				st.add_vertex(ring[k])
		prev = ring
	st.generate_normals()
	return st.commit()

func _on_menu(id: int) -> void:
	if id == 0:
		var v := 0.0 if float(tuft_material.get_shader_parameter("u_physics_blend")) > 0.5 else 1.0
		tuft_material.set_shader_parameter("u_physics_blend", v)
	elif id == 1:
		get_tree().quit()

# ---------------------------------------------------------------- 行为

func _process(delta: float) -> void:
	_elapsed += delta
	_animate(delta)
	_tick_state(delta)

	physics.step(doll.global_transform, pet_pos + HEAD_LOCAL, 0.44,
			Time.get_ticks_msec() / 1000.0, delta)
	tuft_material.set_shader_parameter("u_head_center", pet_pos + HEAD_LOCAL)
	var wind_now := 0.014 if state == State.WALK else 0.005
	for m in fur_materials:
		m.set_shader_parameter("wind_amplitude", wind_now)
	shadow_quad.position = Vector3(pet_pos.x, _ground_y() + 0.02, 0)

	_update_passthrough()
	_maybe_shot()

func _tick_state(delta: float) -> void:
	state_time += delta
	match state:
		State.IDLE:
			body_mesh.scale = Vector3.ONE * (1.0 + 0.015 * sin(_elapsed * 2.2))
			if state_time > state_dur:
				if randf() < 0.3 or OS.get_environment("PET_FORCE_HOP") == "1":
					_enter(State.HOP)
					hop_vy = 2.4
				else:
					_enter(State.WALK)
					if randf() < 0.5:
						walk_dir = -walk_dir
		State.WALK:
			pet_pos.x = clampf(pet_pos.x + walk_dir * walk_speed * delta,
					-half_w + 0.8, half_w - 0.8)
			if is_equal_approx(absf(pet_pos.x), half_w - 0.8) or state_time > state_dur:
				if OS.get_environment("PET_FORCE_WALK") == "1":
					walk_dir = -walk_dir
					state_time = 0.0
				else:
					_enter(State.IDLE)
					state_dur = randf_range(1.5, 4.0)
			doll.position = pet_pos + Vector3(0, absf(sin(state_time * 7.0)) * 0.045, 0)
			doll.rotation.z = sin(state_time * 7.0) * 0.05
		State.HOP:
			var y := pet_pos.y + hop_vy * state_time - 0.5 * 9.8 * state_time * state_time
			if y <= pet_pos.y and state_time > 0.1:
				_enter(State.IDLE)
				state_dur = randf_range(1.5, 3.5)
			else:
				doll.position = pet_pos + Vector3(0, y - pet_pos.y + 0.0, 0)
		State.DRAG:
			pass  # 位置由输入驱动
		State.FALL:
			pet_pos.y -= 6.0 * delta
			if pet_pos.y <= _ground_y():
				pet_pos.y = _ground_y()
				_enter(State.IDLE)
				state_dur = randf_range(1.5, 3.5)
			doll.position = pet_pos
	if state != State.WALK:
		doll.position = doll.position.lerp(pet_pos, minf(1.0, delta * 12.0))
		doll.rotation.z = lerpf(doll.rotation.z, 0.0, minf(1.0, delta * 8.0))

func _enter(s: State) -> void:
	state = s
	state_time = 0.0
	if s == State.IDLE:
		state_dur = randf_range(1.5, 4.0)
	elif s == State.WALK:
		state_dur = randf_range(2.0, 5.0)

func _animate(delta: float) -> void:
	# 嘴巴张合：蹦跳/下落张大，拖拽半张（惊讶），散步微喘，待机闭合 ω
	var target_open := 0.0
	match state:
		State.HOP, State.FALL:
			target_open = 1.0
		State.DRAG:
			target_open = 0.6
		State.WALK:
			target_open = 0.25
	mouth_open = lerpf(mouth_open, target_open, minf(1.0, delta * 12.0))
	var m_s := maxf(mouth_open, 0.001)
	mouth_interior.scale = Vector3(1.35, 1.15, 0.5) * m_s
	var tongue_s := clampf((mouth_open - 0.35) / 0.65, 0.0, 1.0)
	mouth_tongue.scale = Vector3(1.3, 0.75, 0.6) * maxf(tongue_s, 0.001)
	for a in mouth_arcs:
		var side: float = a.side
		var arc: MeshInstance3D = a.node
		arc.position = Vector3(side * (0.024 + 0.016 * mouth_open),
				0.928 - 0.006 * mouth_open, 0.505)

	# 眨眼
	next_blink -= delta
	if next_blink <= 0.0:
		blink_t = 0.14
		next_blink = randf_range(2.0, 5.5)
	if blink_t >= 0.0:
		blink_t -= delta
		var s := 0.12 if blink_t > 0.05 else 1.0
		eye_l.scale = Vector3(1, s, 1)
		eye_r.scale = Vector3(1, s, 1)
	# 抖耳
	next_twitch -= delta
	if next_twitch <= 0.0:
		twitch_t = 0.2
		next_twitch = randf_range(3.5, 8.0)
	if twitch_t >= 0.0:
		twitch_t -= delta
		var w := sin(twitch_t * 40.0) * 0.12
		ear_l.rotation.z = -0.16 + w
		ear_r.rotation.z = 0.16 - w
	else:
		ear_l.rotation.z = -0.16
		ear_r.rotation.z = 0.16

# ---------------------------------------------------------------- 输入

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and _over_pet(mb.position):
				_enter(State.DRAG)
				drag_offset = pet_pos - _mouse_world(mb.position)
			elif not mb.pressed and state == State.DRAG:
				_enter(State.FALL)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _over_pet(mb.position):
				menu.popup(Rect2i(Vector2i(mb.position), Vector2i(10, 10)))
	elif event is InputEventMouseMotion and state == State.DRAG:
		pet_pos = _mouse_world(event.position) + drag_offset
		pet_pos.x = clampf(pet_pos.x, -half_w + 0.8, half_w - 0.8)
		pet_pos.y = clampf(pet_pos.y, _ground_y(), half_h - 1.2)
		doll.position = pet_pos
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()

func _over_pet(sp: Vector2) -> bool:
	var c := camera.unproject_position(doll.global_position + Vector3(0, 0.4, 0))
	return sp.distance_to(c) < 1.0 * px_per_world

func _mouse_world(sp: Vector2) -> Vector3:
	var plane := Plane(Vector3(0, 0, 1), 0.0)
	var hit = plane.intersects_ray(camera.project_ray_origin(sp),
			camera.project_ray_normal(sp))
	return hit if hit != null else pet_pos

## 点击穿透：只有萌宠周围的矩形接受鼠标，其余区域透传给桌面
func _update_passthrough() -> void:
	if mode != Mode.DESKTOP:
		return
	if OS.get_name() != "Windows" and OS.get_name() != "Linux":
		return
	var c := camera.unproject_position(doll.global_position + Vector3(0, 0.4, 0))
	var rx := 1.15 * px_per_world
	var ry := 1.75 * px_per_world
	var poly := PackedVector2Array([
		c + Vector2(-rx, -ry),
		c + Vector2(rx, -ry),
		c + Vector2(rx, ry),
		c + Vector2(-rx, ry),
	])
	DisplayServer.window_set_mouse_passthrough(poly)

# ---------------------------------------------------------------- 截图

func _maybe_shot() -> void:
	if _shot_path == "" or _shot_done or _elapsed < _shot_delay:
		return
	_shot_done = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_shot_path)
	var corner: Color = img.get_pixel(3, 3)
	var c := camera.unproject_position(doll.global_position + Vector3(0, 1.02, 0.30))
	var center: Color = img.get_pixel(
			clampi(int(c.x), 0, img.get_width() - 1),
			clampi(int(c.y), 0, img.get_height() - 1))
	print("[pet] shot=%s corner_a=%.2f pet_a=%.2f pos=(%.2f, %.2f)" % [
		_shot_path, corner.a, center.a, doll.position.x, doll.position.y])
	get_tree().quit()
