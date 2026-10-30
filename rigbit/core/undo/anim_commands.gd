class_name RbAnimCommands
extends RefCounted
## Команды ключей. После любого изменения текущий кадр заново записывается в объекты.


## Ключ на кадре (автоключ в режиме Анимация). Шаги одного жеста склеиваются.
class SetKey extends RbCommand:
	var key: String
	var frame: int
	var value: Variant
	var interp: String
	var old_key: Dictionary = {}
	var _done_once := false

	func _init(track: String, f: int, v: Variant, i := "") -> void:
		label = "Ключ"
		key = track
		frame = f
		value = v
		interp = i

	func do_it(doc: RbDocument) -> void:
		# пустая интерполяция = оставить как есть у существующего ключа (иначе правка сбрасывала бы «ступеньку»)
		var prev := doc.anim.set_key(key, frame, value, interp)
		if not _done_once:
			old_key = prev
			_done_once = true
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")

	func undo_it(doc: RbDocument) -> void:
		if old_key.is_empty():
			doc.anim.remove_key(key, frame)
		else:
			doc.anim.set_key(key, frame, old_key["v"], str(old_key["i"]))
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")

	func merge(newer: RbCommand) -> bool:
		if newer is SetKey and newer.key == key and newer.frame == frame:
			value = newer.value
			return true
		return false


## Удалить набор ключей: [[track, frame], ...]
class RemoveKeys extends RbCommand:
	var refs: Array
	var removed: Array = []  # [[track, key_dict], ...]

	func _init(r: Array) -> void:
		label = "Удалить ключи"
		refs = r

	func do_it(doc: RbDocument) -> void:
		removed.clear()
		for r in refs:
			var k := doc.anim.remove_key(r[0], int(r[1]))
			if not k.is_empty():
				removed.append([r[0], k])
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")

	func undo_it(doc: RbDocument) -> void:
		for r in removed:
			doc.anim.set_key(r[0], int(r[1]["f"]), r[1]["v"], str(r[1]["i"]))
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")


## Сдвинуть набор ключей на delta кадров. Ключи, попавшие на занятые кадры, заменяют их (запоминаются).
class MoveKeys extends RbCommand:
	var refs: Array  # [[track, frame], ...]
	var delta: int
	var overwritten: Array = []

	func _init(r: Array, d: int) -> void:
		label = "Сдвинуть ключи"
		refs = r
		delta = d

	func do_it(doc: RbDocument) -> void:
		_shift(doc, refs, delta, true)

	func undo_it(doc: RbDocument) -> void:
		var moved: Array = []
		for r in refs:
			moved.append([r[0], int(r[1]) + delta])
		_shift(doc, moved, -delta, false)
		for o in overwritten:
			doc.anim.set_key(o[0], int(o[1]["f"]), o[1]["v"], str(o[1]["i"]))
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")

	func _shift(doc: RbDocument, list: Array, d: int, record: bool) -> void:
		var taken: Array = []
		for r in list:
			var k := doc.anim.remove_key(r[0], int(r[1]))
			if not k.is_empty():
				taken.append([r[0], k])
		if record:
			overwritten.clear()
		for t in taken:
			var nf := maxi(0, int(t[1]["f"]) + d)
			var prev := doc.anim.set_key(t[0], nf, t[1]["v"], str(t[1]["i"]))
			if record and not prev.is_empty():
				overwritten.append([t[0], prev])
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")


## Интерполяция ключей (пресет).
class SetInterp extends RbCommand:
	var refs: Array
	var interp: String
	var old: Array = []

	func _init(r: Array, i: String) -> void:
		label = "Интерполяция"
		refs = r
		interp = i

	func do_it(doc: RbDocument) -> void:
		old.clear()
		for r in refs:
			var idx := doc.anim.key_index(r[0], int(r[1]))
			if idx >= 0:
				var k: Dictionary = doc.anim.tracks[r[0]][idx]
				old.append(str(k["i"]))
				k["i"] = interp
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")

	func undo_it(doc: RbDocument) -> void:
		var j := 0
		for r in refs:
			var idx := doc.anim.key_index(r[0], int(r[1]))
			if idx >= 0 and j < old.size():
				doc.anim.tracks[r[0]][idx]["i"] = old[j]
				j += 1
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")


## Автоключ: SetKey плюс стартовый ключ на кадре 0, если дорожка была пустой и правка не на нулевом кадре.
## Так движение начинается из исходного значения, а не «с места правки». Один шаг истории.
class SetKeyAuto extends SetKey:
	var rest_value: Variant  # значение до правки
	var _added_rest := false

	func _init(track: String, f: int, v: Variant, rest: Variant, i := "") -> void:
		super(track, f, v, i)
		rest_value = rest

	func do_it(doc: RbDocument) -> void:
		_added_rest = frame > 0 and doc.anim.keys_of(key).is_empty()
		if _added_rest:
			doc.anim.set_key(key, 0, rest_value, "smooth")
		super.do_it(doc)

	func undo_it(doc: RbDocument) -> void:
		super.undo_it(doc)
		if _added_rest:
			doc.anim.remove_key(key, 0)
		if not doc.anim.tracks.has(key):
			# дорожки больше нет: apply_frame её не пишет, вернуть объекту прежнее значение вручную
			var p := RbAnimation.parse(key)
			match p[0]:
				"param":
					var prm := doc.params.get_param(p[1])
					if prm:
						prm.value = float(rest_value)
				"pin":
					var pin := doc.rig.find_pin(p[1])
					if not pin.is_empty():
						pin[String(p[2])] = rest_value
				_:
					var obj: Object = doc.rig.get_bone(p[1]) if p[0] == "bone" else doc.get_layer(p[1])
					if obj:
						obj.call("set_prop", p[2], rest_value)
		else:
			doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")


## Несколько автоключей одним шагом (IK двигает углы всей цепочки). Шаги одного жеста склеиваются.
class SetKeysAuto extends RbCommand:
	var subs: Array = []  # SetKeyAuto по дорожкам

	func _init(tracks: Array, f: int, values: Array, rests: Array) -> void:
		label = "Ключи"
		for i in tracks.size():
			subs.append(SetKeyAuto.new(tracks[i], f, values[i], rests[i]))

	func do_it(doc: RbDocument) -> void:
		for s in subs:
			s.do_it(doc)

	func undo_it(doc: RbDocument) -> void:
		for i in range(subs.size() - 1, -1, -1):
			subs[i].undo_it(doc)

	func merge(newer: RbCommand) -> bool:
		if not (newer is SetKeysAuto) or newer.subs.size() != subs.size():
			return false
		for i in subs.size():
			if newer.subs[i].key != subs[i].key or newer.subs[i].frame != subs[i].frame:
				return false
		for i in subs.size():
			subs[i].merge(newer.subs[i])
		return true


## Вставить набор ключей: [[track, frame, value, interp], ...]. Занятые кадры заменяются (запоминаются).
class PasteKeys extends RbCommand:
	var entries: Array
	var replaced: Array = []  # [[track, key_dict], ...]
	var created: Array = []  # [[track, frame], ...]

	func _init(e: Array) -> void:
		label = "Вставить ключи"
		entries = e

	func do_it(doc: RbDocument) -> void:
		replaced.clear()
		created.clear()
		for e in entries:
			var prev := doc.anim.set_key(e[0], int(e[1]), e[2], str(e[3]))
			if prev.is_empty():
				created.append([e[0], int(e[1])])
			else:
				replaced.append([e[0], prev])
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")

	func undo_it(doc: RbDocument) -> void:
		for c in created:
			doc.anim.remove_key(c[0], int(c[1]))
		for r in replaced:
			doc.anim.set_key(r[0], int(r[1]["f"]), r[1]["v"], str(r[1]["i"]))
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"keys")


## Длительность и частота кадров.
class SetTiming extends RbCommand:
	var frames: int
	var fps: int
	var old_frames := 0
	var old_fps := 0

	func _init(n: int, r: int) -> void:
		label = "Длительность"
		frames = n
		fps = r

	func do_it(doc: RbDocument) -> void:
		old_frames = doc.frame_count
		old_fps = doc.fps
		_apply_timing(doc, frames, fps)

	func undo_it(doc: RbDocument) -> void:
		_apply_timing(doc, old_frames, old_fps)

	func _apply_timing(doc: RbDocument, n: int, r: int) -> void:
		doc.frame_count = n
		doc.fps = r
		doc.current_frame = clampi(doc.current_frame, 0, n - 1)
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"timing")
