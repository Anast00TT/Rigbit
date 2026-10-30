class_name RbTheme
extends RefCounted
## Стиль «Студия». Все цвета и размеры только отсюда, чтобы тему можно было сменить одной правкой.

const MODE_COLORS := [Color("#E9A23B"), Color("#E5484D"), Color("#8E7CC3"), Color("#46A758")]

static var C: Dictionary = DARK.duplicate()

static var theme: Theme

const DARK := {
	"bg": Color("#161616"), "p1": Color("#262626"), "p2": Color("#2B2B2B"), "p3": Color("#3A3A3A"),
	"seg": Color("#1C1C1C"), "vp": Color("#1E1E1E"), "ln": Color("#111111"),
	"tx": Color("#E8E8E8"), "tx2": Color("#9E9E9E"), "tx3": Color("#666666"),
	"acc": Color("#3D8BFD"), "tip": Color(0.078, 0.078, 0.078, 0.95), "tip_border": Color("#333333"),
	"canvas_shadow": Color(0, 0, 0, 0.4), "sel_row": Color("#33302A"), "danger": Color("#E5484D"),
}
const LIGHT := {
	"bg": Color("#E9E9EB"), "p1": Color("#FAFAFA"), "p2": Color("#EFEFF1"), "p3": Color("#E0E0E3"),
	"seg": Color("#E6E6E9"), "vp": Color("#D9D9DD"), "ln": Color("#D0D0D4"),
	"tx": Color("#1C1C1E"), "tx2": Color("#5C5C62"), "tx3": Color("#9A9AA0"),
	"acc": Color("#2F7BF0"), "tip": Color(1, 1, 1, 0.97), "tip_border": Color("#D0D0D4"),
	"canvas_shadow": Color(0, 0, 0, 0.18), "sel_row": Color("#F3E6CF"), "danger": Color("#D93F44"),
}


## dark / light / system
static func use_palette(name: String) -> void:
	var dark := name != "light"
	if name == "system":
		dark = DisplayServer.is_dark_mode() if DisplayServer.is_dark_mode_supported() else true
	C = (DARK if dark else LIGHT).duplicate()
	RenderingServer.set_default_clear_color(C.bg)


static func sb(color: Color, radius := 0, pad_h := 0.0, pad_v := 0.0, border := Color.TRANSPARENT, border_w := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	if border_w > 0:
		s.border_color = border
		s.set_border_width_all(border_w)
	s.anti_aliasing = true
	return s


static func empty(pad_h := 8.0, pad_v := 4.0) -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	return s


static func build() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Roboto", "Noto Sans", "Segoe UI", "sans-serif"])
	font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	var font_medium := SystemFont.new()
	font_medium.font_names = font.font_names
	font_medium.font_weight = 500
	t.default_font = font
	t.default_font_size = 14

	# --- Button: плоская иконка-кнопка
	_button(t, "Button", empty(), sb(C.p3, 8, 8, 4), sb(C.p3, 8, 8, 4))
	t.set_constant("icon_max_width", "Button", 22)
	t.set_constant("h_separation", "Button", 8)

	# --- основная кнопка (акцент)
	t.set_type_variation("PrimaryButton", "Button")
	_button(t, "PrimaryButton", sb(C.acc, 8, 16, 8), sb(C.acc.lightened(0.1), 8, 16, 8), sb(C.acc.darkened(0.15), 8, 16, 8))
	t.set_stylebox("disabled", "PrimaryButton", sb(C.p3, 8, 16, 8))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(k, "PrimaryButton", Color.WHITE)
	t.set_font("font", "PrimaryButton", font_medium)
	t.set_font_size("font_size", "PrimaryButton", 15)
	t.set_constant("icon_max_width", "PrimaryButton", 20)

	# --- вторичная
	t.set_type_variation("SecondaryButton", "Button")
	_button(t, "SecondaryButton", sb(C.p2, 8, 16, 8), sb(C.p3, 8, 16, 8), sb(C.p3, 8, 16, 8))
	t.set_constant("icon_max_width", "SecondaryButton", 18)

	# --- сегменты режимов
	t.set_type_variation("SegButton", "Button")
	_button(t, "SegButton", empty(6, 4), sb(C.p2, 6, 6, 4), sb(C.p3, 6, 6, 4))
	t.set_stylebox("hover_pressed", "SegButton", sb(C.p3, 6, 6, 4))
	t.set_color("font_color", "SegButton", C.tx2)
	t.set_color("font_hover_color", "SegButton", C.tx)
	t.set_font("font", "SegButton", font_medium)
	t.set_font_size("font_size", "SegButton", 14)
	t.set_constant("icon_max_width", "SegButton", 8)
	t.set_constant("h_separation", "SegButton", 7)

	# --- инструменты справа: иконка над подписью
	t.set_type_variation("ToolButton", "Button")
	_button(t, "ToolButton", empty(2, 4), sb(C.p2, 6, 2, 4), sb(C.p3, 6, 2, 4))
	t.set_stylebox("hover_pressed", "ToolButton", sb(C.p3, 6, 2, 4))
	t.set_color("font_color", "ToolButton", C.tx2)
	t.set_font_size("font_size", "ToolButton", 10)
	t.set_constant("h_separation", "ToolButton", 4)

	# --- пункт меню
	t.set_type_variation("MenuItem", "Button")
	_button(t, "MenuItem", empty(12, 4), sb(C.p3, 6, 12, 4), sb(C.p3, 6, 12, 4))
	t.set_constant("icon_max_width", "MenuItem", 20)
	t.set_constant("h_separation", "MenuItem", 12)
	t.set_font_size("font_size", "MenuItem", 15)

	# --- панели
	t.set_stylebox("panel", "PanelContainer", sb(C.p1))
	_panel(t, "Bar", sb(C.p1))
	var bar_line := sb(C.p1)
	bar_line.border_color = C.ln
	bar_line.border_width_bottom = 1
	_panel(t, "BarLine", bar_line)
	_panel(t, "Seg", sb(C.seg, 8, 3, 3))
	_panel(t, "Rail", sb(C.p1, 6, 4, 5))
	var menu := sb(C.p1, 10, 6, 6, C.p3, 1)
	menu.shadow_color = Color(0, 0, 0, 0.45)
	menu.shadow_size = 16
	_panel(t, "Menu", menu)
	_panel(t, "Tip", sb(C.tip, 8, 12, 8, C.tip_border, 1))
	_panel(t, "Toast", sb(Color(0.1, 0.1, 0.1, 0.95), 8, 14, 9, C.p3, 1))
	_panel(t, "Badge", sb(Color("#252525"), 14, 8, 8))

	# --- подписи
	t.set_color("font_color", "Label", C.tx)
	t.set_type_variation("LabelDim", "Label")
	t.set_color("font_color", "LabelDim", C.tx2)
	t.set_type_variation("LabelFaint", "Label")
	t.set_color("font_color", "LabelFaint", C.tx3)
	t.set_font_size("font_size", "LabelFaint", 12)
	t.set_type_variation("LabelTitle", "Label")
	t.set_font("font", "LabelTitle", font_medium)
	t.set_font_size("font_size", "LabelTitle", 16)

	# --- ползунок: тонкая дорожка, белая ручка
	var track := sb(C.p3, 2)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	var fill := sb(C.acc, 2)
	fill.content_margin_top = 2
	fill.content_margin_bottom = 2
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	var knob := RbIcons.knob()
	t.set_icon("grabber", "HSlider", knob)
	t.set_icon("grabber_highlight", "HSlider", knob)
	t.set_icon("grabber_disabled", "HSlider", knob)
	t.set_stylebox("focus", "HSlider", StyleBoxEmpty.new())

	# --- переключатель
	t.set_icon("checked", "CheckButton", RbIcons.switch(true))
	t.set_icon("unchecked", "CheckButton", RbIcons.switch(false))
	t.set_icon("checked_disabled", "CheckButton", RbIcons.switch(true))
	t.set_icon("unchecked_disabled", "CheckButton", RbIcons.switch(false))
	_button(t, "CheckButton", empty(0, 4), empty(0, 4), empty(0, 4))
	t.set_font_size("font_size", "CheckButton", 15)

	# --- строка ввода
	t.set_stylebox("normal", "LineEdit", sb(C.seg, 8, 12, 8))
	t.set_stylebox("focus", "LineEdit", sb(C.seg, 8, 12, 8, C.acc, 1))
	t.set_color("font_color", "LineEdit", C.tx)
	t.set_color("caret_color", "LineEdit", C.acc)
	t.set_color("selection_color", "LineEdit", Color(C.acc, 0.35))
	t.set_font_size("font_size", "LineEdit", 15)

	# --- строки списков
	t.set_type_variation("RowButton", "Button")
	_button(t, "RowButton", empty(8, 2), sb(C.p2, 6, 8, 2), sb(C.p3, 6, 8, 2))
	t.set_stylebox("pressed", "RowButton", sb(C.sel_row, 6, 8, 2))
	t.set_stylebox("hover_pressed", "RowButton", sb(C.sel_row, 6, 8, 2))
	t.set_constant("icon_max_width", "RowButton", 20)
	t.set_font_size("font_size", "RowButton", 14)
	t.set_type_variation("DangerButton", "Button")
	_button(t, "DangerButton", sb(C.p2, 8, 12, 8), sb(C.p3, 8, 12, 8), sb(C.p3, 8, 12, 8))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		t.set_color(k, "DangerButton", C.danger)
	t.set_constant("icon_max_width", "DangerButton", 18)
	_panel(t, "Sheet", sb(C.p1, 0, 0, 0))
	_panel(t, "Card", sb(C.p2, 8, 12, 4))

	var sc := sb(C.p3, 3)
	sc.content_margin_left = 3
	sc.content_margin_right = 3
	t.set_stylebox("grabber", "VScrollBar", sc)
	t.set_stylebox("scroll", "VScrollBar", empty(3, 0))

	theme = t
	set_mode_color(MODE_COLORS[0])
	return t


static func _button(t: Theme, type: String, normal: StyleBox, hover: StyleBox, pressed: StyleBox) -> void:
	t.set_stylebox("normal", type, normal)
	t.set_stylebox("hover", type, hover)
	t.set_stylebox("pressed", type, pressed)
	t.set_stylebox("hover_pressed", type, pressed)
	t.set_stylebox("disabled", type, normal.duplicate() if normal is StyleBoxEmpty else empty())
	t.set_stylebox("focus", type, StyleBoxEmpty.new())
	t.set_color("font_color", type, C.tx)
	t.set_color("font_hover_color", type, C.tx)
	t.set_color("font_pressed_color", type, C.tx)
	t.set_color("font_hover_pressed_color", type, C.tx)
	t.set_color("font_focus_color", type, C.tx)
	t.set_color("font_disabled_color", type, C.tx3)
	t.set_color("icon_normal_color", type, C.tx)
	t.set_color("icon_hover_color", type, C.tx)
	t.set_color("icon_pressed_color", type, C.tx)
	t.set_color("icon_hover_pressed_color", type, C.tx)
	t.set_color("icon_focus_color", type, C.tx)
	t.set_color("icon_disabled_color", type, C.tx3)


static func _panel(t: Theme, type: String, box: StyleBox) -> void:
	t.set_type_variation(type, "PanelContainer")
	t.set_stylebox("panel", type, box)


## Цвет режима: точка активного сегмента и иконка активного инструмента.
static func set_mode_color(c: Color) -> void:
	for k in ["icon_pressed_color", "icon_hover_pressed_color"]:
		theme.set_color(k, "ToolButton", c)
	# активный режим: плашка, подкрашенная цветом режима, с тонкой обводкой
	var on := sb(C.p3.lerp(c, 0.26), 6, 6, 4, Color(c, 0.6), 1)
	theme.set_stylebox("pressed", "SegButton", on)
	theme.set_stylebox("hover_pressed", "SegButton", on)
	theme.set_color("icon_normal_color", "ToolButton", C.tx2)
	theme.set_color("icon_hover_color", "ToolButton", C.tx)
