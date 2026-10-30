class_name RbPsdReader
extends RefCounted
## Чтение PSD/PSB в дерево слоёв. Ядро, без UI и без зависимости от RbDocument.
## Поддержано: PSD (v1) и PSB (v2), 8 бит, RGB и Grayscale, сжатие raw/RLE/ZIP/ZIP с предсказанием,
## группы (lsct/lsdk), юникод-имена (luni), fill opacity (iOpa), флаги видимости и обтравки.
## Маски слоёв читаются мимо (не применяются). Корректирующие слои и слои-заливки пропускаются.
## Ошибки и предупреждения: строки-ключи локализации, подробности через ": " (например "PSD_WARN_BLEND: diss (Слой 1)").
##
## Результат read_*: { ok, error, width, height, nodes, warnings }.
## nodes: дерево снизу вверх (индекс 0 рисуется первым), как RbDocument.root.
## Узел: { name, kind: "image"|"group", visible, opacity 0..1, blend, rect: Rect2i (px холста),
##         image: Image RGBA8 по rect (только image), children (только group), clipped }.

const BLEND_MAP := {
	"norm": "normal", "pass": "normal", "mul ": "multiply", "scrn": "screen", "lddg": "add", "over": "overlay",
}
## Ключи доп. блоков корректирующих слоёв и слоёв-заливок: такие слои пропускаем.
const ADJUSTMENT_KEYS := [
	"SoCo", "GdFl", "PtFl", "brit", "levl", "curv", "expA", "vibA", "hue ", "hue2", "blnc", "blwh",
	"phfl", "mixr", "clrL", "nvrt", "post", "thrs", "selc", "grdm",
]
## В PSB у этих доп. блоков длина записана 8 байтами.
const BIG_KEYS := [
	"LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD", "lnkE",
]
const MODE_GRAY := 1
const MODE_RGB := 3
const DIVIDER_NONE := -1
const DIVIDER_END := 3  # нижний маркер группы "</Layer group>"
const REP_BLOCK := 1024  # длина заготовок для повторов RLE
const MAX_THREADS := 4
const SHORT_RUN := 8  # короткие серии в запасном RLE копируем по байту, это дешевле среза


static func read_file(path: String, threaded: bool = true) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _fail(_empty_result(), "PSD_ERR_READ")
	var data := f.get_buffer(f.get_length())
	f.close()
	return read_bytes(data, path.get_file().get_basename(), threaded)


## name_hint: имя единственного слоя, если в файле нет слоёв (только сведённая картинка).
## threaded: декодировать слои параллельно через WorkerThreadPool.
static func read_bytes(data: PackedByteArray, name_hint: String = "", threaded: bool = true) -> Dictionary:
	var res := _empty_result()
	var b := _Buf.new(data)
	if data.size() < 26 or b.tag() != "8BPS":
		return _fail(res, "PSD_ERR_SIGNATURE")
	var version := b.u16()
	if version != 1 and version != 2:
		return _fail(res, "PSD_ERR_VERSION")
	b.big = version == 2
	b.p += 6
	var n_channels := b.u16()
	var height := b.u32()
	var width := b.u32()
	var depth := b.u16()
	var mode := b.u16()
	res["width"] = width
	res["height"] = height
	if mode != MODE_RGB and mode != MODE_GRAY:
		return _fail(res, "PSD_ERR_MODE")
	if depth != 8:
		return _fail(res, "PSD_ERR_DEPTH")
	b.p += b.u32()  # color mode data
	b.p += b.u32()  # image resources
	var lm_len := b.length()
	var lm_end := b.p + lm_len
	if b.bad or lm_end > data.size():
		return _fail(res, "PSD_ERR_CORRUPT")

	var warns: Array[String] = res["warnings"]
	var records: Array = []
	if lm_len > 0:
		var li_len := b.length()
		var li_end := b.p + li_len
		if li_len > 0 and li_end <= lm_end:
			records = _parse_layer_info(b, li_end, warns)
		b.p = li_end
		if records.is_empty() and b.p + 4 <= lm_end:
			records = _layers_from_global_tags(b, lm_end, warns)
		if b.bad:
			return _fail(res, "PSD_ERR_CORRUPT")

	var dec := _Decoder.new(data, b.big, mode == MODE_GRAY)
	var nodes: Array = []
	if records.is_empty():
		var node := _merged_node(dec, lm_end, width, height, n_channels, name_hint)
		if node.is_empty():
			return _fail(res, "PSD_ERR_COMPRESSION")
		nodes.append(node)
		warns.append("PSD_WARN_FLATTENED")
	else:
		nodes = _build_tree(records, dec, warns)

	dec.run_all(threaded)
	for job: Dictionary in dec.jobs:
		if job.has("warning"):
			warns.append(job["warning"])
	nodes = _finish(nodes)
	if not _has_images(nodes):
		return _fail(res, "PSD_ERR_EMPTY")
	res["nodes"] = nodes
	res["ok"] = true
	return res


static func _empty_result() -> Dictionary:
	var warns: Array[String] = []
	return {"ok": false, "error": "", "width": 0, "height": 0, "nodes": [], "warnings": warns}


static func _fail(res: Dictionary, err: String) -> Dictionary:
	res["ok"] = false
	res["error"] = err
	res["nodes"] = []
	return res


# --- секция слоёв -------------------------------------------------------------------------------

## b.p стоит на счётчике слоёв. Возвращает записи слоёв в порядке файла (снизу вверх)
## с посчитанными смещениями данных каналов.
static func _parse_layer_info(b: _Buf, end: int, warns: Array[String]) -> Array:
	var count := absi(b.i16())
	var recs: Array = []
	for i in count:
		var rec := _parse_record(b)
		if b.bad or b.p > end:
			warns.append("PSD_WARN_CORRUPT")
			b.bad = false
			return []
		recs.append(rec)
	for rec: Dictionary in recs:
		for ch: Dictionary in rec["channels"]:
			ch["off"] = b.p
			b.p += int(ch["len"])
	if b.p > end:
		warns.append("PSD_WARN_CORRUPT")  # битые хвосты отсеются проверкой границ при декодировании
	return recs


static func _parse_record(b: _Buf) -> Dictionary:
	var rec := {
		"name": "", "blend": "norm", "opacity": 255, "clip": 0, "flags": 0, "fill": 255,
		"divider": DIVIDER_NONE, "divider_blend": "", "adjustment": "", "channels": [],
	}
	var top := b.i32()
	var left := b.i32()
	var bottom := b.i32()
	var right := b.i32()
	rec["rect"] = Rect2i(left, top, maxi(0, right - left), maxi(0, bottom - top))
	var n_ch := b.u16()
	var chans: Array = []
	for c in n_ch:
		var cid := b.i16()
		var clen := b.length()
		chans.append({"id": cid, "len": clen, "off": 0})
	rec["channels"] = chans
	if b.tag() != "8BIM":
		b.bad = true
		return rec
	rec["blend"] = b.tag()
	rec["opacity"] = b.u8()
	rec["clip"] = b.u8()
	rec["flags"] = b.u8()
	b.p += 1
	var extra_len := b.u32()
	var extra_end := b.p + extra_len
	if b.bad or extra_end > b.d.size():
		b.bad = true
		return rec
	b.p += b.u32()  # данные маски слоя (длина бывает 0, 20, 36+)
	b.p += b.u32()  # blending ranges
	var name_start := b.p
	var name_len := b.u8()
	rec["name"] = _decode_pascal(b.bytes(name_len))
	b.p = name_start + ((name_len + 1 + 3) & ~3)  # паскаль-строка выровнена на 4
	if not b.at_sig():
		for alt in [name_start + 1 + name_len, name_start + ((name_len + 2) & ~1)]:
			if alt < extra_end and b.sig_at(alt):
				b.p = alt
				break
	while b.p + 12 <= extra_end and b.at_sig():
		b.p += 4
		var key := b.tag()
		var blen := b.u64() if b.big and BIG_KEYS.has(key) else b.u32()
		var body := b.p
		if body + blen > extra_end:
			break
		match key:
			"luni":
				var uname := _decode_luni(b.d, body, blen)
				if uname != "":
					rec["name"] = uname
			"lsct", "lsdk":
				if blen >= 4:
					rec["divider"] = b.u32()
				if blen >= 12 and b.tag() == "8BIM":
					rec["divider_blend"] = b.tag()
			"iOpa":
				if blen >= 1:
					rec["fill"] = b.u8()
			_:
				if ADJUSTMENT_KEYS.has(key):
					rec["adjustment"] = key
		b.p = body + blen
		b.align_to_sig(extra_end)
	b.p = extra_end
	return rec


## Слои в доп. блоке 'Layr' в конце секции (бывает, когда основной блок пуст).
static func _layers_from_global_tags(b: _Buf, end: int, warns: Array[String]) -> Array:
	b.p += b.u32()  # global layer mask info
	b.align_to_sig(end)
	while b.p + 12 <= end and b.at_sig():
		b.p += 4
		var key := b.tag()
		var blen := b.u64() if b.big and BIG_KEYS.has(key) else b.u32()
		var body := b.p
		if b.bad or body + blen > end:
			break
		if key == "Layr" and blen > 0:
			return _parse_layer_info(b, body + blen, warns)
		b.p = body + blen
		b.align_to_sig(end)
	return []


# --- дерево ------------------------------------------------------------------------------------

static func _build_tree(records: Array, dec: _Decoder, warns: Array[String]) -> Array:
	var stack: Array = [[]]
	var seen_blend := {}
	var clip_warned := false
	for rec: Dictionary in records:
		var div: int = rec["divider"]
		if div == DIVIDER_END:
			stack.append([])
			continue
		var is_group := div == 1 or div == 2
		if not is_group:
			if rec["adjustment"] != "":
				warns.append("PSD_WARN_ADJUSTMENT: %s" % rec["name"])
				continue
			if not (rec["rect"] as Rect2i).has_area():
				continue
		var node := {
			"name": rec["name"], "kind": "group" if is_group else "image",
			"visible": (int(rec["flags"]) & 2) == 0,
			"opacity": float(rec["opacity"]) / 255.0 * float(rec["fill"]) / 255.0,
			"clipped": int(rec["clip"]) != 0, "rect": rec["rect"],
		}
		var key: String = rec["blend"]
		if is_group and rec["divider_blend"] != "":
			key = rec["divider_blend"]
		node["blend"] = BLEND_MAP.get(key, "normal")
		if not BLEND_MAP.has(key) and not seen_blend.has(key):
			seen_blend[key] = true
			warns.append("PSD_WARN_BLEND: %s (%s)" % [key.strip_edges(), rec["name"]])
		if node["clipped"] and not clip_warned:
			clip_warned = true
			warns.append("PSD_WARN_CLIPPING")
		if is_group:
			node["children"] = stack.pop_back() if stack.size() > 1 else []
			stack.back().append(node)
			continue
		var job := dec.layer_job(rec, node)
		if job.is_empty():
			warns.append("PSD_WARN_NO_PIXELS: %s" % rec["name"])
			continue
		stack.back().append(node)
	while stack.size() > 1:  # незакрытые группы: детей наверх
		var kids: Array = stack.pop_back()
		stack.back().append_array(kids)
	return stack[0]


static func _merged_node(dec: _Decoder, at: int, w: int, h: int, n_channels: int, name_hint: String) -> Dictionary:
	var b := _Buf.new(dec.data)
	b.big = dec.big
	b.p = at
	var comp := b.u16()
	var n_color := 1 if dec.gray else 3
	if b.bad or n_channels < n_color or w <= 0 or h <= 0:
		return {}
	var node := {
		"name": name_hint if name_hint != "" else "PSD", "kind": "image", "visible": true, "opacity": 1.0,
		"blend": "normal", "clipped": false, "rect": Rect2i(0, 0, w, h),
	}
	var planes: Array = []
	var n := w * h
	if comp == 0:
		for c in n_color:
			var off := b.p + c * n
			planes.append({"c": c, "comp": 0, "body": off, "end": off + n})
	elif comp == 1:
		var cs := 4 if dec.big else 2
		var start := b.p + n_channels * h * cs
		for c in n_channels:
			var total := 0
			for y in h:
				total += b.u32() if dec.big else b.u16()
			if c < n_color:
				planes.append({"c": c, "comp": 1, "body": start, "end": start + total})
			start += total
		if b.bad:
			return {}
	else:
		return {}
	dec.jobs.append({"node": node, "w": w, "h": h, "planes": planes, "name": node["name"]})
	return node


## Убрать слои, которые не декодировались; посчитать рамки групп.
static func _finish(nodes: Array) -> Array:
	var out: Array = []
	for nd: Dictionary in nodes:
		if nd["kind"] == "group":
			var kids := _finish(nd["children"])
			nd["children"] = kids
			var r := Rect2i()
			for c: Dictionary in kids:
				var cr: Rect2i = c["rect"]
				if not cr.has_area():
					continue
				r = cr if not r.has_area() else r.merge(cr)
			nd["rect"] = r
			out.append(nd)
		elif nd.has("image"):
			out.append(nd)
	return out


static func _has_images(nodes: Array) -> bool:
	for nd: Dictionary in nodes:
		if nd["kind"] == "image" or _has_images(nd["children"]):
			return true
	return false


# --- имена -------------------------------------------------------------------------------------

static func _decode_luni(d: PackedByteArray, at: int, blen: int) -> String:
	if blen < 4:
		return ""
	var count := (d[at] << 24) | (d[at + 1] << 16) | (d[at + 2] << 8) | d[at + 3]
	count = mini(count, (blen - 4) >> 1)
	var s := ""
	var p := at + 4
	var i := 0
	while i < count:
		var u := (d[p] << 8) | d[p + 1]
		p += 2
		i += 1
		if u >= 0xD800 and u <= 0xDBFF and i < count:
			var lo := (d[p] << 8) | d[p + 1]
			if lo >= 0xDC00 and lo <= 0xDFFF:
				p += 2
				i += 1
				u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
		if u == 0:
			break
		s += String.chr(u)
	return s


## Паскаль-имя: UTF-8, если байты валидны, иначе latin1.
static func _decode_pascal(raw: PackedByteArray) -> String:
	var nul := raw.find(0)
	if nul >= 0:
		raw = raw.slice(0, nul)
	if _is_utf8(raw):
		return raw.get_string_from_utf8()
	var s := ""
	for c in raw:
		s += String.chr(c)
	return s


static func _is_utf8(raw: PackedByteArray) -> bool:
	var i := 0
	var n := raw.size()
	while i < n:
		var c := raw[i]
		var extra := 0
		if c < 0x80:
			extra = 0
		elif c >= 0xC2 and c <= 0xDF:
			extra = 1
		elif c >= 0xE0 and c <= 0xEF:
			extra = 2
		elif c >= 0xF0 and c <= 0xF4:
			extra = 3
		else:
			return false
		if i + extra >= n and extra > 0:
			return false
		for k in extra:
			if (raw[i + 1 + k] & 0xC0) != 0x80:
				return false
		i += 1 + extra
	return true


# --- чтение байтов (big-endian) ----------------------------------------------------------------

class _Buf:
	extends RefCounted
	var d: PackedByteArray
	var p: int = 0
	var big: bool = false
	var bad: bool = false

	func _init(data: PackedByteArray) -> void:
		d = data

	func _need(n: int) -> bool:
		if p < 0 or p + n > d.size():
			bad = true
			return false
		return true

	func u8() -> int:
		if not _need(1):
			return 0
		p += 1
		return d[p - 1]

	func u16() -> int:
		if not _need(2):
			return 0
		p += 2
		return (d[p - 2] << 8) | d[p - 1]

	func i16() -> int:
		var v := u16()
		return v - 65536 if v >= 32768 else v

	func u32() -> int:
		if not _need(4):
			return 0
		p += 4
		return (d[p - 4] << 24) | (d[p - 3] << 16) | (d[p - 2] << 8) | d[p - 1]

	func i32() -> int:
		var v := u32()
		return v - 4294967296 if v >= 2147483648 else v

	func u64() -> int:
		var hi := u32()
		var lo := u32()
		return (hi << 32) | lo

	## Длина: 8 байт в PSB, 4 в PSD.
	func length() -> int:
		return u64() if big else u32()

	func tag() -> String:
		if not _need(4):
			return ""
		p += 4
		return d.slice(p - 4, p).get_string_from_ascii()

	func bytes(n: int) -> PackedByteArray:
		if not _need(n):
			return PackedByteArray()
		p += n
		return d.slice(p - n, p)

	func sig_at(at: int) -> bool:
		if at < 0 or at + 4 > d.size():
			return false
		# '8BIM' или '8B64'
		if d[at] != 0x38 or d[at + 1] != 0x42:
			return false
		return (d[at + 2] == 0x49 and d[at + 3] == 0x4D) or (d[at + 2] == 0x36 and d[at + 3] == 0x34)

	func at_sig() -> bool:
		return sig_at(p)

	## После доп. блока: если сигнатуры нет, попробовать выравнивание на 2 и 4.
	func align_to_sig(end: int) -> void:
		if p >= end or at_sig():
			return
		for a in [(p + 1) & ~1, (p + 3) & ~3]:
			if a + 4 <= end and sig_at(a):
				p = a
				return


# --- декодирование пикселей ---------------------------------------------------------------------

## Декодер слоёв. Задачи (jobs) готовятся в главном потоке, run() можно звать из потоков:
## общие данные только читаются, каждая задача пишет лишь в свой словарь.
class _Decoder:
	extends RefCounted
	var data: PackedByteArray
	var big: bool
	var gray: bool
	var jobs: Array = []
	var rep: Array = []  # rep[v] = REP_BLOCK байт со значением v

	func _init(d: PackedByteArray, is_big: bool, is_gray: bool) -> void:
		data = d
		big = is_big
		gray = is_gray

	## Задача на слой; пустой словарь, если у слоя нет цветовых каналов.
	func layer_job(rec: Dictionary, node: Dictionary) -> Dictionary:
		var rect: Rect2i = rec["rect"]
		var w := rect.size.x
		var h := rect.size.y
		var planes: Array = []
		var has_color := false
		var broken := false
		for ch: Dictionary in rec["channels"]:
			var cid: int = ch["id"]
			var c := -1
			if cid == -1:
				c = 3
			elif cid >= 0 and cid < (1 if gray else 3):
				c = cid
				has_color = true
			if c < 0:
				continue  # маски (-2, -3) и лишние каналы пропускаем
			var off: int = ch["off"]
			var clen: int = ch["len"]
			if clen < 2 or off + clen > data.size():
				broken = true
				continue
			var comp := (data[off] << 8) | data[off + 1]
			var body := off + 2
			if comp == 1:
				body += h * (4 if big else 2)
			planes.append({"c": c, "comp": comp, "body": body, "end": off + clen})
		if not has_color:
			return {}
		var job := {"node": node, "w": w, "h": h, "planes": planes, "name": rec["name"]}
		if broken:
			job["broken"] = true
		jobs.append(job)
		return job

	func run_all(threaded: bool) -> void:
		if rep.is_empty():  # заготовки для запасного RLE, строятся до потоков
			for v in 256:
				var blk := PackedByteArray()
				blk.resize(REP_BLOCK)
				blk.fill(v)
				rep.append(blk)
		if jobs.is_empty():
			return
		if threaded and jobs.size() > 1 and OS.get_processor_count() > 1:
			# не больше MAX_THREADS потоков: на телефоне каждый крупный слой держит в памяти ~12 байт на пиксель
			var tasks := mini(MAX_THREADS, OS.get_processor_count())
			var tid := WorkerThreadPool.add_group_task(run, jobs.size(), tasks, true, "psd decode")
			WorkerThreadPool.wait_for_group_task_completion(tid)
		else:
			for i in jobs.size():
				run(i)

	func run(i: int) -> void:
		var job: Dictionary = jobs[i]
		var w: int = job["w"]
		var h: int = job["h"]
		if job.has("broken"):
			job["warning"] = "PSD_WARN_CORRUPT_LAYER: %s" % job["name"]
			return
		var decoded := {}
		for pl: Dictionary in job["planes"]:
			var img := decode_channel(pl["comp"], pl["body"], pl["end"], w, h)
			if img == null:
				var comp: int = pl["comp"]
				job["warning"] = ("PSD_WARN_COMPRESSION: %s" if comp >= 2 else "PSD_WARN_CORRUPT_LAYER: %s") % job["name"]
				return
			decoded[pl["c"]] = img
		job["node"]["image"] = assemble(decoded, w, h)

	## Каналы (c -> Image L8 или RGBA8 вида l,l,l,255) -> RGBA8.
	## Первый цвет разворачивается в RGBA конвертацией, остальные каналы вписываются столбцами
	## blit_rect в ту же память, видимую как L8 шириной 4w. В разы быстрее побайтового цикла в GDScript.
	func assemble(planes: Dictionary, w: int, h: int) -> Image:
		var base: Image = planes[0]
		if base.get_format() != Image.FORMAT_RGBA8:
			base.convert(Image.FORMAT_RGBA8)
		var wide := Image.create_from_data(w * 4, h, false, Image.FORMAT_L8, base.get_data())
		planes.erase(0)
		base = null
		var targets: Array = [3] if gray else [1, 2, 3]
		for c: int in targets:
			var src: Image = planes.get(c)
			if src == null:
				if c == 3:
					continue  # нет канала прозрачности: альфа уже 255
				src = Image.create_empty(w, h, false, Image.FORMAT_L8)
			elif src.get_format() != Image.FORMAT_L8:
				src.convert(Image.FORMAT_L8)
			var col := Rect2i(0, 0, 1, h)
			var dst := Vector2i(c, 0)
			for x in w:
				col.position.x = x
				dst.x = x * 4 + c
				wide.blit_rect(src, col, dst)
			planes.erase(c)
		return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, wide.get_data())

	## Один канал как Image (L8 или RGBA8 с серым в RGB). null = не вышло.
	func decode_channel(comp: int, body: int, end: int, w: int, h: int) -> Image:
		if comp == 1 and w <= 65535 and h <= 65535:
			var img := unpack_bits_tga(body, mini(end, data.size()), w, h)
			if img != null:
				return img
		var plane := decode_plane(comp, body, end, w, h)
		if plane.is_empty():
			return null
		return Image.create_from_data(w, h, false, Image.FORMAT_L8, plane)

	## Один канал w*h байт. Пустой массив = не вышло.
	func decode_plane(comp: int, body: int, end: int, w: int, h: int) -> PackedByteArray:
		var n := w * h
		end = mini(end, data.size())
		if body > end:
			return PackedByteArray()
		match comp:
			0:
				var raw := data.slice(body, mini(end, body + n))
				if raw.size() < n:
					raw.resize(n)
				return raw
			1:
				return unpack_bits(body, end, n)
			2, 3:
				var z := data.slice(body, end).decompress(n, FileAccess.COMPRESSION_DEFLATE)
				if z.size() != n:
					return PackedByteArray()
				if comp == 3:
					for y in h:
						var row := y * w
						for x in range(1, w):
							z[row + x] = (z[row + x] + z[row + x - 1]) & 255
				return z
		return PackedByteArray()

	## PackBits через встроенный загрузчик TGA: литералы у TGA RLE те же, что в PackBits,
	## а заголовок повтора 257-n переписывается в 0x80|(n-1) = 384-hdr. В GDScript остаётся только
	## проход по заголовкам серий, сама распаковка нативная. Выход RGBA8 (l,l,l,255). null = не вышло.
	func unpack_bits_tga(p: int, end: int, w: int, h: int) -> Image:
		var buf := PackedByteArray([0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, w & 255, w >> 8, h & 255, h >> 8, 8, 0x20])
		buf.append_array(data.slice(p, end))
		var q := 18
		var e := buf.size()
		while q < e:
			var hdr: int = buf[q]
			if hdr < 128:
				q += hdr + 2
			elif hdr > 128:
				buf[q] = 384 - hdr
				q += 2
			else:
				return null  # пустой заголовок 128: в TGA его нет, пусть разбирает медленный путь
		if q != e:
			return null  # обрезанная серия в конце
		buf.resize(e + 64)  # загрузчик TGA не берёт буфер короче своей структуры заголовка; хвост он не читает
		var img := Image.new()
		if img.load_tga_from_buffer(buf) != OK or img.get_width() != w or img.get_height() != h:
			return null
		return img

	## PackBits на GDScript (запасной путь). Длинные серии кусками (append_array), короткие по байту,
	## подряд идущие повторы одного значения склеиваются, нули добавляются через resize.
	func unpack_bits(p: int, end: int, n: int) -> PackedByteArray:
		var src := data
		var blocks := rep
		var out := PackedByteArray()
		while p < end:
			var hdr: int = src[p]
			if hdr < 128:
				var q := mini(p + 2 + hdr, end)
				if hdr < SHORT_RUN:
					for k in range(p + 1, q):
						out.append(src[k])
				else:
					out.append_array(src.slice(p + 1, q))
				p = q
			elif hdr > 128:
				if p + 1 >= end:
					break
				var v: int = src[p + 1]
				var cnt := 257 - hdr
				p += 2
				while p + 1 < end and src[p] > 128 and src[p + 1] == v:
					cnt += 257 - src[p]
					p += 2
				if cnt <= SHORT_RUN:
					for k in cnt:
						out.append(v)
				elif v == 0:
					out.resize(out.size() + cnt)
				else:
					var blk: PackedByteArray = blocks[v]
					while cnt >= REP_BLOCK:
						out.append_array(blk)
						cnt -= REP_BLOCK
					if cnt > 0:
						out.append_array(blk.slice(0, cnt))
			else:
				p += 1
			if out.size() >= n:
				break
		if out.size() != n:
			out.resize(n)
		return out
