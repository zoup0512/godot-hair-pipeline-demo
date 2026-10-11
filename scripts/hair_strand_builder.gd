extends RefCounted
## 毛发管线 CPU 阶段：头皮采样 + 发丝属性烘焙。
## 每根发丝只存「根位置 / 生长方向 / 卷曲正交基 / 参数化数据」，
## 形状与动画全部在 GPU 顶点着色器里解析求值，因此长度、重力、风等参数实时可调。
##
## 顶点布局（与 shaders/hair_shaping.gdshaderinc 对应）：
##   POSITION  = 发根位置
##   NORMAL    = 生长方向（含切向扰动）
##   TANGENT   = 卷曲正交基 A（w=1）
##   COLOR     = (t, side, randA, randB)
##   UV / UV2  = (引导丝A索引, 引导丝B索引) / (权重A, 0)   —— Verlet 物理插值用
##   索引      = 每根发丝一条三角带（SEGMENTS 段）

const SEGMENTS := 9  # 每根发丝的分段数，顶点数 = (SEGMENTS + 1) * 2

## 采样发丝参数（发际线 = 前额高/脑后低 + 低频噪声；长度按 d.y² 分层、前额更短）。
## 发丝网格与 Verlet 引导丝共用同一采样器。
static func sample_strands(radius: float, count: int, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 2.5

	var out := []
	var made := 0
	var attempts := 0
	var max_attempts := count * 40
	while made < count and attempts < max_attempts:
		attempts += 1
		var d := _random_unit_dir(rng)

		var az := absf(atan2(d.x, d.z)) / PI  # 0 = 正前, 1 = 正后
		var hairline := lerpf(0.50, 0.02, smoothstep(0.18, 0.72, az))
		hairline += noise.get_noise_3d(d.x, d.y, d.z) * 0.14
		if d.y <= hairline:
			continue

		var ja := rng.randf_range(-1.0, 1.0)
		var jb := rng.randf_range(-1.0, 1.0)
		var t1 := d.cross(Vector3.UP)
		if t1.length_squared() < 1e-4:
			t1 = Vector3(1.0, 0.0, 0.0)
		t1 = t1.normalized()
		var t2 := d.cross(t1).normalized()
		var dir := (d + (t1 * ja + t2 * jb) * 0.12).normalized()

		# 卷曲正交基：绕发根方向随机旋转
		var rot := rng.randf_range(0.0, TAU)
		var a_axis := (t1 * cos(rot) + t2 * sin(rot)).normalized()
		var b_axis := d.cross(a_axis).normalized()

		var len_rand := clampf(rng.randf() * 0.35 + d.y * d.y * 0.75, 0.0, 1.0)
		len_rand *= lerpf(1.0, 0.55, smoothstep(0.25, 0.75, d.z))

		out.append({
			"root": d * (radius * 0.985),
			"dir": dir,
			"a_axis": a_axis,
			"b_axis": b_axis,
			"len_rand": len_rand,
			"rnd_b": rng.randf(),
		})
		made += 1
	return out

## 采样 Verlet 引导丝（与发丝同一采样器，独立种子流）
static func sample_guides(radius: float, count: int, seed_value: int) -> Array:
	if count <= 0:
		return []
	return sample_strands(radius, count, seed_value)

## 头顶毛簇采样：球冠（d.y > cap_y）上的短毛，顶部更密、无发际线逻辑。
## root 以球心为原点，调用方自行叠加头部中心偏移/倾斜。
static func sample_cap_strands(radius: float, count: int, seed_value: int,
		cap_y := 0.45) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out := []
	var attempts := 0
	var max_attempts := count * 80
	while out.size() < count and attempts < max_attempts:
		attempts += 1
		var d := _random_unit_dir(rng)
		if d.y < cap_y:
			continue
		if rng.randf() > 0.35 + 0.65 * d.y:
			continue
		var t1 := d.cross(Vector3.UP)
		if t1.length_squared() < 1e-4:
			t1 = Vector3(1.0, 0.0, 0.0)
		t1 = t1.normalized()
		var t2 := d.cross(t1).normalized()
		var ja := rng.randf_range(-1.0, 1.0)
		var jb := rng.randf_range(-1.0, 1.0)
		var dir := (d + (t1 * ja + t2 * jb) * 0.25).normalized()
		var rot := rng.randf_range(0.0, TAU)
		var a_axis := (t1 * cos(rot) + t2 * sin(rot)).normalized()
		var b_axis := d.cross(a_axis).normalized()
		out.append({
			"root": d * (radius * 0.985),
			"dir": dir,
			"a_axis": a_axis,
			"b_axis": b_axis,
			"len_rand": rng.randf(),
			"rnd_b": rng.randf(),
		})
	return out

## 烘焙发丝网格。guides 非空时为每根发丝写入最近的 2 根引导丝索引与权重（UV/UV2）。
static func build(radius: float, strand_count: int, seed_value: int, guides: Array = []) -> Dictionary:
	return build_from_params(sample_strands(radius, strand_count, seed_value), guides)

## 从已采样的发丝参数构建网格（桌面萌宠的头顶毛簇等自定义采样用）
static func build_from_params(strands: Array, guides: Array) -> Dictionary:
	var made := strands.size()
	if made == 0:
		return {"mesh": ArrayMesh.new(), "strands": 0, "vertices": 0}

	var guide_grid := {}
	if not guides.is_empty():
		guide_grid = _guide_grid(guides)

	var verts_per_strand := (SEGMENTS + 1) * 2
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	pos.resize(made * verts_per_strand)
	nrm.resize(made * verts_per_strand)
	tan.resize(made * verts_per_strand * 4)
	col.resize(made * verts_per_strand)
	uv.resize(made * verts_per_strand)
	uv2.resize(made * verts_per_strand)

	for si in made:
		var e: Dictionary = strands[si]
		var root: Vector3 = e.root
		var dir: Vector3 = e.dir
		var a_axis: Vector3 = e.a_axis
		var len_rand: float = e.len_rand
		var rnd_b: float = e.rnd_b

		var guide_ref := Vector2.ZERO
		var guide_w := 0.0
		if not guide_grid.is_empty():
			var near := _nearest_guides(dir, guides, guide_grid)
			guide_ref = Vector2(near.x, near.y)
			guide_w = near.z

		var base := si * verts_per_strand
		for seg in SEGMENTS + 1:
			var t := float(seg) / float(SEGMENTS)
			for side in 2:
				var vi := base + seg * 2 + side
				pos[vi] = root
				nrm[vi] = dir
				tan[vi * 4 + 0] = a_axis.x
				tan[vi * 4 + 1] = a_axis.y
				tan[vi * 4 + 2] = a_axis.z
				tan[vi * 4 + 3] = 1.0
				col[vi] = Color(t, -1.0 if side == 0 else 1.0, len_rand, rnd_b)
				uv[vi] = guide_ref
				uv2[vi] = Vector2(guide_w, 0.0)
		for seg in SEGMENTS:
			var a0 := base + seg * 2
			idx.append(a0)
			idx.append(a0 + 1)
			idx.append(a0 + 2)
			idx.append(a0 + 1)
			idx.append(a0 + 3)
			idx.append(a0 + 2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TANGENT] = tan
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# 实际形状在顶点着色器里展开，AABB 需要手动放宽以避免误剔除
	mesh.custom_aabb = AABB(Vector3(-1.2, -1.5, -1.2), Vector3(2.4, 2.5, 2.4))

	return {"mesh": mesh, "strands": made, "vertices": pos.size()}

# ---------------------------------------------------------------- 引导丝匹配

## 方位角/仰角网格桶（24×12），把最近邻查询降到 O(邻域)
static func _guide_grid(guides: Array) -> Dictionary:
	var grid := {}
	for gi in guides.size():
		var d: Vector3 = guides[gi].dir
		var az := int(floor((atan2(d.x, d.z) / PI + 1.0) * 12.0))  # 0..23
		var el := int(floor((asin(clampf(d.y, -1.0, 1.0)) / PI + 0.5) * 12.0))  # 0..11
		var key := az * 12 + el
		if not grid.has(key):
			grid[key] = PackedInt32Array()
		grid[key].append(gi)
	return grid

## 返回 (索引A, 索引B, 权重A)：角距离最近的两根引导丝，权重按角距离反比
static func _nearest_guides(d: Vector3, guides: Array, grid: Dictionary) -> Vector3:
	var az := (atan2(d.x, d.z) / PI + 1.0) * 12.0
	var el := (asin(clampf(d.y, -1.0, 1.0)) / PI + 0.5) * 12.0
	var best_a := [PI, -1, PI, -1]  # [角度1, 索引1, 角度2, 索引2]
	for ox in [-1, 0, 1]:
		for oy in [-1, 0, 1]:
			var azb: int = int(floor(az)) + ox
			var azw: int = ((azb % 24) + 24) % 24
			var elb: int = clampi(int(floor(el)) + oy, 0, 11)
			var key: int = azw * 12 + elb
			if not grid.has(key):
				continue
			for gi in grid[key]:
				var gi_i: int = gi
				var gdir: Vector3 = guides[gi_i].dir
				var ang: float = acos(clampf(d.dot(gdir), -1.0, 1.0))
				if ang < best_a[0]:
					best_a[2] = best_a[0]
					best_a[3] = best_a[1]
					best_a[0] = ang
					best_a[1] = gi_i
				elif ang < best_a[2] and gi_i != best_a[1]:
					best_a[2] = ang
					best_a[3] = gi_i
	if best_a[1] < 0:
		# 邻域没找到（引导丝很稀疏时），全量扫描
		for gi in guides.size():
			var gi_i: int = gi
			var gdir: Vector3 = guides[gi_i].dir
			var ang: float = acos(clampf(d.dot(gdir), -1.0, 1.0))
			if ang < best_a[0]:
				best_a[2] = best_a[0]
				best_a[3] = best_a[1]
				best_a[0] = ang
				best_a[1] = gi_i
			elif ang < best_a[2] and gi_i != best_a[1]:
				best_a[2] = ang
				best_a[3] = gi_i
	var ia: int = best_a[1]
	var ib: int = best_a[3]
	var ang_a: float = best_a[0]
	var ang_b: float = best_a[2]
	if ib < 0:
		ib = ia
		ang_b = ang_a
	# 只用最近引导丝（权重 1）：两根引导丝位移的线性插值会“切角”缩短头发，
	# 丢失体积；相邻引导丝形状相近，接缝由发丝自身卷曲掩盖
	var wa: float = 1.0
	return Vector3(ia, ib, wa)

static func _random_unit_dir(rng: RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var a := rng.randf_range(0.0, TAU)
	var r := sqrt(maxf(0.0, 1.0 - z * z))
	return Vector3(r * cos(a), z, r * sin(a))
