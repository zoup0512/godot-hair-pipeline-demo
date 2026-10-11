extends Node3D
##
## Godot 毛发渲染管线 Demo
##
## 左侧 bust：发丝管线（Strand Hair）
##   CPU 生成发丝顶点数据 → GPU 顶点阶段造型（重力/收拢/卷曲/风）
##   → 相机朝向 ribbon 展开 → 片元阶段 Kajiya-Kay 双瓣各向异性高光
##   → alpha scissor 镂空 + 内置 shadow pass 投射/接收阴影。
## 右侧玩偶：外壳毛发（Shell Fur）
##   球体层叠外壳 + 3D 网格噪声纤维 + 逐层阈值镂空，一次 draw call。
##
## 测试辅助（自动化截图）：
##   HAIR_DEMO_SHOT=<png 路径>   启动后延迟截图并退出
##   HAIR_DEMO_SHOT_DELAY=秒     截图延迟（默认 1.8）
##   HAIR_DEMO_YAW/PITCH/DIST    覆盖相机初始视角（度 / 度 / 米）

const HairStrandBuilder := preload("res://scripts/hair_strand_builder.gd")
const FurShellBuilder := preload("res://scripts/fur_shell_builder.gd")
const OrbitCamera := preload("res://scripts/orbit_camera.gd")
const HairPhysics := preload("res://scripts/hair_physics.gd")

const HEAD_RADIUS := 0.35

# 这些参数变化时需要同步 Verlet 引导丝的 rest 形状
const SHAPE_PARAMS := [
	"length_min", "length_max", "droop", "clump",
	"curl_amount", "curl_freq", "wind_amplitude", "wind_frequency",
]

const HAIR_DEFAULTS := {
	"root_color": Color(0.05, 0.03, 0.02),
	"tip_color": Color(0.22, 0.13, 0.055),
	"value_variation": 0.35,
	"length_min": 0.10,
	"length_max": 0.34,
	"droop": 1.5,
	"clump": 0.65,
	"curl_amount": 0.07,
	"curl_freq": 2.4,
	"wind_amplitude": 0.01,
	"wind_frequency": 1.5,
	"width_root": 0.0062,
	"width_tip": 0.0012,
	"cutout": 0.35,
	"tip_fade": 0.2,
	"spec1_power": 150.0,
	"spec1_shift": -0.15,
	"spec1_strength": 0.2,
	"spec1_color": Color(1.0, 0.96, 0.9),
	"spec2_power": 25.0,
	"spec2_shift": 0.4,
	"spec2_strength": 0.12,
	"trans_power": 6.0,
	"trans_strength": 0.32,
	"trans_color": Color(1.0, 0.62, 0.3),
	"rim_strength": 0.15,
	"root_ao": 0.55,
	"ambient_fill": 0.05,
	"aa_edge": 0.15,
	"u_dom_strength": 0.5,
	"u_physics_blend": 0.85,
}

const FUR_DEFAULTS := {
	"base_color": Color(0.26, 0.17, 0.10),
	"tip_color": Color(0.66, 0.50, 0.30),
	"fur_length": 0.055,
	"droop": 0.55,
	"fur_density": 140.0,
	"fiber_radius": 0.28,
	"cutout": 0.35,
	"ao_strength": 0.5,
	"spec_strength": 0.4,
	"wrap_diffuse": 0.3,
	"aa_edge": 0.15,
}

# [uniform 名, 显示名, min, max, step]
const HAIR_SLIDERS := [
	["length_min", "发长 · 最短", 0.03, 0.6, 0.005],
	["length_max", "发长 · 最长", 0.05, 0.8, 0.005],
	["droop", "重力下垂", 0.0, 3.0, 0.01],
	["clump", "发流收拢", 0.0, 1.0, 0.01],
	["curl_amount", "卷曲幅度", 0.0, 0.6, 0.005],
	["curl_freq", "卷曲频率", 0.0, 12.0, 0.1],
	["width_root", "宽度 · 根", 0.001, 0.02, 0.0005],
	["width_tip", "宽度 · 梢", 0.0, 0.02, 0.0005],
	["cutout", "镂空阈值", 0.0, 1.0, 0.01],
	["tip_fade", "发梢渐隐", 0.0, 0.5, 0.01],
	["spec1_power", "R 瓣 · 锐度", 2.0, 512.0, 1.0],
	["spec1_shift", "R 瓣 · 偏移", -0.9, 0.9, 0.01],
	["spec1_strength", "R 瓣 · 强度", 0.0, 4.0, 0.05],
	["spec2_power", "TRT 瓣 · 锐度", 2.0, 128.0, 1.0],
	["spec2_shift", "TRT 瓣 · 偏移", -0.9, 0.9, 0.01],
	["spec2_strength", "TRT 瓣 · 强度", 0.0, 4.0, 0.05],
	["trans_power", "TT 透光 · 锐度", 1.0, 32.0, 0.5],
	["trans_strength", "TT 透光 · 强度", 0.0, 1.0, 0.01],
	["rim_strength", "边缘光", 0.0, 2.0, 0.05],
	["root_ao", "根部 AO", 0.0, 1.0, 0.05],
	["ambient_fill", "环境补光", 0.0, 1.0, 0.05],
	["aa_edge", "AA 边缘", 0.0, 0.5, 0.01],
	["wind_amplitude", "风 · 幅度", 0.0, 0.1, 0.001],
	["wind_frequency", "风 · 频率", 0.0, 8.0, 0.1],
]

const FUR_SLIDERS := [
	["fur_length", "毛长", 0.01, 0.25, 0.005],
	["droop", "下垂", 0.0, 1.0, 0.01],
	["fur_density", "密度（格/米）", 20.0, 150.0, 1.0],
	["fiber_radius", "毛径", 0.05, 0.6, 0.01],
	["cutout", "镂空阈值", 0.0, 1.0, 0.01],
	["ao_strength", "根部 AO", 0.0, 1.0, 0.05],
	["spec_strength", "高光", 0.0, 2.0, 0.05],
	["wrap_diffuse", "包裹漫反射", 0.0, 1.0, 0.05],
	["aa_edge", "AA 边缘", 0.0, 0.5, 0.01],
]

var hair_material: ShaderMaterial
var hair_capture_material: ShaderMaterial   # DOM 捕捉材质（与主材质同步造型 uniform）
var fur_material: ShaderMaterial
var hair_mesh_instance: MeshInstance3D
var hair_dup_instance: MeshInstance3D       # DOM 捕捉用的头发副本（仅渲染层 3）
var head_rig: Node3D
var camera: Camera3D
var key_light: DirectionalLight3D
var dom_viewport: SubViewport
var dom_camera: Camera3D
var physics                                  # HairPhysics 实例
var guides: Array = []

var strand_count := 32000
var guide_count := 384
var rng_seed := 7
var turntable := false
var turntable_speed := 0.35

const FUR_LAYERS := 36

var _hair_stats := ""
var _fur_stats := ""
var _regen_timer := -1.0
var _rest_timer := -1.0
var _stats_accum := 0.0
var _elapsed := 0.0
var _stats_label: Label

# 自动截图（测试用）
var _shot_path := ""
var _shot_delay := 1.8
var _shot_done := false

func _ready() -> void:
	_shot_path = OS.get_environment("HAIR_DEMO_SHOT")
	var delay_env := OS.get_environment("HAIR_DEMO_SHOT_DELAY")
	if delay_env != "":
		_shot_delay = float(delay_env)

	hair_material = _make_material("res://shaders/hair_strands.gdshader", HAIR_DEFAULTS)
	hair_capture_material = _make_material("res://shaders/hair_opacity_capture.gdshader", HAIR_DEFAULTS)
	fur_material = _make_material("res://shaders/fur_shells.gdshader", FUR_DEFAULTS)

	# 调试用：HAIR_DEMO_SET="param=value;param=value" 直接覆盖发丝材质参数
	var overrides := OS.get_environment("HAIR_DEMO_SET")
	if overrides != "":
		for pair in overrides.split(";", false):
			var kv := pair.split("=", false)
			if kv.size() == 2:
				for mat in [hair_material, hair_capture_material]:
					mat.set_shader_parameter(kv[0], kv[1].to_float())

	if OS.get_environment("HAIR_DEMO_TURNTABLE") == "1":
		turntable = true

	_setup_environment()
	_setup_lights()
	_setup_camera()
	_setup_stage()
	_setup_dom_physics()
	_setup_ui()

	_rebuild_hair()

func _process(delta: float) -> void:
	_elapsed += delta
	if turntable:
		head_rig.rotation.y += delta * turntable_speed

	# Verlet 引导丝物理（链首钉在发根，随头部转动甩动）
	if guide_count > 0:
		physics.step(head_rig.global_transform, head_rig.global_position,
				HEAD_RADIUS * 1.06, Time.get_ticks_msec() / 1000.0, delta)

	if _regen_timer >= 0.0:
		_regen_timer -= delta
		if _regen_timer < 0.0:
			_rebuild_hair()

	if _rest_timer >= 0.0:
		_rest_timer -= delta
		if _rest_timer < 0.0:
			physics.rebuild_rest()

	_stats_accum += delta
	if _stats_accum > 0.5:
		_stats_accum = 0.0
		_update_stats()

	if _shot_path != "" and not _shot_done and _elapsed >= _shot_delay:
		_shot_done = true
		_capture_and_quit(_shot_path)

# ---------------------------------------------------------------- 场景搭建

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.38, 0.62)
	sky_mat.sky_horizon_color = Color(0.66, 0.71, 0.78)
	sky_mat.ground_bottom_color = Color(0.16, 0.14, 0.12)
	sky_mat.ground_horizon_color = Color(0.52, 0.50, 0.46)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.15
	env.glow_bloom = 0.0

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

func _setup_lights() -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-46, 28, 0)
	key.light_energy = 2.2
	key.light_color = Color(1.0, 0.95, 0.87)
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 12.0
	key.shadow_blur = 1.2
	add_child(key)
	key_light = key

	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-14, -155, 0)
	rim.light_energy = 0.9
	rim.light_color = Color(0.72, 0.82, 1.0)
	add_child(rim)

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 42
	camera.set_script(OrbitCamera)
	add_child(camera)
	# 第 3 层是 DOM 捕捉用的头发副本，主相机不可见
	camera.cull_mask = (1 << 20) - 1 - (1 << 2)

	var yaw_env := OS.get_environment("HAIR_DEMO_YAW")
	var pitch_env := OS.get_environment("HAIR_DEMO_PITCH")
	var dist_env := OS.get_environment("HAIR_DEMO_DIST")
	if yaw_env != "":
		camera.yaw = deg_to_rad(float(yaw_env))
	if pitch_env != "":
		camera.pitch = deg_to_rad(float(pitch_env))
	if dist_env != "":
		camera.distance = float(dist_env)
	camera.apply()

func _setup_stage() -> void:
	# 地面
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(24, 24)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.30, 0.28, 0.26)
	ground_mat.roughness = 0.95
	ground.material_override = ground_mat
	add_child(ground)

	# ---- 半身像：支架 + 颈 + 头 + 发丝 ----
	var stand_mat := StandardMaterial3D.new()
	stand_mat.albedo_color = Color(0.20, 0.20, 0.22)
	stand_mat.roughness = 0.4
	stand_mat.metallic = 0.4

	var base_post := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 0.4
	base_mesh.bottom_radius = 0.45
	base_mesh.height = 0.06
	base_post.mesh = base_mesh
	base_post.position = Vector3(0, 0.03, 0)
	base_post.material_override = stand_mat
	add_child(base_post)

	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.045
	pole_mesh.bottom_radius = 0.045
	pole_mesh.height = 0.68
	pole.mesh = pole_mesh
	pole.position = Vector3(0, 0.34, 0)
	pole.material_override = stand_mat
	add_child(pole)

	head_rig = Node3D.new()
	head_rig.position = Vector3(0, 1.42, 0)
	add_child(head_rig)

	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.80, 0.60, 0.50)
	skin.roughness = 0.7

	var neck := MeshInstance3D.new()
	var neck_mesh := CylinderMesh.new()
	neck_mesh.top_radius = 0.11
	neck_mesh.bottom_radius = 0.14
	neck_mesh.height = 0.55
	neck.mesh = neck_mesh
	neck.position = Vector3(0, -0.46, 0)
	neck.material_override = skin
	head_rig.add_child(neck)

	var head := MeshInstance3D.new()
	head.mesh = _build_head_mesh()
	var head_skin := StandardMaterial3D.new()
	head_skin.albedo_color = Color.WHITE
	head_skin.vertex_color_use_as_albedo = true
	head_skin.roughness = 0.7
	head.material_override = head_skin
	head_rig.add_child(head)

	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.06, 0.05, 0.05)
	eye_mat.roughness = 0.15
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.037
		eye_mesh.height = 0.074
		eye.mesh = eye_mesh
		eye.position = Vector3(side * 0.125, 0.02, 0.315)
		eye.material_override = eye_mat
		head_rig.add_child(eye)

	hair_mesh_instance = MeshInstance3D.new()
	hair_mesh_instance.material_override = hair_material
	head_rig.add_child(hair_mesh_instance)

	# ---- 毛绒玩偶：底座 + 外壳毛发 + 眼鼻珠 ----
	var doll := Node3D.new()
	doll.position = Vector3(1.45, 0, 0.0)
	add_child(doll)

	var pedestal := MeshInstance3D.new()
	var ped_mesh := CylinderMesh.new()
	ped_mesh.top_radius = 0.5
	ped_mesh.bottom_radius = 0.58
	ped_mesh.height = 0.6
	pedestal.mesh = ped_mesh
	pedestal.position = Vector3(0, 0.3, 0)
	pedestal.material_override = stand_mat
	doll.add_child(pedestal)

	var fur_res: Dictionary = FurShellBuilder.build([
		{"center": Vector3(0, 1.02, 0.0), "radius": 0.42, "radial": 48, "rings": 24},
		{"center": Vector3(-0.20, 1.40, 0.02), "radius": 0.13, "radial": 24, "rings": 12},
		{"center": Vector3(0.20, 1.40, 0.02), "radius": 0.13, "radial": 24, "rings": 12},
		{"center": Vector3(0.0, 0.93, 0.34), "radius": 0.17, "radial": 24, "rings": 12},
	], FUR_LAYERS)
	var fur_instance := MeshInstance3D.new()
	fur_instance.mesh = fur_res.mesh
	fur_instance.material_override = fur_material
	doll.add_child(fur_instance)
	_fur_stats = "外壳毛发 · 顶点 %d · %d 层" % [fur_res.vertices, FUR_LAYERS]

	var bead_mat := StandardMaterial3D.new()
	bead_mat.albedo_color = Color(0.05, 0.04, 0.04)
	bead_mat.roughness = 0.1
	for side in [-1.0, 1.0]:
		var eye_bead := MeshInstance3D.new()
		var bead_mesh := SphereMesh.new()
		bead_mesh.radius = 0.045
		bead_mesh.height = 0.09
		eye_bead.mesh = bead_mesh
		eye_bead.position = Vector3(side * 0.13, 1.14, 0.38)
		eye_bead.material_override = bead_mat
		doll.add_child(eye_bead)
	var nose := MeshInstance3D.new()
	var nose_mesh := SphereMesh.new()
	nose_mesh.radius = 0.04
	nose_mesh.height = 0.08
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 0.98, 0.55)
	nose.material_override = bead_mat
	doll.add_child(nose)

# ---------------------------------------------------------------- 发丝重建

## 头部网格：长发区域涂深色“发根填充”，避免俯视时头皮透出（游戏头发的常规做法）
func _build_head_mesh() -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radius = HEAD_RADIUS
	sphere.height = HEAD_RADIUS * 2.0 * 1.12
	var src := sphere.get_mesh_arrays()
	var sv: PackedVector3Array = src[Mesh.ARRAY_VERTEX]

	var skin_col := Color(0.80, 0.60, 0.50)
	var scalp_col := Color(0.045, 0.03, 0.022)
	var colors := PackedColorArray()
	colors.resize(sv.size())
	for i in sv.size():
		var p := sv[i]
		var d := Vector3(p.x / HEAD_RADIUS, p.y / (HEAD_RADIUS * 1.12), p.z / HEAD_RADIUS).normalized()
		var az := absf(atan2(d.x, d.z)) / PI  # 0 = 正前, 1 = 正后
		var hairline := lerpf(0.50, 0.02, smoothstep(0.18, 0.72, az))
		var mask := smoothstep(hairline - 0.10, hairline + 0.03, d.y)
		colors[i] = skin_col.lerp(scalp_col, mask)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = sv
	arrays[Mesh.ARRAY_NORMAL] = src[Mesh.ARRAY_NORMAL]
	arrays[Mesh.ARRAY_TANGENT] = src[Mesh.ARRAY_TANGENT]
	arrays[Mesh.ARRAY_TEX_UV] = src[Mesh.ARRAY_TEX_UV]
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = src[Mesh.ARRAY_INDEX]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# ---------------------------------------------------------------- DOM 与物理

## DOM 自阴影捕捉 + Verlet 引导丝：
##  - SubViewport 从主光方向渲染头发副本（第 3 层，加法混合累计不透明度/深度）
##  - 副本不投影、不参与主场景，避免反馈
func _setup_dom_physics() -> void:
	physics = HairPhysics.new()

	dom_viewport = SubViewport.new()
	dom_viewport.size = Vector2i(512, 512)
	dom_viewport.transparent_bg = true
	dom_viewport.use_hdr_2d = true
	dom_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(dom_viewport)

	dom_camera = Camera3D.new()
	dom_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	dom_camera.size = 1.7
	dom_camera.near = 0.1
	dom_camera.far = 20.0
	dom_camera.cull_mask = 1 << 2
	dom_viewport.add_child(dom_camera)
	dom_camera.current = true
	var travel := -key_light.global_transform.basis.z
	var target := Vector3(0, 1.45, 0)
	dom_camera.position = target - travel * 3.0
	dom_camera.look_at(target, Vector3.UP)

	hair_dup_instance = MeshInstance3D.new()
	hair_dup_instance.layers = 1 << 2
	hair_dup_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hair_dup_instance.material_override = hair_capture_material
	head_rig.add_child(hair_dup_instance)

	var vp_basis := dom_camera.global_transform.basis
	for mat in [hair_material, hair_capture_material]:
		mat.set_shader_parameter("u_dom_right", vp_basis.x)
		mat.set_shader_parameter("u_dom_up", vp_basis.y)
		mat.set_shader_parameter("u_dom_size", dom_camera.size)
		mat.set_shader_parameter("u_dom_cam_pos", dom_camera.global_position)
		mat.set_shader_parameter("u_dom_dir", travel)
		mat.set_shader_parameter("u_key_dir", key_light.global_transform.basis.z)
		mat.set_shader_parameter("u_head_center", head_rig.global_position)
		mat.set_shader_parameter("u_head_radius", HEAD_RADIUS * 1.05)
	hair_material.set_shader_parameter("u_opacity_map", dom_viewport.get_texture())

func _rebuild_hair() -> void:
	var t0 := Time.get_ticks_msec()
	guides = HairStrandBuilder.sample_guides(HEAD_RADIUS, guide_count, rng_seed)
	var res: Dictionary = HairStrandBuilder.build(HEAD_RADIUS, strand_count, rng_seed, guides)
	hair_mesh_instance.mesh = res.mesh
	hair_dup_instance.mesh = res.mesh
	physics.set_shape_params_from(hair_material)
	physics.setup(guides, head_rig.global_transform)
	for mat in [hair_material, hair_capture_material]:
		mat.set_shader_parameter("u_guide_count", float(guides.size()))
		mat.set_shader_parameter("u_guide_tex", physics.texture)
	var ms := Time.get_ticks_msec() - t0
	_hair_stats = "发丝 %d 根 · 引导丝 %d · 顶点 %d · 生成 %d ms" % [
		res.strands, guides.size(), res.vertices, ms,
	]
	_update_stats()

func _queue_regen() -> void:
	_regen_timer = 0.3

func _queue_rest_rebuild() -> void:
	_rest_timer = 0.3

# ---------------------------------------------------------------- UI

func _make_material(shader_path: String, defaults: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(shader_path)
	for key in defaults:
		mat.set_shader_parameter(key, defaults[key])
	return mat

func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var theme := Theme.new()
	var sys_font := SystemFont.new()
	sys_font.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "Noto Sans CJK SC", "sans-serif",
	])
	theme.default_font = sys_font
	theme.default_font_size = 14

	var panel := PanelContainer.new()
	panel.theme = theme
	panel.anchor_bottom = 1.0
	panel.offset_left = 10
	panel.offset_top = 10
	panel.offset_bottom = -10
	panel.offset_right = 356
	layer.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "毛发渲染管线 Demo"
	title.add_theme_font_size_override("font_size", 19)
	vbox.add_child(title)
	var sub := Label.new()
	sub.text = "Strand Hair 管线 + Shell Fur\n拖动旋转视角 · 滚轮缩放"
	sub.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	vbox.add_child(sub)

	# ---- 发丝管线参数 ----
	var hair_box := _add_section(vbox, "发丝管线 Strand Hair")
	_add_regen_row(hair_box)
	for def in HAIR_SLIDERS:
		_add_param_slider(hair_box, [hair_material, hair_capture_material],
				def[0], def[1], def[2], def[3], def[4])
	_add_param_color(hair_box, hair_material, "root_color", "发根颜色")
	_add_param_color(hair_box, hair_material, "tip_color", "发梢颜色")
	_add_param_color(hair_box, hair_material, "spec1_color", "R 瓣颜色")
	_add_param_color(hair_box, hair_material, "trans_color", "透光颜色")

	# ---- 物理与自阴影 ----
	var phys_box := _add_section(vbox, "物理与自阴影")
	var dom_s := _add_value_slider(phys_box, "自阴影强度", 0.0, 1.0, 0.01,
			float(hair_material.get_shader_parameter("u_dom_strength")))
	dom_s.value_changed.connect(func(v: float) -> void:
		hair_material.set_shader_parameter("u_dom_strength", v))
	var blend_s := _add_value_slider(phys_box, "物理模拟", 0.0, 1.0, 0.01,
			float(hair_material.get_shader_parameter("u_physics_blend")))
	blend_s.value_changed.connect(func(v: float) -> void:
		for m in [hair_material, hair_capture_material]:
			m.set_shader_parameter("u_physics_blend", v))
	var stiff_s := _add_value_slider(phys_box, "形状刚度", 0.0, 0.5, 0.005, physics.stiffness)
	stiff_s.value_changed.connect(func(v: float) -> void: physics.stiffness = v)
	var damp_s := _add_value_slider(phys_box, "运动阻尼", 0.80, 0.99, 0.005, physics.damping)
	damp_s.value_changed.connect(func(v: float) -> void: physics.damping = v)
	var gc_s := _add_value_slider(phys_box, "引导丝数量", 64, 800, 32, guide_count)
	gc_s.value_changed.connect(func(v: float) -> void:
		guide_count = int(v)
		_queue_regen())

	# ---- 外壳毛发参数 ----
	var fur_box := _add_section(vbox, "外壳毛发 Shell Fur")
	for def in FUR_SLIDERS:
		_add_param_slider(fur_box, [fur_material], def[0], def[1], def[2], def[3], def[4])
	_add_param_color(fur_box, fur_material, "base_color", "毛根颜色")
	_add_param_color(fur_box, fur_material, "tip_color", "毛尖颜色")

	# ---- 场景与状态 ----
	var scene_box := _add_section(vbox, "场景")
	var row := HBoxContainer.new()
	var turntable_check := CheckBox.new()
	turntable_check.text = "转台旋转"
	turntable_check.toggled.connect(func(on: bool) -> void: turntable = on)
	var shot_btn := Button.new()
	shot_btn.text = "保存截图"
	shot_btn.pressed.connect(_save_user_screenshot)
	row.add_child(turntable_check)
	row.add_child(shot_btn)
	scene_box.add_child(row)

	_stats_label = Label.new()
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	scene_box.add_child(_stats_label)
	_update_stats()

func _add_section(parent: VBoxContainer, title: String) -> VBoxContainer:
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 16)
	parent.add_child(label)
	parent.add_child(HSeparator.new())
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	return box

func _add_regen_row(box: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "数量 / 种子"
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)

	var count := SpinBox.new()
	count.min_value = 2000
	count.max_value = 40000
	count.step = 500
	count.value = strand_count
	count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	count.value_changed.connect(func(v: float) -> void:
		strand_count = int(v)
		_queue_regen())
	row.add_child(count)

	var seed_box := SpinBox.new()
	seed_box.min_value = 0
	seed_box.max_value = 9999
	seed_box.step = 1
	seed_box.value = rng_seed
	seed_box.custom_minimum_size = Vector2(70, 0)
	seed_box.value_changed.connect(func(v: float) -> void:
		rng_seed = int(v)
		_queue_regen())
	row.add_child(seed_box)

	var btn := Button.new()
	btn.text = "随机"
	btn.pressed.connect(func() -> void:
		rng_seed = randi() % 10000
		seed_box.set_value_no_signal(rng_seed)
		_queue_regen())
	row.add_child(btn)
	box.add_child(row)

	var density := HSlider.new()
	density.min_value = 2000
	density.max_value = 40000
	density.step = 500
	density.value = strand_count
	density.custom_minimum_size = Vector2(0, 20)
	density.value_changed.connect(func(v: float) -> void:
		strand_count = int(v)
		count.set_value_no_signal(v)
		_queue_regen())
	box.add_child(density)

## 通用滑条行（自动更新数值标签），返回滑条供调用方连接信号
func _add_value_slider(box: VBoxContainer, label_text: String, min_value: float,
		max_value: float, step: float, value: float) -> HSlider:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 20)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(52, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text = "%.3f" % slider.value
	row.add_child(value_label)

	slider.value_changed.connect(func(v: float) -> void:
		value_label.text = "%.3f" % v)
	box.add_child(row)
	return slider

## 材质参数滑条：mats 里所有材质同步设值；造型参数还会同步引导丝 rest 形状
func _add_param_slider(box: VBoxContainer, mats: Array, param: String,
		label_text: String, min_value: float, max_value: float, step: float) -> void:
	var slider := _add_value_slider(box, label_text, min_value, max_value, step,
			float(mats[0].get_shader_parameter(param)))
	var do_sync: bool = param in SHAPE_PARAMS
	slider.value_changed.connect(func(v: float) -> void:
		for m in mats:
			m.set_shader_parameter(param, v)
		if do_sync:
			physics.set_shape_params_from(hair_material)
			_queue_rest_rebuild())

func _add_param_color(box: VBoxContainer, mat: ShaderMaterial, param: String,
		label_text: String) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)

	var picker := ColorPickerButton.new()
	picker.color = mat.get_shader_parameter(param)
	picker.custom_minimum_size = Vector2(52, 20)
	picker.color_changed.connect(func(c: Color) -> void:
		mat.set_shader_parameter(param, c))
	row.add_child(picker)
	box.add_child(row)

func _update_stats() -> void:
	if _stats_label == null:
		return
	_stats_label.text = "FPS %d\n%s\n%s" % [
		Engine.get_frames_per_second(), _hair_stats, _fur_stats,
	]

# ---------------------------------------------------------------- 截图

func _save_user_screenshot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "user://hair_demo_%d.png" % Time.get_ticks_msec()
	img.save_png(path)
	_hair_stats = "截图已保存: %s" % ProjectSettings.globalize_path(path)
	_update_stats()

func _capture_and_quit(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[hair_demo] screenshot saved: ", path)
	get_tree().quit()
