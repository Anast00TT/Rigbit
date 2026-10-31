class_name RbExportSheet
extends RbPanel
## Лист режима «Экспорт» (мокап design/mockups/export.html): настройки, прогресс, готово.
## Сам документ не трогает: шлёт сигналы, рендер и сохранение делает главный экран.
## MP4 и WebM видны, но серые, пока на платформе нет видеокодировщика (RbVideoEncoder).

signal export_requested(settings: Dictionary)
signal cancel_requested
signal save_requested
signal toast(text: String)

var doc: RbDocument
var settings := {}
var state := "settings"  # settings | progress | done

var _bar: ProgressBar
var _status: Label
var _range_label: Label


func _init() -> void:
	super("EXPORT_TITLE")


func bind(d: RbDocument) -> void:
	doc = d
	var fmt: String = settings.get("format", "gif")
	settings = RbExportPlan.defaults(doc, fmt)
	state = "settings"
	rebuild()


## Документ поменялся (длина, fps, холст): держать диапазон в границах.
func sync_doc() -> void:
	if doc == null or settings.is_empty():
		return
	var last := maxi(doc.frame_count - 1, 0)
	settings["from"] = clampi(int(settings["from"]), 0, last)
	settings["to"] = clampi(int(settings["to"]), 0, last)
	if state == "settings":
		rebuild()


func rebuild() -> void:
	if doc == null:
		return
	begin_rebuild()
	match state:
		"settings":
			_build_settings()
		"progress":
			_build_progress()
	end_rebuild()
	_update_sub()


func _update_sub() -> void:
	var sz := RbExportPlan.size_of(doc, settings)
	var secs := RbExportPlan.duration(int(settings["from"]), int(settings["to"]), doc.fps)
	set_sub("%d×%d · %d fps · %s" % [sz.x, sz.y, int(settings["fps"]), tr("EXPORT_SECONDS") % _secs(secs)])


## Дробное число с одним знаком, в русской локали через запятую.
static func _secs(s: float) -> String:
	return ("%.1f" % s).replace(".", ",") if TranslationServer.get_locale().begins_with("ru") else "%.1f" % s


func _row(key: String, ctl: Control) -> HBoxContainer:
	var r := RbUi.hbox(12)
	r.custom_minimum_size.y = 48
	var l := RbUi.label(key, "LabelDim")
	l.custom_minimum_size.x = 92
	r.add_child(l)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(ctl)
	return r


func _build_settings() -> void:
	var fmts := ["gif", "png_zip", "mp4", "webm"]
	var fmt_seg := RbUi.segments(["GIF", "PNG", "MP4", "WebM"], fmts.find(settings["format"]), func(i: int) -> void:
		if RbExportPlan.is_soon(fmts[i]):
			notice(tr("EXPORT_SOON"))
			rebuild.call_deferred()  # вернуть подсветку на текущий формат
			return
		var keep_range := [settings["from"], settings["to"]]
		settings = RbExportPlan.defaults(doc, fmts[i])
		settings["from"] = keep_range[0]
		settings["to"] = keep_range[1]
		rebuild())
	for i in [2, 3]:
		if not RbExportPlan.is_soon(fmts[i]):
			continue
		var sb: Button = fmt_seg.get_child(0).get_child(i)
		sb.add_theme_color_override("font_color", RbTheme.C.tx3)
		sb.add_theme_color_override("font_hover_color", RbTheme.C.tx3)
	body.add_child(_row("EXPORT_FORMAT", fmt_seg))

	var sides: Array = RbExportPlan.SIDES
	var side_keys := []
	for s in sides:
		side_keys.append(str(s) if s > 0 else "EXPORT_CANVAS")
	body.add_child(_row("EXPORT_SIZE", RbUi.segments(side_keys, sides.find(int(settings["long_side"])), func(i: int) -> void:
		settings["long_side"] = sides[i]
		rebuild())))

	var fpss := RbExportPlan.fps_choices(doc.fps)
	var fps_keys := []
	for f in fpss:
		fps_keys.append(str(f))
	body.add_child(_row("EXPORT_FPS", RbUi.segments(fps_keys, fpss.find(int(settings["fps"])), func(i: int) -> void:
		settings["fps"] = fpss[i]
		rebuild())))

	var rs := RbRangeSlider.new()
	rs.setup(0, maxi(doc.frame_count - 1, 1), int(settings["from"]), int(settings["to"]))
	var rbox := RbUi.vbox(0)
	rbox.add_child(rs)
	body.add_child(_row("EXPORT_FRAMES", rbox))
	_range_label = RbUi.label("", "LabelFaint")
	_range_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_range_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	body.add_child(_range_label)
	_update_range_label()
	rs.changed.connect(func(a: int, b: int, done: bool) -> void:
		settings["from"] = a
		settings["to"] = b
		_update_range_label()
		_update_sub()
		if done:
			rebuild())

	body.add_child(_row("EXPORT_BG", RbUi.segments(["EXPORT_BG_ALPHA", "EXPORT_BG_COLOR"], 0 if settings["transparent"] else 1, func(i: int) -> void:
		settings["transparent"] = i == 0
		rebuild())))

	var probs := RbExportPlan.problems(doc, settings)
	for p in probs:
		var card := PanelContainer.new()
		card.theme_type_variation = "Card"
		var w := RbUi.label(tr(p[0]), "LabelDim")
		w.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		w.add_theme_color_override("font_color", RbTheme.C.tx if (p[0] as String).contains("ERR") else RbTheme.C.tx2)
		card.add_child(w)
		body.add_child(card)
	var go := RbUi.text_btn("PrimaryButton", "import", "EXPORT_GO", func() -> void: export_requested.emit(settings.duplicate()), 52)
	go.disabled = not RbExportPlan.can_run(probs)
	_green(go)
	body.add_child(go)


## Главная кнопка цветом режима, как в мокапе.
static func _green(b: Button) -> Button:
	var g := RbTheme.MODE_COLORS[3] as Color
	b.add_theme_stylebox_override("normal", RbTheme.sb(g, 8, 16, 8))
	b.add_theme_stylebox_override("hover", RbTheme.sb(g.lightened(0.08), 8, 16, 8))
	b.add_theme_stylebox_override("pressed", RbTheme.sb(g.darkened(0.12), 8, 16, 8))
	return b


func _update_range_label() -> void:
	if _range_label == null:
		return
	var a := int(settings["from"])
	var b := int(settings["to"])
	_range_label.text = tr("EXPORT_RANGE") % [a + 1, b + 1, _secs(RbExportPlan.duration(a, b, doc.fps))]


func _build_progress() -> void:
	var t := RbUi.label("EXPORT_RENDERING", "LabelTitle")
	body.add_child(t)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size.y = 8
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	var bg := RbTheme.sb(RbTheme.C.p3, 4)
	var fill := RbTheme.sb(RbTheme.MODE_COLORS[3], 4)
	_bar.add_theme_stylebox_override("background", bg)
	_bar.add_theme_stylebox_override("fill", fill)
	body.add_child(_bar)
	_status = RbUi.label("", "LabelDim")
	_status.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	body.add_child(_status)
	body.add_child(RbUi.text_btn("SecondaryButton", "x", "EXPORT_CANCEL", func() -> void: cancel_requested.emit(), 52))


func show_progress() -> void:
	state = "progress"
	rebuild()


func set_progress(k: float, text: String) -> void:
	if _bar:
		_bar.value = k
	if _status:
		_status.text = text


## Готово: имя, размеры, вес файла. Сохранить = системный диалог «Сохранить как».
func show_done(file: String, info: String) -> void:
	state = "done"
	begin_rebuild()
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	var row := RbUi.hbox(12)
	card.add_child(row)
	var ic := TextureRect.new()
	ic.texture = RbIcons.tex("check", 24)
	ic.modulate = RbTheme.MODE_COLORS[3]
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	ic.custom_minimum_size = Vector2(44, 44)
	row.add_child(ic)
	var names := RbUi.vbox(2)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(names)
	var n := RbUi.label(file, "LabelTitle")
	n.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	n.clip_text = true
	n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	names.add_child(n)
	var i := RbUi.label(info, "LabelFaint")
	i.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	names.add_child(i)
	body.add_child(card)
	var hint := RbUi.label("EXPORT_DONE_HINT", "LabelDim")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	var btns := RbUi.hbox(8)
	btns.add_child(RbUi.expand(RbUi.text_btn("SecondaryButton", "back", "EXPORT_AGAIN", func() -> void:
		state = "settings"
		rebuild(), 52)))
	btns.add_child(RbUi.expand(_green(RbUi.text_btn("PrimaryButton", "folder", "EXPORT_SAVE", func() -> void: save_requested.emit(), 52))))
	body.add_child(btns)
	end_rebuild()


func notice(text: String) -> void:
	toast.emit(text)
