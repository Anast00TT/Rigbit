extends RefCounted
## Переезд проектов во внешнюю папку (RbStorage.migrate).

var t  # раннер

const FROM := "user://test_storage_from"
const TO := "user://test_storage_to"


func _put(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	for dir in [FROM, TO]:
		var d := DirAccess.open(dir)
		if d:
			for f in d.get_files():
				DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


func test_migrate() -> void:
	_clean()
	DirAccess.make_dir_recursive_absolute(FROM)
	DirAccess.make_dir_recursive_absolute(TO)
	_put(FROM.path_join("Проект 1.rigbit"), "один")
	_put(FROM.path_join("Проект 2.rigbit"), "два")
	_put(FROM.path_join("заметка.txt"), "не проект")
	_put(TO.path_join("Проект 1.rigbit"), "уже был")
	var moved := RbStorage.migrate(FROM, TO, "rigbit")
	t.eq(moved.size(), 2, "переехали оба проекта")
	t.eq(moved[FROM.path_join("Проект 1.rigbit")], TO.path_join("Проект 1 (2).rigbit"), "совпадение имён: суффикс, не затираем")
	t.eq(FileAccess.get_file_as_string(TO.path_join("Проект 1.rigbit")), "уже был", "старый файл цел")
	t.eq(FileAccess.get_file_as_string(TO.path_join("Проект 2.rigbit")), "два", "содержимое на месте")
	t.check(not FileAccess.file_exists(FROM.path_join("Проект 2.rigbit")), "из старой папки убран")
	t.check(FileAccess.file_exists(FROM.path_join("заметка.txt")), "чужие файлы не трогаем")
	t.eq(RbStorage.migrate(FROM, TO, "rigbit").size(), 0, "повторно нечего переносить")
	_clean()
