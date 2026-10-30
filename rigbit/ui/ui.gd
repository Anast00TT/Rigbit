class_name RbUi
extends RefCounted
## Кирпичики интерфейса. Размеры зон касания не меньше 44 dp, зазоры по сетке 4/8.


static func margins(l: int, t: int, r: int, b: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	return m


static func hbox(sep := 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func vbox(sep := 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func icon_btn(icon: String, cb: Callable, w := 44, h := 48) -> Button:
	var b := Button.new()
	b.icon = RbIcons.tex(icon)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.custom_minimum_size = Vector2(w, h)
	b.focus_mode = Control.FOCUS_NONE
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func text_btn(variation: String, icon: String, key: String, cb: Callable, h := 44) -> Button:
	var b := Button.new()
	b.theme_type_variation = variation
	if icon != "":
		b.icon = RbIcons.tex(icon)
	b.text = key
	b.custom_minimum_size.y = h
	b.focus_mode = Control.FOCUS_NONE
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func label(text: String, variation := "") -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	return l


static func expand(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## Строка «подпись — ползунок — значение». on_change(value, finished)
static func slider_row(key: String, min_v: float, max_v: float, value: float, fmt: Callable, on_change: Callable) -> HBoxContainer:
	var row := hbox(12)
	row.custom_minimum_size.y = 48
	var l := label(key, "LabelDim")
	l.custom_minimum_size.x = 104
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = 0.0
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size.y = 44
	s.focus_mode = Control.FOCUS_NONE
	row.add_child(s)
	var out := PanelContainer.new()
	out.theme_type_variation = "Seg"
	out.custom_minimum_size = Vector2(56, 32)
	out.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var vl := label(fmt.call(value))
	vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vl.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	out.add_child(vl)
	row.add_child(out)
	s.value_changed.connect(func(v: float) -> void:
		vl.text = fmt.call(v)
		on_change.call(v, false))
	s.drag_ended.connect(func(_c: bool) -> void: on_change.call(s.value, true))
	row.set_meta("slider", s)
	return row


## Ползунок с подписью и значением сверху, ползунок на всю ширину под ними (узкие панели).
## on_change(value, finished). Ползунок и подпись значения лежат в meta "slider" и "value_label".
## label_is_key: подпись это ключ перевода (иначе готовый текст, например имя параметра).
static func slider2(key: String, min_v: float, max_v: float, value: float, fmt: Callable, on_change: Callable, label_is_key := true) -> VBoxContainer:
	var col := vbox(0)
	var top := hbox(8)
	top.custom_minimum_size.y = 24
	col.add_child(top)
	var l := label(key, "LabelDim")
	if not label_is_key:
		l.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top.add_child(l)
	var out := PanelContainer.new()
	out.theme_type_variation = "Seg"
	out.custom_minimum_size = Vector2(56, 28)
	var vl := label(fmt.call(value))
	vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vl.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	out.add_child(vl)
	top.add_child(out)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = 0.0
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size.y = 44
	s.focus_mode = Control.FOCUS_NONE
	col.add_child(s)
	s.value_changed.connect(func(v: float) -> void:
		vl.text = fmt.call(v)
		on_change.call(v, false))
	s.drag_ended.connect(func(_c: bool) -> void: on_change.call(s.value, true))
	col.set_meta("slider", s)
	col.set_meta("value_label", vl)
	col.set_meta("fmt", fmt)
	return col


## Поставить значение ползунка из slider2 без сигнала (синхронизация после undo и т.п.).
static func set_slider2(row: Control, v: float) -> void:
	var s: HSlider = row.get_meta("slider")
	if absf(s.value - v) < 0.00001:
		return
	s.set_value_no_signal(v)
	(row.get_meta("value_label") as Label).text = (row.get_meta("fmt") as Callable).call(v)


## Число для подписи: два знака, без хвостовых нулей ("1.0", "0.25", "-0.5").
static func num(v: float) -> String:
	var s := "%.2f" % v
	s = s.rstrip("0")
	if s.ends_with("."):
		s += "0"
	return s


## Равны ли два словаря настроек (по содержимому, порядок ключей не важен).
static func same_dict(a: Dictionary, b: Dictionary) -> bool:
	return JSON.stringify(a, "", true) == JSON.stringify(b, "", true)


## Подпись раздела (мелкая, приглушённая).
static func section(key: String) -> Label:
	var l := label(key, "LabelFaint")
	l.custom_minimum_size.y = 20
	return l


## Ряд цветных плашек 44x44 (палитра). colors: html-строки; on_pick(html).
static func swatches(colors: Array, selected: String, on_pick: Callable) -> HFlowContainer:
	var fl := HFlowContainer.new()
	fl.add_theme_constant_override("h_separation", 8)
	fl.add_theme_constant_override("v_separation", 8)
	for c in colors:
		var hex: String = c
		var b := Button.new()
		b.custom_minimum_size = Vector2(44, 44)
		b.focus_mode = Control.FOCUS_NONE
		var on := hex.to_lower() == selected.to_lower()
		var col := Color.html(hex)
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			b.add_theme_stylebox_override(st, RbTheme.sb(col, 22, 0.0, 0.0, Color.WHITE if on else RbTheme.C.p3, 3 if on else 1))
		b.pressed.connect(func() -> void: on_pick.call(hex))
		fl.add_child(b)
	return fl


## Сегменты (вкладки-переключатели). Возвращает панель; on_pick(index).
static func segments(keys: Array, selected: int, on_pick: Callable, h := 40) -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "Seg"
	var row := hbox(2)
	p.add_child(row)
	var group := ButtonGroup.new()
	for i in keys.size():
		var b := Button.new()
		b.theme_type_variation = "SegButton"
		b.toggle_mode = true
		b.button_group = group
		b.text = keys[i]
		b.custom_minimum_size.y = h
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		b.button_pressed = i == selected
		b.pressed.connect(on_pick.bind(i))
		row.add_child(b)
	return p


## Строка-переключатель «текст ... [тумблер]».
static func switch_row(key: String, value: bool, on_toggle: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = key
	c.button_pressed = value
	c.custom_minimum_size.y = 52
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(on_toggle)
	return c


static func hline() -> ColorRect:
	var c := ColorRect.new()
	c.color = RbTheme.C.ln
	c.custom_minimum_size.y = 1
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## Миниатюра картинки, вписанная в квадрат size dp.
static func thumb(img: Image, size := 32) -> Control:
	var p := PanelContainer.new()
	var box := RbTheme.sb(Color("#F2F0EA"), 5)
	p.add_theme_stylebox_override("panel", box)
	p.custom_minimum_size = Vector2(size, size)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if img:
		var small := img.duplicate()
		var k := float(size * RbIcons.scale * 1.5) / maxf(small.get_width(), small.get_height())
		if k < 1.0:
			small.resize(maxi(1, int(small.get_width() * k)), maxi(1, int(small.get_height() * k)), Image.INTERPOLATE_BILINEAR)
		var tr := TextureRect.new()
		tr.texture = ImageTexture.create_from_image(small)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(tr)
	return p
