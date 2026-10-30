class_name RbRenderer
extends Node2D
## Рисует позу документа. Каждый растровый слой = MeshInstance2D с текстурированной сеткой.
## Текстура загружается на GPU один раз и живёт, пока жива картинка в документе.

var doc: RbDocument
var _nodes := {}  # layer id -> MeshInstance2D
var _mesh_sig := {}  # layer id -> хеш вершин
var _tex := {}  # image_id -> [Image, ImageTexture]
var _blend_mats := {}
## Призраки онион скина (только вьюпорт редактора): первым ребёнком, между фоном холста и слоями.
var onion: RbOnionRenderer


func enable_onion() -> RbOnionRenderer:
	if onion == null:
		onion = RbOnionRenderer.new()
		add_child(onion)
		move_child(onion, 0)
	return onion


func texture_for(image_id: String) -> Texture2D:
	return _texture_for(image_id)


func sync(d: RbDocument, pose: RbEvaluator.Pose) -> void:
	doc = d
	queue_redraw()
	var alive := {}
	var base := 0
	if onion:
		move_child(onion, 0)
		base = 1
	for i in pose.order.size():
		var id: int = pose.order[i]
		var l := doc.get_layer(id)
		var lp: RbEvaluator.LayerPose = pose.layers[id]
		var n: MeshInstance2D = _nodes.get(id)
		if n == null:
			n = MeshInstance2D.new()
			n.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			add_child(n)
			_nodes[id] = n
		n.texture = _texture_for(l.image_id)
		var sig := hash(lp.vertices) ^ hash(l.mesh_indices)
		if _mesh_sig.get(id, -1) != sig:
			n.mesh = build_mesh(lp.vertices, l.mesh_uvs, l.mesh_indices)
			_mesh_sig[id] = sig
		n.transform = lp.world
		n.self_modulate = Color(1, 1, 1, lp.opacity)
		n.visible = lp.visible
		var ml := doc.get_layer(l.mask_id) if l.mask_id != 0 else null
		if ml and pose.layers.has(ml.id) and not ml.is_group():
			var mp: RbEvaluator.LayerPose = pose.layers[ml.id]
			n.visible = lp.visible and mp.visible  # спрятанная маска (другой вариант глаза) прячет и обрезаемое
			n.material = _mask_material(l, ml, lp.world, mp.world)
		elif not l.effects.is_empty():
			n.material = _fx_material(l, lp.world)
		else:
			n.material = _blend_material(l.blend_mode)
		move_child(n, i + base)
		alive[id] = true
	for id in _nodes.keys():
		if not alive.has(id):
			_nodes[id].queue_free()
			_nodes.erase(id)
			_mesh_sig.erase(id)
	for key in _tex.keys():
		if not doc.images.has(key):
			_tex.erase(key)


func clear() -> void:
	if onion:
		onion.clear()
	for n in _nodes.values():
		n.queue_free()
	_nodes.clear()
	_mesh_sig.clear()
	_tex.clear()


func _texture_for(image_id: String) -> Texture2D:
	var img: Image = doc.images.get(image_id)
	if img == null:
		return null
	var entry: Array = _tex.get(image_id, [])
	if entry.is_empty() or entry[0] != img:
		var gpu := img.duplicate()
		gpu.generate_mipmaps()
		entry = [img, ImageTexture.create_from_image(gpu)]
		_tex[image_id] = entry
	return entry[1]


static func build_mesh(v: PackedVector2Array, uv: PackedVector2Array, idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


const MASK_SHADER := preload("res://render/layer_mask.gdshader")
var _mask_mats := {}  # layer id -> ShaderMaterial


## Маска-обрезка (эффекты и режим наложения у обрезаемого слоя при этом не применяются).
func _mask_material(l: RbLayer, mask: RbLayer, world: Transform2D, mask_world: Transform2D) -> ShaderMaterial:
	var m: ShaderMaterial = _mask_mats.get(l.id)
	if m == null:
		m = ShaderMaterial.new()
		m.shader = MASK_SHADER
		_mask_mats[l.id] = m
	var x := mask_world.affine_inverse() * world
	m.set_shader_parameter("mask_tex", _texture_for(mask.image_id))
	m.set_shader_parameter("mask_x", x.x)
	m.set_shader_parameter("mask_y", x.y)
	m.set_shader_parameter("mask_o", x.origin)
	m.set_shader_parameter("mask_size", mask.size)
	return m


const FX_SHADER := preload("res://render/layer_fx.gdshader")
const BLENDS := {"add": 0, "screen": 1, "normal": 2, "multiply": 3}
var _fx_mats := {}  # layer id -> ShaderMaterial


## Материал эффектов слоя. Мировые углы света/градиента переводятся в оси слоя.
func _fx_material(l: RbLayer, world: Transform2D) -> ShaderMaterial:
	var m: ShaderMaterial = _fx_mats.get(l.id)
	if m == null:
		m = ShaderMaterial.new()
		m.shader = FX_SHADER
		_fx_mats[l.id] = m
	var rot := world.get_rotation()
	var flip := world.determinant() < 0.0
	var to_local := func(world_angle: float) -> Vector2:
		var v := Vector2.from_angle(world_angle - rot)
		return Vector2(-v.x, v.y) if flip else v
	var rim: Dictionary = l.effects.get("rim", {})
	m.set_shader_parameter("rim_on", not rim.is_empty())
	if not rim.is_empty():
		m.set_shader_parameter("rim_outside", bool(rim.get("outside", false)))
		m.set_shader_parameter("light_dir_local", to_local.call(float(rim.get("angle", -PI / 4))))
		m.set_shader_parameter("rim_distance", float(rim.get("distance", 8.0)))
		m.set_shader_parameter("rim_blur", float(rim.get("blur", 4.0)))
		m.set_shader_parameter("rim_hardness", float(rim.get("hardness", 0.35)))
		m.set_shader_parameter("rim_color", Color.html(str(rim.get("color", "fff2cc"))))
		m.set_shader_parameter("rim_opacity", float(rim.get("opacity", 0.75)))
		m.set_shader_parameter("rim_blend", int(BLENDS.get(str(rim.get("blend", "add")), 0)))
	var grad: Dictionary = l.effects.get("grad", {})
	m.set_shader_parameter("grad_on", not grad.is_empty())
	if not grad.is_empty():
		m.set_shader_parameter("grad_a", Color.html(str(grad.get("a", "ff99cc"))))
		m.set_shader_parameter("grad_b", Color.html(str(grad.get("b", "6699ff"))))
		m.set_shader_parameter("grad_dir_local", to_local.call(float(grad.get("angle", PI / 2))))
		m.set_shader_parameter("grad_amount", float(grad.get("amount", 0.3)))
		m.set_shader_parameter("grad_blend", int(BLENDS.get(str(grad.get("blend", "screen")), 1)))
	var cc: Dictionary = l.effects.get("cc", {})
	m.set_shader_parameter("cc_on", not cc.is_empty())
	if not cc.is_empty():
		m.set_shader_parameter("cc_hue", float(cc.get("hue", 0.0)))
		m.set_shader_parameter("cc_saturation", float(cc.get("saturation", 1.0)))
		m.set_shader_parameter("cc_brightness", float(cc.get("brightness", 0.0)))
		m.set_shader_parameter("cc_contrast", float(cc.get("contrast", 1.0)))
	return m


func _blend_material(mode: String) -> Material:
	if mode == "normal":
		return null
	if not _blend_mats.has(mode):
		var mat := CanvasItemMaterial.new()
		match mode:
			"add": mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			"multiply": mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
			_: mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX  # screen/overlay: шейдеры в фазе 7
		_blend_mats[mode] = mat
	return _blend_mats[mode]


func _draw() -> void:
	if doc == null or doc.root.is_empty():
		return  # пустой проект: вместо холста пунктир во вьюпорте
	var r := Rect2(Vector2.ZERO, Vector2(doc.canvas_size))
	var z: float = maxf(get_global_transform().get_scale().x, 0.0001)
	# мягкая тень: несколько полупрозрачных слоёв, толщина в экранных пикселях
	for i in range(5, 0, -1):
		draw_rect(Rect2(r.position + Vector2(0, 2.0 / z), r.size).grow(i * 2.0 / z), Color(0, 0, 0, 0.05))
	draw_rect(r, doc.background)
