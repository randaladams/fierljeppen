extends SceneTree
## Game-level check: two slips without a clean switch and no regrab ends in
## the canal; a regrab during the drop saves the jump.
##   godot --headless --path . -s res://tests/test_game_slips.gd

const DT := 1.0 / 240.0
var failures := 0


func ticks(game: Node, seconds: float) -> void:
	var t := 0.0
	while t < seconds and game.state != game.State.RESULT:
		game._tick(DT)
		t += DT


func to_pole(game: Node) -> void:
	game.reset()
	var t := 0.0
	var h := 0
	game._on_hand(h)
	while game.state != game.State.POLE:
		t += DT
		if fmod(t, 0.16) < DT:
			h = 1 - h
			game._on_hand(h)
		game._tick(DT)


func check(name: String, cond: bool, info: Variant) -> void:
	print(("PASS " if cond else "FAIL ") + name + "  " + str(info))
	if not cond:
		failures += 1


func _init() -> void:
	var game: Node2D = load("res://scripts/game.gd").new()

	to_pole(game)
	game._on_hand(1); ticks(game, 0.3); game._on_hand_up(1)
	game._on_hand(0); ticks(game, 0.3); game._on_hand_up(0)      # slip 1 (no other hand)
	ticks(game, 0.6)
	game._on_hand(1); ticks(game, 0.3); game._on_hand_up(1)      # slip 2 -> drop
	ticks(game, 6.0)
	check("uncaught drop ends in the canal", game.state == game.State.RESULT and not game.result_ok and "canal" in game.result_text,
		game.result_text.split("\n")[0])

	to_pole(game)
	game._on_hand(1); ticks(game, 0.3); game._on_hand_up(1)
	game._on_hand(0); ticks(game, 0.3); game._on_hand_up(0)      # slip 1
	ticks(game, 0.6)
	game._on_hand(1); ticks(game, 0.3); game._on_hand_up(1)      # drop
	ticks(game, 0.25)
	game._on_hand(0)                                             # regrab
	check("regrab during the drop saves you", game.state == game.State.POLE and not game.sim.sliding, game.sim.s)

	game.free()
	print("RESULT: %d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
