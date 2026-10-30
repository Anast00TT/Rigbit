class_name RbDynamics
extends RefCounted
## Динамика костей (хвостики, волосы, ушки): угловая пружина, которая отстаёт от
## кинематического движения. Детерминированная: симуляция идёт подряд от кадра 0 и
## кешируется по кадрам. При скрабе назад берётся кеш, при правке ключей кеш сбрасывается.
## Параметры кости (0..1): spring — жёсткость, damping — затухание, torque — постоянный «вес».

const SUBSTEPS := 4

var _states: Array = []  # кадр -> {id: Vector2(угол, скорость)}
var _kin: Array = []  # кадр -> {id: [мировой угол, начало кости]}


func invalidate() -> void:
	_states.clear()
	_kin.clear()


## Добавочные локальные углы динамических костей на кадре.
func offsets(doc: RbDocument, frame: int) -> Dictionary:
	var dyn := doc.rig.dynamic_bones()
	if dyn.is_empty():
		return {}
	frame = maxi(frame, 0)
	if _states.size() <= frame:
		_simulate(doc, dyn, frame)
	var out := {}
	var st: Dictionary = _states[frame]
	for id in st:
		out[id] = (st[id] as Vector2).x
	return out


func _simulate(doc: RbDocument, dyn: Array[int], upto: int) -> void:
	var saved := doc.current_frame
	var dt := 1.0 / maxf(float(doc.fps), 1.0)
	for f in range(_states.size(), upto + 1):
		doc.anim.apply_frame(doc, f)
		var w := doc.rig.world_transforms(true)
		var kin := {}
		for id in dyn:
			var t: Transform2D = w.get(id, Transform2D.IDENTITY)
			kin[id] = [t.get_rotation(), t.origin]
		_kin.append(kin)
		var st := {}
		for id in dyn:
			var b := doc.rig.get_bone(id)
			var p: Dictionary = b.constraints["dynamics"]
			var prev: Vector2 = (_states[f - 1] as Dictionary).get(id, Vector2.ZERO) if f > 0 else Vector2.ZERO
			var drive := 0.0
			if f >= 2:
				var a0: float = kin[id][0]
				var a1: float = _kin[f - 1][id][0]
				var a2: float = _kin[f - 2][id][0]
				# угловое ускорение «носителя»: кость отстаёт в обратную сторону
				drive -= (wrapf(a0 - a1, -PI, PI) - wrapf(a1 - a2, -PI, PI)) / (dt * dt)
				# линейное ускорение начала кости раскачивает её как маятник
				var o0: Vector2 = kin[id][1]
				var o1: Vector2 = _kin[f - 1][id][1]
				var o2: Vector2 = _kin[f - 2][id][1]
				var acc := (o0 - 2.0 * o1 + o2) / (dt * dt)
				drive -= Vector2.from_angle(a0).cross(acc) / maxf(b.length, 1.0)
			var k := lerpf(30.0, 400.0, float(p.get("spring", 0.5)))
			var c := lerpf(1.0, 25.0, float(p.get("damping", 0.4)))
			var torque := float(p.get("torque", 0.0)) * 40.0
			var th := prev.x
			var om := prev.y
			var h := dt / SUBSTEPS
			for _s in SUBSTEPS:
				var acc_t := -k * th - c * om + drive + torque
				om += acc_t * h
				th += om * h
			th = clampf(th, -PI * 0.9, PI * 0.9)
			st[id] = Vector2(th, om)
		_states.append(st)
	doc.anim.apply_frame(doc, saved)
