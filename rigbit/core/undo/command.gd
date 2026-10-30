class_name RbCommand
extends RefCounted
## Базовая команда. Всё, что меняет документ, делается командой, иначе undo врёт.

var label: String = ""


func do_it(_doc: RbDocument) -> void:
	pass


func undo_it(_doc: RbDocument) -> void:
	pass


## Склеить с более новой командой (например, шаги одного перетаскивания). true = склеено.
func merge(_newer: RbCommand) -> bool:
	return false


## Примерный вес в памяти (для лимита истории, важно для пиксельных операций).
func cost_bytes() -> int:
	return 256
