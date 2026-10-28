class_name PoleSim
extends RefCounted
## Pole + climber physics for fierljeppen.
##
## World units are metres, y points up, x points across the canal.
## The pole is a rigid rod pivoting at its base (stuck in the canal bed).
## theta is the pole angle from vertical: negative leans back toward the
## runway, positive leans forward toward the sand.
##
## Equation of motion (jumper as a point mass m at distance s up the pole):
##     d/dt (I * omega) = g * sin(theta) * (M*L/2 + m*s)  - damping
##     I = M*L^2/3 + m*s^2
## Expanding gives  I*omega' = torque - 2*m*s*s'*omega - c*I*omega
## The 2*m*s*s'*omega term is the heart of the game: climbing (s' > 0)
## brakes the pole, and sliding down (s' < 0) speeds it up.
##
## Climbing is hand over hand: press a hand to grip, hold it to pull
## (one arm's length per stroke), then grip with the other hand and let go
## of the first. Letting go with no grip left is a slip:
##   1st slip  - slide ~half a metre, then the legs catch you.
##   2nd slip  - (before a clean hand-to-hand transfer) you drop and keep
##               sliding until a hand grabs the pole again, or you hit the water.

const G := 9.81

# --- Tunables (see README for what each one does to the feel) ---
var pole_length := 12.0       # L, metres
var pole_mass := 4.0          # M, kg (carbon pole)
var jumper_mass := 75.0       # m, kg
var base_x := 1.0             # pole base distance from the jetty edge
var start_lean := -0.35       # initial lean back toward the runway, rad
var grab_height := 2.6        # where along the pole the jumper grabs, m
var grab_efficiency := 0.4    # fraction of run momentum the pole receives
var damping := 0.05           # mud / base friction, 1/s
var stroke_length := 0.6      # metres gained by one full arm pull
var stroke_time := 0.3        # seconds for one full arm pull
var top_margin := 0.6         # how close to the tip the jumper can get
var forced_release_angle := 1.35  # pole nearly flat: jumper drops off
var slip_catch_distance := 0.5    # legs catch you after this much slide
var leg_friction := 0.6       # fraction of gravity the legs resist on a slip
var drop_friction := 0.25     # ...and on a drop (legs have lost the pole)
var regrab_time := 0.25       # a hand that catches a drop needs this long before pulling
var water_level_s := 0.8      # slide below this and your feet are in the canal

# --- State ---
var theta := 0.0
var omega := 0.0
var s := 0.0
var s_dot := 0.0              # signed: + climbing, - sliding
var attached := false
var hand_down: Array[bool] = [false, false]   # player is holding this hand
var stroke_progress: Array[float] = [1.0, 1.0]
var active_hand := -1         # the hand currently pulling
var last_pull_hand := -1
var sliding := false
var dropping := false         # a second slip: no leg catch
var slips_in_row := 0
var fell_in := false          # slid all the way down into the water
var _virtual_grip: Array[bool] = [false, false]  # the initial grab, holding in place of each hand
var _legs := false            # legs wrapped round the pole after a slip; let go once you climb
var _slide_distance := 0.0
var _regrab_timer := 0.0


func reset() -> void:
	theta = start_lean
	omega = 0.0
	s = grab_height
	s_dot = 0.0
	attached = false
	hand_down = [false, false]
	stroke_progress = [1.0, 1.0]
	active_hand = -1
	last_pull_hand = -1
	sliding = false
	dropping = false
	slips_in_row = 0
	fell_in = false
	_virtual_grip = [false, false]
	_legs = false
	_slide_distance = 0.0
	_regrab_timer = 0.0


func inertia() -> float:
	var m := jumper_mass if attached else 0.0
	return pole_mass * pole_length * pole_length / 3.0 + m * s * s


func max_climb() -> float:
	return pole_length - top_margin


## Jumper hits the pole at run_speed (m/s). Angular momentum about the base
## from a horizontal run is m*s*v*cos(theta); only part of it survives the grab.
## The jumper lands on the pole holding on with both hands and legs.
func grab(run_speed: float) -> void:
	attached = true
	omega = grab_efficiency * jumper_mass * s * run_speed * cos(theta) / inertia()
	_virtual_grip = [true, true]


func has_grip() -> bool:
	return hand_down[0] or hand_down[1] or _virtual_grip[0] or _virtual_grip[1] or _legs


## The hand that should pull next (-1 = either).
func next_hand() -> int:
	return -1 if last_pull_hand < 0 else 1 - last_pull_hand


## Player presses a hand. Returns what happened:
## "grip" (new pull starts), "fumble" (same hand again: no pull),
## "catch" (stopped a slide), or "" (ignored).
func press(hand: int) -> String:
	if not attached or hand_down[hand]:
		return ""
	hand_down[hand] = true
	_virtual_grip[hand] = false
	_legs = false   # unwrap the legs to climb again
	if sliding:
		# Grabbing during a slide arrests it, but the arm takes a moment.
		sliding = false
		s_dot = 0.0
		_virtual_grip = [false, false]
		_regrab_timer = regrab_time
		_start_pull(hand)
		return "catch"
	if hand == last_pull_hand:
		return "fumble"
	if hand_down[1 - hand]:
		slips_in_row = 0   # clean hand-to-hand transfer
	_start_pull(hand)
	return "grip"


## Player releases a hand. Returns "slip", "drop" or "".
func release_hand(hand: int) -> String:
	if not attached or not hand_down[hand]:
		return ""
	hand_down[hand] = false
	if active_hand == hand:
		active_hand = -1   # a pull cut short only gains part of a stroke
	if not has_grip() and not sliding:
		_slip()
		return "drop" if dropping else "slip"
	return ""


func _start_pull(hand: int) -> void:
	active_hand = hand
	last_pull_hand = hand
	stroke_progress[hand] = 0.0


func _slip() -> void:
	slips_in_row += 1
	sliding = true
	dropping = slips_in_row >= 2
	_slide_distance = 0.0
	s_dot = 0.0
	active_hand = -1


func step(dt: float) -> void:
	if attached:
		_step_climber(dt)
	else:
		s_dot = 0.0

	var m := jumper_mass if attached else 0.0
	var i := inertia()
	var torque := G * sin(theta) * (pole_mass * pole_length / 2.0 + m * s)
	var omega_dot := (torque - 2.0 * m * s * s_dot * omega - damping * omega * i) / i
	omega += omega_dot * dt
	theta += omega * dt

	# A pole on its own ends up lying in the water or on the bank.
	if not attached and absf(theta) > PI / 2.0 - 0.05:
		theta = signf(theta) * (PI / 2.0 - 0.05)
		omega = 0.0


func _step_climber(dt: float) -> void:
	if sliding:
		# Gravity along the pole, partly resisted by legs (or not, on a drop).
		var friction := drop_friction if dropping else leg_friction
		s_dot -= G * cos(theta) * (1.0 - friction) * dt
		var ds := s_dot * dt
		s += ds
		_slide_distance -= ds
		if not dropping and _slide_distance >= slip_catch_distance:
			sliding = false
			s_dot = 0.0
			_legs = true   # legs wrapped round the pole
		if s <= water_level_s:
			s = water_level_s
			s_dot = 0.0
			sliding = false
			fell_in = true
		return

	if _regrab_timer > 0.0:
		_regrab_timer -= dt
		s_dot = 0.0
		return

	if active_hand >= 0 and stroke_progress[active_hand] < 1.0 and s < max_climb():
		s_dot = stroke_length / stroke_time
		stroke_progress[active_hand] = minf(1.0, stroke_progress[active_hand] + dt / stroke_time)
		s = minf(s + s_dot * dt, max_climb())
	else:
		s_dot = 0.0   # hanging: arm fully pulled, or nothing pulling


func is_falling_back() -> bool:
	return attached and omega < 0.0 and theta < 0.0


func must_release() -> bool:
	return attached and theta >= forced_release_angle


func base_position() -> Vector2:
	return Vector2(base_x, 0.0)


func point_on_pole(dist: float) -> Vector2:
	return Vector2(base_x + dist * sin(theta), dist * cos(theta))


func hand_position() -> Vector2:
	return point_on_pole(s)


func tip_position() -> Vector2:
	return point_on_pole(pole_length)


## Velocity of the jumper's hands: rotation of the pole plus motion along it.
func hand_velocity() -> Vector2:
	var tangential := Vector2(cos(theta), -sin(theta)) * (s * omega)
	var along := Vector2(sin(theta), cos(theta)) * s_dot
	return tangential + along


## Let go. Returns the jumper's launch velocity; the pole carries on alone.
func release() -> Vector2:
	var v := hand_velocity()
	attached = false
	s_dot = 0.0
	active_hand = -1
	return v
