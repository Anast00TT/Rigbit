class_name RbSettingsScreen
extends PanelContainer
## Экран настроек на весь экран. Смена языка или темы перезапускает сцену (проект сохраняется заранее).

signal closed
signal restart_needed
signal about_requested

const LOCALES := ["ru", "en"]
const THEMES := ["dark", "light", "system"]

var settings: RbSettings


func _init(s: RbSettings) -> void:
	settings = s
	theme_type_variation = "Sheet"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var col := RbUi.vbox(0)
	add_child(col)
	var head := RbUi.margins(4, 4, 12, 4)
	col.add_child(head)
	var hr := RbUi.hbox(4)
	head.add_child(hr)
	hr.add_child(RbUi.icon_btn("back", func() -> void: closed.emit()))
	var t := RbUi.label("SETTINGS_TITLE", "LabelTitle")
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hr.add_child(t)
	col.add_child(RbUi.hline())
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var m := RbUi.margins(16, 12, 16, 24)
	center.add_child(m)
	var v := RbUi.vbox(8)
	v.custom_minimum_size.x = 0
	m.add_child(v)
	set_meta("content", v)

	v.add_child(RbUi.label("SET_LANGUAGE", "LabelDim"))
	v.add_child(RbUi.segments(["LANG_RU", "LANG_EN"], maxi(0, LOCALES.find(settings.locale)), func(i: int) -> void:
		if settings.locale != LOCALES[i]:
			settings.locale = LOCALES[i]
			settings.save_cfg()
			restart_needed.emit(), 40))
	v.add_child(_gap())
	v.add_child(RbUi.label("SET_THEME", "LabelDim"))
	v.add_child(RbUi.segments(["THEME_DARK", "THEME_LIGHT", "THEME_SYSTEM"], maxi(0, THEMES.find(settings.theme)), func(i: int) -> void:
		if settings.theme != THEMES[i]:
			settings.theme = THEMES[i]
			settings.save_cfg()
			restart_needed.emit(), 40))
	v.add_child(_gap())
	v.add_child(RbUi.hline())
	v.add_child(RbUi.switch_row("SET_HINTS", settings.hints, func(on: bool) -> void:
		settings.hints = on
		settings.save_cfg()))
	v.add_child(RbUi.switch_row("SET_VIBRATION", settings.vibration, func(on: bool) -> void:
		settings.vibration = on
		settings.save_cfg()))
	v.add_child(RbUi.hline())
	v.add_child(_gap())
	var reset := RbUi.text_btn("SecondaryButton", "bulb", "SET_RESET_HINTS", Callable(), 44)
	reset.pressed.connect(func() -> void:
		settings.dismissed_hints.clear()
		settings.save_cfg()
		reset.disabled = true)
	v.add_child(reset)
	v.add_child(RbUi.text_btn("SecondaryButton", "info", "MENU_ABOUT", func() -> void: about_requested.emit(), 44))


func _gap() -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = 4
	return c


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and has_meta("content"):
		var v: VBoxContainer = get_meta("content")
		v.custom_minimum_size.x = minf(size.x - 32.0, 520.0)
