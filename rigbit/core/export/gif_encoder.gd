class_name RbGifEncoder
extends RefCounted
## GIF89a-энкодер на чистом GDScript. Без Variant в горячих циклах: только Packed*Array и int.
## Палитра: median cut по гистограмме 5-5-5 (с подвыборкой пикселей), общая на все кадры
## или своя на каждый кадр. Прозрачность: alpha < alpha_threshold -> индекс 0, диспоз 2.
## Дизеринг: упорядоченный Bayer 4x4 (по желанию).
## Задержка кадра в сотых секунды, ошибка округления копится (24 fps = 4,2,4,4,2,4...).
##
## var enc := RbGifEncoder.new(); enc.dither = true
## var bytes := enc.encode(frames, 24.0)   # frames: Array[Image] одного размера

enum Transparency { AUTO, OFF, ON }

var dither := false
var per_frame_palette := false
## 0 = бесконечный цикл (NETSCAPE2.0), N = повторить N раз
var loop_count := 0
## Максимум цветов палитры без индекса прозрачности (до 255; без прозрачности можно 256).
var max_colors := 255
var transparency: Transparency = Transparency.AUTO
var alpha_threshold := 128
## Сила дизеринга в единицах 0..255 (размах шума)
var dither_spread := 28
## Время этапов последнего encode(), мс: palette, quant, lzw, total; и размер
var last_stats := {}

const HIST := 32768  # 5-5-5
const PAD := 32
const BAYER := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

var _lut := PackedInt32Array()  # ключ 5-5-5 -> индекс палитры, -1 неизвестно
var _pal := PackedByteArray()  # RGB, 3 байта на запись, размер = (1<<bits)*3
var _cbase := 0  # первый индекс цветов (1, если индекс 0 прозрачный)
var _ccount := 0  # сколько цветов
var _bits := 1  # log2 размера таблицы
var _table := PackedInt32Array()  # LZW: (gen<<12)|code по (prefix<<mcs)|sym
var _gen := 1
var _dith_off := PackedInt32Array()  # 16 смещений Bayer
var _tr := PackedInt32Array()  # значение с шумом -> вклад канала в ключ (со сдвигом PAD)
var _tg := PackedInt32Array()
var _tb := PackedInt32Array()


static func encode_frames(frames: Array, fps: float, opts := {}) -> PackedByteArray:
	var e := RbGifEncoder.new()
	for k in opts:
		e.set(k, opts[k])
	return e.encode(frames, fps)


func encode(frames: Array, fps: float) -> PackedByteArray:
	var t0 := Time.get_ticks_usec()
	var out := PackedByteArray()
	last_stats = {"palette_ms": 0.0, "quant_ms": 0.0, "lzw_ms": 0.0}
	if frames.is_empty():
		push_error("RbGifEncoder: нет кадров")
		return out
	var w := 0
	var h := 0
	var datas: Array[PackedByteArray] = []
	var any_alpha := false
	for f: Image in frames:
		var img := f
		if img.get_format() != Image.FORMAT_RGBA8:
			img = f.duplicate()
			img.convert(Image.FORMAT_RGBA8)
		if w == 0:
			w = img.get_width()
			h = img.get_height()
		elif img.get_width() != w or img.get_height() != h:
			push_error("RbGifEncoder: кадры разного размера")
			return out
		if transparency == Transparency.AUTO and not any_alpha and img.detect_alpha() != Image.ALPHA_NONE:
			any_alpha = true
		datas.append(img.get_data())
	var has_alpha := any_alpha if transparency == Transparency.AUTO else transparency == Transparency.ON
	var thr := alpha_threshold if has_alpha else 0
	_cbase = 1 if has_alpha else 0
	var ncol := clampi(max_colors, 1, 256 - _cbase)
	if w <= 0 or h <= 0 or w > 65535 or h > 65535:
		push_error("RbGifEncoder: плохой размер кадра")
		return out
	_prepare_tables()
	if _table.size() != (4096 << 8):
		_table.resize(4096 << 8)
		_gen = 1

	# --- заголовок ---
	out.append_array("GIF89a".to_ascii_buffer())
	_u16(out, w)
	_u16(out, h)
	var tp := Time.get_ticks_usec()
	if not per_frame_palette:
		_build_palette(datas, w, h, ncol, thr)
		out.append(0x80 | ((_bits - 1) << 4) | (_bits - 1))
	else:
		out.append(0x70 | 0)  # без глобальной таблицы, color resolution 8 бит
	out.append(0)  # цвет фона
	out.append(0)  # aspect
	if not per_frame_palette:
		out.append_array(_pal.slice(0, (1 << _bits) * 3))
	last_stats["palette_ms"] += (Time.get_ticks_usec() - tp) / 1000.0
	if loop_count >= 0:
		out.append_array(PackedByteArray([0x21, 0xFF, 0x0B]))
		out.append_array("NETSCAPE2.0".to_ascii_buffer())
		out.append_array(PackedByteArray([0x03, 0x01]))
		_u16(out, loop_count)
		out.append(0)

	# --- кадры ---
	var cs_per_frame := 100.0 / maxf(fps, 0.01)
	var shown_cs := 0  # сколько сотых уже "показано" заданными задержками
	var disposal := 2 if has_alpha else 1
	for fi in datas.size():
		var target := roundi((fi + 1) * cs_per_frame)
		var delay := maxi(2, target - shown_cs)  # < 2 браузеры превращают в 10
		shown_cs += delay
		var d := datas[fi]
		if per_frame_palette:
			var tpp := Time.get_ticks_usec()
			_build_palette([d] as Array[PackedByteArray], w, h, ncol, thr)
			last_stats["palette_ms"] += (Time.get_ticks_usec() - tpp) / 1000.0
		var tq := Time.get_ticks_usec()
		var idx := _quantize(d, w, h, thr)
		var tl := Time.get_ticks_usec()
		last_stats["quant_ms"] += (tl - tq) / 1000.0
		# Graphic Control Extension
		out.append_array(PackedByteArray([0x21, 0xF9, 0x04, (disposal << 2) | (1 if has_alpha else 0)]))
		_u16(out, delay)
		out.append(0)  # прозрачный индекс всегда 0
		out.append(0)
		# Image Descriptor
		out.append(0x2C)
		_u16(out, 0)
		_u16(out, 0)
		_u16(out, w)
		_u16(out, h)
		if per_frame_palette:
			out.append(0x80 | (_bits - 1))
			out.append_array(_pal.slice(0, (1 << _bits) * 3))
		else:
			out.append(0)
		var mcs := maxi(2, _bits)
		out.append(mcs)
		var stream := _lzw(idx, mcs)
		var p := 0
		var total := stream.size()
		while p < total:
			var n := mini(255, total - p)
			out.append(n)
			out.append_array(stream.slice(p, p + n))
			p += n
		out.append(0)
		last_stats["lzw_ms"] += (Time.get_ticks_usec() - tl) / 1000.0
	out.append(0x3B)
	last_stats["total_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	last_stats["bytes"] = out.size()
	last_stats["palette_size"] = 1 << _bits
	return out


static func save(path: String, bytes: PackedByteArray) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	return OK


func _u16(a: PackedByteArray, v: int) -> void:
	a.append(v & 255)
	a.append((v >> 8) & 255)


func _prepare_tables() -> void:
	if _dith_off.size() == 16:
		return
	_dith_off.resize(16)
	for i in 16:
		_dith_off[i] = roundi((float(BAYER[i]) - 7.5) / 16.0 * dither_spread)
	var n := 256 + PAD * 2
	_tr.resize(n)
	_tg.resize(n)
	_tb.resize(n)
	for i in n:
		var v := clampi(i - PAD, 0, 255) >> 3
		_tr[i] = v << 10
		_tg[i] = v << 5
		_tb[i] = v


# ---------- палитра ----------

## Строит _pal, _lut, _bits, _ccount по подвыборке пикселей всех переданных кадров.
func _build_palette(datas: Array[PackedByteArray], w: int, h: int, ncol: int, thr: int) -> void:
	# подвыборка: ~120к пикселей на всё
	var budget := 120000
	var total_px := w * h * datas.size()
	var stride := maxi(1, int(ceil(sqrt(float(total_px) / budget))))
	var cnt := PackedInt32Array()
	var sr := PackedInt32Array()
	var sg := PackedInt32Array()
	var sb := PackedInt32Array()
	cnt.resize(HIST)
	sr.resize(HIST)
	sg.resize(HIST)
	sb.resize(HIST)
	var keys := PackedInt32Array()
	for d in datas:
		for y in range(0, h, stride):
			var o := y * w * 4
			for x in range(0, w, stride):
				var p := o + x * 4
				if d[p + 3] < thr:
					continue
				var r: int = d[p]
				var g: int = d[p + 1]
				var b: int = d[p + 2]
				var key := ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
				if cnt[key] == 0:
					keys.append(key)
				cnt[key] += 1
				sr[key] += r
				sg[key] += g
				sb[key] += b
	var n := keys.size()
	var boxes: Array[PackedInt32Array] = []
	if n > 0:
		var all := PackedInt32Array()
		all.resize(n)
		for i in n:
			all[i] = i
		boxes.append(all)
	if n > ncol:
		_median_cut(boxes, keys, cnt, ncol)
	elif n > 0:
		boxes.clear()
		for i in n:
			boxes.append(PackedInt32Array([i]))
	var nb := boxes.size()
	if nb == 0:
		nb = 1  # всё прозрачное: одна заглушка
	_ccount = nb
	var total := _cbase + nb
	_bits = 1
	while (1 << _bits) < total:
		_bits += 1
	_pal.resize((1 << _bits) * 3)
	_pal.fill(0)
	_lut.resize(HIST)
	_lut.fill(-1)
	for bi in boxes.size():
		var tr := 0
		var tg := 0
		var tb := 0
		var tc := 0
		for m in boxes[bi]:
			var key := keys[m]
			tr += sr[key]
			tg += sg[key]
			tb += sb[key]
			tc += cnt[key]
			_lut[key] = bi + _cbase
		var pi := (bi + _cbase) * 3
		_pal[pi] = tr / tc
		_pal[pi + 1] = tg / tc
		_pal[pi + 2] = tb / tc


## Делим коробки по самому широкому каналу в медиане по весу, пока их не станет ncol.
func _median_cut(boxes: Array[PackedInt32Array], keys: PackedInt32Array, cnt: PackedInt32Array, ncol: int) -> void:
	var n := keys.size()
	var cr := PackedInt32Array()
	var cg := PackedInt32Array()
	var cb := PackedInt32Array()
	var cc := PackedInt32Array()
	cr.resize(n)
	cg.resize(n)
	cb.resize(n)
	cc.resize(n)
	for i in n:
		var k := keys[i]
		cr[i] = k >> 10
		cg[i] = (k >> 5) & 31
		cb[i] = k & 31
		cc[i] = cnt[k]
	var scores := PackedFloat32Array()
	var chans := PackedInt32Array()
	scores.append(0.0)
	chans.append(0)
	_box_score(boxes[0], cr, cg, cb, cc, scores, chans, 0)
	while boxes.size() < ncol:
		var best := -1
		var bs := 0.0
		for i in boxes.size():
			if scores[i] > bs:
				bs = scores[i]
				best = i
		if best < 0:
			break
		var mem := boxes[best]
		var ch := chans[best]
		var comp := cr if ch == 0 else (cg if ch == 1 else cb)
		var sorted := PackedInt64Array()
		sorted.resize(mem.size())
		var total := 0
		for j in mem.size():
			var m := mem[j]
			sorted[j] = (comp[m] << 16) | m
			total += cc[m]
		sorted.sort()
		var half := total / 2
		var acc := 0
		var cut := 1
		for j in sorted.size() - 1:
			acc += cc[sorted[j] & 0xFFFF]
			cut = j + 1
			if acc >= half:
				break
		var left := PackedInt32Array()
		var right := PackedInt32Array()
		left.resize(cut)
		right.resize(sorted.size() - cut)
		for j in sorted.size():
			var m2 := int(sorted[j] & 0xFFFF)
			if j < cut:
				left[j] = m2
			else:
				right[j - cut] = m2
		boxes[best] = left
		boxes.append(right)
		scores.append(0.0)
		chans.append(0)
		_box_score(left, cr, cg, cb, cc, scores, chans, best)
		_box_score(right, cr, cg, cb, cc, scores, chans, boxes.size() - 1)


func _box_score(mem: PackedInt32Array, cr: PackedInt32Array, cg: PackedInt32Array, cb: PackedInt32Array,
		cc: PackedInt32Array, scores: PackedFloat32Array, chans: PackedInt32Array, bi: int) -> void:
	if mem.size() < 2:
		scores[bi] = 0.0
		return
	var rmin := 31
	var rmax := 0
	var gmin := 31
	var gmax := 0
	var bmin := 31
	var bmax := 0
	var total := 0
	for m in mem:
		var r := cr[m]
		var g := cg[m]
		var b := cb[m]
		if r < rmin: rmin = r
		if r > rmax: rmax = r
		if g < gmin: gmin = g
		if g > gmax: gmax = g
		if b < bmin: bmin = b
		if b > bmax: bmax = b
		total += cc[m]
	var rr := (rmax - rmin) * 3.0
	var gr := (gmax - gmin) * 4.0
	var br := (bmax - bmin) * 2.0
	var best := rr
	var ch := 0
	if gr > best:
		best = gr
		ch = 1
	if br > best:
		best = br
		ch = 2
	chans[bi] = ch
	scores[bi] = best * sqrt(float(total)) if best > 0.0 else 0.0


## Ближайший цвет палитры к центру корзины 5-5-5 (для корзин вне подвыборки).
func _nearest(key: int) -> int:
	var r := ((key >> 10) & 31) * 8 + 4
	var g := ((key >> 5) & 31) * 8 + 4
	var b := (key & 31) * 8 + 4
	var best := _cbase
	var bd := 1 << 30
	var pal := _pal
	for i in range(_cbase, _cbase + _ccount):
		var dr := r - pal[i * 3]
		var dg := g - pal[i * 3 + 1]
		var db := b - pal[i * 3 + 2]
		var dd := dr * dr * 3 + dg * dg * 4 + db * db * 2
		if dd < bd:
			bd = dd
			best = i
	_lut[key] = best
	return best


# ---------- квантование кадра ----------

func _quantize(d: PackedByteArray, w: int, h: int, thr: int) -> PackedByteArray:
	var idx := PackedByteArray()
	idx.resize(w * h)
	var lut := _lut
	var o := 0
	var i := 0
	if not dither:
		for _y in h:
			for _x in w:
				if d[o + 3] < thr:
					idx[i] = 0
				else:
					var key := ((d[o] >> 3) << 10) | ((d[o + 1] >> 3) << 5) | (d[o + 2] >> 3)
					var c := lut[key]
					if c < 0:
						c = _nearest(key)
					idx[i] = c
				o += 4
				i += 1
	else:
		var off := _dith_off
		var tr := _tr
		var tg := _tg
		var tb := _tb
		for y in h:
			var row := (y & 3) << 2
			for x in w:
				if d[o + 3] < thr:
					idx[i] = 0
				else:
					var s := off[row | (x & 3)] + PAD
					var key := tr[d[o] + s] | tg[d[o + 1] + s] | tb[d[o + 2] + s]
					var c := lut[key]
					if c < 0:
						c = _nearest(key)
					idx[i] = c
				o += 4
				i += 1
	return idx


# ---------- LZW ----------

## Возвращает поток кодов (без разбиения на подблоки): clear, данные, eoi.
func _lzw(idx: PackedByteArray, mcs: int) -> PackedByteArray:
	var n := idx.size()
	var clear := 1 << mcs
	var eoi := clear + 1
	var nxt := eoi + 1
	var csize := mcs + 1
	if _gen > 400000:
		_table.fill(0)
		_gen = 1
	var gen := _gen + 1
	var table := _table
	var buf := PackedByteArray()
	buf.resize(n * 2 + 1024)
	var pos := 0
	var bits := clear
	var nb := csize
	var prefix: int = idx[0]
	for i in range(1, n):
		var sym: int = idx[i]
		var k := (prefix << mcs) | sym
		var e := table[k]
		if (e >> 12) == gen:
			prefix = e & 4095
		else:
			bits |= prefix << nb
			nb += csize
			while nb >= 8:
				buf[pos] = bits & 255
				pos += 1
				bits >>= 8
				nb -= 8
			if nxt < 4096:
				table[k] = (gen << 12) | nxt
				nxt += 1
				if nxt > (1 << csize):
					csize += 1
			else:
				bits |= clear << nb
				nb += csize
				while nb >= 8:
					buf[pos] = bits & 255
					pos += 1
					bits >>= 8
					nb -= 8
				gen += 1
				nxt = eoi + 1
				csize = mcs + 1
			prefix = sym
	bits |= prefix << nb
	nb += csize
	while nb >= 8:
		buf[pos] = bits & 255
		pos += 1
		bits >>= 8
		nb -= 8
	if nxt == (1 << csize) and csize < 12:
		csize += 1  # декодер уже добавил запись и увеличил размер перед чтением EOI
	bits |= eoi << nb
	nb += csize
	while nb > 0:
		buf[pos] = bits & 255
		pos += 1
		bits >>= 8
		nb -= 8
	_gen = gen
	buf.resize(pos)
	return buf
