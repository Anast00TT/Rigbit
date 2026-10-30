shader_type canvas_item;
// Эффекты слоя за один проход по его же текстуре (без отдельного буфера на слой).
//  Край: внутри = рим-лайт / внутренняя тень со стороны света, снаружи = обводка / свечение
//        (снаружи рисуется в пределах сетки слоя: у автосетки это отступ от силуэта).
//  Градиентный свет: цветной градиент по силуэту.
//  Цветокор: тон, насыщенность, яркость, контраст.
// Свет задаётся в мировых координатах: light_dir_local пересчитывается на CPU из мирового угла
// и поворота слоя, поэтому свет не крутится вместе с персонажем.

uniform bool rim_on = false;
uniform bool rim_outside = false;
uniform vec2 light_dir_local = vec2(1.0, 0.0); // единичный вектор К свету, в осях слоя
uniform float rim_distance = 8.0; // пиксели текстуры
uniform float rim_blur = 4.0;
uniform float rim_hardness = 0.5; // 0 мягко .. 1 жёстко
uniform vec4 rim_color : source_color = vec4(1.0, 0.9, 0.7, 1.0);
uniform float rim_opacity = 1.0;
uniform int rim_blend = 0; // 0 add, 1 screen, 2 mix, 3 multiply

uniform bool grad_on = false;
uniform vec4 grad_a : source_color = vec4(1.0, 0.6, 0.8, 1.0);
uniform vec4 grad_b : source_color = vec4(0.4, 0.6, 1.0, 1.0);
uniform vec2 grad_dir_local = vec2(0.0, 1.0);
uniform float grad_amount = 0.3;
uniform int grad_blend = 1;

uniform bool cc_on = false;
uniform float cc_hue = 0.0; // -0.5..0.5 оборота
uniform float cc_saturation = 1.0;
uniform float cc_brightness = 0.0;
uniform float cc_contrast = 1.0;

varying vec4 vcol;

void vertex() {
	vcol = COLOR; // цвет вершины и модуляция (прозрачность слоя), без текстуры
}

vec3 blend_rgb(vec3 base, vec3 over, float a, int mode) {
	vec3 r;
	if (mode == 0) r = base + over;
	else if (mode == 1) r = 1.0 - (1.0 - base) * (1.0 - over);
	else if (mode == 3) r = base * over;
	else r = over;
	return mix(base, clamp(r, 0.0, 1.0), clamp(a, 0.0, 1.0));
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

// Размытая альфа в точке: 8 отсчётов по кругу + центр.
float soft_alpha(sampler2D tex, vec2 uv, vec2 px, float r) {
	float s = texture(tex, uv).a;
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.785398;
		s += texture(tex, uv + vec2(cos(a), sin(a)) * r * px).a;
	}
	return s / 9.0;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec2 px = TEXTURE_PIXEL_SIZE;
	if (cc_on) {
		vec3 hsv = rgb2hsv(c.rgb);
		hsv.x = fract(hsv.x + cc_hue);
		hsv.y = clamp(hsv.y * cc_saturation, 0.0, 1.0);
		vec3 rgb = hsv2rgb(hsv);
		rgb = (rgb - 0.5) * cc_contrast + 0.5 + cc_brightness;
		c.rgb = clamp(rgb, 0.0, 1.0);
	}
	if (grad_on) {
		float g = clamp(dot(UV - 0.5, normalize(grad_dir_local)) + 0.5, 0.0, 1.0);
		vec4 gc = mix(grad_a, grad_b, g);
		c.rgb = blend_rgb(c.rgb, gc.rgb, grad_amount * gc.a, grad_blend);
	}
	if (rim_on) {
		vec2 off = light_dir_local * rim_distance * px;
		float hard = mix(0.45, 0.02, rim_hardness);
		if (!rim_outside) {
			// внутри: пиксель силуэта, у которого в сторону света за rim_distance уже пусто
			float toward = soft_alpha(TEXTURE, UV + off, px, rim_blur);
			float rim = c.a * smoothstep(0.5 - hard, 0.5 + hard, 1.0 - toward);
			c.rgb = blend_rgb(c.rgb, rim_color.rgb, rim * rim_opacity * rim_color.a, rim_blend);
		} else {
			// снаружи: пусто здесь, но рядом есть силуэт (сдвиг по свету даёт свечение с одной стороны)
			float near = soft_alpha(TEXTURE, UV - off * 0.5, px, rim_distance * 0.5 + rim_blur);
			float glow = (1.0 - c.a) * smoothstep(0.5 - hard - 0.4, 0.5 + hard, near * 2.0);
			float ga = glow * rim_opacity * rim_color.a;
			c = vec4(mix(c.rgb, rim_color.rgb, ga / max(c.a + ga, 1e-4)), clamp(c.a + ga, 0.0, 1.0));
		}
	}
	COLOR = c * vcol;
}
