extends SceneTree
## Мини-раннер тестов ядра. Запуск:
##   godot --headless --path rigbit -s res://tests/run_tests.gd
## Берёт все res://tests/test_*.gd, вызывает методы test_*. Код выхода = число упавших.

var failed := 0
var passed := 0
var current := ""


func _initialize() -> void:
	var dir := DirAccess.open("res://tests")
	var files := Array(dir.get_files()).filter(func(f: String) -> bool: return f.begins_with("test_") and f.ends_with(".gd"))
	files.sort()
	for f in files:
		var script: GDScript = load("res://tests/" + f)
		if script == null or not script.can_instantiate():
			failed += 1
			printerr("  FAIL ", f, "  скрипт не компилируется")
			continue
		var inst: Object = script.new()
		inst.set("t", self)
		for m in script.get_script_method_list():
			var mname: String = m["name"]
			if not mname.begins_with("test_"):
				continue
			current = "%s::%s" % [f.get_basename(), mname]
			var before := failed
			inst.call(mname)
			if failed == before:
				passed += 1
				print("  ok   ", current)
	print("\n%d passed, %d failed" % [passed, failed])
	quit(failed)


func check(cond: bool, msg := "") -> void:
	if not cond:
		failed += 1
		printerr("  FAIL ", current, "  ", msg)


func eq(a: Variant, b: Variant, msg := "") -> void:
	check(a == b, "%s: ожидалось %s, получено %s" % [msg, str(b), str(a)])


func near(a: float, b: float, msg := "", eps := 0.0001) -> void:
	check(absf(a - b) <= eps, "%s: ожидалось %f, получено %f" % [msg, b, a])
