class_name RbOnionRenderer
extends Node2D
## Призраки онион скина. Узел живёт внутри RbRenderer первым ребёнком: рисуется поверх фона холста,
## но под слоями текущего кадра. Меши берутся из поз соседних кадров (RbEvaluator.pose_at),
## текстуры общие с основным рендерером, цвет и прозрачность из RbOnion.tint.

const SHADER := preload("res://render/onion.gdshader")

var _pool: Array[MeshInstance2D] = []
var _sig: Array[int] = []
var _mats := {}  # цвет html -> ShaderMaterial


## ghosts: [[RbEvaluator.Pose, Color]], дальние первыми. textures: Callable(image_id) -> Texture2D.
func show_ghosts(doc: RbDocument, ghosts: Array, textures: Callable) -> void:
	var used := 0
	for g in ghosts:
		var pose: RbEvaluator.Pose = g[0]
		var col: Color = g[1]
		for id in pose.order:
			var lp: RbEvaluator.LayerPose = pose.layers[id]
			var l := doc.get_layer(id)
			if l == null or not lp.visible or lp.opacity <= 0.01 or lp.vertices.is_empty():
				continue
			var n := _slot(used)
			var sig := hash(lp.vertices) ^ hash(l.mesh_indices)
			if _sig[used] != sig:
				n.mesh = RbRenderer.build_mesh(lp.vertices, l.mesh_uvs, l.mesh_indices)
				_sig[used] = sig
			n.texture = textures.call(l.image_id)
			n.transform = lp.world
			n.material = _mat(Color(col.r, col.g, col.b, col.a * lp.opacity))
			n.visible = true
			used += 1
	for i in range(used, _pool.size()):
		_pool[i].visible = false


func clear() -> void:
	for n in _pool:
		n.visible = false


func _slot(i: int) -> MeshInstance2D:
	while _pool.size() <= i:
		var n := MeshInstance2D.new()
		n.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		add_child(n)
		_pool.append(n)
		_sig.append(-1)
	return _pool[i]


func _mat(c: Color) -> ShaderMaterial:
	var key := c.to_html(true)
	var m: ShaderMaterial = _mats.get(key)
	if m == null:
		m = ShaderMaterial.new()
		m.shader = SHADER
		m.set_shader_parameter("tint", c)
		_mats[key] = m
	return m

