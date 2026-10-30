class_name RbFrameRenderer
extends Node
## Рендер кадра документа в Image на размере экспорта, независимо от вьюпорта редактора.
## Владеет своим SubViewport (свой World2D, основной вид не трогает) и своим вычислителем.
## Узел должен быть в дереве сцены (add_child), иначе кадр не отрисуется.
## Использование:
##   var fr := RbFrameRenderer.new(); add_child(fr)
##   fr.setup(doc, Vector2i(512, 512), true, Color.WHITE)
##   for f in doc.frame_count: frames.append(await fr.render_frame(f))
##   fr.finish()   # вернуть low_processor_usage_mode

var doc: RbDocument
var export_size := Vector2i(512, 512)
var transparent := true
var background := Color.WHITE
## Сглаживание краёв геометрии (MSAA 2D). Текстуры и так фильтруются с мипмапами.
var msaa := Viewport.MSAA_4X

var _vp: SubViewport
var _cam: Node2D  # масштаб+сдвиг: холст документа ровно (с полями по бокам) во вьюпорт
var _bg: ColorRect
var _ren: _ExportRenderer
var _eval := RbEvaluator.new()
var _saved_low_proc := false
var _low_proc_taken := false


## Без тени и без фона холста (это рисует редактор во вьюпорте): только слои.
class _ExportRenderer extends RbRenderer:
	func _draw() -> void:
		pass


func setup(d: RbDocument, size: Vector2i, transparent_bg: bool, bg: Color) -> void:
	doc = d
	export_size = Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	transparent = transparent_bg
	background = bg
	if _vp == null:
		_vp = SubViewport.new()
		_vp.own_world_3d = false
		_vp.disable_3d = true
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_bg = ColorRect.new()
		_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_vp.add_child(_bg)
		_cam = Node2D.new()
		_vp.add_child(_cam)
		_ren = _ExportRenderer.new()
		_cam.add_child(_ren)
		add_child(_vp)
	_vp.size = export_size
	_vp.transparent_bg = transparent
	# в gl_compatibility MSAA 2D не поддерживается (ворнинг), края сглаживает фильтрация текстур
	_vp.msaa_2d = msaa if RenderingServer.get_current_rendering_method() != "gl_compatibility" else Viewport.MSAA_DISABLED
	_bg.visible = not transparent
	_bg.color = Color(bg.r, bg.g, bg.b, 1.0)
	_bg.size = Vector2(export_size)
	# вписать холст целиком, по центру (пропорции сохраняются)
	var cs := Vector2(doc.canvas_size)
	var k := minf(export_size.x / cs.x, export_size.y / cs.y)
	_cam.scale = Vector2(k, k)
	_cam.position = (Vector2(export_size) - cs * k) * 0.5
	_ren.clear()


## Отрисовать кадр. Дорожки применяются к документу, затем всё возвращается как было.
func render_frame(frame: int) -> Image:
	if doc == null or _vp == null:
		push_error("RbFrameRenderer: сначала setup()")
		return null
	_take_low_proc()
	var snap := _snapshot()
	var old_frame := doc.current_frame
	doc.current_frame = frame
	doc.anim.apply_frame(doc, frame)
	var pose := _eval.evaluate(doc, frame, true)
	_restore(snap)
	doc.current_frame = old_frame
	_ren.sync(doc, pose)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	if img == null or img.is_empty():
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if transparent:
		unpremultiply(img)  # Godot отдаёт прозрачный вьюпорт с premultiplied-цветом: края темнеют
	return img


## premultiplied -> straight alpha, на месте (RGBA8). Полностью прозрачные и непрозрачные не трогаем.
static func unpremultiply(img: Image) -> void:
	var d := img.get_data()
	var n := d.size()
	var inv := PackedInt32Array()
	inv.resize(256)
	for a in range(1, 256):
		inv[a] = (255 << 8) / a
	var changed := false
	var o := 3
	while o < n:
		var a := d[o]
		if a != 255 and a != 0:
			var k := inv[a]
			d[o - 3] = mini(255, (d[o - 3] * k) >> 8)
			d[o - 2] = mini(255, (d[o - 2] * k) >> 8)
			d[o - 1] = mini(255, (d[o - 1] * k) >> 8)
			changed = true
		o += 4
	if changed:
		img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, d)


## Вернуть настройки окна (low_processor_usage_mode). Звать после экспорта.
func finish() -> void:
	if _low_proc_taken:
		OS.low_processor_usage_mode = _saved_low_proc
		_low_proc_taken = false
	if _ren:
		_ren.clear()
	if _vp:
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _exit_tree() -> void:
	finish()


func _take_low_proc() -> void:
	if not _low_proc_taken:
		_saved_low_proc = OS.low_processor_usage_mode
		_low_proc_taken = true
	OS.low_processor_usage_mode = false  # иначе frame_post_draw может не прийти


## Значения дорожек, которые apply_frame перезапишет: вернём их после вычисления,
## чтобы экспорт не менял то, что видит пользователь (в т.ч. в режиме Риг).
func _snapshot() -> Array:
	var out: Array = []
	for key in doc.anim.tracks:
		var p := RbAnimation.parse(key)
		match p[0]:
			"bone":
				var b := doc.rig.get_bone(p[1])
				if b:
					out.append([key, b.get_prop(p[2])])
			"layer":
				var l := doc.get_layer(p[1])
				if l:
					out.append([key, l.get_prop(p[2])])
			"param":
				var prm := doc.params.get_param(p[1])
				if prm:
					out.append([key, prm.value])
			"pin":
				var pin := doc.rig.find_pin(p[1])
				if not pin.is_empty():
					out.append([key, pin.get(String(p[2]))])
	return out


func _restore(snap: Array) -> void:
	for e in snap:
		var key: String = e[0]
		var v: Variant = e[1]
		var p := RbAnimation.parse(key)
		match p[0]:
			"bone":
				var b := doc.rig.get_bone(p[1])
				if b:
					b.set_prop(p[2], v)
			"layer":
				var l := doc.get_layer(p[1])
				if l:
					l.set_prop(p[2], v)
			"param":
				var prm := doc.params.get_param(p[1])
				if prm:
					prm.value = float(v)
			"pin":
				var pin := doc.rig.find_pin(p[1])
				if not pin.is_empty():
					pin[String(p[2])] = v
