class_name RbAnimation
extends RefCounted
## Ключи анимации. Дорожка = одно свойство одного объекта:
##   "bone:<id>:pose_angle" / "bone:<id>:pose_offset" / "bone:<id>:pose_scale"
##   "layer:<id>:position" / rotation / scale / opacity / visible / switch_index / z (последние три ступенькой)
## Модель «текущий кадр записан в объекты»: apply_frame(f) кладёт значения дорожек
## в кости и слои, вычислитель читает объекты. Правка в режиме Анимация = ключ на кадре.

const INTERPS := ["linear", "smooth", "ease_in", "ease_out", "step", "bounce"]
## Свойства, которые всегда меняются ступенькой, какая бы интерполяция ни стояла на ключе
const STEP_PROPS: Array[StringName] = [&"visible", &"switch_index", &"z"]

## track_key -> Array ключей [{f: int, v: Variant, i: String}], отсортировано по f
var tracks: Dictionary = {}


static func track_key(kind: String, id: int, prop: StringName) -> String:
	return "%s:%d:%s" % [kind, id, prop]


static func parse(key: String) -> Array:
	var p := key.split(":")
	return [p[0], int(p[1]), StringName(p[2])]


func keys_of(key: String) -> Array:
	return tracks.get(key, [])


func key_index(key: String, frame: int) -> int:
	var ks := keys_of(key)
	for i in ks.size():
		if int(ks[i]["f"]) == frame:
			return i
	return -1


## Поставить ключ (заменить, если на кадре уже есть). Возвращает прежний ключ или {}.
func set_key(key: String, frame: int, value: Variant, interp := "smooth") -> Dictionary:
	var ks: Array = tracks.get(key, [])
	var old := {}
	var i := key_index(key, frame)
	if i >= 0:
		old = ks[i].duplicate()
		ks[i] = {"f": frame, "v": value, "i": interp if interp != "" else str(old.get("i", "smooth"))}
	else:
		ks.append({"f": frame, "v": value, "i": interp if interp != "" else "smooth"})
		ks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["f"]) < int(b["f"]))
	tracks[key] = ks
	return old


func remove_key(key: String, frame: int) -> Dictionary:
	var i := key_index(key, frame)
	if i < 0:
		return {}
	var ks: Array = tracks[key]
	var old: Dictionary = ks[i]
	ks.remove_at(i)
	if ks.is_empty():
		tracks.erase(key)
	return old


## Значение дорожки на кадре (float-кадры для плавного превью).
func sample(key: String, frame: float) -> Variant:
	var ks := keys_of(key)
	if ks.is_empty():
		return null
	if frame <= float(ks[0]["f"]):
		return ks[0]["v"]
	if frame >= float(ks[ks.size() - 1]["f"]):
		return ks[ks.size() - 1]["v"]
	for i in ks.size() - 1:
		var a: Dictionary = ks[i]
		var b: Dictionary = ks[i + 1]
		if frame >= float(a["f"]) and frame < float(b["f"]):
			if _is_step(key):
				return a["v"]
			var t := (frame - float(a["f"])) / float(int(b["f"]) - int(a["f"]))
			return _mix(a["v"], b["v"], ease_t(t, str(a["i"])))
	return ks[ks.size() - 1]["v"]


static func _is_step(key: String) -> bool:
	return parse(key)[2] in STEP_PROPS


static func ease_t(t: float, interp: String) -> float:
	match interp:
		"linear":
			return t
		"step":
			return 0.0
		"ease_in":
			return t * t
		"ease_out":
			return 1.0 - (1.0 - t) * (1.0 - t)
		"bounce":
			# перелёт и возврат: как пружинка у чиби
			var s := 1.70158 * 1.525
			var u := t - 1.0
			return 1.0 + u * u * ((s + 1.0) * u + s)
		_:
			return t * t * (3.0 - 2.0 * t)  # smooth


static func _mix(a: Variant, b: Variant, t: float) -> Variant:
	if a is float or a is int:
		return lerpf(float(a), float(b), t)
	if a is Vector2:
		return (a as Vector2).lerp(b, t)
	if a is bool:
		return a if t < 1.0 else b
	return a


## Записать значения всех дорожек на кадре в объекты документа.
func apply_frame(doc: RbDocument, frame: float) -> void:
	for key in tracks:
		var p := parse(key)
		var v: Variant = sample(key, frame)
		if v == null:
			continue
		if p[0] == "bone":
			var b := doc.rig.get_bone(p[1])
			if b:
				b.set_prop(p[2], v)
		elif p[0] == "layer":
			var l := doc.get_layer(p[1])
			if l:
				l.set_prop(p[2], v)
		elif p[0] == "param":
			var prm := doc.params.get_param(p[1])
			if prm:
				prm.value = float(v)
		elif p[0] == "pin":
			var pin := doc.rig.find_pin(p[1])
			if not pin.is_empty():
				pin[String(p[2])] = v


## Текущие значения свойств, которые apply_frame перезапишет: [[track, value], ...].
## Чтобы вычислить другой кадр (экспорт, онион скин) и вернуть всё как было.
func capture(doc: RbDocument) -> Array:
	var out: Array = []
	for key in tracks:
		var p := parse(key)
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


static func restore(doc: RbDocument, snap: Array) -> void:
	for e in snap:
		var key: String = e[0]
		var v: Variant = e[1]
		var p := parse(key)
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


func has_tracks_for(kind: String, id: int) -> bool:
	var prefix := "%s:%d:" % [kind, id]
	for key in tracks:
		if (key as String).begins_with(prefix):
			return true
	return false


## Все кадры с ключами (для сводной строки таймлайна). prefix: фильтр по объекту ("" = всё).
func key_frames(prefix := "") -> PackedInt32Array:
	var set := {}
	for key in tracks:
		if prefix == "" or (key as String).begins_with(prefix):
			for k in tracks[key]:
				set[int(k["f"])] = true
	var out := PackedInt32Array(set.keys())
	out.sort()
	return out


## Удалить дорожки объекта (при удалении кости/слоя). Возвращает снятые дорожки.
func drop_object(kind: String, id: int) -> Dictionary:
	var prefix := "%s:%d:" % [kind, id]
	var out := {}
	for key in tracks.keys():
		if (key as String).begins_with(prefix):
			out[key] = tracks[key]
			tracks.erase(key)
	return out


func to_dict() -> Dictionary:
	var out := {}
	for key in tracks:
		var ks: Array = []
		for k in tracks[key]:
			ks.append({"f": k["f"], "v": _enc(k["v"]), "i": k["i"]})
		out[key] = ks
	return {"tracks": out}


static func from_dict(d: Dictionary) -> RbAnimation:
	var a := RbAnimation.new()
	var tr: Dictionary = d.get("tracks", {})
	for key in tr:
		var ks: Array = []
		for k in tr[key]:
			ks.append({"f": int(k["f"]), "v": _dec(k["v"]), "i": str(k.get("i", "smooth"))})
		a.tracks[key] = ks
	return a


static func _enc(v: Variant) -> Variant:
	if v is Vector2:
		return [(v as Vector2).x, (v as Vector2).y]
	return v


static func _dec(v: Variant) -> Variant:
	if v is Array and (v as Array).size() == 2:
		return Vector2(v[0], v[1])
	return v
