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
## The 2*m*s*s'*omega term is the heart of the game: climbing brakes the pole.

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
var stroke_length := 0.5      # metres gained per hand-over-hand stroke
var stroke_time := 0.25       # seconds per stroke
var top_margin := 0.6         # how close to the tip the jumper can get
var forced_release_angle := 1.35  # pole nearly flat: jumper drops off

# --- State ---
var theta := 0.0
var omega := 0.0
var s := 0.0
var attached := false
var climb_speed := 0.0
var _stroke_timer := 0.0
var _queued_strokes := 0
var _last_hand := -1


func reset() -> void:
	theta = start_lean
	omega = 0.0
	s = grab_height
	attached = false
	climb_speed = 0.0
	_stroke_timer = 0.0
	_queued_strokes = 0
	_last_hand = -1


func inertia() -> float:
	var m := jumper_mass if attached else 0.0
	return pole_mass * pole_length * pole_length / 3.0 + m * s * s


func max_climb() -> float:
	return pole_length - top_margin


## Jumper hits the pole at run_speed (m/s). Angular momentum about the base
## from a horizontal run is m*s*v*cos(theta); only part of it survives the grab.
func grab(run_speed: float) -> void:
	attached = true
	omega = grab_efficiency * jumper_mass * s * run_speed * cos(theta) / inertia()


## A climbing tap. Hands must alternate (0 = left, 1 = right).
## Returns false for a fumble (same hand twice).
func request_stroke(hand: int) -> bool:
	if not attached or s >= max_climb():
		return false
	if hand == _last_hand:
		return false
	_last_hand = hand
	_queued_strokes = mini(_queued_strokes + 1, 2)
	return true


func step(dt: float) -> void:
	# Climbing: each stroke moves the jumper up at a constant rate.
	if attached:
		if _stroke_timer <= 0.0 and _queued_strokes > 0:
			_queued_strokes -= 1
			_stroke_timer = stroke_time
		if _stroke_timer > 0.0 and s < max_climb():
			climb_speed = stroke_length / stroke_time
			_stroke_timer -= dt
		else:
			climb_speed = 0.0
			_stroke_timer = maxf(_stroke_timer - dt, 0.0)
	else:
		climb_speed = 0.0

	var m := jumper_mass if attached else 0.0
	var i := inertia()
	var torque := G * sin(theta) * (pole_mass * pole_length / 2.0 + m * s)
	var omega_dot := (torque - 2.0 * m * s * climb_speed * omega - damping * omega * i) / i
	omega += omega_dot * dt
	theta += omega * dt
	if attached:
		s = minf(s + climb_speed * dt, max_climb())

	# A pole on its own ends up lying in the water or on the bank.
	if not attached and absf(theta) > PI / 2.0 - 0.05:
		theta = signf(theta) * (PI / 2.0 - 0.05)
		omega = 0.0


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


## Velocity of the jumper's hands: rotation of the pole plus climbing along it.
func hand_velocity() -> Vector2:
	var tangential := Vector2(cos(theta), -sin(theta)) * (s * omega)
	var along := Vector2(sin(theta), cos(theta)) * climb_speed
	return tangential + along


## Let go. Returns the jumper's launch velocity; the pole carries on alone.
func release() -> Vector2:
	var v := hand_velocity()
	attached = false
	climb_speed = 0.0
	return v
