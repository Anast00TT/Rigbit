class_name RbMeshGen
extends RefCounted
## Сетка слоя: автогенерация по альфе картинки и ручная правка точек пальцем.
## Ядро, без UI и рендера.
##
## Сетка — словарь:
##   "vertices": PackedVector2Array   локальные координаты слоя, центр картинки = (0,0)
##   "uvs": PackedVector2Array        uv = вершина / size + 0.5
##   "indices": PackedInt32Array      треугольники, площадь положительная (обход как в RbLayer.make_quad_mesh)
##   "boundary": PackedInt32Array     все граничные вершины, контуры подряд
##   "loops": Array[PackedInt32Array] контуры по отдельности: внешние с положительной площадью, дыры с отрицательной
##   "size": Vector2                  размер картинки в пикселях
## Область сетки всегда слева от направленного ребра контура (cross(b - a, q - a) > 0).
## Сразу после generate() граничные вершины идут первыми, внутренние после них.
## После правок порядок произвольный: что граница, смотреть по "loops".

const GRID_MAX := 256  ## длинная сторона маски после уменьшения
const MAX_VERTS := 600
const MIN_TARGET := 30.0  ## density = 0
const MAX_TARGET := 400.0  ## density = 1
const SMOOTH_ITERS := 3
const INNER_MARGIN := 0.55  ## внутренние точки не ближе этой доли шага к границе
const SNAP_PX := 0.75  ## add_point: ближе к границе = точка на границе
const DUP_PX := 0.5  ## ближе = та же точка
const SEED := 20240611
const TOL_OUT_K := 0.3  ## допуск упрощения контура наружу, доля шага сетки
const TOL_IN_K := 0.2  ## и внутрь



# ---------------------------------------------------------------- публичное API

## Сетка по альфе. density 0..1 (примерно 30..400 вершин, не больше ~600).
## Сетка покрывает все пиксели с альфой > alpha_threshold с запасом не меньше padding_px.
static func generate(img: Image, density: float, alpha_threshold := 0.05, padding_px := 3.0) -> Dictionary:
	if img == null or img.is_empty():
		return quad(Vector2.ZERO)
	var w := img.get_width()
	var h := img.get_height()
	var size := Vector2(w, h)
	density = clampf(density, 0.0, 1.0)
	var pad := maxf(padding_px, 0.0)
	var src := img
	if src.is_compressed() or src.get_format() != Image.FORMAT_RGBA8:
		src = img.duplicate() as Image
		if src.is_compressed():
			src.decompress()
		src.convert(Image.FORMAT_RGBA8)

	# 1. грубая маска: клетка s x s пикселей включена, если в ней есть пиксель с альфой > порога
	var s := 1
	var lvl := 0
	while maxi(w, h) > GRID_MAX * s:
		s *= 2
		lvl += 1
	var gw := ceili(float(w) / s)
	var gh := ceili(float(h) / s)
	var thr8 := floori(clampf(alpha_threshold, 0.0, 1.0) * 255.0)
	var data: PackedByteArray
	var off := 0
	var stride := w
	if s == 1:
		data = src.get_data()
	else:
		var work: Image
		if gw * s != w or gh * s != h:
			work = Image.create_empty(gw * s, gh * s, false, Image.FORMAT_RGBA8)
			work.blit_rect(src, Rect2i(0, 0, w, h), Vector2i.ZERO)
		else:
			work = src.duplicate() as Image
			if work.has_mipmaps():
				work.clear_mipmaps()
		work.generate_mipmaps()  # уровень lvl = среднее по блоку s x s
		data = work.get_data()
		off = work.get_mipmap_offset(lvl)
		stride = gw * s
	var cov := PackedByteArray()
	cov.resize(gw * gh)
	cov.fill(0)
	var mask := PackedByteArray()
	mask.resize(gw * gh * 4)
	mask.fill(0)
	var on_cells := 0
	for cy in gh:
		var row := cy * gw
		for cx in gw:
			var i := row + cx
			var a := data[off + i * 4 + 3]
			if a == 0:
				continue
			if a <= thr8:
				# среднее ниже порога, но отдельный пиксель может быть выше: проверить блок честно
				if s == 1 or not _block_any(data, stride, cx * s, cy * s, mini(s, w - cx * s), mini(s, h - cy * s), thr8):
					continue
			cov[i] = a
			mask[i * 4 + 3] = 255
			on_cells += 1
	if on_cells == 0:
		return quad(size)

	# 2. шаг сетки и допуски упрощения, от них запас расширения
	var n_target := MIN_TARGET * pow(MAX_TARGET / MIN_TARGET, density)
	var h_min := maxf(4.0, 2.0 * s)
	var a_on := float(on_cells) * s * s
	var h0 := maxf(_spacing(a_on, 3.5 * sqrt(a_on), n_target), h_min)
	# наружу контур может отходить смелее (лишняя прозрачная кромка безвредна): иначе на изгибах
	# точки края идут втрое чаще внутренних; внутрь строго, от этого зависит запас расширения маски
	var tol_out := maxf(float(s), TOL_OUT_K * h0)
	var tol_in := maxf(0.5 * s, 0.5 * maxf(float(s), TOL_IN_K * h0))

	# 3. расширение маски (BitMap.grow_mask в C++), круглое ядро
	var gimg := Image.create_from_data(gw, gh, false, Image.FORMAT_RGBA8, mask)
	var bm := BitMap.new()
	bm.create_from_image_alpha(gimg, 0.5)
	var grow := _grow_radius(pad + tol_in, s)
	if grow > 0:
		bm.grow_mask(grow, Rect2i(0, 0, gw, gh))
	var grid := bm.convert_to_image().get_data()

	# 4. контуры по границам клеток
	var corner_loops: Array[PackedInt32Array] = []
	for attempt in 64:
		var tr := _trace(grid, gw, gh)
		if tr["ok"]:
			corner_loops = tr["loops"]
			break
	if corner_loops.is_empty():
		return quad(size)
	var raw: Array[PackedVector2Array] = []
	var areas := PackedFloat64Array()
	for cl in corner_loops:
		var pts := _corner_points(cl, gw + 1, s, w, h)
		if pts.size() < 3:
			continue
		raw.append(pts)
		areas.append(_area(pts))

	# 5. мелкие островки и дырки выкинуть
	var img_area := float(w) * h
	var min_island := 0.0015 * img_area
	var min_mass := maxf(16.0, 1e-5 * img_area)
	var min_hole := maxf(0.001 * img_area, 16.0 * s * s)
	var drop := PackedByteArray()
	drop.resize(raw.size())
	drop.fill(0)
	for i in raw.size():
		if areas[i] > 0.0:
			if areas[i] < min_island and _island_mass(raw[i], cov, gw, gh, s, w, h) < min_mass:
				drop[i] = 1
		elif -areas[i] < min_hole:
			drop[i] = 1
	var changed := true
	while changed:  # всё, что внутри выкинутого, тоже долой
		changed = false
		for i in raw.size():
			if drop[i] == 0:
				continue
			for j in raw.size():
				if drop[j] == 0 and Geometry2D.is_point_in_polygon(raw[j][0], raw[i]):
					drop[j] = 1
					changed = true
	var kept: Array[PackedVector2Array] = []
	var area_sum := 0.0
	for i in raw.size():
		if drop[i] == 0:
			kept.append(raw[i])
			area_sum += areas[i]
	if kept.is_empty() or area_sum <= 0.0:
		return quad(size)

	# 6. упрощение, разбивка длинных рёбер, внутренние точки; держим бюджет вершин
	var rng := RandomNumberGenerator.new()
	var sp := h0
	var res: Array[PackedVector2Array] = []
	var inner := PackedVector2Array()
	var first := true
	var corrected := false
	for attempt in 12:
		var simp := _simplify_loops(kept, tol_out, tol_in)
		if first:
			first = false
			sp = maxf(_spacing(area_sum, _perimeter(simp), n_target), h_min)
		rng.seed = SEED
		res = []
		var total := 0
		for lp in simp:
			var r := _resample(lp, sp)
			res.append(r)
			total += r.size()
		var exact := maxf(tol_out, tol_in) >= 0.9 * INNER_MARGIN * sp
		inner = _interior(res, grid, gw, gh, s, w, h, sp, rng, exact)
		total += inner.size()
		if not corrected:
			corrected = true
			if total > n_target * 1.3 or total < n_target * 0.75:
				var nsp := maxf(sp * sqrt(float(total) / n_target), h_min)
				if absf(nsp - sp) > 0.05 * sp:
					sp = nsp
					continue
		if total <= MAX_VERTS:
			break
		sp *= sqrt(float(total) / (MAX_VERTS * 0.85))
		tol_out *= 1.6

	# 7. ограниченная триангуляция Делоне + сглаживание внутренних точек
	var verts := PackedVector2Array()
	var loops: Array[PackedInt32Array] = []
	for lp in res:
		var idx := PackedInt32Array()
		for q in lp:
			idx.append(verts.size())
			verts.append(q)
		loops.append(idx)
	var nb := verts.size()
	verts.append_array(inner)
	var tris := _cdt(verts, loops)
	for it in SMOOTH_ITERS:
		if nb >= verts.size():
			break
		verts = _smooth(verts, tris, nb)
		tris = _cdt(verts, loops)
	var half := size * 0.5
	for i in verts.size():
		verts[i] -= half
	return _make(verts, tris, loops, size)


## Простая сетка из 4 углов, 2 треугольника.
static func quad(size: Vector2) -> Dictionary:
	var hs := size * 0.5
	var verts := PackedVector2Array([Vector2(-hs.x, -hs.y), Vector2(hs.x, -hs.y), Vector2(hs.x, hs.y), Vector2(-hs.x, hs.y)])
	var loops: Array[PackedInt32Array] = [PackedInt32Array([0, 1, 2, 3])]
	return _make(verts, PackedInt32Array([0, 1, 2, 0, 2, 3]), loops, size)


## Добавить точку. Внутри области = внутренняя вершина, у самой границы = новая вершина контура.
## Снаружи или поверх существующей вершины: сетка не меняется. Новая вершина всегда последняя.
static func add_point(mesh: Dictionary, p: Vector2) -> Dictionary:
	var verts: PackedVector2Array = mesh.get("vertices", PackedVector2Array())
	var loops := _loops_of(mesh)
	if verts.size() < 3 or loops.is_empty():
		return mesh
	for q in verts:
		if q.distance_to(p) < DUP_PX:
			return mesh
	var best := INF
	var bl := -1
	var bi := -1
	var bq := p
	for li in loops.size():
		var lp := loops[li]
		for i in lp.size():
			var c := Geometry2D.get_closest_point_to_segment(p, verts[lp[i]], verts[lp[(i + 1) % lp.size()]])
			var d := c.distance_to(p)
			if d < best:
				best = d
				bl = li
				bi = i
				bq = c
	var nv := verts.duplicate()
	if best <= SNAP_PX:
		for q in verts:
			if q.distance_to(bq) < DUP_PX:
				return mesh
		nv.append(bq)
		var lp := loops[bl]
		lp.insert(bi + 1, nv.size() - 1)
		loops[bl] = lp
	elif _inside(_polys(verts, loops), p):
		nv.append(p)
	else:
		return mesh
	var r := _rebuild(mesh, nv, loops)
	return mesh if r.is_empty() else r


## Убрать вершину. Индексы после неё сдвигаются на 1 (веса костей сдвинуть так же).
## Граничную можно убрать, только если в контуре останется >= 3 вершин и все внутренние останутся внутри.
static func remove_point(mesh: Dictionary, index: int) -> Dictionary:
	var verts: PackedVector2Array = mesh.get("vertices", PackedVector2Array())
	if index < 0 or index >= verts.size():
		return mesh
	var loops := _loops_of(mesh)
	var li := -1
	var pos := -1
	for i in loops.size():
		pos = loops[i].find(index)
		if pos >= 0:
			li = i
			break
	if li >= 0:
		var lp := loops[li]
		var n := lp.size()
		if n <= 3:
			return mesh
		var prev := lp[(pos - 1 + n) % n]
		var nxt := lp[(pos + 1) % n]
		var old_area := _loop_area(verts, lp)
		lp.remove_at(pos)
		loops[li] = lp
		var new_area := _loop_area(verts, lp)
		if absf(new_area) < 1e-3 or signf(new_area) != signf(old_area):
			return mesh
		if _segment_hits_loops(verts, loops, prev, nxt):
			return mesh
		if not _interior_inside(verts, loops, index):
			return mesh
	var nv := verts.duplicate()
	nv.remove_at(index)
	for i in loops.size():
		var lp := loops[i]
		for k in lp.size():
			if lp[k] > index:
				lp[k] -= 1
		loops[i] = lp
	var r := _rebuild(mesh, nv, loops)
	return mesh if r.is_empty() else r


## Сдвинуть вершину в позе покоя, uv пересчитывается (uv = p / size + 0.5).
## Перестраивает треугольники, только если какой-то вывернулся. Недопустимый сдвиг
## (внутренняя точка за границей, граница пересекает себя) возвращает сетку без изменений.
static func move_point(mesh: Dictionary, index: int, p: Vector2) -> Dictionary:
	var verts: PackedVector2Array = mesh.get("vertices", PackedVector2Array())
	if index < 0 or index >= verts.size() or verts[index].is_equal_approx(p):
		return mesh
	for i in verts.size():
		if i != index and verts[i].distance_to(p) < DUP_PX:
			return mesh
	var loops := _loops_of(mesh)
	var nv := verts.duplicate()
	nv[index] = p
	var li := -1
	var pos := -1
	for i in loops.size():
		pos = loops[i].find(index)
		if pos >= 0:
			li = i
			break
	if li >= 0:
		var lp := loops[li]
		var n := lp.size()
		if _segment_hits_loops(nv, loops, lp[(pos - 1 + n) % n], index) or _segment_hits_loops(nv, loops, index, lp[(pos + 1) % n]):
			return mesh
		var old_area := _loop_area(verts, lp)
		var new_area := _loop_area(nv, lp)
		if absf(new_area) < 1e-3 or signf(new_area) != signf(old_area):
			return mesh
		if not _interior_inside(nv, loops, -1):
			return mesh
	elif not _inside_strict(_polys(nv, loops), p):
		return mesh
	var size: Vector2 = mesh.get("size", Vector2.ONE)
	var tris: PackedInt32Array = mesh.get("indices", PackedInt32Array())
	var ok := not tris.is_empty()
	for k in range(0, tris.size(), 3):
		if tris[k] == index or tris[k + 1] == index or tris[k + 2] == index:
			if _cross3(nv[tris[k]], nv[tris[k + 1]], nv[tris[k + 2]]) <= 1e-6:
				ok = false
				break
	if ok:
		return _make(nv, tris, loops, size)
	var r := _rebuild(mesh, nv, loops)
	return mesh if r.is_empty() else r


## Треугольник под точкой и барицентрические координаты (для переноса весов костей).
## Если точка вне сетки: ближайший треугольник и координаты ближайшей точки на нём.
static func locate(mesh: Dictionary, p: Vector2) -> Dictionary:
	var verts: PackedVector2Array = mesh.get("vertices", PackedVector2Array())
	var tris: PackedInt32Array = mesh.get("indices", PackedInt32Array())
	var best := INF
	var bt := -1
	var bb := Vector3.ZERO
	for k in range(0, tris.size(), 3):
		var a := verts[tris[k]]
		var b := verts[tris[k + 1]]
		var c := verts[tris[k + 2]]
		var bc := _bary(a, b, c, p)
		if bc.x >= -1e-5 and bc.y >= -1e-5 and bc.z >= -1e-5:
			return {"tri": int(k / 3.0), "bary": bc}
		var pts := [a, b, c]
		for e in 3:
			var u: Vector2 = pts[e]
			var v: Vector2 = pts[(e + 1) % 3]
			var q := Geometry2D.get_closest_point_to_segment(p, u, v)
			var d := q.distance_squared_to(p)
			if d < best:
				best = d
				bt = int(k / 3.0)
				var len2 := u.distance_squared_to(v)
				var f := 0.0 if len2 <= 0.0 else clampf((q - u).dot(v - u) / len2, 0.0, 1.0)
				bb = Vector3.ZERO
				bb[e] = 1.0 - f
				bb[(e + 1) % 3] = f
	return {"tri": bt, "bary": bb}


## Ближайшая вершина не дальше max_dist, иначе -1.
static func nearest_vertex(mesh: Dictionary, p: Vector2, max_dist: float) -> int:
	var verts: PackedVector2Array = mesh.get("vertices", PackedVector2Array())
	var best := max_dist * max_dist
	var bi := -1
	for i in verts.size():
		var d := verts[i].distance_squared_to(p)
		if d <= best:
			best = d
			bi = i
	return bi


# ---------------------------------------------------------------- маска и контуры

static func _block_any(data: PackedByteArray, stride: int, x0: int, y0: int, bw: int, bh: int, thr8: int) -> bool:
	for yy in bh:
		var base := ((y0 + yy) * stride + x0) * 4 + 3
		for xx in bw:
			if data[base + xx * 4] > thr8:
				return true
	return false


## Радиус расширения в клетках, чтобы вокруг каждого пикселя маски был запас m пикселей.
static func _grow_radius(m: float, s: int) -> int:
	if m <= 0.0:
		return 0
	var k := m / s
	var lim := ceili(k) + 1
	var best := 0
	for a in lim + 1:
		for b in lim + 1:
			var da := maxf(a - 1.0, 0.0)
			var db := maxf(b - 1.0, 0.0)
			if da * da + db * db < k * k:
				best = maxi(best, a * a + b * b)
	return ceili(sqrt(float(best)))


## Шаг сетки под целевое число вершин: N ~ (A - 0.55·h·P) / (0.866·h²) + P / h.
static func _spacing(area: float, perim: float, n: float) -> float:
	var qa := 0.8660254 * n
	var qb := -0.3160254 * perim
	var qc := -maxf(area, 1.0)
	return (-qb + sqrt(qb * qb - 4.0 * qa * qc)) / (2.0 * qa)


static func _row_runs(grid: PackedByteArray, gw: int, y: int) -> PackedInt32Array:
	var row := grid.slice(y * gw, (y + 1) * gw)
	var out := PackedInt32Array()
	var x := 0
	while x < gw:
		var a := row.find(255, x)
		if a < 0:
			break
		var b := row.find(0, a)
		if b < 0:
			b = gw
		out.append(a)
		out.append(b)
		x = b
	return out


static func _link(nxt: PackedInt32Array, starts: PackedInt32Array, conflicts: PackedInt32Array, a: int, b: int) -> void:
	if nxt[a] != -1:
		conflicts.append(a)
		return
	nxt[a] = b
	starts.append(a)


## Обход границ включённых клеток. Область слева от ребра (cross > 0).
## Диагональные «шахматные» стыки заливаются и обход повторяется (ok = false).
@warning_ignore("integer_division")
static func _trace(grid: PackedByteArray, gw: int, gh: int) -> Dictionary:
	var cw := gw + 1
	var nxt := PackedInt32Array()
	nxt.resize(cw * (gh + 1))
	nxt.fill(-1)
	var starts := PackedInt32Array()
	var conflicts := PackedInt32Array()
	var prev := PackedInt32Array()
	for y in gh + 1:
		var cur := PackedInt32Array()
		if y < gh:
			cur = _row_runs(grid, gw, y)
			for r in range(0, cur.size(), 2):
				_link(nxt, starts, conflicts, (y + 1) * cw + cur[r], y * cw + cur[r])
				_link(nxt, starts, conflicts, y * cw + cur[r + 1], (y + 1) * cw + cur[r + 1])
		if cur != prev:
			var xs := PackedInt32Array(prev)
			xs.append_array(cur)
			xs.sort()
			var pi := 0
			var ci := 0
			for j in xs.size() - 1:
				var x0 := xs[j]
				var x1 := xs[j + 1]
				if x1 == x0:
					continue
				while pi < prev.size() and prev[pi + 1] <= x0:
					pi += 2
				while ci < cur.size() and cur[ci + 1] <= x0:
					ci += 2
				var pon := pi < prev.size() and prev[pi] <= x0
				var con := ci < cur.size() and cur[ci] <= x0
				if pon == con:
					continue
				if con:
					_link(nxt, starts, conflicts, y * cw + x0, y * cw + x1)
				else:
					_link(nxt, starts, conflicts, y * cw + x1, y * cw + x0)
		prev = cur
	if not conflicts.is_empty():
		for c in conflicts:
			var x := c % cw
			var y := c / cw
			for dy in [-1, 0]:
				for dx in [-1, 0]:
					var gx: int = x + dx
					var gy: int = y + dy
					if gx >= 0 and gy >= 0 and gx < gw and gy < gh:
						grid[gy * gw + gx] = 255
		return {"ok": false}
	var loops: Array[PackedInt32Array] = []
	for st in starts:
		if nxt[st] < 0:
			continue
		var lp := PackedInt32Array()
		var c := st
		while true:
			lp.append(c)
			var nc := nxt[c]
			nxt[c] = -1
			if nc < 0 or nc == st:
				break
			c = nc
		loops.append(lp)
	return {"ok": true, "loops": loops}


## Углы клеток в пиксели, обрезка по картинке, без коллинеарных точек.
@warning_ignore("integer_division")
static func _corner_points(cl: PackedInt32Array, cw: int, s: int, w: int, h: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for c in cl:
		var q := Vector2(mini((c % cw) * s, w), mini((c / cw) * s, h))
		if pts.is_empty() or pts[pts.size() - 1] != q:
			pts.append(q)
	if pts.size() > 1 and pts[0] == pts[pts.size() - 1]:
		pts.resize(pts.size() - 1)
	var n := pts.size()
	var out := PackedVector2Array()
	for i in n:
		var a := pts[(i - 1 + n) % n]
		var b := pts[i]
		var c := pts[(i + 1) % n]
		if _orient(a.x, a.y, b.x, b.y, c.x, c.y) != 0.0:
			out.append(b)
	return out


## Примерное число непрозрачных пикселей внутри островка (по неразмытой маске).
static func _island_mass(poly: PackedVector2Array, cov: PackedByteArray, gw: int, gh: int, s: int, w: int, h: int) -> float:
	var bb := _bbox([poly])
	var x0 := clampi(int(bb.position.x / s), 0, gw - 1)
	var y0 := clampi(int(bb.position.y / s), 0, gh - 1)
	var x1 := clampi(int(bb.end.x / s), 0, gw - 1)
	var y1 := clampi(int(bb.end.y / s), 0, gh - 1)
	var sum := 0.0
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var a := cov[cy * gw + cx]
			if a == 0:
				continue
			var c := Vector2(minf((cx + 0.5) * s, w - 0.25), minf((cy + 0.5) * s, h - 0.25))
			if Geometry2D.is_point_in_polygon(c, poly):
				sum += a / 255.0 * s * s
	return sum


# ---------------------------------------------------------------- упрощение и точки

## Дуглас-Пекер для замкнутого контура, несимметричный: хорда может уйти наружу
## от области на tol_out, а внутрь (срезая рисунок) только на tol_in.
static func _simplify(pts: PackedVector2Array, tol_out: float, tol_in: float) -> PackedVector2Array:
	var n := pts.size()
	if n <= 3:
		return pts
	var far := 0
	var fd := -1.0
	for i in n:
		var d := pts[i].distance_squared_to(pts[0])
		if d > fd:
			fd = d
			far = i
	var keep := PackedByteArray()
	keep.resize(n)
	keep.fill(0)
	keep[0] = 1
	keep[far] = 1
	var stack := PackedInt32Array([0, far, far, n])
	while not stack.is_empty():
		var sz := stack.size()
		var i0 := stack[sz - 2]
		var i1 := stack[sz - 1]
		stack.resize(sz - 2)
		if i1 - i0 < 2:
			continue
		var a := pts[i0]
		var b := pts[i1 % n]
		var ax := a.x
		var ay := a.y
		var dx := b.x - ax
		var dy := b.y - ay
		var ln := sqrt(dx * dx + dy * dy)
		var worst := 1.0
		var wi := -1
		for i in range(i0 + 1, i1):
			var q := pts[i]
			var v: float
			if ln < 1e-9:
				var dd := sqrt((q.x - ax) * (q.x - ax) + (q.y - ay) * (q.y - ay))
				v = dd / tol_in if tol_in > 0.0 else (INF if dd > 1e-9 else 0.0)
			else:
				var d := (dx * (q.y - ay) - dy * (q.x - ax)) / ln
				if d >= 0.0:
					v = d / tol_out
				elif tol_in > 0.0:
					v = -d / tol_in
				else:
					v = INF if d < -1e-9 else 0.0
			if v > worst:
				worst = v
				wi = i
		if wi >= 0:
			keep[wi] = 1
			stack.append_array(PackedInt32Array([i0, wi, wi, i1]))
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(pts[i])
	return out


## Упростить все контуры; если упрощённые пересеклись, упрощать их мягче, в крайнем случае не трогать.
static func _simplify_loops(kept: Array[PackedVector2Array], tol_out: float, tol_in: float) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for lp in kept:
		var q := _simplify(lp, tol_out, tol_in)
		if q.size() < 3 or absf(_area(q)) < 0.5:
			q = lp
		out.append(q)
	var to := tol_out
	var ti := tol_in
	for attempt in 4:
		var bad := SegHash.new(out, _bbox(out).size.length() / 32.0).crossing_loops()
		if bad.is_empty():
			break
		to *= 0.5
		ti *= 0.5
		for li in bad:
			var q := kept[li] if attempt == 3 else _simplify(kept[li], to, ti)
			if q.size() < 3 or absf(_area(q)) < 0.5:
				q = kept[li]
			out[li] = q
	return out


## Длинные рёбра режутся на куски около sp.
static func _resample(lp: PackedVector2Array, sp: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := lp.size()
	for i in n:
		var a := lp[i]
		var b := lp[(i + 1) % n]
		out.append(a)
		var k := maxi(1, roundi(a.distance_to(b) / sp))
		for j in range(1, k):
			out.append(a.lerp(b, float(j) / k))
	return out


## Внутренние точки: шестиугольная решётка с лёгким дрожанием, отступ от границы INNER_MARGIN·sp.
static func _interior(loops: Array[PackedVector2Array], grid: PackedByteArray, gw: int, gh: int, s: int, w: int, h: int, sp: float, rng: RandomNumberGenerator, exact: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	var hs := SegHash.new(loops, sp)
	var bb := _bbox(loops)
	var row_h := sp * 0.8660254
	var rows := int(bb.size.y / row_h)
	var cols := int(bb.size.x / sp)
	var oy := bb.position.y + (bb.size.y - rows * row_h) * 0.5
	var ox := bb.position.x + (bb.size.x - cols * sp) * 0.5
	var mg2 := INNER_MARGIN * sp * INNER_MARGIN * sp
	var jit := 0.04 * sp
	for j in rows + 1:
		var y0 := oy + j * row_h
		var shift := 0.5 * sp if j % 2 == 1 else 0.0
		for i in range(-1, cols + 1):
			var x := ox + i * sp + shift + rng.randf_range(-jit, jit)
			var y := y0 + rng.randf_range(-jit, jit)
			if x <= 0.0 or y <= 0.0 or x >= w or y >= h:
				continue
			var cx := int(x / s)
			var cy := int(y / s)
			if cx >= gw or cy >= gh or grid[cy * gw + cx] == 0:
				continue
			if hs.dist2(x, y) < mg2:
				continue
			if exact and not _inside(loops, Vector2(x, y)):
				continue
			out.append(Vector2(x, y))
	return out


## Лапласово сглаживание внутренних вершин (индексы >= first_inner), без выворачивания треугольников.
static func _smooth(p: PackedVector2Array, tris: PackedInt32Array, first_inner: int) -> PackedVector2Array:
	var n := p.size()
	var sx := PackedFloat64Array()
	sx.resize(n)
	sx.fill(0.0)
	var sy := PackedFloat64Array()
	sy.resize(n)
	sy.fill(0.0)
	var cnt := PackedInt32Array()
	cnt.resize(n)
	cnt.fill(0)
	for k in range(0, tris.size(), 3):
		for e in 3:
			var a := tris[k + e]
			var b := tris[k + (e + 1) % 3]
			sx[a] += p[b].x
			sy[a] += p[b].y
			cnt[a] += 1
			sx[b] += p[a].x
			sy[b] += p[a].y
			cnt[b] += 1
	var out := p.duplicate()
	for i in range(first_inner, n):
		if cnt[i] > 0:
			out[i] = p[i].lerp(Vector2(sx[i] / cnt[i], sy[i] / cnt[i]), 0.6)
	for pass_i in 8:
		var bad := false
		for k in range(0, tris.size(), 3):
			var a := tris[k]
			var b := tris[k + 1]
			var c := tris[k + 2]
			var before := _cross3(p[a], p[b], p[c])
			var after := _cross3(out[a], out[b], out[c])
			if after > 0.0 and after >= 0.1 * before:
				continue
			for v in [a, b, c]:
				if v >= first_inner and out[v] != p[v]:
					out[v] = p[v]
					bad = true
		if not bad:
			break
	return out


# ---------------------------------------------------------------- триангуляция

## Ограниченная триангуляция Делоне: Делоне Godot (с рамкой) → восстановление рёбер контуров
## переворотами (Sloan) → Лоусон → внутренние треугольники по чётности пересечений контуров.
static func _cdt(pts: PackedVector2Array, loops: Array[PackedInt32Array]) -> PackedInt32Array:
	var nreal := pts.size()
	if nreal < 3:
		return PackedInt32Array()
	var bb := Rect2(pts[0], Vector2.ZERO)
	for q in pts:
		bb = bb.expand(q)
	var mg := maxf(bb.size.x, bb.size.y) + 16.0
	var all := pts.duplicate()
	all.append(bb.position + Vector2(-mg, -mg))
	all.append(Vector2(bb.end.x + mg, bb.position.y - mg))
	all.append(bb.end + Vector2(mg, mg))
	all.append(Vector2(bb.position.x - mg, bb.end.y + mg))
	var tr := Tri.new()
	tr.setup(all, Geometry2D.triangulate_delaunay(all))
	for lp in loops:
		for i in lp.size():
			tr.cons[tr.key(lp[i], lp[(i + 1) % lp.size()])] = true
	for lp in loops:
		for i in lp.size():
			var a := lp[i]
			var b := lp[(i + 1) % lp.size()]
			if tr.find_edge(a, b) < 0:
				tr.recover(a, b)
	return tr.classify(nreal)


class Tri:
	## Треугольники с соседями: tri[3k+j], ребро j = (tri[3k+j], tri[3k+(j+1)%3]), adj[3k+j] = сосед через него.
	var pts := PackedVector2Array()
	var tri := PackedInt32Array()
	var adj := PackedInt32Array()
	var vt := PackedInt32Array()  # вершина -> какой-нибудь её треугольник
	var cons := {}  # ключи рёбер контуров
	var m := 0

	@warning_ignore("integer_division")
	func setup(points: PackedVector2Array, raw: PackedInt32Array) -> void:
		pts = points
		m = points.size()
		var tc := raw.size() / 3
		tri.resize(tc * 3)
		adj.resize(tc * 3)
		adj.fill(-1)
		vt.resize(m)
		vt.fill(-1)
		for k in tc:
			var a := raw[3 * k]
			var b := raw[3 * k + 1]
			var c := raw[3 * k + 2]
			if orient(a, b, c) < 0.0:
				var tmp := b
				b = c
				c = tmp
			tri[3 * k] = a
			tri[3 * k + 1] = b
			tri[3 * k + 2] = c
		var em := {}
		for k in tc:
			for j in 3:
				var a := tri[3 * k + j]
				var b := tri[3 * k + (j + 1) % 3]
				vt[a] = k
				var rk: int = em.get(b * m + a, -1)
				if rk >= 0:
					adj[3 * k + j] = rk / 3
					adj[rk] = k
				else:
					em[a * m + b] = 3 * k + j

	func key(a: int, b: int) -> int:
		return mini(a, b) * m + maxi(a, b)

	func orient(a: int, b: int, c: int) -> float:
		var pa := pts[a]
		var pb := pts[b]
		var pc := pts[c]
		return RbMeshGen._orient(pa.x, pa.y, pb.x, pb.y, pc.x, pc.y)

	func incircle(a: int, b: int, c: int, d: int) -> float:
		var pd := pts[d]
		var adx: float = pts[a].x - pd.x
		var ady: float = pts[a].y - pd.y
		var bdx: float = pts[b].x - pd.x
		var bdy: float = pts[b].y - pd.y
		var cdx: float = pts[c].x - pd.x
		var cdy: float = pts[c].y - pd.y
		return (adx * adx + ady * ady) * (bdx * cdy - cdx * bdy) \
			- (bdx * bdx + bdy * bdy) * (adx * cdy - cdx * ady) \
			+ (cdx * cdx + cdy * cdy) * (adx * bdy - bdx * ady)

	func vidx(k: int, a: int) -> int:
		if tri[3 * k] == a:
			return 0
		if tri[3 * k + 1] == a:
			return 1
		if tri[3 * k + 2] == a:
			return 2
		return -1

	func edge_of(k: int, a: int, b: int) -> int:
		for j in 3:
			if tri[3 * k + j] == a and tri[3 * k + (j + 1) % 3] == b:
				return j
		return -1

	## 3k+j треугольника с ребром a-b (в любую сторону), -1 если ребра нет.
	func find_edge(a: int, b: int) -> int:
		var t0 := vt[a]
		if t0 < 0:
			return -1
		var k := t0
		for g in 4096:
			var j := vidx(k, a)
			if j < 0:
				return -1
			if tri[3 * k + (j + 1) % 3] == b:
				return 3 * k + j
			if tri[3 * k + (j + 2) % 3] == b:
				return 3 * k + (j + 2) % 3
			k = adj[3 * k + (j + 2) % 3]
			if k < 0 or k == t0:
				break
		if k < 0:
			k = t0
			for g in 4096:
				k = adj[3 * k + vidx(k, a)]
				if k < 0 or k == t0:
					break
				var j := vidx(k, a)
				if tri[3 * k + (j + 1) % 3] == b:
					return 3 * k + j
				if tri[3 * k + (j + 2) % 3] == b:
					return 3 * k + (j + 2) % 3
		return -1

	## Перевернуть ребро e треугольника k: (a,b,c)+(b,a,d) -> (c,a,d)+(d,b,c).
	func flip(k: int, e: int) -> void:
		var a := tri[3 * k + e]
		var b := tri[3 * k + (e + 1) % 3]
		var c := tri[3 * k + (e + 2) % 3]
		var u := adj[3 * k + e]
		var f := edge_of(u, b, a)
		var d := tri[3 * u + (f + 2) % 3]
		var n_bc := adj[3 * k + (e + 1) % 3]
		var n_ca := adj[3 * k + (e + 2) % 3]
		var n_ad := adj[3 * u + (f + 1) % 3]
		var n_db := adj[3 * u + (f + 2) % 3]
		tri[3 * k] = c
		tri[3 * k + 1] = a
		tri[3 * k + 2] = d
		adj[3 * k] = n_ca
		adj[3 * k + 1] = n_ad
		adj[3 * k + 2] = u
		tri[3 * u] = d
		tri[3 * u + 1] = b
		tri[3 * u + 2] = c
		adj[3 * u] = n_db
		adj[3 * u + 1] = n_bc
		adj[3 * u + 2] = k
		if n_ad >= 0:
			adj[3 * n_ad + edge_of(n_ad, d, a)] = k
		if n_bc >= 0:
			adj[3 * n_bc + edge_of(n_bc, c, b)] = u
		vt[a] = k
		vt[c] = k
		vt[d] = u
		vt[b] = u

	func crosses(a: int, b: int, c: int, d: int) -> bool:
		var o1 := orient(a, b, c)
		var o2 := orient(a, b, d)
		var o3 := orient(c, d, a)
		var o4 := orient(c, d, b)
		return ((o1 > 0.0 and o2 < 0.0) or (o1 < 0.0 and o2 > 0.0)) and ((o3 > 0.0 and o4 < 0.0) or (o3 < 0.0 and o4 > 0.0))

	func between(a: int, b: int, c: int) -> bool:
		var pa := pts[a]
		var pb := pts[b]
		var pc := pts[c]
		return (pc - pa).dot(pb - pa) > 0.0 and (pc - pb).dot(pa - pb) > 0.0

	## Восстановить ребро a-b переворотами пересекающих его рёбер.
	@warning_ignore("integer_division")
	func recover(a: int, b: int) -> bool:
		var t0 := vt[a]
		if t0 < 0 or vt[b] < 0:
			return false
		var k := t0
		var cur := -1
		var u := -1
		var v := -1
		for g in 4096:
			var j := vidx(k, a)
			var v1 := tri[3 * k + (j + 1) % 3]
			var v2 := tri[3 * k + (j + 2) % 3]
			var o1 := orient(a, b, v1)
			var o2 := orient(a, b, v2)
			if (o1 == 0.0 and between(a, b, v1)) or (o2 == 0.0 and between(a, b, v2)):
				return false
			if o1 < 0.0 and o2 > 0.0:
				cur = k
				u = v1
				v = v2
				break
			k = adj[3 * k + (j + 2) % 3]
			if k < 0 or k == t0:
				return false
		if cur < 0:
			return false
		var queue := PackedInt32Array()
		for g in 100000:
			queue.append(u)
			queue.append(v)
			var e := edge_of(cur, u, v)
			if e < 0:
				return false
			var nb := adj[3 * cur + e]
			if nb < 0:
				return false
			var f := edge_of(nb, v, u)
			var w := tri[3 * nb + (f + 2) % 3]
			if w == b:
				break
			var ow := orient(a, b, w)
			if ow == 0.0:
				return false
			if ow < 0.0:
				u = w
			else:
				v = w
			cur = nb
		var fresh := PackedInt32Array()
		var qh := 0
		var limit := 64 * queue.size() + 1000
		var guard := 0
		while qh < queue.size():
			guard += 1
			if guard > limit:
				return false
			var x := queue[qh]
			var y := queue[qh + 1]
			qh += 2
			var fe := find_edge(x, y)
			if fe < 0:
				continue
			var tk := fe / 3
			var te := fe % 3
			var a0 := tri[fe]
			var b0 := tri[3 * tk + (te + 1) % 3]
			var c0 := tri[3 * tk + (te + 2) % 3]
			var nb := adj[fe]
			if nb < 0:
				continue
			var d0 := tri[3 * nb + (edge_of(nb, b0, a0) + 2) % 3]
			var s1 := orient(c0, d0, a0)
			var s2 := orient(c0, d0, b0)
			if not ((s1 > 0.0 and s2 < 0.0) or (s1 < 0.0 and s2 > 0.0)):
				queue.append(x)
				queue.append(y)
				continue
			flip(tk, te)
			if c0 != a and c0 != b and d0 != a and d0 != b and crosses(a, b, c0, d0):
				queue.append(c0)
				queue.append(d0)
			else:
				fresh.append(c0)
				fresh.append(d0)
		lawson(fresh)
		return true

	## Вернуть свойство Делоне переворотами (рёбра контуров не трогаем).
	@warning_ignore("integer_division")
	func lawson(stack: PackedInt32Array) -> void:
		var guard := 0
		while stack.size() >= 2 and guard < 50000:
			guard += 1
			var sz := stack.size()
			var x := stack[sz - 2]
			var y := stack[sz - 1]
			stack.resize(sz - 2)
			if x >= m or y >= m or cons.has(key(x, y)):
				continue
			var fe := find_edge(x, y)
			if fe < 0:
				continue
			var tk := fe / 3
			var te := fe % 3
			var a0 := tri[fe]
			var b0 := tri[3 * tk + (te + 1) % 3]
			var c0 := tri[3 * tk + (te + 2) % 3]
			var nb := adj[fe]
			if nb < 0:
				continue
			var d0 := tri[3 * nb + (edge_of(nb, b0, a0) + 2) % 3]
			if incircle(a0, b0, c0, d0) <= 1e-9:
				continue
			var s1 := orient(c0, d0, a0)
			var s2 := orient(c0, d0, b0)
			if not ((s1 > 0.0 and s2 < 0.0) or (s1 < 0.0 and s2 > 0.0)):
				continue
			flip(tk, te)
			stack.append_array(PackedInt32Array([c0, a0, a0, d0, d0, b0, b0, c0]))

	## Внутренние треугольники: заливка от рамки, переход через ребро контура меняет чётность.
	@warning_ignore("integer_division")
	func classify(nreal: int) -> PackedInt32Array:
		var tc := tri.size() / 3
		var depth := PackedInt32Array()
		depth.resize(tc)
		depth.fill(-1)
		var cur := PackedInt32Array()
		for k in tc:
			if tri[3 * k] >= nreal or tri[3 * k + 1] >= nreal or tri[3 * k + 2] >= nreal:
				depth[k] = 0
				cur.append(k)
		var level := 0
		while not cur.is_empty():
			var later := PackedInt32Array()
			var qi := 0
			while qi < cur.size():
				var k := cur[qi]
				qi += 1
				for j in 3:
					var nb := adj[3 * k + j]
					if nb < 0 or depth[nb] >= 0:
						continue
					if cons.has(key(tri[3 * k + j], tri[3 * k + (j + 1) % 3])):
						later.append(nb)
					else:
						depth[nb] = level
						cur.append(nb)
			level += 1
			cur = PackedInt32Array()
			for k in later:
				if depth[k] < 0:
					depth[k] = level
					cur.append(k)
		var out := PackedInt32Array()
		for k in tc:
			if depth[k] % 2 != 1:
				continue
			var a := tri[3 * k]
			var b := tri[3 * k + 1]
			var c := tri[3 * k + 2]
			if a >= nreal or b >= nreal or c >= nreal or orient(a, b, c) <= 0.0:
				continue
			out.append(a)
			out.append(b)
			out.append(c)
		return out


class SegHash:
	## Отрезки контуров в корзинах сетки: расстояние до границы и поиск пересечений.
	var ax := PackedFloat64Array()
	var ay := PackedFloat64Array()
	var bx := PackedFloat64Array()
	var by := PackedFloat64Array()
	var loop_id := PackedInt32Array()
	var loop_pos := PackedInt32Array()
	var loop_len := PackedInt32Array()
	var cell := 1.0
	var ox := 0.0
	var oy := 0.0
	var nx := 1
	var ny := 1
	var head := PackedInt32Array()
	var link := PackedInt32Array()
	var item := PackedInt32Array()

	func _init(loops: Array[PackedVector2Array], cell_size: float) -> void:
		var bb := RbMeshGen._bbox(loops)
		cell = maxf(cell_size, 1e-3)
		var dim := maxf(bb.size.x, bb.size.y)
		if dim / cell > 512.0:
			cell = dim / 512.0
		ox = bb.position.x - cell
		oy = bb.position.y - cell
		nx = int(bb.size.x / cell) + 3
		ny = int(bb.size.y / cell) + 3
		head.resize(nx * ny)
		head.fill(-1)
		for li in loops.size():
			var lp := loops[li]
			var n := lp.size()
			loop_len.append(n)
			for i in n:
				var a := lp[i]
				var b := lp[(i + 1) % n]
				var sid := ax.size()
				ax.append(a.x)
				ay.append(a.y)
				bx.append(b.x)
				by.append(b.y)
				loop_id.append(li)
				loop_pos.append(i)
				var x0 := clampi(int((minf(a.x, b.x) - ox) / cell), 0, nx - 1)
				var x1 := clampi(int((maxf(a.x, b.x) - ox) / cell), 0, nx - 1)
				var y0 := clampi(int((minf(a.y, b.y) - oy) / cell), 0, ny - 1)
				var y1 := clampi(int((maxf(a.y, b.y) - oy) / cell), 0, ny - 1)
				for gy in range(y0, y1 + 1):
					for gx in range(x0, x1 + 1):
						var bk := gy * nx + gx
						item.append(sid)
						link.append(head[bk])
						head[bk] = item.size() - 1

	## Квадрат расстояния до ближайшего отрезка (ищет только в соседних корзинах, дальше cell = INF).
	func dist2(x: float, y: float) -> float:
		var gx := int((x - ox) / cell)
		var gy := int((y - oy) / cell)
		var best := INF
		for yy in range(maxi(gy - 1, 0), mini(gy + 2, ny)):
			for xx in range(maxi(gx - 1, 0), mini(gx + 2, nx)):
				var it := head[yy * nx + xx]
				while it >= 0:
					var sid := item[it]
					it = link[it]
					var d := RbMeshGen._seg_dist2(x, y, ax[sid], ay[sid], bx[sid], by[sid])
					if d < best:
						best = d
		return best

	## Номера контуров, которые пересекают себя или другие.
	func crossing_loops() -> PackedInt32Array:
		var flags := PackedByteArray()
		flags.resize(loop_len.size())
		flags.fill(0)
		var lst := PackedInt32Array()
		for bk in head.size():
			lst.clear()
			var it := head[bk]
			while it >= 0:
				lst.append(item[it])
				it = link[it]
			for i in lst.size():
				var s1 := lst[i]
				for j in range(i + 1, lst.size()):
					var s2 := lst[j]
					var l1 := loop_id[s1]
					var l2 := loop_id[s2]
					if l1 == l2:
						var d := absi(loop_pos[s1] - loop_pos[s2])
						if d == 0 or d == 1 or d == loop_len[l1] - 1:
							continue
					if RbMeshGen._seg_cross(ax[s1], ay[s1], bx[s1], by[s1], ax[s2], ay[s2], bx[s2], by[s2]):
						flags[l1] = 1
						flags[l2] = 1
		var out := PackedInt32Array()
		for i in flags.size():
			if flags[i] == 1:
				out.append(i)
		return out


# ---------------------------------------------------------------- геометрия

static func _orient(ax: float, ay: float, bx: float, by: float, cx: float, cy: float) -> float:
	return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


static func _cross3(a: Vector2, b: Vector2, c: Vector2) -> float:
	return _orient(a.x, a.y, b.x, b.y, c.x, c.y)


## Отрезки пересекаются или касаются.
static func _seg_cross(ax: float, ay: float, bx: float, by: float, cx: float, cy: float, dx: float, dy: float) -> bool:
	if maxf(ax, bx) < minf(cx, dx) or maxf(cx, dx) < minf(ax, bx) or maxf(ay, by) < minf(cy, dy) or maxf(cy, dy) < minf(ay, by):
		return false
	var d1 := _orient(cx, cy, dx, dy, ax, ay)
	var d2 := _orient(cx, cy, dx, dy, bx, by)
	if (d1 > 0.0 and d2 > 0.0) or (d1 < 0.0 and d2 < 0.0):
		return false
	var d3 := _orient(ax, ay, bx, by, cx, cy)
	var d4 := _orient(ax, ay, bx, by, dx, dy)
	if (d3 > 0.0 and d4 > 0.0) or (d3 < 0.0 and d4 < 0.0):
		return false
	return true


static func _seg_dist2(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
	var dx := bx - ax
	var dy := by - ay
	var l2 := dx * dx + dy * dy
	var t := 0.0
	if l2 > 0.0:
		t = clampf(((px - ax) * dx + (py - ay) * dy) / l2, 0.0, 1.0)
	var qx := ax + t * dx - px
	var qy := ay + t * dy - py
	return qx * qx + qy * qy


static func _area(pts: PackedVector2Array) -> float:
	var s := 0.0
	var n := pts.size()
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		s += float(a.x) * b.y - float(b.x) * a.y
	return s * 0.5


static func _loop_area(verts: PackedVector2Array, lp: PackedInt32Array) -> float:
	var s := 0.0
	var n := lp.size()
	for i in n:
		var a := verts[lp[i]]
		var b := verts[lp[(i + 1) % n]]
		s += float(a.x) * b.y - float(b.x) * a.y
	return s * 0.5


static func _perimeter(loops: Array[PackedVector2Array]) -> float:
	var s := 0.0
	for lp in loops:
		for i in lp.size():
			s += lp[i].distance_to(lp[(i + 1) % lp.size()])
	return s


static func _bbox(loops: Array) -> Rect2:
	var bb := Rect2()
	var first := true
	for lp: PackedVector2Array in loops:
		for q in lp:
			if first:
				bb = Rect2(q, Vector2.ZERO)
				first = false
			else:
				bb = bb.expand(q)
	return bb


static func _bary(a: Vector2, b: Vector2, c: Vector2, p: Vector2) -> Vector3:
	var d := _cross3(a, b, c)
	if absf(d) < 1e-12:
		return Vector3(-1, -1, -1)
	var u := _cross3(p, b, c) / d
	var v := _cross3(a, p, c) / d
	return Vector3(u, v, 1.0 - u - v)


static func _polys(verts: PackedVector2Array, loops: Array[PackedInt32Array]) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for lp in loops:
		var poly := PackedVector2Array()
		for i in lp:
			poly.append(verts[i])
		out.append(poly)
	return out


## Внутри области: нечётное число контуров вокруг точки.
static func _inside(polys: Array[PackedVector2Array], p: Vector2) -> bool:
	var c := 0
	for poly in polys:
		if Geometry2D.is_point_in_polygon(p, poly):
			c += 1
	return c % 2 == 1


static func _inside_strict(polys: Array[PackedVector2Array], p: Vector2) -> bool:
	if not _inside(polys, p):
		return false
	for poly in polys:
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			if _seg_dist2(p.x, p.y, a.x, a.y, b.x, b.y) < 1e-6:
				return false
	return true


## Все вершины не на контурах (кроме skip) строго внутри области.
static func _interior_inside(verts: PackedVector2Array, loops: Array[PackedInt32Array], skip: int) -> bool:
	var on_loop := PackedByteArray()
	on_loop.resize(verts.size())
	on_loop.fill(0)
	for lp in loops:
		for i in lp:
			on_loop[i] = 1
	var polys := _polys(verts, loops)
	for v in verts.size():
		if v != skip and on_loop[v] == 0 and not _inside_strict(polys, verts[v]):
			return false
	return true


## Отрезок a-b задевает какое-нибудь ребро контуров (кроме рёбер с концами a или b).
static func _segment_hits_loops(verts: PackedVector2Array, loops: Array[PackedInt32Array], a: int, b: int) -> bool:
	var pa := verts[a]
	var pb := verts[b]
	for lp in loops:
		var n := lp.size()
		for i in n:
			var c := lp[i]
			var d := lp[(i + 1) % n]
			if c == a or c == b or d == a or d == b:
				continue
			var pc := verts[c]
			var pd := verts[d]
			if _seg_cross(pa.x, pa.y, pb.x, pb.y, pc.x, pc.y, pd.x, pd.y):
				return true
	return false


# ---------------------------------------------------------------- сборка словаря

static func _make(verts: PackedVector2Array, tris: PackedInt32Array, loops: Array[PackedInt32Array], size: Vector2) -> Dictionary:
	var uvs := PackedVector2Array()
	uvs.resize(verts.size())
	var inv := Vector2(1.0 / size.x if size.x != 0.0 else 0.0, 1.0 / size.y if size.y != 0.0 else 0.0)
	for i in verts.size():
		uvs[i] = verts[i] * inv + Vector2(0.5, 0.5)
	var boundary := PackedInt32Array()
	var lcopy: Array[PackedInt32Array] = []
	for lp in loops:
		boundary.append_array(lp)
		lcopy.append(lp.duplicate())
	return {"vertices": verts, "uvs": uvs, "indices": tris, "boundary": boundary, "loops": lcopy, "size": size}


static func _rebuild(mesh: Dictionary, verts: PackedVector2Array, loops: Array[PackedInt32Array]) -> Dictionary:
	var tris := _cdt(verts, loops)
	if tris.is_empty():
		return {}
	var used := PackedByteArray()
	used.resize(verts.size())
	used.fill(0)
	for i in tris:
		used[i] = 1
	if used.count(0) > 0:
		return {}
	return _make(verts, tris, loops, mesh.get("size", Vector2.ONE))


## Контуры сетки (копия). Если в словаре их нет: собрать по рёбрам, у которых один треугольник.
static func _loops_of(mesh: Dictionary) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	var stored: Array = mesh.get("loops", [])
	if not stored.is_empty():
		for e in stored:
			out.append(PackedInt32Array(e))
		return out
	var verts: PackedVector2Array = mesh.get("vertices", PackedVector2Array())
	var tris: PackedInt32Array = mesh.get("indices", PackedInt32Array())
	var m := verts.size()
	var count := {}
	for k in range(0, tris.size(), 3):
		for e in 3:
			var a := tris[k + e]
			var b := tris[k + (e + 1) % 3]
			var kk := mini(a, b) * m + maxi(a, b)
			count[kk] = int(count.get(kk, 0)) + 1
	var nxt := {}
	for k in range(0, tris.size(), 3):
		for e in 3:
			var a := tris[k + e]
			var b := tris[k + (e + 1) % 3]
			if int(count[mini(a, b) * m + maxi(a, b)]) == 1:
				nxt[a] = b
	while not nxt.is_empty():
		var st: int = nxt.keys()[0]
		var lp := PackedInt32Array()
		var c := st
		while nxt.has(c):
			lp.append(c)
			var nc: int = nxt[c]
			nxt.erase(c)
			c = nc
		if lp.size() >= 3:
			out.append(lp)
	return out
