class_name RbGl2Import
extends RefCounted
## Импорт персонажа Gacha Life 2 из SVG мода Насти (формат v1), ТЗ: design/gacha_import.md.
## Каждая часть растрируется отдельно из своего куска SVG (исходник хранится в RbDocument.svgs),
## скелет собирается из 13 <pivot> и рамок частей с именами костей как в Moho-экспорте мода,
## привязка жёсткая, кроме тела (автосетка + веса по Body1/Body2/Clavicle1/Clavicle2/Coccyx).
## Глаза: зрачок (eyeball) растрируется без clip-path и обрезается живой маской по склере.
## Глаза, рот и кисти становятся свитч-группами с одним вариантом (доноры добавят остальные).
## Ноги: постоянная IK к корневым костям target1/target2. Ядро без UI, на выходе Result для команды.

const TARGET_H := 1500.0  # высота персонажа в пикселях холста: чёткость при зуме
const PROBE_K := 0.125  # грубый проход растрирования, чтобы найти рамку части
const PAD := 2.0  # запас вокруг рамки части, px холста
const BODY_DENSITY := 0.45
const BODY_BONES := ["Body1", "Body2", "Clavicle1", "Clavicle2", "Coccyx"]

## Части головы -> кость (жёстко). Неизвестные части головы идут на Head.
const HEAD_BONES := {
	"headshape": "Head", "rearhair": "Head", "ear1": "Ear1", "ear2": "Ear2",
	"sidehair1": "Side_hair1", "sidehair2": "Side_hair2", "fronthair": "Front_hair",
	"mouth": "Mouth", "eyebrow1": "brow1", "eyebrow2": "brow2",
}
## Части тела верхнего уровня -> кость. Неизвестные (пояс, шарф, хвост) идут на Body1.
const TOP_BONES := {
	"shadow": "Main_bone", "fx1": "Main_bone", "backhair": "Back_hair",
	"backshoulder": "Shoulder2", "shoulder": "Shoulder1",
	"backthigh": "Leg2", "thigh": "Leg1", "backfoot": "leg2_2", "foot": "leg1_2",
}


class Result:
	var ok := false
	var error := ""
	var canvas := Vector2i.ZERO
	var layers: Array[RbLayer] = []  # родители раньше детей
	var images := {}  # image_id -> Image
	var svgs := {}  # image_id -> SVG части
	var bones: Array[RbBone] = []
	var weights := {}  # layer id -> {bones, w}
	var bone_ids := {}  # имя кости -> id
	var parts := {}  # ключ части (путь) -> id слоя, для тестов и доноров


static func is_gl2(text: String) -> bool:
	var head := text.left(4096)
	return head.contains("<title>GL2 character</title>") or head.contains("data-name=\"char\"") or text.contains("data-name=\"char\"")


# ---------------- мини-DOM ----------------

## Узел: {n: имя, a: атрибуты (порядок сохраняется), c: дети, t: текст, i: номер}
static func parse(text: String) -> Dictionary:
	var p := XMLParser.new()
	if p.open_buffer(text.to_utf8_buffer()) != OK:
		return {}
	var root := {}
	var stack: Array = []
	var counter := 0
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var a := {}
				for k in p.get_attribute_count():
					a[p.get_attribute_name(k)] = p.get_attribute_value(k)
				var node := {"n": p.get_node_name(), "a": a, "c": [], "t": "", "i": counter}
				counter += 1
				if stack.is_empty():
					root = node
				else:
					(stack.back()["c"] as Array).append(node)
				if not p.is_empty():
					stack.append(node)
			XMLParser.NODE_ELEMENT_END:
				if not stack.is_empty():
					stack.pop_back()
			XMLParser.NODE_TEXT:
				if not stack.is_empty():
					stack.back()["t"] += p.get_node_data()
	return root


static func find_named(node: Dictionary, name: String) -> Dictionary:
	for c: Dictionary in node["c"]:
		if c["a"].get("data-name", "") == name:
			return c
	return {}


static func named_children(node: Dictionary) -> Array:
	return (node["c"] as Array).filter(func(c: Dictionary) -> bool: return c["a"].has("data-name"))


static func _first(node: Dictionary, tag: String) -> Dictionary:
	if node.is_empty():
		return {}
	if node["n"] == tag:
		return node
	for c: Dictionary in node["c"]:
		var r := _first(c, tag)
		if not r.is_empty():
			return r
	return {}


static func _collect(node: Dictionary, tag: String, out: Array) -> void:
	if node["n"] == tag:
		out.append(node)
	for c: Dictionary in node["c"]:
		_collect(c, tag, out)


## <pivot name m="a b c d tx ty"> -> имя: Transform2D в координатах SVG.
static func pivots(root: Dictionary) -> Dictionary:
	var list: Array = []
	_collect(root, "pivot", list)
	var out := {}
	for p: Dictionary in list:
		var m: PackedFloat64Array = str(p["a"].get("m", "")).split_floats(" ", false)
		if m.size() == 6:
			out[str(p["a"].get("name", ""))] = Transform2D(Vector2(m[0], m[1]), Vector2(m[2], m[3]), Vector2(m[4], m[5]))
	return out


static func _esc(v: String) -> String:
	return v.replace("&", "&amp;").replace("<", "&lt;").replace("\"", "&quot;")


## Узел обратно в текст. skip: номера узлов, которые пропустить; strip_clip: убрать clip-path.
static func serialize(node: Dictionary, skip := {}, strip_clip := false) -> String:
	var out := PackedStringArray()
	_ser(node, out, skip, strip_clip)
	return "".join(out)


static func _ser(node: Dictionary, out: PackedStringArray, skip: Dictionary, strip_clip: bool) -> void:
	if skip.has(node["i"]):
		return
	out.append("<" + node["n"])
	for k in node["a"]:
		if strip_clip and k == "clip-path":
			continue
		out.append(" %s=\"%s\"" % [k, _esc(str(node["a"][k]))])
	if (node["c"] as Array).is_empty() and node["t"] == "":
		out.append("/>")
		return
	out.append(">")
	if node["t"] != "":
		out.append(_esc(node["t"]).replace("&quot;", "\""))
	for c: Dictionary in node["c"]:
		_ser(c, out, skip, strip_clip)
	out.append("</%s>" % node["n"])


# ---------------- импорт ----------------

class _Ctx:
	var doc: RbDocument
	var res: Result
	var defs := ""
	var vb := Rect2()  # viewBox SVG
	var k := 1.0  # px холста на единицу SVG
	var piv := {}  # имя -> Transform2D (SVG)
	var rects := {}  # ключ части -> Rect2 в холсте
	var bind := {}  # id слоя -> имя кости или "@body"

	func to_canvas(p: Vector2) -> Vector2:
		return (p - vb.position) * k

	func pivot(name: String) -> Vector2:
		return to_canvas((piv[name] as Transform2D).origin) if piv.has(name) else Vector2.ZERO


static func build(doc: RbDocument, text: String) -> Result:
	var res := Result.new()
	var root := parse(text)
	if root.is_empty() or root["n"] != "svg":
		res.error = "IMPORT_ERR_READ"
		return res
	var outer := _find_char(root)
	var ch := find_named(outer, "char") if not outer.is_empty() else {}
	if ch.is_empty():
		ch = outer
	if ch.is_empty():
		res.error = "GL2_ERR_NO_CHAR"
		return res
	var cx := _Ctx.new()
	cx.doc = doc
	cx.res = res
	var vbs: PackedFloat64Array = str(root["a"].get("viewBox", "")).split_floats(" ", false)
	if vbs.size() != 4:
		vbs = PackedFloat64Array([0, 0, float(root["a"].get("width", "512")), float(root["a"].get("height", "512"))])
	cx.vb = Rect2(vbs[0], vbs[1], vbs[2], vbs[3])
	cx.k = TARGET_H / maxf(cx.vb.size.y, 1.0)
	cx.piv = pivots(root)
	var defs := _first(root, "defs")
	cx.defs = serialize(defs) if not defs.is_empty() else ""
	res.canvas = Vector2i(ceili(cx.vb.size.x * cx.k), ceili(cx.vb.size.y * cx.k))

	var group := _group("Персонаж", 0, RbLayer.Kind.GROUP, cx)
	for part: Dictionary in named_children(ch):
		var nm: String = part["a"]["data-name"]
		match nm:
			"head":
				var inner := find_named(part, "head")
				for hp: Dictionary in named_children(inner if not inner.is_empty() else part):
					_head_part(hp, group.id, cx)
			"handx":
				_arm(part, group.id, "1", cx)
			"backhand":
				_arm(part, group.id, "2", cx)
			"body":
				var l := _part(part, "body", group.id, cx)
				if l:
					cx.bind[l.id] = "@body"
			_:
				var l2 := _part(part, nm, group.id, cx)
				if l2:
					cx.bind[l2.id] = TOP_BONES.get(nm, "Body1")
	if res.images.is_empty():
		res.error = "GL2_ERR_NO_PARTS"
		return res
	_skeleton(cx)
	_weights(cx)
	res.ok = true
	return res


static func _find_char(node: Dictionary) -> Dictionary:
	if node["a"].get("data-name", "") == "char":
		return node
	for c: Dictionary in node["c"]:
		var r := _find_char(c)
		if not r.is_empty():
			return r
	return {}


static func _group(name: String, parent: int, kind: RbLayer.Kind, cx: _Ctx) -> RbLayer:
	var g := RbLayer.new()
	g.id = cx.doc.new_id()
	g.name = name
	g.kind = kind
	g.parent_id = parent
	cx.res.layers.append(g)
	return g


## Глаз: свитч > вариант > [склера, зрачок (маска = склера, без клипа), веко].
static func _eye(node: Dictionary, n: String, parent: int, cx: _Ctx) -> void:
	var sw := _group("eye" + n, parent, RbLayer.Kind.SWITCH, cx)
	var v := _group("Глаза 1", sw.id, RbLayer.Kind.GROUP, cx)
	var sclera := find_named(node, "sclera")
	var ball := find_named(node, "eyeball")
	var lid := find_named(node, "eyeshape")
	var sl := _part(sclera, "eye%s/sclera" % n, v.id, cx) if not sclera.is_empty() else null
	var bl := _part(ball, "eye%s/eyeball" % n, v.id, cx, {}, true) if not ball.is_empty() else null
	var ll := _part(lid, "eye%s/eyeshape" % n, v.id, cx) if not lid.is_empty() else null
	if sl:
		cx.bind[sl.id] = "Eye" + n
	if ll:
		cx.bind[ll.id] = "Eye" + n
	if bl:
		cx.bind[bl.id] = "Pupil" + n
		if sl:
			bl.mask_id = sl.id


static func _head_part(hp: Dictionary, parent: int, cx: _Ctx) -> void:
	var nm: String = hp["a"]["data-name"]
	if nm == "eye1" or nm == "eye2":
		_eye(hp, nm.right(1), parent, cx)
		return
	if nm == "mouth":
		var sw := _group("mouth", parent, RbLayer.Kind.SWITCH, cx)
		var m := _part(hp, "mouth", sw.id, cx)
		if m:
			m.name = "Рот 1"
			cx.bind[m.id] = "Mouth"
		return
	var l := _part(hp, nm, parent, cx)
	if l == null:
		return
	if nm.begins_with("faceacc") or nm.begins_with("glasses"):
		cx.bind[l.id] = "Face_bone"
	else:
		cx.bind[l.id] = HEAD_BONES.get(nm, "Head")


## Рука: handx > handx > [handx (предплечье) > handx (кисть), sleeve].
## Слои: предплечье (без кисти), кисть (свитч), рукав поверх кисти.
static func _arm(node: Dictionary, parent: int, n: String, cx: _Ctx) -> void:
	var l2 := find_named(node, "handx")
	if l2.is_empty():
		var whole := _part(node, "arm" + n, parent, cx)
		if whole:
			cx.bind[whole.id] = "Forearm" + n
		return
	var fore := find_named(l2, "handx")
	var hand := find_named(fore, "handx") if not fore.is_empty() else {}
	var sleeve := find_named(l2, "sleeve")
	if not fore.is_empty():
		var skip := {}
		if not hand.is_empty():
			skip[hand["i"]] = true
		var fl := _part(fore, "forearm" + n, parent, cx, skip)
		if fl:
			cx.bind[fl.id] = "Forearm" + n
	if not hand.is_empty():
		var sw := _group("hand" + n, parent, RbLayer.Kind.SWITCH, cx)
		var hl := _part(hand, "hand" + n, sw.id, cx)
		if hl:
			hl.name = "Кисть 1"
			cx.bind[hl.id] = "Brush" + n
	if not sleeve.is_empty():
		var sl := _part(sleeve, "sleeve" + n, parent, cx)
		if sl:
			cx.bind[sl.id] = "Forearm" + n


## Растрировать узел отдельным SVG и сделать слой. null, если часть пустая.
static func _part(node: Dictionary, key: String, parent: int, cx: _Ctx, skip := {}, strip_clip := false) -> RbLayer:
	var body := serialize(node, skip, strip_clip)
	var probe := _raster(cx, body, cx.vb, PROBE_K * cx.k)
	if probe == null:
		return null
	var used := probe.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return null
	# рамка в SVG по грубому проходу (+1 пиксель пробы на округление), затем чистый растр только рамки
	var pk := PROBE_K * cx.k
	var r := Rect2(cx.vb.position + Vector2(used.position) / pk, Vector2(used.size) / pk).grow(1.0 / pk + PAD / cx.k)
	r = r.intersection(cx.vb)
	var img := _raster(cx, body, r, cx.k)
	if img == null:
		return null
	var u := img.get_used_rect()
	if u.size.x <= 0 or u.size.y <= 0:
		return null
	img = img.get_region(u)
	var l := RbLayer.new()
	l.id = cx.doc.new_id()
	l.name = key.get_file()
	l.kind = RbLayer.Kind.IMAGE
	l.parent_id = parent
	l.image_id = "img%d" % l.id
	l.size = Vector2(img.get_width(), img.get_height())
	var tl := cx.to_canvas(r.position) + Vector2(u.position)
	l.position = tl + l.size * 0.5
	l.make_quad_mesh()
	cx.res.layers.append(l)
	cx.res.images[l.image_id] = img
	cx.res.svgs[l.image_id] = _svg_doc(cx, body, r)
	cx.res.parts[key] = l.id
	cx.rects[key] = Rect2(tl, l.size)
	return l


static func _svg_doc(cx: _Ctx, body: String, r: Rect2) -> String:
	return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"%s %s %s %s\">%s%s</svg>" % [
		r.size.x, r.size.y, r.position.x, r.position.y, r.size.x, r.size.y, cx.defs, body]


static func _raster(cx: _Ctx, body: String, r: Rect2, scale: float) -> Image:
	var img := Image.new()
	if img.load_svg_from_string(_svg_doc(cx, body, r), scale) != OK or img.is_empty():
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


# ---------------- скелет ----------------

## Кость из двух мировых точек холста; родитель уже должен быть в cx.res.bones.
static func _bone(cx: _Ctx, name: String, parent: String, a: Vector2, b: Vector2) -> RbBone:
	var bn := RbBone.new()
	bn.id = cx.doc.new_id()
	bn.name = name
	var d := b - a
	if d.length() < 4.0:
		d = Vector2(0, -4.0)
	bn.length = d.length()
	var world_angle := d.angle()
	var pid: int = cx.res.bone_ids.get(parent, 0)
	bn.parent_id = pid
	if pid == 0:
		bn.position = a
		bn.angle = world_angle
	else:
		var pw := _rest_world(cx, pid)
		bn.position = pw.affine_inverse() * a
		bn.angle = wrapf(world_angle - pw.get_rotation(), -PI, PI)
	cx.res.bones.append(bn)
	cx.res.bone_ids[name] = bn.id
	return bn


static func _rest_world(cx: _Ctx, id: int) -> Transform2D:
	for b: RbBone in cx.res.bones:
		if b.id == id:
			var local := b.rest_local()
			return local if b.parent_id == 0 else _rest_world(cx, b.parent_id) * local
	return Transform2D.IDENTITY


static func _rect(cx: _Ctx, key: String) -> Rect2:
	return cx.rects.get(key, Rect2())


static func _top_center(r: Rect2) -> Vector2:
	return Vector2(r.get_center().x, r.position.y)


static func _skeleton(cx: _Ctx) -> void:
	var up := Vector2(0, -1)
	var root := cx.pivot("root")
	var body := cx.pivot("body")
	var neck := cx.pivot("head")
	var k := cx.k
	_bone(cx, "Main_bone", "", root, root + up * 30.0 * k)
	var mid := body.lerp(neck, 0.5)
	_bone(cx, "Body1", "Main_bone", body, mid)
	var b2 := _bone(cx, "Body2", "Body1", mid, neck)
	b2.constraints = {"limit": {"min": deg_to_rad(-10.0), "max": deg_to_rad(10.0)}}
	var hs := _rect(cx, "headshape")
	var head_top := Vector2(neck.x, hs.position.y) if hs.size.y > 0 else neck + up * 80.0 * k
	_bone(cx, "Head", "Body2", neck, head_top)
	var face := hs.get_center() if hs.size.y > 0 else neck + up * 60.0 * k
	_bone(cx, "Face_bone", "Head", face, face + up * maxf(hs.size.y * 0.2, 8.0))
	for n in ["1", "2"]:
		var sc := _rect(cx, "eye%s/sclera" % n)
		var c := sc.get_center() if sc.size.x > 0 else face
		_bone(cx, "Eye" + n, "Face_bone", c, c + up * maxf(sc.size.y * 0.5, 6.0))
	var e1 := _rect(cx, "eye1/sclera").get_center()
	var e2 := _rect(cx, "eye2/sclera").get_center()
	var pc := e1.lerp(e2, 0.5) if e1 != Vector2.ZERO and e2 != Vector2.ZERO else face
	_bone(cx, "Pupils", "Face_bone", pc, pc + up * 8.0)
	for n in ["1", "2"]:
		var eb := _rect(cx, "eye%s/eyeball" % n)
		var c2 := eb.get_center() if eb.size.x > 0 else pc
		_bone(cx, "Pupil" + n, "Pupils", c2, c2 + up * maxf(eb.size.y * 0.3, 4.0))
	for pair in [["mouth", "Mouth"], ["eyebrow1", "brow1"], ["eyebrow2", "brow2"], ["ear1", "Ear1"], ["ear2", "Ear2"]]:
		var r := _rect(cx, pair[0])
		var c3 := r.get_center() if r.size.x > 0 else face
		_bone(cx, pair[1], "Face_bone" if pair[1] in ["Mouth", "brow1", "brow2"] else "Head", c3, c3 + up * maxf(r.size.y * 0.5, 6.0))
	# волосы висят: от верха части вниз
	for pair in [["backhair", "Back_hair"], ["fronthair", "Front_hair"], ["sidehair1", "Side_hair1"], ["sidehair2", "Side_hair2"]]:
		var r2 := _rect(cx, pair[0])
		var t := _top_center(r2) if r2.size.x > 0 else head_top
		_bone(cx, pair[1], "Head", t, t + Vector2(0, maxf(r2.size.y * 0.6, 10.0)))
	# руки: ключица от шеи к плечу, плечо, предплечье, кисть дальше по линии предплечья
	for side in [["1", "shoulder", "arm", "hand"], ["2", "backshoulder", "backarm", "backhand"]]:
		var n2: String = side[0]
		var sh := cx.pivot(side[1])
		var el := cx.pivot(side[2])
		var wr := cx.pivot(side[3])
		_bone(cx, "Clavicle" + n2, "Body2", neck, sh)
		_bone(cx, "Shoulder" + n2, "Clavicle" + n2, sh, el)
		_bone(cx, "Forearm" + n2, "Shoulder" + n2, el, wr)
		var hr := _rect(cx, "hand" + n2)
		var reach := maxf(hr.size.length() * 0.5, 10.0)
		_bone(cx, "Brush" + n2, "Forearm" + n2, wr, wr + (wr - el).normalized() * reach)
	# ноги: копчик, бедро до колена, голень до низа стопы; IK к целям в конце голени
	var hips := cx.pivot("thigh").lerp(cx.pivot("backthigh"), 0.5)
	_bone(cx, "Coccyx", "Body1", body, hips)
	for side in [["1", "thigh", "foot"], ["2", "backthigh", "backfoot"]]:
		var n3: String = side[0]
		var hip := cx.pivot(side[1])
		var knee := cx.pivot(side[2])
		var fr := _rect(cx, side[2])
		var ankle := Vector2(knee.x, fr.end.y - fr.size.y * 0.15) if fr.size.y > 0 else knee + Vector2(0, 80.0 * k)
		var leg_name := "Leg1" if n3 == "1" else "leg2"
		_bone(cx, leg_name, "Coccyx", hip, knee)
		var shin := _bone(cx, "leg%s_2" % n3, leg_name, knee, ankle)
		var tg := _bone(cx, "target" + n3, "", ankle, ankle + Vector2(20.0 * k, 0))
		shin.constraints = {"ik": {"target": tg.id}}


## Имена ног в Moho: Leg1 и leg2 (как в экспорте мода).
static func _bone_id(cx: _Ctx, name: String) -> int:
	if name == "Leg2":
		name = "leg2"
	return int(cx.res.bone_ids.get(name, cx.res.bone_ids.get("Body1", 0)))


static func _weights(cx: _Ctx) -> void:
	var rig := RbRig.new()
	for b in cx.res.bones:
		rig.bones[b.id] = b
	for l in cx.res.layers:
		if not cx.bind.has(l.id):
			continue
		var what: String = cx.bind[l.id]
		if what == "@body":
			var m := RbMeshGen.generate(cx.res.images[l.image_id], BODY_DENSITY)
			l.mesh_vertices = m["vertices"]
			l.mesh_uvs = m["uvs"]
			l.mesh_indices = m["indices"]
			l.mesh_density = BODY_DENSITY
			var world := PackedVector2Array()
			for v in l.mesh_vertices:
				world.append(v + l.position)
			var ids: Array = []
			for nm in BODY_BONES:
				ids.append(_bone_id(cx, nm))
			cx.res.weights[l.id] = rig.auto_weights(world, ids)
		else:
			cx.res.weights[l.id] = RbRig.rigid_weights(l.mesh_vertices.size(), _bone_id(cx, what))
