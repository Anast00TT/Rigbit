class_name RbImporter
extends RefCounted
## Картинка -> слой. Без UI: предупреждения возвращаются строками-ключами локализации.


class Result:
	var layer: RbLayer
	var image: Image
	var warnings: Array[String] = []
	var error: String = ""


static func load_image(path: String) -> Image:
	var img := Image.new()
	if img.load(path) == OK:
		return img
	# content:// и прочие пути, которые Image.load не понимает
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var buf := f.get_buffer(f.get_length())
	f.close()
	img = Image.new()
	if img.load_png_from_buffer(buf) == OK or img.load_jpg_from_buffer(buf) == OK or img.load_webp_from_buffer(buf) == OK:
		return img
	return null


static func image_to_layer(doc: RbDocument, img: Image, layer_name: String) -> Result:
	var r := Result.new()
	if img == null or img.is_empty():
		r.error = "IMPORT_ERR_READ"
		return r
	img = img.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var side := maxi(img.get_width(), img.get_height())
	if side > RbDocument.MAX_LAYER_SIDE:
		var k := float(RbDocument.MAX_LAYER_SIDE) / side
		img.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)), Image.INTERPOLATE_LANCZOS)
		r.warnings.append("IMPORT_WARN_DOWNSCALED")
	var bytes := img.get_width() * img.get_height() * 4
	if doc.texture_bytes() + bytes > RbDocument.TEXTURE_BUDGET_BYTES:
		r.error = "IMPORT_ERR_BUDGET"
		return r
	var l := RbLayer.new()
	l.id = doc.new_id()
	l.name = layer_name
	l.kind = RbLayer.Kind.IMAGE
	l.image_id = "img%d" % l.id
	l.size = Vector2(img.get_width(), img.get_height())
	l.position = Vector2(doc.canvas_size) * 0.5
	# крупнее холста — вписать
	var fit := minf(doc.canvas_size.x / l.size.x, doc.canvas_size.y / l.size.y)
	if fit < 1.0:
		l.scale = Vector2.ONE * fit
	l.make_quad_mesh()
	r.layer = l
	r.image = img
	return r


## Результат RbPsdReader -> плоский список слоёв. Вставлять по порядку через insert_layer(layer, -1):
## родитель раньше детей, соседи снизу вверх, у групп children пустые (заполнятся при вставке).
## Позиция слоя = центр его рамки в координатах холста PSD (+ offset). Трансформы групп единичные.
## Вернёт { layers: Array[RbLayer], images: image_id -> Image, warnings, error, canvas_size: Vector2i }.
static func psd_to_layers(doc: RbDocument, psd: Dictionary, offset := Vector2.ZERO) -> Dictionary:
	var layers: Array[RbLayer] = []
	var warnings: Array[String] = []
	var out := {
		"layers": layers, "images": {}, "warnings": warnings, "error": "",
		"canvas_size": Vector2i(int(psd.get("width", 0)), int(psd.get("height", 0))),
	}
	if not psd.get("ok", false):
		var err := str(psd.get("error", ""))
		out["error"] = err if err != "" else "IMPORT_ERR_READ"
		return out
	for w in psd.get("warnings", []):
		warnings.append(str(w))
	_psd_nodes(doc, psd.get("nodes", []), 0, offset, out)
	var bytes := 0
	for img: Image in (out["images"] as Dictionary).values():
		bytes += img.get_width() * img.get_height() * 4
	if doc.texture_bytes() + bytes > RbDocument.TEXTURE_BUDGET_BYTES:
		layers.clear()
		(out["images"] as Dictionary).clear()
		out["error"] = "IMPORT_ERR_BUDGET"
	return out


static func _psd_nodes(doc: RbDocument, nodes: Array, parent_id: int, offset: Vector2, out: Dictionary) -> void:
	var layers: Array[RbLayer] = out["layers"]
	var warnings: Array[String] = out["warnings"]
	for nd: Dictionary in nodes:
		var is_group: bool = nd.get("kind", "image") == "group"
		var img: Image = null
		if not is_group:
			img = nd.get("image")
			if img == null or img.is_empty():
				continue
		var l := RbLayer.new()
		l.id = doc.new_id()
		l.name = str(nd.get("name", ""))
		l.parent_id = parent_id
		l.visible = bool(nd.get("visible", true))
		l.opacity = clampf(float(nd.get("opacity", 1.0)), 0.0, 1.0)
		var blend := str(nd.get("blend", "normal"))
		l.blend_mode = blend if RbLayer.BLEND_MODES.has(blend) else "normal"
		if is_group:
			l.kind = RbLayer.Kind.GROUP
			layers.append(l)
			_psd_nodes(doc, nd.get("children", []), l.id, offset, out)
			continue
		var rect: Rect2i = nd.get("rect", Rect2i(Vector2i.ZERO, img.get_size()))
		if img.get_format() != Image.FORMAT_RGBA8:
			img = img.duplicate()
			img.convert(Image.FORMAT_RGBA8)
		var side := maxi(img.get_width(), img.get_height())
		if side > RbDocument.MAX_LAYER_SIDE:
			var k := float(RbDocument.MAX_LAYER_SIDE) / side
			img = img.duplicate()
			img.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)), Image.INTERPOLATE_LANCZOS)
			if not warnings.has("IMPORT_WARN_DOWNSCALED"):
				warnings.append("IMPORT_WARN_DOWNSCALED")
		l.kind = RbLayer.Kind.IMAGE
		l.image_id = "img%d" % l.id
		l.size = Vector2(img.get_width(), img.get_height())
		# уменьшенная картинка растягивается масштабом, видимый размер = рамка из PSD
		l.scale = Vector2(rect.size) / l.size
		l.position = Vector2(rect.position) + Vector2(rect.size) * 0.5 + offset
		l.make_quad_mesh()
		layers.append(l)
		out["images"][l.image_id] = img
