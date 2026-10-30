class_name RbBenchmark
extends Node2D
## Бенчмарк фазы 0: бюджет из ТЗ (50 слоёв, сетки ~300 вершин), вершины гнутся каждый кадр на CPU,
## как будет при скиннинге. Меряет FPS и время CPU на обновление сеток.

signal finished(result: Dictionary)

const LAYERS := 50
const GRID := Vector2i(15, 20)  # 300 вершин
const DURATION := 6.0
const WARMUP := 0.7

var area := Vector2(400, 700)
var _meshes: Array[ArrayMesh] = []
var _nodes: Array[MeshInstance2D] = []
var _base := PackedVector2Array()
var _uvs := PackedVector2Array()
var _idx := PackedInt32Array()
var _t := 0.0
var _frames := PackedFloat32Array()
var _cpu := PackedFloat32Array()
var _done := false


func _ready() -> void:
	var cell := Vector2(130.0 / (GRID.x - 1), 170.0 / (GRID.y - 1))
	for y in GRID.y:
		for x in GRID.x:
			_base.append(Vector2(x, y) * cell - Vector2(65, 85))
			_uvs.append(Vector2(float(x) / (GRID.x - 1), float(y) / (GRID.y - 1)))
	for y in GRID.y - 1:
		for x in GRID.x - 1:
			var i := y * GRID.x + x
			_idx.append_array([i, i + 1, i + GRID.x, i + 1, i + GRID.x + 1, i + GRID.x])
	var tex := ImageTexture.create_from_image(RbIcons.frog_image(256))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in LAYERS:
		var m := ArrayMesh.new()
		var n := MeshInstance2D.new()
		n.mesh = m
		n.texture = tex
		n.position = Vector2(rng.randf_range(60, area.x - 60), rng.randf_range(80, area.y - 80))
		add_child(n)
		_meshes.append(m)
		_nodes.append(n)


func _process(delta: float) -> void:
	if _done:
		return
	_t += delta
	var t0 := Time.get_ticks_usec()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = _idx
	for i in LAYERS:
		var v := _base.duplicate()
		var ph := _t * 3.0 + i * 0.37
		for j in v.size():
			var p := v[j]
			v[j] = p + Vector2(sin(ph + p.y * 0.04) * 10.0, cos(ph * 0.7 + p.x * 0.05) * 4.0)
		arrays[Mesh.ARRAY_VERTEX] = v
		_meshes[i].clear_surfaces()
		_meshes[i].add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_nodes[i].rotation = sin(_t + i) * 0.25
	if _t > WARMUP:
		_cpu.append((Time.get_ticks_usec() - t0) / 1000.0)
		_frames.append(delta)
	if _t >= DURATION:
		_done = true
		finished.emit(_result())


func _result() -> Dictionary:
	var sorted := Array(_frames)
	sorted.sort()
	var total := 0.0
	for f in _frames:
		total += f
	var cpu_total := 0.0
	for c in _cpu:
		cpu_total += c
	var n := maxi(1, _frames.size())
	var p99: float = sorted[clampi(int(n * 0.99), 0, n - 1)] if n > 0 else 0.0
	return {
		"fps": n / maxf(total, 0.001),
		"low1": 1.0 / maxf(p99, 0.0001),
		"worst_ms": (sorted.back() if not sorted.is_empty() else 0.0) * 1000.0,
		"cpu_ms": cpu_total / n,
		"refresh": DisplayServer.screen_get_refresh_rate(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"layers": LAYERS,
		"verts": LAYERS * _base.size(),
	}
