extends RefCounted
## Тесты PSD: ридер на синтетических файлах, перевод в слои, импорт одним шагом истории.

const Fixture := preload("res://tests/psd_fixture.gd")

var t  # раннер


## RGBA с градиентом и сплошными строками (чтобы в RLE были и литералы, и повторы).
func _pix(w: int, h: int, seed: int, alpha := true) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w * h * 4)
	for y in h:
		for x in w:
			var i := (y * w + x) * 4
			if y % 2 == 1:
				out[i] = seed * 40 & 255
				out[i + 1] = 10
				out[i + 2] = 200
				out[i + 3] = 255 if not alpha else 128
			else:
				out[i] = (x * 37 + seed * 13) & 255
				out[i + 1] = (y * 11 + x) & 255
				out[i + 2] = (seed * 29 + x * y) & 255
				out[i + 3] = 255 if not alpha else (x * 50 + 5) & 255
	return out


func _specs() -> Array:
	return [
		{"name": "Fon", "uname": "Фон", "rect": Rect2i(0, 0, 8, 6), "rgba": _pix(8, 6, 1), "comp": 0},
		{"name": "half", "rect": Rect2i(2, 1, 4, 3), "rgba": _pix(4, 3, 2), "comp": 1, "opacity": 128,
			"blend": "mul ", "mask": true},
		{"name": "</Layer group>", "divider": 3},
		{"name": "inner", "rect": Rect2i(-1, 2, 5, 2), "rgba": _pix(5, 2, 3), "comp": 1},
		{"name": "Group", "uname": "Группа", "divider": 1, "divider_blend": "pass", "blend": "pass"},
		{"name": "hidden", "rect": Rect2i(5, 4, 2, 2), "rgba": _pix(2, 2, 4), "hidden": true, "fill": 128},
		{"name": "levels", "rect": Rect2i(0, 0, 8, 6), "rgba": _pix(8, 6, 5), "tags": [["levl", PackedByteArray([0, 2])]]},
		{"name": "empty", "rect": Rect2i()},
		{"name": "zip", "rect": Rect2i(0, 0, 3, 2), "rgba": _pix(3, 2, 6), "comp": 2},
		{"name": "zipp", "rect": Rect2i(1, 1, 6, 3), "rgba": _pix(6, 3, 7), "comp": 3, "alpha": false},
		{"name": "diss", "rect": Rect2i(0, 0, 2, 2), "rgba": _pix(2, 2, 8), "blend": "diss", "clip": true},
	]


func _names(nodes: Array) -> Array:
	var out: Array = []
	for n: Dictionary in nodes:
		out.append(n["name"])
	return out


func _check_tree(res: Dictionary, tag: String) -> void:
	t.check(res["ok"], tag + ": ok (%s)" % res["error"])
	if not res["ok"]:
		return
	t.eq(res["width"], 8, tag + ": ширина")
	t.eq(res["height"], 6, tag + ": высота")
	var nodes: Array = res["nodes"]
	t.eq(_names(nodes), ["Фон", "half", "Группа", "hidden", "zip", "zipp", "diss"], tag + ": порядок снизу вверх")
	if nodes.size() != 7:
		return
	var specs := _specs()
	var fon: Dictionary = nodes[0]
	t.eq(fon["kind"], "image", tag + ": фон картинка")
	t.eq(fon["rect"], Rect2i(0, 0, 8, 6), tag + ": рамка фона")
	t.eq((fon["image"] as Image).get_data(), specs[0]["rgba"], tag + ": пиксели raw")
	var half: Dictionary = nodes[1]
	t.near(half["opacity"], 128.0 / 255.0, tag + ": opacity 50%", 0.001)
	t.eq(half["blend"], "multiply", tag + ": multiply")
	t.eq(half["rect"], Rect2i(2, 1, 4, 3), tag + ": рамка half")
	t.eq((half["image"] as Image).get_data(), specs[1]["rgba"], tag + ": пиксели RLE (маска пропущена)")
	var g: Dictionary = nodes[2]
	t.eq(g["kind"], "group", tag + ": группа")
	t.eq(g["blend"], "normal", tag + ": pass-through -> normal")
	t.eq(_names(g["children"]), ["inner"], tag + ": ребёнок группы")
	t.eq(g["rect"], Rect2i(-1, 2, 5, 2), tag + ": рамка группы по детям")
	if (g["children"] as Array).size() == 1:
		var inner: Dictionary = g["children"][0]
		t.eq((inner["image"] as Image).get_data(), specs[3]["rgba"], tag + ": пиксели в группе")
	var hid: Dictionary = nodes[3]
	t.check(not hid["visible"], tag + ": скрытый слой")
	t.check(fon["visible"], tag + ": видимый слой")
	t.near(hid["opacity"], 128.0 / 255.0, tag + ": fill opacity", 0.001)
	t.eq((nodes[4]["image"] as Image).get_data(), specs[8]["rgba"], tag + ": пиксели ZIP")
	var zipp: Image = nodes[5]["image"]
	var exp: PackedByteArray = (specs[9]["rgba"] as PackedByteArray).duplicate()
	for i in range(3, exp.size(), 4):
		exp[i] = 255  # нет канала прозрачности -> альфа 255
	t.eq(zipp.get_data(), exp, tag + ": пиксели ZIP с предсказанием, альфа 255")
	var diss: Dictionary = nodes[6]
	t.eq(diss["blend"], "normal", tag + ": неизвестный режим -> normal")
	t.check(diss["clipped"], tag + ": обтравка")
	var warns: Array = res["warnings"]
	t.check(warns.any(func(w: String) -> bool: return w.begins_with("PSD_WARN_BLEND") and w.contains("diss")), tag + ": предупреждение о режиме")
	t.check(warns.has("PSD_WARN_CLIPPING"), tag + ": предупреждение об обтравке")
	t.check(warns.any(func(w: String) -> bool: return w.begins_with("PSD_WARN_ADJUSTMENT") and w.contains("levels")), tag + ": корректирующий пропущен")


func test_read_psd() -> void:
	var data := Fixture.build(8, 6, _specs())
	_check_tree(RbPsdReader.read_bytes(data, "", false), "psd")
	_check_tree(RbPsdReader.read_bytes(data, "", true), "psd потоки")


func test_read_psb() -> void:
	_check_tree(RbPsdReader.read_bytes(Fixture.build(8, 6, _specs(), {"big": true})), "psb")


func test_grayscale() -> void:
	var px := _pix(4, 4, 3)
	var data := Fixture.build(4, 4, [{"name": "g", "rect": Rect2i(0, 0, 4, 4), "rgba": px, "comp": 1}], {"mode": 1})
	var res := RbPsdReader.read_bytes(data)
	t.check(res["ok"], "gray ok")
	if not res["ok"]:
		return
	var img: Image = res["nodes"][0]["image"]
	var c := img.get_pixel(1, 0)
	t.eq(c.r8, px[4], "серый в R")
	t.eq(c.g8, px[4], "серый в G")
	t.eq(c.b8, px[4], "серый в B")
	t.eq(c.a8, px[7], "альфа")


func test_flattened_fallback() -> void:
	var merged := PackedByteArray()
	for i in 3 * 2:
		merged.append_array(PackedByteArray([10, 20, 30]))
	var res := RbPsdReader.read_bytes(Fixture.build(3, 2, [], {"merged": merged}), "картинка")
	t.check(res["ok"], "сведённый файл читается")
	if not res["ok"]:
		return
	var nodes: Array = res["nodes"]
	t.eq(nodes.size(), 1, "один слой")
	t.eq(nodes[0]["name"], "картинка", "имя из файла")
	t.eq((nodes[0]["image"] as Image).get_pixel(2, 1), Color8(10, 20, 30, 255), "цвет")


func test_errors() -> void:
	t.eq(RbPsdReader.read_bytes(Fixture.build(2, 2, [], {"depth": 16}))["error"], "PSD_ERR_DEPTH", "16 бит")
	t.eq(RbPsdReader.read_bytes(Fixture.build(2, 2, [], {"mode": 4}))["error"], "PSD_ERR_MODE", "CMYK")
	t.eq(RbPsdReader.read_bytes(PackedByteArray([1, 2, 3]))["error"], "PSD_ERR_SIGNATURE", "мусор")
	var data := Fixture.build(8, 6, _specs())
	for cut in [30, 60, 200, data.size() / 2, data.size() - 40]:
		var res := RbPsdReader.read_bytes(data.slice(0, cut))
		t.check(res.has("ok"), "обрезанный файл не падает (%d)" % cut)
	t.eq(RbPsdReader.read_file("user://нет_такого.psd")["error"], "PSD_ERR_READ", "нет файла")


func test_psd_to_layers_and_undo() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var psd := RbPsdReader.read_bytes(Fixture.build(8, 6, _specs()))
	var r := RbImporter.psd_to_layers(doc, psd)
	t.eq(r["error"], "", "без ошибки")
	t.eq(r["canvas_size"], Vector2i(8, 6), "размер холста PSD")
	var layers: Array[RbLayer] = r["layers"]
	t.eq(layers.size(), 8, "7 картинок + группа")
	t.eq((r["images"] as Dictionary).size(), 7, "картинки")
	var old_canvas := doc.canvas_size
	undo.push(RbAddLayersCommand.new(layers, r["images"], r["canvas_size"]))
	t.eq(undo.size(), 1, "один шаг истории")
	t.eq(doc.canvas_size, Vector2i(8, 6), "холст по PSD")
	var names: Array = []
	for id in doc.root:
		names.append(doc.get_layer(id).name)
	t.eq(names, ["Фон", "half", "Группа", "hidden", "zip", "zipp", "diss"], "порядок в документе")
	var g := doc.get_layer(doc.root[2])
	t.eq(g.kind, RbLayer.Kind.GROUP, "группа")
	t.eq(g.children.size(), 1, "ребёнок в группе")
	if g.children.size() == 1:
		var inner := doc.get_layer(g.children[0])
		t.eq(inner.parent_id, g.id, "родитель")
		t.eq(inner.position, Vector2(1.5, 3), "центр рамки с отрицательным x")
	var half := doc.get_layer(doc.root[1])
	t.eq(half.position, Vector2(4, 2.5), "позиция = центр рамки")
	t.eq(half.size, Vector2(4, 3), "размер")
	t.eq(half.blend_mode, "multiply", "режим")
	t.check(not doc.get_layer(doc.root[3]).visible, "скрытый")
	t.eq(doc.images.size(), 7, "картинки в документе")
	var snap := JSON.stringify(doc.to_dict())
	undo.undo()
	t.eq(doc.root.size(), 0, "undo убрал слои")
	t.eq(doc.layers.size(), 0, "и детей")
	t.eq(doc.images.size(), 0, "и картинки")
	t.eq(doc.canvas_size, old_canvas, "холст вернулся")
	undo.redo()
	t.eq(JSON.stringify(doc.to_dict()), snap, "redo восстановил то же самое")
	t.eq(doc.images.size(), 7, "картинки после redo")


func test_psd_to_layers_downscale() -> void:
	var doc := RbDocument.new()
	var img := Image.create_empty(5000, 10, false, Image.FORMAT_RGBA8)
	var psd := {"ok": true, "width": 5000, "height": 10, "warnings": [], "nodes": [
		{"name": "big", "kind": "image", "visible": true, "opacity": 1.0, "blend": "normal",
			"rect": Rect2i(0, 0, 5000, 10), "image": img, "clipped": false},
	]}
	var r := RbImporter.psd_to_layers(doc, psd)
	var l: RbLayer = r["layers"][0]
	t.check((r["warnings"] as Array).has("IMPORT_WARN_DOWNSCALED"), "предупреждение")
	t.eq(l.size.x, 4096.0, "сторона 4096")
	t.near(l.size.x * l.scale.x, 5000.0, "видимая ширина сохранена", 0.01)
	t.near(l.size.y * l.scale.y, 10.0, "видимая высота сохранена", 0.01)
	t.eq(l.position, Vector2(2500, 5), "центр")
	t.eq(img.get_width(), 5000, "исходная картинка не тронута")


func test_psd_error_passthrough() -> void:
	var r := RbImporter.psd_to_layers(RbDocument.new(), {"ok": false, "error": "PSD_ERR_DEPTH"})
	t.eq(r["error"], "PSD_ERR_DEPTH", "ошибка ридера наружу")
	t.eq((r["layers"] as Array).size(), 0, "без слоёв")


func test_rle_fallback_and_fast_path_agree() -> void:
	var px := _pix(37, 9, 5)
	var spec := {"name": "nop", "rect": Rect2i(0, 0, 37, 9), "rgba": px, "comp": 1, "rle_nop": true}
	var res := RbPsdReader.read_bytes(Fixture.build(37, 9, [spec]))
	t.check(res["ok"], "RLE с пустыми заголовками читается")
	if res["ok"]:
		t.eq((res["nodes"][0]["image"] as Image).get_data(), px, "запасной путь RLE: пиксели")
	# случайные данные: быстрый путь (TGA) и запасной дают одно и то же
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var w := 300
	var h := 7
	var plane := PackedByteArray()
	plane.resize(w * h)
	for i in plane.size():
		plane[i] = 0 if i % 150 < 50 else (rng.randi() & 3) * 60
	var enc := PackedByteArray()
	for y in h:
		enc.append_array(Fixture.packbits(plane.slice(y * w, (y + 1) * w)))
	var dec := RbPsdReader._Decoder.new(enc, false, false)
	dec.run_all(false)
	var slow := dec.unpack_bits(0, enc.size(), w * h)
	var fast := dec.unpack_bits_tga(0, enc.size(), w, h)
	t.eq(slow, plane, "запасной PackBits")
	t.check(fast != null, "быстрый PackBits сработал")
	if fast:
		fast.convert(Image.FORMAT_L8)
		t.eq(fast.get_data(), plane, "быстрый PackBits")
