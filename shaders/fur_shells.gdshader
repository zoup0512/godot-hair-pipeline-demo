shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, world_vertex_coords, alpha_to_coverage;

// ============================================================================
// 外壳毛发（Shell Fur / Shells Technique）
//
// CPU 阶段把球体表面沿法向复制成 N 层外壳（COLOR.r = 层高 0..1）；
// 顶点阶段沿法向挤出（带重力弯曲），片元阶段用 3D 网格噪声抠出纤维截面，
// 逐层提高镂空阈值让毛尖自然稀疏。一次 draw call 完成整只毛绒玩偶。
// ============================================================================

uniform float fur_length = 0.09;
uniform float droop : hint_range(0.0, 1.0) = 0.4;
uniform float fur_density = 65.0;      // 每米网格数
uniform float fiber_radius : hint_range(0.05, 0.6) = 0.28;
uniform float cutout : hint_range(0.0, 1.0) = 0.3;
uniform vec3 base_color : source_color = vec3(0.32, 0.22, 0.13);
uniform vec3 tip_color : source_color = vec3(0.85, 0.68, 0.45);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.5;
uniform float spec_strength : hint_range(0.0, 2.0) = 0.5;
uniform float wrap_diffuse : hint_range(0.0, 1.0) = 0.3;
uniform float aa_edge : hint_range(0.0, 1.0) = 0.15;         // A2C 边缘阈值（< 镂空阈值）
uniform float wind_amplitude = 0.004;  // 毛发随风轻摆（走路/蹦跳时调大更活泼）

varying vec3 v_base;    // 挤出前位置：纤维网格以此对齐，逐层稳定
varying float v_layer;
varying vec3 v_nrm;
varying float v_bald;   // 秃斑系数（COLOR.g）：0=正常毛，1=无毛（五官周围）

void vertex() {
	v_layer = COLOR.r;
	v_bald = COLOR.g;
	v_base = VERTEX;
	vec3 N = normalize(NORMAL);
	v_nrm = N;
	vec3 down = vec3(0.0, -1.0, 0.0);
	vec3 dir = normalize(mix(N, down, droop * v_layer * v_layer * (1.0 - 0.5 * v_bald)));
	VERTEX += dir * (fur_length * (1.0 - 0.8 * v_bald) * v_layer);
	// 毛尖随时间轻摆（低频 + 空间相位错开），脸部毛短摆动也小
	VERTEX += vec3(sin(TIME * 2.6 + v_base.x * 4.0 + v_base.y * 3.0) * 0.7,
			cos(TIME * 2.1 + v_base.z * 5.0) * 0.3,
			sin(TIME * 1.8 + v_base.x * 3.0) * 0.5) * (wind_amplitude * v_layer * (1.0 - 0.6 * v_bald));
}

float hash13(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void fragment() {
	vec3 p = v_base * fur_density;
	vec3 cell = floor(p);
	vec3 f = fract(p) - 0.5;
	vec3 off = (vec3(hash13(cell),
			hash13(cell + vec3(31.7, 11.3, 7.1)),
			hash13(cell + vec3(5.3, 71.9, 13.7))) - 0.5) * 0.4;
	float d = length(f - off);
	float radius = fiber_radius * (1.0 - 0.55 * v_layer) * (1.0 - 0.45 * v_bald);
	float fiber = smoothstep(radius, radius * 0.35, d);

	// 五官周围：纤维变细 + 变稀（alpha 降低配合 scissor 剔除）
	float alpha = fiber * (1.0 - smoothstep(0.55, 1.0, v_layer) * 0.65);
	alpha *= 1.0 - 0.85 * v_bald;

	float hue_var = hash13(cell + vec3(9.1, 3.7, 41.3)) - 0.5;
	vec3 base = mix(base_color, tip_color, clamp(v_layer + hue_var * 0.4, 0.0, 1.0));
	base *= 1.0 + hue_var * 0.5;

	float ao = mix(1.0 - ao_strength, 1.0, sqrt(v_layer));
	ALBEDO = base * ao;
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = cutout;
	ALPHA_ANTIALIASING_EDGE = aa_edge;
	// 纤维截面距离 d 随像素平滑变化 → A2C 覆盖率沿纤维边缘渐变
	ALPHA_TEXTURE_COORDINATE = vec2(d * 2.0, v_layer);
}

void light() {
	vec3 N = normalize(v_nrm);
	float ndl = dot(N, LIGHT);
	float diff = clamp((ndl + wrap_diffuse) / (1.0 + wrap_diffuse), 0.0, 1.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * diff;

	float ks = pow(max(dot(N, normalize(LIGHT + VIEW)), 0.0), 32.0);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * ks * spec_strength;
}
