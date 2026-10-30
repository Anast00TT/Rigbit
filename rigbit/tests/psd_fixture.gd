extends RefCounted
## Минимальный писатель PSD/PSB для тестов RbPsdReader (не часть приложения).
##
## Спека слоя (Dictionary), всё необязательно:
##   name: String (паскаль-имя), uname: String (блок luni), rect: Rect2i,
##   rgba: PackedByteArray w*h*4 | row: PackedByteArray w*4 (одна строка, повторяется на все строки),
##   comp: 0 raw | 1 RLE | 2 ZIP | 3 ZIP с предсказанием, alpha: bool (канал -1, по умолчанию да),
##   opacity: 0..255, blend: "norm", hidden: bool, clip: bool, fill: 0..255 (iOpa),
##   divider: 1|2|3 (lsct), divider_blend: "pass", mask: bool (канал -2 + данные маски),
##   rle_nop: bool (в начало каждой RLE-строки пустой заголовок 128),
##   tags: [[key, PackedByteArray]]
## opts: big (PSB), depth, mode (3 RGB, 1 Gray), merged: PackedByteArray (RGB или Gray w*h*каналы).

const MODE_GRAY := 1


static func build(w: int, h: int, layers: Array, opts := {}) -> PackedByteArray:
	var big: bool = opts.get("big", false)
	var mode: int = opts.get("mode", 3)
	var gray := mode == MODE_GRAY
	var n_color := 1 if gray else 3
	var out := PackedByteArray()
	_tag(out, "8BPS")
	_u16(out, 2 if big else 1)
	out.append_array(PackedByteArray([0, 0, 0, 0, 0, 0]))
	_u16(out, n_color)
	_u32(out, h)
	_u32(out, w)
	_u16(out, int(opts.get("depth", 8)))
	_u16(out, mode)
	_u32(out, 0)  # color mode data
	_u32(out, 0)  # image resources
	var li := PackedByteArray()
	if not layers.is_empty():
		_u16(li, layers.size())
		var chan := PackedByteArray()
		for spec: Dictionary in layers:
			_record(li, chan, spec, big, gray)
		li.append_array(chan)
		if li.size() % 2 == 1:
			li.append(0)
	var lm := PackedByteArray()
	_len(lm, li.size(), big)
	lm.append_array(li)
	_u32(lm, 0)  # global layer mask
	_len(out, lm.size(), big)
	out.append_array(lm)
	# сведённая картинка, raw
	_u16(out, 0)
	var merged: PackedByteArray = opts.get("merged", PackedByteArray())
	if merged.size() != w * h * n_color:
		merged = PackedByteArray()
		merged.resize(w * h * n_color)
		merged.fill(255)
	for c in n_color:
		for i in w * h:
			out.append(merged[i * n_color + c])
	return out


static func _record(li: PackedByteArray, chan: PackedByteArray, spec: Dictionary, big: bool, gray: bool) -> void:
	var rect: Rect2i = spec.get("rect", Rect2i())
	var w := rect.size.x
	var h := rect.size.y
	_u32(li, rect.position.y)
	_u32(li, rect.position.x)
	_u32(li, rect.end.y)
	_u32(li, rect.end.x)
	var comp: int = spec.get("comp", 0)
	var row_mode := spec.has("row")
	var src: PackedByteArray = spec.get("row", spec.get("rgba", PackedByteArray()))
	var ids: Array[int] = []
	if spec.get("alpha", true):
		ids.append(-1)
	if not spec.get("no_color", false):
		ids.append_array([0] if gray else [0, 1, 2])
	if spec.get("mask", false):
		ids.append(-2)
	_u16(li, ids.size())
	for id in ids:
		var payload := PackedByteArray()
		if id == -2:
			_u16(payload, 0)
			payload.append_array(PackedByteArray([255, 0, 255, 0]))  # маска 2x2
		else:
			var src_c := 3 if id == -1 else id
			var px := w if row_mode else w * h
			var plane := PackedByteArray()
			plane.resize(px)
			for i in px:
				var v := 0
				if src.size() >= (i + 1) * 4:
					v = src[i * 4 + src_c] if not gray or id == -1 else src[i * 4]
				plane[i] = v
			payload = _encode(plane, w, h, comp, big, row_mode, spec.get("rle_nop", false))
		_u16(li, id & 0xFFFF)
		_len(li, payload.size(), big)
		chan.append_array(payload)
	_tag(li, "8BIM")
	_tag(li, spec.get("blend", "norm"))
	li.append(int(spec.get("opacity", 255)))
	li.append(1 if spec.get("clip", false) else 0)
	li.append((2 if spec.get("hidden", false) else 0) | 8)
	li.append(0)
	var extra := PackedByteArray()
	if spec.get("mask", false):
		_u32(extra, 20)
		for v in [rect.position.y, rect.position.x, rect.position.y + 2, rect.position.x + 2]:
			_u32(extra, v)
		extra.append_array(PackedByteArray([0, 0, 0, 0]))
	else:
		_u32(extra, 0)
	_u32(extra, 0)  # blending ranges
	var nb := str(spec.get("name", "")).to_utf8_buffer()
	extra.append(nb.size())
	extra.append_array(nb)
	while (nb.size() + 1) % 4 != 0:
		extra.append(0)
		nb.append(0)
	if spec.has("uname"):
		var u := PackedByteArray()
		var s: String = spec["uname"]
		_u32(u, s.length())
		for i in s.length():
			_u16(u, s.unicode_at(i))
		_block(extra, "luni", u)
	if spec.has("divider"):
		var d := PackedByteArray()
		_u32(d, int(spec["divider"]))
		if spec.has("divider_blend"):
			_tag(d, "8BIM")
			_tag(d, spec["divider_blend"])
		_block(extra, "lsct", d)
	if spec.has("fill"):
		_block(extra, "iOpa", PackedByteArray([int(spec["fill"]), 0, 0, 0]))
	for t: Array in spec.get("tags", []):
		_block(extra, t[0], t[1])
	_u32(li, extra.size())
	li.append_array(extra)


static func _encode(plane: PackedByteArray, w: int, h: int, comp: int, big: bool, row_mode: bool, nop := false) -> PackedByteArray:
	var out := PackedByteArray()
	_u16(out, comp)
	match comp:
		0:
			if row_mode:
				for y in h:
					out.append_array(plane)
			else:
				out.append_array(plane)
		1:
			var rows: Array[PackedByteArray] = []
			if row_mode:
				var r := packbits(plane)
				for y in h:
					rows.append(r)
			else:
				for y in h:
					var r := packbits(plane.slice(y * w, (y + 1) * w))
					if nop:
						r.insert(0, 128)  # пустой заголовок PackBits, допустим по спецификации
					rows.append(r)
			for r in rows:
				if big:
					_u32(out, r.size())
				else:
					_u16(out, r.size())
			for r in rows:
				out.append_array(r)
		2, 3:
			var full := PackedByteArray()
			if row_mode:
				for y in h:
					full.append_array(plane)
			else:
				full = plane.duplicate()
			if comp == 3:
				for y in h:
					for x in range(w - 1, 0, -1):
						full[y * w + x] = (full[y * w + x] - full[y * w + x - 1]) & 255
			out.append_array(full.compress(FileAccess.COMPRESSION_DEFLATE))
	return out


## PackBits одной строки.
static func packbits(row: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var i := 0
	var n := row.size()
	while i < n:
		var j := i + 1
		while j < n and j - i < 128 and row[j] == row[i]:
			j += 1
		if j - i >= 2:
			out.append(257 - (j - i))
			out.append(row[i])
			i = j
			continue
		var k := i + 1
		while k < n and k - i < 128:
			if k + 2 < n and row[k] == row[k + 1] and row[k] == row[k + 2]:
				break
			k += 1
		out.append(k - i - 1)
		out.append_array(row.slice(i, k))
		i = k
	return out


static func _block(buf: PackedByteArray, key: String, body: PackedByteArray) -> void:
	_tag(buf, "8BIM")
	_tag(buf, key)
	var b := body.duplicate()
	if b.size() % 2 == 1:
		b.append(0)
	_u32(buf, b.size())
	buf.append_array(b)


static func _tag(buf: PackedByteArray, s: String) -> void:
	buf.append_array(s.to_ascii_buffer())


static func _u16(buf: PackedByteArray, v: int) -> void:
	buf.append((v >> 8) & 255)
	buf.append(v & 255)


static func _u32(buf: PackedByteArray, v: int) -> void:
	for s in [24, 16, 8, 0]:
		buf.append((v >> s) & 255)


static func _len(buf: PackedByteArray, v: int, big: bool) -> void:
	if big:
		_u32(buf, v >> 32)
	_u32(buf, v & 0xFFFFFFFF)
