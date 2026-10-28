extends SceneTree
## Headless physics checks. Run with:
##   godot --headless --path . -s res://tests/test_pole_sim.gd
## Each scenario simulates a jump with a scripted player and checks the outcome,
## so a tuning change that kills the skill window shows up immediately.

const DT := 1.0 / 240.0
const BODY_HANG := 2.05
const SAND_X := 8.0
const OVERLAP := 0.04   # perfect rhythm: grab with the new hand, then let go of the old

var failures := 0


func new_sim(v: float) -> PoleSim:
	var sim := PoleSim.new()
	sim.reset()
	sim.grab(v)
	return sim


## Simulate a jump with a perfect press/hold/release rhythm: run speed v,
## first grip after `delay` seconds, let go of the pole at release_angle.
func jump(v: float, delay: float, release_angle: float) -> Dictionary:
	var sim := new_sim(v)
	var t := 0.0
	var next_press := delay
	var hand := 0
	var release_at := -1.0
	var release_hand := -1
	while t < 20.0:
		if t >= next_press:
			sim.press(hand)
			release_hand = 1 - hand
			release_at = t + OVERLAP
			hand = 1 - hand
			next_press += sim.stroke_time
		if release_at >= 0.0 and t >= release_at:
			sim.release_hand(release_hand)
			release_at = -1.0
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


func run_for(sim: PoleSim, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		sim.step(DT)
		t += DT


func check(name: String, cond: bool, info: Variant) -> void:
	print(("PASS " if cond else "FAIL ") + name + "  " + str(info))
	if not cond:
		failures += 1


func _init() -> void:
	# --- Whole jumps: the stall / short / release-timing window ---
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

	# --- Hand over hand ---
	var sim := new_sim(7.0)
	var s0 := sim.s
	sim.press(1)
	run_for(sim, 1.0)
	check("one held pull gains exactly one stroke", absf(sim.s - s0 - sim.stroke_length) < 0.02, sim.s - s0)

	sim = new_sim(7.0)
	s0 = sim.s
	sim.press(1)
	run_for(sim, sim.stroke_time * 0.5)
	sim.release_hand(1)
	run_for(sim, 0.5)
	check("releasing mid-pull gains only part of a stroke", sim.s - s0 < sim.stroke_length * 0.6 and not sim.sliding, sim.s - s0)

	sim = new_sim(7.0)
	sim.press(1)
	run_for(sim, 0.4)
	check("same hand twice is a fumble", sim.release_hand(1) == "" and sim.press(1) == "fumble", sim.s)

	# --- Slips ---
	sim = new_sim(7.0)
	sim.press(1); run_for(sim, 0.4)
	sim.press(0); run_for(sim, 0.4)     # clean transfer: R still held
	sim.release_hand(1); run_for(sim, 0.05)
	var before := sim.s
	var ev := sim.release_hand(0)       # nothing left holding on
	run_for(sim, 1.5)
	check("first slip: legs catch after about half a metre",
		ev == "slip" and not sim.sliding and absf(before - sim.s - sim.slip_catch_distance) < 0.08,
		{"event": ev, "lost": before - sim.s})

	sim.press(1); run_for(sim, 0.4)
	ev = sim.release_hand(1)            # second slip, no clean transfer in between
	run_for(sim, 0.3)
	check("second slip drops: still sliding after the leg-catch distance",
		ev == "drop" and sim.sliding and sim.dropping, {"event": ev, "s": sim.s})

	var falling_s := sim.s
	ev = sim.press(0)
	run_for(sim, sim.regrab_time * 0.9)
	check("a hand can catch a drop (with a short delay before pulling)",
		ev == "catch" and not sim.sliding and absf(sim.s - falling_s) < 0.01, {"event": ev, "s": sim.s})

	sim = new_sim(7.0)
	sim.press(1); run_for(sim, 0.4)
	sim.release_hand(1)                 # still has the grab grip on the left
	check("first release after the grab is not a slip", not sim.sliding, sim.slips_in_row)

	sim = new_sim(7.0)
	sim.press(1); run_for(sim, 0.4); sim.release_hand(1)
	sim.press(0); run_for(sim, 0.4); sim.release_hand(0); run_for(sim, 1.0)   # slip 1
	sim.press(1); run_for(sim, 0.4); sim.release_hand(1); run_for(sim, 5.0)   # drop, no catch
	check("an uncaught drop ends in the canal", sim.fell_in, sim.s)

	# --- Sliding feeds the pole physics ---
	var a := new_sim(7.0)
	var b := new_sim(7.0)
	for x in [a, b]:
		x.press(1); run_for(x, 0.4); x.release_hand(1)
		x.press(0); run_for(x, 0.4)
	b.release_hand(0)                   # b slips, a keeps holding
	run_for(a, 0.3); run_for(b, 0.3)
	check("sliding down makes the pole rotate faster", b.omega > a.omega, {"holding": a.omega, "sliding": b.omega})

	print("RESULT: %d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
