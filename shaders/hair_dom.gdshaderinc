// ============================================================================
// Deep Opacity 自阴影（发丝间互相遮挡）
//
// main.gd 用 SubViewport 从主光方向渲染一份头发副本（加法混合，见
// hair_opacity_capture.gdshader）：R = 累计不透明度，G = α·深度，B = α·(1-深度)。
// 着色时按「体积前缘 → 本片元」的深度比例做指数衰减 —— 外层发丝保持被照亮，
// 内部与发根被前方发丝遮挡变暗，消除“充气假发”感。
// ============================================================================

uniform sampler2D u_opacity_map : filter_linear, repeat_disable;
uniform vec3 u_dom_right;              // 捕捉相机右方向（世界，单位）
uniform vec3 u_dom_up;                 // 捕捉相机上方向（世界，单位）
uniform float u_dom_size = 1.7;        // 正交视野高度（米）
uniform vec3 u_dom_cam_pos;            // 捕捉相机世界位置
uniform vec3 u_dom_dir;                // 主光传播方向（单位）
uniform float u_dom_near = 1.8;        // 深度归一化区间（沿传播方向）
uniform float u_dom_far = 4.2;
uniform float u_dom_strength = 0.5;
uniform vec3 u_key_dir = vec3(0.0, 1.0, 0.0);   // 主光方向（表面指向光源）

float hair_dom_shadow(vec3 wpos) {
	vec3 rel = wpos - u_dom_cam_pos;
	vec2 uv = vec2(dot(rel, u_dom_right), dot(rel, u_dom_up)) / u_dom_size + 0.5;
	vec4 s = texture(u_opacity_map, uv);
	float op = s.r;
	if (op < 1e-3) {
		return 1.0;
	}
	float d_front = s.g / op;             // α 加权平均前缘深度（归一化 0..1）
	float d_back = 1.0 - s.b / op;        // α 加权平均后缘深度
	float d = dot(wpos - u_dom_cam_pos, u_dom_dir);
	float dn = clamp((d - u_dom_near) / max(u_dom_far - u_dom_near, 1e-3), 0.0, 1.0);
	float t_vol = clamp((dn - d_front) / max(d_back - d_front, 1e-3), 0.0, 1.0);
	return exp(-u_dom_strength * 4.0 * op * t_vol);
}
