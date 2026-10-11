shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, world_vertex_coords, alpha_to_coverage;

#include "res://shaders/hair_shaping.gdshaderinc"
#include "res://shaders/hair_dom.gdshaderinc"

// ============================================================================
// 发丝（Strand Hair）渲染管线 —— GPU 阶段
// 造型与引导丝逻辑在 hair_shaping.gdshaderinc，DOM 自阴影在 hair_dom.gdshaderinc。
// 本文件：着色（Marschner 三瓣 + 根部AO + rim）与透明处理（scissor + A2C）。
// ============================================================================

uniform vec3 root_color : source_color = vec3(0.05, 0.03, 0.02);
uniform vec3 tip_color : source_color = vec3(0.22, 0.13, 0.055);
uniform float value_variation : hint_range(0.0, 1.0) = 0.35;
uniform float cutout : hint_range(0.0, 1.0) = 0.35;    // alpha scissor 阈值

uniform float spec1_power : hint_range(2.0, 512.0) = 150.0;  // R 瓣：毛小皮表面反射
uniform float spec1_shift : hint_range(-0.9, 0.9) = -0.15;
uniform float spec1_strength : hint_range(0.0, 4.0) = 0.2;
uniform vec3 spec1_color : source_color = vec3(1.0, 0.96, 0.9);
uniform float spec2_power : hint_range(2.0, 128.0) = 25.0;   // TRT 瓣：内部二次反射
uniform float spec2_shift : hint_range(-0.9, 0.9) = 0.4;
uniform float spec2_strength : hint_range(0.0, 4.0) = 0.12;
uniform float trans_power : hint_range(1.0, 32.0) = 6.0;     // TT 瓣：透射（逆光辉光）
uniform float trans_strength : hint_range(0.0, 1.0) = 0.32;
uniform vec3 trans_color : source_color = vec3(1.0, 0.62, 0.3);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.15;
uniform float root_ao : hint_range(0.0, 1.0) = 0.55;
uniform float ambient_fill : hint_range(0.0, 1.0) = 0.05;
uniform float aa_edge : hint_range(0.0, 1.0) = 0.15;         // A2C 边缘阈值（< 镂空阈值）

varying vec3 v_tangent;
varying vec3 v_world;   // 造型后的世界坐标（DOM 自阴影采样用）
varying float v_t;
varying float v_side;
varying float v_rand;

void vertex() {
	float t    = COLOR.r;
	float side = COLOR.g;
	float r_a  = COLOR.b;
	float r_b  = COLOR.a;
	v_t = t;
	v_side = side;
	v_rand = r_b;

	vec4 guide_ref = vec4(UV.x, UV.y, UV2.x, 0.0);
	vec3 shaped_tan;
	vec3 pos = hair_shape(VERTEX, NORMAL, TANGENT, t, side, r_a, r_b,
			guide_ref, CAMERA_POSITION_WORLD, shaped_tan);
	v_tangent = shaped_tan;
	v_world = pos;
	NORMAL = v_tangent;
	VERTEX = pos;
}

void fragment() {
	float t = v_t;
	// 横向 1-|side| 线性渐变 → 配合 scissor/A2C 得到圆润的发丝截面
	float fiber = clamp(1.0 - abs(v_side), 0.0, 1.0);
	float alpha = fiber * (1.0 - smoothstep(1.0 - tip_fade, 1.0, t));

	float vary = (v_rand - 0.5) * 2.0 * value_variation;
	vec3 base = mix(root_color, tip_color, clamp(t + vary * 0.45, 0.0, 1.0));
	base *= 1.0 + vary * 0.4;

	float ao = mix(1.0 - root_ao, 1.0, smoothstep(0.0, 0.4, t));
	ALBEDO = base * ao;
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = cutout;
	ALPHA_ANTIALIASING_EDGE = aa_edge;
	ALPHA_TEXTURE_COORDINATE = vec2(v_t, v_side);

	// 边缘光（用切线算菲涅尔）+ 轻微环境补光
	float tv = abs(dot(normalize(v_tangent), normalize(VIEW)));
	float fres = pow(clamp(1.0 - tv, 0.0, 1.0), 4.0);
	EMISSION = tip_color * fres * rim_strength + base * ambient_fill * (0.6 + 0.4 * t);
}

// Marschner 三瓣各向异性光照（KK 式 sin 幂近似）；ATTENUATION 自带场景阴影。
// DOM 自阴影只作用于主光（用 u_key_dir 识别），TT 瓣只依赖光线方向、逆光时最亮。
void light() {
	vec3 T = normalize(v_tangent);
	float TdL = dot(T, LIGHT);
	float kdiff = sqrt(max(1.0 - TdL * TdL, 0.0));

	float dom = 1.0;
	if (dot(normalize(LIGHT), normalize(u_key_dir)) > 0.99) {
		dom = hair_dom_shadow(v_world);
	}

	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * dom * kdiff;

	vec3 H = normalize(LIGHT + VIEW);
	float TdH = dot(T, H);
	// 背光因子：视线与光线方向相反（光源在头发背后）时透射才可见
	float backlit = clamp(-dot(normalize(VIEW), normalize(LIGHT)), 0.0, 1.0);
	// R：锐利、近白、向发根偏移
	float s_r = clamp(TdH + spec1_shift, -1.0, 1.0);
	float kR = pow(sqrt(max(1.0 - s_r * s_r, 0.0)), spec1_power);
	// TRT：宽带、被头发颜色染色、向发梢偏移
	float s_t = clamp(TdH + spec2_shift, -1.0, 1.0);
	float kTRT = pow(sqrt(max(1.0 - s_t * s_t, 0.0)), spec2_power);

	SPECULAR_LIGHT += (spec1_color * (kR * spec1_strength)
			+ ALBEDO * (kTRT * spec2_strength * 2.0)
			+ trans_color * (pow(kdiff, trans_power) * trans_strength * backlit))
			* LIGHT_COLOR * ATTENUATION * dom;
}
