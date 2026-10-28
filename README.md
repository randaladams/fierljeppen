# Fierljeppen

An Android game of fierljeppen — Frisian canal pole-vaulting — built in Godot 4.7.

The plan is two modes on one physics model:

- **Zen** — the same simulation with invisible assists (stall help, wider timing windows, lean correction). Hard to fail, but a bad jump still feels bad.
- **Simulation** — a competition ladder where each tier adds one skill demand (rhythm → climb pacing → steering → conditions → release craft), gated by skill checks rather than grinding.

This repository currently holds the **physics prototype**: everything is drawn with `_draw()` so the feel can be tuned before any art exists.

## Install on a phone

Every push to `main` builds a debug APK (GitHub Actions, `.github/workflows/android.yml`) and publishes it on the [latest release](https://github.com/randaladams/fierljeppen/releases/tag/latest).

1. Open that link on the phone and tap **fierljeppen.apk**.
2. Open the download. Android will ask to allow installs from your browser; allow it once.
3. Later builds install over the previous one (they share the debug key in `signing/`, which is for testing only — a Play Store release needs its own private key).

## Running it on a computer

Open the folder in Godot 4.7+ and press Play, or:

```sh
godot --path .
```

Physics checks (headless, no display needed):

```sh
godot --headless --path . -s res://tests/test_pole_sim.gd
```

Scripted jump with screenshots (needs a display, e.g. `xvfb-run`):

```sh
godot --path . --rendering-driver opengl3 --fixed-fps 60 -s res://tools/capture.gd
```

## Controls (prototype)

| Phase | Touch | Keyboard |
|---|---|---|
| Run-up | Tap left / right halves alternately. Same side twice = stumble. | Left/A, Right/D |
| Grab | Automatic at the jetty edge; your run speed becomes pole momentum. | — |
| Climb | Alternate left / right taps, one hand-over-hand stroke each. | Left/A, Right/D |
| Let go | Tap the **LET GO** bar at the top. | Space |
| Reset | Tap after the result. | R |

## The physics

The pole is a rigid rod pivoting at its base in the canal bed; the jumper is a point mass `m` at distance `s` up the pole. With `θ` the angle from vertical (negative = leaning back toward the runway):

```
I·θ'' = g·sin θ·(M·L/2 + m·s)  −  2·m·s·s'·θ'  −  c·I·θ'
I     = M·L²/3 + m·s²
```

The middle term is the game. **Climbing brakes the pole.** Climb too early on a slow run and the pole stalls before vertical — you fall back into the canal. Climb too late and you are still low when the pole tips over — you land short. Real fierljeppers pass the dead centre as slowly as they dare to buy climbing time; this is that tension.

- **Grab:** angular momentum from the run is `m·s·v·cos θ`, scaled by `grab_efficiency` (the jump and the grab lose most of it).
- **Release:** launch velocity is the hands' velocity — pole rotation `s·θ'` plus climb speed along the pole. There is a sweet spot around 50° past vertical; letting go earlier or riding it down both lose distance.
- **Distance:** measured where the feet first touch the sand, from the jetty edge.

`tests/test_pole_sim.gd` locks these behaviours in, so a tuning change that kills the skill window fails the test.

## Tuning knobs

All in `scripts/pole_sim.gd` (physics) and the constants at the top of `scripts/game.gd` (run-up, layout).

| Knob | Effect |
|---|---|
| `grab_efficiency` | How much run speed becomes rotation. Higher = more forgiving, faster jumps. |
| `start_lean` | How far the pole leans back at the start. More lean = harder to get over vertical. |
| `grab_height` | Higher grab = head start on the climb, but more inertia to rotate. |
| `stroke_length`, `stroke_time` | Climb speed, and how strongly climbing brakes the pole. |
| `damping` | Mud friction at the base. Later: varies with conditions. |
| `RUN_TAP_GAIN`, `RUN_DECAY` | How hard it is to build run-up speed. |

## Layout

```
project.godot
scenes/main.tscn        single scene, Node2D with game.gd
scripts/pole_sim.gd     physics (no rendering, unit-testable)
scripts/game.gd         state machine, input, debug drawing
tests/test_pole_sim.gd  headless physics checks
tools/capture.gd        scripted jump + screenshots
```

## Next steps

1. Sideways lean (second angle) with tilt-to-steer, and landing off the side of the sand bed.
2. Grab timing input instead of the automatic grab.
3. Training overlay: slow-motion replay with θ, θ' and climb-rate graphs.
4. Zen assists as parameters on top of `PoleSim`.
5. Android export preset and a debug keystore.
6. Art pass: jumper animation, canal, Frisian landscape.
