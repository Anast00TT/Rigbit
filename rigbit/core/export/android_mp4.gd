class_name RbAndroidMp4
extends RbVideoEncoder
## MP4 (H.264) на Android системным кодировщиком: MediaCodec + MediaMuxer, без своих кодеков
## и без FFmpeg (лицензии, размер APK). Пока заглушка: supported() = false, MP4 в интерфейсе «скоро».
##
## План (дописать локально, проверять на LDPlayer, потом на телефоне по adb; design/export_research.md, вариант a):
##  1. Мост: JavaClassWrapper.wrap("android.media.MediaCodec") и т.д. (Godot 4.4+), без Gradle-плагина.
##     Если обёртка упрётся (поля enum'ов, byte[], колбэки), вариант b: маленький Kotlin-плагин
##     с тем же интерфейсом begin/add_frame/finish (схема из примеров Google Grafika, EncodeAndMuxTest).
##  2. begin: MediaFormat.createVideoFormat("video/avc", w, h); KEY_BIT_RATE, KEY_FRAME_RATE,
##     KEY_I_FRAME_INTERVAL = 1, KEY_COLOR_FORMAT; createEncoderByType; configure(..., CONFIGURE_FLAG_ENCODE);
##     MediaMuxer(path, MUXER_OUTPUT_MPEG_4). Путь: свой файл в user:// (globalize_path), наружу потом
##     копирует «Сохранить» (SAF), как у GIF.
##  3. Подача кадров, по надёжности:
##     a) входная Surface + lockHardwareCanvas (API 23+) + drawBitmap: Bitmap из RGBA через
##        copyPixelsFromBuffer(ByteBuffer.wrap(bytes)). Цвет в YUV переводит сам Android, капризов вендоров нет;
##     b) байтовый вход COLOR_FormatYUV420Flexible: перевод RGBA -> YUV420 на GPU отдельным проходом
##        RbFrameRenderer (в GDScript 2 Мпикс на кадр слишком медленно), раскладка по getInputImage().
##  4. Цикл: после каждого кадра забирать выход dequeueOutputBuffer: INFO_OUTPUT_FORMAT_CHANGED ->
##     muxer.addTrack + start; данные -> writeSampleData с presentationTimeUs = номер * 1e6 / fps.
##  5. finish: signalEndOfInputStream (Surface) или пустой буфер с BUFFER_FLAG_END_OF_STREAM, дочитать
##     выход до EOS, muxer.stop/release, codec.stop/release.
##  6. Размеры чётные (RbExportPlan делает), у некоторых кодировщиков кратные 16: проверять
##     MediaCodecInfo.VideoCapabilities.isSizeSupported, иначе подрезать до ближайшего поддерживаемого.
##  7. Прозрачности в H.264 нет: фон из настроек экспорта (RbExportPlan ставит transparent = false).


static func supported() -> bool:
	return false  # включить, когда мост заработает на устройстве
