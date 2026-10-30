extends RefCounted
## Тесты автосетки RbMeshGen: картинки рисуются процедурно.

var t  # раннер

const N := 256
const THR := 0.05
const SLACK := 16  # насколько сетка может вылезать за рисунок, пикселей


# ---------------------------------------------------------------- картинки

static func make_image(w: int, h: int, alpha: Callable) -> Image:
	var data := PackedByteArray()
	data.resize(w * h * 4)
	for y in h:
		for x in w:
			var a: float = alpha.call(x + 0.5, y + 0.5)
			var i := (y * w + x) * 4
			data[i] = 200
			data[i + 1] = 120
			data[i + 2] = 80
			data[i + 3] = clampi(roundi(a * 255.0), 0, 255)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)


static func _disk(x: float, y: float, cx: float, cy: float, r: float) -> bool:
	return Vector2(x, y).distance_to(Vector2(cx, cy)) <= r


static func _line_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))


## Имя -> [картинка, точки (в пикселях), которые сетка покрывать не должна].
static func shapes() -> Dictionary:
	var c := N * 0.5
	return {
		"circle": [make_image(N, N, func(x: float, y: float) -> float:
			return 1.0 if _disk(x, y, c, c, 90) else 0.0), []],
		"donut": [make_image(N, N, func(x: float, y: float) -> float:
			return 1.0 if _disk(x, y, c, c, 100) and not _disk(x, y, c, c, 45) else 0.0), [Vector2(c, c)]],
		"blobs": [make_image(N, N, func(x: float, y: float) -> float:
			return 1.0 if _disk(x, y, 65, c, 40) or _disk(x, y, 191, c, 40) else 0.0), [Vector2(c, c)]],
		"L": [make_image(N, N, func(x: float, y: float) -> float:
			return 1.0 if (x >= 40 and x < 110 and y >= 30 and y < 226) or (x >= 40 and x < 226 and y >= 160 and y < 226) else 0.0),
			[Vector2(180, 80), Vector2(150, 125)]],
		"strand": [make_image(N, N, func(x: float, y: float) -> float:
			return 1.0 if _line_dist(Vector2(x, y), Vector2(20, 24), Vector2(236, 220)) <= 3.0 else 0.0),
			[Vector2(200, 60), Vector2(60, 200)]],
		"crescent": [make_image(N, N, func(x: float, y: float) -> float:
			return 1.0 if _disk(x, y, c, c, 100) and not _disk(x, y, c + 50, c, 85) else 0.0), [Vector2(190, c), Vector2(230, c)]],
		"aa_circle": [make_image(N, N, func(x: float, y: float) -> float:
			return clampf(80.5 - Vector2(x, y).distance_to(Vector2(c, c)), 0.0, 1.0)), []],
	}


## Похоже на часть персонажа: голова с прорезью, прядь, блик, сглаженные края.
static func character(size: int) -> Image:
	var k := size / 256.0
	return make_image(size, size, func(x: float, y: float) -> float:
		var p := Vector2(x, y) / k
		var a := clampf((95.0 - p.distance_to(Vector2(120, 110))) * k, 0.0, 1.0)
		a = maxf(a, clampf((4.0 - _line_dist(p, Vector2(60, 150), Vector2(30, 245))) * k, 0.0, 1.0))
		a = maxf(a, clampf((3.0 - _line_dist(p, Vector2(170, 170), Vector2(225, 240))) * k, 0.0, 1.0))
		if p.distance_to(Vector2(135, 95)) < 22.0:
			a = 0.0
		if p.distance_to(Vector2(230, 30)) < 6.0:
			a = 0.8
		return a)


# ---------------------------------------------------------------- проверки

static func raster(v: PackedVector2Array, idx: PackedInt32Array, size: Vector2) -> PackedByteArray:
	var w := int(size.x)
	var h := int(size.y)
	var out := PackedByteArray()
	out.resize(w * h)
	out.fill(0)
	var half := size * 0.5
	for k in range(0, idx.size(), 3):
		var a := v[idx[k]] + half
		var b := v[idx[k + 1]] + half
		var c := v[idx[k + 2]] + half
		var x0 := clampi(floori(minf(a.x, minf(b.x, c.x))), 0, w - 1)
		var x1 := clampi(ceili(maxf(a.x, maxf(b.x, c.x))), 0, w - 1)
		var y0 := clampi(floori(minf(a.y, minf(b.y, c.y))), 0, h - 1)
		var y1 := clampi(ceili(maxf(a.y, maxf(b.y, c.y))), 0, h - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var bc := RbMeshGen._bary(a, b, c, Vector2(x + 0.5, y + 0.5))
				if bc.x >= -1e-4 and bc.y >= -1e-4 and bc.z >= -1e-4:
					out[y * w + x] = 1
	return out


## Топология: обход, все вершины в деле, рёбра контуров = рёбра треугольников, площади сходятся.
func _check_topology(label: String, m: Dictionary) -> void:
	var v: PackedVector2Array = m["vertices"]
	var uv: PackedVector2Array = m["uvs"]
	var idx: PackedInt32Array = m["indices"]
	var loops: Array = m["loops"]
	var size: Vector2 = m["size"]
	t.eq(v.size(), uv.size(), label + ": uv на каждую вершину")
	t.check(idx.size() > 0 and idx.size() % 3 == 0, label + ": есть треугольники")
	var uv_bad := 0
	for i in v.size():
		if (uv[i] - (v[i] / size + Vector2(0.5, 0.5))).length() > 1e-4:
			uv_bad += 1
	t.eq(uv_bad, 0, label + ": uv = v/size + 0.5")
	var bad := 0
	var area_t := 0.0
	var used := PackedByteArray()
	used.resize(v.size())
	used.fill(0)
	var edges := {}
	var m_n := v.size()
	for k in range(0, idx.size(), 3):
		var cr := RbMeshGen._cross3(v[idx[k]], v[idx[k + 1]], v[idx[k + 2]])
		if cr <= 1e-6:
			bad += 1
		area_t += cr * 0.5
		for e in 3:
			used[idx[k + e]] = 1
			edges[idx[k + e] * m_n + idx[k + (e + 1) % 3]] = true
	t.eq(bad, 0, label + ": вывернутые или нулевые треугольники")
	t.eq(used.count(0), 0, label + ": висячие вершины")
	var area_l := 0.0
	var miss_edges := 0
	var boundary_n := 0
	for lp: PackedInt32Array in loops:
		area_l += RbMeshGen._loop_area(v, lp)
		boundary_n += lp.size()
		for i in lp.size():
			if not edges.has(lp[i] * m_n + lp[(i + 1) % lp.size()]):
				miss_edges += 1
	t.eq(miss_edges, 0, label + ": рёбра контуров есть среди рёбер треугольников")
	t.eq((m["boundary"] as PackedInt32Array).size(), boundary_n, label + ": boundary = все контуры")
	t.near(area_t, area_l, label + ": площадь треугольников = площадь контуров", area_l * 0.002 + 1.0)


## Полная проверка сетки на картинке.
func _check(label: String, img: Image, m: Dictionary, holes: Array) -> void:
	_check_topology(label, m)
	var w := img.get_width()
	var h := img.get_height()
	var v: PackedVector2Array = m["vertices"]
	var idx: PackedInt32Array = m["indices"]
	t.check(v.size() <= RbMeshGen.MAX_VERTS, label + ": не больше %d вершин (%d)" % [RbMeshGen.MAX_VERTS, v.size()])
	t.eq(m["size"], Vector2(w, h), label + ": size")
	var cover := raster(v, idx, Vector2(w, h))
	var data := img.get_data()
	var thr8 := floori(THR * 255.0)
	var miss := 0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			if data[(y * w + x) * 4 + 3] > thr8 and cover[y * w + x] == 0:
				miss += 1
	t.eq(miss, 0, label + ": непрозрачные пиксели без сетки")
	var bm := BitMap.new()
	bm.create_from_image_alpha(img, THR)
	bm.grow_mask(SLACK, Rect2i(0, 0, w, h))
	var half := Vector2(w, h) * 0.5
	var outside := 0
	for k in range(0, idx.size(), 3):
		var c := (v[idx[k]] + v[idx[k + 1]] + v[idx[k + 2]]) / 3.0 + half
		var ci := Vector2i(clampi(int(c.x), 0, w - 1), clampi(int(c.y), 0, h - 1))
		if not bm.get_bitv(ci):
			outside += 1
	t.eq(outside, 0, label + ": центры треугольников вне (расширенной) формы")
	for p: Vector2 in holes:
		t.eq(cover[int(p.y) * w + int(p.x)], 0, label + ": точка %s в дырке/выемке не покрыта" % p)


# ---------------------------------------------------------------- тесты

func test_shapes() -> void:
	var all := shapes()
	for key: String in all:
		var item: Array = all[key]
		var img: Image = item[0]
		for d in [0.0, 0.5, 1.0]:
			var t0 := Time.get_ticks_usec()
			var m := RbMeshGen.generate(img, d)
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			var v: PackedVector2Array = m["vertices"]
			print("    %-10s d=%.1f  %3d верш  %3d треуг  %d контур  %.1f мс  мин.угол %.1f°" % [
				key, d, v.size(), (m["indices"] as PackedInt32Array).size() / 3, (m["loops"] as Array).size(), ms, min_angle(m)])
			_check("%s d=%.1f" % [key, d], img, m, item[1])
	var loops_donut: Array = RbMeshGen.generate(all["donut"][0], 0.5)["loops"]
	t.eq(loops_donut.size(), 2, "у бублика внешний контур и дырка")
	var loops_blobs: Array = RbMeshGen.generate(all["blobs"][0], 0.5)["loops"]
	t.eq(loops_blobs.size(), 2, "два островка = два контура")


func test_density_budget() -> void:
	var img: Image = shapes()["circle"][0]
	var n0 := (RbMeshGen.generate(img, 0.0)["vertices"] as PackedVector2Array).size()
	var n5 := (RbMeshGen.generate(img, 0.5)["vertices"] as PackedVector2Array).size()
	var n1 := (RbMeshGen.generate(img, 1.0)["vertices"] as PackedVector2Array).size()
	print("    круг: d=0 %d, d=0.5 %d, d=1 %d вершин" % [n0, n5, n1])
	t.check(n0 >= 12 and n0 <= 80, "density 0: около 30 вершин (%d)" % n0)
	t.check(n5 > n0 and n1 > n5, "вершин больше с ростом density")
	t.check(n1 >= 200 and n1 <= RbMeshGen.MAX_VERTS, "density 1: сотни вершин (%d)" % n1)


func test_empty_and_opaque() -> void:
	var empty := Image.create_empty(64, 40, false, Image.FORMAT_RGBA8)
	var m := RbMeshGen.generate(empty, 0.5)
	t.eq((m["vertices"] as PackedVector2Array).size(), 4, "прозрачная картинка = 4 угла")
	_check_topology("пустая", m)
	var full := Image.create_empty(200, 120, false, Image.FORMAT_RGBA8)
	full.fill(Color(1, 0, 0, 1))
	for d in [0.0, 1.0]:
		var mf := RbMeshGen.generate(full, d)
		_check("непрозрачная d=%.1f" % d, full, mf, [])
		var v: PackedVector2Array = mf["vertices"]
		var bb := Rect2(v[0], Vector2.ZERO)
		for q in v:
			bb = bb.expand(q)
		t.check(bb.is_equal_approx(Rect2(-100, -60, 200, 120)), "сетка на весь прямоугольник (%s)" % bb)
		t.check(v.size() > 8 if d > 0.5 else v.size() >= 4, "внутри есть точки")
	var rgb := Image.create_empty(64, 48, false, Image.FORMAT_RGB8)
	rgb.fill(Color(0, 1, 0))
	var mr := RbMeshGen.generate(rgb, 0.3)
	_check_topology("RGB8 без альфы", mr)
	t.near(RbMeshGen._loop_area(mr["vertices"], (mr["loops"] as Array)[0]), 64.0 * 48.0, "RGB8 = весь прямоугольник", 0.5)


func test_quad() -> void:
	var m := RbMeshGen.quad(Vector2(100, 50))
	_check_topology("quad", m)
	t.eq(m["vertices"], PackedVector2Array([Vector2(-50, -25), Vector2(50, -25), Vector2(50, 25), Vector2(-50, 25)]), "углы")


func test_timing_large() -> void:
	var img := character(1024)
	var best := INF
	var m := {}
	for d in [0.0, 0.5, 1.0]:
		best = INF
		for i in 3:
			var t0 := Time.get_ticks_usec()
			m = RbMeshGen.generate(img, d)
			best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
		print("    1024x1024 d=%.1f: %.1f мс, %d вершин" % [d, best, (m["vertices"] as PackedVector2Array).size()])
		_check("персонаж 1024 d=%.1f" % d, img, m, [Vector2(135, 95) * 4.0])
		t.check(best < 300.0, "генерация 1024 укладывается (%.1f мс)" % best)
	var big := img.duplicate() as Image
	big.resize(4096, 4096, Image.INTERPOLATE_BILINEAR)
	var t1 := Time.get_ticks_usec()
	var mb := RbMeshGen.generate(big, 0.5)
	print("    4096x4096 d=0.5: %.1f мс, %d вершин" % [(Time.get_ticks_usec() - t1) / 1000.0, (mb["vertices"] as PackedVector2Array).size()])
	_check_topology("персонаж 4096", mb)


func test_edit_ops() -> void:
	var img: Image = shapes()["donut"][0]
	var m := RbMeshGen.generate(img, 0.3)
	var v: PackedVector2Array = m["vertices"]
	var idx: PackedInt32Array = m["indices"]
	var n := v.size()
	var boundary: PackedInt32Array = m["boundary"]
	var inner := -1
	var inner2 := -1
	for i in n:
		if not boundary.has(i):
			if inner < 0:
				inner = i
			elif v[i].distance_to(v[inner]) > 60.0:
				inner2 = i
	t.check(inner >= 0 and inner2 >= 0, "есть внутренние вершины")

	# добавить внутрь
	var cen := (v[idx[0]] + v[idx[1]] + v[idx[2]]) / 3.0
	var ma := RbMeshGen.add_point(m, cen)
	t.eq((ma["vertices"] as PackedVector2Array).size(), n + 1, "add_point внутри добавил вершину")
	t.check((ma["indices"] as PackedInt32Array).has(n), "новая вершина в треугольниках")
	_check_topology("add внутри", ma)
	# снаружи и в дырке: без изменений
	t.eq((RbMeshGen.add_point(m, Vector2(500, 500))["vertices"] as PackedVector2Array).size(), n, "add_point снаружи отклонён")
	t.eq((RbMeshGen.add_point(m, Vector2(0, 0))["vertices"] as PackedVector2Array).size(), n, "add_point в дырке отклонён")
	# у границы: в контур
	var lp0: PackedInt32Array = (m["loops"] as Array)[0]
	var mid := (v[lp0[0]] + v[lp0[1]]) * 0.5
	var mb := RbMeshGen.add_point(m, mid)
	t.eq(((mb["loops"] as Array)[0] as PackedInt32Array).size(), lp0.size() + 1, "точка на ребре вошла в контур")
	_check_topology("add на границу", mb)

	# убрать внутреннюю
	var mr := RbMeshGen.remove_point(m, inner)
	t.eq((mr["vertices"] as PackedVector2Array).size(), n - 1, "remove_point убрал внутреннюю")
	_check_topology("remove внутренней", mr)
	# убрать граничную
	var mrb := RbMeshGen.remove_point(m, lp0[2])
	t.eq(((mrb["loops"] as Array)[0] as PackedInt32Array).size(), lp0.size() - 1, "remove_point убрал граничную")
	_check_topology("remove граничной", mrb)
	# треугольник нельзя сделать меньше 3 вершин
	var q := RbMeshGen.quad(Vector2(10, 10))
	q = RbMeshGen.remove_point(q, 0)
	t.eq((RbMeshGen.remove_point(q, 0)["vertices"] as PackedVector2Array).size(), 3, "контур из 3 вершин не трогаем")

	# сдвиг чуть-чуть: треугольники те же, uv новые
	var p := v[inner] + Vector2(0.6, -0.4)
	var mm := RbMeshGen.move_point(m, inner, p)
	t.eq(mm["indices"], m["indices"], "маленький сдвиг без перестройки")
	t.check(((mm["uvs"] as PackedVector2Array)[inner] - (p / Vector2(img.get_size()) +Vector2(0.5, 0.5))).length() < 1e-5, "uv пересчитан")
	_check_topology("move мало", mm)
	# сдвиг далеко: перестройка без вывернутых
	var far := v[inner2] + Vector2(1.5, 1.1)
	var mf := RbMeshGen.move_point(m, inner, far)
	t.eq((mf["vertices"] as PackedVector2Array)[inner], far, "вершина уехала")
	t.check(mf["indices"] != m["indices"], "далёкий сдвиг перестроил треугольники")
	_check_topology("move далеко", mf)
	# наружу: нельзя
	t.eq(RbMeshGen.move_point(m, inner, Vector2(0, 0))["vertices"], m["vertices"], "внутреннюю в дырку не двигаем")
	# граничную наружу немного: можно
	var bp := v[lp0[3]] * 1.03
	var mbm := RbMeshGen.move_point(m, lp0[3], bp)
	t.eq((mbm["vertices"] as PackedVector2Array)[lp0[3]], bp, "граничную сдвинули")
	_check_topology("move граничной", mbm)

	# locate
	for k in [0, 3, 30]:
		var a := v[idx[3 * k]]
		var b := v[idx[3 * k + 1]]
		var c := v[idx[3 * k + 2]]
		var r := RbMeshGen.locate(m, (a + b + c) / 3.0)
		t.eq(r["tri"], k, "locate нашёл треугольник")
		t.check(((r["bary"] as Vector3) - Vector3.ONE / 3.0).length() < 1e-4, "барицентрические 1/3")
	var ro := RbMeshGen.locate(m, Vector2(1000, 3))
	var bo: Vector3 = ro["bary"]
	t.check(int(ro["tri"]) >= 0 and absf(bo.x + bo.y + bo.z - 1.0) < 1e-5 and bo.x >= 0 and bo.y >= 0 and bo.z >= 0, "locate снаружи: ближайший")
	# ближайшая вершина
	t.eq(RbMeshGen.nearest_vertex(m, v[inner] + Vector2(1, 1), 5.0), inner, "nearest_vertex")
	t.eq(RbMeshGen.nearest_vertex(m, Vector2(5000, 0), 5.0), -1, "nearest_vertex далеко = -1")


func test_loops_from_plain_mesh() -> void:
	# сетка без "loops" (как из RbLayer): контуры собираются по треугольникам
	var q := RbMeshGen.quad(Vector2(40, 20))
	q.erase("loops")
	var m := RbMeshGen.add_point(q, Vector2(3, 2))
	t.eq((m["vertices"] as PackedVector2Array).size(), 5, "точка добавлена без loops")
	_check_topology("без loops", m)


## Минимальный угол сетки в градусах (для отчёта).
static func min_angle(m: Dictionary) -> float:
	var v: PackedVector2Array = m["vertices"]
	var idx: PackedInt32Array = m["indices"]
	var best := 180.0
	for k in range(0, idx.size(), 3):
		for e in 3:
			var a := v[idx[k + e]]
			var b := v[idx[k + (e + 1) % 3]]
			var c := v[idx[k + (e + 2) % 3]]
			best = minf(best, rad_to_deg((b - a).angle_to(c - a)))
	return best
