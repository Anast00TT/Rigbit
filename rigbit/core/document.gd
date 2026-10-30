class_name RbDocument
extends RefCounted
## Модель проекта: холст, слои, картинки. Ядро, без UI.
## Любое изменение идёт через команды (RbUndoStack), после изменения шлётся changed.

signal changed(what: StringName)

const FORMAT_VERSION := 1
const MAX_LAYER_SIDE := 4096
const TEXTURE_BUDGET_BYTES := 512 * 1024 * 1024

var canvas_size := Vector2i(1080, 1920)
var fps: int = 24
var frame_count: int = 48
var background := Color(1, 1, 1, 1)

var layers: Dictionary = {}  # id -> RbLayer
var rig := RbRig.new()
var anim := RbAnimation.new()
var params := RbParams.new()
var current_frame: int = 0  # текущий кадр (значения дорожек записаны в объекты)
## Режим Риг показывает кадр 0 (базовая поза, как setup-кадр в Moho), анимация — текущий.
var rig_mode := false


func shown_frame() -> int:
	return 0 if rig_mode else current_frame
var root: Array[int] = []  # корневые слои, снизу вверх
var images: Dictionary = {}  # image_id -> Image
var png_cache: Dictionary = {}  # image_id -> [Image, PackedByteArray], чтобы автосохранение не кодировало заново
## Исходный векторный текст картинки (части персонажа из SVG): image_id -> String.
## Растр в images остаётся главным; по SVG картинку можно перерастрировать в любом размере.
var svgs: Dictionary = {}
var _next_id: int = 1


func new_id() -> int:
	var i := _next_id
	_next_id += 1
	return i


func get_layer(id: int) -> RbLayer:
	return layers.get(id)


func sibling_list(parent_id: int) -> Array[int]:
	if parent_id == 0:
		return root
	var p := get_layer(parent_id)
	return p.children if p else root


## Вставить слой (уже с id) в родителя на позицию index (-1 = наверх).
func insert_layer(layer: RbLayer, index: int = -1) -> void:
	layers[layer.id] = layer
	_next_id = maxi(_next_id, layer.id + 1)
	var list := sibling_list(layer.parent_id)
	if index < 0 or index > list.size():
		list.append(layer.id)
	else:
		list.insert(index, layer.id)
	changed.emit(&"layers")


## Убрать слой (и детей) из документа. Возвращает позицию, где он был.
func detach_layer(id: int) -> int:
	var l := get_layer(id)
	if l == null:
		return -1
	var list := sibling_list(l.parent_id)
	var idx := list.find(id)
	if idx >= 0:
		list.remove_at(idx)
	_erase_recursive(id)
	changed.emit(&"layers")
	return idx


## Переставить слой (без удаления). Возвращает [старый родитель, старый индекс].
func move_layer(id: int, new_parent: int, index: int) -> Array:
	var l := get_layer(id)
	if l == null:
		return [0, -1]
	var old_list := sibling_list(l.parent_id)
	var old_index := old_list.find(id)
	var old_parent := l.parent_id
	old_list.remove_at(old_index)
	l.parent_id = new_parent
	var list := sibling_list(new_parent)
	if index < 0 or index > list.size():
		list.append(id)
	else:
		list.insert(index, id)
	changed.emit(&"layers")
	return [old_parent, old_index]


## Глубина вложенности и путь до корня (для дерева слоёв).
func depth_of(id: int) -> int:
	var d := 0
	var l := get_layer(id)
	while l and l.parent_id != 0:
		d += 1
		l = get_layer(l.parent_id)
	return d


func _erase_recursive(id: int) -> void:
	var l := get_layer(id)
	if l == null:
		return
	for c in l.children:
		_erase_recursive(c)
	layers.erase(id)


## Все слои в порядке отрисовки (снизу вверх), группы раскрыты.
func draw_order() -> Array[RbLayer]:
	var out: Array[RbLayer] = []
	_collect(root, out)
	return out


func _collect(ids: Array[int], out: Array[RbLayer]) -> void:
	for id in ids:
		var l := get_layer(id)
		if l == null:
			continue
		out.append(l)
		if l.is_group():
			_collect(l.children, out)


func texture_bytes() -> int:
	var total := 0
	for img: Image in images.values():
		total += img.get_width() * img.get_height() * 4
	return total


func notify(what: StringName) -> void:
	changed.emit(what)


func to_dict() -> Dictionary:
	var ls: Array = []
	for l in draw_order():
		ls.append(l.to_dict())
	return {
		"format_version": FORMAT_VERSION,
		"app": "Rigbit",
		"canvas": {"width": canvas_size.x, "height": canvas_size.y, "fps": fps, "frames": frame_count,
			"background": background.to_html(true)},
		"root": Array(root),
		"layers": ls,
		"rig": rig.to_dict(),
		"anim": anim.to_dict(),
		"params": params.to_dict(),
		"next_id": _next_id,
	}


static func from_dict(d: Dictionary) -> RbDocument:
	var doc := RbDocument.new()
	var c: Dictionary = d.get("canvas", {})
	doc.canvas_size = Vector2i(int(c.get("width", 1080)), int(c.get("height", 1920)))
	doc.fps = int(c.get("fps", 24))
	doc.frame_count = int(c.get("frames", 48))
	doc.background = Color.html(str(c.get("background", "ffffffff")))
	for ld in d.get("layers", []):
		var l := RbLayer.from_dict(ld)
		doc.layers[l.id] = l
	for id in d.get("root", []):
		doc.root.append(int(id))
	doc.rig = RbRig.from_dict(d.get("rig", {}))
	doc.params = RbParams.from_dict(d.get("params", {}))
	for id in doc.params.params:
		doc._next_id = maxi(doc._next_id, int(id) + 1)
	doc.anim = RbAnimation.from_dict(d.get("anim", {}))
	doc.anim.apply_frame(doc, 0)
	doc._next_id = int(d.get("next_id", 1))
	for id in doc.rig.bones:
		doc._next_id = maxi(doc._next_id, int(id) + 1)
	for id in doc.layers:
		doc._next_id = maxi(doc._next_id, int(id) + 1)
	return doc
