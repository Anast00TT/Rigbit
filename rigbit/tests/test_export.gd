extends RefCounted

const Dec := preload("res://tests/gif_decode.gd")

var t  # раннер


## Синтетический кадр: градиент + цветной прямоугольник, сдвигающийся по кадрам; hole = прозрачная дыра.
func _frame(w: int, h: int, i: int, hole := false) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var c := Color(float(x) / w, float(y) / h, 0.5, 1.0)
			if x >= 4 + i * 3 and x < 14 + i * 3 and y >= 6 and y < 18:
				c = Color(1, 0.2, 0.1, 1)
			if hole and x >= 30 and y >= 20:
				c = Color(0, 0, 0, 0)
			img.set_pixel(x, y, c)
	return img


func _max_err(rgba: PackedByteArray, img: Image, only_opaque := true) -> int:
	var d := img.get_data()
	var worst := 0
	for i in range(0, d.size(), 4):
		if only_opaque and d[i + 3] < 128:
			continue
		for k in 3:
			worst = maxi(worst, absi(int(d[i + k]) - int(rgba[i + k])))
	return worst


func test_gif_roundtrip_basic() -> void:
	var frames: Array = []
	for i in 6:
		frames.append(_frame(48, 32, i))
	var enc := RbGifEncoder.new()
	var bytes := enc.encode(frames, 24.0)
	t.check(bytes.size() > 100, "есть байты")
	var r := Dec.decode(bytes)
	t.check(r["ok"], "декодируется: " + str(r["error"]))
	t.eq(r["frames"].size(), 6, "число кадров")
	t.eq(r["width"], 48, "ширина")
	t.eq(r["height"], 32, "высота")
	t.eq(r["loop"], 0, "бесконечный цикл")
	t.check((r["global_palette"] as PackedByteArray).size() <= 256 * 3, "палитра <= 256")
	for i in 6:
		var fr: Dictionary = r["frames"][i]
		t.eq(fr["transparent"], -1, "без прозрачности")
		var err := _max_err(fr["rgba"], frames[i])
		t.check(err <= 24, "кадр %d: ошибка цвета %d" % [i, err])


func test_gif_delays_accumulate() -> void:
	var frames: Array = []
	for i in 24:
		frames.append(_frame(16, 8, 0))
	var r := Dec.decode(RbGifEncoder.new().encode(frames, 24.0))
	var sum := 0
	for fr in r["frames"]:
		sum += int(fr["delay"])
		t.check(fr["delay"] == 4 or fr["delay"] == 5, "задержка 4 или 5, а не %d" % fr["delay"])
	t.eq(sum, 100, "24 кадра при 24 fps = ровно 1 с")
	frames.clear()
	for i in 10:
		frames.append(_frame(16, 8, 0))
	r = Dec.decode(RbGifEncoder.new().encode(frames, 10.0))
	for fr in r["frames"]:
		t.eq(fr["delay"], 10, "10 fps = 10 cs")


func test_gif_transparency() -> void:
	var frames: Array = []
	for i in 4:
		frames.append(_frame(48, 32, i, true))
	var enc := RbGifEncoder.new()
	var r := Dec.decode(enc.encode(frames, 12.0))
	t.check(r["ok"], "декодируется: " + str(r["error"]))
	t.eq(r["frames"].size(), 4, "кадры")
	for i in 4:
		var fr: Dictionary = r["frames"][i]
		t.eq(fr["transparent"], 0, "прозрачный индекс 0")
		t.eq(fr["disposal"], 2, "диспоз 2")
		var rgba: PackedByteArray = fr["rgba"]
		var o := (25 * 48 + 40) * 4
		t.eq(rgba[o + 3], 0, "дыра прозрачна")
		var o2 := (2 * 48 + 2) * 4
		t.eq(rgba[o2 + 3], 255, "остальное непрозрачно")
		var err := _max_err(rgba, frames[i])
		t.check(err <= 24, "кадр %d: ошибка цвета %d" % [i, err])
	t.check((r["global_palette"] as PackedByteArray).size() <= 256 * 3, "палитра <= 256")


func test_gif_exact_palette_big_lzw() -> void:
	# <=255 цветов в разных корзинах: палитра точная, шумный узор заставляет LZW переполнять таблицу и слать clear
	var w := 220
	var h := 220
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in h:
		for x in w:
			var k := rng.randi() % 200
			img.set_pixel(x, y, Color8((k % 8) * 32, ((k / 8) % 8) * 32, (k / 64) * 64 + 3, 255))
	var enc := RbGifEncoder.new()
	var r := Dec.decode(enc.encode([img], 10.0))
	t.check(r["ok"], "декодируется: " + str(r["error"]))
	var err := _max_err(r["frames"][0]["rgba"], img)
	t.eq(err, 0, "точная палитра -> пиксели без потерь")


func test_gif_per_frame_palette_and_dither() -> void:
	var frames: Array = []
	for i in 3:
		frames.append(_frame(40, 40, i))
	var enc := RbGifEncoder.new()
	enc.per_frame_palette = true
	enc.dither = true
	var r := Dec.decode(enc.encode(frames, 24.0))
	t.check(r["ok"], "декодируется: " + str(r["error"]))
	t.eq(r["frames"].size(), 3, "кадры")
	for i in 3:
		var fr: Dictionary = r["frames"][i]
		t.check((fr["palette"] as PackedByteArray).size() <= 256 * 3, "локальная палитра <= 256")
		var err := _max_err(fr["rgba"], frames[i])
		t.check(err <= 40, "дизеринг: ошибка цвета %d" % err)


func test_gif_loop_count_and_gradient_many_colors() -> void:
	# много цветов (шумный градиент) -> median cut до 255, всё ещё валидный поток
	var img := Image.create(160, 120, false, Image.FORMAT_RGBA8)
	for y in 120:
		for x in 160:
			img.set_pixel(x, y, Color8(x * 255 / 159, y * 255 / 119, (x + y) * 255 / 279, 255))
	var enc := RbGifEncoder.new()
	enc.loop_count = 3
	var r := Dec.decode(enc.encode([img, img], 10.0))
	t.check(r["ok"], "декодируется: " + str(r["error"]))
	t.eq(r["loop"], 3, "число повторов")
	t.check(enc.last_stats["palette_size"] <= 256, "палитра <= 256")
	var ge := _max_err(r["frames"][0]["rgba"], img)
	t.check(ge <= 40, "градиент в допуске: %d" % ge)


func test_png_sequence_zip() -> void:
	var path := "user://test_seq.zip"
	var frames: Array = []
	for i in 3:
		frames.append(_frame(48, 32, i, true))
	t.eq(RbPngSequence.write_zip(path, frames), OK, "запись zip")
	var z := ZIPReader.new()
	t.eq(z.open(path), OK, "zip открывается")
	var files := z.get_files()
	t.eq(files.size(), 3, "3 файла")
	t.eq(files[0], "frame_0000.png", "имя 0")
	t.eq(files[2], "frame_0002.png", "имя 2")
	var img := Image.new()
	t.eq(img.load_png_from_buffer(z.read_file("frame_0001.png")), OK, "png читается")
	t.eq(img.get_width(), 48, "ширина")
	t.eq(img.get_pixel(40, 25).a, 0.0, "альфа сохранена (дыра)")
	t.eq(img.get_pixel(1, 1).a, 1.0, "непрозрачный пиксель")
	z.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	t.eq(RbPngSequence.frame_name(12, "f_", 3), "f_012.png", "формат имени")


func test_presets_validation() -> void:
	var tg := RbExportPresets.get_preset("tg_sticker")
	t.eq(tg["format"], "webm", "тг: webm")
	t.eq(RbExportPresets.export_size(tg, Vector2i(1080, 1920)), Vector2i(288, 512), "тг: 512 по длинной")
	t.eq(RbExportPresets.export_size(tg, Vector2i(300, 300)), Vector2i(512, 512), "тг: апскейл до 512")
	t.eq(RbExportPresets.export_size(tg, Vector2i(1920, 1080)), Vector2i(512, 288), "тг: ландшафт")
	t.eq(RbExportPresets.export_fps(tg, 60), 30, "тг: fps <= 30")
	t.eq(RbExportPresets.export_fps(tg, 24), 24, "тг: 24 остаётся")
	t.eq(RbExportPresets.max_frames(tg, 30), 90, "тг: 3 с * 30")
	var ok := RbExportPresets.validate(tg, {"width": 288, "height": 512, "fps": 30, "frames": 90, "bytes": 200 * 1024, "alpha": true})
	t.eq(ok.size(), 0, "норма без предупреждений: " + str(ok))
	var bad := RbExportPresets.validate(tg, {"width": 600, "height": 512, "fps": 60, "frames": 240, "bytes": 400 * 1024})
	t.check(bad.size() >= 4, "длительность, fps, сторона, размер файла: " + str(bad))
	var joined := "\n".join(bad)
	t.check(joined.contains("длительность"), "предупреждение о длительности")
	t.check(joined.contains("КБ"), "предупреждение о размере")
	var tt := RbExportPresets.get_preset("tiktok")
	t.eq(RbExportPresets.export_size(tt, Vector2i(500, 500)), Vector2i(1080, 1920), "тикток: фикс. размер")
	t.eq(RbExportPresets.validate(tt, {"width": 1080, "height": 1920, "fps": 30, "frames": 100}).size(), 0, "тикток ок")
	t.check(RbExportPresets.validate(tt, {"width": 1080, "height": 1080, "fps": 30, "frames": 100}).size() == 1, "тикток: не тот размер")
	t.eq(RbExportPresets.all().size(), 5, "5 пресетов")
	t.eq(RbExportPresets.get_preset("нет"), {}, "неизвестный id")
