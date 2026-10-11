// ============================================================================
// 发丝造型共享代码（被 hair_strands.gdshader 与 hair_opacity_capture.gdshader
// #include）—— 两个通道必须产生完全一致的形状，DOM 捕捉体积才与可见头发吻合。
//
// 顶点属性（由 scripts/hair_strand_builder.gd 烘焙）：
//   POSITION = 发根   NORMAL = 生长方向   TANGENT = 卷曲正交基 A
//   COLOR    = (t, side, randA, randB)
//   UV       = (引导丝A索引, 引导丝B索引)   UV2 = (权重A, 0)
//
// Verlet 引导丝数据纹理（CPU 每帧上传，RGBA32F）：
//   texel(x=分段 0..9, y=引导丝索引) = (世界位置 xyz, 该引导丝长度)
// ============================================================================

// ---- 造型参数（main.gd 会把值同步到主材质与捕捉材质）----
uniform float length_min = 0.10;
uniform float length_max = 0.34;
uniform float droop = 1.5;          // 重力下垂强度
uniform float clump = 0.65;         // 沿头皮“下坡”方向的收拢
uniform float curl_amount = 0.07;
uniform float curl_freq = 2.4;
uniform float wind_amplitude = 0.01;
uniform float wind_frequency = 1.5;
uniform float width_root = 0.0062;
uniform float width_tip = 0.0012;
uniform float tip_fade = 0.2;       // 发梢渐隐长度

// ---- Verlet 引导丝 ----
uniform sampler2D u_guide_tex : filter_nearest, repeat_disable;
uniform float u_guide_count = 1.0;
uniform float u_physics_blend = 0.0;   // 0 = 纯程序化，1 = 完全跟随物理模拟
uniform vec3 u_head_center = vec3(0.0, 1.42, 0.0);  // 头部碰撞球（世界）
uniform float u_head_radius = 0.365;

// 计算造型后的最终顶点位置（含 ribbon 展开），out_tan 为发丝切线。
// guide_ref = (引导丝A索引, 引导丝B索引, 权重A, 0)
vec3 hair_shape(vec3 P0, vec3 D, vec3 A, float t, float side, float r_a, float r_b,
		vec4 guide_ref, vec3 cam_pos, out vec3 out_tan) {
	float L = mix(length_min, length_max, r_a);
	vec3 B = cross(D, A);
	vec3 down = vec3(0.0, -1.0, 0.0);
	float tt = t * t;

	// ---- 程序化造型：沿头皮“下坡”方向 S 曲线收拢 + 重力 + 螺旋卷曲 + 风 ----
	// （CPU 侧 rest 形状见 scripts/hair_physics.gd 的 _shaped_point，两处保持一致）
	vec3 downhill = down - D * dot(D, down);
	float dh_len = length(downhill);
	float clump_w = clamp(dh_len * 1.5, 0.0, 1.0) * clump;
	vec3 flow = (dh_len > 0.15 ? downhill / dh_len : A) + A * 0.3 * sin(r_b * 6.28318);
	float s_shape = smoothstep(0.0, 1.0, t);
	vec3 bend = (flow - D) * (clump_w * L * s_shape);

	float phase = r_b * 6.28318;
	float w = t * curl_freq * 6.28318 + phase;
	vec3 curl = (A * cos(w) + B * sin(w)) * (curl_amount * L * t);

	vec3 sway_axis = normalize(A * 0.7 + vec3(0.7, 0.0, 0.7));
	float sway = sin(TIME * wind_frequency + phase + dot(P0.xz, vec2(3.1, -2.7)) * 2.0 + t * 2.6);

	vec3 pos = P0 + D * (L * t) + bend + down * (droop * L * tt) + curl
			+ sway_axis * (sway * wind_amplitude * tt);

	vec3 dpos = D * L + (flow - D) * (clump_w * L * 6.0 * t * (1.0 - t))
			+ down * (droop * L * 2.0 * t)
			+ curl_amount * L * (A * cos(w) + B * sin(w))
			+ curl_amount * L * t * curl_freq * 6.28318 * (B * cos(w) - A * sin(w));
	vec3 Tdir = normalize(dpos);

	// ---- Verlet 引导丝位移：把 CPU 模拟出的摆动/下垂/碰撞响应转移到发丝上 ----
	if (u_physics_blend > 0.001) {
		int ia = min(int(guide_ref.x + 0.5), int(u_guide_count) - 1);
		int ib = min(int(guide_ref.y + 0.5), int(u_guide_count) - 1);
		float wa = clamp(guide_ref.z, 0.0, 1.0);
		int seg = int(t * 9.0 + 0.5);   // 与 builder 的 SEGMENTS=9 对应
		vec4 pa = texelFetch(u_guide_tex, ivec2(seg, ia), 0);
		vec4 pb = texelFetch(u_guide_tex, ivec2(seg, ib), 0);
		vec3 ra = texelFetch(u_guide_tex, ivec2(0, ia), 0).xyz;
		vec3 rb = texelFetch(u_guide_tex, ivec2(0, ib), 0).xyz;
		float wmix = wa;
		vec3 gpos = mix(pb.xyz, pa.xyz, wmix);
		vec3 groot = mix(rb, ra, wmix);
		float glen = max(mix(pb.w, pa.w, wmix), 1e-3);
		vec3 gp1 = mix(texelFetch(u_guide_tex, ivec2(min(seg + 1, 15), ib), 0).xyz,
				texelFetch(u_guide_tex, ivec2(min(seg + 1, 15), ia), 0).xyz, wmix);
		vec3 gm1 = mix(texelFetch(u_guide_tex, ivec2(max(seg - 1, 0), ib), 0).xyz,
				texelFetch(u_guide_tex, ivec2(max(seg - 1, 0), ia), 0).xyz, wmix);
		vec3 gtan = normalize(gp1 - gm1 + vec3(1e-5));
		// 位移按本丝长度缩放，保留发丝间的长短差异；
		// 物理模式下增强自身卷曲，补偿引导丝插值带来的细节损失
		vec3 disp = (gpos - groot) * (L / glen);
		curl *= 1.0 + u_physics_blend * 1.2;
		vec3 gtarget = P0 + disp + curl;
		pos = mix(pos, gtarget, u_physics_blend);
		// 摆动交给物理后，减弱程序化风摆避免叠加
		pos -= sway_axis * (sway * wind_amplitude * tt) * u_physics_blend;
		Tdir = normalize(mix(Tdir, gtan, u_physics_blend * 0.6));
	}

	// 发丝级碰撞兜底：两根引导丝之间的插值可能穿过头部，把 t>0 的点推到球面外
	if (u_physics_blend > 0.001 && t > 0.0) {
		vec3 off = pos - u_head_center;
		float l = max(length(off), 1e-5);
		float k = u_head_radius / l;
		k = k > 1.0 ? k : 1.0;   // 仅在球内时向外推
		float push = smoothstep(0.0, 0.12, t) * u_physics_blend;
		pos = mix(pos, u_head_center + off * k, push);
	}

	// ---- 展开阶段：相机朝向 ribbon ----
	vec3 to_cam = cam_pos - pos;
	float cam_d = max(length(to_cam), 1e-4);
	to_cam /= cam_d;
	vec3 c = cross(Tdir, to_cam);
	float cl = length(c);
	vec3 side_dir = cl > 1e-5 ? c / cl : B;
	float width = mix(width_root, width_tip, t);
	out_tan = Tdir;
	return pos + side_dir * (width * side);
}
