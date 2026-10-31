class_name RbVideoEncoder
extends RefCounted
## Видеокодировщик экспорта (MP4, потом WebM). Кадры по одному, в памяти не копятся:
##   var enc := RbVideoEncoder.create("mp4")   # null = на этой платформе формата нет
##   enc.begin(path, size, fps, bitrate) -> add_frame(img) × N -> finish()   (или cancel())
## Реализации по платформам. Пока ни одна не говорит supported(), формат в интерфейсе серый «скоро».
## Android MP4: core/export/android_mp4.gd (дописывается в локальной сессии, план внутри).


static func create(format: String) -> RbVideoEncoder:
	if format == "mp4" and RbAndroidMp4.supported():
		return RbAndroidMp4.new()
	return null


static func available(format: String) -> bool:
	match format:
		"mp4":
			return RbAndroidMp4.supported()
	return false


## Битрейт по размеру и fps: ~0.1 бита на пиксель в кадре, как у роликов TikTok (1080x1920x30 ≈ 6 Мбит/с).
static func bitrate_for(size: Vector2i, fps: int) -> int:
	return clampi(roundi(size.x * size.y * fps * 0.1), 500_000, 20_000_000)


func begin(_path: String, _size: Vector2i, _fps: int, _bitrate: int) -> Error:
	return ERR_UNAVAILABLE


## Кадр RGBA8 ровно размера из begin(). Время кадра = номер / fps.
func add_frame(_img: Image) -> Error:
	return ERR_UNAVAILABLE


## Дописать хвост и закрыть файл (moov у MP4). После этого файл готов.
func finish() -> Error:
	return ERR_UNAVAILABLE


## Бросить запись: освободить кодировщик, недописанный файл удалит вызывающий.
func cancel() -> void:
	pass
