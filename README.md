# omarchy-attention

Look away from your screen and it blurs. Look back and it clears.

A privacy shield for [Omarchy](https://omarchy.org), in the spirit of
ShyGlass on macOS — built on the head-pose stream from
[glanced](https://github.com/ayandexyz/glance-linux), the face-unlock daemon.
Someone walks up behind you, you turn to talk to them, and whatever was on
your screen is a frosted blur until you turn back.

## What makes it different

- **No screen capture.** ShyGlass screenshots your display and blurs the
  snapshot, which is why it needs Screen Recording permission. This puts a
  translucent surface over the screen and asks the compositor to blur what is
  already behind it (`ext-background-effect`). No portal prompt, and not one
  pixel of your screen in any userspace buffer but the compositor's own.
- **No face leaves the daemon.** `glanced` sends two angles and a bool over a
  publish-only socket — never frames, never landmarks. The shield cannot
  reach the camera, and nothing on that socket can touch face unlock.
- **Takes no input.** The veil has an empty input region and no keyboard
  interactivity. Keep typing from the paper on your desk; every key and
  click goes straight through.
- **Fails open.** Daemon crashes, camera unplugged, socket closes, no event
  for 1.5 s — the veil comes down. There is no code path where a crash leaves
  your screen covered.
- **Works without enrolling.** Attention mode uses only the landmarker. You do
  not need to have enrolled a face, armed the daemon, or touched PAM. Anyone
  with a webcam can run this.
- **Proportional and directional.** Inside a 15° comfort zone nothing
  happens. Past it the veil comes in from the side you turned toward, and
  advances with your head — half turned, half covered — until at 35° the
  screen is fully covered. Turn back and it recedes the same way. The motion
  is velocity-smoothed, so it follows you rather than snapping.
- **Cheap.** The daemon runs the landmarker at 8 fps only while the shield is
  subscribed: about 8% of one core, camera included. The veil is unmapped
  while idle, so it costs the compositor nothing.

## Install

You need `glanced` 0.3 or later (the release with `attention.sock`) running
as your user:

```bash
pipx install 'glanced[runtime]'
glancectl install-service            # fetches the models, writes the unit, starts it
```

That is the daemon only. Attention mode uses the landmarker alone, so you do
not need to enroll, arm, or touch PAM — add face unlock later from that
project's README if you want it.

Check the stream before going further:

```bash
glancectl attention                  # should print yaw/pitch lines; Ctrl-C
```

Then the plugin:

```bash
omarchy plugin add https://github.com/ayandexyz/omarchy-attention.git --enable
```

An eye appears in the bar. Turn your head past 15° and the veil starts to
come in from that side; by 35° the screen is covered. Turn back and it
recedes.

### Blur

Omarchy ships with compositor blur off. Without it the veil is a 92% tint of
your theme's background, which hides the screen but is not pretty. For the
frosted-glass look, in `~/.config/hypr/looknfeel.lua`:

```lua
hl.config({ decoration = { blur = { enabled = true, passes = 3, size = 8 } } })
```

and turn the veil opacity down to ~0.65 in the widget's settings. Blur costs
GPU on every transparent window, not just this one, so it is your call.

### Keys

Plugins cannot bind keys, so in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + S", "Attention: toggle",   "omarchy-shell io.github.ayandexyz.attention toggle")
o.bind("SUPER + SHIFT + C", "Attention: recentre", "omarchy-shell io.github.ayandexyz.attention recenter")
o.bind("SUPER + SHIFT + X", "Attention: cover now", "omarchy-shell io.github.ayandexyz.attention cover 30")
```

`cover` is the panic key: veil up for N seconds regardless of where you are
looking, then it fails open like everything else.

## Using it

| Bar icon | |
|---|---|
| Left click | open the panel |
| Right click | toggle the shield on/off (remembered) |
| Middle click | recentre |

**Recentre** tells the shield that the way you are facing right now is
"straight ahead". The camera defines zero, so a webcam off to one side of an
ultrawide, or a laptop on a stand beside your monitor, needs this once. It is
remembered.

**Snooze** holds the veil down for five minutes (configurable). The shield
also never engages over a fullscreen window — presentations, films, games —
unless you turn that off.

**Settings** (bar widget settings): comfort zone, fully-covered angle,
whether the veil follows your head or acts as a switch, dwell and release
(for the switch and for an empty chair), whether an empty chair counts, veil
opacity, snooze length, directional sweep. Nothing inside the comfort zone
ever moves the veil, so reading, typing and glancing at the keyboard are
free.

### IPC

```
omarchy-shell io.github.ayandexyz.attention toggle|enable|disable
omarchy-shell io.github.ayandexyz.attention recenter
omarchy-shell io.github.ayandexyz.attention snooze [seconds]
omarchy-shell io.github.ayandexyz.attention wake
omarchy-shell io.github.ayandexyz.attention cover [seconds]
omarchy-shell io.github.ayandexyz.attention state      # JSON: what it sees and why
```

## How it works

```
glanced ──attention.sock──▶ Service.qml ──▶ one PanelWindow per output
 8 fps    {present,yaw,pitch}   AttentionLogic.js     overlay layer, empty input
 landmarker only               hysteresis +      region, compositor blur,
                               dwell + watchdog  opacity ramp
```

`Service.qml` is a headless service plugin: it holds the socket, runs the
state machine in `AttentionLogic.js`, and owns the veil surfaces. `BarWidget.qml`
is the switch and the readout; the shield works without it showing.

Only the daemon's `tracking` state means anything. `starting`, `paused` (an
unlock scan has the camera), `error`, silence, or a disconnect all drop the
veil immediately.

## Tests

```bash
tests/run
```

Runs the state machine under node against scripted event streams with a fake
clock — dwell, hysteresis, release, recentre, absence, every non-tracking
state, the watchdog — then validates the manifest.

## License

MIT
