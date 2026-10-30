class_name RbExportPlan
extends RefCounted
## Что именно экспортировать: формат, размер, fps, кадры, фон. Ядро без UI, проверяется тестами.
## Настройки: {format: "gif" | "png_zip", long_side: int (0 = как холст), fps: int,
##   from: int, to: int (кадры документа включительно), transparent: bool}.
## MP4/WebM в интерфейсе пока «скоро»: им нужен Android-плагин (design/export_research.md).

const FORMATS := ["gif", "png_zip"]
const SOON := ["mp4", "webm"]
const SIDES := [256, 512, 1024, 0]  # 0 = размер холста
const FPS_CHOICES := [12, 24, 30]
## Кадры GIF держатся в памяти целиком (общая палитра): дальше этого предела отказываемся
const GIF_MAX_BYTES := 384 * 1024 * 1024
const GIF_MAX_SIDE := 1024


static func defaults(doc: RbDocument, format: String) -> Dictionary:
	return {
		"format": format,
		"long_side": 512 if format == "gif" else 0,
		"fps": doc.fps if doc.fps in fps_choices(doc.fps) else 24,
		"from": 0,
		"to": maxi(doc.frame_count - 1, 0),
		"transparent": format == "png_zip",
	}


## Варианты fps: стандартные плюс fps документа, если он другой.
static func fps_choices(doc_fps: int) -> Array:
	var out := FPS_CHOICES.duplicate()
	if doc_fps > 0 and not doc_fps in out:
		out.append(doc_fps)
		out.sort()
	return out


## Размер вывода: длинная сторона ровно long_side (и уменьшение, и увеличение), пропорции холста.
static func out_size(canvas: Vector2i, long_side: int) -> Vector2i:
	if long_side <= 0:
		return Vector2i(maxi(canvas.x, 1), maxi(canvas.y, 1))
	var side := maxi(canvas.x, canvas.y)
	var k := float(long_side) / float(maxi(side, 1))
	var s := Vector2i(maxi(1, roundi(canvas.x * k)), maxi(1, roundi(canvas.y * k)))
	if canvas.x >= canvas.y:
		s.x = long_side
	else:
		s.y = long_side
	return s


## Кадры документа для каждого кадра вывода. Длительность сохраняется: 48 кадров при 24 fps
## в 12 fps дают 24 кадра (через один), в 30 fps 60 кадров (некоторые повторяются).
static func source_frames(from: int, to: int, doc_fps: int, out_fps: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var a := mini(from, to)
	var b := maxi(from, to)
	if doc_fps <= 0 or out_fps <= 0:
		return out
	var count := b - a + 1
	var n := maxi(1, roundi(float(count) * out_fps / doc_fps))
	for i in n:
		out.append(mini(a + floori(float(i) * doc_fps / out_fps + 0.0001), b))
	return out


static func duration(from: int, to: int, doc_fps: int) -> float:
	return float(absi(to - from) + 1) / float(maxi(doc_fps, 1))


static func ext(format: String) -> String:
	return "gif" if format == "gif" else "zip"


## Имя файла: имя проекта без расширения, иначе Rigbit. Небезопасные символы убираются.
static func file_name(project_path: String, format: String) -> String:
	var base := project_path.get_file().get_basename() if project_path != "" else ""
	base = base.validate_filename().strip_edges()
	if base == "" or base.begins_with("autosave"):
		base = "Rigbit"
	return "%s.%s" % [base, ext(format)]


## Проблемы до запуска: [[ключ локализации, аргументы...]]. Ключ с "ERR" = экспорт невозможен.
static func problems(doc: RbDocument, s: Dictionary) -> Array:
	var out: Array = []
	if doc.root.is_empty():
		out.append(["EXPORT_ERR_EMPTY"])
	var size := out_size(doc.canvas_size, int(s["long_side"]))
	var frames := source_frames(int(s["from"]), int(s["to"]), doc.fps, int(s["fps"])).size()
	if s["format"] == "gif":
		if maxi(size.x, size.y) > GIF_MAX_SIDE:
			out.append(["EXPORT_WARN_GIF_BIG"])
		if frames * size.x * size.y * 4 > GIF_MAX_BYTES:
			out.append(["EXPORT_ERR_GIF_MEM"])
		if s["transparent"]:
			out.append(["EXPORT_WARN_GIF_ALPHA"])
	return out


static func can_run(probs: Array) -> bool:
	for p in probs:
		if (p[0] as String).contains("ERR"):
			return false
	return true
