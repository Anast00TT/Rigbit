shader_type canvas_item;
// Маска-обрезка: слой виден только там, где непрозрачна текстура маски (другого слоя) в её
// текущей позе. Ничего не запекается: зрачок двигается внутри склеры, край всегда по склере.
// mask_x/mask_y/mask_o: аффинное преобразование из локальных координат этого слоя
// в локальные координаты маски (считается на CPU каждый кадр). Деформация сетки маски
// (скиннинг, пины) не учитывается: маска считается жёсткой в своих осях.

uniform sampler2D mask_tex : filter_linear_mipmap;
uniform vec2 mask_x = vec2(1.0, 0.0);
uniform vec2 mask_y = vec2(0.0, 1.0);
uniform vec2 mask_o = vec2(0.0);
uniform vec2 mask_size = vec2(1.0);

varying vec2 mpos;

void vertex() {
	mpos = mask_x * VERTEX.x + mask_y * VERTEX.y + mask_o;
}

void fragment() {
	vec2 uv = mpos / mask_size + 0.5;
	float inside = step(0.0, uv.x) * step(0.0, uv.y) * step(uv.x, 1.0) * step(uv.y, 1.0);
	vec4 c = texture(TEXTURE, UV) * COLOR;
	c.a *= texture(mask_tex, clamp(uv, 0.0, 1.0)).a * inside;
	COLOR = c;
}
