pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "AttentionLogic.js" as Logic

// The shield. Lives as a headless service inside omarchy-shell so it exists
// whether or not the bar widget is showing, subscribes to glanced's attention
// socket, and owns one translucent surface per output.
//
// What it never does:
//   * take input — every surface has an empty input region and no keyboard
//     interactivity, so you can keep typing from a paper on your desk;
//   * capture the screen — the compositor blurs what is already behind the
//     surface (ext-background-effect), nothing is screenshotted;
//   * stay up on its own — every non-tracking state from the daemon, and any
//     silence past `staleMs`, brings it down. A crash anywhere fails open.
Scope {
  id: root

  // Injected by the shell.
  property var shell: null
  property var manifest: null

  property var settings: Logic.normalizeSettings({})
  property bool enabled: true
  // Yaw the user calls "straight at the screen". The camera defines zero, so
  // a webcam off to one side of an ultrawide needs this.
  property real offset: 0
  property double snoozedUntil: 0
  // `cover`: shield up regardless of pose until this time. A panic hotkey,
  // and the honest way to demo the thing. Bounded, so it fails open too.
  property double coveredUntil: 0
  property double nowMs: Date.now()
  property var state: Logic.initial()

  readonly property bool fullscreenFocused: {
    var top = ToplevelManager.activeToplevel
    return !!top && top.fullscreen === true
  }
  readonly property bool snoozed: root.nowMs < root.snoozedUntil
  readonly property bool covered: root.nowMs < root.coveredUntil
  // Why the shield is held down regardless of head pose, or "".
  readonly property string suspended: snoozed ? "snoozed"
    : (settings.suspendFullscreen && fullscreenFocused ? "fullscreen" : "")
  // How much of the screen the veil should cover right now, 0..1. In gradual
  // mode this follows the head; the veil animates toward it.
  readonly property real coverage: covered ? 1 : (enabled && suspended === "" ? state.coverage : 0)
  readonly property bool shielded: covered || (enabled && suspended === "" && (state.shielded || state.coverage >= 0.5))
  // Which edge the veil sweeps in from: +1 the right edge (you turned left),
  // -1 the left edge. Decided as coverage leaves zero and held until it is
  // back there, so the veil leaves the way it came. With no face to read, the
  // last side you were seen turning toward.
  property int side: 1
  property int lastTurn: 1
  property real _lastCoverage: 0
  onCoverageChanged: {
    if (root._lastCoverage === 0 && root.coverage > 0) root.side = root.turnSide()
    root._lastCoverage = root.coverage
  }
  function turnSide() {
    var yaw = root.state.smoothYaw !== null ? root.state.smoothYaw : root.state.yaw
    if (yaw === null) return root.lastTurn
    return (yaw - root.offset) < 0 ? -1 : 1
  }
  readonly property string label: covered ? "covered" : Logic.describe(state, enabled, suspended)
  readonly property string severity: Logic.severity(state, enabled, suspended)

  readonly property string socketPath: {
    // Quickshell.env yields null/undefined for an unset variable, not "".
    var explicit = Quickshell.env("GLANCE_RUNTIME_DIR")
    var runtimeDir = Quickshell.env("XDG_RUNTIME_DIR")
    var runtime = typeof explicit === "string" && explicit !== "" ? explicit
      : (typeof runtimeDir === "string" && runtimeDir !== "" ? runtimeDir : "/run/user/1000") + "/glance"
    return runtime + "/attention.sock"
  }

  function applySettings(raw) { root.settings = Logic.normalizeSettings(raw) }
  function setEnabled(on) {
    root.enabled = !!on
    if (root.enabled) root.connectNow()
    else root.disconnectNow()
  }
  function toggle() { root.setEnabled(!root.enabled) }
  function recenter() {
    if (root.state.yaw === null) return false
    root.offset = root.state.yaw
    return true
  }
  function snooze(seconds) {
    var s = Number(seconds)
    if (!isFinite(s) || s <= 0) s = root.settings.snoozeSeconds
    root.snoozedUntil = Date.now() + s * 1000
  }
  function wake() { root.snoozedUntil = 0; root.coveredUntil = 0 }
  function cover(seconds) {
    var s = Number(seconds)
    if (!isFinite(s) || s <= 0) s = 10
    root.coveredUntil = Date.now() + Math.min(s, 3600) * 1000
    root.nowMs = Date.now()
  }

  // Quickshell's Socket.connected is the *requested* state: it stays true
  // after a failed or dropped connection, so it cannot be used to decide
  // whether to (re)connect. Our own view of it is what the daemon last told
  // us, and a reconnect always goes through false first.
  readonly property bool linked: root.state.daemon !== "disconnected"
  function connectNow() {
    socket.connected = false
    socket.path = root.socketPath
    socket.connected = true
  }
  function disconnectNow() {
    socket.connected = false
    root.state = Logic.disconnected(root.state)
  }

  Component.onCompleted: if (root.enabled) root.connectNow()

  Socket {
    id: socket
    path: root.socketPath
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var event = Logic.parseEvent(data)
        if (event === null) return
        root.state = Logic.step(root.state, event, Date.now(), root.settings, root.offset)
        if (event.yaw !== null && Math.abs(event.yaw - root.offset) > 5)
          root.lastTurn = (event.yaw - root.offset) < 0 ? -1 : 1
      }
    }
    onConnectedChanged: {
      if (!socket.connected) root.state = Logic.disconnected(root.state)
    }
    onError: function(error) {
      console.warn("attention socket error " + error + " on " + socket.path)
      root.state = Logic.disconnected(root.state)
    }
  }

  // Daemon not up yet, restarted, or started after the shell: keep knocking
  // until it answers with an event.
  Timer {
    interval: 2000
    repeat: true
    running: root.enabled && !root.linked
    onTriggered: root.connectNow()
  }

  // The watchdog, and the clock the snooze reads. Cheap: it only allocates
  // when something actually changed.
  Timer {
    interval: 250
    repeat: true
    running: root.enabled || root.covered
    onTriggered: {
      root.nowMs = Date.now()
      var next = Logic.tick(root.state, root.nowMs, root.settings)
      if (next !== root.state) root.state = next
    }
  }

  IpcHandler {
    target: "io.github.ayandexyz.attention"
    function toggle(): string { root.toggle(); return root.enabled ? "on" : "off" }
    function enable(): string { root.setEnabled(true); return "on" }
    function disable(): string { root.setEnabled(false); return "off" }
    function recenter(): string { return root.recenter() ? "ok" : "no face" }
    function snooze(seconds: int): string { root.snooze(seconds); return "ok" }
    function wake(): string { root.wake(); return "ok" }
    function cover(seconds: int): string { root.cover(seconds); return "ok" }
    function state(): string {
      return JSON.stringify({
        enabled: root.enabled, shielded: root.shielded, suspended: root.suspended,
        daemon: root.state.daemon, present: root.state.present,
        yaw: root.state.yaw, pitch: root.state.pitch, offset: root.offset, label: root.label,
        socket: root.socketPath, socketConnected: socket.connected, linked: root.linked,
        fullscreen: root.fullscreenFocused, settings: root.settings, side: root.side, lastTurn: root.lastTurn,
        activeToplevel: ToplevelManager.activeToplevel ? ToplevelManager.activeToplevel.title : null
      })
    }
    function ping(): string { return "ok" }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      screen: modelData
      // Mapped only while there is something to show, so an idle shield costs
      // the compositor nothing at all. Shown on the decision, not on the
      // opacity: animations do not advance inside a hidden window, so
      // waiting for the fade-in to start would wait forever.
      //
      // Hidden a beat *after* the sweep has fully left the screen. The
      // compositor fades an unmapping layer out using its last buffer, so
      // unmapping mid-sweep flashes a stale slice of veil back onto the
      // screen. Lingering a few frames with nothing drawn and an empty blur
      // region makes that fade invisible.
      visible: root.shielded || veil.coverage > 0 || panel.lingering
      property bool lingering: false
      Timer {
        id: linger
        interval: 150
        onTriggered: panel.lingering = false
      }
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-attention"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Empty input region: clicks and keys go straight through to whatever
      // is underneath, shield or no shield.
      mask: Region {}
      // Compositor blur regions are binary: a pixel is either blurred or it
      // is not, so wherever the region ends there is a hard step. It cannot
      // be feathered, only hidden. The veil is therefore almost opaque
      // exactly at the crest where the blur begins, and eases out from there
      // in both directions over a wide spread: down to the resting tint over
      // the blurred side, down to nothing over the clear side. Every stop
      // follows a smoothstep curve so there is no ridge and no seam, just a
      // soft shadow that rolls across the screen.
      readonly property bool sweep: root.settings.directionalSweep
      readonly property real coverage: veil.coverage
      // Width of the fade on each side of the crest.
      readonly property int feather: Math.min(640, Math.max(320, Math.round(panel.width * 0.36)))

      // The crest where compositor blur begins. The sweep travels one feather
      // past the screen on the far side, so the leading shadow rolls fully
      // off (or on) instead of snapping away when the crest hits the edge.
      readonly property int travel: panel.width + panel.feather
      readonly property int crestX: !sweep ? panel.width
        : root.side > 0 ? Math.round(panel.width + panel.feather - travel * coverage)
        : Math.round(travel * coverage - panel.feather)
      // The crest clamped to the screen: the blur region and veil end here.
      readonly property int veilStart: root.side > 0 ? Math.max(0, Math.min(panel.width, crestX)) : 0
      readonly property int veilWidth: !sweep ? panel.width
        : root.side > 0 ? panel.width - veilStart : Math.max(0, Math.min(panel.width, crestX))

      readonly property real baseOpacity: root.settings.veilOpacity
      // Dense enough that the blur step underneath cannot be seen.
      readonly property real crestOpacity: 0.94

      // Compositor blur region covers the shielded side up to the crest.
      BackgroundEffect.blurRegion: Region {
        x: panel.veilStart
        y: 0
        width: panel.veilWidth
        height: panel.height
      }

      readonly property color tintColor: Color.background

      function tint(alpha) {
        return Qt.rgba(panel.tintColor.r, panel.tintColor.g, panel.tintColor.b, alpha)
      }
      // Smoothstep between two alphas, t in 0..1.
      function ease(from, to, t) {
        var k = t * t * (3 - 2 * t)
        return from + (to - from) * k
      }

      // 1. The frosted veil over the blurred region. Starts dense at the crest
      // and settles to the resting tint over one feather width.
      Rectangle {
        id: veil
        property real coverage: root.coverage
        Behavior on coverage {
          SmoothedAnimation { velocity: 1.6; reversingMode: SmoothedAnimation.Sync }
        }
        onCoverageChanged: {
          if (coverage > 0) { linger.stop(); panel.lingering = false }
          else { panel.lingering = true; linger.restart() }
        }

        y: 0
        height: panel.height
        x: panel.veilStart
        width: panel.veilWidth
        visible: width > 0

        gradient: panel.sweep && width > 0 ? blurSideGradient : null
        color: !panel.sweep ? panel.tintColor : "transparent"
        opacity: !panel.sweep ? panel.coverage * panel.baseOpacity : 1.0

        // Fraction of the veil taken by the fade, in gradient space.
        readonly property real span: Math.min(1.0, panel.feather / Math.max(1, veil.width))
        // Stops are listed left to right (Qt wants ascending positions), so
        // `t` is the distance from the crest as a fraction of the fade: it
        // runs 0..1 left to right when the crest is on the left, 1..0 when
        // it is on the right.
        readonly property var ts: [0, 0.15, 0.30, 0.45, 0.60, 0.80, 1.0]
        function pos(i) { return root.side > 0 ? veil.ts[i] * span : 1.0 - veil.ts[6 - i] * span }
        function alpha(i) {
          var t = root.side > 0 ? veil.ts[i] : veil.ts[6 - i]
          return panel.tint(panel.ease(panel.crestOpacity, panel.baseOpacity, t))
        }

        Gradient {
          id: blurSideGradient
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: root.side > 0 ? panel.tint(panel.crestOpacity) : panel.tint(panel.baseOpacity) }
          GradientStop { position: veil.pos(0); color: veil.alpha(0) }
          GradientStop { position: veil.pos(1); color: veil.alpha(1) }
          GradientStop { position: veil.pos(2); color: veil.alpha(2) }
          GradientStop { position: veil.pos(3); color: veil.alpha(3) }
          GradientStop { position: veil.pos(4); color: veil.alpha(4) }
          GradientStop { position: veil.pos(5); color: veil.alpha(5) }
          GradientStop { position: veil.pos(6); color: veil.alpha(6) }
          GradientStop { position: 1.0; color: root.side > 0 ? panel.tint(panel.baseOpacity) : panel.tint(panel.crestOpacity) }
        }
      }

      // 2. The leading shadow over the clear side. Dense at the crest, gone
      // one feather width away.
      Rectangle {
        id: leadingWave
        visible: panel.sweep && veil.coverage > 0 && veil.coverage < 1
        y: 0
        height: panel.height
        width: panel.feather
        x: root.side > 0 ? panel.crestX - panel.feather : panel.crestX

        // Distance from the crest as a fraction of the fade, for the stop at
        // position `p`. The crest is on the right when sweeping from the right.
        function alpha(p) {
          var t = root.side > 0 ? 1.0 - p : p
          return panel.tint(panel.ease(panel.crestOpacity, 0, t))
        }

        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: leadingWave.alpha(0.0) }
          GradientStop { position: 0.1; color: leadingWave.alpha(0.1) }
          GradientStop { position: 0.2; color: leadingWave.alpha(0.2) }
          GradientStop { position: 0.3; color: leadingWave.alpha(0.3) }
          GradientStop { position: 0.4; color: leadingWave.alpha(0.4) }
          GradientStop { position: 0.5; color: leadingWave.alpha(0.5) }
          GradientStop { position: 0.6; color: leadingWave.alpha(0.6) }
          GradientStop { position: 0.7; color: leadingWave.alpha(0.7) }
          GradientStop { position: 0.8; color: leadingWave.alpha(0.8) }
          GradientStop { position: 0.9; color: leadingWave.alpha(0.9) }
          GradientStop { position: 1.0; color: leadingWave.alpha(1.0) }
        }
      }
    }
  }
}
