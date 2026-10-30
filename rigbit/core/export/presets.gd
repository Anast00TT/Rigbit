class_name RbExportPresets
extends RefCounted
## Пресеты экспорта и проверка ограничений площадок. Ядро, без UI.
## Поля пресета:
##   id, name (рус.), format: "mp4" | "webm" | "gif" | "png_zip",
##   width/height: точный размер (0 = взять из холста),
##   max_side: длинная сторона не больше (и ровно столько при fit_side), 0 = нет,
##   fit_side: true = длинная сторона РОВНО max_side (Telegram: одна сторона ровно 512),
##   even: размеры чётные (yuv420 требует),
##   transparent: нужна альфа, fps: по умолчанию (0 = как у документа), max_fps,
##   max_seconds (0 = без лимита), max_bytes (0 = без лимита), codec, loop.

const TELEGRAM_STICKER_ID := "tg_sticker"

const PRESETS := [
	{
		"id": "tiktok", "name": "TikTok 9:16", "format": "mp4", "codec": "h264",
		"width": 1080, "height": 1920, "max_side": 0, "fit_side": false, "even": true,
		"transparent": false, "fps": 30, "max_fps": 60, "max_seconds": 600, "max_bytes": 0, "loop": false,
	},
	{
		"id": "square", "name": "Квадрат 1:1", "format": "mp4", "codec": "h264",
		"width": 1080, "height": 1080, "max_side": 0, "fit_side": false, "even": true,
		"transparent": false, "fps": 30, "max_fps": 60, "max_seconds": 0, "max_bytes": 0, "loop": false,
	},
	{
		"id": "tg_sticker", "name": "Telegram стикер", "format": "webm", "codec": "vp9",
		"width": 0, "height": 0, "max_side": 512, "fit_side": true, "even": true,
		"transparent": true, "fps": 0, "max_fps": 30, "max_seconds": 3.0, "max_bytes": 256 * 1024, "loop": true,
	},
	{
		"id": "png_zip", "name": "PNG-секвенция", "format": "png_zip", "codec": "png",
		"width": 0, "height": 0, "max_side": 0, "fit_side": false, "even": false,
		"transparent": true, "fps": 0, "max_fps": 0, "max_seconds": 0, "max_bytes": 0, "loop": false,
	},
	{
		"id": "gif", "name": "GIF", "format": "gif", "codec": "gif",
		"width": 0, "height": 0, "max_side": 512, "fit_side": false, "even": false,
		"transparent": false, "fps": 24, "max_fps": 50, "max_seconds": 0, "max_bytes": 0, "loop": true,
	},
]


static func all() -> Array:
	return PRESETS.duplicate(true)


## Пресет по id (копия) или {} если нет такого.
static func get_preset(id: String) -> Dictionary:
	for p: Dictionary in PRESETS:
		if p["id"] == id:
			return p.duplicate(true)
	return {}


## Размер вывода для холста документа.
static func export_size(preset: Dictionary, canvas: Vector2i) -> Vector2i:
	var w := int(preset.get("width", 0))
	var h := int(preset.get("height", 0))
	if w > 0 and h > 0:
		return Vector2i(w, h)
	var size := canvas
	var max_side := int(preset.get("max_side", 0))
	var side := maxi(canvas.x, canvas.y)
	if max_side > 0 and (side > max_side or bool(preset.get("fit_side", false))):
		var k := float(max_side) / side
		size = Vector2i(maxi(1, roundi(canvas.x * k)), maxi(1, roundi(canvas.y * k)))
		# длинная сторона ровно max_side, без накопленной ошибки округления
		if canvas.x >= canvas.y:
			size.x = max_side
		else:
			size.y = max_side
	if bool(preset.get("even", false)):
		size = Vector2i(maxi(2, size.x + (size.x & 1)), maxi(2, size.y + (size.y & 1)))
		if max_side > 0:
			size = Vector2i(mini(size.x, max_side), mini(size.y, max_side))
	return size


## fps вывода: пресетный/документа, но не выше max_fps.
static func export_fps(preset: Dictionary, doc_fps: int) -> int:
	var f := int(preset.get("fps", 0))
	if f <= 0:
		f = doc_fps
	var mx := int(preset.get("max_fps", 0))
	return mini(f, mx) if mx > 0 else f


## Сколько кадров влезает в max_seconds при данном fps (-1 = без лимита).
static func max_frames(preset: Dictionary, fps: int) -> int:
	var s := float(preset.get("max_seconds", 0))
	if s <= 0.0:
		return -1
	return int(floor(s * fps + 0.0001))


## Проверка параметров экспорта. info: {width, height, fps, frames, bytes (необязательно), alpha (необязательно)}.
## Возвращает список предупреждений по-русски; пустой = всё в рамках.
static func validate(preset: Dictionary, info: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var w := int(info.get("width", 0))
	var h := int(info.get("height", 0))
	var fps := float(info.get("fps", 0))
	var frames := int(info.get("frames", 0))
	var name := str(preset.get("name", ""))
	var secs := frames / fps if fps > 0.0 else 0.0
	var max_s := float(preset.get("max_seconds", 0))
	if max_s > 0.0 and secs > max_s + 0.0001:
		out.append("%s: длительность %.1f с, максимум %.1f с (лишнее будет обрезано)." % [name, secs, max_s])
	var max_f := float(preset.get("max_fps", 0))
	if max_f > 0.0 and fps > max_f + 0.0001:
		out.append("%s: %d fps, максимум %d fps." % [name, int(fps), int(max_f)])
	var max_side := int(preset.get("max_side", 0))
	if max_side > 0:
		if maxi(w, h) > max_side:
			out.append("%s: сторона %d px, максимум %d px." % [name, maxi(w, h), max_side])
		elif bool(preset.get("fit_side", false)) and maxi(w, h) != max_side:
			out.append("%s: одна сторона должна быть ровно %d px (сейчас %dx%d)." % [name, max_side, w, h])
	var fw := int(preset.get("width", 0))
	var fh := int(preset.get("height", 0))
	if fw > 0 and fh > 0 and (w != fw or h != fh):
		out.append("%s: размер %dx%d, нужен %dx%d." % [name, w, h, fw, fh])
	if bool(preset.get("even", false)) and ((w & 1) == 1 or (h & 1) == 1):
		out.append("%s: размеры должны быть чётными (%dx%d)." % [name, w, h])
	var max_b := int(preset.get("max_bytes", 0))
	var bytes := int(info.get("bytes", -1))
	if max_b > 0 and bytes > max_b:
		out.append("%s: файл %d КБ, максимум %d КБ." % [name, ceili(bytes / 1024.0), max_b / 1024])
	if bool(preset.get("transparent", false)) and info.has("alpha") and not bool(info["alpha"]) \
			and str(preset.get("id", "")) == TELEGRAM_STICKER_ID:
		out.append("%s: фон непрозрачный, стикер будет с подложкой." % name)
	if frames < 1:
		out.append("%s: нет кадров." % name)
	return out
