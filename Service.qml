pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "ShyLogic.js" as Shy

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

  property var settings: Shy.normalizeSettings({})
  property bool enabled: true
  // Yaw the user calls "straight at the screen". The camera defines zero, so
  // a webcam off to one side of an ultrawide needs this.
  property real offset: 0
  property double snoozedUntil: 0
  // `cover`: shield up regardless of pose until this time. A panic hotkey,
  // and the honest way to demo the thing. Bounded, so it fails open too.
  property double coveredUntil: 0
  property double nowMs: Date.now()
  property var state: Shy.initial()

  readonly property bool fullscreenFocused: {
    var top = ToplevelManager.activeToplevel
    return !!top && top.fullscreen === true
  }
  readonly property bool snoozed: root.nowMs < root.snoozedUntil
  readonly property bool covered: root.nowMs < root.coveredUntil
  // Why the shield is held down regardless of head pose, or "".
  readonly property string suspended: snoozed ? "snoozed"
    : (settings.suspendFullscreen && fullscreenFocused ? "fullscreen" : "")
  readonly property bool shielded: covered || (enabled && suspended === "" && state.shielded)
  readonly property string label: covered ? "covered" : Shy.describe(state, enabled, suspended)
  readonly property string severity: Shy.severity(state, enabled, suspended)

  readonly property string socketPath: {
    // Quickshell.env yields null/undefined for an unset variable, not "".
    var explicit = Quickshell.env("GLANCE_RUNTIME_DIR")
    var runtimeDir = Quickshell.env("XDG_RUNTIME_DIR")
    var runtime = typeof explicit === "string" && explicit !== "" ? explicit
      : (typeof runtimeDir === "string" && runtimeDir !== "" ? runtimeDir : "/run/user/1000") + "/glance"
    return runtime + "/attention.sock"
  }

  function applySettings(raw) { root.settings = Shy.normalizeSettings(raw) }
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

  function connectNow() {
    if (socket.connected) return
    socket.path = root.socketPath
    socket.connected = true
  }
  function disconnectNow() {
    socket.connected = false
    root.state = Shy.disconnected(root.state)
  }

  Component.onCompleted: if (root.enabled) root.connectNow()

  Socket {
    id: socket
    path: root.socketPath
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var event = Shy.parseEvent(data)
        if (event === null) return
        root.state = Shy.step(root.state, event, Date.now(), root.settings, root.offset)
      }
    }
    onConnectedChanged: {
      if (!socket.connected) root.state = Shy.disconnected(root.state)
    }
    onError: function() { /* the reconnect timer handles it */ }
  }

  // Daemon not up yet, restarted, or started after the shell: keep knocking.
  Timer {
    interval: 2000
    repeat: true
    running: root.enabled && !socket.connected
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
      var next = Shy.tick(root.state, root.nowMs, root.settings)
      if (next !== root.state) root.state = next
    }
  }

  IpcHandler {
    target: "io.github.ayandexyz.shy"
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
        socket: root.socketPath, fullscreen: root.fullscreenFocused, settings: root.settings,
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
      visible: root.shielded || veil.opacity > 0.001
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-shy"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Empty input region: clicks and keys go straight through to whatever
      // is underneath, shield or no shield.
      mask: Region {}
      // Ask the compositor to blur what is behind the veil. Hyprland honours
      // this when decoration.blur is enabled; otherwise the veil's own
      // opacity does the hiding.
      BackgroundEffect.blurRegion: Region { item: veil }

      Rectangle {
        id: veil
        anchors.fill: parent
        // The theme colour may carry alpha of its own; the veil's opacity is
        // the one knob, so flatten it.
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
        opacity: root.shielded ? root.settings.veilOpacity : 0
        Behavior on opacity {
          NumberAnimation { duration: 350; easing.type: Easing.InOutQuad }
        }
      }
    }
  }
}
