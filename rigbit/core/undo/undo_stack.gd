class_name RbUndoStack
extends RefCounted
## История на командном паттерне. Ограничена числом шагов и памятью.

signal changed

var max_steps: int = 200
var max_bytes: int = 256 * 1024 * 1024

var _done: Array[RbCommand] = []
var _undone: Array[RbCommand] = []
var _doc: RbDocument
var _merge_open := false  # можно ли склеивать следующую команду с последней


func _init(doc: RbDocument) -> void:
	_doc = doc


## Выполнить и записать. already_done = команда уже применена (живое перетаскивание).
## mergeable = разрешить склейку с предыдущей (внутри одного жеста).
func push(cmd: RbCommand, already_done := false, mergeable := false) -> void:
	if not already_done:
		cmd.do_it(_doc)
	_undone.clear()
	if mergeable and _merge_open and not _done.is_empty() and _done.back().merge(cmd):
		changed.emit()
		return
	_done.append(cmd)
	_merge_open = mergeable
	_trim()
	changed.emit()


## Закрыть текущий жест: следующая команда уже не склеится.
func end_gesture() -> void:
	_merge_open = false


func can_undo() -> bool:
	return not _done.is_empty()


func can_redo() -> bool:
	return not _undone.is_empty()


func undo() -> bool:
	if _done.is_empty():
		return false
	var cmd: RbCommand = _done.pop_back()
	cmd.undo_it(_doc)
	_undone.append(cmd)
	_merge_open = false
	changed.emit()
	return true


func redo() -> bool:
	if _undone.is_empty():
		return false
	var cmd: RbCommand = _undone.pop_back()
	cmd.do_it(_doc)
	_done.append(cmd)
	_merge_open = false
	changed.emit()
	return true


## Откатить последнюю команду без возможности redo (отменённый жест).
func cancel_last() -> void:
	if _done.is_empty():
		return
	_done.pop_back().undo_it(_doc)
	_merge_open = false
	changed.emit()


func clear() -> void:
	_done.clear()
	_undone.clear()
	_merge_open = false
	changed.emit()


func size() -> int:
	return _done.size()


func _trim() -> void:
	while _done.size() > max_steps:
		_done.pop_front()
	var total := 0
	for c in _done:
		total += c.cost_bytes()
	while total > max_bytes and _done.size() > 1:
		total -= _done.pop_front().cost_bytes()
