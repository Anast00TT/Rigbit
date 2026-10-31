class_name RbTouchScroll
extends ScrollContainer
## Список, который крутится пальцем. Кнопка по умолчанию глушит касание (MOUSE_FILTER_STOP),
## и свайп по строке до ScrollContainer не доходит. Поэтому всем кнопкам внутри ставим PASS,
## в том числе тем, что появятся позже (списки пересобираются).


func _init() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED


func _enter_tree() -> void:
	get_tree().node_added.connect(_on_node_added)
	for b in find_children("*", "BaseButton", true, false):
		_on_node_added(b)


func _exit_tree() -> void:
	get_tree().node_added.disconnect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if n is BaseButton and is_ancestor_of(n):
		(n as Control).mouse_filter = Control.MOUSE_FILTER_PASS
