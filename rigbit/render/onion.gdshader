shader_type canvas_item;
// Призрак онион скина: силуэт слоя плоским цветом, альфа = альфа текстуры * tint.a.
uniform vec4 tint : source_color = vec4(1.0, 0.35, 0.37, 0.38);

void fragment() {
	COLOR = vec4(tint.rgb, texture(TEXTURE, UV).a * tint.a);
}
