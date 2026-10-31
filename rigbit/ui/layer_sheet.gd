class_name RbLayerSheet
extends PanelContainer
## Настройки выделенного слоя. Телефон в портрете: снизу. Широкий экран: справа от вьюпорта.
## Вкладки: Слой (вид и порядок) / Сетка (плотность, правка точек).

signal action(name: String, arg: Variant)
## Что показать в ползунках: func(layer, prop) -> значение (правка формы показывает форму). Пусто = как в слое.
var shown: Callable
signal closed

var doc: RbDocument
var layer_id := 0
var tab := 0
var mesh_available := true  # RbMeshGen есть в сборке
var bind_status := ""  # «не привязан» / «привязан к: …», заполняет главный экран

var _head_thumb: TextureRect
var _head_name: Label
var _head_sub: Label
var _body: VBoxContainer
var _tabs: PanelContainer
var _tabs_holder: MarginContainer


func _init() -> void:
	theme_type_variation = "Sheet"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var col := RbUi.vbox(0)
	add_child(col)
	var head := RbUi.margins(12, 4, 4, 4)
	col.add_child(head)
	var hr := RbUi.hbox(10)
	head.add_child(hr)
	var th := RbUi.thumb(null, 36)
	th.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_head_thumb = TextureRect.new()
	_head_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_head_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	th.add_child(_head_thumb)
	hr.add_child(th)
	var names := RbUi.vbox(0)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	hr.add_child(names)
	_head_name = RbUi.label("")
	_head_name.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_head_name.clip_text = true
	_head_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	names.add_child(_head_name)
	_head_sub = RbUi.label("", "LabelFaint")
	_head_sub.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	names.add_child(_head_sub)
	hr.add_child(RbUi.icon_btn("pencil", func() -> void: action.emit("rename", null)))
	hr.add_child(RbUi.icon_btn("x", func() -> void: closed.emit()))
	col.add_child(RbUi.hline())
	_tabs_holder = RbUi.margins(12, 10, 12, 2)
	col.add_child(_tabs_holder)
	var scroll := RbTouchScroll.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var bm := RbUi.margins(12, 6, 12, 12)
	bm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(bm)
	_body = RbUi.vbox(8)
	bm.add_child(_body)


func show_layer(d: RbDocument, id: int) -> void:
	doc = d
	layer_id = id
	rebuild()


func rebuild() -> void:
	var l := doc.get_layer(layer_id) if doc else null
	if l == null:
		return
	_head_name.text = l.name
	_head_sub.text = (tr("SUB_GROUP") % l.children.size()) if l.is_group() else (tr("SUB_LAYER") % l.mesh_vertices.size())
	var img: Image = doc.images.get(l.image_id)
	_head_thumb.texture = ImageTexture.create_from_image(_small(img)) if img else RbIcons.tex("folder")
	for c in _tabs_holder.get_children():
		c.queue_free()
	if l.is_group():
		tab = 0
	else:
		_tabs_holder.add_child(RbUi.segments(["SHEET_TAB_LAYER", "SHEET_TAB_MESH", "SHEET_TAB_BIND"], tab, func(i: int) -> void:
			tab = i
			rebuild()))
	for c in _body.get_children():
		c.queue_free()
	if tab == 0:
		_build_layer_tab(l)
	elif tab == 1:
		_build_mesh_tab(l)
	else:
		_build_bind_tab(l)


## Привязка к костям: одна механика весов, снаружи три понятные кнопки.
func _build_bind_tab(_l: RbLayer) -> void:
	var st := RbUi.label(bind_status, "LabelDim")
	st.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	st.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(st)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	_body.add_child(grid)
	for a in [["bone", "BIND_RIGID", "bind_rigid"], ["refresh", "BIND_AUTO", "bind_auto"],
			["brush", "BIND_PAINT", "paint_weights"], ["x", "BIND_UNBIND", "unbind"]]:
		var key: String = a[2]
		var b := RbUi.text_btn("SecondaryButton", a[0], a[1], func() -> void: action.emit(key, null), 44)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		grid.add_child(b)
	var hint := RbUi.label("BIND_HINT", "LabelFaint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(hint)


func _build_layer_tab(l: RbLayer) -> void:
	_body.add_child(RbUi.slider_row("PROP_OPACITY", 0.0, 1.0, float(shown.call(l, &"opacity")) if shown.is_valid() else l.opacity,
		func(v: float) -> String: return "%d%%" % roundi(v * 100.0),
		func(v: float, done: bool) -> void: action.emit("opacity", [v, done])))
	var blend_row := RbUi.hbox(12)
	blend_row.custom_minimum_size.y = 48
	var bl := RbUi.label("PROP_BLEND", "LabelDim")
	bl.custom_minimum_size.x = 104
	blend_row.add_child(bl)
	var bb := RbUi.text_btn("SecondaryButton", "", "BLEND_" + l.blend_mode.to_upper(), func() -> void: action.emit("blend_menu", null), 40)
	bb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blend_row.add_child(bb)
	_body.add_child(blend_row)
	if l.kind == RbLayer.Kind.SWITCH and not l.children.is_empty():
		var idx := clampi(int(shown.call(l, &"switch_index")) if shown.is_valid() else l.switch_index, 0, l.children.size() - 1)
		var child := doc.get_layer(l.children[idx])
		var sw_row := RbUi.hbox(12)
		sw_row.custom_minimum_size.y = 48
		var sl := RbUi.label("PROP_VARIANT", "LabelDim")
		sl.custom_minimum_size.x = 104
		sw_row.add_child(sl)
		var sb := RbUi.text_btn("SecondaryButton", "", child.name if child else "?", func() -> void: action.emit("switch_menu", null), 40)
		sb.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		sb.clip_text = true
		sb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sw_row.add_child(sb)
		_body.add_child(sw_row)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	_body.add_child(grid)
	for a in [["arrow_up", "ACT_UP", "up"], ["arrow_down", "ACT_DOWN", "down"],
			["copy", "ACT_DUPLICATE", "duplicate"], ["flip", "ACT_FLIP", "flip"],
			["group", "ACT_GROUP", "group"], ["reset", "ACT_RESET", "reset"]]:
		var key: String = a[2]
		var b := RbUi.text_btn("SecondaryButton", a[0], a[1], func() -> void: action.emit(key, null), 44)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		grid.add_child(b)
	if l.image_id != "":
		var df := RbUi.text_btn("SecondaryButton", "brush", "ACT_DEFRINGE", func() -> void: action.emit("defringe", null), 44)
		df.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_body.add_child(df)
	var del := RbUi.text_btn("DangerButton", "trash", "ACT_DELETE", func() -> void: action.emit("delete", null), 44)
	_body.add_child(del)


func _build_mesh_tab(l: RbLayer) -> void:
	if not mesh_available:
		var e := RbUi.label("MESH_SOON", "LabelFaint")
		e.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_body.add_child(e)
		return
	_body.add_child(RbUi.slider_row("PROP_DENSITY", 0.0, 1.0, l.mesh_density,
		func(v: float) -> String: return "%d%%" % roundi(v * 100.0),
		func(v: float, done: bool) -> void:
			if done:
				action.emit("mesh_density", v)))
	var row := RbUi.hbox(8)
	_body.add_child(row)
	row.add_child(RbUi.expand(RbUi.text_btn("SecondaryButton", "mesh", "MESH_EDIT", func() -> void: action.emit("mesh_edit", null), 44)))
	row.add_child(RbUi.expand(RbUi.text_btn("PrimaryButton", "refresh", "MESH_REBUILD", func() -> void: action.emit("mesh_rebuild", null), 44)))
	var row2 := RbUi.hbox(8)
	_body.add_child(row2)
	row2.add_child(RbUi.expand(RbUi.text_btn("SecondaryButton", "square", "MESH_QUAD", func() -> void: action.emit("mesh_quad", null), 44)))
	var hint := RbUi.label("MESH_HINT", "LabelFaint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(hint)


func _small(img: Image) -> Image:
	var s := img.duplicate()
	var k := float(36 * RbIcons.scale * 1.5) / maxf(s.get_width(), s.get_height())
	if k < 1.0:
		s.resize(maxi(1, int(s.get_width() * k)), maxi(1, int(s.get_height() * k)), Image.INTERPOLATE_BILINEAR)
	return s
