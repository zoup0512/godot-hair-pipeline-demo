extends RefCounted
## 外壳毛发 CPU 阶段：把若干球体沿法向复制成 N 层外壳，合并为单个表面。
## COLOR.r 存层高（0..1），COLOR.g 存「秃斑系数」（0=正常毛，1=无毛），
## 由 shaders/fur_shells.gdshader 据此缩短/稀疏毛发——五官周围用遮罩让脸露出来。

## parts 每项: {center, radius, radial?, rings?, masks?}
## masks: [[doll局部坐标 Vector3, 半径 float], ...] —— 该球面顶点落在遮罩球内时毛发变短变稀

static func build(parts: Array, layers: int) -> Dictionary:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	var vert_base := 0

	for part in parts:
		var sphere := SphereMesh.new()
		sphere.radius = part.radius
		sphere.height = part.radius * 2.0
		sphere.radial_segments = part.get("radial", 40)
		sphere.rings = part.get("rings", 20)
		var masks: Array = part.get("masks", [])

		var src := sphere.get_mesh_arrays()
		var sv: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
		var sn: PackedVector3Array = src[Mesh.ARRAY_NORMAL]
		var st: PackedFloat32Array = src[Mesh.ARRAY_TANGENT]
		var su: PackedVector2Array = src[Mesh.ARRAY_TEX_UV]
		var si: PackedInt32Array = src[Mesh.ARRAY_INDEX]
		var vc := sv.size()
		var center: Vector3 = part.center

		for layer in layers:
			var f := 0.0 if layers <= 1 else float(layer) / float(layers - 1)
			for i in vc:
				var vpos: Vector3 = sv[i] + center
				var bald := 0.0
				for mk in masks:
					var d := vpos.distance_to(mk[0])
					bald = maxf(bald, 1.0 - smoothstep(mk[1] * 0.45, mk[1], d))
				pos.append(vpos)
				nrm.append(sn[i])
				tan.append(st[i * 4 + 0])
				tan.append(st[i * 4 + 1])
				tan.append(st[i * 4 + 2])
				tan.append(st[i * 4 + 3])
				uv.append(su[i])
				col.append(Color(f, bald, 0.0, 0.0))
			for i in si.size():
				idx.append(si[i] + vert_base)
			vert_base += vc

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TANGENT] = tan
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = AABB(Vector3(-1.2, -0.5, -1.2), Vector3(2.4, 3.0, 2.4))

	return {"mesh": mesh, "vertices": pos.size()}
