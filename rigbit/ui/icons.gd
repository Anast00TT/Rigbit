class_name RbIcons
extends RefCounted
## Иконки из SVG-строк, растеризуются под плотность экрана. Белые, цвет даёт тема.

static var scale := 1.0
static var _cache := {}

const P := {
	"undo": '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
	"redo": '<path d="m15 14 5-5-5-5"/><path d="M20 9H9.5a5.5 5.5 0 0 0 0 11H13"/>',
	"more": '<circle cx="5" cy="12" r="1.4" fill="#fff"/><circle cx="12" cy="12" r="1.4" fill="#fff"/><circle cx="19" cy="12" r="1.4" fill="#fff"/>',
	"bone": '<path d="M4.5 19.5 8.6 12.6 19.5 4.5 11.4 15.4Z"/><circle cx="4.5" cy="19.5" r="1.6"/>',
	"mesh": '<path d="M12 3.5 21 20H3Z"/><path d="M7.5 11.8h9M12 20l-4.5-8.2M12 20l4.5-8.2"/>',
	"move": '<path d="M12 3v18M3 12h18M12 3 9.5 5.5M12 3l2.5 2.5M12 21l-2.5-2.5M12 21l2.5-2.5M3 12l2.5-2.5M3 12l2.5 2.5M21 12l-2.5-2.5M21 12l-2.5 2.5"/>',
	"hand": '<path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V11"/><path d="M11 10.5V4a1.5 1.5 0 0 1 3 0v6.5"/><path d="M14 10.5V6a1.5 1.5 0 0 1 3 0v8a6 6 0 0 1-6 6h-.5a6 6 0 0 1-4.6-2.2L3.5 14.6a1.6 1.6 0 0 1 2.3-2.2L8 14.5"/>',
	"layers": '<path d="m12 3 9 5-9 5-9-5Z"/><path d="m3 13 9 5 9-5"/>',
	"play": '<path d="M7 4.5v15l13-7.5Z" fill="#fff" stroke="none"/>',
	"sliders": '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
	"folder": '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>',
	"import": '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
	"plus": '<path d="M12 5v14M5 12h14"/>',
	"x": '<path d="M6 6l12 12M18 6 6 18"/>',
	"fit": '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>',
	"gauge": '<path d="M4 18a9 9 0 1 1 16 0"/><path d="m12 13 4-5"/><circle cx="12" cy="13" r="1.3" fill="#fff"/>',
	"info": '<circle cx="12" cy="12" r="9"/><path d="M12 11v6"/><circle cx="12" cy="7.6" r="1" fill="#fff"/>',
	"frog": '<circle cx="8" cy="7" r="3"/><circle cx="16" cy="7" r="3"/><path d="M4 13c0-3 3.5-4.5 8-4.5s8 1.5 8 4.5-3 6-8 6-8-3-8-6Z"/><path d="M9.5 14.5q2.5 1.5 5 0"/>',
	"bulb": '<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.4 1 1.1 1 1.9V16h5v-.2c0-.8.4-1.5 1-1.9A6 6 0 0 0 12 3Z"/>',
	"dot": '<circle cx="12" cy="12" r="10" fill="#fff" stroke="none"/>',
	"brush": '<path d="m14.5 4.5 5 5L11 18l-5-5Z"/><path d="M6 13c-2 0-3 2-3 4.5V20h2.5C8 20 10 19 10 17"/>',
	"group":'<rect x="3" y="7" width="13" height="13" rx="2"/><path d="M7 4h11a2 2 0 0 1 2 2v11"/>',
	"folder_closed": '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/><path d="M8 13h8"/>',
	"eye": '<path d="M2 12s3.5-6.5 10-6.5S22 12 22 12s-3.5 6.5-10 6.5S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
	"eye_off": '<path d="M3 3l18 18"/><path d="M10.6 5.6A10 10 0 0 1 12 5.5c6.5 0 10 6.5 10 6.5a17 17 0 0 1-3 3.7M6.3 6.6C3.6 8.3 2 12 2 12s3.5 6.5 10 6.5c1.6 0 3-.4 4.3-1"/>',
	"pencil": '<path d="M4 20h4L19 9l-4-4L4 16Z"/><path d="m13.5 6.5 4 4"/>',
	"arrow_up": '<path d="M12 19V5"/><path d="m6 11 6-6 6 6"/>',
	"arrow_down": '<path d="M12 5v14"/><path d="m6 13 6 6 6-6"/>',
	"copy": '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
	"flip": '<path d="M12 3v18"/><path d="M9 7 3 17h6Z"/><path d="m15 7 6 10h-6Z"/>',
	"reset": '<path d="M4 12a8 8 0 1 0 2.3-5.7"/><path d="M4 4v5h5"/>',
	"trash": '<path d="M4 7h16"/><path d="M9 7V4h6v3"/><path d="M6 7l1 13h10l1-13"/>',
	"square": '<rect x="5" y="5" width="14" height="14" rx="1"/><path d="M5 5l14 14"/>',
	"back": '<path d="M15 5 8 12l7 7"/>',
	"gear": '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/>',
	"check": '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
	"refresh": '<path d="M20 12a8 8 0 1 1-2.5-5.8"/><path d="M20 4v5h-5"/>',
	"fwd": '<path d="m9 5 7 7-7 7"/>',
	"pause": '<rect x="6" y="5" width="4" height="14" rx="1" fill="#fff" stroke="none"/><rect x="14" y="5" width="4" height="14" rx="1" fill="#fff" stroke="none"/>',
	"loop": '<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>',
	"chevron_down": '<path d="m6 9 6 6 6-6"/>',
	"chevron_up": '<path d="m6 15 6-6 6 6"/>',
	"paste": '<rect x="8" y="3" width="8" height="4" rx="1"/><path d="M16 5h2a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2"/>',
	"curve": '<path d="M3 19c8 0 6-14 18-14"/><circle cx="3" cy="19" r="1.5"/><circle cx="21" cy="5" r="1.5"/>',
	"pin": '<path d="M9 3h6l-.8 6.5 3.3 3.5h-11l3.3-3.5Z"/><path d="M12 13v8"/>',
	"chain": '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
	"palette": '<path d="M12 3a9 9 0 1 0 0 18c1.2 0 2-.8 2-1.8 0-.5-.2-.9-.5-1.2-.3-.3-.5-.7-.5-1.2 0-1 .8-1.8 1.8-1.8H17a4 4 0 0 0 4-4c0-4.4-4-8-9-8Z"/><circle cx="7.5" cy="11" r="1" fill="#fff"/><circle cx="10" cy="7" r="1" fill="#fff"/><circle cx="15" cy="7" r="1" fill="#fff"/>',
	"fx": '<path d="m12 3 1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8Z"/><path d="M19 16v4M17 18h4"/>',
	"lock": '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
}

const FROG_SVG := '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 240" width="200" height="240"><ellipse cx="66" cy="226" rx="27" ry="9" fill="#68AE57"/><ellipse cx="134" cy="226" rx="27" ry="9" fill="#68AE57"/><ellipse cx="100" cy="182" rx="54" ry="46" fill="#7CC26A"/><ellipse cx="100" cy="192" rx="34" ry="28" fill="#EAF3CD"/><ellipse cx="56" cy="176" rx="11" ry="26" fill="#68AE57" transform="rotate(28 56 176)"/><ellipse cx="144" cy="176" rx="11" ry="26" fill="#68AE57" transform="rotate(-28 144 176)"/><circle cx="64" cy="52" r="26" fill="#7CC26A"/><circle cx="136" cy="52" r="26" fill="#7CC26A"/><ellipse cx="100" cy="98" rx="80" ry="56" fill="#7CC26A"/><circle cx="64" cy="52" r="18" fill="#fff"/><circle cx="136" cy="52" r="18" fill="#fff"/><circle cx="67" cy="55" r="8.5" fill="#1d1d22"/><circle cx="133" cy="55" r="8.5" fill="#1d1d22"/><circle cx="64" cy="51" r="3" fill="#fff"/><circle cx="130" cy="51" r="3" fill="#fff"/><ellipse cx="46" cy="112" rx="12" ry="6" fill="#FF9BB0" opacity=".75"/><ellipse cx="154" cy="112" rx="12" ry="6" fill="#FF9BB0" opacity=".75"/><path d="M84 116 Q100 131 116 116" stroke="#2d4d24" stroke-width="3.5" fill="none" stroke-linecap="round"/></svg>'


## Иконка размером size_dp (в единицах интерфейса).
static func tex(icon_name: String, size_dp := 24.0) -> Texture2D:
	var px := maxi(8, ceili(size_dp * scale * 1.5))
	var key := "%s@%d" % [icon_name, px]
	if _cache.has(key):
		return _cache[key]
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">%s</svg>' % P.get(icon_name, "")
	var img := Image.new()
	img.load_svg_from_string(svg, px / 24.0)
	var t := ImageTexture.create_from_image(img)
	t.set_size_override(Vector2(size_dp, size_dp))  # картинка чёткая, а размер в dp
	_cache[key] = t
	return t


static func _svg_tex(key: String, svg: String, size_dp: Vector2) -> Texture2D:
	if _cache.has(key):
		return _cache[key]
	var img := Image.new()
	img.load_svg_from_string(svg, scale * 1.5)
	var t := ImageTexture.create_from_image(img)
	t.set_size_override(size_dp)
	_cache[key] = t
	return t


## Ручка ползунка: белый круг с лёгкой тенью.
static func knob() -> Texture2D:
	return _svg_tex("knob", '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12.8" r="9.5" fill="#000" fill-opacity=".35"/><circle cx="12" cy="12" r="9" fill="#ffffff"/></svg>', Vector2(24, 24))


## Переключатель вкл/выкл.
static func switch(on: bool) -> Texture2D:
	var c: Color = RbTheme.C.acc if on else RbTheme.C.p3
	var bg := c.to_html(false)
	var x := 30 if on else 14
	return _svg_tex("switch_%s_%s" % [on, bg], '<svg xmlns="http://www.w3.org/2000/svg" width="44" height="28"><rect x="1" y="3" width="42" height="22" rx="11" fill="#%s"/><circle cx="%d" cy="14" r="8" fill="#ffffff"/></svg>' % [bg, x], Vector2(44, 28))


## Цветная лягушка (заглушка-персонаж и картинка в пустом проекте).
static func frog_image(width_px: int) -> Image:
	var img := Image.new()
	img.load_svg_from_string(FROG_SVG, width_px / 200.0)
	return img
