extends RefCounted

var t  # раннер


## Красный квадрат 4x4 в центре 10x10, вокруг белая полупрозрачная кайма в 1 px, дальше прозрачный белый.
func _fringe_image() -> Image:
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	for y in range(2, 8):
		for x in range(2, 8):
			img.set_pixel(x, y, Color(1, 1, 1, 0.5))
	for y in range(3, 7):
		for x in range(3, 7):
			img.set_pixel(x, y, Color(1, 0, 0, 1))
	return img


func test_defringe_recolors_edge() -> void:
	var src := _fringe_image()
	var r := RbImageOps.defringe(src, 2)
	var out: Image = r[0]
	t.eq(int(r[1]), 20, "перекрашена вся кайма: 6x6 минус 4x4")
	var edge := out.get_pixel(2, 4)
	t.near(edge.r, 1.0, "кайма стала красной")
	t.near(edge.g, 0.0, "без белого")
	t.near(edge.a, src.get_pixel(2, 4).a, "альфа не тронута", 0.01)
	var outside := out.get_pixel(1, 4)
	t.near(outside.g, 0.0, "прозрачный сосед тоже получил цвет (нет ореола при фильтрации)")
	t.near(outside.a, 0.0, "и остался прозрачным")
	t.near(out.get_pixel(0, 4).g, 1.0, "дальше width не трогается")
	t.near(out.get_pixel(4, 4).r, 1.0, "середина как была")
	t.near(src.get_pixel(2, 4).g, 1.0, "исходная картинка цела (для undo)")


func test_defringe_edge_cases() -> void:
	var empty := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	t.eq(int(RbImageOps.defringe(empty, 2)[1]), 0, "без чистых пикселей ничего не делает")
	t.eq(int(RbImageOps.defringe(_fringe_image(), 0)[1]), 0, "нулевая ширина")
	var rgb := Image.create(3, 3, false, Image.FORMAT_RGB8)
	t.eq((RbImageOps.defringe(rgb, 1)[0] as Image).get_format(), Image.FORMAT_RGBA8, "любой формат на входе")


func test_set_image_undo() -> void:
	var doc := RbDocument.new()
	var a := _fringe_image()
	doc.images["img1"] = a
	var undo := RbUndoStack.new(doc)
	var b: Image = RbImageOps.defringe(a, 1)[0]
	undo.push(RbCommands.SetImage.new("img1", a, b))
	t.check(doc.images["img1"] == b, "новая картинка")
	undo.undo()
	t.check(doc.images["img1"] == a, "undo вернул прежний объект")
	undo.redo()
	t.check(doc.images["img1"] == b, "redo")
