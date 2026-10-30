class_name RbTimeline
extends PanelContainer
## Таймлайн режима «Анимация». Внизу экрана: транспорт, панель действий над выделенными ключами
## и сетка с дорожками (ui/timeline_grid.gd). Документ меняет главный экран, таймлайн только шлёт сигналы.
## Портрет: высота ~230-264 dp, действия отдельной строкой. Ландшафт: ~176 dp, действия в строке транспорта.

signal frame_requested(f: int)
signal play_toggled
signal loop_toggled(on: bool)
signal timing_requested
signal keys_delete(refs: Array)
signal keys_move(refs: Array, delta: int)
signal keys_paste(entries: Array)
signal interp_menu_requested(anchor: Control)
signal object_picked(kind: String, id: int)
signal haptic(ms: int)
signal notice(text: String)

const H_LANDSCAPE := 176.0

var doc: RbDocument
var collapsed := false
var wide := false
var clip: Array = []  # буфер обмена ключей (RbTimelineLogic.copy_keys)
var grid: RbTimelineGrid
var btn_play: Button
var btn_loop: Button
var btn_interp: Button

var _panel_h := 250.0
var _col: VBoxContainer
var _transport: HBoxContainer
var _actions: HBoxContainer
var _btn_prev: Button
var _btn_next: Button
var _btn_frame: Button
var _btn_collapse: Button
var _btn_clear: Button
var _btn_del: Button
var _btn_copy: Button
var _btn_paste: Button
var _prev_timer: Timer
var _prev_long := false
var _mode_color := Color("#E5484D")


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := RbTheme.sb(RbTheme.C.p1)
	box.border_color = RbTheme.C.ln
	box.border_width_top = 1
	add_theme_stylebox_override("panel", box)
	var m := RbUi.margins(8, 4, 8, 6)
	add_child(m)
	_col = RbUi.vbox(4)
	m.add_child(_col)

	# транспорт: назад, играть, вперёд, поле кадра, [действия в ландшафте], повтор, свернуть
	_transport = RbUi.hbox(8)
	_col.add_child(_transport)
	_btn_prev = RbUi.icon_btn("back", Callable(), 44, 44)
	_btn_prev.button_down.connect(func() -> void:
		_prev_long = false
		_prev_timer.start())
	_btn_prev.button_up.connect(func() -> void: _prev_timer.stop())
	_btn_prev.pressed.connect(func() -> void:
		if _prev_long:
			_prev_long = false
		else:
			_step(-1))
	_transport.add_child(_btn_prev)
	btn_play = RbUi.icon_btn("play", func() -> void: play_toggled.emit(), 44, 44)
	_transport.add_child(btn_play)
	_btn_next = RbUi.icon_btn("fwd", func() -> void: _step(1), 44, 44)
	_transport.add_child(_btn_next)
	_btn_frame = RbUi.text_btn("SecondaryButton", "", "", func() -> void: timing_requested.emit(), 44)
	_btn_frame.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_btn_frame.custom_minimum_size.x = 72
	_compact(_btn_frame)
	_transport.add_child(_btn_frame)
	_transport.add_child(RbUi.spacer())
	btn_loop = RbUi.icon_btn("loop", Callable(), 44, 44)
	btn_loop.toggle_mode = true
	btn_loop.toggled.connect(func(on: bool) -> void: loop_toggled.emit(on))
	_transport.add_child(btn_loop)
	_btn_collapse = RbUi.icon_btn("chevron_down", func() -> void: set_collapsed(not collapsed), 44, 44)
	_transport.add_child(_btn_collapse)

	# действия над выделенными ключами
	_actions = RbUi.hbox(8)
	_btn_clear = RbUi.text_btn("SecondaryButton", "x", "", func() -> void: grid.clear_selection(), 44)
	_btn_clear.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_btn_clear.tooltip_text = "TL_CLEAR"
	_compact(_btn_clear)
	_actions.add_child(_btn_clear)
	_btn_del = _action_btn("trash", "TL_DELETE", _on_delete)
	_btn_copy = _action_btn("copy", "TL_COPY", _on_copy)
	_btn_paste = _action_btn("paste", "TL_PASTE", _on_paste)
	btn_interp = _action_btn("curve", "TL_INTERP", func() -> void: interp_menu_requested.emit(btn_interp))
	_place_actions()

	grid = RbTimelineGrid.new()
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.custom_minimum_size.y = 64
	_col.add_child(grid)
	grid.frame_requested.connect(func(f: int) -> void: frame_requested.emit(f))
	grid.keys_move_requested.connect(func(refs: Array, d: int) -> void: keys_move.emit(refs, d))
	grid.selection_changed.connect(_update_actions)
	grid.object_picked.connect(func(k: String, i: int) -> void: object_picked.emit(k, i))
	grid.filter_toggled.connect(func() -> void:
		grid.only_focus = not grid.only_focus
		grid.vscroll = 0.0
		grid.rebuild())
	grid.haptic.connect(func(ms: int) -> void: haptic.emit(ms))

	_prev_timer = Timer.new()
	_prev_timer.one_shot = true
	_prev_timer.wait_time = 0.5
	_prev_timer.timeout.connect(func() -> void:
		_prev_long = true
		haptic.emit(20)
		frame_requested.emit(0))
	add_child(_prev_timer)
	_apply_height()
	set_mode_color(_mode_color)
	_update_actions()


func _action_btn(icon: String, tip: String, cb: Callable) -> Button:
	var b := RbUi.text_btn("SecondaryButton", icon, "", cb, 44)
	b.custom_minimum_size.x = 44
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.tooltip_text = tip
	_compact(b)
	_actions.add_child(b)
	return b


## Узкие поля у кнопки-плашки, чтобы вписаться в 344 dp портрета.
func _compact(b: Button) -> void:
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st, RbTheme.sb(RbTheme.C.p2 if st == "normal" else RbTheme.C.p3, 8, 10, 4))
	b.add_theme_stylebox_override("disabled", RbTheme.sb(RbTheme.C.p2, 8, 10, 4))


# ---------------- состояние ----------------

func bind(d: RbDocument) -> void:
	doc = d
	grid.doc = d
	grid.clear_selection()
	grid.scroll = 0.0
	grid.vscroll = 0.0
	grid._user_zoomed = false
	grid._last_count = -1
	grid._last_frame = -1
	clip = []
	refresh()


func set_focus(kind: String, id: int) -> void:
	if kind == grid.focus_kind and id == grid.focus_id:
		return
	grid.focus_kind = kind
	grid.focus_id = id
	grid.vscroll = 0.0
	grid.rebuild()


func refresh() -> void:
	if doc == null or not is_visible_in_tree():
		return
	grid.doc = doc
	grid.rebuild()
	_btn_frame.text = "%d / %d" % [doc.current_frame, doc.frame_count]
	_update_actions()


func set_playing(p: bool) -> void:
	btn_play.icon = RbIcons.tex("pause" if p else "play")


func set_loop(on: bool) -> void:
	btn_loop.set_pressed_no_signal(on)


func set_mode_color(c: Color) -> void:
	_mode_color = c
	grid.mode_color = c
	grid.restyle()
	for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		btn_play.add_theme_color_override(k, c)
	btn_loop.add_theme_color_override("icon_normal_color", RbTheme.C.tx2)
	btn_loop.add_theme_color_override("icon_hover_color", RbTheme.C.tx2)
	btn_loop.add_theme_color_override("icon_pressed_color", c)
	btn_loop.add_theme_color_override("icon_hover_pressed_color", c)


func set_layout(is_wide: bool, vs: Vector2) -> void:
	wide = is_wide
	grid.label_w = 112.0 if wide else 92.0
	_panel_h = H_LANDSCAPE if wide else clampf(vs.y * 0.34, 230.0, 264.0)
	_place_actions()
	_apply_height()
	grid._apply_fit()


func set_collapsed(c: bool) -> void:
	collapsed = c
	_btn_collapse.icon = RbIcons.tex("chevron_up" if c else "chevron_down")
	_apply_height()
	_update_actions()
	grid.rebuild()


func selected_refs() -> Array:
	return grid.selected_refs()


func select_refs(refs: Array) -> void:
	grid.select_refs(refs)


func _apply_height() -> void:
	custom_minimum_size.y = 0.0 if collapsed else _panel_h
	grid.collapsed = collapsed
	grid.custom_minimum_size.y = RbTimelineGrid.SUM_H if collapsed else 64.0
	grid.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if collapsed else Control.SIZE_EXPAND_FILL
	size.y = 0.0  # сжаться до содержимого после сворачивания
	grid.queue_redraw()


## Ландшафт: действия в строке транспорта; портрет: отдельной строкой под ним.
func _place_actions() -> void:
	if _actions.get_parent():
		_actions.get_parent().remove_child(_actions)
	if wide:
		_transport.add_child(_actions)
		_transport.move_child(_actions, 5)
	else:
		_col.add_child(_actions)
		_col.move_child(_actions, 1)


func _update_actions() -> void:
	var n := grid.selected_refs().size() if grid else 0
	_actions.visible = n > 0 and not collapsed
	_btn_clear.text = str(n)
	_btn_paste.disabled = clip.is_empty()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree():
		refresh.call_deferred()


# ---------------- действия ----------------

func _step(d: int) -> void:
	if doc == null:
		return
	frame_requested.emit(clampi(doc.current_frame + d, 0, doc.frame_count - 1))


func _on_delete() -> void:
	var refs := grid.selected_refs()
	if refs.is_empty():
		return
	keys_delete.emit(refs)
	notice.emit(tr("TL_DELETED") % refs.size())


func _on_copy() -> void:
	clip = RbTimelineLogic.copy_keys(doc.anim, grid.selected_refs())
	_update_actions()
	notice.emit(tr("TL_COPIED") % clip.size())


func _on_paste() -> void:
	if clip.is_empty():
		return
	var kind := grid.focus_kind if grid.only_focus else ""
	var entries := RbTimelineLogic.paste_entries(clip, doc.current_frame, kind, grid.focus_id, doc.frame_count)
	if entries.is_empty():
		return
	keys_paste.emit(entries)
	var refs: Array = []
	for e in entries:
		refs.append([e[0], e[1]])
	grid.select_refs(refs)
	notice.emit(tr("TL_PASTED") % entries.size())
