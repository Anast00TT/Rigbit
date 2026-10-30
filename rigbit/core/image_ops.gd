class_name RbImageOps
extends RefCounted
## Операции с пикселями слоя (не живые эффекты: меняют картинку, идут через undo командой SetImage).

const SOLID := 250  # альфа, с которой цвет пикселя считается чистым


## Удаление каймы (как Defringe в Photoshop). Цвет полупрозрачных пикселей края заменяется
## цветом ближайших чистых соседей, кольцами на width px внутрь каймы. Прозрачные пиксели
## в этих кольцах тоже получают цвет соседей: иначе при фильтрации текстуры на GPU из них
## подмешивается белый или чёрный и вокруг персонажа виден ореол. Альфа не меняется.
## Возвращает [новая картинка RGBA8, сколько пикселей поменялось].
static func defringe(src: Image, width: int) -> Array:
	var img := src.duplicate() as Image
	if img.has_mipmaps():
		img.clear_mipmaps()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var d := img.get_data()
	var n := w * h
	var solid := PackedByteArray()
	solid.resize(n)
	var any_solid := false
	for i in n:
		if d[i * 4 + 3] >= SOLID:
			solid[i] = 1
			any_solid = true
	if not any_solid or width <= 0:
		return [img, 0]
	# первое кольцо: нечистые пиксели рядом с чистыми (4-соседство)
	var queued := solid.duplicate()
	var ring := PackedInt32Array()
	for y in h:
		var row := y * w
		for x in w:
			var i := row + x
			if solid[i] == 1:
				continue
			if (x > 0 and solid[i - 1] == 1) or (x < w - 1 and solid[i + 1] == 1) \
					or (y > 0 and solid[i - w] == 1) or (y < h - 1 and solid[i + w] == 1):
				ring.append(i)
				queued[i] = 1
	var changed := 0
	for r in width:
		if ring.is_empty():
			break
		var colors := PackedInt32Array()
		colors.resize(ring.size() * 3)
		# цвета считаются по уже чистым соседям (8-соседство), а записываются после: кольцо не красит само себя
		for k in ring.size():
			var i := ring[k]
			var x := i % w
			var y := i / w
			var sr := 0
			var sg := 0
			var sb := 0
			var cnt := 0
			for dy in [-1, 0, 1]:
				var yy: int = y + dy
				if yy < 0 or yy >= h:
					continue
				for dx in [-1, 0, 1]:
					var xx: int = x + dx
					if xx < 0 or xx >= w or (dx == 0 and dy == 0):
						continue
					var j := yy * w + xx
					if solid[j] == 1:
						var o := j * 4
						sr += d[o]
						sg += d[o + 1]
						sb += d[o + 2]
						cnt += 1
			if cnt > 0:
				colors[k * 3] = sr / cnt
				colors[k * 3 + 1] = sg / cnt
				colors[k * 3 + 2] = sb / cnt
			else:
				colors[k * 3] = -1
		var next := PackedInt32Array()
		for k in ring.size():
			if colors[k * 3] < 0:
				continue
			var i := ring[k]
			var o := i * 4
			if d[o] != colors[k * 3] or d[o + 1] != colors[k * 3 + 1] or d[o + 2] != colors[k * 3 + 2]:
				if d[o + 3] > 0:
					changed += 1
				d[o] = colors[k * 3]
				d[o + 1] = colors[k * 3 + 1]
				d[o + 2] = colors[k * 3 + 2]
		for k in ring.size():
			if colors[k * 3] >= 0:
				solid[ring[k]] = 1
		for k in ring.size():
			var i := ring[k]
			var x := i % w
			for j in [i - w, i + w, i - 1 if x > 0 else -1, i + 1 if x < w - 1 else -1]:
				if j >= 0 and j < n and queued[j] == 0:
					queued[j] = 1
					next.append(j)
		ring = next
	img.set_data(w, h, false, Image.FORMAT_RGBA8, d)
	return [img, changed]
