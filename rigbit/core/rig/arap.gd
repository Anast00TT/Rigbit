class_name RbArap
extends RefCounted
## As-rigid-as-possible деформация сетки пинами (как Puppet Warp).
## Пины = мягкие позиционные ограничения с большим весом: матрица системы зависит только от
## сетки и набора закреплённых вершин, поэтому факторизуется один раз (prepare), а на кадр
## остаются прогоны (solve). Матрица разреженная: перенумерация Cuthill-McKee + ленточный Холецкий.

const PIN_WEIGHT := 1.0e4

var n := 0
var rest := PackedVector2Array()
var neighbors: Array = []  # i -> PackedInt32Array соседей
var pinned := PackedInt32Array()
var _perm := PackedInt32Array()  # новый индекс -> старый
var _inv := PackedInt32Array()  # старый -> новый
var _bw := 0  # полуширина ленты
var _L := PackedFloat64Array()  # ленточный множитель Холецкого, n x (bw+1)
var _cur := PackedVector2Array()  # последнее решение (тёплый старт)


## Подготовка: сетка (rest-вершины, треугольники) и индексы закреплённых вершин.
func prepare(vertices: PackedVector2Array, indices: PackedInt32Array, pinned_vertices: PackedInt32Array) -> void:
	n = vertices.size()
	rest = vertices
	pinned = pinned_vertices
	_cur = vertices.duplicate()
	var sets: Array = []
	for i in n:
		sets.append({})
	for t in range(0, indices.size() - 2, 3):
		for e in [[0, 1], [1, 2], [2, 0]]:
			var a := indices[t + e[0]]
			var b := indices[t + e[1]]
			sets[a][b] = true
			sets[b][a] = true
	neighbors.clear()
	for i in n:
		neighbors.append(PackedInt32Array(sets[i].keys()))
	_order()
	_factor()


## Перенумерация Cuthill-McKee (обратная): сужает ленту матрицы.
func _order() -> void:
	var visited := PackedByteArray()
	visited.resize(n)
	var order := PackedInt32Array()
	while order.size() < n:
		var start := -1
		var best := 1 << 30
		for i in n:
			if not visited[i] and (neighbors[i] as PackedInt32Array).size() < best:
				best = (neighbors[i] as PackedInt32Array).size()
				start = i
		var queue := [start]
		visited[start] = 1
		while not queue.is_empty():
			var v: int = queue.pop_front()
			order.append(v)
			var nb := Array(neighbors[v] as PackedInt32Array)
			nb.sort_custom(func(a: int, b: int) -> bool: return (neighbors[a] as PackedInt32Array).size() < (neighbors[b] as PackedInt32Array).size())
			for u in nb:
				if not visited[u]:
					visited[u] = 1
					queue.append(u)
	order.reverse()
	_perm = order
	_inv.resize(n)
	for k in n:
		_inv[_perm[k]] = k
	_bw = 0
	for i in n:
		for j in neighbors[i]:
			_bw = maxi(_bw, absi(_inv[i] - _inv[j]))


## Матрица: лапласиан графа (вес 1 на ребро) + PIN_WEIGHT на диагонали закреплённых.
func _factor() -> void:
	var w := _bw + 1
	_L = PackedFloat64Array()
	_L.resize(n * w)
	# A в ленточном виде: A[r][c] (c<=r, r-c<=bw) хранится в _L[r*w + (r-c)]
	var pin_set := {}
	for p in pinned:
		pin_set[p] = true
	for i in n:
		var r := _inv[i]
		var deg := float((neighbors[i] as PackedInt32Array).size())
		_L[r * w] = deg + (PIN_WEIGHT if pin_set.has(i) else 0.0) + 1e-9
		for j in neighbors[i]:
			var c := _inv[j]
			if c < r:
				_L[r * w + (r - c)] = -1.0
	# ленточный Холецкий: A = L·Lᵀ
	for r in n:
		for c in range(maxi(0, r - _bw), r + 1):
			var s := _L[r * w + (r - c)]
			for k in range(maxi(0, maxi(r, c) - _bw), c):
				s -= _L[r * w + (r - k)] * _L[c * w + (c - k)]
			if r == c:
				_L[r * w] = sqrt(maxf(s, 1e-12))
			else:
				_L[r * w + (r - c)] = s / _L[c * w]


func _solve_axis(b: PackedFloat64Array) -> PackedFloat64Array:
	var w := _bw + 1
	var y := PackedFloat64Array()
	y.resize(n)
	for r in n:
		var s := b[r]
		for k in range(maxi(0, r - _bw), r):
			s -= _L[r * w + (r - k)] * y[k]
		y[r] = s / _L[r * w]
	var x := PackedFloat64Array()
	x.resize(n)
	for r in range(n - 1, -1, -1):
		var s := y[r]
		for k in range(r + 1, mini(n, r + _bw + 1)):
			s -= _L[k * w + (k - r)] * x[k]
		x[r] = s / _L[r * w]
	return x


## Решить для текущих положений пинов (targets: те же индексы, что pinned).
## start: начальное приближение (обычно вершины после скиннинга); пусто = прошлое решение.
func solve(targets: PackedVector2Array, start := PackedVector2Array(), iterations := 3) -> PackedVector2Array:
	if n == 0:
		return PackedVector2Array()
	var cur := start.duplicate() if start.size() == n else _cur
	var rot := PackedVector2Array()  # (cos, sin) поворота каждой вершины
	rot.resize(n)
	for _it in iterations:
		# локальный шаг: лучший поворот каждой вершины
		for i in n:
			var sc := 0.0
			var ss := 0.0
			for j in neighbors[i]:
				var e := rest[i] - rest[j]
				var e2 := cur[i] - cur[j]
				sc += e.dot(e2)
				ss += e.cross(e2)
			var l := sqrt(sc * sc + ss * ss)
			rot[i] = Vector2(sc / l, ss / l) if l > 1e-9 else Vector2(1, 0)
		# глобальный шаг: L p' = Σ ½(Ri+Rj)(pi-pj) + λ·цель
		var bx := PackedFloat64Array()
		var by := PackedFloat64Array()
		bx.resize(n)
		by.resize(n)
		for i in n:
			var acc := Vector2.ZERO
			for j in neighbors[i]:
				var e := rest[i] - rest[j]
				var ri: Vector2 = rot[i]
				var rj: Vector2 = rot[j]
				var c := (ri.x + rj.x) * 0.5
				var s := (ri.y + rj.y) * 0.5
				acc += Vector2(c * e.x - s * e.y, s * e.x + c * e.y)
			var r := _inv[i]
			bx[r] = acc.x
			by[r] = acc.y
		for k in pinned.size():
			var r2 := _inv[pinned[k]]
			bx[r2] += PIN_WEIGHT * targets[k].x
			by[r2] += PIN_WEIGHT * targets[k].y
		var x := _solve_axis(bx)
		var y := _solve_axis(by)
		for i in n:
			cur[i] = Vector2(x[_inv[i]], y[_inv[i]])
	_cur = cur
	return cur


func band_width() -> int:
	return _bw
