extends Control
## Главный экран, раскладка «Студия».
## Узкий экран (телефон в портрете): тулбар + отдельная строка режимов.
## Широкий (телефон в ландшафте, планшет): режимы встраиваются в тулбар, одна строка.
## Проекты сохраняются сами (как в iLight): в user://projects, через 2 с после изменения и при сворачивании.

const WIDE_DP := 700.0
const VERSION := "0.0.1"
const TAB_KEYS := ["TAB_RIG", "TAB_ANIM", "TAB_COMP", "TAB_EXPORT"]

var settings := RbSettings.new()
var doc: RbDocument
var undo: RbUndoStack
var evaluator := RbEvaluator.new()
var pose: RbEvaluator.Pose
var project_path := ""
var selected_id := 0
var mode := 0
var tool := "layer"
var ui_scale := 1.0

var _args := {}
var _no_save := false
var _dirty := false
var _refresh_queued := false
var _wide := -1
var _tip_id := ""

var _drag_id := 0
var _drag_start_world := Vector2.ZERO
var _drag_start_pos := Vector2.ZERO
var _drag_pushed := false

# правка сетки: перетаскивание точки
const MESH_PICK_DP := 24.0  # перетаскивание и долгое нажатие ловят точку в таком радиусе на экране
const MESH_TAP_DP := 16.0  # тап ближе этого к точке не добавляет новую (мельче, чтобы на плотной сетке было куда тапнуть)
var _mesh_drag_id := 0
var _mesh_drag_index := -1
var _mesh_drag_offset := Vector2.ZERO
var _mesh_work := {}
var _mesh_start := {}
var _importing := false
var busy_layer: Control

var root_margin: MarginContainer
var top_bar: PanelContainer
var seg_slot: HBoxContainer
var tabs_bar: PanelContainer
var tabs_margin: MarginContainer
var seg: PanelContainer
var seg_buttons: Array[Button] = []
var view: RbViewportView
var rail: PanelContainer
var rail_grid: GridContainer
var _rail_queued := false
var tool_buttons := {}
var btn_folder: Button
var btn_undo: Button
var btn_redo: Button
var btn_more: Button
var cta_center: CenterContainer
var cta: VBoxContainer
var cta_badge: PanelContainer
var tip_holder: MarginContainer
var tip: PanelContainer
var tip_label: Label
var toast_holder: MarginContainer
var toast: PanelContainer
var toast_label: Label
var _toast_tween: Tween
var overlay_layer: Control
var save_timer: Timer
var main_col: VBoxContainer
var content: HBoxContainer
var view_col: VBoxContainer
var layers_panel: RbLayersPanel
var sheet: RbLayerSheet
var sel_chip: Button
var rig_tools: RbRigTools
var pin_tools: RbPinTools
var form_tools: RbFormTools
var params_sheet: RbParamsSheet
var pose_clip := {}  # скопированная поза: {bone_id: [angle, offset, scale]}
var export_sheet: RbExportSheet
var exporting := false
var _export_cancel := false
var _export_file := ""  # готовый файл в user://exports
var _export_block: _HoleBlocker


## Заслонка на время экспорта: ловит касания везде, кроме листа экспорта (там «Отменить»).
class _HoleBlocker extends Control:
	var hole: Control

	func _has_point(p: Vector2) -> bool:
		return hole == null or not hole.get_global_rect().has_point(p + global_position)
var onion_eval := RbEvaluator.new()  # свой вычислитель для призраков, кеши вьюпорта не трогает
var _onion_key := ""
var _doc_rev := 0  # счётчик правок документа: призраки пересчитываются только после правки или смены кадра
var bone_sheet: RbBoneSheet
var fx_sheet: RbFxSheet
var btn_params: Button
var form_banner: PanelContainer
var form_banner_holder: MarginContainer
var form_banner_box: BoxContainer
var form_banner_label: Label
var _fx_last_id := 0  # слой, для которого лист эффектов открывался сам
var _light_drag := false
var timeline: RbTimeline
var btn_play: Button
var playing := false
var loop_play := true
var _play_acc := 0.0
const MODE_TOOLS := [
	["layer", "bone", "mesh", "weights", "pins", "hand"],  # Риг
	["pose", "pins", "layer", "hand"],  # Анимация
	["layer", "hand"],  # Композинг
	["hand"],  # Экспорт
]
## Правка ключевой формы: кости, точки сетки, вид.
const FORM_TOOLS := ["pose", "mesh", "hand"]
const FORM_COLOR := Color("#E0539B")
const RIG_TOOLS := ["bone", "pose", "weights"]
var btn_layers: Button

# жест трансформа: "move" / "scale" / "rotate"
var _xf_mode := ""
var _xf_start_scale := Vector2.ONE
var _xf_start_rot := 0.0
var _xf_center := Vector2.ZERO


func _ready() -> void:
	_parse_args()
	set_process(false)
	_no_save = _args.has("shot") or _args.has("nosave")
	settings.load_cfg()
	if _args.has("lang"):
		settings.locale = _args["lang"]
	if _args.has("onion"):  # --onion=N: призраки онион скина ±N кадров
		settings.onion = int(_args["onion"])
	TranslationServer.set_locale(settings.locale)
	_setup_scale()
	RbTheme.use_palette(_args.get("theme", settings.theme))
	theme = RbTheme.build()
	_build_ui()
	save_timer = Timer.new()
	save_timer.one_shot = true
	save_timer.wait_time = 2.0
	save_timer.timeout.connect(_save_now)
	add_child(save_timer)
	get_window().size_changed.connect(_on_window_resized)
	_set_doc(RbDocument.new(), "")
	if not _no_save and settings.last_project != "" and FileAccess.file_exists(settings.last_project):
		var d := RbProjectIO.load_doc(settings.last_project)
		if d:
			_set_doc(d, settings.last_project)
	_on_window_resized()
	if _args.has("demo"):
		_add_demo()
	if _args.has("gl2"):  # --gl2[=путь]: импорт персонажа Gacha Life 2 (по умолчанию фикстура тестов)
		var gp := str(_args["gl2"])
		_import_svg(gp if gp.ends_with(".svg") else "res://tests/fixtures/gl2_claude.svg")
	if _args.has("demo_rig"):
		_refresh()
		_add_demo_rig()
	if _args.has("demo_anim"):
		_add_demo_anim()
	if _args.has("demo_con"):
		_add_demo_con()
	if _args.has("demo_params"):
		_add_demo_params()
	if _args.has("demo_pins"):
		await _add_demo_pins()
	if _args.has("demo_fx"):
		_add_demo_fx()
	if _args.has("import"):
		await _import_path(str(_args["import"]).uri_decode())
	if _args.has("mode"):
		seg_buttons[int(_args["mode"])].button_pressed = true
		_set_mode(int(_args["mode"]))
	if _args.get("tool", "") == "mesh":
		await _activate_mesh_tool_for_shot()
	elif _args.has("tool") and tool_buttons.has(_args["tool"]):
		tool_buttons[_args["tool"]].button_pressed = true
		_set_tool(_args["tool"])
	if _args.has("shot"):
		_take_shot()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"


# ---------------- масштаб и раскладка ----------------

func _setup_scale() -> void:
	var w := get_window()
	if _args.has("size"):
		var p: PackedStringArray = _args["size"].split("x")
		w.size = Vector2i(int(p[0]), int(p[1]))
	if OS.has_feature("mobile"):
		ui_scale = DisplayServer.screen_get_dpi() / 160.0
	else:
		ui_scale = float(_args.get("scale", DisplayServer.screen_get_scale()))
	ui_scale = clampf(ui_scale, 1.0, 4.0)
	RbIcons.scale = ui_scale
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	_apply_content_size()


func _apply_content_size() -> void:
	var w := get_window()
	w.content_scale_size = Vector2i(maxi(1, int(w.size.x / ui_scale)), maxi(1, int(w.size.y / ui_scale)))


func _on_window_resized() -> void:
	_apply_content_size()
	_relayout.call_deferred()


func _relayout() -> void:
	var vs := get_viewport_rect().size
	var wide := vs.x >= WIDE_DP
	if int(wide) != _wide:
		_wide = int(wide)
		if seg.get_parent():
			seg.get_parent().remove_child(seg)
		if wide:
			seg_slot.add_child(seg)
			tabs_bar.visible = false
			top_bar.theme_type_variation = "BarLine"
		else:
			tabs_margin.add_child(seg)
			tabs_bar.visible = true
			top_bar.theme_type_variation = "Bar"
	# в тулбаре: 7 кнопок по 44 + разделитель + 9 зазоров по 4 + поля 8 = 353, плюс 16 воздуха
	seg.custom_minimum_size.x = clampf(vs.x - 370.0, 320.0, 460.0) if wide else 0.0
	seg.size_flags_horizontal = Control.SIZE_SHRINK_CENTER if wide else Control.SIZE_FILL
	var m := _safe_insets()
	root_margin.add_theme_constant_override("margin_left", int(m.position.x))
	root_margin.add_theme_constant_override("margin_top", int(m.position.y))
	root_margin.add_theme_constant_override("margin_right", int(m.size.x))
	root_margin.add_theme_constant_override("margin_bottom", int(m.size.y))
	for p in _panels():
		if p and p.visible:
			_place_panel(p)
	_update_rail_columns()
	if timeline:
		var holder: Control = view_col if wide else main_col
		if timeline.get_parent() != holder:
			timeline.get_parent().remove_child(timeline)
			holder.add_child(timeline)
		timeline.set_layout(wide, vs)
		_update_timeline_visibility()
	_update_empty_state.call_deferred()


## Рейка инструментов: если кнопки не помещаются по высоте (низкий ландшафт, открытый лист снизу), два столбца.
## Высоту берём из соседей по колонке (сама рейка раздула бы content своим минимумом).
func _update_rail_columns() -> void:
	if _rail_queued:
		return
	_rail_queued = true
	_do_rail_columns.call_deferred()


func _do_rail_columns() -> void:
	await get_tree().process_frame
	_rail_queued = false
	if rail_grid == null or content == null:
		return
	var n := 0
	for k in tool_buttons:
		if tool_buttons[k].visible:
			n += 1
	var ins := _safe_insets()
	var avail := get_viewport_rect().size.y - ins.position.y - ins.size.y - 8.0
	for c in main_col.get_children():
		if c is Control and (c as Control).visible and c != content.get_parent():
			avail -= (c as Control).size.y
	# сначала обычные кнопки 56, потом плотные 48 (всё ещё не меньше 44), и только потом два столбца
	var gaps := float(maxi(n - 1, 0)) * 4.0 + 10.0
	var h := 56.0
	var cols := 1
	if avail >= 40.0 and float(n) * 56.0 + gaps > avail:
		if float(n) * 48.0 + gaps <= avail:
			h = 48.0
		else:
			cols = 2
	for k in tool_buttons:
		tool_buttons[k].custom_minimum_size.y = h
	if rail_grid.columns != cols:
		rail_grid.columns = cols


## Отступы от выреза камеры и системных полос, в dp: (left, top) и (right, bottom).
func _safe_insets() -> Rect2:
	if _args.has("safe"):
		var p: PackedStringArray = _args["safe"].split(",")
		return Rect2(float(p[0]), float(p[1]), float(p[2]), float(p[3]))
	if not OS.has_feature("mobile"):
		return Rect2()
	var w := get_window()
	var win := Rect2i(w.position, w.size)
	var safe := DisplayServer.get_display_safe_area()
	var l := maxf(0.0, safe.position.x - win.position.x)
	var t := maxf(0.0, safe.position.y - win.position.y)
	var r := maxf(0.0, win.end.x - safe.end.x)
	var b := maxf(0.0, win.end.y - safe.end.y)
	return Rect2(l / ui_scale, t / ui_scale, r / ui_scale, b / ui_scale)


# ---------------- сборка интерфейса ----------------

func _build_ui() -> void:
	root_margin = MarginContainer.new()
	root_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root_margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	root_margin.add_child(col)
	main_col = col

	# тулбар
	top_bar = PanelContainer.new()
	top_bar.theme_type_variation = "Bar"
	col.add_child(top_bar)
	var tm := _margins(4, 4, 4, 4)
	top_bar.add_child(tm)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	tm.add_child(row)
	btn_folder = _icon_btn("folder", _menu_project)
	row.add_child(btn_folder)
	btn_undo = _icon_btn("undo", _on_undo)
	row.add_child(btn_undo)
	btn_redo = _icon_btn("redo", _on_redo)
	row.add_child(btn_redo)
	row.add_child(_vsep())
	btn_layers = _icon_btn("layers", _toggle_layers)
	row.add_child(btn_layers)
	btn_params = _icon_btn("sliders", _toggle_params)
	row.add_child(btn_params)
	seg_slot = HBoxContainer.new()
	seg_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seg_slot.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(seg_slot)
	btn_play = _icon_btn("play", _toggle_play)
	row.add_child(btn_play)
	btn_more = _icon_btn("more", _menu_more)
	row.add_child(btn_more)

	# строка режимов (узкий экран)
	tabs_bar = PanelContainer.new()
	tabs_bar.theme_type_variation = "BarLine"
	col.add_child(tabs_bar)
	tabs_margin = _margins(8, 2, 8, 6)
	tabs_bar.add_child(tabs_margin)
	seg = _build_seg()
	tabs_margin.add_child(seg)

	# вьюпорт + инструменты
	var cm := _margins(4, 4, 4, 4)
	cm.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(cm)
	content = HBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	cm.add_child(content)
	content.resized.connect(_update_rail_columns)
	# колонка вьюпорта: в ландшафте таймлайн встаёт под вьюпорт, рейка инструментов справа остаётся во всю высоту
	view_col = VBoxContainer.new()
	view_col.add_theme_constant_override("separation", 4)
	view_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(view_col)
	view = RbViewportView.new()
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view_col.add_child(view)
	view.tap.connect(_on_tap)
	view.double_tap.connect(func(_w: Vector2) -> void: view.fit_canvas())
	view.drag_begin.connect(_on_drag_begin)
	view.drag_move.connect(_on_drag_move)
	view.drag_end.connect(_on_drag_end)
	view.drag_cancel.connect(_on_drag_cancel)
	view.two_finger_tap.connect(_on_undo)
	view.three_finger_tap.connect(_on_redo)
	view.resized.connect(_update_empty_state)
	view.snapped.connect(func() -> void: _vibrate(12))
	view.long_press.connect(_on_long_press)

	rail = PanelContainer.new()
	rail.theme_type_variation = "Rail"
	content.add_child(rail)
	var rb := GridContainer.new()  # в низком ландшафте инструменты идут в два столбца
	rb.columns = 1
	rb.add_theme_constant_override("h_separation", 4)
	rb.add_theme_constant_override("v_separation", 4)
	rail.add_child(rb)
	rail_grid = rb
	var group := ButtonGroup.new()
	for t in [["layer", "move", "TOOL_LAYER"], ["bone", "bone", "TOOL_BONE"], ["pose", "bone", "TOOL_POSE"],
			["mesh", "mesh", "TOOL_MESH"], ["weights", "brush", "TOOL_WEIGHTS"], ["pins", "pin", "TOOL_PINS"],
			["hand", "hand", "TOOL_HAND"]]:
		var b := Button.new()
		b.theme_type_variation = "ToolButton"
		b.toggle_mode = true
		b.button_group = group
		b.icon = RbIcons.tex(t[1])
		b.text = t[2]
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.custom_minimum_size = Vector2(48, 56)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_set_tool.bind(t[0]))
		rb.add_child(b)
		tool_buttons[t[0]] = b
	tool_buttons["layer"].button_pressed = true
	rig_tools = RbRigTools.new(self)
	pin_tools = RbPinTools.new(self)
	form_tools = RbFormTools.new(self)

	_build_cta()
	_build_tip()
	_build_toast()
	_build_panels()

	overlay_layer = Control.new()
	overlay_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay_layer.visible = false
	overlay_layer.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			_close_overlay())
	add_child(overlay_layer)
	# прозрачная заслонка на время долгих операций (импорт PSD): касания не проходят к интерфейсу
	busy_layer = Control.new()
	busy_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	busy_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	busy_layer.visible = false
	add_child(busy_layer)
	_export_block = _HoleBlocker.new()
	_export_block.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_export_block.mouse_filter = Control.MOUSE_FILTER_STOP
	_export_block.hole = export_sheet
	_export_block.visible = false
	add_child(_export_block)
	_set_mode(0)


func _build_seg() -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "Seg"
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)
	p.add_child(h)
	var group := ButtonGroup.new()
	for i in 4:
		var b := Button.new()
		b.theme_type_variation = "SegButton"
		b.toggle_mode = true
		b.button_group = group
		b.text = TAB_KEYS[i]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(76, 42)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_set_mode.bind(i))
		h.add_child(b)
		seg_buttons.append(b)
	seg_buttons[0].button_pressed = true
	return p


func _build_cta() -> void:
	cta_center = CenterContainer.new()
	cta_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cta_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.add_child(cta_center)
	cta = VBoxContainer.new()
	cta.add_theme_constant_override("separation", 10)
	cta_center.add_child(cta)
	cta_badge = PanelContainer.new()
	cta_badge.theme_type_variation = "Badge"
	cta_badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var fr := TextureRect.new()
	fr.texture = ImageTexture.create_from_image(RbIcons.frog_image(int(48 * ui_scale * 1.5)))
	fr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	fr.custom_minimum_size = Vector2(48, 56)
	cta_badge.add_child(fr)
	cta.add_child(cta_badge)
	var imp := _text_btn("PrimaryButton", "import", "EMPTY_IMPORT", _on_import, 48)
	cta.add_child(imp)
	var hint := Label.new()
	hint.theme_type_variation = "LabelFaint"
	hint.text = "EMPTY_HINT"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cta.add_child(hint)
	cta.add_child(_text_btn("SecondaryButton", "folder", "EMPTY_OPEN", _open_projects, 44))
	cta.add_child(_text_btn("SecondaryButton", "frog", "EMPTY_DEMO", _add_demo, 44))


func _build_tip() -> void:
	tip_holder = _margins(12, 12, 12, 12)
	tip_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tip_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip_holder.visible = false
	view.add_child(tip_holder)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip_holder.add_child(v)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(spacer)
	tip = PanelContainer.new()
	tip.theme_type_variation = "Tip"
	tip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(tip)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	tip.add_child(h)
	var ic := TextureRect.new()
	ic.texture = RbIcons.tex("bulb")
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.custom_minimum_size = Vector2(18, 18)
	ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	ic.modulate = RbTheme.C.acc
	var icm := _margins(0, 4, 0, 0)
	icm.add_child(ic)
	h.add_child(icm)
	tip_label = Label.new()
	tip_label.theme_type_variation = "LabelDim"
	tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tip_label.custom_minimum_size.x = 140
	h.add_child(tip_label)
	var close := _icon_btn("x", _dismiss_tip)
	close.custom_minimum_size = Vector2(40, 40)
	close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(close)


func _build_toast() -> void:
	toast_holder = _margins(12, 62, 12, 12)  # ниже кнопки выделенного слоя (10 + 44 + зазор 8)
	toast_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	toast_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.add_child(toast_holder)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_holder.add_child(v)
	toast = PanelContainer.new()
	toast.theme_type_variation = "Toast"
	toast.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast.visible = false
	v.add_child(toast)
	toast_label = Label.new()
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast.add_child(toast_label)


func _margins(l: int, t: int, r: int, b: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	return m


func _icon_btn(icon: String, cb: Callable) -> Button:
	var b := Button.new()
	b.icon = RbIcons.tex(icon)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.custom_minimum_size = Vector2(44, 48)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _text_btn(variation: String, icon: String, key: String, cb: Callable, h: int) -> Button:
	var b := Button.new()
	b.theme_type_variation = variation
	b.icon = RbIcons.tex(icon)
	b.text = key
	b.custom_minimum_size.y = h
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _vsep() -> Control:
	var c := ColorRect.new()
	c.color = RbTheme.C.p3
	c.custom_minimum_size = Vector2(1, 24)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return c


# ---------------- документ ----------------

func _set_doc(d: RbDocument, path: String) -> void:
	if doc and doc.changed.is_connected(_on_doc_changed):
		doc.changed.disconnect(_on_doc_changed)
	if form_tools and form_tools.active:
		form_tools.discard()
		_form_state_changed()
	for p in _panels():
		if p and p.visible:
			p.visible = false
	_fx_last_id = 0
	_stop_playback()
	doc = d
	project_path = path
	undo = RbUndoStack.new(doc)
	undo.changed.connect(_update_undo_buttons)
	doc.changed.connect(_on_doc_changed)
	selected_id = 0
	_dirty = false
	if timeline:
		timeline.bind(doc)
	view.renderer.clear()
	view.canvas_size = Vector2(doc.canvas_size)
	view.fit_canvas()
	_refresh()
	_update_undo_buttons()
	if not _no_save:
		settings.last_project = path
		settings.save_cfg()


func _on_doc_changed(what: StringName) -> void:
	if what == &"canvas":  # импорт PSD на пустом документе (и его undo) меняет размер холста
		view.canvas_size = Vector2(doc.canvas_size)
		view.fit_canvas()
	if export_sheet.visible and not exporting:
		export_sheet.sync_doc.call_deferred()
	if what == &"params" and params_sheet.visible:
		params_sheet.rebuild.call_deferred(doc)  # список, имена и диапазоны поменялись (значения ползунков идут через &"param_value")
	_dirty = true
	_doc_rev += 1
	_stop_playback()  # воспроизведение документ не трогает, значит любое изменение это правка
	if not _no_save:
		save_timer.start()
	if not _refresh_queued:
		_refresh_queued = true
		_refresh.call_deferred()


func _refresh() -> void:
	_refresh_queued = false
	if form_tools.active:
		# правка формы: ползунок держится на точке формы, какие бы ключи ни писали значения
		var fp := form_tools.param()
		if fp:
			fp.value = form_tools.point
	# в Риге ползунки показываются, пока открыта их панель (предпросмотр формы)
	pose = evaluator.evaluate(doc, 0, mode != 0 or params_sheet.visible)
	view.renderer.sync(doc, pose)
	_update_onion()
	_update_selection()
	_update_empty_state()
	timeline.refresh()
	if params_sheet.visible:
		params_sheet.sync_values()


## Онион скин: только в Анимации, не при проигрывании и не при правке формы.
func _update_onion() -> void:
	var n := settings.onion
	if mode != 1 or n <= 0 or playing or form_tools.active or doc.frame_count < 2:
		if view.renderer.onion:
			view.renderer.onion.clear()
		_onion_key = ""
		return
	var key := "%d|%d|%d|%d|%s" % [doc.current_frame, doc.frame_count, n, _doc_rev, loop_play]
	if key == _onion_key:
		return
	_onion_key = key
	var ghosts: Array = []
	for g in RbOnion.ghost_frames(doc.current_frame, doc.frame_count, n, loop_play):
		ghosts.append([onion_eval.pose_at(doc, g[0]), RbOnion.tint(g[1], n)])
	view.renderer.enable_onion().show_ghosts(doc, ghosts, view.renderer.texture_for)


# ---------------- экспорт ----------------

## Кадр за кадром в RbFrameRenderer, прогресс и отмена в листе. Файл сначала в user://exports,
## потом «Сохранить» отдаёт копию через системный диалог (на Android SAF: галерея, Загрузки, диск).
func _run_export(s: Dictionary) -> void:
	if exporting or doc == null:
		return
	_stop_playback()
	exporting = true
	_export_cancel = false
	_export_block.visible = true
	export_sheet.show_progress()
	var size := RbExportPlan.out_size(doc.canvas_size, int(s["long_side"]))
	var src := RbExportPlan.source_frames(int(s["from"]), int(s["to"]), doc.fps, int(s["fps"]))
	var gif: bool = s["format"] == "gif"
	DirAccess.make_dir_recursive_absolute("user://exports")
	var name := RbExportPlan.file_name(project_path, s["format"])
	var path := "user://exports/" + name
	var fr := RbFrameRenderer.new()
	add_child(fr)
	fr.setup(doc, size, bool(s["transparent"]), doc.background)
	var frames: Array = []
	var seq: RbPngSequence = null
	var err := ""
	if not gif:
		seq = RbPngSequence.new()
		if seq.open(path) != OK:
			err = "EXPORT_ERR_WRITE"
	var t0 := Time.get_ticks_msec()
	var n := src.size()
	for i in n:
		if _export_cancel or err != "":
			break
		var img: Image = await fr.render_frame(src[i])
		if img == null:
			err = "EXPORT_ERR_RENDER"
			break
		if seq:
			if seq.add(img) != OK:
				err = "EXPORT_ERR_WRITE"
		else:
			frames.append(img)
		var left := float(Time.get_ticks_msec() - t0) / float(i + 1) * float(n - i - 1) / 1000.0
		export_sheet.set_progress(float(i + 1) / n * (0.85 if gif else 1.0), tr("EXPORT_FRAME") % [i + 1, n, ceili(left)])
	fr.finish()
	fr.queue_free()
	if seq:
		seq.close()
	if _export_cancel or err != "":
		frames.clear()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		_finish_export()
		_toast(tr("EXPORT_CANCELLED") if err == "" else tr(err))
		return
	if gif:
		export_sheet.set_progress(0.9, tr("EXPORT_GIF_ENCODE"))
		await _frames(2)  # надпись успевает нарисоваться до долгого сжатия
		var bytes := RbGifEncoder.encode_frames(frames, float(s["fps"]))
		frames.clear()
		if bytes.is_empty() or RbGifEncoder.save(path, bytes) != OK:
			_finish_export()
			_toast(tr("EXPORT_ERR_WRITE"))
			return
	_export_file = path
	var kb := ceili(FileAccess.get_file_as_bytes(path).size() / 1024.0)
	var weight := (tr("SIZE_KB") % kb) if kb < 1024 else (tr("SIZE_MB") % RbExportSheet._secs(kb / 1024.0))
	_finish_export()
	export_sheet.show_done(name, "%d×%d · %d %s · %s" % [size.x, size.y, n, tr("EXPORT_FRAMES_SHORT"), weight])
	_vibrate(30)


func _finish_export() -> void:
	exporting = false
	_export_block.visible = false
	if export_sheet.state == "progress":
		export_sheet.state = "settings"
		export_sheet.rebuild()


func _export_save() -> void:
	if _export_file == "" or not FileAccess.file_exists(_export_file):
		return
	var name := _export_file.get_file()
	var filt := "*.gif;GIF;image/gif" if name.ends_with(".gif") else "*.zip;ZIP;application/zip"
	if _args.has("export_save"):  # отладка: сохранить без диалога
		_export_copy(str(_args["export_save"]))
	elif DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		DisplayServer.file_dialog_show(tr("EXPORT_SAVE"), "", name, false, DisplayServer.FILE_DIALOG_MODE_SAVE_FILE,
			PackedStringArray([filt]), func(ok: bool, paths: PackedStringArray, _f: int) -> void:
				if ok and not paths.is_empty():
					_export_copy.call_deferred(paths[0]))
	else:
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.filters = PackedStringArray([filt])
		fd.current_file = name
		fd.file_selected.connect(_export_copy)
		add_child(fd)
		fd.popup_centered_ratio(0.9)


func _export_copy(dst: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(_export_file)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null or bytes.is_empty():
		_toast(tr("EXPORT_ERR_WRITE"))
		return
	f.store_buffer(bytes)
	f.close()
	_toast(tr("EXPORT_SAVED"))


func _onion_menu() -> void:
	var items := []
	for n in [0, 1, 2, 3]:
		var label := tr("ONION_OFF") if n == 0 else tr("ONION_N") % n
		items.append(["check" if settings.onion == n else "dot_empty", label, func() -> void:
			settings.onion = n
			settings.save_cfg()
			_update_onion()])
	_open_menu(btn_more, items)


func _update_selection() -> void:
	view.selection = PackedVector2Array()
	if mode == 3 and selected_id != 0 and pose and pose.layers.has(selected_id):
		pass  # Экспорт: вьюпорт = чистое превью, без рамок и чипов
	elif selected_id != 0 and pose and pose.layers.has(selected_id):
		var l := doc.get_layer(selected_id)
		var lp: RbEvaluator.LayerPose = pose.layers[selected_id]
		if not l.is_group():
			var h := l.size * 0.5
			for c in [Vector2(-h.x, -h.y), Vector2(h.x, -h.y), h, Vector2(-h.x, h.y)]:
				view.selection.append(lp.world * c)
	elif doc.get_layer(selected_id) == null:
		selected_id = 0
	view.show_gizmo = tool == "layer" and mode <= 1
	_update_mesh_overlay()
	rig_tools.update_overlay()
	pin_tools.update_overlay()
	var l2 := doc.get_layer(selected_id) if selected_id else null
	var bone := doc.rig.get_bone(rig_tools.selected_bone) if tool in ["bone", "pose"] else null
	sel_chip.visible = (l2 != null or bone != null) and not layers_panel.visible and not form_tools.active and mode != 3
	var chip_name := bone.name if bone else (l2.name if l2 else "")
	if sel_chip.visible:
		sel_chip.icon = RbIcons.tex("bone" if bone else ("fx" if mode == 2 else "gear"))
		sel_chip.text = chip_name if chip_name.length() <= 18 else chip_name.left(17) + "…"
		sel_chip.size = Vector2.ZERO  # подогнать ширину под текст
	if sheet.visible:
		if l2 == null:
			_close_sheet()
		elif sheet.layer_id != selected_id:
			sheet.show_layer(doc, selected_id)
	if bone_sheet.visible:
		if bone == null:
			_hide_panel(bone_sheet, false)
		elif bone_sheet.bone_id != bone.id:
			bone_sheet.show_bone(doc.rig, bone.id)
		else:
			bone_sheet.sync()
	_update_fx_panel(l2)
	if layers_panel.visible:
		layers_panel.selected_id = selected_id
	view.refresh_overlay()
	_sync_timeline_focus()


## Лист эффектов в Композинге: сам открывается на выбранном слое с картинкой и закрывается, когда выбирать нечего.
func _update_fx_panel(l: RbLayer) -> void:
	view.light_arrow = {}
	if mode != 2:
		_fx_last_id = 0
		if fx_sheet.visible:
			_hide_panel(fx_sheet, false)
		return
	if l == null or l.is_group():
		_fx_last_id = 0
		if fx_sheet.visible:
			_hide_panel(fx_sheet, false)
		return
	if selected_id != _fx_last_id:
		_fx_last_id = selected_id
		_open_fx_sheet()
	elif fx_sheet.visible:
		if fx_sheet.layer_id != selected_id:
			fx_sheet.show_layer(doc, selected_id)
		else:
			fx_sheet.sync()
	if fx_sheet.visible and l.effects.has("rim") and pose and pose.layers.has(l.id):
		var rim: Dictionary = l.effects["rim"]
		view.light_arrow = {"c": (pose.layers[l.id] as RbEvaluator.LayerPose).world.origin, "a": float(rim.get("angle", -PI / 4.0))}


func _update_empty_state() -> void:
	if doc == null or cta_center == null:
		return
	var empty := doc.root.is_empty()
	cta_center.visible = empty
	rail.visible = not empty and mode != 3
	view.show_ghost = false
	if empty:
		cta_badge.visible = true
		var need := cta.get_combined_minimum_size()
		if view.size.y > 0 and need.y + 24.0 > view.size.y:
			cta_badge.visible = false
			need = cta.get_combined_minimum_size()
		var g := view.ghost_rect()
		view.show_ghost = need.x + 32.0 <= g.size.x and need.y + 32.0 <= g.size.y
	tip.custom_minimum_size.x = minf(view.size.x - 24.0, 460.0)
	view.refresh_overlay()


func _update_undo_buttons() -> void:
	var editing_form := form_tools != null and form_tools.active
	btn_undo.disabled = editing_form or not undo.can_undo()
	btn_redo.disabled = editing_form or not undo.can_redo()


func _save_now() -> void:
	if _no_save or not _dirty:
		return
	if project_path == "":
		if doc.root.is_empty():
			_dirty = false
			return
		project_path = _new_project_path()
		settings.last_project = project_path
		settings.save_cfg()
	if RbProjectIO.save(doc, project_path) == OK:
		_dirty = false
	else:
		push_error("Rigbit: не удалось сохранить " + project_path)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_CLOSE_REQUEST:
			_save_now()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			if overlay_layer and overlay_layer.visible:
				_close_overlay()
			elif form_tools and form_tools.active:
				_finish_form()  # «назад» во время правки формы = «Готово»
			else:
				_save_now()
				get_tree().quit()


func _projects_dir() -> String:
	DirAccess.make_dir_recursive_absolute("user://projects")
	return "user://projects"


func _new_project_path() -> String:
	var n := 1
	while FileAccess.file_exists("%s/%s.%s" % [_projects_dir(), tr("PROJECT_N") % n, RbProjectIO.EXT]):
		n += 1
	return "%s/%s.%s" % [_projects_dir(), tr("PROJECT_N") % n, RbProjectIO.EXT]


func _list_projects() -> Array:
	var out := []
	var d := DirAccess.open(_projects_dir())
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with("." + RbProjectIO.EXT):
			var p := _projects_dir() + "/" + f
			out.append({"path": p, "name": f.get_basename(), "time": FileAccess.get_modified_time(p)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["time"] > b["time"])
	return out


func _new_project() -> void:
	_save_now()
	_set_doc(RbDocument.new(), "")
	_toast(tr("TOAST_NEW"))


func _open_path(path: String) -> void:
	_save_now()
	var d := RbProjectIO.load_doc(path)
	if d == null:
		_toast(tr("IMPORT_ERR_READ"))
		return
	_set_doc(d, path)
	_toast(tr("TOAST_OPENED") % path.get_file().get_basename())


# ---------------- импорт ----------------

func _on_import() -> void:
	var filters := PackedStringArray(["*.psd, *.psb, *.png, *.jpg, *.jpeg, *.webp, *.svg;%s;image/vnd.adobe.photoshop,application/octet-stream,image/png,image/jpeg,image/webp,image/svg+xml" % tr("FILTER_IMAGES")])
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		DisplayServer.file_dialog_show(tr("MENU_IMPORT"), "", "", false,
			DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, filters, _on_import_picked)
	else:
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.filters = filters
		fd.file_selected.connect(_import_path)
		add_child(fd)
		fd.popup_centered_ratio(0.9)


func _on_import_picked(status: bool, paths: PackedStringArray, _filter: int) -> void:
	if status and not paths.is_empty():
		_import_path.call_deferred(paths[0])


## PSD/PSB узнаём по расширению или по подписи "8BPS" (content:// путь расширения не имеет).
func _is_psd(path: String) -> bool:
	var ext := path.get_extension().to_lower()
	if ext == "psd" or ext == "psb":
		return true
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var head := f.get_buffer(4)
	f.close()
	return head.size() == 4 and head.get_string_from_ascii() == "8BPS"


## Ключ локализации, возможно с подробностями после ": " ("PSD_WARN_BLEND: diss (Слой)").
## Подробности подставляются, если в переводе есть %s.
func _tr_msg(s: String) -> String:
	var i := s.find(": ")
	var key := s if i < 0 else s.substr(0, i)
	var detail := "" if i < 0 else s.substr(i + 2)
	var txt := tr(key)
	if txt.contains("%s"):
		txt = txt % detail
	return txt


func _import_path(path: String) -> void:
	if _importing:
		return
	if _is_psd(path):
		await _import_psd(path)
		return
	if _is_svg(path):
		_import_svg(path)
		return
	var img := RbImporter.load_image(path)
	var nm := path.get_file().get_basename().uri_decode()
	if nm.is_empty() or nm.is_valid_int():
		nm = tr("TOOL_LAYER")
	_import_image(img, nm)


func _import_image(img: Image, nm: String) -> void:
	var r := RbImporter.image_to_layer(doc, img, nm)
	if r.error != "":
		_toast(tr(r.error))
		return
	var first := doc.root.is_empty()
	undo.push(RbCommands.AddLayer.new(r.layer, r.image))
	selected_id = r.layer.id
	for w in r.warnings:
		_toast(tr(w))
	tool_buttons["layer"].button_pressed = true
	_set_tool("layer")
	if first:
		view.fit_canvas()
		_show_hint("transform", "HINT_TRANSFORM")


## SVG узнаём по расширению или по началу файла (content:// путь расширения не имеет).
func _is_svg(path: String) -> bool:
	if path.get_extension().to_lower() == "svg":
		return true
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var head := f.get_buffer(512).get_string_from_utf8()
	f.close()
	return head.contains("<svg")


## SVG: персонаж Gacha Life 2 из мода = готовый риг одним шагом истории (design/gacha_import.md),
## любой другой SVG = одна картинка. На непустом холсте персонаж встаёт по центру.
func _import_svg(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		_toast(tr("IMPORT_ERR_READ"))
		return
	if not RbGl2Import.is_gl2(text):
		var img := Image.new()
		if img.load_svg_from_string(text, 2.0) != OK:
			_toast(tr("IMPORT_ERR_READ"))
			return
		_import_image(img, path.get_file().get_basename().uri_decode())
		return
	_importing = true
	busy_layer.visible = true
	_toast(tr("GL2_IMPORTING"), 120.0)
	await _frames(2)  # надпись успевает нарисоваться
	var r := RbGl2Import.build(doc, text)
	_importing = false
	busy_layer.visible = false
	if not r.ok:
		_toast(tr(r.error))
		return
	var first := doc.root.is_empty()
	if not first:
		var off := ((Vector2(doc.canvas_size) - Vector2(r.canvas)) * 0.5).floor()
		r.layers[0].position += off  # группа «Персонаж»: дети в её координатах
		for b in r.bones:
			if b.parent_id == 0:
				b.position += off
	undo.push(RbImportCharacterCommand.new(r, r.canvas if first else Vector2i.ZERO))
	undo.end_gesture()
	selected_id = r.parts.get("body", 0)
	if mode != 0 and not _args.has("mode"):
		seg_buttons[0].button_pressed = true
		_set_mode(0)
	if mode == 0:
		tool_buttons["bone"].button_pressed = true
		_set_tool("bone")
	view.fit_canvas()
	_toast(tr("GL2_DONE"))


## PSD/PSB: чтение на рабочем потоке, дальше один шаг истории. На пустом документе холст
## становится размером PSD, иначе PSD встаёт по центру текущего холста.
func _import_psd(path: String) -> void:
	_importing = true
	busy_layer.visible = true
	_toast(tr("PSD_IMPORTING"), 120.0)
	var holder := {}
	var job := func() -> void:
		holder["psd"] = RbPsdReader.read_file(path)
	var tid := WorkerThreadPool.add_task(job, false, "psd import")
	while not WorkerThreadPool.is_task_completed(tid):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	var psd: Dictionary = holder.get("psd", {})
	var first := doc.root.is_empty()
	var offset := Vector2.ZERO
	if not first:
		var psd_size := Vector2(float(psd.get("width", 0)), float(psd.get("height", 0)))
		offset = ((Vector2(doc.canvas_size) - psd_size) * 0.5).floor()
	var r := RbImporter.psd_to_layers(doc, psd, offset)
	_importing = false
	busy_layer.visible = false
	var layers: Array[RbLayer] = r["layers"]
	if r["error"] != "" or layers.is_empty():
		_toast(_tr_msg(r["error"] if r["error"] != "" else "IMPORT_ERR_READ"))
		return
	undo.push(RbAddLayersCommand.new(layers, r["images"], (r["canvas_size"] as Vector2i) if first else Vector2i.ZERO))
	undo.end_gesture()
	var count := 0
	selected_id = layers.back().id
	for l in layers:
		if not l.is_group():
			count += 1
			selected_id = l.id  # верхний растровый слой пачки
	tool_buttons["layer"].button_pressed = true
	_set_tool("layer")
	view.fit_canvas()
	_toast(tr("PSD_DONE") % count)
	var msgs: Array[String] = []
	for w in r["warnings"]:
		var m := _tr_msg(w)
		if not msgs.has(m):
			msgs.append(m)
	_toast_series(msgs.slice(0, 3))
	if first:
		_show_hint("transform", "HINT_TRANSFORM")


## Предупреждения по очереди, пока предыдущий тост не погас.
func _toast_series(msgs: Array[String]) -> void:
	for m in msgs:
		await get_tree().create_timer(2.1).timeout
		_toast(m)


## Демо-скелет лягушки (для самопроверки): тело + голова, сетка, автовеса.
func _add_demo_rig() -> void:
	var l := doc.get_layer(selected_id)
	if l == null:
		return
	var m := RbMeshGen.generate(doc.images[l.image_id], 0.45)
	undo.push(RbCommands.SetMesh.new(l.id, RbCommands.SetMesh.snap(l), {"v": m["vertices"], "uv": m["uvs"], "i": m["indices"], "d": 0.45}))
	var top := l.position - l.size * 0.5 * l.scale
	var k := l.size.x * l.scale.x / 200.0
	var body := RbBone.new()
	body.id = doc.new_id()
	body.name = "Тело"
	body.position = top + Vector2(100, 214) * k
	body.angle = -PI / 2
	body.length = 64 * k
	undo.push(RbRigCommands.AddBone.new(body))
	var head := RbBone.new()
	head.id = doc.new_id()
	head.name = "Голова"
	head.parent_id = body.id
	head.position = Vector2(64 * k, 0)
	head.length = 80 * k
	undo.push(RbRigCommands.AddBone.new(head))
	_refresh()
	rig_tools.selected_bone = head.id
	rig_tools.bind_auto(l)
	if _args.has("pose"):
		doc.rig.get_bone(head.id).pose_angle = -0.35
		doc.notify(&"bones")


## --demo_anim: ключи на костях демо-лягушки (кадры 0, 12, 24) и прозрачность слоя, кадр 12.
func _add_demo_anim() -> void:
	for id in doc.rig.bones:
		var b := doc.rig.get_bone(id)
		if b.parent_id != 0:
			var tk := RbAnimation.track_key("bone", id, &"pose_angle")
			doc.anim.set_key(tk, 0, 0.0, "smooth")
			doc.anim.set_key(tk, 12, -0.35, "smooth")
			doc.anim.set_key(tk, 24, 0.25, "smooth")
		else:
			var to := RbAnimation.track_key("bone", id, &"pose_offset")
			doc.anim.set_key(to, 0, Vector2.ZERO, "bounce")
			doc.anim.set_key(to, 12, Vector2(0, -30), "bounce")
			doc.anim.set_key(to, 24, Vector2.ZERO, "bounce")
			var ts := RbAnimation.track_key("bone", id, &"pose_scale")
			doc.anim.set_key(ts, 0, Vector2.ONE, "step")
			doc.anim.set_key(ts, 12, Vector2(1.0, 1.08), "step")
			doc.anim.set_key(ts, 24, Vector2.ONE, "step")
	if selected_id != 0:
		var to2 := RbAnimation.track_key("layer", selected_id, &"opacity")
		doc.anim.set_key(to2, 0, 1.0, "linear")
		doc.anim.set_key(to2, 24, 0.7, "linear")
	_set_frame(12)


## --demo_params: три параметра; у «Моргания» форма в точке 1 (кости наклоняются).
func _add_demo_params() -> void:
	var f := RbFormEdit.empty_form()
	for id in doc.rig.bones:
		if doc.rig.get_bone(id).parent_id != 0:
			RbFormEdit.set_bone_prop(f, id, "angle", 0.45)
	var defs := [["Моргание", 0.0, 1.0, 0.6], ["Поворот головы", -1.0, 1.0, 0.0], ["Улыбка", 0.0, 1.0, 0.0], ["Очень длинное название параметра для проверки переполнения", 0.0, 1.0, 0.3]]
	for i in defs.size():
		var p := RbParams.Param.new()
		p.id = doc.new_id()
		p.name = defs[i][0]
		p.min_v = defs[i][1]
		p.max_v = defs[i][2]
		p.value = defs[i][3]
		if i == 0:
			p.forms[1.0] = f
		doc.params.params[p.id] = p
	doc.notify(&"params")


## --demo_con: констрейны на выделенной кости (предел, копирование, динамика).
func _add_demo_con() -> void:
	var b := doc.rig.get_bone(rig_tools.selected_bone)
	if b == null:
		return
	var from := 0
	for id in doc.rig.bones:
		if id != b.id:
			from = id
	b.constraints = {"limit": {"min": -0.6, "max": 0.8}, "dynamics": {"spring": 0.5, "damping": 0.4, "torque": 0.2}}
	if from != 0:
		b.constraints["copy"] = {"from": from, "angle": 0.5, "move": 0.0, "scale": 0.0}
	doc.notify(&"bones")


## --demo_pins: у лягушки сетка и три пина (один привязан к кости, один смещён).
func _add_demo_pins() -> void:
	await get_tree().process_frame
	var l := doc.get_layer(selected_id) if selected_id != 0 else null
	if l == null or l.is_group():
		return
	if l.mesh_vertices.size() <= 4:
		_mesh_generate(l, 0.4)
	var pins: Array = []
	for rel in [Vector2(-0.32, -0.12), Vector2(0.32, -0.12), Vector2(0.0, 0.3)]:
		var v := RbPins.nearest_vertex(l.mesh_vertices, rel * l.size)
		pins.append(RbPins.new_pin(doc.new_id(), v, 0))
	if rig_tools.selected_bone != 0:
		pins[2]["bone"] = rig_tools.selected_bone
	undo.push(RbRigCommands.SetPins.new(l.id, [], pins, "Пины"))
	undo.end_gesture()
	pin_tools.selected = int(pins[0]["id"])
	var tk := RbAnimation.track_key("pin", int(pins[1]["id"]), &"offset")
	doc.anim.set_key(tk, 0, Vector2(0.06, -0.1) * l.size, "smooth")
	doc.anim.apply_frame(doc, doc.shown_frame())
	doc.notify(&"pins")


## --demo_fx[=rim,grad,cc]: эффекты на выделенном слое.
func _add_demo_fx() -> void:
	var l := doc.get_layer(selected_id) if selected_id != 0 else null
	if l == null or l.is_group():
		return
	var which: PackedStringArray = str(_args["demo_fx"]).split(",") if _args["demo_fx"] != "1" else PackedStringArray(["rim", "grad", "cc"])
	var fx := {}
	if which.has("rim"):
		fx["rim"] = RbFxSheet.DEFAULT_RIM.duplicate(true)
	if which.has("grad"):
		fx["grad"] = RbFxSheet.DEFAULT_GRAD.duplicate(true)
	if which.has("cc"):
		fx["cc"] = RbFxSheet.DEFAULT_CC.duplicate(true)
		fx["cc"]["saturation"] = 1.3
	l.effects = fx
	doc.notify(&"transform")


func _add_demo() -> void:
	_import_image(RbIcons.frog_image(800), "Фроги")


# ---------------- инструменты ----------------

func _set_mode(i: int) -> void:
	if exporting and i != 3:
		seg_buttons[3].button_pressed = true
		return
	if form_tools and form_tools.active and i != 1:
		_finish_form()  # из правки формы выходим «Готово»
	mode = i
	var c: Color = RbTheme.MODE_COLORS[i]
	RbTheme.set_mode_color(c)
	view.set_mode_color(c)
	if i != 1:
		_stop_playback()
	if timeline:
		timeline.set_mode_color(c)
		_update_timeline_visibility()
	if i == 3 and doc:
		if export_sheet.doc != doc:
			export_sheet.bind(doc)
		else:
			export_sheet.sync_doc()
		_show_panel(export_sheet, false)
	elif export_sheet and export_sheet.visible:
		_hide_panel(export_sheet, false)
	if i == 2 and doc:
		_show_hint("fx", "HINT_FX")
	elif _tip_id == "fx":
		tip_holder.visible = false
	if params_sheet and params_sheet.visible:
		_update_params_hint()
	_update_tool_buttons()
	if doc:
		# Риг показывает кадр 0 (базовая поза), Анимация — кадр, на котором остановились
		doc.rig_mode = i == 0
		doc.anim.apply_frame(doc, doc.shown_frame())
		_refresh()


## Инструменты режима (при правке формы свой набор): лишние кнопки прячем, неподходящий текущий меняем на первый.
func _update_tool_buttons() -> void:
	rail.visible = mode != 3  # в Экспорте инструментов нет, превью на всю ширину
	var allowed: Array = FORM_TOOLS if form_tools.active else MODE_TOOLS[mode]
	for k in tool_buttons:
		tool_buttons[k].visible = allowed.has(k)
	if not allowed.has(tool):
		tool_buttons[allowed[0]].button_pressed = true
		_set_tool(allowed[0])
	_update_rail_columns()


func _set_tool(t: String) -> void:
	if tool == "mesh" and t != "mesh":
		_mesh_drag_reset()
		if _tip_id == "mesh":
			tip_holder.visible = false  # подсказка про сетку нужна только в этом инструменте
	if tool == "pins" and t != "pins" and _tip_id == "pins":
		tip_holder.visible = false
	tool = t
	view.hand_mode = t == "hand"
	view.long_press_enabled = (t == "mesh" and not form_tools.active) or t == "pins"
	view.double_tap_enabled = t != "mesh" and t != "pins"  # тапы по сетке и пинам идут подряд, это не «вписать холст»
	if t == "pose":
		_show_hint("pose_ik", "HINT_POSE")  # другой id: текст про IK стоит показать и тем, кто закрыл старую подсказку
	elif t in ["bone", "weights", "pins"]:
		_show_hint(t, "HINT_" + t.to_upper())
	if t == "mesh":
		_show_hint("mesh", "MESH_HINT")
		if doc and _mesh_layer() == null:
			_toast(tr("MESH_PICK"))
	if doc:
		_update_selection()


func _hit(w: Vector2) -> int:
	if pose == null:
		return 0
	for i in range(pose.order.size() - 1, -1, -1):
		var id: int = pose.order[i]
		var lp: RbEvaluator.LayerPose = pose.layers[id]
		if not lp.visible:
			continue
		var l := doc.get_layer(id)
		var local := lp.world.affine_inverse() * w
		var uv := local / l.size + Vector2(0.5, 0.5)
		if uv.x < 0.0 or uv.y < 0.0 or uv.x >= 1.0 or uv.y >= 1.0:
			continue
		var img: Image = doc.images.get(l.image_id)
		if img == null:
			continue
		var px := Vector2i(uv * l.size)
		if img.get_pixelv(px.clamp(Vector2i.ZERO, img.get_size() - Vector2i.ONE)).a > 0.1:
			return id
	return 0


func _on_tap(w: Vector2) -> void:
	if tool in RIG_TOOLS:
		rig_tools.tap(w)
		return
	if tool == "pins":
		pin_tools.tap(w)
		return
	if tool == "layer":
		var tip := view.light_tip()
		if mode == 2 and tip != Vector2.INF and (view.view * w).distance_to(tip) <= 32.0:
			return  # тап по ручке стрелки света не снимает выделение слоя
		selected_id = _hit(w)
		_update_selection()
	elif tool == "mesh":
		if form_tools.active:
			var top := _hit(w)  # правка формы: точки не добавляются, тап только выбирает слой
			if top != 0 and not doc.get_layer(top).is_group():
				selected_id = top
				_update_selection()
		else:
			_mesh_tap(w)


func _on_drag_begin(w: Vector2) -> void:
	_drag_id = 0
	_xf_mode = ""
	_light_drag = false
	if tool in RIG_TOOLS:
		rig_tools.drag_begin(w)
		return
	if tool == "pins":
		pin_tools.drag_begin(w)
		return
	if tool == "mesh":
		if form_tools.active:
			form_tools.mesh_begin(w)
		else:
			_mesh_drag_begin(w)
		return
	if tool != "layer":
		return
	if mode == 2:
		# Композинг: слой не двигаем, тянуть можно только стрелку света
		var tip := view.light_tip()
		_light_drag = tip != Vector2.INF and (view.view * w).distance_to(tip) <= 32.0
		return
	var s := view.view * w
	if selected_id != 0 and view.selection.size() == 4 and view.show_gizmo:
		if s.distance_to(view.rotate_handle()) < 26.0:
			_xf_mode = "rotate"
		else:
			for p in view.selection_screen():
				if s.distance_to(p) < 26.0:
					_xf_mode = "scale"
	var id := selected_id if _xf_mode != "" else _hit(w)
	if id == 0:
		id = selected_id  # тянуть за пустое место двигает выделенный слой
	var l := doc.get_layer(id) if id else null
	if l == null:
		return
	if _xf_mode == "":
		_xf_mode = "move"
	selected_id = id
	_drag_id = id
	_drag_start_world = w
	_drag_start_pos = l.position
	_xf_start_scale = l.scale
	_xf_start_rot = l.rotation
	_xf_center = (pose.layers[id] as RbEvaluator.LayerPose).world.origin if pose.layers.has(id) else w
	_drag_pushed = false
	_update_selection()


func _parent_world(l: RbLayer) -> Transform2D:
	if l.parent_id != 0 and pose.layers.has(l.parent_id):
		return (pose.layers[l.parent_id] as RbEvaluator.LayerPose).world
	return Transform2D.IDENTITY


## Стрелка света тянется за пальцем: мировой угол от центра слоя, магнит к шагу 15°.
func _light_move(w: Vector2) -> void:
	if view.light_arrow.is_empty():
		return
	var a := (w - (view.light_arrow["c"] as Vector2)).angle()
	var step := deg_to_rad(15.0)
	var near := roundf(a / step) * step
	if absf(a - near) < deg_to_rad(3.0):
		if absf(fx_sheet.rim_angle() - near) > 0.0001:
			_vibrate(8)
		a = near
	fx_sheet.set_rim_angle(a, false)


func _on_drag_move(w: Vector2) -> void:
	if tool in RIG_TOOLS:
		rig_tools.drag_move(w)
		return
	if tool == "pins":
		pin_tools.drag_move(w)
		return
	if tool == "mesh":
		if form_tools.active:
			form_tools.mesh_move(w)
		else:
			_mesh_drag_move(w)
		return
	if _light_drag:
		_light_move(w)
		return
	if _drag_id == 0:
		return
	var l := doc.get_layer(_drag_id)
	if l == null:
		return
	match _xf_mode:
		"move":
			var d := _parent_world(l).affine_inverse().basis_xform(w - _drag_start_world)
			_push_prop(l, &"position", _drag_start_pos + d)
		"scale":
			var k := (w - _xf_center).length() / maxf((_drag_start_world - _xf_center).length(), 0.001)
			k = maxf(k, 0.02)
			if absf(k - 1.0) < 0.03:
				k = 1.0  # магнит к исходному размеру
			_push_prop(l, &"scale", _xf_start_scale * k)
		"rotate":
			var a := _xf_start_rot + (w - _xf_center).angle() - (_drag_start_world - _xf_center).angle()
			var step := PI / 4.0
			var near := roundf(a / step) * step
			if absf(a - near) < deg_to_rad(4.0):
				if absf(l.rotation - near) > 0.0001:
					_vibrate(10)
				a = near
			_push_prop(l, &"rotation", a)


func _push_prop(l: RbLayer, prop: StringName, v: Variant) -> void:
	_drag_pushed = true
	if mode == 1:
		_key_layer(l, prop, v, true)
		return
	var track := RbAnimation.track_key("layer", l.id, prop)
	if doc.anim.tracks.has(track):
		# свойство анимировано: в Риге правим базовую позу = ключ кадра 0
		l.set_prop(prop, v)
		undo.push(RbAnimCommands.SetKey.new(track, 0, v), false, true)
		return
	var old: Variant = l.get_prop(prop)
	l.set_prop(prop, v)
	undo.push(RbCommands.SetLayerProp.new(l.id, prop, old, v), true, true)
	doc.notify(&"transform")


## Автоключ слоя на текущем кадре (режим Анимация). Стартовый ключ на кадре 0 ставит сама команда.
func _key_layer(l: RbLayer, prop: StringName, v: Variant, mergeable: bool) -> void:
	var old: Variant = l.get_prop(prop)
	l.set_prop(prop, v)
	undo.push(RbAnimCommands.SetKeyAuto.new(RbAnimation.track_key("layer", l.id, prop), doc.current_frame, v, old), false, mergeable)


func _on_drag_end() -> void:
	if tool in RIG_TOOLS:
		rig_tools.drag_end()
		return
	if tool == "pins":
		pin_tools.drag_end()
		return
	if tool == "mesh":
		if form_tools.active:
			form_tools.mesh_end()
		else:
			_mesh_drag_end()
		return
	_light_drag = false
	undo.end_gesture()
	_drag_id = 0


func _on_drag_cancel() -> void:
	if tool in RIG_TOOLS:
		rig_tools.drag_cancel()
		return
	if tool == "pins":
		pin_tools.drag_cancel()
		return
	if tool == "mesh":
		if form_tools.active:
			form_tools.mesh_cancel()
		else:
			_mesh_drag_cancel()
		return
	if _light_drag:
		_light_drag = false
		undo.end_gesture()
		return
	if _drag_id != 0 and _drag_pushed:
		undo.cancel_last()
	undo.end_gesture()
	_drag_id = 0


# ---------------- таймлайн и воспроизведение ----------------

## Таймлайн только в режиме «Анимация». В портрете лист слоя занимает его место, пока открыт.
func _update_timeline_visibility() -> void:
	if timeline == null:
		return
	# лист слоя закрывает таймлайн в портрете; новые панели ещё и в низком ландшафте (иначе вьюпорту остаётся полоска)
	var low_wide := _wide == 1 and get_viewport_rect().size.y < 480.0
	var new_panel := (params_sheet != null and params_sheet.visible) or (bone_sheet != null and bone_sheet.visible) \
			or (fx_sheet != null and fx_sheet.visible)
	var covered := (sheet != null and sheet.visible and _wide != 1) or (new_panel and (_wide != 1 or low_wide))
	var editing_form := form_tools != null and form_tools.active  # правка формы идёт без таймлайна: больше места вьюпорту
	timeline.visible = mode == 1 and not covered and not editing_form
	_update_rail_columns()


## Что показывать в таймлайне: кость (инструмент «Поза»), пин (инструмент «Пины») или выделенный слой.
func _sync_timeline_focus() -> void:
	if timeline == null:
		return
	var kind := ""
	var id := 0
	if tool == "pose" and doc.rig.get_bone(rig_tools.selected_bone):
		kind = "bone"
		id = rig_tools.selected_bone
	elif tool == "pins" and not doc.rig.find_pin(pin_tools.selected).is_empty():
		kind = "pin"
		id = pin_tools.selected
	elif selected_id != 0 and doc.get_layer(selected_id):
		kind = "layer"
		id = selected_id
	timeline.set_focus(kind, id)


func _toggle_play() -> void:
	if playing:
		_stop_playback()
	else:
		_start_playback()


func _start_playback() -> void:
	if doc == null or doc.frame_count < 2:
		return
	if mode != 1 and mode != 3:  # в Экспорте вьюпорт = превью, играем на месте
		seg_buttons[1].button_pressed = true
		_set_mode(1)
	if not loop_play and doc.current_frame >= doc.frame_count - 1:
		_set_frame(0)
	playing = true
	_play_acc = 0.0
	OS.low_processor_usage_mode = false
	set_process(true)
	_update_play_ui()


func _stop_playback() -> void:
	if not playing:
		return
	playing = false
	set_process(false)
	OS.low_processor_usage_mode = true
	_update_play_ui()
	_update_onion()


func _update_play_ui() -> void:
	btn_play.icon = RbIcons.tex("pause" if playing else "play")
	timeline.set_playing(playing)


func _process(delta: float) -> void:
	if not playing or doc == null:
		return
	_play_acc += delta
	var step := 1.0 / float(maxi(doc.fps, 1))
	var adv := int(_play_acc / step)
	if adv <= 0:
		return
	_play_acc -= float(adv) * step
	var f := doc.current_frame + adv
	if f >= doc.frame_count:
		if loop_play:
			f = f % doc.frame_count
		else:
			_set_frame(doc.frame_count - 1)
			_stop_playback()
			return
	_set_frame(f)


## Текущий кадр: значения дорожек записываются в кости и слои, кадр рисуется.
func _set_frame(f: int) -> void:
	doc.current_frame = clampi(f, 0, doc.frame_count - 1)
	doc.anim.apply_frame(doc, doc.current_frame)
	_refresh()


func _on_timeline_frame(f: int) -> void:
	_stop_playback()
	_set_frame(f)
	if sheet.visible and doc.get_layer(selected_id):
		sheet.show_layer(doc, selected_id)  # ползунок прозрачности показывает значение этого кадра


func _on_timeline_object(kind: String, id: int) -> void:
	if kind == "param":
		if not params_sheet.visible:
			_toggle_params()
		return
	if kind == "pin":
		var info := RbTimelineLogic.pin_info(doc, id)
		if info[0] == 0:
			return
		selected_id = info[0]
		pin_tools.selected = id
		tool_buttons["pins"].button_pressed = true
		_set_tool("pins")
	elif kind == "bone":
		rig_tools.selected_bone = id
		tool_buttons["pose"].button_pressed = true
		_set_tool("pose")
	else:
		selected_id = id
		tool_buttons["layer"].button_pressed = true
		_set_tool("layer")
	_update_selection()


func _interp_menu(anchor: Control) -> void:
	var refs := timeline.selected_refs()
	if refs.is_empty():
		return
	var cur := RbTimelineLogic.common_interp(doc.anim, refs)
	var items := []
	for i in RbAnimation.INTERPS:
		var nm: String = i
		items.append(["check" if nm == cur else "dot_empty", "INTERP_" + nm.to_upper(), func() -> void:
			undo.push(RbAnimCommands.SetInterp.new(refs, nm))
			undo.end_gesture()])
	_open_menu(anchor, items)


## Длительность: число кадров и частота.
func _timing_dialog() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var fields: Array[LineEdit] = []
	for spec in [["TL_FRAMES", doc.frame_count], ["TL_FPS", doc.fps]]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var lb := Label.new()
		lb.theme_type_variation = "LabelDim"
		lb.text = spec[0]
		lb.custom_minimum_size.x = 120
		row.add_child(lb)
		var le := LineEdit.new()
		le.text = str(spec[1])
		le.custom_minimum_size.y = 44
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
		le.select_all_on_focus = true
		row.add_child(le)
		box.add_child(row)
		fields.append(le)
	var ok := Callable(func() -> void:
		var n := clampi(int(fields[0].text) if fields[0].text.is_valid_int() else doc.frame_count, 2, 600)
		var r := clampi(int(fields[1].text) if fields[1].text.is_valid_int() else doc.fps, 1, 60)
		if n != doc.frame_count or r != doc.fps:
			undo.push(RbAnimCommands.SetTiming.new(n, r))
			undo.end_gesture()
		_close_overlay())
	_dialog("TL_TIMING_TITLE", "", box, "ACT_SAVE", ok)
	fields[0].grab_focus.call_deferred()


# ---------------- сетка слоя ----------------

## Выделенный растровый слой, пригодный для правки сетки.
func _mesh_layer() -> RbLayer:
	var l := doc.get_layer(selected_id) if selected_id != 0 else null
	if l == null or l.is_group() or pose == null or not pose.layers.has(l.id):
		return null
	return l


func _mesh_world(l: RbLayer) -> Transform2D:
	return (pose.layers[l.id] as RbEvaluator.LayerPose).world


func _mesh_dict(l: RbLayer) -> Dictionary:
	return {"vertices": l.mesh_vertices, "uvs": l.mesh_uvs, "indices": l.mesh_indices, "size": l.size}


## Ближайшая к точке w (координаты холста) вершина в радиусе radius dp на экране, иначе -1.
func _mesh_pick(l: RbLayer, w: Vector2, radius := MESH_PICK_DP) -> int:
	var lw := _mesh_world(l)
	var s := view.view * w
	var best := radius * radius
	var bi := -1
	for i in l.mesh_vertices.size():
		var d := (view.view * (lw * l.mesh_vertices[i])).distance_squared_to(s)
		if d <= best:
			best = d
			bi = i
	return bi


## Одним шагом истории заменить сетку слоя результатом RbMeshGen.
func _mesh_commit(l: RbLayer, m: Dictionary, density: float) -> void:
	var new_s := {"v": m["vertices"], "uv": m["uvs"], "i": m["indices"], "d": density}
	undo.push(RbCommands.SetMesh.new(l.id, RbCommands.SetMesh.snap(l), new_s))
	undo.end_gesture()


func _mesh_generate(l: RbLayer, density: float) -> void:
	var img: Image = doc.images.get(l.image_id)
	if img == null:
		_toast(tr("MESH_FAIL"))
		return
	_mesh_commit(l, RbMeshGen.generate(img, density), density)


func _mesh_tap(w: Vector2) -> void:
	var l := _mesh_layer()
	if l == null:
		var id := _hit(w)
		if id != 0 and not doc.get_layer(id).is_group():
			selected_id = id
			_update_selection()
		else:
			_toast(tr("MESH_PICK"))
		return
	if _mesh_pick(l, w, MESH_TAP_DP) >= 0:
		return  # тап по точке ничего не делает: её двигают, а долгим нажатием удаляют
	var r := RbMeshGen.add_point(_mesh_dict(l), _mesh_world(l).affine_inverse() * w)
	if (r["vertices"] as PackedVector2Array).size() <= l.mesh_vertices.size():
		var other := _hit(w)  # мимо фигуры: если там другой слой, переключиться на него
		if other != 0 and other != l.id and not doc.get_layer(other).is_group():
			selected_id = other
			_update_selection()
		else:
			_toast(tr("MESH_NO_ADD"))
		return
	_mesh_commit(l, r, l.mesh_density)
	_vibrate(12)


func _on_long_press(w: Vector2) -> void:
	if tool == "pins":
		pin_tools.long_press(w)
		return
	if tool != "mesh" or form_tools.active:
		return
	var l := _mesh_layer()
	if l == null:
		return
	var i := _mesh_pick(l, w)
	if i < 0:
		return
	var r := RbMeshGen.remove_point(_mesh_dict(l), i)
	if (r["vertices"] as PackedVector2Array).size() >= l.mesh_vertices.size():
		_toast(tr("MESH_NO_REMOVE"))
		_vibrate(12)
		return
	_mesh_commit(l, r, l.mesh_density)
	_vibrate(40)


func _mesh_drag_begin(w: Vector2) -> void:
	_mesh_drag_reset()
	var l := _mesh_layer()
	if l == null:
		return
	var i := _mesh_pick(l, w)
	if i < 0:
		return
	_mesh_drag_id = l.id
	_mesh_drag_index = i
	_mesh_start = RbCommands.SetMesh.snap(l)
	_mesh_work = _mesh_dict(l)
	# палец держит точку со сдвигом, без рывка к центру касания
	_mesh_drag_offset = l.mesh_vertices[i] - _mesh_world(l).affine_inverse() * w
	_vibrate(8)
	_update_mesh_overlay()


func _mesh_drag_move(w: Vector2) -> void:
	if _mesh_drag_id == 0:
		return
	var l := doc.get_layer(_mesh_drag_id)
	if l == null:
		return
	var target := _mesh_world(l).affine_inverse() * w + _mesh_drag_offset
	var cur: Vector2 = (_mesh_work["vertices"] as PackedVector2Array)[_mesh_drag_index]
	# недопустимый сдвиг (точка за границей, пересечение) режем пополам: точка упирается в стенку, а не залипает
	for k in 3:
		var p := cur.lerp(target, 1.0 / float(1 << k))
		var r := RbMeshGen.move_point(_mesh_work, _mesh_drag_index, p)
		if (r["vertices"] as PackedVector2Array)[_mesh_drag_index] != cur:
			_mesh_work = r
			l.mesh_vertices = r["vertices"]
			l.mesh_uvs = r["uvs"]
			l.mesh_indices = r["indices"]
			doc.notify(&"mesh")
			break


func _mesh_drag_end() -> void:
	var l := doc.get_layer(_mesh_drag_id) if _mesh_drag_id != 0 else null
	if l:
		var now := RbCommands.SetMesh.snap(l)
		if now["v"] != _mesh_start["v"]:
			undo.push(RbCommands.SetMesh.new(l.id, _mesh_start, now), true)
	undo.end_gesture()
	_mesh_drag_reset()


func _mesh_drag_cancel() -> void:
	var l := doc.get_layer(_mesh_drag_id) if _mesh_drag_id != 0 else null
	if l:
		RbCommands.SetMesh.apply_state(l, _mesh_start)
		doc.notify(&"mesh")
	undo.end_gesture()
	_mesh_drag_reset()


func _mesh_drag_reset() -> void:
	_mesh_drag_id = 0
	_mesh_drag_index = -1
	_mesh_work = {}
	_mesh_start = {}
	if view:
		view.mesh_focus = Vector2.INF
		view.refresh_overlay()


## Каркас выделенного слоя во вьюпорт: рёбра с двумя треугольниками тонкие, с одним (граница) толстые.
func _update_mesh_overlay() -> void:
	view.mesh_lines = PackedVector2Array()
	view.mesh_outline = PackedVector2Array()
	view.mesh_points = PackedVector2Array()
	view.mesh_edge_points = PackedVector2Array()
	view.mesh_focus = Vector2.INF
	view.mesh_dim = tool == "pins"
	if tool != "mesh" and tool != "pins":
		return
	var l := _mesh_layer()
	if l == null:
		return
	var lw := _mesh_world(l)
	# пины и правка формы показывают сетку такой, какой её видно сейчас (с позой и формами)
	var verts := l.mesh_vertices
	if tool == "pins" or form_tools.active:
		verts = (pose.layers[l.id] as RbEvaluator.LayerPose).vertices
	var tris := l.mesh_indices
	var m := verts.size()
	var edges := {}  # ключ ребра -> [a, b, сколько треугольников]
	for k in range(0, tris.size() - 2, 3):
		for e in 3:
			var a := tris[k + e]
			var b := tris[k + (e + 1) % 3]
			if a >= m or b >= m:
				continue
			var key := mini(a, b) * m + maxi(a, b)
			if edges.has(key):
				edges[key][2] += 1
			else:
				edges[key] = [a, b, 1]
	var on_edge := PackedByteArray()
	on_edge.resize(m)
	on_edge.fill(0)
	var lines := PackedVector2Array()
	var outline := PackedVector2Array()
	for e: Array in edges.values():
		var pa := lw * verts[e[0]]
		var pb := lw * verts[e[1]]
		if e[2] == 1:
			outline.append(pa)
			outline.append(pb)
			on_edge[e[0]] = 1
			on_edge[e[1]] = 1
		else:
			lines.append(pa)
			lines.append(pb)
	var inner := PackedVector2Array()
	var border := PackedVector2Array()
	for i in m:
		if on_edge[i] == 1:
			border.append(lw * verts[i])
		else:
			inner.append(lw * verts[i])
	view.mesh_lines = lines
	view.mesh_outline = outline
	view.mesh_points = inner
	view.mesh_edge_points = border
	if _mesh_drag_id == l.id and _mesh_drag_index >= 0 and _mesh_drag_index < m:
		view.mesh_focus = lw * verts[_mesh_drag_index]
	elif form_tools.active and form_tools.dragged_layer() == l.id and form_tools.dragged_vertex() >= 0 and form_tools.dragged_vertex() < m:
		view.mesh_focus = lw * verts[form_tools.dragged_vertex()]


func _on_undo() -> void:
	_vibrate()
	if form_tools.active:
		_toast(tr("FORM_UNDO_BLOCK"))  # правка формы ещё не в истории
		return
	_toast(tr("TOAST_UNDO") if undo.undo() else tr("TOAST_NOTHING_UNDO"))


func _on_redo() -> void:
	_vibrate()
	if form_tools.active:
		_toast(tr("FORM_UNDO_BLOCK"))
		return
	_toast(tr("TOAST_REDO") if undo.redo() else tr("TOAST_NOTHING_REDO"))


func _vibrate(ms := 25) -> void:
	if settings.vibration and OS.has_feature("mobile"):
		Input.vibrate_handheld(ms)


# ---------------- подсказки, тосты, меню ----------------

func _show_hint(id: String, key: String) -> void:
	if not settings.hints or settings.dismissed_hints.has(id) or _args.has("nohint"):
		return
	_tip_id = id
	tip_label.text = key
	tip_holder.visible = true
	_update_empty_state()


func _dismiss_tip() -> void:
	tip_holder.visible = false
	if _tip_id != "" and not settings.dismissed_hints.has(_tip_id):
		settings.dismissed_hints.append(_tip_id)
		if not _no_save:
			settings.save_cfg()


func _toast(text: String, hold := 1.6) -> void:
	toast_label.text = text
	# ширина по тексту, но не шире вьюпорта: иначе перенос ломается по буквам
	var font := toast_label.get_theme_font("font")
	var fs := toast_label.get_theme_font_size("font_size")
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 2.0
	toast_label.custom_minimum_size.x = minf(tw, maxf(view.size.x - 64.0, 120.0))
	toast.visible = true
	toast.modulate.a = 1.0
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(hold)
	_toast_tween.tween_property(toast, "modulate:a", 0.0, 0.3)
	_toast_tween.tween_callback(func() -> void: toast.visible = false)


func _soon() -> void:
	_toast(tr("TOAST_SOON"))


func _close_overlay() -> void:
	for c in overlay_layer.get_children():
		c.queue_free()
	overlay_layer.visible = false


func _open_overlay() -> void:
	_close_overlay()
	overlay_layer.visible = true
	overlay_layer.mouse_filter = Control.MOUSE_FILTER_STOP


## items: [[иконка, ключ, callable], ...]
func _open_menu(anchor: Control, items: Array) -> void:
	_open_menu_rect(anchor.get_global_rect(), items)


## Меню у прямоугольника на экране (кнопка или точка касания). Длинный список прокручивается.
func _open_menu_rect(ar: Rect2, items: Array) -> void:
	_open_overlay()
	var panel := PanelContainer.new()
	panel.theme_type_variation = "Menu"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	for it in items:
		var b := Button.new()
		b.theme_type_variation = "MenuItem"
		b.icon = RbIcons.tex(it[0])
		b.text = it[1]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(240, 48)
		b.focus_mode = Control.FOCUS_NONE
		var cb: Callable = it[2]
		b.pressed.connect(func() -> void:
			_close_overlay()
			cb.call())
		v.add_child(b)
	var vs := get_viewport_rect().size
	# меню шире 240 dp под самый длинный пункт, но не шире экрана (тогда уже многоточие)
	if v.get_combined_minimum_size().x > vs.x - 40.0:
		for b in v.get_children():
			(b as Button).clip_text = true
			(b as Button).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.custom_minimum_size.x = vs.x - 40.0
	var full := v.get_combined_minimum_size().y + 12.0
	if full > vs.y - 16.0:
		var sc := ScrollContainer.new()
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sc.add_child(v)
		sc.custom_minimum_size = Vector2(v.get_combined_minimum_size().x, vs.y - 28.0)
		panel.add_child(sc)
	else:
		panel.add_child(v)
	overlay_layer.add_child(panel)
	var sz := panel.get_combined_minimum_size()
	var x := ar.position.x
	if ar.get_center().x > vs.x * 0.5:
		x = ar.end.x - sz.x
	var y := ar.end.y + 6.0
	if y + sz.y > vs.y - 8.0 and ar.position.y - sz.y - 6.0 >= 8.0:
		y = ar.position.y - sz.y - 6.0  # внизу места нет: открыть над кнопкой
	panel.position = Vector2(clampf(x, 8.0, vs.x - sz.x - 8.0), clampf(y, 8.0, vs.y - sz.y - 8.0))
	panel.size = sz


func _menu_project() -> void:
	_open_menu(btn_folder, [
		["plus", "MENU_NEW", _new_project],
		["folder", "MENU_OPEN", _open_projects],
		["import", "MENU_IMPORT", _on_import],
		["frog", "MENU_DEMO", _add_demo],
	])


func _menu_more() -> void:
	var items := [["fit", "MENU_FIT", view.fit_canvas]]
	if mode == 1:
		items.append(["eye", tr("MENU_ONION") if settings.onion == 0 else tr("MENU_ONION_ON") % settings.onion, _onion_menu])
	_open_menu(btn_more, items + [

		["gauge", "MENU_BENCH", _run_bench],
		["gear", "MENU_SETTINGS", _open_settings],
		["info", "MENU_ABOUT", func() -> void: _dialog("ABOUT_TITLE", tr("ABOUT_TEXT") % VERSION)],
	])


## Окно по центру: заголовок, содержимое, кнопка «Понятно».
func _dialog(title_key: String, text: String, body: Control = null, ok_key := "OK", ok_cb := Callable()) -> void:
	_open_overlay()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_layer.add_child(center)
	var p := PanelContainer.new()
	p.theme_type_variation = "Menu"
	p.custom_minimum_size.x = minf(360.0, get_viewport_rect().size.x - 32.0)
	center.add_child(p)
	var m := _margins(12, 10, 12, 8)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	m.add_child(v)
	var t := Label.new()
	t.theme_type_variation = "LabelTitle"
	t.text = title_key
	v.add_child(t)
	if text != "":
		var l := Label.new()
		l.theme_type_variation = "LabelDim"
		l.text = text
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(l)
	if body:
		v.add_child(body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(row)
	row.add_theme_constant_override("separation", 8)
	if ok_cb.is_valid():
		var cancel := RbUi.text_btn("SecondaryButton", "", "ACT_CANCEL", _close_overlay, 44)
		cancel.custom_minimum_size.x = 112
		row.add_child(cancel)
	var ok := RbUi.text_btn("PrimaryButton", "", ok_key, ok_cb if ok_cb.is_valid() else _close_overlay, 44)
	ok.custom_minimum_size.x = 120
	row.add_child(ok)


func _open_projects() -> void:
	var list := _list_projects()
	var body: Control
	if list.is_empty():
		_dialog("OPEN_TITLE", tr("OPEN_EMPTY"))
		return
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = minf(list.size() * 50.0, get_viewport_rect().size.y * 0.5)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)
	for p in list:
		var b := Button.new()
		b.theme_type_variation = "MenuItem"
		b.icon = RbIcons.tex("folder")
		b.text = p["name"]
		b.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.custom_minimum_size.y = 48
		b.focus_mode = Control.FOCUS_NONE
		var path: String = p["path"]
		b.pressed.connect(func() -> void:
			_close_overlay()
			_open_path(path))
		v.add_child(b)
	body = scroll
	_dialog("OPEN_TITLE", "", body)


# ---------------- панели: слои, настройки слоя, настройки ----------------

func _build_panels() -> void:
	layers_panel = RbLayersPanel.new()
	layers_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layers_panel.visible = false
	view.add_child(layers_panel)
	layers_panel.picked.connect(func(id: int) -> void:
		selected_id = id
		layers_panel.selected_id = id
		layers_panel.rebuild()
		_update_selection())
	layers_panel.visibility_toggled.connect(func(id: int) -> void:
		var l := doc.get_layer(id)
		if mode == 1:
			_key_layer(l, &"visible", not l.visible, false)
			undo.end_gesture()
		else:
			undo.push(RbCommands.SetLayerProp.new(id, &"visible", l.visible, not l.visible)))
	layers_panel.closed.connect(_toggle_layers)
	layers_panel.import_requested.connect(_on_import)
	layers_panel.group_requested.connect(func() -> void: _layer_action("group", null))

	timeline = RbTimeline.new()
	timeline.visible = false
	main_col.add_child(timeline)  # в ландшафте _relayout переносит его в колонку вьюпорта
	timeline.frame_requested.connect(_on_timeline_frame)
	timeline.play_toggled.connect(_toggle_play)
	timeline.loop_toggled.connect(func(on: bool) -> void: loop_play = on)
	timeline.set_loop(loop_play)
	timeline.timing_requested.connect(_timing_dialog)
	timeline.keys_delete.connect(func(refs: Array) -> void:
		undo.push(RbAnimCommands.RemoveKeys.new(refs))
		undo.end_gesture())
	timeline.keys_move.connect(func(refs: Array, d: int) -> void:
		undo.push(RbAnimCommands.MoveKeys.new(refs, d))
		undo.end_gesture())
	timeline.keys_paste.connect(func(entries: Array) -> void:
		undo.push(RbAnimCommands.PasteKeys.new(entries))
		undo.end_gesture())
	timeline.interp_menu_requested.connect(_interp_menu)
	timeline.object_picked.connect(_on_timeline_object)
	timeline.haptic.connect(_vibrate)
	timeline.notice.connect(func(t: String) -> void: _toast(t))

	sheet = RbLayerSheet.new()
	sheet.visible = false
	sheet.shown = _sheet_value
	sheet.action.connect(_layer_action)
	sheet.closed.connect(_close_sheet)

	params_sheet = RbParamsSheet.new()
	params_sheet.visible = false
	params_sheet.closed.connect(func() -> void: _hide_panel(params_sheet))
	params_sheet.value_changed.connect(_on_param_slider)
	params_sheet.add_requested.connect(_param_add)
	params_sheet.menu_requested.connect(_param_menu)

	export_sheet = RbExportSheet.new()
	export_sheet.visible = false
	export_sheet.closed.connect(func() -> void:
		if not exporting:
			seg_buttons[1].button_pressed = true
			_set_mode(1))
	export_sheet.export_requested.connect(_run_export)
	export_sheet.cancel_requested.connect(func() -> void: _export_cancel = true)
	export_sheet.save_requested.connect(_export_save)
	export_sheet.toast.connect(func(t: String) -> void: _toast(t))

	bone_sheet = RbBoneSheet.new()
	bone_sheet.visible = false
	bone_sheet.closed.connect(func() -> void: _hide_panel(bone_sheet))
	bone_sheet.changed.connect(_on_constraints_changed)
	bone_sheet.pick_requested.connect(_on_bone_pick)

	fx_sheet = RbFxSheet.new()
	fx_sheet.visible = false
	fx_sheet.closed.connect(func() -> void: _hide_panel(fx_sheet))
	fx_sheet.changed.connect(_fx_changed)
	fx_sheet.blend_requested.connect(_fx_blend_menu)

	_build_form_banner()

	sel_chip = Button.new()
	sel_chip.theme_type_variation = "SecondaryButton"
	sel_chip.icon = RbIcons.tex("gear")
	sel_chip.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	sel_chip.custom_minimum_size = Vector2(0, 44)
	sel_chip.focus_mode = Control.FOCUS_NONE
	sel_chip.position = Vector2(10, 10)
	sel_chip.visible = false
	sel_chip.pressed.connect(func() -> void:
		if tool in ["bone", "pose"] and doc.rig.get_bone(rig_tools.selected_bone):
			_bone_menu()
		elif mode == 2:
			_open_fx_sheet()
		else:
			_open_sheet())
	view.add_child(sel_chip)


func _toggle_layers() -> void:
	layers_panel.visible = not layers_panel.visible
	btn_layers.add_theme_color_override("icon_normal_color", RbTheme.MODE_COLORS[mode] if layers_panel.visible else RbTheme.C.tx)
	if layers_panel.visible:
		layers_panel.doc = doc
		layers_panel.selected_id = selected_id
		layers_panel.rebuild()
	_update_selection()


func _open_sheet() -> void:
	if selected_id == 0:
		return
	sheet.mesh_available = true
	sheet.bind_status = rig_tools.bind_status(doc.get_layer(selected_id))
	sheet.show_layer(doc, selected_id)
	_show_panel(sheet, false)
	sel_chip.visible = false


func _close_sheet() -> void:
	_hide_panel(sheet)


## Боковые панели занимают одно место: открытая прячет остальные.
func _panels() -> Array:
	return [sheet, params_sheet, bone_sheet, fx_sheet, export_sheet]


func _any_panel() -> bool:
	for p in _panels():
		if p != null and p.visible:
			return true
	return false


func _show_panel(p: Control, refresh := true) -> void:
	for q in _panels():
		if q != null and q != p and q.visible:
			q.visible = false
	_place_panel(p)
	p.visible = true
	_update_params_button()
	_update_timeline_visibility()
	_update_rail_columns()
	if refresh:
		_update_selection()


func _hide_panel(p: Control, refresh := true) -> void:
	p.visible = false
	_update_params_button()
	_update_timeline_visibility()
	_update_rail_columns()
	if refresh:
		_update_selection()


func _update_params_button() -> void:
	if btn_params:
		btn_params.add_theme_color_override("icon_normal_color", RbTheme.MODE_COLORS[mode] if params_sheet.visible else RbTheme.C.tx)


## Узкий экран: панель снизу. Широкий: колонка справа от вьюпорта.
func _place_panel(p: Control) -> void:
	var vs := get_viewport_rect().size
	if p.get_parent():
		p.get_parent().remove_child(p)
	if vs.x >= WIDE_DP:
		content.add_child(p)
		content.move_child(p, 1)
		p.custom_minimum_size = Vector2(minf(340.0, vs.x * 0.36), 0)
		p.size_flags_vertical = Control.SIZE_EXPAND_FILL
		p.add_theme_stylebox_override("panel", RbTheme.sb(RbTheme.C.p1, 6))
	else:
		main_col.add_child(p)
		var hmax := 470.0 if p == export_sheet else 380.0  # у экспорта всё на одном экране, без прокрутки
		p.custom_minimum_size = Vector2(0, clampf(vs.y * (0.56 if p == export_sheet else 0.42), 260.0, hmax))
		p.size_flags_vertical = Control.SIZE_FILL
		var sbx := RbTheme.sb(RbTheme.C.p1)
		sbx.border_color = RbTheme.C.ln
		sbx.border_width_top = 1
		p.add_theme_stylebox_override("panel", sbx)


const DEFRINGE_PX := 2  # «Убрать кайму»: колец по краю, пикселей картинки


## Вариант свитч-группы: правка формы = в форму, Анимация = ключ ступенькой, Риг = значение.
func _pick_switch(l: RbLayer, i: int) -> void:
	if form_tools.active:
		form_tools.set_switch(l.id, i)
	elif mode == 1:
		_key_layer(l, &"switch_index", i, false)
		undo.end_gesture()
	else:
		undo.push(RbCommands.SetLayerProp.new(l.id, &"switch_index", l.switch_index, i))
		undo.end_gesture()
	if sheet.visible:
		sheet.show_layer(doc, l.id)


## Слой по имени (для самопроверок), 0 если нет.
func r_part(nm: StringName) -> int:
	for l: RbLayer in doc.layers.values():
		if l.name == String(nm):
			return l.id
	return 0


## Значения для листа слоя: при правке формы прозрачность и вариант берутся с учётом формы.
func _sheet_value(l: RbLayer, prop: StringName) -> Variant:
	if form_tools.active:
		if prop == &"opacity":
			return clampf(l.opacity + form_tools.opacity_delta(l.id), 0.0, 1.0)
		if prop == &"switch_index":
			var p := form_tools.switch_pick(l.id)
			return p if p >= 0 else l.switch_index
	return l.get_prop(prop)


func _layer_action(act: String, arg: Variant) -> void:
	var l := doc.get_layer(selected_id)
	if l == null:
		return
	match act:
		"opacity":
			var v: float = arg[0]
			if form_tools.active:
				form_tools.set_opacity_delta(l.id, v - l.opacity)  # в форму, запишется по «Готово»
				return
			if mode == 1:
				_key_layer(l, &"opacity", v, true)
			else:
				var old := l.opacity
				l.opacity = v
				undo.push(RbCommands.SetLayerProp.new(l.id, &"opacity", old, v), true, true)
				doc.notify(&"transform")
			if arg[1]:
				undo.end_gesture()
		"blend_menu":
			var items := []
			for m in RbLayer.BLEND_MODES:
				var mm: String = m
				items.append(["check" if mm == l.blend_mode else "dot_empty", "BLEND_" + mm.to_upper(), func() -> void:
					undo.push(RbCommands.SetLayerProp.new(l.id, &"blend_mode", l.blend_mode, mm))
					sheet.rebuild()])
			_open_menu(sheet, items)
		"switch_menu":
			var cur := form_tools.switch_pick(l.id) if form_tools.active else -1
			if cur < 0:
				cur = l.switch_index
			var items := []
			for i in l.children.size():
				var c := doc.get_layer(l.children[i])
				var k := i
				items.append(["check" if i == cur else "dot_empty", c.name if c else "?", func() -> void: _pick_switch(l, k)])
			_open_menu(sheet, items)
			return
		"up", "down":
			if mode == 1 and not form_tools.active:
				# в Анимации порядок ставится ключом на кадре (рука перед телом только здесь)
				_key_layer(l, &"z", l.z + (1 if act == "up" else -1), false)
				_toast(tr("Z_KEYED") % (l.z))
				undo.end_gesture()
				return
			var list := doc.sibling_list(l.parent_id)
			var i := list.find(l.id)
			var j := i + (1 if act == "up" else -1)
			if j >= 0 and j < list.size():
				undo.push(RbCommands.MoveLayer.new(l.id, l.parent_id, j))
		"duplicate":
			var d := RbLayer.from_dict(l.to_dict())
			d.id = doc.new_id()
			d.name = tr("COPY_SUFFIX") % l.name
			d.position += Vector2(24, 24)
			var img: Image = null
			if not l.is_group():
				d.image_id = "img%d" % d.id
				img = doc.images.get(l.image_id)
			d.children.clear()
			var idx := doc.sibling_list(l.parent_id).find(l.id) + 1
			undo.push(RbCommands.AddLayer.new(d, img, idx))
			selected_id = d.id
		"defringe":
			var img: Image = doc.images.get(l.image_id)
			if img == null:
				return
			var r := RbImageOps.defringe(img, DEFRINGE_PX)
			if int(r[1]) == 0:
				_toast(tr("DEFRINGE_NONE"))
				return
			undo.push(RbCommands.SetImage.new(l.image_id, img, r[0], "Кайма"))
			_toast(tr("DEFRINGE_DONE") % int(r[1]))
		"flip":
			if mode == 1:
				_key_layer(l, &"scale", Vector2(-l.scale.x, l.scale.y), false)
			else:
				undo.push(RbCommands.SetLayerProp.new(l.id, &"scale", l.scale, Vector2(-l.scale.x, l.scale.y)))
		"reset":
			var unit := Vector2(signf(l.scale.x), signf(l.scale.y))
			if mode == 1:
				_key_layer(l, &"rotation", 0.0, false)
				undo.end_gesture()
				_key_layer(l, &"scale", unit, false)
			else:
				undo.push(RbCommands.SetLayerProp.new(l.id, &"rotation", l.rotation, 0.0))
				undo.end_gesture()
				undo.push(RbCommands.SetLayerProp.new(l.id, &"scale", l.scale, unit))
		"group":
			undo.push(RbCommands.GroupLayer.new(doc, l.id, tr("GROUP_NAME")))
		"delete":
			undo.push(RbCommands.RemoveLayer.new(l.id))
			selected_id = 0
			_close_sheet()
		"rename":
			_rename_dialog(l)
		"bind_rigid":
			if not rig_tools.bind_rigid(l):
				_toast(tr("BIND_PICK_BONE"))
		"bind_auto":
			if not rig_tools.bind_auto(l):
				_toast(tr("BIND_NO_BONES"))
		"unbind":
			rig_tools.unbind(l)
		"paint_weights":
			_close_sheet()
			tool_buttons["weights"].button_pressed = true
			_set_tool("weights")
		"mesh_density":
			_mesh_generate(l, clampf(float(arg), 0.0, 1.0))
		"mesh_rebuild":
			_mesh_generate(l, l.mesh_density)
		"mesh_quad":
			_mesh_commit(l, RbMeshGen.quad(l.size), l.mesh_density)
		"mesh_edit":
			_close_sheet()
			tool_buttons["mesh"].button_pressed = true
			_set_tool("mesh")
	if act != "opacity":
		undo.end_gesture()
	if sheet.visible and act != "opacity" and doc.get_layer(selected_id):
		sheet.bind_status = rig_tools.bind_status(doc.get_layer(selected_id))
		sheet.show_layer(doc, selected_id)
	if layers_panel.visible:
		layers_panel.selected_id = selected_id
		layers_panel.rebuild()


func _bone_menu() -> void:
	var b := doc.rig.get_bone(rig_tools.selected_bone)
	if b == null:
		return
	var items := [["pencil", "ACT_RENAME", func() -> void: _rename_bone(b)],
		["lock", "BONE_CONSTRAINTS", _open_bone_sheet]]
	if mode == 1:
		items.append(["reset", "BONE_RESET_POSE", func() -> void: _apply_pose(RbPoseTools.rest_pose([b.id]))])
		items.append(["copy", "POSE_COPY", func() -> void:
			pose_clip = RbPoseTools.snapshot(doc.rig)
			_toast(tr("POSE_COPIED"))])
		if not pose_clip.is_empty():
			items.append(["paste", "POSE_PASTE", func() -> void: _apply_pose(pose_clip)])
		items.append(["flip", "POSE_MIRROR", func() -> void:
			_apply_pose(RbPoseTools.mirrored(doc.rig, RbPoseTools.snapshot(doc.rig)))])
	if b.parent_id != 0:
		items.append(["back", "BONE_DETACH", func() -> void: undo.push(RbRigCommands.ReparentBone.new(b.id, 0))])
	items.append(["trash", "BONE_DELETE", func() -> void:
		undo.push(RbRigCommands.RemoveBone.new(b.id))
		rig_tools.selected_bone = 0
		_update_selection()])
	_open_menu(sel_chip, items)


## Поставить позу костей ключами на текущем кадре одним шагом истории.
func _apply_pose(pose: Dictionary) -> void:
	var e := RbPoseTools.key_entries(doc, pose)
	if e.is_empty():
		return
	var tracks: Array = []
	var values: Array = []
	var rests: Array = []
	for x in e:
		tracks.append(x[0])
		values.append(x[1])
		rests.append(x[2])
	undo.end_gesture()
	undo.push(RbAnimCommands.SetKeysAuto.new(tracks, doc.current_frame, values, rests))
	undo.end_gesture()


func _rename_bone(b: RbBone) -> void:
	var le := LineEdit.new()
	le.text = b.name
	le.custom_minimum_size.y = 44
	le.select_all_on_focus = true
	var ok := Callable(func() -> void:
		var t := le.text.strip_edges()
		if t != "" and t != b.name:
			undo.push(RbRigCommands.SetBoneProp.new(b.id, &"name", b.name, t))
			_update_selection()
		_close_overlay())
	_dialog("ACT_RENAME", "", le, "ACT_SAVE", ok)
	le.grab_focus.call_deferred()
	le.text_submitted.connect(func(_t: String) -> void: ok.call())


func _rename_dialog(l: RbLayer) -> void:
	var le := LineEdit.new()
	le.text = l.name
	le.custom_minimum_size.y = 44
	le.select_all_on_focus = true
	var ok := Callable(func() -> void:
		var t := le.text.strip_edges()
		if t != "" and t != l.name:
			undo.push(RbCommands.SetLayerProp.new(l.id, &"name", l.name, t))
			if sheet.visible:
				sheet.rebuild()
			if layers_panel.visible:
				layers_panel.rebuild()
		_close_overlay())
	_dialog("ACT_RENAME", "", le, "ACT_SAVE", ok)
	le.grab_focus.call_deferred()
	le.text_submitted.connect(func(_t: String) -> void: ok.call())


# ---------------- параметры ----------------

func _toggle_params() -> void:
	if params_sheet.visible:
		_hide_panel(params_sheet)
		_refresh()
		return
	params_sheet.hint_key = "PARAMS_HINT_ANIM" if mode == 1 else "PARAMS_HINT_RIG"
	params_sheet.rebuild(doc)
	_show_panel(params_sheet)
	_refresh()  # в Риге ползунки показываются только с открытой панелью


func _update_params_hint() -> void:
	params_sheet.hint_key = "PARAMS_HINT_ANIM" if mode == 1 else "PARAMS_HINT_RIG"
	params_sheet.rebuild(doc)


## Ползунок параметра: Анимация = автоключ "param:<id>:value", иначе просто значение для предпросмотра.
func _on_param_slider(id: int, v: float, done: bool) -> void:
	var p := doc.params.get_param(id)
	if p == null:
		return
	if mode == 1:
		undo.push(RbAnimCommands.SetKeyAuto.new(RbAnimation.track_key("param", id, &"value"), doc.current_frame, v, p.value), false, true)
		if done:
			undo.end_gesture()
	else:
		p.value = v
		doc.notify(&"param_value")


## Окно с одной строкой ввода.
func _text_dialog(title_key: String, initial: String, on_ok: Callable) -> void:
	var le := LineEdit.new()
	le.text = initial
	le.custom_minimum_size.y = 44
	le.select_all_on_focus = true
	var ok := Callable(func() -> void:
		var t := le.text.strip_edges()
		_close_overlay()
		if t != "":
			on_ok.call(t))
	_dialog(title_key, "", le, "ACT_SAVE", ok)
	le.grab_focus.call_deferred()
	le.text_submitted.connect(func(_t: String) -> void: ok.call())


func _parse_num(text: String, fallback: float) -> float:
	var t := text.strip_edges().replace(",", ".")
	return float(t) if t.is_valid_float() else fallback


func _param_add() -> void:
	_text_dialog("PARAM_NEW", tr("PARAM_N") % (doc.params.params.size() + 1), func(t: String) -> void:
		var p := RbParams.Param.new()
		p.id = doc.new_id()
		p.name = t
		p.min_v = 0.0
		p.max_v = 1.0
		p.default_v = 0.0
		undo.push(RbParamCommands.AddParam.new(p))
		undo.end_gesture())


func _param_menu(id: int, anchor: Control) -> void:
	var p := doc.params.get_param(id)
	if p == null:
		return
	_open_menu(anchor, [
		["pencil", "ACT_RENAME", func() -> void:
			_text_dialog("ACT_RENAME", p.name, func(t: String) -> void:
				var s := RbParamCommands.SetParamProps.snap(p)
				var n := s.duplicate()
				n["name"] = t
				undo.push(RbParamCommands.SetParamProps.new(id, s, n))
				undo.end_gesture())],
		["sliders", "PARAM_RANGE", func() -> void: _param_range_dialog(id)],
		["curve", "PARAM_FORM", func() -> void: _param_form_dialog(id)],
		["chain", "PARAM_DRIVE", func() -> void: _param_drive_menu(id, anchor)],
		["trash", "PARAM_DELETE", func() -> void:
			undo.push(RbParamCommands.RemoveParam.new(id))
			undo.end_gesture()],
	])


func _param_range_dialog(id: int) -> void:
	var p := doc.params.get_param(id)
	if p == null:
		return
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var fields: Array[LineEdit] = []
	for spec in [["PARAM_MIN", p.min_v], ["PARAM_MAX", p.max_v], ["PARAM_DEFAULT", p.default_v]]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var lb := Label.new()
		lb.theme_type_variation = "LabelDim"
		lb.text = spec[0]
		lb.custom_minimum_size.x = 120
		lb.clip_text = true
		lb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(lb)
		var le := LineEdit.new()
		le.text = RbUi.num(spec[1])
		le.custom_minimum_size.y = 44
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.select_all_on_focus = true
		row.add_child(le)
		box.add_child(row)
		fields.append(le)
	var err := RbUi.label("PARAM_RANGE_BAD", "LabelFaint")
	err.add_theme_color_override("font_color", RbTheme.C.danger)
	err.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err.visible = false
	box.add_child(err)
	var ok := Callable(func() -> void:
		var mn := _parse_num(fields[0].text, p.min_v)
		var mx := _parse_num(fields[1].text, p.max_v)
		var df := _parse_num(fields[2].text, p.default_v)
		if mn >= mx:
			err.visible = true
			return
		var s := RbParamCommands.SetParamProps.snap(p)
		undo.push(RbParamCommands.SetParamProps.new(id, s, {"name": p.name, "min": mn, "max": mx, "default": clampf(df, mn, mx)}))
		undo.end_gesture()
		_close_overlay())
	_dialog("PARAM_RANGE", "", box, "ACT_SAVE", ok)
	fields[0].grab_focus.call_deferred()


## Выбор точки ключевой формы: ползунок значения, быстрые точки (мин, макс, уже записанные формы).
func _param_form_dialog(id: int) -> void:
	var p := doc.params.get_param(id)
	if p == null:
		return
	var start_v := p.max_v
	if not p.forms.is_empty():
		var pts := p.forms.keys()
		pts.sort()
		start_v = float(pts[0])
	var state := {"v": start_v}
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var info := RbUi.label("FORM_PICK", "LabelDim")
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info)
	var holder := {}  # clear_btn создаётся позже, лямбда берёт его отсюда
	var refresh := func() -> void:
		var has := RbFormEdit.has_form(p, float(state["v"]))
		if holder.has("clear"):
			(holder["clear"] as Button).visible = has
	var slider_row := RbUi.slider2("FORM_VALUE", p.min_v, p.max_v, start_v, RbUi.num, func(v: float, _done: bool) -> void:
		# у уже записанной формы значение прилипает к её точке
		var snapped_v := snappedf(v, 0.01)
		for k in p.forms:
			if absf(float(k) - v) <= (p.max_v - p.min_v) * 0.02:
				snapped_v = float(k)
		state["v"] = snapped_v
		refresh.call())
	box.add_child(slider_row)
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 8)
	chips.add_theme_constant_override("v_separation", 8)
	var points := {}
	points[p.min_v] = true
	points[p.max_v] = true
	for k in p.forms:
		points[float(k)] = true
	var plist := points.keys()
	plist.sort()
	for pt in plist:
		var val: float = pt
		var pick := func() -> void:
			state["v"] = val
			RbUi.set_slider2(slider_row, val)
			refresh.call()
		var chip := RbUi.text_btn("SecondaryButton", "", RbUi.num(val), pick, 44)
		chip.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		chip.custom_minimum_size.x = 64
		chips.add_child(chip)
	box.add_child(chips)
	var clear_cb := func() -> void:
		var key := RbFormEdit.point_key(p, float(state["v"]))
		var nf := p.forms.duplicate(true)
		nf.erase(key)
		undo.push(RbParamCommands.SetParamForms.new(id, p.forms, nf))
		undo.end_gesture()
		_toast(tr("FORM_CLEARED"))
		refresh.call()
	var clear_btn := RbUi.text_btn("DangerButton", "trash", "FORM_CLEAR", clear_cb, 44)
	holder["clear"] = clear_btn
	box.add_child(clear_btn)
	refresh.call()
	var ok := Callable(func() -> void:
		_close_overlay()
		_enter_form(id, float(state["v"])))
	_dialog("FORM_TITLE", "", box, "FORM_EDIT", ok)


## Драйвер: выбираем, каким параметром управлять. Циклы запрещает RbParams.can_drive.
func _param_drive_menu(id: int, anchor: Control) -> void:
	var p := doc.params.get_param(id)
	var items := []
	for q: RbParams.Param in doc.params.params.values():
		if q.id == id:
			continue
		var tid := q.id
		var on := false
		for d in p.drivers:
			if int(d["target"]) == tid:
				on = true
		items.append(["check" if on else "dot_empty", q.name, func() -> void: _param_drive_pick(id, tid)])
	if items.is_empty():
		_toast(tr("PARAM_NO_OTHERS"))
		return
	_open_menu(anchor, items)


func _param_drive_pick(id: int, tid: int) -> void:
	var p := doc.params.get_param(id)
	var t := doc.params.get_param(tid)
	if p == null or t == null:
		return
	var idx := -1
	for i in p.drivers.size():
		if int(p.drivers[i]["target"]) == tid:
			idx = i
	if idx < 0 and not doc.params.can_drive(id, tid):
		_toast(tr("PARAM_CYCLE"))
		return
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var who := RbUi.label("%s  >  %s" % [p.name, t.name], "LabelDim")
	who.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(who)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var lb := RbUi.label("PARAM_DRIVE_K", "LabelDim")
	lb.custom_minimum_size.x = 120
	row.add_child(lb)
	var le := LineEdit.new()
	le.text = RbUi.num(float(p.drivers[idx].get("k", 1.0))) if idx >= 0 else "1.0"
	le.custom_minimum_size.y = 44
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.select_all_on_focus = true
	row.add_child(le)
	box.add_child(row)
	if idx >= 0:
		var stop_cb := func() -> void:
			var nd := p.drivers.duplicate(true)
			nd.remove_at(idx)
			undo.push(RbParamCommands.SetParamDrivers.new(id, p.drivers, nd))
			undo.end_gesture()
			_close_overlay()
		box.add_child(RbUi.text_btn("DangerButton", "x", "PARAM_DRIVE_STOP", stop_cb, 44))
	var ok := Callable(func() -> void:
		var k := _parse_num(le.text, 1.0)
		var nd := p.drivers.duplicate(true)
		var entry := {"target": tid, "k": k, "b": 0.0}
		if idx >= 0:
			nd[idx] = entry
		else:
			nd.append(entry)
		undo.push(RbParamCommands.SetParamDrivers.new(id, p.drivers, nd))
		undo.end_gesture()
		_close_overlay())
	_dialog("PARAM_DRIVE_TITLE", "", box, "ACT_SAVE", ok)
	le.grab_focus.call_deferred()


# ---------------- правка ключевой формы ----------------

func _build_form_banner() -> void:
	var holder := _margins(8, 8, 8, 8)
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.visible = false
	view.add_child(holder)
	form_banner_holder = holder
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(v)
	form_banner = PanelContainer.new()
	form_banner.mouse_filter = Control.MOUSE_FILTER_STOP
	form_banner.add_theme_stylebox_override("panel", RbTheme.sb(FORM_COLOR, 10, 12, 8))
	v.add_child(form_banner)
	form_banner_box = BoxContainer.new()
	form_banner_box.add_theme_constant_override("separation", 8)
	form_banner.add_child(form_banner_box)
	form_banner_label = Label.new()
	form_banner_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	form_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form_banner_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form_banner_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	form_banner_label.add_theme_color_override("font_color", Color.WHITE)
	form_banner_box.add_child(form_banner_label)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	btns.alignment = BoxContainer.ALIGNMENT_END
	form_banner_box.add_child(btns)
	var reset_cb := func() -> void:
		form_tools.reset_form()
		_toast(tr("FORM_CLEARED"))
	var reset := RbUi.text_btn("SecondaryButton", "", "FORM_RESET", reset_cb, 44)
	reset.custom_minimum_size.x = 88
	btns.add_child(reset)
	var done := RbUi.text_btn("PrimaryButton", "check", "FORM_DONE", _finish_form, 44)
	done.custom_minimum_size.x = 112
	btns.add_child(done)
	view.resized.connect(_layout_form_banner)


func _layout_form_banner() -> void:
	if form_banner_box:
		# узкий вьюпорт: подпись над кнопками, широкий: всё в одну строку
		form_banner_box.vertical = view.size.x < 540.0


func _enter_form(id: int, value: float) -> void:
	if mode != 1:
		seg_buttons[1].button_pressed = true
		_set_mode(1)
	for p in _panels():
		if p != null and p.visible:
			_hide_panel(p, false)
	tool_buttons["pose"].button_pressed = true
	_set_tool("pose")
	form_tools.enter(id, value)


func _finish_form() -> void:
	if form_tools.finish():
		_toast(tr("FORM_SAVED"))


## Вызывается из RbFormTools при входе и выходе: баннер, рамка, набор инструментов.
func _form_state_changed() -> void:
	var on := form_tools.active
	form_banner_holder.visible = on
	view.alert_color = FORM_COLOR if on else Color(0, 0, 0, 0)
	if on:
		var p := form_tools.param()
		form_banner_label.text = tr("FORM_BANNER") % [p.name if p else "", RbUi.num(form_tools.point)]
		_layout_form_banner()
	view.long_press_enabled = (tool == "mesh" and not on) or tool == "pins"
	_update_tool_buttons()
	_update_timeline_visibility()
	_update_undo_buttons()
	_refresh()  # значение ползунка поменялось без команды: кадр и позу пересчитать сразу
	view.refresh_overlay()
	_place_toast.call_deferred()


## Тосты ниже баннера формы (иначе они лежат поверх него).
func _place_toast() -> void:
	await get_tree().process_frame
	var top := 62
	if form_banner_holder.visible:
		top = int(form_banner.get_global_rect().end.y - view.global_position.y) + 8
	toast_holder.add_theme_constant_override("margin_top", top)


# ---------------- констрейны кости ----------------

func _open_bone_sheet() -> void:
	var b := doc.rig.get_bone(rig_tools.selected_bone)
	if b == null:
		return
	bone_sheet.show_bone(doc.rig, b.id)
	_show_panel(bone_sheet)


## Правка констрейнов: словарь целиком копией, шаги слайдера склеиваются, динамика сбрасывается сама (&"bones").
func _on_constraints_changed(c: Dictionary, done: bool) -> void:
	var b := doc.rig.get_bone(bone_sheet.bone_id)
	if b == null:
		return
	undo.push(RbRigCommands.SetBoneProp.new(b.id, &"constraints", b.constraints.duplicate(true), c.duplicate(true)), false, true)
	if done:
		undo.end_gesture()


func _on_bone_pick(kind: String, anchor: Control) -> void:
	var b := doc.rig.get_bone(bone_sheet.bone_id)
	if b == null:
		return
	var cur := 0
	if kind == "copy":
		cur = int((b.constraints.get("copy", {}) as Dictionary).get("from", 0))
	else:
		cur = int(b.constraints.get("target", 0))
	var items := [["x", "CON_NONE", func() -> void: bone_sheet.set_pick(kind, 0)]]
	var order := doc.rig.order()
	var my := order.find(b.id)
	for id in order:
		if id == b.id:
			continue
		# «смотреть на кость» работает на костях, посчитанных раньше этой
		if kind == "target" and order.find(id) > my:
			continue
		var bid: int = id
		items.append(["check" if bid == cur else "dot_empty", doc.rig.get_bone(bid).name, func() -> void: bone_sheet.set_pick(kind, bid)])
	if items.size() == 1:
		_toast(tr("CON_NO_BONES"))
		return
	_open_menu(anchor, items)


# ---------------- эффекты ----------------

func _open_fx_sheet(refresh := true) -> void:
	var l := doc.get_layer(selected_id) if selected_id != 0 else null
	if l == null:
		return
	if l.is_group():
		_open_sheet()
		return
	fx_sheet.show_layer(doc, selected_id)
	_show_panel(fx_sheet, refresh)


## Эффекты слоя: словарь целиком копией, шаги слайдера и стрелки света склеиваются.
func _fx_changed(fx: Dictionary, done: bool) -> void:
	var l := doc.get_layer(fx_sheet.layer_id)
	if l == null or l.is_group():
		return
	undo.push(RbCommands.SetLayerProp.new(l.id, &"effects", l.effects.duplicate(true), fx.duplicate(true)), false, true)
	if done:
		undo.end_gesture()


func _fx_blend_menu(anchor: Control) -> void:
	var items := []
	for bm in RbFxSheet.BLENDS:
		var mm: String = bm
		items.append(["check" if mm == fx_sheet.rim_blend() else "dot_empty", "BLEND_" + mm.to_upper(), func() -> void: fx_sheet.set_blend(mm)])
	_open_menu(anchor, items)


func _open_settings() -> void:
	_open_overlay()
	var s := RbSettingsScreen.new(settings)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var m := _safe_insets()
	s.offset_left = m.position.x
	s.offset_top = m.position.y
	s.offset_right = -m.size.x
	s.offset_bottom = -m.size.y
	overlay_layer.add_child(s)
	s.closed.connect(_close_overlay)
	s.about_requested.connect(func() -> void: _dialog("ABOUT_TITLE", tr("ABOUT_TEXT") % VERSION))
	s.restart_needed.connect(func() -> void:
		_save_now()
		get_tree().reload_current_scene())


# ---------------- бенчмарк ----------------

func _run_bench() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = RbTheme.C.vp
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var b := RbBenchmark.new()
	b.area = get_viewport_rect().size
	layer.add_child(b)
	var lbl := Label.new()
	lbl.theme = RbTheme.theme
	lbl.text = "BENCH_RUNNING"
	lbl.position = Vector2(16, 16)
	layer.add_child(lbl)
	OS.low_processor_usage_mode = false
	var res: Dictionary = await b.finished
	OS.low_processor_usage_mode = true
	layer.queue_free()
	print("RIGBIT_BENCH ", JSON.stringify(res))
	_dialog("BENCH_TITLE", tr("BENCH_RESULT") % [res["fps"], res["refresh"], res["low1"], res["worst_ms"],
		res["cpu_ms"], res["layers"], res["verts"], res["gpu"]])


# ---------------- скриншоты для самопроверки ----------------

## --tool=mesh: у выбранного слоя строится сетка с плотностью 0.5 и включается инструмент сетки.
func _activate_mesh_tool_for_shot() -> void:
	await get_tree().process_frame  # дать _refresh посчитать позу нового слоя
	var l := doc.get_layer(selected_id) if selected_id != 0 else null
	if l == null or l.is_group():
		return
	_mesh_generate(l, 0.5)
	tool_buttons["mesh"].button_pressed = true
	_set_tool("mesh")


## --auto=ik|pins|form|param|fx|con: прогон жестов без пальцев (самопроверка), результат в консоль "AUTO ...".
func _auto(kind: String) -> void:
	await _frames(3)
	match kind:
		"switch":  # вариант свитча и порядок ключами в Анимации (после --gl2)
			var sw: RbLayer = null
			for l: RbLayer in doc.layers.values():
				if l.kind == RbLayer.Kind.SWITCH and l.name == "mouth":
					sw = l
			if sw:
				var hand: RbLayer = doc.get_layer(r_part(&"forearm1"))
				selected_id = sw.id
				_open_sheet()
				var steps := undo.size()
				_pick_switch(sw, 0)
				print("AUTO switch keys=", doc.anim.keys_of(RbAnimation.track_key("layer", sw.id, &"switch_index")).size(), " undo_added=", undo.size() - steps)
				if hand:
					selected_id = hand.id
					_layer_action("down", null)
					print("AUTO switch z=", hand.z, " zkeys=", doc.anim.keys_of(RbAnimation.track_key("layer", hand.id, &"z")).size())
				selected_id = sw.id
				_update_selection()
				sheet.show_layer(doc, sw.id)
		"gl2pose":  # поза гача-персонажа: рука вверх, присед на IK, зрачки вбок-вверх
			var by := {}
			for b: RbBone in doc.rig.bones.values():
				by[b.name] = b
			if by.has("Shoulder1"):
				by["Shoulder1"].pose_angle = -1.1
				by["Forearm1"].pose_angle = -0.8
				by["Main_bone"].pose_offset = Vector2(0, 0)
				by["Body1"].pose_offset = Vector2(0, 60)
				by["target1"].pose_offset = Vector2(0, 0)
				by["Head"].pose_angle = 0.15
				by["Pupil1"].pose_offset = Vector2(10, -12)
				by["Pupil2"].pose_offset = Vector2(10, -12)
				doc.notify(&"bones")
				await _frames(3)
				print("AUTO gl2pose ok")
		"export":
			if _args.has("export_fmt"):  # --export_fmt=png_zip
				export_sheet.settings = RbExportPlan.defaults(doc, str(_args["export_fmt"]))
			_run_export(export_sheet.settings.duplicate())
			while exporting:
				await _frames(1)
			print("AUTO export file=", _export_file, " bytes=", FileAccess.get_file_as_bytes(_export_file).size(), " state=", export_sheet.state)
			if _args.has("export_save"):
				_export_save()
				print("AUTO export saved=", FileAccess.file_exists(str(_args["export_save"])))
		"defringe":
			var dl := doc.get_layer(selected_id)
			var before: Image = doc.images[dl.image_id]
			var steps0 := undo.size()
			_layer_action("defringe", null)
			await _frames(2)
			print("AUTO defringe replaced=", doc.images[dl.image_id] != before, " undo_added=", undo.size() - steps0)
			undo.undo()
			print("AUTO defringe after_undo restored=", doc.images[dl.image_id] == before)
		"mirror":
			var hb := doc.rig.get_bone(rig_tools.selected_bone)
			var a0 := hb.pose_angle
			var steps := undo.size()
			_apply_pose(RbPoseTools.mirrored(doc.rig, RbPoseTools.snapshot(doc.rig)))
			print("AUTO mirror angle ", a0, " -> ", hb.pose_angle, " undo_added=", undo.size() - steps)
			pose_clip = RbPoseTools.snapshot(doc.rig)
			undo.undo()
			print("AUTO mirror after_undo ", hb.pose_angle)
			_apply_pose(pose_clip)
			print("AUTO mirror pasted ", hb.pose_angle)
		"ik":
			var head := rig_tools.selected_bone
			var b := doc.rig.get_bone(head)
			var tip: Vector2 = (pose.bones[head] as Transform2D) * Vector2(b.length, 0)
			var target := tip + Vector2(-b.length * 0.5, b.length * 0.7)
			var before := undo.size()
			_on_drag_begin(tip)
			for i in 6:
				_on_drag_move(tip.lerp(target, float(i + 1) / 6.0))
				await _frames(2)
			_on_drag_end()
			await _frames(2)
			var nt: Vector2 = (pose.bones[head] as Transform2D) * Vector2(b.length, 0)
			var kp := doc.anim.keys_of(RbAnimation.track_key("bone", head, &"pose_angle")).size()
			print("AUTO ik tip_err=", snappedf(nt.distance_to(target), 0.01), " keys_head=", kp, " undo_steps=", undo.size() - before)
			undo.undo()
			await _frames(2)
			print("AUTO ik after_undo pose_angle=", doc.rig.get_bone(head).pose_angle, " tracks=", doc.anim.tracks.size())
		"ikform":
			var pidf: int = doc.params.params.keys()[0]
			var stepsf := undo.size()
			_enter_form(pidf, 1.0)
			await _frames(3)
			var headf := rig_tools.selected_bone
			var bf := doc.rig.get_bone(headf)
			var tipf: Vector2 = (pose.bones[headf] as Transform2D) * Vector2(bf.length, 0)
			var targetf := tipf + Vector2(-bf.length * 0.5, bf.length * 0.7)
			_on_drag_begin(tipf)
			for i in 6:
				_on_drag_move(tipf.lerp(targetf, float(i + 1) / 6.0))
				await _frames(2)
			_on_drag_end()
			await _frames(2)
			var ntf: Vector2 = (pose.bones[headf] as Transform2D) * Vector2(bf.length, 0)
			var pf := doc.params.get_param(pidf)
			print("AUTO ikform tip_err=", snappedf(ntf.distance_to(targetf), 0.01), " form_bones=", (pf.forms[1.0]["bones"] as Dictionary).size(), " pose_angle=", bf.pose_angle, " tracks=", doc.anim.tracks.size(), " undo_added=", undo.size() - stepsf)
		"pins":
			var l := doc.get_layer(selected_id)
			var w0: Vector2 = (pose.layers[l.id] as RbEvaluator.LayerPose).world * Vector2(0, -l.size.y * 0.2)
			_on_tap(w0)
			await _frames(3)
			var pins: Array = doc.rig.pins.get(l.id, [])
			print("AUTO pins added=", pins.size(), " mesh_verts=", l.mesh_vertices.size())
			var pid := int(pins[0]["id"])
			var hw := pin_tools.handle_world(l, pins[0])
			_on_drag_begin(hw)
			for i in 5:
				_on_drag_move(hw + Vector2(8, -6) * float(i + 1))
				await _frames(2)
			_on_drag_end()
			await _frames(2)
			var tk := RbAnimation.track_key("pin", pid, &"offset")
			print("AUTO pins offset=", doc.rig.find_pin(pid).get("offset"), " keys=", doc.anim.keys_of(tk).size(), " mode=", mode)
			pin_tools.long_press(pin_tools.handle_world(l, doc.rig.find_pin(pid)))
			await _frames(2)
			print("AUTO pins menu_open=", overlay_layer.visible)
			_close_overlay()
			pin_tools._bind(l, pid)
			await _frames(2)
			print("AUTO pins bound_to=", doc.rig.find_pin(pid)["bone"], " selected_bone=", rig_tools.selected_bone)
			pin_tools._unbind(l, pid)
			await _frames(2)
			print("AUTO pins unbound=", doc.rig.find_pin(pid)["bone"])
			pin_tools._delete(l, pid)
			await _frames(2)
			print("AUTO pins deleted=", doc.rig.pins.get(l.id, []).size())
			undo.undo()
			undo.undo()
			undo.undo()
			await _frames(2)
			undo.undo()
			await _frames(2)
			print("AUTO pins after_undo offset=", doc.rig.find_pin(pid).get("offset"))
		"form":
			var pid2: int = doc.params.params.keys()[0]
			var p := doc.params.get_param(pid2)
			var steps := undo.size()
			_enter_form(pid2, 1.0)
			await _frames(3)
			var head2 := rig_tools.selected_bone
			var hb := doc.rig.get_bone(head2)
			var base_angle := hb.pose_angle
			var tip2: Vector2 = (pose.bones[head2] as Transform2D) * Vector2(hb.length, 0)
			var mid: Vector2 = (pose.bones[head2] as Transform2D) * Vector2(hb.length * 0.5, 0)
			_on_drag_begin(mid)
			for i in 5:
				_on_drag_move(mid + Vector2(10, 0) * float(i + 1))
				await _frames(2)
			_on_drag_end()
			await _frames(2)
			print("AUTO form pose_angle_unchanged=", hb.pose_angle == base_angle, " form_bones=", (p.forms[1.0]["bones"] as Dictionary).size(), " undo_added=", undo.size() - steps)
			tool_buttons["mesh"].button_pressed = true
			_set_tool("mesh")
			await _frames(2)
			var l2 := doc.get_layer(selected_id)
			if l2:
				if l2.mesh_vertices.size() <= 4:
					print("AUTO form mesh is quad, vertices=", l2.mesh_vertices.size())
				var vw := (pose.layers[l2.id] as RbEvaluator.LayerPose).world * (pose.layers[l2.id] as RbEvaluator.LayerPose).vertices[0]
				_on_drag_begin(vw)
				for i in 4:
					_on_drag_move(vw + Vector2(6, 9) * float(i + 1))
					await _frames(2)
				_on_drag_end()
				await _frames(2)
				print("AUTO form verts_layers=", (p.forms[1.0]["verts"] as Dictionary).size(), " delta0=", RbFormEdit.vert_delta(p.forms[1.0], l2.id, 0))
			_finish_form()
			await _frames(2)
			print("AUTO form done undo_added=", undo.size() - steps, " value_restored=", p.value, " active=", form_tools.active)
			undo.undo()
			await _frames(2)
			print("AUTO form after_undo bones=", (p.forms[1.0]["bones"] as Dictionary).size() if p.forms.has(1.0) else -1)
		"param":
			var pid3: int = doc.params.params.keys()[0]
			var steps3 := undo.size()
			for v in [0.2, 0.4, 0.8]:
				_on_param_slider(pid3, v, v == 0.8)
				await _frames(2)
			print("AUTO param value=", doc.params.get_param(pid3).value, " keys=", doc.anim.keys_of(RbAnimation.track_key("param", pid3, &"value")).size(), " undo_added=", undo.size() - steps3, " mode=", mode)
			undo.undo()
			await _frames(2)
			print("AUTO param after_undo value=", doc.params.get_param(pid3).value)
		"light":
			var l4 := doc.get_layer(selected_id)
			var s4 := undo.size()
			var tip4 := view.to_world(view.light_tip())
			var c4: Vector2 = view.light_arrow["c"]
			_on_drag_begin(tip4)
			print("AUTO light grabbed=", _light_drag)
			for i in 5:
				_on_drag_move(c4 + Vector2.from_angle(deg_to_rad(-45.0 + 20.0 * float(i + 1))) * 200.0)
				await _frames(2)
			_on_drag_end()
			await _frames(2)
			print("AUTO light angle_deg=", snappedf(rad_to_deg(float(l4.effects["rim"]["angle"])), 0.1), " undo_added=", undo.size() - s4, " arrow_a=", snappedf(rad_to_deg(float(view.light_arrow["a"])), 0.1))
		"fx":
			var l3 := doc.get_layer(selected_id)
			var s0 := undo.size()
			fx_sheet.set_rim_angle(0.0, false)
			fx_sheet.set_rim_angle(0.5, true)
			await _frames(2)
			print("AUTO fx rim_angle=", l3.effects.get("rim", {}).get("angle"), " undo_added=", undo.size() - s0)
		"con":
			var bn := doc.rig.get_bone(rig_tools.selected_bone)
			_open_bone_sheet()
			var s1 := undo.size()
			var c := bn.constraints.duplicate(true)
			c["limit"] = {"min": -0.3, "max": 0.3}
			bone_sheet.changed.emit(c, false)
			c["limit"] = {"min": -0.3, "max": 0.4}
			bone_sheet.changed.emit(c, true)
			await _frames(2)
			print("AUTO con limit=", bn.constraints.get("limit"), " undo_added=", undo.size() - s1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _take_shot() -> void:
	OS.low_processor_usage_mode = false
	for i in 10:
		await get_tree().process_frame
	if _args.has("auto"):
		await _auto(str(_args["auto"]))
	if _args.get("tl", "") == "collapsed":
		timeline.set_collapsed(true)
	elif _args.get("tl", "") == "all":
		timeline.grid.only_focus = false
		timeline.grid.rebuild()
	if _args.has("zoom"):  # --zoom=коэффициент: приблизить вид к центру
		view._zoom_at(view.size * 0.5, float(_args["zoom"]))
		await get_tree().process_frame
	if _args.has("menu"):
		if _args["menu"] in ["keys", "interp"]:
			var refs := []
			for tk in doc.anim.tracks:
				if (tk as String).begins_with("bone:%d:" % rig_tools.selected_bone):
					for kk in doc.anim.tracks[tk]:
						if int(kk["f"]) in [12, 24]:
							refs.append([tk, int(kk["f"])])
			timeline.refresh()
			timeline.select_refs(refs)
			if _args["menu"] == "interp":
				await get_tree().process_frame
				_interp_menu(timeline.btn_interp)
		elif _args["menu"] == "project":
			_menu_project()
		elif _args["menu"] == "more":
			_menu_more()
		elif _args["menu"] == "about":
			_dialog("ABOUT_TITLE", tr("ABOUT_TEXT") % VERSION)
		elif _args["menu"] == "sheet":
			_open_sheet()
		elif _args["menu"] == "sheet_mesh":
			sheet.tab = 1
			_open_sheet()
		elif _args["menu"] == "layers":
			_toggle_layers()
		elif _args["menu"] == "settings":
			_open_settings()
		elif _args["menu"] == "blend":
			_open_sheet()
			await get_tree().process_frame
			_layer_action("blend_menu", null)
		elif _args["menu"] == "rename":
			_layer_action("rename", null)
		elif _args["menu"] == "toast":
			_soon()
		elif _args["menu"] == "bone":
			_bone_menu()
		elif _args["menu"] == "constraints":
			_open_bone_sheet()
		elif _args["menu"] == "bone_pick":
			_open_bone_sheet()
			await get_tree().process_frame
			bone_sheet.pick_requested.emit("copy", bone_sheet)
		elif _args["menu"] == "params":
			_toggle_params()
		elif _args["menu"] in ["params_menu", "range", "form_dialog", "drive"]:
			_toggle_params()
			await get_tree().process_frame
			await get_tree().process_frame
			var pid: int = doc.params.params.keys()[0]
			if _args["menu"] == "params_menu":
				_param_menu(pid, params_sheet.more_buttons[pid])
			elif _args["menu"] == "range":
				_param_range_dialog(pid)
			elif _args["menu"] == "form_dialog":
				_param_form_dialog(pid)
			else:
				_param_drive_menu(pid, params_sheet.more_buttons[pid])
		elif _args["menu"] == "form":
			_enter_form(doc.params.params.keys()[0], 1.0)
		elif _args["menu"] == "fx":
			if selected_id != 0:
				_open_fx_sheet()
		elif _args["menu"] == "fx_blend":
			_open_fx_sheet()
			await get_tree().process_frame
			_fx_blend_menu(fx_sheet)
		elif _args["menu"] == "pin_menu":
			var pl := pin_tools.layer()
			if pl and not pin_tools.pins_of(pl).is_empty():
				pin_tools.long_press(pin_tools.handle_world(pl, pin_tools.pins_of(pl)[0]))
		for i in 4:
			await get_tree().process_frame
	if _args.has("scroll"):  # --scroll=px: прокрутить открытую боковую панель
		for pnl in _panels():
			if pnl is RbPanel and pnl.visible:
				pnl.scroll_to(int(_args["scroll"]))
		if sheet.visible:  # и лист слоя
			for sc in sheet.find_children("*", "ScrollContainer", true, false):
				(sc as ScrollContainer).scroll_vertical = int(_args["scroll"])
		for i in 4:
			await get_tree().process_frame
	if _args.has("wait"):  # подождать тосты и таймеры (--wait=секунды)
		await get_tree().create_timer(float(_args["wait"])).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_args["shot"])
	get_tree().quit()
