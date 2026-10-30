class_name RbOnion
extends RefCounted
## Онион скин: какие кадры показать призраками и каким цветом. Отрисовка в render/onion_renderer.gd.
## Прошлые кадры красноватые, будущие голубые (как в Moho), чем дальше от текущего, тем прозрачнее.
## Призраки без эффектов композинга, только силуэт слоя плоским цветом.

const MAX_N := 3
const BEFORE := Color("#FF5A5F")
const AFTER := Color("#3E9BFF")
const ALPHA := 0.38  # ближайший призрак


## Кадры призраков вокруг current: [[кадр, смещение]], смещение < 0 = прошлое. По n в каждую сторону.
## loop: за краем диапазона берётся кадр с другого конца (зацикленная анимация). Текущий кадр
## и повторы отбрасываются, ближние идут последними (рисуются поверх дальних).
static func ghost_frames(current: int, count: int, n: int, loop := false) -> Array:
	var out: Array = []
	if count < 2 or n <= 0:
		return out
	var seen := {current: true}
	for d in range(mini(n, MAX_N), 0, -1):
		for s in [-1, 1]:
			var f: int = current + d * s
			if loop:
				f = posmod(f, count)
			elif f < 0 or f >= count:
				continue
			if seen.has(f):
				continue
			seen[f] = true
			out.append([f, d * s])
	return out


static func tint(offset: int, n: int) -> Color:
	var c := BEFORE if offset < 0 else AFTER
	var k := 1.0 - float(absi(offset) - 1) / float(maxi(mini(n, MAX_N), 1))
	return Color(c.r, c.g, c.b, ALPHA * k)
