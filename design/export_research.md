# Экспорт видео в Rigbit: MP4 (H.264) и WebM VP9 с альфой на Android

Дата: 13.10.2026. Godot 4.7.2, рендер gl_compatibility, APK сейчас собирается без Gradle
(`gradle_build/use_gradle_build=false`), ABI arm64-v8a + x86_64.

## Что уже есть и работает (без нативного кода)
- `RbFrameRenderer`: кадр документа в Image на размере экспорта, прозрачный фон, 512x512 за 6 мс/кадр (+16 мс на unpremultiply для прозрачных).
- `RbGifEncoder`, `RbPngSequence`: чистый GDScript, GIF 512x512 x 24 кадра кодируется за ~1.0-1.5 с на ПК.
- Видео-кодеки в GDScript не написать (VP9 и H.264 слишком тяжёлые), нужен либо MediaCodec, либо нативная libvpx.

## Требования Telegram (core.telegram.org/stickers, проверено)
WebM, кодек VP9, без аудио, одна сторона ровно 512, другая <= 512, <= 3 с, <= 30 fps, <= 256 КБ, желательно зацикленный. Альфа в странице прямо не требуется, но стикеры без неё выглядят прямоугольником с фоном, так что делаем yuva420p.

Проверка на ПК (ffmpeg libvpx-vp9, `-pix_fmt yuva420p -crf 34`, кадры нашей лягушки 512x512, 3 с при 24 fps): **130 КБ**, альфа читается libvpx-декодером (угол a=0, тело a=255). Лимит 256 КБ с запасом для простых анимаций. Нюанс: ffprobe/ffmpeg по умолчанию показывают такой файл как yuv420p, потому что нативный декодер не знает про альфу; она лежит во втором потоке (BlockAdditions, тег `alpha_mode=1`), браузеры и Telegram её читают.

## (a) JavaClassWrapper, MediaCodec/MediaMuxer без плагина
`JavaClassWrapper.wrap("android.media.MediaCodec")` есть с Godot 4.4, плагин и Gradle не нужны, в текущий APK-пайплайн ложится как есть. Есть `create_proxy()` для интерфейсов и синглтон `AndroidRuntime` (getActivity, runnable из Callable).

Ключевая идея: **не гонять байты кадров через JNI**. Схема с входной поверхностью:
1. GDScript сохраняет кадр в PNG во временную папку (уже умеем).
2. `MediaCodec.createByCodecName/createEncoderByType("video/avc")`, `configure(MediaFormat, COLOR_FormatSurface, bitrate, fps, I_FRAME_INTERVAL)`, `createInputSurface()`.
3. На каждый кадр: `BitmapFactory.decodeFile(path)`, `surface.lockHardwareCanvas()`, `canvas.drawBitmap(bmp, 0, 0, null)`, `unlockCanvasAndPost`. Кодек сам конвертирует цвет, форматы YUV420Flexible не трогаем.
4. Цикл `dequeueOutputBuffer(BufferInfo, timeout)`, `getOutputBuffer(i)` и сразу `muxer.writeSampleData(track, byteBuffer, info)`: ByteBuffer остаётся чистым Java-объектом, в GDScript не приходит. `INFO_OUTPUT_FORMAT_CHANGED` -> `muxer.addTrack(format)`, `start()`. В конце `signalEndOfInputStream`, `stop`, `release`.

Плюсы: 0 новых зависимостей, быстро проверить на LDPlayer (на эмуляторе обычно есть программный `c2.android.avc.encoder`), на телефонах аппаратный H.264.
Риски (проверить спайком): перегрузки Java-методов с null (`drawBitmap(..., null)`), типы float/int при маппинге, `BufferInfo` как поле-объект (читать `info.flags`, `size`, `presentationTimeUs`), всё синхронно на главном потоке Godot (на кадр ~10 JNI-вызовов, но dequeue блокирует: ставить таймаут 0 и крутить в `_process` или в Thread), `get_exception()` после каждого вызова, JavaClassWrapper заявлен нестабильным. Передача `PackedByteArray` как `byte[]` и чтение `ByteBuffer.get(byte[])` в доках не описаны, на них не закладываться (форум: byte[] из плагина приходил пустым, помогал base64).
Нужная MP4-часть: `MediaMuxer(path, OUTPUT_FORMAT_MPEG_4)`, работает с API 18+.
Оценка: **1-2 дня** на спайк + рабочий MP4 для TikTok/квадрата. Если упрётся в обёртку, откат на (b).

## (b) Android-плагин v2 (Kotlin) для Godot
Нужен Gradle-экспорт, то есть пересборка пайплайна. Шаги:
1. Установить в проект шаблон: Project > Install Android Build Template (берётся из `android_source.zip`, 214 МБ уже лежит в `%APPDATA%\Godot\export_templates\4.7.2.stable\`), получится папка `res://android/build`.
2. В export_presets: `gradle_build/use_gradle_build=true`. Нужны JDK 21 (есть), Android SDK build-tools 35 и platform 36 (есть в `C:\renpy\renpy-8.5.2-sdk\rapt\Sdk`), **Gradle** и зависимости Maven скачаются при первой сборке (сотни МБ в `~/.gradle`, требуется интернет). Пути в Godot: Editor Settings > Export > Android (sdk, jdk, debug keystore).
3. Модуль плагина: Kotlin-класс `RigbitExportPlugin : GodotPlugin`, зависимость `compileOnly` на `godot-lib` (aar из шаблона), `@UsedByGodot fun encodeMp4(framesDir, w, h, fps, bitrate, out): Boolean`, `AndroidManifest` с `org.godotengine.plugin.v2.RigbitExport` meta-data, `.gdap` не нужен для v2 (через `EditorExportPlugin` + `_get_android_libraries`). Сборка в `.aar`.
4. Положить `.aar` в `addons/` и добавить `EditorExportPlugin` на GDScript (список библиотек).
Плюсы: тот же MediaCodec, но без капризов обёртки, потоки и колбэки как в нормальном Kotlin, можно писать и VP9-муксер. Минусы: медленнее итерации сборки (минуты вместо секунд), emu.ps1 и build придётся править, APK растёт ненамного.
Оценка: **2-3 дня** на настройку + MP4, плагин потом переиспользуется.

## (c) FFmpeg/libvpx через GDExtension
- Для WebM с альфой: напрямую **libvpx** (BSD) + **libwebm** (BSD), без FFmpeg. libvpx для альфы кодирует второй VP9-поток (альфа как яркость) и libwebm пишет его в BlockAdditions. Размер: примерно 1-2 МБ на ABI после strip.
- FFmpeg как «всё в одном» (LGPL, `--disable-everything` + `libvpx`, webm/mp4 муксеры, `h264_mediacodec`): 3-6 МБ на ABI. libx264 нельзя (GPL), openh264 лицензия BSD, но бинарная раздача Cisco. ffmpeg-kit архивирован, готовых надёжных сборок рассчитывать не стоит (проверять форки отдельно).
- Что скачать: Android NDK r27+ (~0.7-1 ГБ в распакованном виде, его в Sdk нет, есть только cmdline-tools), godot-cpp (ветка 4.x), исходники libvpx (+ libwebm), CMake/SCons. Сборка под arm64-v8a и x86_64 (для LDPlayer), `.gdextension` с `android.debug.arm64` и т.п.
- Плюс: единственный проверенный способ получить корректный VP9+alpha, одинаково работает на всех устройствах, декодирование/проверка. Минус: самый тяжёлый вход (toolchain, кросс-компиляция libvpx, GDExtension API под 4.7), нужен Gradle? Нет, GDExtension работает и с обычным APK-экспортом.
Оценка: **4-7 дней** (первый день уходит на получение libvpx.a под NDK).

## (d) Кодек VP9 в MediaCodec и альфа
- На Android есть программный VP9-энкодер (`c2.android.vp9.encoder`, на базе libvpx, с Android 5/Q+ зависит от версии), аппаратный есть не везде. `MediaCodecList` покажет на устройстве.
- **Альфа через MediaCodec не поддерживается**: нет цветового формата с альфой (только YUV420/Surface), и `MediaMuxer(OUTPUT_FORMAT_WEBM)` не пишет BlockAdditions и AlphaMode. Одним вызовом «VP9 + прозрачность» не получить.
- Обходной путь (непроверенный): два экземпляра MediaCodec VP9: поток цвета (кадры с альфой, принудительно alpha=1, прямые цвета) и поток альфы (серое изображение из альфы), ключевые кадры в обоих на одних и тех же кадрах (интервал 1 ключ на ролик, для 3 с нормально), и **собственный WebM-муксер** (EBML: Segment/Info/Tracks с `AlphaMode=1`/Cluster/BlockGroup+BlockAdditions, `BlockAddID=1`, Cues). Муксер простой, ~200 строк, можно на GDScript/Kotlin. Риски: битрейт-контроль грубый (лимит 256 КБ, возможны повторные проходы), совместимость декодера Telegram, не гарантированная одинаковость заголовков двух потоков. Оценка: 4-6 дней, итог рискованнее, чем libvpx.

## Рекомендуемый план
1. **Сейчас (готово):** GIF, PNG-секвенция (zip), рендер кадров. Пользователь уже может выгружать это, в том числе стикер-кадры.
2. **MP4 (TikTok, квадрат): вариант (a), 1-2 дня.** Спайк на LDPlayer: H.264 Surface + MediaMuxer, кадры из PNG. Если JavaClassWrapper подведёт, сразу вариант (b) (2-3 дня), задача та же.
3. **WebM VP9 + альфа для Telegram: вариант (c) на чистой libvpx + libwebm (4-7 дней).** Не FFmpeg, чтобы бинарник был ~1.5 МБ на ABI и без лицензионных вопросов. Параллельно (если захочется обойтись без NDK) можно проверить гипотезу из (d) на одном устройстве за 1 день, но закладываться на неё нельзя.
4. Предохранитель: перед выдачей файла гонять `RbExportPresets.validate` (длительность, fps, сторона, размер) и при превышении 256 КБ перекодировать с повышением CRF (в libvpx это штатно, `rc_end_usage=VPX_Q`/`cq_level`, 2-3 прохода).
5. До появления (c) для стикеров Telegram в UI честно предлагать «PNG-секвенция/GIF + инструкция конвертера» (или экспорт на ПК через ffmpeg: команда выше проверена).

Итого: MP4 ~2 дня, WebM+alpha ~5 дней, 7-8 дней суммарно.

## Источники
- Telegram Stickers: https://core.telegram.org/stickers
- Godot, интеграция с Android API (JavaClassWrapper, AndroidRuntime): https://docs.godotengine.org/en/latest/tutorials/platform/android/javaclasswrapper_and_androidruntimeplugin.html
- Заметки по альфе VP9 в FFmpeg (нативный декодер не читает альфу): трекер trac.ffmpeg.org, тикеты #8344, #8468
- Локальная проверка: ffmpeg 8.1 + libvpx-vp9 на этой машине (130 КБ за 3 с, альфа подтверждена)
