shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, world_vertex_coords, unshaded;

#include "res://shaders/hair_shaping.gdshaderinc"

// ============================================================================
// DOM 捕捉通道：从主光视角渲染头发副本，加法混合累计
//   R += α                 （总体不透明度）
//   G += α·深度             （α 加权平均前缘深度）
//   B += α·(1-深度)          （α 加权平均后缘深度）
// 由 main.gd 的 SubViewport（仅渲染第 3 层的头发副本，use_hdr_2d）每帧驱动。
// ============================================================================

uniform vec3 u_dom_cam_pos;
uniform vec3 u_dom_dir;      // 主光传播方向（单位）
uniform float u_dom_near = 1.8;
uniform float u_dom_far = 4.2;

varying float v_dnorm;
varying float v_t;
varying float v_side;

void vertex() {
	float t    = COLOR.r;
	float side = COLOR.g;
	float r_a  = COLOR.b;
	float r_b  = COLOR.a;
	v_t = t;
	v_side = side;

	vec4 guide_ref = vec4(UV.x, UV.y, UV2.x, 0.0);
	vec3 out_tan;
	vec3 pos = hair_shape(VERTEX, NORMAL, TANGENT, t, side, r_a, r_b,
			guide_ref, CAMERA_POSITION_WORLD, out_tan);

	float d = dot(pos - u_dom_cam_pos, u_dom_dir);
	v_dnorm = clamp((d - u_dom_near) / max(u_dom_far - u_dom_near, 1e-3), 0.0, 1.0);
	VERTEX = pos;
}

void fragment() {
	float fiber = clamp(1.0 - abs(v_side), 0.0, 1.0);
	float alpha = fiber * (1.0 - smoothstep(1.0 - tip_fade, 1.0, v_t));
	// blend_add：dst += ALBEDO * ALPHA → 累计 (α, α·d, α·(1-d))
	ALBEDO = vec3(1.0, v_dnorm, 1.0 - v_dnorm);
	ALPHA = alpha;
}
