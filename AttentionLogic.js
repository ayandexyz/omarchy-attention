.pragma library

// The shield's decision logic, kept pure so it can be run under node with a
// scripted stream of events and a fake clock. Nothing here touches QML.
//
// Input is the daemon's attention event (see glance-linux, attention.py):
//   {schemaVersion:1, t, state, present, yaw, pitch, conf}
// Output is one bool: shielded. Everything between is hysteresis and time.

var SCHEMA_VERSION = 1

var DEFAULTS = {
  // Degrees of head turn, relative to the recentre offset. Inside `exitAngle`
  // is the comfort zone: nothing happens. Past `enterAngle` the screen is
  // fully covered. Between the two is the transition: in gradual mode the
  // veil advances in proportion to how far you have turned, ShyGlass-style,
  // so it softens as you turn rather than snapping. In switch mode the pair
  // is a plain hysteresis band with a dwell.
  enterAngle: 35,
  exitAngle: 15,
  gradual: true,
  // Exponential smoothing on yaw before it drives the veil, 0..1: how much of
  // each new 8 fps reading to take. Landmarker jitter is a degree or two;
  // this keeps it from shimmering the veil's edge.
  yawSmoothing: 0.5,
  // How long the head must stay turned before the shield engages, and how
  // long it must be back before it clears. Engaging is the slow direction.
  dwellMs: 350,
  releaseMs: 200,
  // Nobody in front of the camera at all. Walking away is the case a privacy
  // shield exists for, so it counts as "away" — with a longer dwell, since a
  // dropped detection for a frame or two must not blank the screen.
  absentShields: true,
  absentDwellMs: 2000,
  // No event for this long means the daemon is gone, paused for a scan, or
  // wedged. Whatever the reason: shield down.
  staleMs: 1500,
  // Do not shield over a fullscreen window: presentations, films, games.
  suspendFullscreen: true,
  // How opaque the veil is at rest. With compositor blur this sits at an
  // airy frosted glass level (~0.48) rather than a dense, heavy dark wall.
  veilOpacity: 0.48,
  // Sweep the veil in from the side you turned toward (and back out the same
  // way), rather than a flat fade.
  directionalSweep: true,
  snoozeSeconds: 300
}

function clamp(value, low, high, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  return Math.min(high, Math.max(low, n))
}

// Settings as the widget hands them over: anything missing takes the default,
// anything absurd is pulled into range, and exit is always inside enter.
function normalizeSettings(raw) {
  raw = raw || {}
  var s = {}
  s.enterAngle = clamp(raw.enterAngle, 5, 80, DEFAULTS.enterAngle)
  s.exitAngle = clamp(raw.exitAngle, 2, 80, DEFAULTS.exitAngle)
  if (s.exitAngle >= s.enterAngle) s.exitAngle = Math.max(2, s.enterAngle - 5)
  s.gradual = raw.gradual === undefined ? DEFAULTS.gradual : !!raw.gradual
  s.yawSmoothing = clamp(raw.yawSmoothing, 0.05, 1, DEFAULTS.yawSmoothing)
  s.dwellMs = clamp(raw.dwellMs, 0, 5000, DEFAULTS.dwellMs)
  s.releaseMs = clamp(raw.releaseMs, 0, 5000, DEFAULTS.releaseMs)
  s.absentShields = raw.absentShields === undefined ? DEFAULTS.absentShields : !!raw.absentShields
  s.absentDwellMs = clamp(raw.absentDwellMs, 0, 30000, DEFAULTS.absentDwellMs)
  s.staleMs = clamp(raw.staleMs, 500, 10000, DEFAULTS.staleMs)
  s.suspendFullscreen = raw.suspendFullscreen === undefined ? DEFAULTS.suspendFullscreen : !!raw.suspendFullscreen
  s.veilOpacity = clamp(raw.veilOpacity, 0.2, 1, DEFAULTS.veilOpacity)
  s.directionalSweep = raw.directionalSweep === undefined ? DEFAULTS.directionalSweep : !!raw.directionalSweep
  s.snoozeSeconds = clamp(raw.snoozeSeconds, 10, 86400, DEFAULTS.snoozeSeconds)
  return s
}

// One line off the socket -> an event, or null for anything that is not a
// well-formed schema-1 attention event. Unknown schemas are dropped rather
// than guessed at: a wrong yaw is worse than no yaw.
function parseEvent(line) {
  var data
  try { data = JSON.parse(String(line)) } catch (e) { return null }
  if (!data || typeof data !== "object" || Array.isArray(data)) return null
  if (data.schemaVersion !== SCHEMA_VERSION) return null
  if (typeof data.state !== "string") return null
  var yaw = typeof data.yaw === "number" && isFinite(data.yaw) ? data.yaw : null
  var pitch = typeof data.pitch === "number" && isFinite(data.pitch) ? data.pitch : null
  return {
    state: data.state,
    present: data.present === true,
    yaw: yaw,
    pitch: pitch,
    reason: typeof data.reason === "string" ? data.reason : ""
  }
}

function initial() {
  return {
    shielded: false,
    awaySince: null,
    backSince: null,
    lastEventMs: 0,
    // What the daemon last said about itself: disconnected, starting,
    // tracking, paused, error, stale.
    daemon: "disconnected",
    reason: "",
    present: false,
    yaw: null,
    pitch: null,
    // Smoothed yaw, and how much of the screen the veil should cover, 0..1.
    smoothYaw: null,
    coverage: 0
  }
}

// How far across the screen the veil should be for a head turned `turned`
// degrees from centre: 0 inside the comfort zone, 1 past the full angle, a
// smoothstep between. Symmetric, so it is the same curve either side.
function coverageFor(turned, settings) {
  var span = settings.enterAngle - settings.exitAngle
  if (span <= 0) return Math.abs(turned) > settings.enterAngle ? 1 : 0
  var t = (Math.abs(turned) - settings.exitAngle) / span
  if (t <= 0) return 0
  if (t >= 1) return 1
  return t * t * (3 - 2 * t)
}

function copy(state) {
  var next = {}
  for (var k in state) next[k] = state[k]
  return next
}

// Where the head is, for the purposes of the shield: "away", "absent",
// "back", or "unknown" when the daemon is not tracking. `shielded` picks
// which of the two angles applies — that is the hysteresis.
function classify(event, shielded, settings, offset) {
  if (event.state !== "tracking") return "unknown"
  if (!event.present || event.yaw === null) return "absent"
  var turned = Math.abs(event.yaw - (offset || 0))
  var limit = shielded ? settings.exitAngle : settings.enterAngle
  return turned > limit ? "away" : "back"
}

// Advance the state by one event. The returned state is a fresh object, so a
// QML property bound to it notifies.
function step(state, event, nowMs, settings, offset) {
  var next = copy(state)
  next.lastEventMs = nowMs
  next.daemon = event.state
  next.reason = event.reason
  next.present = event.present
  next.yaw = event.yaw
  next.pitch = event.pitch
  if (event.yaw === null) next.smoothYaw = null
  else if (state.smoothYaw === null) next.smoothYaw = event.yaw
  else next.smoothYaw = state.smoothYaw + (event.yaw - state.smoothYaw) * settings.yawSmoothing

  var where = classify(event, state.shielded, settings, offset)
  if (where === "unknown") {
    // Not tracking: the shield never stays up on stale knowledge.
    next.shielded = false
    next.coverage = 0
    next.awaySince = null
    next.backSince = null
    return next
  }
  if (where === "absent" && !settings.absentShields) where = "back"

  var stepped = _advance(next, where, nowMs, settings)
  stepped.coverage = _coverage(stepped, where, settings, offset)
  return stepped
}

function _coverage(state, where, settings, offset) {
  // An empty chair, or switch mode: the dwell/hysteresis verdict, whole.
  if (!settings.gradual || where === "absent" || state.smoothYaw === null) return state.shielded ? 1 : 0
  // Gradual: follow the head. The hysteresis verdict still wins once it has
  // committed, so a fully turned head does not flicker at the top end.
  return Math.max(coverageFor(state.smoothYaw - (offset || 0), settings), state.shielded ? 1 : 0)
}

function _advance(next, where, nowMs, settings) {
  if (where === "back") {
    next.awaySince = null
    if (next.shielded) {
      if (next.backSince === null) next.backSince = nowMs
      if (nowMs - next.backSince >= settings.releaseMs) {
        next.shielded = false
        next.backSince = null
      }
    }
    return next
  }

  // away or absent
  next.backSince = null
  if (!next.shielded) {
    if (next.awaySince === null) next.awaySince = nowMs
    var dwell = where === "absent" ? settings.absentDwellMs : settings.dwellMs
    if (nowMs - next.awaySince >= dwell) {
      next.shielded = true
      next.awaySince = null
    }
  }
  return next
}

// The clock, independent of events: silence past `staleMs` drops the shield.
// Returns the same object when nothing changed, so callers can skip a notify.
function tick(state, nowMs, settings) {
  if (state.daemon === "disconnected" || state.daemon === "stale") return state
  if (nowMs - state.lastEventMs <= settings.staleMs) return state
  var next = copy(state)
  next.daemon = "stale"
  next.shielded = false
  next.coverage = 0
  next.awaySince = null
  next.backSince = null
  return next
}

// The socket went away. Different from stale only in what the label says.
function disconnected(state) {
  var next = initial()
  next.lastEventMs = state.lastEventMs
  return next
}

// One line for the bar tooltip and the panel header.
function describe(state, enabled, suspended) {
  if (!enabled) return "off"
  if (suspended === "snoozed") return "snoozed"
  if (suspended === "fullscreen") return "paused for fullscreen"
  switch (state.daemon) {
    case "disconnected": return "daemon not running"
    case "stale": return "no signal from daemon"
    case "starting": return "camera starting"
    case "paused": return "paused for unlock scan"
    case "error": return "camera unavailable"
    case "tracking":
      if (state.shielded) return state.present ? "shielded — looking away" : "shielded — nobody there"
      if (state.coverage > 0) return "shielding " + Math.round(state.coverage * 100) + "%"
      return state.present ? "watching" : "no face in view"
  }
  return state.daemon
}

// What the bar icon should say about the state, as a severity the widget
// maps to a colour: "on" while shielding, "off", "idle", or "problem".
function severity(state, enabled, suspended) {
  if (!enabled) return "off"
  if (suspended) return "idle"
  if (state.daemon === "tracking") return state.shielded || state.coverage >= 0.5 ? "on" : "idle"
  if (state.daemon === "starting" || state.daemon === "paused") return "idle"
  return "problem"
}
