class_name RbAndroidMp4
extends RbVideoEncoder
## MP4 (H.264) на Android системным кодировщиком: MediaCodec + MediaMuxer через JavaClassWrapper,
## без своих кодеков, без FFmpeg и без Gradle-плагина (design/export_research.md, вариант a).
##
## Кадр: RGBA -> Bitmap (copyPixelsFromBuffer) -> входная Surface кодировщика (lockHardwareCanvas),
## цвет в YUV переводит сам Android. Время кадра у Surface системное, поэтому профиль Baseline
## (без B-кадров: выход идёт в том же порядке, что вход) и время в MP4 ставим сами: номер / fps.
## Поля BufferInfo обёртка не читает, offset/size/flags берём через reflection (Field.getInt);
## ByteBuffer.position() не годится: обёртка выбирает перегрузку position(int).
## Прозрачности в H.264 нет: фон из настроек экспорта (RbExportPlan ставит transparent = false).

const TIMEOUT_US := 10_000
const EOS_TRIES := 300  # ~3 с ждать хвост после конца входа
const FLAG_CODEC_CONFIG := 2
const FLAG_EOS := 4
const INFO_TRY_AGAIN := -1
const INFO_FORMAT_CHANGED := -2

var _codec: JavaObject
var _muxer: JavaObject
var _surface: JavaObject
var _bitmap: JavaObject
var _paint: JavaObject
var _info: JavaObject
var _out_info: JavaObject
var _flags_field: JavaObject
var _size_field: JavaObject
var _offset_field: JavaObject
var _byte_buffer: JavaClass
var _track := -1
var _muxing := false
var _written := 0
var _fps := 30
var _size := Vector2i.ZERO


static func supported() -> bool:
	if not OS.has_feature("android"):
		return false
	var ver := JavaClassWrapper.wrap("android.os.Build$VERSION")
	return ver != null and int(ver.SDK_INT) >= 23  # lockHardwareCanvas


func begin(path: String, size: Vector2i, fps: int, bitrate: int) -> Error:
	_size = size
	_fps = maxi(fps, 1)
	var mf := JavaClassWrapper.wrap("android.media.MediaFormat")
	var caps := JavaClassWrapper.wrap("android.media.MediaCodecInfo$CodecCapabilities")
	var prof := JavaClassWrapper.wrap("android.media.MediaCodecInfo$CodecProfileLevel")
	var mc := JavaClassWrapper.wrap("android.media.MediaCodec")
	var fmt: JavaObject = mf.createVideoFormat("video/avc", size.x, size.y)
	fmt.setInteger(mf.KEY_COLOR_FORMAT, caps.COLOR_FormatSurface)
	fmt.setInteger(mf.KEY_BIT_RATE, bitrate)
	fmt.setInteger(mf.KEY_FRAME_RATE, _fps)
	fmt.setInteger(mf.KEY_I_FRAME_INTERVAL, 1)
	fmt.setInteger(mf.KEY_PROFILE, prof.AVCProfileBaseline)
	fmt.setInteger(mf.KEY_LEVEL, prof.AVCLevel41)
	_codec = mc.createEncoderByType("video/avc")
	if _failed("createEncoderByType") or _codec == null:
		return ERR_UNAVAILABLE
	_codec.configure(fmt, null, null, mc.CONFIGURE_FLAG_ENCODE)
	if _failed("configure"):
		return ERR_UNAVAILABLE
	_surface = _codec.createInputSurface()
	_codec.start()
	if _failed("start") or _surface == null:
		return ERR_UNAVAILABLE
	var mm := JavaClassWrapper.wrap("android.media.MediaMuxer")
	var of := JavaClassWrapper.wrap("android.media.MediaMuxer$OutputFormat")
	_muxer = mm.MediaMuxer(path, of.MUXER_OUTPUT_MPEG_4)
	if _failed("MediaMuxer") or _muxer == null:
		return ERR_CANT_CREATE
	var cfg := JavaClassWrapper.wrap("android.graphics.Bitmap$Config")
	_bitmap = JavaClassWrapper.wrap("android.graphics.Bitmap").createBitmap(size.x, size.y, cfg.valueOf("ARGB_8888"))
	_paint = JavaClassWrapper.wrap("android.graphics.Paint").Paint()
	var bi := JavaClassWrapper.wrap("android.media.MediaCodec$BufferInfo")
	# Конструктор вложенного класса зовётся по имени с внешним классом.
	_info = bi.call("MediaCodec$BufferInfo")
	_out_info = bi.call("MediaCodec$BufferInfo")
	var cls: JavaObject = _info.getClass()
	_flags_field = cls.getField("flags")
	_size_field = cls.getField("size")
	_offset_field = cls.getField("offset")
	_byte_buffer = JavaClassWrapper.wrap("java.nio.ByteBuffer")
	if _failed("setup") or _bitmap == null or _flags_field == null:
		return ERR_UNAVAILABLE
	print("MP4 begin %dx%d %d fps %d bit/s" % [size.x, size.y, _fps, bitrate])
	return OK


func add_frame(img: Image) -> Error:
	if _codec == null:
		return ERR_UNCONFIGURED
	if img.get_format() != Image.FORMAT_RGBA8:
		img = img.duplicate()
		img.convert(Image.FORMAT_RGBA8)
	# ARGB_8888 в памяти Android лежит как R,G,B,A: байты Godot подходят как есть.
	_bitmap.copyPixelsFromBuffer(_byte_buffer.wrap(img.get_data()))
	var canvas: JavaObject = _surface.lockHardwareCanvas()
	if _failed("lockHardwareCanvas") or canvas == null:
		return ERR_CANT_ACQUIRE_RESOURCE
	canvas.drawBitmap(_bitmap, 0.0, 0.0, _paint)
	_surface.unlockCanvasAndPost(canvas)
	if _failed("drawBitmap"):
		return ERR_CANT_ACQUIRE_RESOURCE
	return _drain(false)


func finish() -> Error:
	if _codec == null:
		return ERR_UNCONFIGURED
	_codec.signalEndOfInputStream()
	var err := _drain(true)
	if err == OK and not _muxing:
		err = ERR_FILE_CORRUPT  # кодировщик не отдал ни одного кадра
	if _muxing:
		_muxer.stop()
		if _failed("muxer.stop"):
			err = ERR_FILE_CORRUPT
	print("MP4 finish frames=%d err=%d" % [_written, err])
	_release()
	return err


func cancel() -> void:
	if _muxing:
		_muxer.stop()
		_failed("muxer.stop")
	_release()


## Забрать готовое из кодировщика. В конце (eos) ждём, пока не придёт флаг конца потока.
func _drain(eos: bool) -> Error:
	var tries := 0
	while true:
		var idx := int(_codec.dequeueOutputBuffer(_info, TIMEOUT_US if eos else 0))
		if _failed("dequeueOutputBuffer"):
			return ERR_BUG
		if idx == INFO_TRY_AGAIN:
			if not eos:
				return OK
			tries += 1
			if tries > EOS_TRIES:
				push_warning("MP4: кодировщик не дослал конец потока")
				return OK if _muxing else ERR_TIMEOUT
			continue
		if idx == INFO_FORMAT_CHANGED:
			_track = int(_muxer.addTrack(_codec.getOutputFormat()))
			_muxer.start()
			_muxing = not _failed("muxer.start")
			if not _muxing:
				return ERR_CANT_CREATE
			continue
		if idx < 0:
			continue  # устаревшее INFO_OUTPUT_BUFFERS_CHANGED
		var flags := int(_flags_field.getInt(_info))
		var n := int(_size_field.getInt(_info))
		var buf: JavaObject = _codec.getOutputBuffer(idx)
		if n > 0 and buf != null and _muxing and flags & FLAG_CODEC_CONFIG == 0:
			# Время свое: номер / fps. Baseline без B-кадров, порядок выхода = порядок входа.
			# call(): у Object есть свой set(), а нужен BufferInfo.set(offset, size, timeUs, flags).
			_out_info.call("set", int(_offset_field.getInt(_info)), n, _written * 1_000_000 / _fps, flags)
			_muxer.writeSampleData(_track, buf, _out_info)
			if _failed("writeSampleData"):
				return ERR_FILE_CANT_WRITE
			_written += 1
		_codec.releaseOutputBuffer(idx, false)
		if flags & FLAG_EOS:
			return OK
	return OK


func _release() -> void:
	for o: JavaObject in [_codec, _muxer, _surface, _bitmap]:
		if o != null:
			o.release() if o != _bitmap else o.recycle()
	JavaClassWrapper.get_exception()  # release после stop может ругнуться, это не ошибка
	_codec = null
	_muxer = null
	_surface = null
	_bitmap = null
	_muxing = false


## Исключение Java из последнего вызова (обёртка его ловит и возвращает null).
func _failed(what: String) -> bool:
	var e: JavaObject = JavaClassWrapper.get_exception()
	if e == null:
		return false
	push_error("MP4 %s: %s" % [what, e.toString()])
	return true
