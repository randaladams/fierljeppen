extends Node2D
## Prototype game loop: run-up -> grab -> climb -> release -> flight -> result.
## Everything is drawn with _draw() so the physics can be tuned before any art exists.
##
## Controls
##   Touch: tap left / right half of the screen alternately to run and to climb
##          (thumb pads in the bottom corners show which hand is next).
##          Tap the round LET GO button, bottom centre, to release.
##   Keys:  Left/A and Right/D alternate, Space = start / let go, R = reset.

enum State { READY, RUN, POLE, FLIGHT, RESULT }

const SWEET_MIN := 0.7          # release sweet spot, pole angle past vertical (rad)
const SWEET_MAX := 1.05
const GRAB_SLOWMO_TIME := 0.9   # real seconds of slow motion after the grab
const GRAB_SLOWMO_SCALE := 0.3

const PHYSICS_HZ := 240.0
const RUNWAY_LENGTH := 18.0
const JETTY_HEIGHT := 0.8
const SAND_X := 8.0
const SAND_END := 26.0
const BODY_HANG := 2.05        # hands to feet while hanging, metres
const RUN_V_MAX := 10.0
const RUN_V_MIN := 2.0
const RUN_TAP_GAIN := 0.15     # fraction of the gap to max speed per good step
const RUN_DECAY := 0.25        # speed lost per second, as a fraction of speed

var sim := PoleSim.new()
var state: State = State.READY
var run_x := -RUNWAY_LENGTH
var run_speed := 0.0
var _last_run_hand := -1
var _run_phase := 0.0
var _grab_speed := 0.0

var jumper_pos := Vector2.ZERO   # hand position while in flight
var jumper_vel := Vector2.ZERO
var result_text := ""
var result_ok := false
var best := 0.0
var _result_timer := 0.0
var _fumble_flash := 0.0
var _accumulator := 0.0
var _view_left := -8.0
var _trail: PackedVector2Array = []
var _slowmo_timer := 0.0
var _banner := ""
var _banner_timer := 0.0
var _jumps := 0


func _ready() -> void:
	reset()


func reset() -> void:
	sim.reset()
	state = State.READY
	run_x = -RUNWAY_LENGTH
	run_speed = 0.0
	_last_run_hand = -1
	_trail.clear()
	result_text = ""


# ---------------------------------------------------------------- input ---

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed:
		var size := get_viewport_rect().size
		if state == State.POLE and _in_release_button(event.position, size):
			_let_go()
		else:
			_on_hand(0 if event.position.x < size.x / 2.0 else 1)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT, KEY_A:
				_on_hand(0)
			KEY_RIGHT, KEY_D:
				_on_hand(1)
			KEY_SPACE, KEY_UP, KEY_W:
				_on_action()
			KEY_R:
				reset()


func _on_hand(hand: int) -> void:
	match state:
		State.READY:
			state = State.RUN
			run_speed = 3.0
			_last_run_hand = hand
		State.RUN:
			if hand != _last_run_hand:
				run_speed += (RUN_V_MAX - run_speed) * RUN_TAP_GAIN
			else:
				run_speed = maxf(RUN_V_MIN, run_speed - 1.0)   # stumble
				_fumble_flash = 0.3
			_last_run_hand = hand
		State.POLE:
			if not sim.request_stroke(hand):
				_fumble_flash = 0.3
		State.RESULT:
			if _result_timer > 0.6:
				reset()


func _on_action() -> void:
	match state:
		State.READY:
			_on_hand(0)
		State.POLE:
			_let_go()
		State.RESULT:
			if _result_timer > 0.6:
				reset()


var _auto_released := false


func _let_go(auto := false) -> void:
	if state != State.POLE:
		return
	_auto_released = auto
	if not auto:
		if sim.theta < SWEET_MIN:
			_banner = "Early!"
		elif sim.theta <= SWEET_MAX:
			_banner = "Good timing!"
		else:
			_banner = "A bit late"
		_banner_timer = 1.0
	jumper_pos = sim.hand_position()
	jumper_vel = sim.release()
	state = State.FLIGHT


# -------------------------------------------------------------- physics ---

func _process(delta: float) -> void:
	var time_scale := GRAB_SLOWMO_SCALE if _slowmo_timer > 0.0 else 1.0
	_slowmo_timer = maxf(0.0, _slowmo_timer - delta)
	_banner_timer = maxf(0.0, _banner_timer - delta)
	_accumulator += minf(delta, 0.1) * time_scale
	var dt := 1.0 / PHYSICS_HZ
	while _accumulator >= dt:
		_tick(dt)
		_accumulator -= dt
	_fumble_flash = maxf(0.0, _fumble_flash - delta)
	if state == State.RESULT:
		_result_timer += delta
	_update_camera(delta)
	queue_redraw()


func _tick(dt: float) -> void:
	match state:
		State.RUN:
			run_speed = maxf(RUN_V_MIN, run_speed - run_speed * RUN_DECAY * dt)
			run_x += run_speed * dt
			_run_phase += run_speed * dt * 1.6
			if run_x >= 0.0:
				_grab_speed = run_speed
				sim.grab(run_speed)
				state = State.POLE
				_slowmo_timer = GRAB_SLOWMO_TIME
				_banner = "CLIMB!  keep tapping L · R"
				_banner_timer = 1.4
		State.POLE:
			sim.step(dt)
			if _trail.size() == 0 or _trail[-1].distance_to(sim.hand_position()) > 0.15:
				_trail.append(sim.hand_position())
			if sim.must_release():
				_let_go(true)
			elif sim.is_falling_back() and sim.theta < sim.start_lean - 0.15:
				_finish(false, "Splash! The pole fell back.\nRun faster, or climb a little later.")
		State.FLIGHT:
			sim.step(dt)   # the abandoned pole keeps falling
			jumper_vel.y -= PoleSim.G * dt
			jumper_pos += jumper_vel * dt
			_trail.append(jumper_pos)
			var feet := jumper_pos - Vector2(0, BODY_HANG)
			if feet.y <= 0.0:
				if feet.x >= SAND_X:
					best = maxf(best, feet.x)
					var tip := "\nYou rode the pole down. Hit LET GO when it turns green." if _auto_released else ""
					_finish(true, "%.2f m%s" % [feet.x, tip])
				else:
					_finish(false, "Splash! %.2f m — short of the sand.\nClimb higher before letting go." % maxf(feet.x, 0.0))
		State.RESULT:
			if not sim.attached:
				sim.step(dt)


func _finish(ok: bool, text: String) -> void:
	state = State.RESULT
	result_ok = ok
	result_text = text
	_result_timer = 0.0
	sim.attached = false
	_jumps += 1


# ------------------------------------------------------------- drawing ---

var _ppm := 40.0
var _ground_y := 560.0


func _update_camera(delta: float) -> void:
	var size := get_viewport_rect().size
	_ppm = minf(size.x / 30.0, size.y * 0.58 / 13.0)
	_ground_y = size.y * 0.64
	var target := -10.0
	if state == State.RUN or state == State.READY:
		target = minf(-10.0, run_x - 9.0)
	_view_left = lerpf(_view_left, target, clampf(delta * 4.0, 0.0, 1.0))


func w2s(p: Vector2) -> Vector2:
	return Vector2((p.x - _view_left) * _ppm, _ground_y - p.y * _ppm)


func _draw() -> void:
	var size := get_viewport_rect().size
	var font := ThemeDB.fallback_font
	# Sky
	draw_rect(Rect2(Vector2.ZERO, size), Color("#cfe3ee"))
	# Water (canal)
	var water_top := w2s(Vector2(0, 0)).y
	draw_rect(Rect2(Vector2(w2s(Vector2(0, 0)).x, water_top),
		Vector2((SAND_X) * _ppm, size.y - water_top)), Color("#3f7891"))
	# Jetty / runway
	var jl := w2s(Vector2(-RUNWAY_LENGTH - 30.0, JETTY_HEIGHT))
	var jr := w2s(Vector2(0, -40.0))
	draw_rect(Rect2(jl, jr - jl), Color("#7a5a3a"))
	# Sand bed with distance marks
	var sl := w2s(Vector2(SAND_X, 0.15))
	var sr := w2s(Vector2(SAND_END + 20.0, -40.0))
	draw_rect(Rect2(sl, sr - sl), Color("#e2c98f"))
	for m in range(int(SAND_X), int(SAND_END) + 1):
		var top := w2s(Vector2(m, 0.15))
		var tick := 0.35 if m % 5 == 0 else 0.15
		draw_line(top, top + Vector2(0, tick * _ppm), Color("#8a6d3b"), 2.0)
		if m % 5 == 0:
			draw_string(font, top + Vector2(-8, tick * _ppm + 16), str(m), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#5c4a28"))
	if best > 0.0:
		var bp := w2s(Vector2(best, 0.15))
		draw_line(bp, bp - Vector2(0, 0.8 * _ppm), Color("#c0392b"), 3.0)
		draw_string(font, bp - Vector2(-4, 0.8 * _ppm), "best", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#c0392b"))

	# Training overlay: pole angle arc at the base
	var base := w2s(sim.base_position())
	draw_arc(base, 1.4 * _ppm, -PI / 2.0 + sim.start_lean, -PI / 2.0 + 1.35, 32, Color(1, 1, 1, 0.35), 2.0)
	draw_arc(base, 1.4 * _ppm, -PI / 2.0 + SWEET_MIN, -PI / 2.0 + SWEET_MAX, 16, Color("#3ddc84"), 5.0)
	draw_line(base, base - Vector2(0, 1.6 * _ppm), Color(1, 1, 1, 0.6), 1.5)

	# Trail
	if _trail.size() > 1:
		var pts := PackedVector2Array()
		for p in _trail:
			pts.append(w2s(p))
		draw_polyline(pts, Color(1, 1, 1, 0.5), 2.0)

	# Pole
	draw_line(base, w2s(sim.tip_position()), Color("#222831"), maxf(3.0, 0.07 * _ppm))
	draw_circle(base, 0.15 * _ppm, Color("#222831"))

	# Jumper
	match state:
		State.READY, State.RUN:
			_draw_runner(Vector2(run_x, JETTY_HEIGHT))
		State.POLE:
			_draw_hanging(sim.hand_position())
		State.FLIGHT:
			_draw_hanging(jumper_pos)
		State.RESULT:
			if result_ok:
				_draw_hanging(jumper_pos)

	_draw_hud(size, font)


func _draw_runner(feet: Vector2) -> void:
	var c := Color("#1b3a5c")
	var w := maxf(2.5, 0.08 * _ppm)
	var hip := feet + Vector2(0, 0.95)
	var sh := hip + Vector2(0.15, 0.65)
	var swing := sin(_run_phase) * 0.35
	draw_line(w2s(hip), w2s(feet + Vector2(swing, 0)), c, w)
	draw_line(w2s(hip), w2s(feet + Vector2(-swing, 0.1)), c, w)
	draw_line(w2s(hip), w2s(sh), c, w)
	draw_line(w2s(sh), w2s(sh + Vector2(0.3, 0.45)), c, w)   # reaching arm
	draw_circle(w2s(sh + Vector2(0.08, 0.3)), 0.16 * _ppm, c)


func _draw_hanging(hands: Vector2) -> void:
	var c := Color("#1b3a5c")
	var w := maxf(2.5, 0.08 * _ppm)
	var sh := hands - Vector2(0, 0.55)
	var hip := sh - Vector2(0, 0.7)
	var feet := hip - Vector2(0, 0.8)
	draw_line(w2s(hands), w2s(sh), c, w)
	draw_line(w2s(sh), w2s(hip), c, w)
	draw_line(w2s(hip), w2s(feet + Vector2(0.15, 0)), c, w)
	draw_line(w2s(hip), w2s(feet + Vector2(-0.1, 0.05)), c, w)
	draw_circle(w2s(sh + Vector2(-0.18, 0.15)), 0.16 * _ppm, c)


func _draw_hud(size: Vector2, font: Font) -> void:
	var ink := Color("#14212b")
	var fs := int(clampf(size.y / 32.0, 14.0, 30.0))
	var x := 16.0
	var y := fs + 10.0
	var lines: Array[String] = []
	match state:
		State.READY:
			lines.append("Tap left / right alternately to run.")
		State.RUN:
			lines.append("Speed %.1f m/s" % run_speed)
		State.POLE:
			lines.append("Climb: alternate taps.  θ %+.0f°  ω %.2f rad/s  height %.1f m" % [
				rad_to_deg(sim.theta), sim.omega, sim.s])
			lines.append("Grab speed %.1f m/s" % _grab_speed)
		State.FLIGHT:
			lines.append("...")
	if best > 0.0:
		lines.append("Best %.2f m" % best)
	for line in lines:
		draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
		y += fs + 6.0

	if state == State.RUN or state == State.READY:
		var bar := Rect2(Vector2(x, y + 4), Vector2(size.x * 0.3, fs * 0.7))
		draw_rect(bar, Color(0, 0, 0, 0.15))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * run_speed / RUN_V_MAX, bar.size.y)), Color("#2e86ab"))

	if state in [State.READY, State.RUN, State.POLE]:
		_draw_thumb_pads(size, font, fs)
	if state == State.POLE:
		_draw_release_button(size, font, fs)
	if state == State.READY:
		_draw_how_to(size, font, fs)

	if _banner_timer > 0.0:
		var a := clampf(_banner_timer / 0.3, 0.0, 1.0)
		draw_string(font, Vector2(0, size.y * 0.3), _banner, HORIZONTAL_ALIGNMENT_CENTER, size.x,
			int(fs * 1.8), Color(0.08, 0.13, 0.17, a))

	if _fumble_flash > 0.0:
		draw_string(font, Vector2(0, size.y * 0.45), "fumble!", HORIZONTAL_ALIGNMENT_CENTER, size.x, fs, Color(0.75, 0.1, 0.1, _fumble_flash / 0.3))

	if state == State.RESULT:
		var big := fs * 2
		var col := Color("#1e7b34") if result_ok else Color("#a33a1a")
		var parts := result_text.split("\n")
		var yy := size.y * 0.32
		for i in parts.size():
			draw_string(font, Vector2(0, yy), parts[i], HORIZONTAL_ALIGNMENT_CENTER, size.x, big if i == 0 else fs, col)
			yy += (big if i == 0 else fs) + 10
		if _result_timer > 0.6:
			draw_string(font, Vector2(0, yy + 10), "tap to jump again", HORIZONTAL_ALIGNMENT_CENTER, size.x, fs, ink)


# ------------------------------------------------------------ controls ---

func _pad_rect(size: Vector2, hand: int) -> Rect2:
	var w := size.x * 0.22
	var h := size.y * 0.3
	var x := size.x * 0.02 if hand == 0 else size.x * 0.98 - w
	return Rect2(Vector2(x, size.y * 0.97 - h), Vector2(w, h))


func _release_center(size: Vector2) -> Vector2:
	return Vector2(size.x / 2.0, size.y * 0.8)


func _release_radius(size: Vector2) -> float:
	return size.y * 0.14


func _in_release_button(pos: Vector2, size: Vector2) -> bool:
	# Generous hit area: anywhere in the middle third of the lower half.
	return pos.distance_to(_release_center(size)) < _release_radius(size) * 1.4 \
		or (pos.y > size.y * 0.5 and absf(pos.x - size.x / 2.0) < size.x / 6.0)


func _next_hand() -> int:
	match state:
		State.RUN:
			return 1 - _last_run_hand
		State.POLE:
			return -1 if sim.last_hand() < 0 else 1 - sim.last_hand()
	return -1


func _draw_thumb_pads(size: Vector2, font: Font, fs: int) -> void:
	var next := _next_hand()
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 90.0)
	for hand in [0, 1]:
		var r := _pad_rect(size, hand)
		var lit: bool = next == -1 or next == hand
		var fill := Color(0.18, 0.53, 0.67, 0.25 + 0.3 * pulse) if lit else Color(1, 1, 1, 0.12)
		draw_rect(r, fill)
		draw_rect(r, Color(1, 1, 1, 0.6 if lit else 0.25), false, 2.0)
		var label := "L" if hand == 0 else "R"
		draw_string(font, r.position + Vector2(0, r.size.y * 0.6), label, HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, int(fs * 2.2), Color(1, 1, 1, 0.95 if lit else 0.45))
		var verb := "run" if state != State.POLE else "climb"
		draw_string(font, r.position + Vector2(0, r.size.y * 0.85), verb, HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, fs, Color(1, 1, 1, 0.8 if lit else 0.4))


func _draw_release_button(size: Vector2, font: Font, fs: int) -> void:
	var c := _release_center(size)
	var r := _release_radius(size)
	var col := Color("#d9822b")
	var label := "LET GO"
	if sim.theta >= SWEET_MIN and sim.theta <= SWEET_MAX:
		col = Color("#2fbf71")
		label = "NOW!"
		r *= 1.0 + 0.08 * sin(Time.get_ticks_msec() / 60.0)
	elif sim.theta < SWEET_MIN:
		col = Color(0.85, 0.5, 0.17, 0.55)
	draw_circle(c, r, col)
	draw_arc(c, r, 0, TAU, 48, Color(1, 1, 1, 0.9), 3.0)
	draw_string(font, c + Vector2(-r, fs * 0.35), label, HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, fs, Color.WHITE)


func _draw_how_to(size: Vector2, font: Font, fs: int) -> void:
	var w := size.x * 0.56
	var h := size.y * 0.42
	var r := Rect2(Vector2((size.x - w) / 2.0, size.y * 0.1), Vector2(w, h))
	draw_rect(r, Color(1, 1, 1, 0.88))
	var ink := Color("#14212b")
	var steps := [
		"1   RUN:  tap  L, R, L, R ...",
		"2   CLIMB:  keep tapping  L, R  on the pole",
		"3   LET GO:  big button, when it turns green",
	]
	var y := r.position.y + fs * 1.8
	draw_string(font, Vector2(r.position.x, y), "How to jump", HORIZONTAL_ALIGNMENT_CENTER, w, int(fs * 1.3), ink)
	y += fs * 2.0
	for s in steps:
		draw_string(font, Vector2(r.position.x + fs, y), s, HORIZONTAL_ALIGNMENT_LEFT, w - fs * 2, fs, ink)
		y += fs * 1.7
	draw_string(font, Vector2(r.position.x, r.end.y - fs * 0.8), "Tap L or R to start", HORIZONTAL_ALIGNMENT_CENTER, w, fs, Color("#2e86ab"))
