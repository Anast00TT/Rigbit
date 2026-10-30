class_name RbBoneSheet
extends RbPanel
## Констрейны кости: предел угла, независимый угол, взять у кости, смотреть на кость, динамика.
## Лист держит рабочую копию словаря и шлёт его целиком; команду и склейку жеста делает главный экран.

signal changed(constraints: Dictionary, done: bool)
signal pick_requested(kind: String, anchor: Control)  # kind: "copy" | "target"

var rig: RbRig
var bone_id := 0

var _c := {}  # рабочая копия констрейнов


func _init() -> void:
	super("CON_TITLE")


func show_bone(r: RbRig, id: int) -> void:
	rig = r
	bone_id = id
	var b := rig.get_bone(id)
	_c = b.constraints.duplicate(true) if b else {}
	rebuild()


## После undo и правок снаружи: перестроить, только если словарь реально изменился.
func sync() -> void:
	var b := rig.get_bone(bone_id) if rig else null
	if b and not RbUi.same_dict(_c, b.constraints):
		_c = b.constraints.duplicate(true)
		rebuild()


## Выбор кости в меню: kind "copy" / "target", id 0 = снять.
func set_pick(kind: String, id: int) -> void:
	if kind == "copy":
		if id == 0:
			_c.erase("copy")
		else:
			var cp: Dictionary = _c.get("copy", {"angle": 1.0, "move": 0.0, "scale": 0.0})
			cp["from"] = id
			_c["copy"] = cp
	else:
		if id == 0:
			_c.erase("target")
		else:
			_c["target"] = id
	_emit(true)
	rebuild()


func _emit(done: bool) -> void:
	changed.emit(_c.duplicate(true), done)


func rebuild() -> void:
	var b := rig.get_bone(bone_id) if rig else null
	if b == null:
		return
	set_sub(b.name)
	begin_rebuild()
	var hint := RbUi.label("CON_HINT", "LabelFaint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	_build_limit()
	_build_independent()
	_build_copy(b)
	_build_target(b)
	_build_dynamics()
	end_rebuild()


func _deg(v: float) -> String:
	return "%d°" % roundi(v)


func _build_limit() -> void:
	body.add_child(RbUi.switch_row("CON_LIMIT", _c.has("limit"), func(on: bool) -> void:
		if on:
			_c["limit"] = {"min": -PI / 4.0, "max": PI / 4.0}
		else:
			_c.erase("limit")
		_emit(true)
		rebuild()))
	if not _c.has("limit"):
		return
	var lim: Dictionary = _c["limit"]
	var rows := {}
	rows["min"] = RbUi.slider2("LBL_MIN", -180.0, 180.0, rad_to_deg(float(lim.get("min", -PI))), _deg,
		func(v: float, done: bool) -> void:
			var d: Dictionary = _c["limit"]
			d["min"] = deg_to_rad(v)
			if v > rad_to_deg(float(d["max"])):
				d["max"] = deg_to_rad(v)
				RbUi.set_slider2(rows["max"], v)
			_emit(done))
	rows["max"] = RbUi.slider2("LBL_MAX", -180.0, 180.0, rad_to_deg(float(lim.get("max", PI))), _deg,
		func(v: float, done: bool) -> void:
			var d: Dictionary = _c["limit"]
			d["max"] = deg_to_rad(v)
			if v < rad_to_deg(float(d["min"])):
				d["min"] = deg_to_rad(v)
				RbUi.set_slider2(rows["min"], v)
			_emit(done))
	body.add_child(rows["min"])
	body.add_child(rows["max"])


func _build_independent() -> void:
	body.add_child(RbUi.switch_row("CON_INDEP", bool(_c.get("independent", false)), func(on: bool) -> void:
		if on:
			_c["independent"] = true
		else:
			_c.erase("independent")
		_emit(true)))


func _bone_name(id: int) -> String:
	var nb := rig.get_bone(id)
	return nb.name if nb else ""


func _pick_button(kind: String, id: int) -> Button:
	var b := Button.new()
	b.theme_type_variation = "SecondaryButton"
	b.icon = RbIcons.tex("chain")
	b.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	b.text = _bone_name(id) if id != 0 and rig.get_bone(id) else tr("CON_NONE")
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size.y = 44
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void: pick_requested.emit(kind, b))
	return b


func _build_copy(_b: RbBone) -> void:
	body.add_child(RbUi.section("CON_COPY"))
	var cp: Dictionary = _c.get("copy", {})
	var from_id := int(cp.get("from", 0))
	body.add_child(_pick_button("copy", from_id))
	if from_id == 0 or rig.get_bone(from_id) == null:
		return
	for spec in [["TL_ROT", "angle"], ["TL_OFFSET", "move"], ["TL_SCALE", "scale"]]:
		var k: String = spec[1]
		body.add_child(RbUi.slider2(spec[0], -2.0, 2.0, float(cp.get(k, 0.0)), RbUi.num,
			func(v: float, done: bool) -> void:
				var d: Dictionary = _c["copy"]
				d[k] = v
				_emit(done)))


func _build_target(_b: RbBone) -> void:
	body.add_child(RbUi.section("CON_LOOK"))
	body.add_child(_pick_button("target", int(_c.get("target", 0))))


func _build_dynamics() -> void:
	body.add_child(RbUi.switch_row("CON_DYN", _c.has("dynamics"), func(on: bool) -> void:
		if on:
			_c["dynamics"] = {"spring": 0.5, "damping": 0.4, "torque": 0.0}
		else:
			_c.erase("dynamics")
		_emit(true)
		rebuild()))
	if not _c.has("dynamics"):
		return
	var dyn: Dictionary = _c["dynamics"]
	for spec in [["CON_SPRING", "spring"], ["CON_DAMP", "damping"], ["CON_WEIGHT", "torque"]]:
		var k: String = spec[1]
		body.add_child(RbUi.slider2(spec[0], 0.0, 1.0, float(dyn.get(k, 0.0)),
			func(v: float) -> String: return "%d%%" % roundi(v * 100.0),
			func(v: float, done: bool) -> void:
				var d: Dictionary = _c["dynamics"]
				d[k] = v
				_emit(done)))
