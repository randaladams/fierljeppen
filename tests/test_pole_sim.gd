extends SceneTree
## Headless physics checks. Run with:
##   godot --headless --path . -s res://tests/test_pole_sim.gd
## Each scenario simulates a jump with a scripted player and checks the outcome,
## so a tuning change that kills the skill window shows up immediately.

const DT := 1.0 / 240.0
const BODY_HANG := 2.05
const SAND_X := 8.0

var failures := 0


## Simulate a jump: run speed v, start climbing after delay (s), tap every
## tap_interval seconds, let go at release_angle (rad). Returns outcome + distance.
func jump(v: float, delay: float, release_angle: float, tap_interval := 0.25) -> Dictionary:
	var sim := PoleSim.new()
	sim.reset()
	sim.grab(v)
	var t := 0.0
	var next_tap := delay
	var hand := 0
	while t < 20.0:
		if t >= next_tap:
			sim.request_stroke(hand)
			hand = 1 - hand
			next_tap += tap_interval
		sim.step(DT)
		t += DT
		if sim.is_falling_back():
			return {"outcome": "back", "t": t}
		if sim.theta >= release_angle or sim.must_release():
			var pos := sim.hand_position()
			var vel := sim.release()
			while pos.y - BODY_HANG > 0.0:
				vel.y -= PoleSim.G * DT
				pos += vel * DT
			var outcome := "land" if pos.x >= SAND_X else "short"
			return {"outcome": outcome, "dist": pos.x, "height": sim.s}
	return {"outcome": "timeout"}


func check(name: String, cond: bool, info: Dictionary) -> void:
	print(("PASS " if cond else "FAIL ") + name + "  " + str(info))
	if not cond:
		failures += 1


func _init() -> void:
	var r := jump(8.0, 0.0, 0.9)
	check("good jump lands on the sand", r.outcome == "land", r)
	var good: float = r.get("dist", 0.0)

	r = jump(6.0, 0.0, 0.9)
	check("slow run + instant climb stalls the pole", r.outcome == "back", r)

	r = jump(6.0, 1.0, 0.9)
	check("slow run is rescued by waiting before climbing", r.outcome == "land", r)

	r = jump(9.0, 1.5, 0.9)
	check("fast run + late climb lands short", r.outcome == "short", r)

	var early := jump(8.0, 0.0, 0.3)
	check("letting go too early is worse", early.get("dist", 0.0) < good, early)

	var late := jump(8.0, 0.0, 1.3)
	check("letting go at the last moment is worse than the sweet spot", late.get("dist", 0.0) < good, late)

	print("RESULT: %d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
