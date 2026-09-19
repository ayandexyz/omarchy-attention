#!/usr/bin/env node
// Unit tests for AttentionLogic.js: the shield's state machine, driven by a scripted
// event stream and a fake clock. The file is a QML `.pragma library`, so it is
// loaded by stripping that line and evaluating it as plain script.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "AttentionLogic.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const S = vm.runInNewContext(source + "\n;({ DEFAULTS, normalizeSettings, parseEvent, initial, classify, step, tick, disconnected, describe, severity, coverageFor })")

const tests = []
function test(name, fn) { tests.push([name, fn]) }

const settings = S.normalizeSettings({})

function ev(overrides) {
  return Object.assign({ state: "tracking", present: true, yaw: 0, pitch: 0, reason: "" }, overrides)
}

// Feed a stream at 8 fps from t=0: each entry is [yawOrEvent, durationMs].
// Returns the state after the whole script and a log of shield transitions.
function run(script, opts) {
  opts = opts || {}
  let state = opts.from || S.initial()
  let now = opts.startMs || 1000
  const transitions = []
  for (const [what, ms] of script) {
    const end = now + ms
    while (now < end) {
      const event = typeof what === "number" ? ev({ yaw: what }) : what
      const before = state.shielded
      state = S.step(state, event, now, opts.settings || settings, opts.offset || 0)
      state = S.tick(state, now, opts.settings || settings)
      if (state.shielded !== before) transitions.push([now - (opts.startMs || 1000), state.shielded])
      now += 125
    }
  }
  return { state, transitions, now }
}

test("parses a schema-1 event and rejects anything else", () => {
  const e = S.parseEvent('{"schemaVersion":1,"t":1.5,"state":"tracking","present":true,"yaw":-12.4,"pitch":3.1,"conf":1.0}')
  assert.deepStrictEqual(JSON.parse(JSON.stringify(e)), { state: "tracking", present: true, yaw: -12.4, pitch: 3.1, reason: "" })
  assert.strictEqual(S.parseEvent('{"schemaVersion":2,"state":"tracking"}'), null)
  assert.strictEqual(S.parseEvent("not json"), null)
  assert.strictEqual(S.parseEvent("[]"), null)
  assert.strictEqual(S.parseEvent('{"schemaVersion":1}'), null)
  const paused = S.parseEvent('{"schemaVersion":1,"t":2,"state":"paused","present":null,"yaw":null,"pitch":null,"conf":null,"reason":"unlock scan in progress"}')
  assert.strictEqual(paused.present, false)
  assert.strictEqual(paused.yaw, null)
  assert.strictEqual(paused.reason, "unlock scan in progress")
})

test("settings: defaults fill gaps, exit always sits inside enter", () => {
  assert.strictEqual(S.normalizeSettings({}).enterAngle, S.DEFAULTS.enterAngle)
  assert.strictEqual(S.normalizeSettings({ enterAngle: "garbage" }).enterAngle, S.DEFAULTS.enterAngle)
  assert.strictEqual(S.normalizeSettings({ enterAngle: 500 }).enterAngle, 80)
  const inverted = S.normalizeSettings({ enterAngle: 20, exitAngle: 40 })
  assert.strictEqual(inverted.exitAngle, 15)
  assert.strictEqual(S.normalizeSettings({ absentShields: false }).absentShields, false)
  assert.strictEqual(S.normalizeSettings({}).directionalSweep, true)
  assert.strictEqual(S.normalizeSettings({ directionalSweep: false }).directionalSweep, false)
})

test("facing the screen never shields", () => {
  const { state, transitions } = run([[0, 5000], [10, 5000], [-25, 5000]])
  assert.strictEqual(state.shielded, false)
  assert.deepStrictEqual(transitions, [])
})

test("turning away shields only after the dwell", () => {
  const { transitions } = run([[0, 1000], [45, 2000]])
  assert.strictEqual(transitions.length, 1)
  const [at, up] = transitions[0]
  assert.strictEqual(up, true)
  // Turned at 1000ms; 350ms dwell; 8 fps quantisation.
  assert.ok(at >= 1000 + settings.dwellMs && at < 1000 + settings.dwellMs + 250, `engaged at ${at}`)
})

test("a glance shorter than the dwell does nothing", () => {
  const { transitions } = run([[0, 1000], [45, 250], [0, 2000]])
  assert.deepStrictEqual(transitions, [])
})

test("hysteresis: between exit and enter angle the shield holds its state", () => {
  // 25° is inside enter (30) but outside exit (18).
  const down = run([[25, 3000]])
  assert.strictEqual(down.state.shielded, false)
  const up = run([[45, 2000], [25, 3000]])
  assert.strictEqual(up.state.shielded, true, "shield should hold at 25° once up")
  const cleared = run([[45, 2000], [10, 1000]])
  assert.strictEqual(cleared.state.shielded, false)
})

test("coming back clears after the release delay", () => {
  const { transitions } = run([[45, 2000], [0, 2000]])
  assert.strictEqual(transitions.length, 2)
  const [at, up] = transitions[1]
  assert.strictEqual(up, false)
  assert.ok(at >= 2000 + settings.releaseMs && at < 2000 + settings.releaseMs + 250, `cleared at ${at}`)
})

test("recentre offset moves the zero", () => {
  // Camera off to the side: the user's neutral is 25°.
  const { state } = run([[25, 3000]], { offset: 25 })
  assert.strictEqual(state.shielded, false)
  const turned = run([[65, 3000]], { offset: 25 })
  assert.strictEqual(turned.state.shielded, true)
  const other = run([[-15, 3000]], { offset: 25 })
  assert.strictEqual(other.state.shielded, true)
})

test("nobody there shields, but only after the longer absent dwell", () => {
  const absent = ev({ present: false, yaw: null, pitch: null })
  const { transitions } = run([[0, 1000], [absent, 4000]])
  assert.strictEqual(transitions.length, 1)
  const at = transitions[0][0]
  assert.ok(at >= 1000 + settings.absentDwellMs && at < 1000 + settings.absentDwellMs + 250, `engaged at ${at}`)
  // A dropped detection for a few frames is not absence.
  const blip = run([[0, 1000], [absent, 500], [0, 2000]])
  assert.deepStrictEqual(blip.transitions, [])
})

test("absence can be told not to shield", () => {
  const absent = ev({ present: false, yaw: null })
  const s = S.normalizeSettings({ absentShields: false })
  const { state } = run([[0, 1000], [absent, 10000]], { settings: s })
  assert.strictEqual(state.shielded, false)
  // ...and it clears a shield that was up.
  const cleared = run([[45, 2000], [absent, 2000]], { settings: s })
  assert.strictEqual(cleared.state.shielded, false)
})

test("any non-tracking state drops the shield at once", () => {
  for (const daemon of ["paused", "error", "starting"]) {
    const { state, transitions } = run([[45, 2000], [ev({ state: daemon, present: false, yaw: null }), 125]])
    assert.strictEqual(state.shielded, false, daemon)
    assert.strictEqual(state.daemon, daemon)
    assert.strictEqual(transitions[transitions.length - 1][1], false)
  }
})

test("silence drops the shield: the watchdog", () => {
  const { state } = run([[45, 2000]])
  const now = state.lastEventMs
  assert.strictEqual(state.shielded, true)
  assert.strictEqual(S.tick(state, now + settings.staleMs - 1, settings), state, "not stale yet: same object")
  const stale = S.tick(state, now + settings.staleMs + 1, settings)
  assert.strictEqual(stale.shielded, false)
  assert.strictEqual(stale.daemon, "stale")
  // Idempotent while silent.
  assert.strictEqual(S.tick(stale, now + 60000, settings), stale)
})

test("after a stale spell, tracking resumes cleanly with the dwell", () => {
  let { state, now } = run([[45, 2000]])
  state = S.tick(state, now + 5000, settings)
  const resumed = run([[45, 2000]], { from: state, startMs: now + 5000 })
  assert.strictEqual(resumed.transitions.length, 1)
  assert.ok(resumed.transitions[0][0] >= settings.dwellMs)
})

test("disconnect resets everything but remembers when it last heard anything", () => {
  const { state } = run([[45, 2000]])
  const gone = S.disconnected(state)
  assert.strictEqual(gone.shielded, false)
  assert.strictEqual(gone.daemon, "disconnected")
  assert.strictEqual(gone.lastEventMs, state.lastEventMs)
})

test("step returns a new object every time, so QML bindings notify", () => {
  const a = S.initial()
  const b = S.step(a, ev({ yaw: 0 }), 1000, settings, 0)
  assert.notStrictEqual(a, b)
  assert.strictEqual(a.lastEventMs, 0)
})

test("labels", () => {
  const off = S.describe(S.initial(), false, "")
  assert.strictEqual(off, "off")
  assert.strictEqual(S.describe(S.initial(), true, ""), "daemon not running")
  const up = run([[45, 2000]]).state
  assert.strictEqual(S.describe(up, true, ""), "shielded — looking away")
  assert.strictEqual(S.describe(up, true, "snoozed"), "snoozed")
  assert.strictEqual(S.describe(up, true, "fullscreen"), "paused for fullscreen")
  assert.strictEqual(S.severity(up, true, ""), "on")
  assert.strictEqual(S.severity(up, true, "snoozed"), "idle")
  assert.strictEqual(S.severity(S.initial(), true, ""), "problem")
  assert.strictEqual(S.severity(S.initial(), false, ""), "off")
  const watching = run([[0, 1000]]).state
  assert.strictEqual(S.describe(watching, true, ""), "watching")
  assert.strictEqual(S.severity(watching, true, ""), "idle")
})

test("coverage: zero in the comfort zone, one past the full angle, smooth between", () => {
  assert.strictEqual(S.coverageFor(0, settings), 0)
  assert.strictEqual(S.coverageFor(settings.exitAngle, settings), 0)
  assert.strictEqual(S.coverageFor(-settings.exitAngle, settings), 0)
  assert.strictEqual(S.coverageFor(settings.enterAngle, settings), 1)
  assert.strictEqual(S.coverageFor(-80, settings), 1)
  const mid = S.coverageFor((settings.exitAngle + settings.enterAngle) / 2, settings)
  assert.ok(mid > 0.45 && mid < 0.55, `midpoint ${mid}`)
  const quarter = S.coverageFor(settings.exitAngle + (settings.enterAngle - settings.exitAngle) / 4, settings)
  assert.ok(quarter > 0 && quarter < 0.2, `quarter ${quarter}`)
})

test("gradual: coverage follows a smoothed head, out and back", () => {
  let state = S.initial()
  const seen = []
  for (const yaw of [0, 25, 25, 25, 25, 25, 25, 0, 0, 0, 0, 0, 0]) {
    state = S.step(state, ev({ yaw }), 1000, settings, 0)
    seen.push(state.coverage)
  }
  // Holding at 25° (midway) settles near half, then returns to zero.
  assert.ok(seen[6] > 0.4 && seen[6] < 0.6, `settled ${seen[6]}`)
  assert.ok(seen[1] < seen[6], "smoothing: first reading undershoots")
  assert.strictEqual(seen[12], 0)
})

test("gradual: a committed shield holds full coverage until the exit angle", () => {
  const { state } = run([[60, 2000], [25, 1000]])
  assert.strictEqual(state.shielded, true)
  assert.strictEqual(state.coverage, 1)
})

test("switch mode: coverage is 0 or 1 only", () => {
  const s = S.normalizeSettings({ gradual: false })
  let state = S.initial()
  state = S.step(state, ev({ yaw: 25 }), 1000, s, 0)
  assert.strictEqual(state.coverage, 0)
  const up = run([[60, 2000]], { settings: s }).state
  assert.strictEqual(up.coverage, 1)
})

test("absence and non-tracking states set coverage whole or none", () => {
  const absent = ev({ present: false, yaw: null })
  const { state } = run([[0, 1000], [absent, 4000]])
  assert.strictEqual(state.coverage, 1)
  const paused = S.step(state, ev({ state: "paused", present: false, yaw: null }), 99999, settings, 0)
  assert.strictEqual(paused.coverage, 0)
})

let failed = 0
for (const [name, fn] of tests) {
  try { fn(); console.log("  ok   " + name) }
  catch (error) { failed++; console.log("  FAIL " + name + "\n       " + (error.stack || error).toString().split("\n").slice(0, 3).join("\n       ")) }
}
console.log(failed ? `${failed} of ${tests.length} failed` : `all ${tests.length} passed`)
process.exit(failed ? 1 : 0)
