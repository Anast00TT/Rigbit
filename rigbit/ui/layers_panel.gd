class_name RbLayersPanel
extends PanelContainer
## Дерево слоёв поверх вьюпорта (закрывает его целиком, инструменты справа видны).
## Верх списка = верхний слой. Тап по строке выделяет, глаз прячет, тап по иконке группы сворачивает.

signal picked(id: int)
signal visibility_toggled(id: int)
signal closed
signal import_requested
signal group_requested

var doc: RbDocument
var selected_id := 0
var _collapsed := {}
var _thumbs := {}  # image_id -> [Image, ImageTexture]
var _list: VBoxContainer
var _title: Label


func _init() -> void:
	theme_type_variation = "Sheet"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var col := RbUi.vbox(0)
	add_child(col)
	var head := RbUi.margins(14, 4, 4, 4)
	col.add_child(head)
	var hr := RbUi.hbox(4)
	head.add_child(hr)
	_title = RbUi.label("LAYERS_TITLE", "LabelTitle")
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hr.add_child(_title)
	hr.add_child(RbUi.icon_btn("x", func() -> void: closed.emit()))
	col.add_child(RbUi.hline())
	var scroll := RbTouchScroll.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var lm := RbUi.margins(6, 6, 6, 6)
	lm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(lm)
	_list = RbUi.vbox(2)
	lm.add_child(_list)
	col.add_child(RbUi.hline())
	var foot := RbUi.margins(8, 8, 8, 8)
	col.add_child(foot)
	var fr := RbUi.hbox(8)
	foot.add_child(fr)
	fr.add_child(RbUi.expand(RbUi.text_btn("SecondaryButton", "import", "LAYERS_IMPORT", func() -> void: import_requested.emit())))
	fr.add_child(RbUi.expand(RbUi.text_btn("SecondaryButton", "group", "LAYER_GROUP", func() -> void: group_requested.emit())))


func rebuild() -> void:
	if doc == null or not is_inside_tree():
		return
	for c in _list.get_children():
		c.queue_free()
	var count := 0
	for l in doc.draw_order():
		if not l.is_group():
			count += 1
	_title.text = tr("LAYERS_TITLE_N") % count
	if doc.root.is_empty():
		var e := RbUi.label("LAYERS_EMPTY", "LabelFaint")
		e.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		e.custom_minimum_size.y = 64
		e.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_list.add_child(e)
		return
	_add_rows(doc.root, 0)


## Верхние слои показываем сверху, поэтому идём по списку с конца.
func _add_rows(ids: Array[int], depth: int) -> void:
	for i in range(ids.size() - 1, -1, -1):
		var l := doc.get_layer(ids[i])
		if l == null:
			continue
		_list.add_child(_row(l, depth))
		if l.is_group() and not _collapsed.get(l.id, false):
			_add_rows(l.children, depth + 1)


func _row(l: RbLayer, depth: int) -> Control:
	var b := Button.new()
	b.theme_type_variation = "RowButton"
	b.toggle_mode = true
	b.button_pressed = l.id == selected_id
	b.custom_minimum_size.y = 52
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void: picked.emit(l.id))
	var m := RbUi.margins(4 + depth * 18, 0, 0, 0)
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(m)
	var h := RbUi.hbox(10)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(h)
	if l.is_group():
		var g := RbUi.icon_btn("folder" if not _collapsed.get(l.id, false) else "folder_closed", func() -> void:
			_collapsed[l.id] = not _collapsed.get(l.id, false)
			rebuild(), 36, 36)
		g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(g)
	else:
		var th := RbUi.thumb(null, 36)
		th.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var tr_ := TextureRect.new()
		tr_.texture = _thumb_tex(l.image_id)
		tr_.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr_.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr_.mouse_filter = Control.MOUSE_FILTER_IGNORE
		th.add_child(tr_)
		h.add_child(th)
	var names := RbUi.vbox(0)
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(names)
	var nl := RbUi.label(l.name)
	nl.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nl.clip_text = true
	names.add_child(nl)
	var sub := RbUi.label(_subtitle(l), "LabelFaint")
	sub.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	sub.clip_text = true
	names.add_child(sub)
	var eye := RbUi.icon_btn("eye" if l.visible else "eye_off", func() -> void: visibility_toggled.emit(l.id), 44, 44)
	eye.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if not l.visible:
		eye.modulate = Color(1, 1, 1, 0.5)
		nl.modulate = Color(1, 1, 1, 0.5)
	h.add_child(eye)
	return b


func _subtitle(l: RbLayer) -> String:
	if l.is_group():
		return tr("SUB_GROUP") % l.children.size()
	var s := tr("SUB_LAYER") % l.mesh_vertices.size()
	if l.opacity < 0.999:
		s += " · %d%%" % roundi(l.opacity * 100.0)
	return s


func _thumb_tex(image_id: String) -> Texture2D:
	var img: Image = doc.images.get(image_id)
	if img == null:
		return null
	var e: Array = _thumbs.get(image_id, [])
	if e.is_empty() or e[0] != img:
		var small := img.duplicate()
		var k := float(36 * RbIcons.scale * 1.5) / maxf(small.get_width(), small.get_height())
		if k < 1.0:
			small.resize(maxi(1, int(small.get_width() * k)), maxi(1, int(small.get_height() * k)), Image.INTERPOLATE_BILINEAR)
		e = [img, ImageTexture.create_from_image(small)]
		_thumbs[image_id] = e
	return e[1]
