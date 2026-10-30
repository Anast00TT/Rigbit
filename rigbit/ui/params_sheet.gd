class_name RbParamsSheet
extends RbPanel
## Панель параметров: у каждого ползунок в диапазоне параметра и меню «…».

signal value_changed(id: int, v: float, done: bool)
signal add_requested
signal menu_requested(id: int, anchor: Control)

var doc: RbDocument
var hint_key := ""  # что делает перетаскивание в текущем режиме

var more_buttons := {}  # id -> кнопка «…» (меню опирается на неё)
var _rows := {}  # id -> {slider, label}


func _init() -> void:
	super("PARAMS_TITLE")
	add_head_button("plus", func() -> void: add_requested.emit())


func rebuild(d: RbDocument = null) -> void:
	if d:
		doc = d
	if doc == null:
		return
	begin_rebuild()
	_rows.clear()
	more_buttons.clear()
	if hint_key != "":
		var h := RbUi.label(hint_key, "LabelFaint")
		h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(h)
	if doc.params.params.is_empty():
		var e := RbUi.label("PARAMS_EMPTY", "LabelDim")
		e.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(e)
		body.add_child(RbUi.text_btn("PrimaryButton", "plus", "PARAM_NEW", func() -> void: add_requested.emit(), 48))
	for p: RbParams.Param in doc.params.params.values():
		body.add_child(_card(p))
	end_rebuild()


func _is_driven(id: int) -> bool:
	for q: RbParams.Param in doc.params.params.values():
		for d in q.drivers:
			if int(d["target"]) == id:
				return true
	return false


func _card(p: RbParams.Param) -> Control:
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	var v := RbUi.vbox(0)
	card.add_child(v)
	var top := RbUi.hbox(4)
	v.add_child(top)
	var names := RbUi.vbox(0)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_child(names)
	var nm := RbUi.label(p.name, "LabelTitle")
	nm.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	names.add_child(nm)
	var driven := _is_driven(p.id)
	if driven:
		names.add_child(RbUi.label("PARAM_DRIVEN", "LabelFaint"))
	var more := RbUi.icon_btn("more", Callable(), 44, 44)
	more.pressed.connect(func() -> void: menu_requested.emit(p.id, more))
	top.add_child(more)
	more_buttons[p.id] = more
	var row := RbUi.hbox(8)
	row.custom_minimum_size.y = 44
	v.add_child(row)
	var s := HSlider.new()
	s.min_value = p.min_v
	s.max_value = p.max_v
	s.step = 0.0
	s.value = clampf(p.value, p.min_v, p.max_v)
	s.editable = not driven
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size.y = 44
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	row.add_child(s)
	var out := PanelContainer.new()
	out.theme_type_variation = "Seg"
	out.custom_minimum_size = Vector2(56, 28)
	out.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var vl := RbUi.label(RbUi.num(s.value))
	vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vl.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	out.add_child(vl)
	row.add_child(out)
	var id := p.id
	s.value_changed.connect(func(x: float) -> void:
		vl.text = RbUi.num(x)
		value_changed.emit(id, x, false))
	s.drag_ended.connect(func(_c: bool) -> void: value_changed.emit(id, s.value, true))
	_rows[id] = {"slider": s, "label": vl}
	return card


## Показать текущие значения параметров (после undo, смены кадра, драйверов), не трогая сигналы.
func sync_values() -> void:
	if doc == null:
		return
	for id in _rows:
		var p := doc.params.get_param(id)
		if p == null:
			continue
		var s: HSlider = _rows[id]["slider"]
		var x := clampf(p.value, p.min_v, p.max_v)
		if absf(s.value - x) > 0.00001:
			s.set_value_no_signal(x)
			(_rows[id]["label"] as Label).text = RbUi.num(x)
