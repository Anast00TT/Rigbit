class_name RbFxSheet
extends RbPanel
## Эффекты слоя (режим Композинг): край (рим-лайт или обводка), градиентный свет, цветокор.
## Лист держит рабочую копию словаря effects и шлёт его целиком; команду и склейку жеста делает главный экран.
## Угол света двигает стрелка во вьюпорте, главный экран зовёт set_rim_angle.

signal changed(fx: Dictionary, done: bool)
signal blend_requested(anchor: Control)

const PALETTE := ["fff2cc", "ffffff", "ffd166", "ff7a59", "ff5fa2", "a78bfa", "5ec8ff", "1a1a1a"]
const BLENDS := ["add", "screen", "normal", "multiply"]
const DEFAULT_RIM := {"outside": false, "angle": -PI / 4.0, "distance": 8.0, "blur": 4.0,
	"hardness": 0.35, "color": "fff2cc", "opacity": 0.75, "blend": "add"}
const DEFAULT_GRAD := {"a": "ff99cc", "b": "6699ff", "angle": PI / 2.0, "amount": 0.3, "blend": "screen"}
const DEFAULT_CC := {"hue": 0.0, "saturation": 1.0, "brightness": 0.0, "contrast": 1.0}

var doc: RbDocument
var layer_id := 0

var _e := {}  # рабочая копия effects
var _angle_val: Label


func _init() -> void:
	super("FX_TITLE")


func show_layer(d: RbDocument, id: int) -> void:
	doc = d
	layer_id = id
	var l := doc.get_layer(id)
	_e = l.effects.duplicate(true) if l else {}
	rebuild()


## После undo и правок снаружи: перестроить, только если словарь реально изменился.
func sync() -> void:
	var l := doc.get_layer(layer_id) if doc else null
	if l and not RbUi.same_dict(_e, l.effects):
		_e = l.effects.duplicate(true)
		rebuild()


func has_rim() -> bool:
	return _e.has("rim")


func rim_angle() -> float:
	return float((_e.get("rim", {}) as Dictionary).get("angle", -PI / 4.0))


## Угол света из стрелки во вьюпорте (мировой, радианы).
func set_rim_angle(a: float, done: bool) -> void:
	if not _e.has("rim"):
		return
	(_e["rim"] as Dictionary)["angle"] = a
	if _angle_val:
		_angle_val.text = "%d°" % roundi(rad_to_deg(a))
	_emit(done)


func set_blend(mode: String) -> void:
	if _e.has("rim"):
		(_e["rim"] as Dictionary)["blend"] = mode
		_emit(true)
		rebuild()


func rim_blend() -> String:
	return str((_e.get("rim", {}) as Dictionary).get("blend", "add"))


func _emit(done: bool) -> void:
	changed.emit(_e.duplicate(true), done)


func rebuild() -> void:
	var l := doc.get_layer(layer_id) if doc else null
	if l == null:
		return
	set_sub(l.name)
	_angle_val = null
	begin_rebuild()
	_build_rim()
	body.add_child(RbUi.hline())
	_build_grad()
	body.add_child(RbUi.hline())
	_build_cc()
	end_rebuild()


func _toggle(key: String, sect: String, defaults: Dictionary) -> void:
	body.add_child(RbUi.switch_row(key, _e.has(sect), func(on: bool) -> void:
		if on:
			_e[sect] = defaults.duplicate(true)
		else:
			_e.erase(sect)
		_emit(true)
		rebuild()))


func _pct(v: float) -> String:
	return "%d%%" % roundi(v * 100.0)


func _deg(v: float) -> String:
	return "%d°" % roundi(v)


func _num0(v: float) -> String:
	return "%d" % roundi(v)


## Слайдер числового поля словаря sect[key].
func _slider(label_key: String, sect: String, key: String, lo: float, hi: float, fmt: Callable, scale := 1.0) -> void:
	var d: Dictionary = _e[sect]
	body.add_child(RbUi.slider2(label_key, lo, hi, float(d.get(key, 0.0)) * scale, fmt,
		func(v: float, done: bool) -> void:
			(_e[sect] as Dictionary)[key] = v / scale
			_emit(done)))


func _palette(label_key: String, sect: String, key: String) -> void:
	body.add_child(RbUi.section(label_key))
	var cur := str((_e[sect] as Dictionary).get(key, ""))
	body.add_child(RbUi.swatches(PALETTE, cur, func(hex: String) -> void:
		(_e[sect] as Dictionary)[key] = hex
		_emit(true)
		rebuild()))


func _build_rim() -> void:
	_toggle("FX_EDGE", "rim", DEFAULT_RIM)
	if not _e.has("rim"):
		return
	var rim: Dictionary = _e["rim"]
	var pick_side := func(i: int) -> void:
		(_e["rim"] as Dictionary)["outside"] = i == 1
		_emit(true)
	body.add_child(RbUi.segments(["FX_INSIDE", "FX_OUTSIDE"], 1 if bool(rim.get("outside", false)) else 0, pick_side, 44))
	var row := RbUi.hbox(8)
	row.custom_minimum_size.y = 36
	var al := RbUi.label("FX_ANGLE", "LabelDim")
	al.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	al.clip_text = true
	al.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(al)
	var pill := PanelContainer.new()
	pill.theme_type_variation = "Seg"
	pill.custom_minimum_size = Vector2(56, 28)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_angle_val = RbUi.label("%d°" % roundi(rad_to_deg(rim_angle())))
	_angle_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_angle_val.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	pill.add_child(_angle_val)
	row.add_child(pill)
	body.add_child(row)
	var hint := RbUi.label("FX_ANGLE_HINT", "LabelFaint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	_slider("FX_DIST", "rim", "distance", 0.0, 40.0, _num0)
	_slider("FX_BLUR", "rim", "blur", 0.0, 40.0, _num0)
	_slider("FX_HARD", "rim", "hardness", 0.0, 1.0, _pct)
	_slider("PROP_OPACITY", "rim", "opacity", 0.0, 1.0, _pct)
	_palette("FX_COLOR", "rim", "color")
	var br := RbUi.hbox(12)
	br.custom_minimum_size.y = 48
	var bl := RbUi.label("PROP_BLEND", "LabelDim")
	bl.custom_minimum_size.x = 96
	br.add_child(bl)
	var bb := RbUi.text_btn("SecondaryButton", "", "BLEND_" + rim_blend().to_upper(), func() -> void: pass, 44)
	bb.pressed.connect(func() -> void: blend_requested.emit(bb))
	bb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	br.add_child(bb)
	body.add_child(br)


func _build_grad() -> void:
	_toggle("FX_GRAD", "grad", DEFAULT_GRAD)
	if not _e.has("grad"):
		return
	_palette("FX_COLOR_A", "grad", "a")
	_palette("FX_COLOR_B", "grad", "b")
	var g: Dictionary = _e["grad"]
	body.add_child(RbUi.slider2("FX_ANGLE_G", -180.0, 180.0, rad_to_deg(float(g.get("angle", PI / 2.0))), _deg,
		func(v: float, done: bool) -> void:
			(_e["grad"] as Dictionary)["angle"] = deg_to_rad(v)
			_emit(done)))
	_slider("FX_AMOUNT", "grad", "amount", 0.0, 1.0, _pct)


func _build_cc() -> void:
	_toggle("FX_CC", "cc", DEFAULT_CC)
	if not _e.has("cc"):
		return
	_slider("FX_HUE", "cc", "hue", -0.5, 0.5, func(v: float) -> String: return "%d°" % roundi(v * 360.0))
	_slider("FX_SAT", "cc", "saturation", 0.0, 2.0, _pct)
	_slider("FX_BRIGHT", "cc", "brightness", -1.0, 1.0, _pct)
	_slider("FX_CONTRAST", "cc", "contrast", 0.0, 2.0, _pct)
