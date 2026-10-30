class_name RbSettings
extends RefCounted
## Настройки приложения (не проекта). user://settings.cfg

const PATH := "user://settings.cfg"

var locale := "ru"
var theme := "dark"
var hints := true
var vibration := true
var last_project := ""
var dismissed_hints: Array = []


func load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		var sys := OS.get_locale_language()
		locale = sys if sys in ["ru", "en"] else "en"
		return
	locale = cfg.get_value("app", "locale", locale)
	theme = cfg.get_value("app", "theme", theme)
	hints = cfg.get_value("app", "hints", hints)
	vibration = cfg.get_value("app", "vibration", vibration)
	last_project = cfg.get_value("app", "last_project", last_project)
	dismissed_hints = cfg.get_value("app", "dismissed_hints", [])


func save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("app", "locale", locale)
	cfg.set_value("app", "theme", theme)
	cfg.set_value("app", "hints", hints)
	cfg.set_value("app", "vibration", vibration)
	cfg.set_value("app", "last_project", last_project)
	cfg.set_value("app", "dismissed_hints", dismissed_hints)
	cfg.save(PATH)
