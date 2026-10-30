class_name RbAddLayersCommand
extends RbCommand
## Много слоёв с картинками одним шагом истории (импорт PSD).
## Слои вставляются по порядку через insert_layer(layer, -1): родитель раньше детей.
## Если задан canvas_size, холст меняется вместе со слоями и возвращается при undo.

var layer_dicts: Array = []  # снимки слоёв, у групп children пустые
var images: Dictionary = {}  # image_id -> Image
var new_canvas := Vector2i.ZERO
var old_canvas := Vector2i.ZERO


func _init(layers: Array[RbLayer], imgs: Dictionary, canvas_size := Vector2i.ZERO, cmd_label := "Импорт PSD") -> void:
	label = cmd_label
	for l in layers:
		var d := l.to_dict()
		if l.is_group():
			d["children"] = []  # дети допишутся сами при вставке
		layer_dicts.append(d)
	images = imgs.duplicate()
	new_canvas = canvas_size


func do_it(doc: RbDocument) -> void:
	if new_canvas != Vector2i.ZERO:
		old_canvas = doc.canvas_size
		doc.canvas_size = new_canvas
		doc.notify(&"canvas")
	for k in images:
		doc.images[k] = images[k]
	for d: Dictionary in layer_dicts:
		doc.insert_layer(RbLayer.from_dict(d), -1)


func undo_it(doc: RbDocument) -> void:
	var ids := {}
	for d: Dictionary in layer_dicts:
		ids[int(d["id"])] = true
	# верхние слои пачки снимаем сверху вниз, детей detach_layer уберёт сам
	for i in range(layer_dicts.size() - 1, -1, -1):
		var d: Dictionary = layer_dicts[i]
		if not ids.has(int(d["parent"])):
			doc.detach_layer(int(d["id"]))
	for k in images:
		doc.images.erase(k)
		doc.png_cache.erase(k)
	if new_canvas != Vector2i.ZERO:
		doc.canvas_size = old_canvas
		doc.notify(&"canvas")


func cost_bytes() -> int:
	var total := 256
	for img: Image in images.values():
		total += img.get_data_size()
	return total
