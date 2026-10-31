extends RefCounted

var t  # раннер


func test_out_size() -> void:
	t.eq(RbExportPlan.out_size(Vector2i(1080, 1920), 512), Vector2i(288, 512), "портрет по высоте")
	t.eq(RbExportPlan.out_size(Vector2i(800, 600), 256), Vector2i(256, 192), "ландшафт по ширине")
	t.eq(RbExportPlan.out_size(Vector2i(300, 300), 512), Vector2i(512, 512), "увеличение тоже")
	t.eq(RbExportPlan.out_size(Vector2i(720, 1280), 0), Vector2i(720, 1280), "0 = как холст")


func test_source_frames() -> void:
	t.eq(RbExportPlan.source_frames(0, 47, 24, 24).size(), 48, "тот же fps: все кадры")
	var half := RbExportPlan.source_frames(0, 47, 24, 12)
	t.eq(half.size(), 24, "12 fps: вдвое меньше")
	t.eq([half[0], half[1], half[23]], [0, 2, 46], "через один")
	var up := RbExportPlan.source_frames(0, 23, 24, 30)
	t.eq(up.size(), 30, "30 fps: та же секунда")
	t.eq(up[up.size() - 1], 23, "последний кадр на месте")
	t.eq(RbExportPlan.source_frames(10, 14, 24, 24), PackedInt32Array([10, 11, 12, 13, 14]), "диапазон")
	t.eq(RbExportPlan.source_frames(14, 10, 24, 24).size(), 5, "перевёрнутый диапазон")
	t.near(RbExportPlan.duration(0, 47, 24), 2.0, "длительность")


func test_names_and_problems() -> void:
	t.eq(RbExportPlan.file_name("user://projects/Фроги.rigbit", "gif"), "Фроги.gif", "имя проекта")
	t.eq(RbExportPlan.file_name("", "png_zip"), "Rigbit.zip", "без проекта")
	var doc := RbDocument.new()
	doc.canvas_size = Vector2i(512, 512)
	doc.frame_count = 48
	doc.fps = 24
	var s := RbExportPlan.defaults(doc, "gif")
	t.eq(int(s["to"]), 47, "по умолчанию вся анимация")
	t.check(not RbExportPlan.can_run(RbExportPlan.problems(doc, s)), "пустой документ не экспортируется")
	doc.root.append(1)
	t.eq(RbExportPlan.problems(doc, s).size(), 0, "GIF 512 без проблем")
	s["long_side"] = 1024
	s["to"] = 999
	doc.frame_count = 1000
	t.check(not RbExportPlan.can_run(RbExportPlan.problems(doc, s)), "тысяча кадров 1024 в GIF не влезет в память")
	t.eq(RbExportPlan.fps_choices(25), [12, 24, 25, 30], "fps документа добавляется")


func test_video_seam() -> void:
	t.eq(RbExportPlan.out_size(Vector2i(1081, 1921), 0, true), Vector2i(1080, 1920), "видео: стороны чётные")
	t.eq(RbExportPlan.ext("mp4"), "mp4", "расширение mp4")
	t.near(float(RbVideoEncoder.bitrate_for(Vector2i(1080, 1920), 30)), 6220800.0, "битрейт как у TikTok", 1.0)
	var doc := RbDocument.new()
	doc.root.append(1)
	var s := RbExportPlan.defaults(doc, "mp4")
	t.check(not s["transparent"], "у MP4 фон непрозрачный")
	# на ПК видеокодировщика нет: формат «скоро» и не запускается
	t.eq(RbVideoEncoder.create("mp4"), null, "кодировщика нет")
	t.check(RbExportPlan.is_soon("mp4") and not RbExportPlan.can_run(RbExportPlan.problems(doc, s)), "MP4 пока «скоро»")
	t.check(not RbExportPlan.is_soon("gif"), "GIF работает всегда")
