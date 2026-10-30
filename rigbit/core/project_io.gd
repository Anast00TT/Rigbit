class_name RbProjectIO
extends RefCounted
## Формат проекта .rigbit: zip-контейнер
##   document.json  — структура (с format_version)
##   images/<id>.png — текстуры слоёв
##   images/<id>.svg — исходный SVG картинки, если она из вектора (RbDocument.svgs)

const EXT := "rigbit"


static func save(doc: RbDocument, path: String) -> Error:
	var tmp := path + ".tmp"
	var zip := ZIPPacker.new()
	var err := zip.open(tmp)
	if err != OK:
		return err
	zip.start_file("document.json")
	zip.write_file(JSON.stringify(doc.to_dict(), "\t").to_utf8_buffer())
	zip.close_file()
	for key: String in doc.images:
		var img: Image = doc.images[key]
		zip.start_file("images/%s.png" % key)
		var cached: Array = doc.png_cache.get(key, [])
		if cached.is_empty() or cached[0] != img:
			cached = [img, img.save_png_to_buffer()]
			doc.png_cache[key] = cached
		zip.write_file(cached[1])
		zip.close_file()
	for key: String in doc.svgs:
		if doc.images.has(key):
			zip.start_file("images/%s.svg" % key)
			zip.write_file((doc.svgs[key] as String).to_utf8_buffer())
			zip.close_file()
	zip.close()
	# атомарная замена: Android может убить процесс посреди записи
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return ERR_CANT_OPEN
	if FileAccess.file_exists(path):
		dir.remove(path)
	return dir.rename(tmp, path)


static func load_doc(path: String) -> RbDocument:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return null
	var raw := zip.read_file("document.json")
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not parsed is Dictionary:
		zip.close()
		return null
	var d: Dictionary = migrate(parsed)
	var doc := RbDocument.from_dict(d)
	for f in zip.get_files():
		if f.begins_with("images/") and f.ends_with(".png"):
			var img := Image.new()
			if img.load_png_from_buffer(zip.read_file(f)) == OK:
				doc.images[f.get_file().get_basename()] = img
		elif f.begins_with("images/") and f.ends_with(".svg"):
			doc.svgs[f.get_file().get_basename()] = zip.read_file(f).get_string_from_utf8()
	zip.close()
	return doc


## Миграции между версиями формата. Каждая функция поднимает версию на 1.
static func migrate(d: Dictionary) -> Dictionary:
	var v := int(d.get("format_version", 1))
	while v < RbDocument.FORMAT_VERSION:
		match v:
			# 1: d = _v1_to_v2(d)   ← сюда добавлять шаги
			_:
				pass
		v += 1
		d["format_version"] = v
	return d
