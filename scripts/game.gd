extends Node2D
## Prototype game loop: run-up -> grab -> climb -> release -> flight -> result.
## Everything is drawn with _draw() so the physics can be tuned before any art exists.
##
## Controls
##   Touch: run - tap the left / right half of the screen alternately.
##          climb - hand over hand: press and HOLD one side while that arm
##          pulls, press the other side, then let go of the first. Repeat.
##          Letting go with no other grip is a slip (see PoleSim).
##          Tap the round LET GO button, bottom centre, to release the pole.
##          "Watch a perfect jump" plays an autopilot demo (doesn't count for best).
##   Keys:  Left/A and Right/D (hold them to climb), Space = start / let go, R = reset, P = demo.

enum State { READY, RUN, POLE, FLIGHT, RESULT }

const SWEET_MIN := 0.6          # release sweet spot, pole angle past vertical (rad)
const SWEET_MAX := 0.95
const HAND_COL: Array[Color] = [Color("#2e86ab"), Color("#e8833a")]   # L blue, R orange
const GRAB_SLOWMO_TIME := 0.6   # real seconds of slow motion after the grab
const GRAB_SLOWMO_SCALE := 0.3

const PHYSICS_HZ := 240.0
const RUNWAY_LENGTH := 18.0
const JETTY_HEIGHT := 0.8
const SAND_X := 12.0           # canal width: real ones are ~12 m
const SAND_END := 30.0
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
var last_distance := 0.0

# --- Demo autopilot ("perfect jump") ---
# Climb delay and release angle come from tools/optimize_demo.gd, which
# searches them against this exact game loop. Re-run it after physics changes.
var demo_run_tap := 0.12            # seconds between running steps
const DEMO_OVERLAP := 0.04           # grab with the new hand, then let go of the old
var demo_climb_delay := 0.2
var demo_release_angle := 0.74
var demo := false
var _demo_t := 0.0
var _demo_next := 0.0
var _demo_hand := 0
var _demo_caption := ""
var _demo_release_at := -1.0
var _demo_release_hand := -1
var _touch_hand := {}                # touch index -> hand it pressed
var _pad_flash: Array[float] = [0.0, 0.0]
var _release_flash := 0.0


func _ready() -> void:
	reset()


func start_demo() -> void:
	reset()
	demo = true
	_demo_hand = 0
	_demo_t = 0.0
	_demo_next = 0.0
	_demo_release_at = -1.0


func reset() -> void:
	sim.reset()
	demo = false
	_demo_caption = ""
	state = State.READY
	run_x = -RUNWAY_LENGTH
	run_speed = 0.0
	_last_run_hand = -1
	_trail.clear()
	result_text = ""


# ---------------------------------------------------------------- input ---

func _unhandled_input(event: InputEvent) -> void:
	var hands_off := demo and state != State.RESULT   # the autopilot is jumping
	if event is InputEventScreenTouch:
		var size := get_viewport_rect().size
		if not event.pressed:
			if _touch_hand.has(event.index):
				var lifted: int = _touch_hand[event.index]
				_touch_hand.erase(event.index)
				if not hands_off:
					_on_hand_up(lifted)
			return
		if hands_off:
			return
		if _demo_button_visible() and _demo_button_rect(size).has_point(event.position):
			start_demo()
		elif state == State.POLE and _in_release_button(event.position, size):
			_let_go()
		else:
			var hand := 0 if event.position.x < size.x / 2.0 else 1
			_touch_hand[event.index] = hand
			_on_hand(hand)
	elif event is InputEventKey and not event.echo and not event.pressed:
		if hands_off:
			return
		match event.keycode:
			KEY_LEFT, KEY_A:
				_on_hand_up(0)
			KEY_RIGHT, KEY_D:
				_on_hand_up(1)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_P and _demo_button_visible():
			start_demo()
			return
		if demo and state != State.RESULT:
			return
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
			match sim.press(hand):
				"fumble":
					_fumble_flash = 0.3
				"catch":
					_show_banner("Caught it!", 0.8, Color("#1e7b34"))
		State.RESULT:
			if _result_timer > 0.6:
				reset()


func _on_hand_up(hand: int) -> void:
	if state != State.POLE:
		return
	sim.release_hand(hand)   # a slip, if any, arrives after the switch window


var _banner_color := Color(0.08, 0.13, 0.17)


func _show_banner(text: String, seconds: float, color := Color(0.08, 0.13, 0.17)) -> void:
	_banner = text
	_banner_timer = seconds
	_banner_color = color


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
		_release_flash = 0.35
		_banner_color = Color(0.08, 0.13, 0.17)
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
	_pad_flash[0] = maxf(0.0, _pad_flash[0] - delta)
	_pad_flash[1] = maxf(0.0, _pad_flash[1] - delta)
	_release_flash = maxf(0.0, _release_flash - delta)
	if state == State.RESULT:
		_result_timer += delta
	_update_camera(delta)
	queue_redraw()


## Autopilot: presses the same buttons a player would, on physics time,
## so the demo is deterministic and matches what the player can do.
func _demo_drive(dt: float) -> void:
	match state:
		State.READY:
			_demo_press(0)
			_demo_next = demo_run_tap
			_demo_caption = "RUN:  L, R, L, R  at a steady pace"
		State.RUN:
			_demo_t += dt
			if _demo_t >= _demo_next:
				_demo_press(_demo_hand)
				_demo_next += demo_run_tap
		State.POLE:
			_demo_t += dt
			if sim.theta >= demo_release_angle:
				_release_flash = 0.35
				_demo_caption = "LET GO in the green zone!"
				_let_go()
			elif _demo_t < demo_climb_delay:
				_demo_caption = "GRAB:  hang on a moment as the pole starts to swing"
			else:
				_demo_caption = "CLIMB:  hold while the arm bends, grab with the other, let go"
				if _demo_t >= _demo_next:
					_demo_release_hand = 1 - _demo_hand
					_demo_release_at = _demo_t + DEMO_OVERLAP
					_demo_press(_demo_hand)
					_demo_next += sim.stroke_time
				if _demo_release_at >= 0.0 and _demo_t >= _demo_release_at:
					_on_hand_up(_demo_release_hand)
					_demo_release_at = -1.0


func _demo_press(hand: int) -> void:
	_pad_flash[hand] = 0.18
	_on_hand(hand)
	_demo_hand = 1 - hand


func _tick(dt: float) -> void:
	if demo:
		_demo_drive(dt)
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
				_banner = "CLIMB!  hold L ... grab R ... let go L"
				_banner_color = Color(0.08, 0.13, 0.17)
				_banner_timer = 1.4
				if demo:
					_demo_t = 0.0
					_demo_next = demo_climb_delay
					_banner_timer = 0.0   # the demo caption explains instead
		State.POLE:
			sim.step(dt)
			match sim.take_event():
				"slip":
					_show_banner("Slip!  Your legs caught you", 1.2, Color("#b03a1a"))
				"drop":
					_show_banner("Lost your grip!  GRAB!", 2.0, Color("#b03a1a"))
			if _trail.size() == 0 or _trail[-1].distance_to(sim.hand_position()) > 0.15:
				_trail.append(sim.hand_position())
			if sim.must_release():
				_let_go(true)
			elif sim.is_falling_back() and sim.theta < sim.start_lean - 0.15:
				_finish(false, "Splash! The pole fell back.\nRun faster, or climb a little later.")
			elif sim.fell_in:
				_finish(false, "Splash! You slid down into the canal.\nGrab with the other hand before you let go.")
			elif sim.dropping and sim.sliding:
				_show_banner("Lost your grip!  GRAB!", 0.2, Color("#b03a1a"))
		State.FLIGHT:
			sim.step(dt)   # the abandoned pole keeps falling
			jumper_vel.y -= PoleSim.G * dt
			jumper_pos += jumper_vel * dt
			_trail.append(jumper_pos)
			var feet := jumper_pos - Vector2(0, BODY_HANG)
			if feet.y <= 0.0:
				last_distance = feet.x
				if feet.x >= SAND_X and demo:
					_demo_caption = ""
					_finish(true, "DEMO  %.2f m\nDemo jumps don't count toward your best. Your turn!" % feet.x)
				elif feet.x >= SAND_X:
					best = maxf(best, feet.x)
					var tip := "\nYou rode the pole down. Hit LET GO when it turns green." if _auto_released else ""
					_finish(true, "%.2f m%s" % [feet.x, tip])
				else:
					_finish(false, "Splash! %.2f m — short of the sand.\nClimb higher before letting go." % maxf(feet.x, 0.0))
		State.RESULT:
			if not sim.attached:
				sim.step(dt)


func _finish(ok: bool, text: String) -> void:
	if not ok:
		last_distance = 0.0
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
	_ppm = minf(size.x / 32.0, size.y * 0.58 / 13.6)
	_ground_y = size.y * 0.64
	var target := -5.0
	if state == State.RUN or state == State.READY:
		target = minf(-5.0, run_x - 9.0)
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
			_draw_climber()
		State.FLIGHT:
			_draw_hanging(jumper_pos)
		State.RESULT:
			if result_ok:
				_draw_hanging(jumper_pos)

	_draw_climb_cam(size, font)
	_draw_hud(size, font)


## The jumper on the pole: body along the pole, legs wrapped round it, and
## two arms coloured like the thumb pads. A pressed hand reaches up and grips;
## while it pulls, the arm visibly bends as the body rises to it.
func _draw_climber() -> void:
	var u := Vector2(sin(sim.theta), cos(sim.theta))        # up the pole
	var n := Vector2(-cos(sim.theta), sin(sim.theta))       # off the pole, runway side
	var at := func(d: float, off: float) -> Vector2:
		return w2s(sim.point_on_pole(sim.s + d) + n * off)
	var body := Color("#1b3a5c")
	var w := maxf(2.5, 0.09 * _ppm)
	var shoulder: Vector2 = at.call(-0.15, 0.24)
	var hip: Vector2 = at.call(-0.85, 0.3)
	# Far arm (R) behind the body, near arm (L) in front.
	_draw_arm(1, shoulder, at, w * 1.5)
	draw_line(at.call(-0.85, 0.3), at.call(-1.2, 0.42), body, w)       # thigh
	draw_line(at.call(-1.2, 0.42), at.call(-1.55, 0.05), body, w)      # shin, wrapped on the pole
	draw_line(hip, at.call(-1.15, 0.22), body, w)
	draw_line(at.call(-1.15, 0.22), at.call(-1.65, 0.02), body, w)
	draw_line(shoulder, hip, body, w * 1.3)
	draw_circle(at.call(0.0, 0.5), 0.16 * _ppm, body)
	_draw_arm(0, shoulder, at, w * 1.5)
	var _unused := u


func _draw_arm(hand: int, shoulder: Vector2, at: Callable, w: float) -> void:
	var col: Color = HAND_COL[hand]
	var reach := 0.0          # where along the pole (from the shoulder) the hand is
	var off := 0.04           # how far off the pole the hand is
	var other := 1 - hand
	var other_prog: float = sim.stroke_progress[other]
	var other_pulling := sim.active_hand == other and other_prog < 1.0
	if sim.sliding:
		reach = 0.9           # clawing at the pole as you slide
		off = 0.35
	elif sim.grips(hand):
		var pulling := sim.active_hand == hand and sim.stroke_progress[hand] < 1.0
		if pulling:
			reach = 1.05 - 0.8 * sim.stroke_progress[hand]   # straight arm -> bent arm
		else:
			reach = 0.25 + 0.08 * hand                        # holding, arm bent
	elif other_pulling:
		# Free hand: drops to the chest, then rises to reach above as the
		# other arm finishes its pull. When it's up high: press!
		reach = lerpf(-0.1, 1.0, smoothstep(0.35, 1.0, other_prog))
		off = lerpf(0.4, 0.14, smoothstep(0.35, 1.0, other_prog))
	else:
		reach = 1.0           # waiting up high, ready to grab
		off = 0.14
	var hand_pt: Vector2 = at.call(-0.15 + reach, off)
	var elbow_out := 0.18 + 0.32 * clampf(1.0 - absf(reach) / 1.05, 0.0, 1.0)
	var elbow: Vector2 = at.call(-0.15 + reach * 0.45, 0.24 + elbow_out)
	draw_line(shoulder, elbow, col, w)
	draw_line(elbow, hand_pt, col, w)
	draw_circle(elbow, w * 0.5, col)
	draw_circle(hand_pt, w * 1.0, col)
	draw_circle(hand_pt, w * 0.45, Color(1, 1, 1, 0.8) if sim.grips(hand) else col)


## Zoomed view of the climber while on the pole, so arm movement is easy to
## match with presses.
func _draw_climb_cam(size: Vector2, font: Font) -> void:
	if state != State.POLE:
		return
	var r := Rect2(Vector2(size.x * 0.64, size.y * 0.24), Vector2(size.x * 0.34, size.y * 0.38))
	draw_rect(r, Color(0.93, 0.96, 0.98, 0.94))
	draw_rect(r, Color(0.08, 0.13, 0.17, 0.5), false, 2.0)
	var fs := int(clampf(size.y / 40.0, 11.0, 22.0))
	draw_string(font, r.position + Vector2(8, fs + 4), "CLIMB CAM", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.08, 0.13, 0.17, 0.6))
	var saved := [_ppm, _view_left, _ground_y]
	var k := r.size.y * 0.9 / 2.6
	var focus := sim.point_on_pole(sim.s - 0.2)
	var c := r.get_center()
	_ppm = k
	_view_left = focus.x - c.x / k
	_ground_y = c.y + focus.y * k
	var lo := maxf(0.0, sim.s - 1.5)
	var hi := minf(sim.pole_length, sim.s + 1.1)
	draw_line(w2s(sim.point_on_pole(lo)), w2s(sim.point_on_pole(hi)), Color("#222831"), maxf(4.0, 0.07 * k))
	_draw_climber()
	_ppm = saved[0]
	_view_left = saved[1]
	_ground_y = saved[2]


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
			lines.append("Climb: hold, grab, let go.  θ %+.0f°  ω %.2f rad/s  height %.1f m" % [
				rad_to_deg(sim.theta), sim.omega, sim.s])
			if sim.slips_in_row > 0:
				lines.append("Slipped — next slip drops you until a clean hand-to-hand switch")
			lines.append("Grab speed %.1f m/s" % _grab_speed)
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
	_draw_release_press(size)
	if state == State.READY and not demo:
		_draw_how_to(size, font, fs)
	if _demo_button_visible():
		_draw_demo_button(size, font, fs)
	if demo and state != State.RESULT:
		_draw_demo_caption(size, font, fs)

	if _banner_timer > 0.0:
		var a := clampf(_banner_timer / 0.3, 0.0, 1.0)
		var bc := _banner_color
		bc.a = a
		draw_string(font, Vector2(0, size.y * 0.3), _banner, HORIZONTAL_ALIGNMENT_CENTER, size.x,
			int(fs * 1.8), bc)

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
			return sim.next_hand()
	return -1


func _draw_thumb_pads(size: Vector2, font: Font, fs: int) -> void:
	var next := _next_hand()
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 90.0)
	var on_pole := state == State.POLE
	for hand in [0, 1]:
		var r := _pad_rect(size, hand)
		var lit: bool = next == -1 or next == hand
		var held: bool = on_pole and sim.hand_down[hand]
		var prog: float = sim.stroke_progress[hand]
		var pulling: bool = held and sim.active_hand == hand and prog < 1.0
		var other: int = 1 - hand
		var other_done: bool = on_pole and sim.hand_down[other] and sim.stroke_progress[other] >= 1.0
		var other_pulling: bool = on_pole and sim.active_hand == other and sim.stroke_progress[other] < 1.0

		var hc: Color = HAND_COL[hand]
		var fill := Color(hc, 0.3 + 0.3 * pulse) if lit else Color(1, 1, 1, 0.12)
		var verb := "run"
		if on_pole:
			if held and pulling:
				fill = Color(hc, 0.9)
				verb = "pulling..."
			elif held and other_pulling:
				fill = Color(hc, 0.4 + 0.3 * pulse)
				verb = "let go"
			elif held:
				fill = Color(hc, 0.7)
				verb = "hold"
			elif lit and other_done:
				fill = Color(0.18, 0.75, 0.44, 0.45 + 0.4 * pulse)
				verb = "GRAB!"
			else:
				verb = "grab" if lit else ""
			if sim.sliding:
				fill = Color(0.75, 0.2, 0.15, 0.4 + 0.4 * pulse)
				verb = "GRAB!"
		var tapped := _pad_flash[hand] > 0.0
		if tapped and not on_pole:
			fill = Color(1.0, 0.85, 0.3, 0.85)
		draw_rect(r, fill)
		draw_rect(r, Color(1, 1, 1, 0.6 if lit or held else 0.25), false, 2.0)

		# Arm-pull meter along the top of the pad.
		if on_pole and (held or (sim.last_pull_hand == hand and prog < 1.0)):
			var bar := Rect2(r.position + Vector2(6, 6), Vector2((r.size.x - 12) * prog, fs * 0.45))
			draw_rect(Rect2(r.position + Vector2(6, 6), Vector2(r.size.x - 12, fs * 0.45)), Color(0, 0, 0, 0.25))
			draw_rect(bar, Color("#3ddc84") if prog >= 1.0 else Color("#ffd24a"))

		# Fingertip: shows a held hand (or a running tap) so presses read clearly.
		if held or tapped:
			var k := 1.0 if held else _pad_flash[hand] / 0.18
			draw_circle(r.get_center(), r.size.y * (0.24 + 0.1 * (1.0 - k)), Color(1, 1, 1, 0.3 + 0.25 * k))

		var label := "L" if hand == 0 else "R"
		draw_string(font, r.position + Vector2(0, r.size.y * 0.6), label, HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, int(fs * 2.2), Color(1, 1, 1, 0.95 if lit or held else 0.45))
		draw_string(font, r.position + Vector2(0, r.size.y * 0.87), verb, HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, fs, Color(1, 1, 1, 0.95 if lit or held else 0.4))


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


## The LET GO button lingers for a moment after a press, so the demo's
## release (and the player's) visibly lands.
func _draw_release_press(size: Vector2) -> void:
	if _release_flash <= 0.0:
		return
	var c := _release_center(size)
	var r := _release_radius(size)
	var k := _release_flash / 0.35
	draw_circle(c, r, Color(0.18, 0.75, 0.44, 0.6 * k))
	draw_arc(c, r * (1.0 + 0.6 * (1.0 - k)), 0, TAU, 48, Color(1, 1, 1, k), 4.0)
	draw_circle(c, r * 0.35, Color(1, 1, 1, 0.5 * k))


# ---------------------------------------------------------------- demo ---

func _demo_button_visible() -> bool:
	return (state == State.READY and not demo) or (state == State.RESULT and _result_timer > 0.6)


func _demo_button_rect(size: Vector2) -> Rect2:
	var w := size.x * 0.34
	var h := size.y * 0.09
	if state == State.RESULT:
		# Top-right, so it doesn't cover the jumper on the sand.
		return Rect2(Vector2(size.x - w - size.x * 0.02, size.y * 0.03), Vector2(w, h))
	return Rect2(Vector2((size.x - w) / 2.0, size.y * 0.535), Vector2(w, h))


func _draw_demo_button(size: Vector2, font: Font, fs: int) -> void:
	var r := _demo_button_rect(size)
	draw_rect(r, Color("#14212b"))
	draw_rect(r, Color(1, 1, 1, 0.8), false, 2.0)
	# Play triangle
	var t := r.position + Vector2(r.size.y * 0.45, r.size.y * 0.25)
	var tri := PackedVector2Array([t, t + Vector2(0, r.size.y * 0.5), t + Vector2(r.size.y * 0.42, r.size.y * 0.25)])
	draw_colored_polygon(tri, Color("#ffd24a"))
	draw_string(font, r.position + Vector2(r.size.y * 0.5, r.size.y * 0.5 + fs * 0.35), "Watch a perfect jump",
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x - r.size.y * 0.5, fs, Color.WHITE)


func _draw_demo_caption(size: Vector2, font: Font, fs: int) -> void:
	var badge := Rect2(Vector2(size.x - fs * 6.5, fs * 0.6), Vector2(fs * 5.5, fs * 1.6))
	draw_rect(badge, Color("#ffd24a"))
	draw_string(font, badge.position + Vector2(0, badge.size.y * 0.72), "DEMO", HORIZONTAL_ALIGNMENT_CENTER,
		badge.size.x, fs, Color("#14212b"))
	if _demo_caption == "":
		return
	var cap := Rect2(Vector2(size.x * 0.12, size.y * 0.15), Vector2(size.x * 0.76, fs * 2.2))
	draw_rect(cap, Color(0.08, 0.13, 0.17, 0.82))
	draw_string(font, cap.position + Vector2(0, cap.size.y * 0.66), _demo_caption, HORIZONTAL_ALIGNMENT_CENTER,
		cap.size.x, fs, Color.WHITE)


func _draw_how_to(size: Vector2, font: Font, fs: int) -> void:
	var w := size.x * 0.56
	var h := size.y * 0.42
	var r := Rect2(Vector2((size.x - w) / 2.0, size.y * 0.1), Vector2(w, h))
	draw_rect(r, Color(1, 1, 1, 0.88))
	var ink := Color("#14212b")
	var steps := [
		"1   RUN:  tap  L, R, L, R ...",
		"2   CLIMB:  hold one side; when the other arm reaches up, press it",
		"3   LET GO:  big button, when it turns green",
	]
	var y := r.position.y + fs * 1.8
	draw_string(font, Vector2(r.position.x, y), "How to jump", HORIZONTAL_ALIGNMENT_CENTER, w, int(fs * 1.3), ink)
	y += fs * 2.0
	for s in steps:
		draw_string(font, Vector2(r.position.x + fs, y), s, HORIZONTAL_ALIGNMENT_LEFT, w - fs * 2, fs, ink)
		y += fs * 1.7
	draw_string(font, Vector2(r.position.x, r.end.y - fs * 0.8), "Tap L or R to start", HORIZONTAL_ALIGNMENT_CENTER, w, fs, Color("#2e86ab"))
