extends SceneTree
## Finds the demo's run rhythm, climb delay and release angle by brute force
## against the real game loop (same _tick, same physics rate).
## Run after physics changes:
##   godot --headless --path . -s res://tools/optimize_demo.gd
## then copy the printed values into demo_run_tap / demo_climb_delay /
## demo_release_angle in scripts/game.gd.

func _init() -> void:
	var game: Node2D = load("res://scripts/game.gd").new()
	var dt := 1.0 / 240.0
	var best := {"x": 0.0}
	for tap_i in range(8, 21):            # 0.08 .. 0.20 s between steps
		var tap := tap_i / 100.0
		var row_best := 0.0
		for d_i in range(0, 25):          # 0.00 .. 1.20 s climb delay
			var d := d_i * 0.05
			for a_i in range(0, 26):      # 0.50 .. 1.00 rad release angle
				var a := 0.5 + a_i * 0.02
				game.start_demo()
				game.demo_run_tap = tap
				game.demo_climb_delay = d
				game.demo_release_angle = a
				var n := 0
				while game.state != game.State.RESULT and n < 4800:
					game._tick(dt)
					n += 1
				if game.result_ok:
					row_best = maxf(row_best, game.last_distance)
					if game.last_distance > best.x:
						best = {"x": game.last_distance, "tap": tap, "d": d, "a": a, "v": game._grab_speed}
		print("run tap %.2f s -> best %.2f m" % [tap, row_best])
	print("BEST %.2f m  run_tap %.2f  climb_delay %.2f  release_angle %.2f  (grab speed %.2f m/s)" % [
		best.x, best.tap, best.d, best.a, best.v])
	game.free()
	quit()
