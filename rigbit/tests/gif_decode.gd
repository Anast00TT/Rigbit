extends RefCounted
## Минимальный декодер GIF для тестов (независим от энкодера: классический LZW-декодер).
## decode(bytes) -> {ok, error, width, height, loop (-1 нет расширения), global_palette, frames: [
##   {delay, disposal, transparent (индекс или -1), palette (RGB), indices, rgba (холст после кадра)} ]}


static func decode(b: PackedByteArray) -> Dictionary:
	var res := {"ok": false, "error": "", "frames": [], "loop": -1}
	if b.size() < 13 or b.slice(0, 6).get_string_from_ascii() != "GIF89a":
		res["error"] = "нет заголовка GIF89a"
		return res
	var w := b[6] | (b[7] << 8)
	var h := b[8] | (b[9] << 8)
	res["width"] = w
	res["height"] = h
	var flags := b[10]
	var p := 13
	var gpal := PackedByteArray()
	if flags & 0x80:
		var n := 1 << ((flags & 7) + 1)
		gpal = b.slice(p, p + n * 3)
		p += n * 3
	res["global_palette"] = gpal
	var canvas := PackedByteArray()
	canvas.resize(w * h * 4)  # прозрачный чёрный
	var gce := {"delay": 0, "disposal": 0, "transparent": -1}
	while p < b.size():
		var tag := b[p]
		p += 1
		if tag == 0x3B:
			res["ok"] = true
			return res
		elif tag == 0x21:
			var label := b[p]
			p += 1
			if label == 0xF9:
				var pk := b[p + 1]
				gce = {"delay": b[p + 2] | (b[p + 3] << 8), "disposal": (pk >> 2) & 7,
					"transparent": b[p + 4] if (pk & 1) else -1}
			elif label == 0xFF:
				var app := b.slice(p + 1, p + 12).get_string_from_ascii()
				if app == "NETSCAPE2.0" and b[p + 12] == 3 and b[p + 13] == 1:
					res["loop"] = b[p + 14] | (b[p + 15] << 8)
			# пропустить подблоки
			var sz := b[p]
			while sz != 0:
				p += sz + 1
				sz = b[p]
			p += 1
		elif tag == 0x2C:
			var fx := b[p] | (b[p + 1] << 8)
			var fy := b[p + 2] | (b[p + 3] << 8)
			var fw := b[p + 4] | (b[p + 5] << 8)
			var fh := b[p + 6] | (b[p + 7] << 8)
			var pk2 := b[p + 8]
			p += 9
			var pal := gpal
			if pk2 & 0x80:
				var n2 := 1 << ((pk2 & 7) + 1)
				pal = b.slice(p, p + n2 * 3)
				p += n2 * 3
			var mcs := b[p]
			p += 1
			var data := PackedByteArray()
			var sz2 := b[p]
			while sz2 != 0:
				data.append_array(b.slice(p + 1, p + 1 + sz2))
				p += sz2 + 1
				sz2 = b[p]
			p += 1
			var idx := _lzw_decode(data, mcs, fw * fh)
			if idx.size() != fw * fh:
				res["error"] = "LZW: получено %d пикселей из %d" % [idx.size(), fw * fh]
				return res
			var prev_canvas := canvas.duplicate()
			var tr: int = gce["transparent"]
			for y in fh:
				for x in fw:
					var ci := idx[y * fw + x]
					if ci == tr:
						continue
					var o := ((fy + y) * w + fx + x) * 4
					canvas[o] = pal[ci * 3]
					canvas[o + 1] = pal[ci * 3 + 1]
					canvas[o + 2] = pal[ci * 3 + 2]
					canvas[o + 3] = 255
			(res["frames"] as Array).append({"delay": gce["delay"], "disposal": gce["disposal"], "transparent": tr,
				"palette": pal, "indices": idx, "rgba": canvas.duplicate(), "rect": Rect2i(fx, fy, fw, fh)})
			var disp: int = gce["disposal"]
			if disp == 2:
				for y in fh:
					for x in fw:
						var o2 := ((fy + y) * w + fx + x) * 4
						canvas[o2] = 0
						canvas[o2 + 1] = 0
						canvas[o2 + 2] = 0
						canvas[o2 + 3] = 0
			elif disp == 3:
				canvas = prev_canvas
			gce = {"delay": 0, "disposal": 0, "transparent": -1}
		else:
			res["error"] = "неизвестный блок 0x%02x на %d" % [tag, p - 1]
			return res
	res["error"] = "нет трейлера"
	return res


static func _lzw_decode(data: PackedByteArray, mcs: int, expect: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(expect)
	var o := 0
	var clear := 1 << mcs
	var eoi := clear + 1
	var prefix := PackedInt32Array()
	prefix.resize(4096)
	var suffix := PackedByteArray()
	suffix.resize(4096)
	for i in clear:
		suffix[i] = i
	var next := eoi + 1
	var size := mcs + 1
	var prev := -1
	var first := 0
	var bitpos := 0
	var total_bits := data.size() * 8
	var stack := PackedByteArray()
	while bitpos + size <= total_bits:
		var code := 0
		for k in size:
			var bp := bitpos + k
			code |= ((data[bp >> 3] >> (bp & 7)) & 1) << k
		bitpos += size
		if code == clear:
			next = eoi + 1
			size = mcs + 1
			prev = -1
			continue
		if code == eoi:
			break
		if prev == -1:
			if code >= clear:
				return out.slice(0, o)
			if o < expect:
				out[o] = code
				o += 1
			prev = code
			first = code
			continue
		var cur := code
		stack.clear()
		if code >= next:
			if code != next:
				return out.slice(0, o)
			stack.append(first)
			cur = prev
		while cur >= clear:
			stack.append(suffix[cur])
			cur = prefix[cur]
		first = cur
		stack.append(cur)
		for k in range(stack.size() - 1, -1, -1):
			if o < expect:
				out[o] = stack[k]
				o += 1
		if next < 4096:
			prefix[next] = prev
			suffix[next] = first
			next += 1
			if next == (1 << size) and size < 12:
				size += 1
		prev = code
	return out.slice(0, o)
