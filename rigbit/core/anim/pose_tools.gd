class_name RbPoseTools
extends RefCounted
## Копирование, вставка и зеркало позы. Поза = дельты костей к rest: {bone_id: [angle, offset, scale]}.
## Зеркало лево <-> право: пары костей ищутся по именам (L/R, Left/Right, лев/прав, Л/П),
## кость без пары отражается сама в себя. Отражение по вертикальной оси холста:
## угол меняет знак; сдвиг корневой кости (в координатах холста) = (-x, y);
## сдвиг дочерней (в пространстве родителя, ось X вдоль родителя) = (x, -y).
## Так симметричный риг в отражённой позе выглядит ровно как зеркальная картинка.

const PROPS: Array[StringName] = [&"pose_angle", &"pose_offset", &"pose_scale"]

## Пары слов, которые меняются местами. Русские как основы: «левая» -> «правая», «левый» -> «правый».
const _WORDS := [["left", "right"], ["l", "r"], ["лев", "прав"], ["л", "п"]]


## Текущая поза всех костей (или только из списка ids).
static func snapshot(rig: RbRig, ids: Array = []) -> Dictionary:
	var out := {}
	for id in (ids if not ids.is_empty() else rig.bones.keys()):
		var b := rig.get_bone(int(id))
		if b:
			out[b.id] = [b.pose_angle, b.pose_offset, b.pose_scale]
	return out


## Имя зеркальной кости или "", если в имени нет признака стороны.
static func mirror_name(name: String) -> String:
	var parts := _split(name)
	var changed := false
	for i in parts.size():
		var sw := _swap_word(parts[i])
		if sw != "":
			parts[i] = sw
			changed = true
	return "".join(parts) if changed else ""


## bone_id -> id пары (или сам себе, если пары нет).
static func mirror_map(rig: RbRig) -> Dictionary:
	var by_name := {}
	for b: RbBone in rig.bones.values():
		if b.name != "":
			by_name[b.name.to_lower()] = b.id
	var out := {}
	for b: RbBone in rig.bones.values():
		out[b.id] = b.id
		var mn := mirror_name(b.name)
		if mn != "" and by_name.has(mn.to_lower()):
			out[b.id] = int(by_name[mn.to_lower()])
	return out


## Отражённая поза: значения каждой кости переезжают на её пару и отражаются.
static func mirrored(rig: RbRig, pose: Dictionary) -> Dictionary:
	var mp := mirror_map(rig)
	var out := {}
	for id in pose:
		var b := rig.get_bone(int(id))
		if b == null:
			continue
		var v: Array = pose[id]
		var off: Vector2 = v[1]
		var target := int(mp.get(b.id, b.id))
		var tb := rig.get_bone(target)
		var root := (tb.parent_id if tb else b.parent_id) == 0
		out[target] = [-float(v[0]), Vector2(-off.x, off.y) if root else Vector2(off.x, -off.y), v[2]]
	return out


## Что поменять, чтобы кости встали в позу: [[track, value, rest], ...] только для отличающихся значений
## и дорожек, где уже есть ключи (там ключ нужен, иначе кадр возьмёт соседний).
static func key_entries(doc: RbDocument, pose: Dictionary) -> Array:
	var out: Array = []
	for id in pose:
		var b := doc.rig.get_bone(int(id))
		if b == null:
			continue
		for i in PROPS.size():
			var prop := PROPS[i]
			var v: Variant = pose[id][i]
			var cur: Variant = b.get_prop(prop)
			var tk := RbAnimation.track_key("bone", b.id, prop)
			if not _same(cur, v) or doc.anim.tracks.has(tk):
				out.append([tk, v, cur])
	return out


## Нулевая поза для «Сбросить позу».
static func rest_pose(ids: Array) -> Dictionary:
	var out := {}
	for id in ids:
		out[int(id)] = [0.0, Vector2.ZERO, Vector2.ONE]
	return out


static func _same(a: Variant, b: Variant) -> bool:
	if a is float or a is int:
		return absf(float(a) - float(b)) < 0.00001
	if a is Vector2:
		return (a as Vector2).is_equal_approx(b)
	return a == b


## Имя на слова и разделители (пробел, _, ., -), разделители сохраняются отдельными частями.
static func _split(name: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	for ch in name:
		if ch in " _.-":
			if cur != "":
				out.append(cur)
			out.append(ch)
			cur = ""
		else:
			cur += ch
	if cur != "":
		out.append(cur)
	return out


## Замена одного слова с сохранением регистра или "".
static func _swap_word(w: String) -> String:
	var low := w.to_lower()
	for pair in _WORDS:
		for k in 2:
			var a: String = pair[k]
			var b: String = pair[1 - k]
			var hit := false
			if a.length() <= 1:
				hit = low == a  # одиночные буквы только целым словом
			else:
				hit = low.begins_with(a)  # «Left», «левая», «правый»: как основа слова
			if hit:
				return _case_like(w.left(a.length()), b) + w.substr(a.length())
	return ""


static func _case_like(src: String, dst: String) -> String:
	if src == src.to_upper() and src != src.to_lower():
		return dst.to_upper() if src.length() > 1 or dst.length() == 1 else dst.capitalize()
	if src.left(1) == src.left(1).to_upper() and src.left(1) != src.left(1).to_lower():
		return dst.left(1).to_upper() + dst.substr(1)
	return dst
