extends RefCounted
## Verlet 引导发丝物理（CPU）：
##   - 每根引导丝是一条 10 点粒子链，Verlet 积分（重力 + 风 + 阻尼）
##   - 约束：距离约束（跟随链，段长取 rest 实际间距）+ 形状回弹 + 头部球体碰撞
##   - 链首钉在发根上，随头部转动 → 转头时头发会甩动、回弹
## 每帧把链上位置写入 RGBA32F 数据纹理，顶点着色器把稠密发丝插值到引导丝上
## （见 shaders/hair_shaping.gdshaderinc 的 hair_shape）。
##
## 注意：GDScript 的 PackedVector3Array 是值类型，必须用扁平成员数组写入，
## 否则局部副本的修改会被丢弃。rest 形状必须与着色器程序化造型一致
## （_shaped_point 镜像了 hair_shape 的程序化部分，不含风与 ribbon）。

const POINTS := 10   # 与 hair_strand_builder.SEGMENTS + 1 一致
const TEX_W := 16    # 数据纹理宽度（POINTS 向上取整，留 seg±1 采样余量）

var texture: ImageTexture

var damping := 0.94       # 速度保留系数（每帧）
var stiffness := 0.12     # 形状回弹强度
var gravity := 9.8
var wind_strength := 90.0 # 风力→加速度换算（wind_amplitude 为位移量纲，力的量纲更大）

# 造型参数（与材质 uniform 同步，rest 形状依赖它们）
var length_min := 0.10
var length_max := 0.34
var droop := 1.5
var clump := 0.65
var curl_amount := 0.07
var curl_freq := 2.4
var wind_amplitude := 0.01
var wind_frequency := 1.5

## 从主发丝材质读取造型参数（与 hair_shaping.gdshaderinc 的 uniform 对应）；
## 材质未设置的参数保留当前默认值
func set_shape_params_from(mat: ShaderMaterial) -> void:
	length_min = _paramf(mat, "length_min", length_min)
	length_max = _paramf(mat, "length_max", length_max)
	droop = _paramf(mat, "droop", droop)
	clump = _paramf(mat, "clump", clump)
	curl_amount = _paramf(mat, "curl_amount", curl_amount)
	curl_freq = _paramf(mat, "curl_freq", curl_freq)
	wind_amplitude = _paramf(mat, "wind_amplitude", wind_amplitude)
	wind_frequency = _paramf(mat, "wind_frequency", wind_frequency)

func _paramf(mat: ShaderMaterial, name: String, fallback: float) -> float:
	var v = mat.get_shader_parameter(name)
	return float(v) if v != null else fallback

var _guides := []                       # builder.sample_guides() 的输出
var _rest := PackedVector3Array()       # 扁平：局部 rest 形状 (count×POINTS)
var _seglen := PackedFloat32Array()     # 扁平：rest 相邻点距离 (count×(POINTS-1))
var _pos := PackedVector3Array()        # 扁平：世界空间当前位置 (count×POINTS)
var _prev := PackedVector3Array()       # 扁平：上一帧位置
var _lenarr := PackedFloat32Array()     # 扁平：每丝长度（纹理 w 通道）
var _count := 0
var _data := PackedFloat32Array()

func setup(entries: Array, head_xform: Transform3D) -> void:
	_guides = entries
	_count = entries.size()
	rebuild_rest()
	_pos.resize(_count * POINTS)
	_prev.resize(_count * POINTS)
	for gi in _count:
		for i in POINTS:
			var w: Vector3 = head_xform * Vector3(_rest[gi * POINTS + i])
			_pos[gi * POINTS + i] = w
			_prev[gi * POINTS + i] = w
	_data.resize(TEX_W * _count * 4)
	texture = null
	_write_texture()

## 造型参数变化后重算 rest（局部空间），发丝会通过回弹平滑过渡到新形状
func rebuild_rest() -> void:
	_rest.resize(_count * POINTS)
	_seglen.resize(_count * (POINTS - 1))
	_lenarr.resize(_count)
	for gi in _count:
		var e: Dictionary = _guides[gi]
		var L := lerpf(length_min, length_max, e.len_rand)
		_lenarr[gi] = L
		var root: Vector3 = e.root
		var dir: Vector3 = e.dir
		var a_axis: Vector3 = e.a_axis
		var b_axis: Vector3 = e.b_axis
		var rnd_b: float = e.rnd_b
		for i in POINTS:
			var t := float(i) / float(POINTS - 1)
			_rest[gi * POINTS + i] = _shaped_point(root, dir, a_axis, b_axis, L, t, rnd_b)
		for i in POINTS - 1:
			_seglen[gi * (POINTS - 1) + i] = \
					_rest[gi * POINTS + i].distance_to(_rest[gi * POINTS + i + 1])

func step(head_xform: Transform3D, head_center: Vector3, head_radius: float,
		time_sec: float, delta: float) -> void:
	if _count == 0:
		return
	var dt := minf(delta, 1.0 / 30.0)
	var dt2 := dt * dt

	for gi in _count:
		var e: Dictionary = _guides[gi]
		var base := gi * POINTS
		var root_w: Vector3 = head_xform * (e.root as Vector3)
		var phase: float = e.rnd_b * TAU + (e.root.x * 3.1 - e.root.z * 2.7) * 2.0

		# 链首钉在发根（跟随头部旋转）
		_pos[base] = root_w
		_prev[base] = root_w

		for i in range(1, POINTS):
			var t := float(i) / float(POINTS - 1)
			var rest_w: Vector3 = head_xform * Vector3(_rest[base + i])
			# 风：与着色器风摆同频同相，作为加速度作用在粒子上
			var wind := sin(time_sec * wind_frequency + phase + t * 2.6)
			var accel := Vector3(0.0, -gravity, 0.0) \
					+ Vector3(0.7, 0.0, 0.7) * (wind * wind_amplitude * wind_strength)
			var vel: Vector3 = (_pos[base + i] - _prev[base + i]) * damping
			_prev[base + i] = _pos[base + i]
			_pos[base + i] += vel + accel * dt2 + (rest_w - _pos[base + i]) * stiffness

		# 约束迭代：距离（段长 = rest 实际间距，只推子点的跟随链）+ 头部碰撞
		for _iter in 2:
			for i in range(1, POINTS):
				var d: Vector3 = _pos[base + i] - _pos[base + i - 1]
				var l := d.length()
				var seg_len: float = _seglen[gi * (POINTS - 1) + i - 1]
				if l > 1e-6:
					_pos[base + i] = _pos[base + i - 1] + d * (seg_len / l)
				var off: Vector3 = _pos[base + i] - head_center
				var ol := off.length()
				if ol < head_radius:
					_pos[base + i] = head_center + off * (head_radius / maxf(ol, 1e-6))

	_write_texture()

## 与 shaders/hair_shaping.gdshaderinc 的 hair_shape() 程序化部分保持一致
## （不含风摆与 ribbon 展开；改着色器造型时务必同步这里）
func _shaped_point(root: Vector3, D: Vector3, A: Vector3, B: Vector3,
		L: float, t: float, r_b: float) -> Vector3:
	var down := Vector3(0.0, -1.0, 0.0)
	var dh := down - D * D.dot(down)
	var dhl := dh.length()
	var cw := clampf(dhl * 1.5, 0.0, 1.0) * clump
	var flow := (dh / dhl if dhl > 0.15 else A) + A * 0.3 * sin(r_b * TAU)
	var s := smoothstep(0.0, 1.0, t)
	var bend := (flow - D) * (cw * L * s)
	var w := t * curl_freq * TAU + r_b * TAU
	var curl := (A * cos(w) + B * sin(w)) * (curl_amount * L * t)
	return root + D * (L * t) + bend + down * (droop * L * t * t) + curl

func _write_texture() -> void:
	var f := 0
	for gi in _count:
		var base := gi * POINTS
		for x in TEX_W:
			var i := mini(x, POINTS - 1)
			_data[f] = _pos[base + i].x
			_data[f + 1] = _pos[base + i].y
			_data[f + 2] = _pos[base + i].z
			_data[f + 3] = _lenarr[gi]
			f += 4
	var img := Image.create_from_data(TEX_W, _count, false, Image.FORMAT_RGBAF,
			_data.to_byte_array())
	if texture == null:
		texture = ImageTexture.create_from_image(img)
	else:
		texture.update(img)
