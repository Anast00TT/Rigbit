class_name RbTimelineLogic
extends RefCounted
## Логика таймлайна без интерфейса: кадр <-> координата, зум и прокрутка, строки, поиск и выделение ключей,
## копирование и вставка. Всё статическое, чтобы проверять тестами.
## Координаты области дорожек отсчитываются от её левого края (колонка имён не входит),
## по вертикали от верха первой строки с учётом прокрутки.

const MIN_PPF := 6.0  # px на кадр
const MAX_PPF := 60.0
const HEAD_H := 40.0  # строка заголовка объекта
const ROW_H := 32.0  # строка дорожки
const KEY_HALF := 7.0  # ключ рисуется 14 dp
const HIT_HALF := 14.0  # зона касания ключа: 28 dp по ширине

const BONE_PROPS: Array[StringName] = [&"pose_angle", &"pose_offset", &"pose_scale"]
const LAYER_PROPS: Array[StringName] = [&"position", &"rotation", &"scale", &"opacity", &"visible"]
const PARAM_PROPS: Array[StringName] = [&"value"]
const PIN_PROPS: Array[StringName] = [&"offset"]
## Порядок объектов в общем списке: кости, слои, ползунки, пины.
const KIND_ORDER := {"bone": 0, "layer": 1, "param": 2, "pin": 3}
const LABELS := {
	&"pose_angle": "TL_ROT", &"pose_offset": "TL_OFFSET", &"pose_scale": "TL_SCALE",
	&"position": "TL_POS", &"rotation": "TL_ROT", &"scale": "TL_SCALE",
	&"opacity": "TL_OPACITY", &"visible": "TL_VISIBLE",
	&"value": "TL_VALUE", &"offset": "TL_OFFSET",
}


# ---------------- кадр <-> координата ----------------

## Центр ячейки кадра: ключи и линия кадра стоят здесь.
static func frame_x(f: float, scroll: float, ppf: float) -> float:
	return (f - scroll + 0.5) * ppf


## Кадр под координатой x, прижатый к 0..count-1.
static func x_frame(x: float, scroll: float, ppf: float, count: int) -> int:
	return clampi(floori(x / ppf + scroll), 0, maxi(count - 1, 0))


static func max_scroll(ppf: float, view_w: float, count: int) -> float:
	return maxf(0.0, float(count) - view_w / ppf)


static func clamp_scroll(scroll: float, ppf: float, view_w: float, count: int) -> float:
	return clampf(scroll, 0.0, max_scroll(ppf, view_w, count))


## Масштаб, при котором все кадры помещаются в ширину (не меньше MIN_PPF).
static func fit_ppf(view_w: float, count: int) -> float:
	return clampf(view_w / float(maxi(count, 1)), MIN_PPF, MAX_PPF)


## Зум вокруг точки anchor_x: кадр под пальцем остаётся на месте. Возвращает [scroll, ppf].
static func zoom_at(scroll: float, ppf: float, new_ppf: float, anchor_x: float, view_w: float, count: int) -> Array:
	var np := clampf(new_ppf, MIN_PPF, MAX_PPF)
	var f_at := anchor_x / ppf + scroll
	return [clamp_scroll(f_at - anchor_x / np, np, view_w, count), np]


## Подписи линейки через каждые N кадров, чтобы не слипались (не реже чем раз в 32 px).
static func label_step(ppf: float) -> int:
	for s in [1, 2, 3, 6, 12, 24, 48, 96, 192]:
		if s * ppf >= 32.0:
			return s
	return 384


## Прокрутка так, чтобы кадр f был виден целиком.
static func scroll_to_show(f: int, scroll: float, ppf: float, view_w: float, count: int) -> float:
	var s := scroll
	if float(f) < s:
		s = float(f)
	elif float(f + 1) > s + view_w / ppf:
		s = float(f + 1) - view_w / ppf
	return clamp_scroll(s, ppf, view_w, count)


# ---------------- строки ----------------

static func object_exists(doc: RbDocument, kind: String, id: int) -> bool:
	match kind:
		"bone":
			return doc.rig.get_bone(id) != null
		"param":
			return doc.params.get_param(id) != null
		"pin":
			return not doc.rig.find_pin(id).is_empty()
	return doc.get_layer(id) != null


## Имя объекта; пустое, если у кости или ползунка нет имени (интерфейс подставит «Кость N»).
## У пина своего имени нет: возвращается имя его слоя.
static func object_name(doc: RbDocument, kind: String, id: int) -> String:
	match kind:
		"bone":
			var b := doc.rig.get_bone(id)
			return b.name if b else ""
		"param":
			var prm := doc.params.get_param(id)
			return prm.name if prm else ""
		"pin":
			var info := pin_info(doc, id)
			var pl := doc.get_layer(info[0]) if info[0] != 0 else null
			return pl.name if pl else ""
	var l := doc.get_layer(id)
	return l.name if l else ""


## Слой пина и его номер на слое с 1: [layer_id, n] или [0, 0].
static func pin_info(doc: RbDocument, pin_id: int) -> Array:
	for lid in doc.rig.pins:
		var arr: Array = doc.rig.pins[lid]
		for i in arr.size():
			if int(arr[i]["id"]) == pin_id:
				return [int(lid), i + 1]
	return [0, 0]


static func props_of(kind: String) -> Array[StringName]:
	match kind:
		"bone":
			return BONE_PROPS
		"param":
			return PARAM_PROPS
		"pin":
			return PIN_PROPS
	return LAYER_PROPS


## Строки таймлайна. Заголовок объекта {t:"head", kind, id, name} (у пина ещё n: номер на слое), затем его дорожки
## {t:"track", track, kind, id, prop, label}; у объекта без ключей одна строка {t:"empty"}.
## only_focus и focus_kind != "": только выделенный объект. Иначе все объекты, у которых есть дорожки.
static func build_rows(doc: RbDocument, focus_kind: String, focus_id: int, only_focus: bool) -> Array:
	var objs: Array = []
	if only_focus and focus_kind != "":
		objs.append([focus_kind, focus_id])
	else:
		var seen := {}
		for key in doc.anim.tracks:
			var p := RbAnimation.parse(key)
			var k := "%s:%d" % [p[0], p[1]]
			if not seen.has(k):
				seen[k] = true
				objs.append([p[0], p[1]])
		objs.sort_custom(func(a: Array, b: Array) -> bool:
			if a[0] != b[0]:
				return int(KIND_ORDER.get(a[0], 9)) < int(KIND_ORDER.get(b[0], 9))
			return int(a[1]) < int(b[1]))
	var rows: Array = []
	for o in objs:
		if not object_exists(doc, o[0], o[1]):
			continue
		var head := {"t": "head", "kind": o[0], "id": o[1], "name": object_name(doc, o[0], o[1])}
		if o[0] == "pin":
			head["n"] = pin_info(doc, o[1])[1]
		rows.append(head)
		var count := 0
		for prop in props_of(o[0]):
			var tk := RbAnimation.track_key(o[0], o[1], prop)
			if doc.anim.tracks.has(tk):
				rows.append({"t": "track", "track": tk, "kind": o[0], "id": o[1], "prop": prop, "label": LABELS[prop]})
				count += 1
		if count == 0:
			rows.append({"t": "empty"})
	return rows


static func row_height(row: Dictionary) -> float:
	return HEAD_H if row["t"] == "head" else ROW_H


## Верхние границы строк, последний элемент = полная высота.
static func row_tops(rows: Array) -> PackedFloat32Array:
	var tops := PackedFloat32Array([0.0])
	var y := 0.0
	for r in rows:
		y += row_height(r)
		tops.append(y)
	return tops


## Индекс строки на высоте y (в координатах содержимого) или -1.
static func row_at(tops: PackedFloat32Array, y: float) -> int:
	if y < 0.0 or tops.size() < 2 or y >= tops[tops.size() - 1]:
		return -1
	for i in tops.size() - 1:
		if y < tops[i + 1]:
			return i
	return -1


# ---------------- ключи ----------------

static func ref_key(track: String, frame: int) -> String:
	return "%s@%d" % [track, frame]


## Ключ под точкой p (область дорожек, содержимое): [track, frame] или []. Берётся ближайший по x.
static func key_at(rows: Array, tops: PackedFloat32Array, anim: RbAnimation, p: Vector2, scroll: float, ppf: float) -> Array:
	var i := row_at(tops, p.y)
	if i < 0 or rows[i]["t"] != "track":
		return []
	var tk: String = rows[i]["track"]
	var best := HIT_HALF + 0.001
	var out: Array = []
	for k in anim.keys_of(tk):
		var dx := absf(frame_x(float(k["f"]), scroll, ppf) - p.x)
		if dx <= best:
			best = dx
			out = [tk, int(k["f"])]
	return out


## Ключи, чьи значки пересекают прямоугольник (область дорожек, содержимое). Только строки дорожек.
static func refs_in_rect(rows: Array, tops: PackedFloat32Array, anim: RbAnimation, rect: Rect2, scroll: float, ppf: float) -> Array:
	var r := rect.abs()
	var out: Array = []
	for i in rows.size():
		if rows[i]["t"] != "track":
			continue
		if tops[i + 1] < r.position.y or tops[i] > r.end.y:
			continue
		var tk: String = rows[i]["track"]
		for k in anim.keys_of(tk):
			var cx := frame_x(float(k["f"]), scroll, ppf)
			if cx + KEY_HALF >= r.position.x and cx - KEY_HALF <= r.end.x:
				out.append([tk, int(k["f"])])
	return out


## Все ключи строки i.
static func refs_of_row(rows: Array, i: int, anim: RbAnimation) -> Array:
	var out: Array = []
	if i < 0 or i >= rows.size() or rows[i]["t"] != "track":
		return out
	var tk: String = rows[i]["track"]
	for k in anim.keys_of(tk):
		out.append([tk, int(k["f"])])
	return out


static func shifted(refs: Array, delta: int) -> Array:
	var out: Array = []
	for r in refs:
		out.append([r[0], int(r[1]) + delta])
	return out


## Сдвиг группы ключей так, чтобы она не вышла за 0..count-1.
static func move_delta_clamped(refs: Array, delta: int, count: int) -> int:
	if refs.is_empty():
		return 0
	var mn := 1 << 30
	var mx := -1
	for r in refs:
		mn = mini(mn, int(r[1]))
		mx = maxi(mx, int(r[1]))
	return clampi(delta, -mn, maxi(count - 1 - mx, 0))


## Общая интерполяция ключей или "", если они разные.
static func common_interp(anim: RbAnimation, refs: Array) -> String:
	var res := ""
	for r in refs:
		var idx := anim.key_index(r[0], int(r[1]))
		if idx < 0:
			continue
		var i := str(anim.tracks[r[0]][idx]["i"])
		if res == "":
			res = i
		elif res != i:
			return ""
	return res


# ---------------- буфер обмена ----------------

## Снимок ключей: [{track, df, v, i}], df = кадр минус самый ранний кадр набора.
static func copy_keys(anim: RbAnimation, refs: Array) -> Array:
	var found: Array = []
	var mn := 1 << 30
	for r in refs:
		var idx := anim.key_index(r[0], int(r[1]))
		if idx < 0:
			continue
		var k: Dictionary = anim.tracks[r[0]][idx]
		found.append([r[0], k])
		mn = mini(mn, int(k["f"]))
	var out: Array = []
	for f in found:
		out.append({"track": f[0], "df": int(f[1]["f"]) - mn, "v": f[1]["v"], "i": str(f[1]["i"])})
	return out


## Ключи для вставки на кадр at: [[track, frame, value, interp]]. Если буфер целиком из объектов
## того же вида, что target_kind, дорожки переезжают на target_id (скопировал с Головы, вставил на Тело).
## Кадры за пределами 0..count-1 отбрасываются.
static func paste_entries(clip: Array, at: int, target_kind: String, target_id: int, count: int) -> Array:
	var retarget := target_kind != "" and not clip.is_empty()
	for c in clip:
		if RbAnimation.parse(c["track"])[0] != target_kind:
			retarget = false
	var out: Array = []
	for c in clip:
		var f := at + int(c["df"])
		if f < 0 or f >= count:
			continue
		var tk: String = c["track"]
		if retarget:
			tk = RbAnimation.track_key(target_kind, target_id, RbAnimation.parse(tk)[2])
		out.append([tk, f, c["v"], c["i"]])
	return out
