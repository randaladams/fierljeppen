extends SceneTree
## Plays the demo ("perfect jump") and saves screenshots to user://captures/
## at key moments. Needs a display (e.g. xvfb-run):
##   godot --path . --rendering-driver opengl3 --fixed-fps 60 -s res://tools/capture.gd

var game: Node
var frame := 0
var taken := {}
var pole_frames := 0


func _initialize() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	DirAccess.make_dir_recursive_absolute("user://captures")


func _shot(name: String) -> void:
	if taken.has(name):
		return
	taken[name] = true
	var path := "user://captures/%d_%s.png" % [taken.size(), name]
	root.get_texture().get_image().save_png(path)
	print("saved ", path, "  frame=", frame)


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 3:
		_shot("ready")
	if frame == 5:
		game.start_demo()
	if game.state == game.State.RUN and frame == 60:
		_shot("run")
	if game.state == game.State.POLE:
		pole_frames += 1
		if pole_frames == 20:
			_shot("grab")
		if game.sim.theta > 0.2:
			_shot("climb")
		# A pull early, middle and late, to check the arm animation.
		if game.sim.active_hand >= 0 and pole_frames > 60:
			var p: float = game.sim.stroke_progress[game.sim.active_hand]
			if p > 0.05 and p < 0.15: _shot("pull_start")
			if p > 0.45 and p < 0.55 and taken.has("pull_start"): _shot("pull_mid")
			if p > 0.85 and p < 0.98 and taken.has("pull_mid"): _shot("pull_end")
	if game.state == game.State.FLIGHT:
		_shot("release")
	if game.state == game.State.RESULT and game._result_timer > 0.7:
		_shot("result")
		return true
	return frame > 1200
