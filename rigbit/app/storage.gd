class_name RbStorage
extends RefCounted
## Где живут проекты. На Android это Документы/Rigbit: папку видно в «Файлах», туда же можно класть
## свои PSD и картинки. Писать туда Android 11+ даёт и без разрешений, но пережить переустановку
## (прочитать файлы прошлой установки) можно только с «Доступом ко всем файлам».
## Если общая папка недоступна (и на ПК), проекты во внутренней папке приложения user://projects.

const PERM := "android.permission.MANAGE_EXTERNAL_STORAGE"
const INTERNAL := "user://projects"


static func shared_dir() -> String:
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join("Rigbit")


## Можно ли писать в общую папку. Проверяем делом (пробный файл), а не списком разрешений:
## Android 10 и ниже, 11+ и разные прошивки отвечают про MANAGE_EXTERNAL_STORAGE по-разному.
static func shared_writable() -> bool:
	if not OS.has_feature("android"):
		return false
	var dir := shared_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return false
	var probe := dir.path_join(".rigbit_probe")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true


static func has_permission() -> bool:
	return OS.get_granted_permissions().has(PERM)


## Системный экран «Доступ ко всем файлам» (Godot сам открывает нужные настройки).
static func request() -> void:
	OS.request_permission(PERM)


## Перенести файлы проектов из from в to. Совпадение имён: «Проект 1 (2).rigbit», ничего не затираем.
## Исходник удаляется, только если копия того же размера. Возвращает {старый путь: новый}.
static func migrate(from: String, to: String, ext: String) -> Dictionary:
	var moved := {}
	var d := DirAccess.open(from)
	if d == null or DirAccess.make_dir_recursive_absolute(to) != OK:
		return moved
	for f in d.get_files():
		if not f.ends_with("." + ext):
			continue
		var src := from.path_join(f)
		var dst := _free_name(to, f.get_basename(), ext)
		if DirAccess.copy_absolute(ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(dst)) != OK:
			continue
		if FileAccess.get_file_as_bytes(dst).size() != FileAccess.get_file_as_bytes(src).size():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dst))
			continue
		DirAccess.remove_absolute(ProjectSettings.globalize_path(src))
		moved[src] = dst
	return moved


static func _free_name(dir: String, base: String, ext: String) -> String:
	var p := dir.path_join("%s.%s" % [base, ext])
	var n := 2
	while FileAccess.file_exists(p):
		p = dir.path_join("%s (%d).%s" % [base, n, ext])
		n += 1
	return p
