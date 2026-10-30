class_name RbPanel
extends PanelContainer
## Основа боковых панелей (параметры, констрейны кости, эффекты): шапка с заголовком, ✕ и прокручиваемое тело.
## Телефон в портрете: снизу. Широкий экран: справа от вьюпорта (расставляет главный экран).

signal closed

var body: VBoxContainer
var scroll: ScrollContainer
var head_row: HBoxContainer

var _title: Label
var _sub: Label
var _keep_scroll := 0


func _init(title_key := "") -> void:
	theme_type_variation = "Sheet"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var col := RbUi.vbox(0)
	add_child(col)
	var head := RbUi.margins(12, 4, 4, 4)
	col.add_child(head)
	head_row = RbUi.hbox(8)
	head.add_child(head_row)
	var names := RbUi.vbox(0)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	head_row.add_child(names)
	_title = RbUi.label(title_key, "LabelTitle")
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	names.add_child(_title)
	_sub = RbUi.label("", "LabelFaint")
	_sub.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_sub.clip_text = true
	_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_sub.visible = false
	names.add_child(_sub)
	head_row.add_child(RbUi.icon_btn("x", func() -> void: closed.emit()))
	col.add_child(RbUi.hline())
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var bm := RbUi.margins(12, 8, 12, 12)
	bm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(bm)
	body = RbUi.vbox(8)
	bm.add_child(body)


## Заголовок: ключ перевода или готовый текст.
func set_title(text: String, is_key := true) -> void:
	_title.text = text
	_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_INHERIT if is_key else Node.AUTO_TRANSLATE_MODE_DISABLED


func set_sub(text: String) -> void:
	_sub.text = text
	_sub.visible = text != ""


## Кнопка в шапке перед ✕.
func add_head_button(icon: String, cb: Callable) -> Button:
	var b := RbUi.icon_btn(icon, cb)
	head_row.add_child(b)
	head_row.move_child(b, head_row.get_child_count() - 2)
	return b


## Очистить тело перед перестройкой (положение прокрутки запоминается).
func begin_rebuild() -> void:
	_keep_scroll = scroll.scroll_vertical
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()


func end_rebuild() -> void:
	if _keep_scroll > 0:
		_restore_scroll.call_deferred()


func _restore_scroll() -> void:
	await get_tree().process_frame
	scroll.scroll_vertical = _keep_scroll


## Для скриншотов: прокрутить тело на px вниз.
func scroll_to(px: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	scroll.scroll_vertical = px
