extends SceneTree
## Plays one scripted jump and saves screenshots to user://captures/.
## Needs a display (e.g. xvfb-run):
##   godot --path . --rendering-driver opengl3 --fixed-fps 60 -s res://tools/capture.gd

var game: Node
var frame := 0
var hand := 0
var shots := {3: "ready", 60: "run", 160: "grab", 230: "climb", 300: "top", 470: "result"}


func _initialize() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	DirAccess.make_dir_recursive_absolute("user://captures")


func _process(_delta: float) -> bool:
	frame += 1
	var tap_every := 7 if game.state == game.State.RUN else 15
	if frame > 5 and frame % tap_every == 0 and game.state in [game.State.READY, game.State.RUN, game.State.POLE]:
		game._on_hand(hand)
		hand = 1 - hand
	if game.state == game.State.POLE and game.sim.theta >= 0.9:
		game._let_go()
	if shots.has(frame):
		var img := root.get_texture().get_image()
		var path := "user://captures/%03d_%s.png" % [frame, shots[frame]]
		img.save_png(path)
		print("saved ", ProjectSettings.globalize_path(path), "  state=", game.state)
	return frame > 480
