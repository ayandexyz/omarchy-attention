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
      visible: root.shielded || veil.coverage > 0.001
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-attention"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Empty input region: clicks and keys go straight through to whatever
      // is underneath, shield or no shield.
      mask: Region {}
      // In Wayland, compositor blur regions are binary geometric masks (on or off).
      // Rather than cutting the blur arbitrarily inside a translucent smear (which
      // created a jarring hard line), the blur region precisely bounds the frosted
      // glass panel. At the leading edge, an Apple-style material structure is
      // applied:
      //   1. A forward-facing ambient drop shadow that softly shades the unblurred screen;
      //   2. A luminous specular glass highlight line and micro-bevel on the rim;
      //   3. A subtle inner Fresnel glow that eases into the frosted glass veil.
      // This turns the boundary into a natural, physically convincing optical glass edge.
      readonly property bool sweep: root.settings.directionalSweep
      readonly property real coverage: veil.coverage
      readonly property real shadowWidth: Math.min(48, Math.round(panel.width * 0.035))

      // The frosted glass panel bounds. The blur region precisely matches
      // the physical glass pane, while a specular rim and soft ambient shadow
      // eliminate the raw blur cut and produce a smooth, Apple-like frosted
      // glass sweep.
      readonly property int glassLeft: !sweep ? 0
        : root.side > 0 ? Math.round(panel.width * (1.0 - coverage))
        : 0
      readonly property int glassRight: !sweep ? panel.width
        : root.side > 0 ? panel.width
        : Math.round(panel.width * coverage)
      readonly property int glassWidth: Math.max(0, glassRight - glassLeft)

      // Compositor blur region covers the entire frosted glass pane.
      BackgroundEffect.blurRegion: Region {
        x: panel.glassLeft
        y: 0
        width: panel.glassWidth
        height: panel.height
      }

      // 1. Ambient drop shadow cast forward onto the unblurred desktop.
      // Extends outside the glass pane to create depth and soften the visual lead.
      Rectangle {
        id: ambientShadow
        visible: panel.sweep && panel.glassWidth > 0 && panel.coverage < 0.999
        y: 0
        height: panel.height
        width: panel.shadowWidth
        x: root.side > 0
          ? Math.max(0, panel.glassLeft - panel.shadowWidth)
          : panel.glassRight
        opacity: Math.min(1.0, panel.coverage * 3.0) * root.settings.veilOpacity
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop {
            position: 0.0
            color: root.side > 0 ? "transparent" : Qt.rgba(0, 0, 0, 0.35)
          }
          GradientStop {
            position: 0.35
            color: root.side > 0 ? Qt.rgba(0, 0, 0, 0.08) : Qt.rgba(0, 0, 0, 0.20)
          }
          GradientStop {
            position: 0.70
            color: root.side > 0 ? Qt.rgba(0, 0, 0, 0.20) : Qt.rgba(0, 0, 0, 0.08)
          }
          GradientStop {
            position: 1.0
            color: root.side > 0 ? Qt.rgba(0, 0, 0, 0.35) : "transparent"
          }
        }
      }

      // 2. The frosted glass veil itself (inside the blur region).
      Rectangle {
        id: veil
        readonly property color tint: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
        property real coverage: root.coverage
        Behavior on coverage {
          SmoothedAnimation { velocity: 1.6; reversingMode: SmoothedAnimation.Sync }
        }

        y: 0
        height: panel.height
        x: panel.glassLeft
        width: panel.glassWidth
        opacity: panel.sweep ? root.settings.veilOpacity : coverage * root.settings.veilOpacity
        color: tint

        // Subtle inner Fresnel specular gradient near the leading edge
        Rectangle {
          id: innerGlow
          visible: panel.sweep && panel.glassWidth > 0
          y: 0
          height: parent.height
          width: Math.min(36, panel.glassWidth)
          x: root.side > 0 ? 0 : parent.width - width
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
              position: 0.0
              color: root.side > 0 ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
            }
            GradientStop {
              position: 1.0
              color: root.side > 0 ? "transparent" : Qt.rgba(1, 1, 1, 0.12)
            }
          }
        }

        // 3. Apple-style specular glass rim at the leading edge.
        // A luminous highlight line paired with a subtle contrast bevel gives
        // the glass a physical, polished optical boundary.
        Item {
          id: glassRim
          visible: panel.sweep && panel.glassWidth > 0 && panel.coverage < 0.999
          y: 0
          height: parent.height
          width: 3
          x: root.side > 0 ? 0 : parent.width - width

          // Soft micro-shadow bevel
          Rectangle {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            x: root.side > 0 ? 0 : 2
            color: Qt.rgba(0, 0, 0, 0.28)
          }

          // Luminous specular reflection highlight
          Rectangle {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1.5
            x: root.side > 0 ? 1 : 0
            color: Qt.rgba(1, 1, 1, 0.35)
          }
        }
      }
    }
  }
}
