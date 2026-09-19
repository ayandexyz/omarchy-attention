pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// Bar icon + panel for the Shy service. The service does the work; this is
// the switch, the recentre button, and a readout of what the daemon sees.
//
// Settings live on this widget's bar entry (the schema in manifest.json) and
// are pushed to the service, which has sane defaults of its own for the
// moments before the widget has loaded.
Ui.Panel {
  id: root
  moduleName: "io.github.ayandexyz.shy"
  ipcTarget: "io.github.ayandexyz.shy.panel"
  manageIpc: false

  // Injected by the shell: the scoped API that can find our own service.
  property var shell: null
  property var service: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool enabled: service ? service.enabled : false
  readonly property bool shielded: service ? service.shielded : false
  readonly property string label: service ? service.label : "service not loaded"
  readonly property string severity: service ? service.severity : "problem"
  readonly property var live: service ? service.state : null

  implicitWidth: iconButton.implicitWidth
  implicitHeight: iconButton.implicitHeight

  function findService() {
    var found = null
    if (root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
      found = root.bar.shell.serviceFor(root.moduleName)
    else if (root.shell && typeof root.shell.serviceFor === "function")
      found = root.shell.serviceFor(root.moduleName)
    if (found && found !== root.service) {
      root.service = found
      root.pushSettings()
    }
  }

  // Everything the service needs, from this entry's inline settings.
  function pushSettings() {
    if (!root.service) return
    root.service.applySettings(root.settings)
    if (typeof root.settings.offset === "number") root.service.offset = root.settings.offset
    if (root.settings.enabled === false) root.service.setEnabled(false)
    else if (root.settings.enabled === true && !root.service.enabled) root.service.setEnabled(true)
  }

  // Persist one key back onto the bar entry, so it survives a shell restart.
  function remember(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleShield() {
    if (!root.service) return
    root.service.toggle()
    root.remember("enabled", root.service.enabled)
  }
  function recenter() {
    if (!root.service || !root.service.recenter()) return
    root.remember("offset", root.service.offset)
  }
  function snooze() { if (root.service) root.service.snooze(0) }
  function wake() { if (root.service) root.service.wake() }

  function severityColor(s) {
    if (s === "on") return Color.accent
    if (s === "problem") return urgent
    if (s === "off") return dim
    return foreground
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.RightButton) { toggleShield(); return }
    if (buttonCode === Qt.MiddleButton) { recenter(); return }
    toggle()
  }

  onSettingsChanged: root.pushSettings()
  Component.onCompleted: root.findService()

  // The service may come up after the widget, or be recreated on a rescan.
  Timer {
    interval: 1000
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  Ui.BarIconButton {
    id: iconButton
    anchors.fill: parent
    bar: root.bar
    text: root.enabled ? "󰈈" : "󰈉"
    active: root.shielded
    tooltipText: "Shy · " + root.label
    onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: iconButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.toggleShield()
      onCloseRequested: root.close()

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.spacing.lg

        Ui.PanelHero {
          width: parent.width
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: "Shy"
          meta: root.label
          detail: root.enabled ? (root.shielded ? "shielded" : "") : "off"
          iconComponent: Component {
            Text {
              text: root.enabled ? "󰈈" : "󰈉"
              color: root.severityColor(root.severity)
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // The daemon is the one thing that can be missing. Say what to do.
        Text {
          width: parent.width
          visible: root.enabled && root.live && root.live.daemon === "disconnected"
          text: "Cannot reach glanced's attention socket. Install the glanced package (0.3 or later) and start it: systemctl --user start glanced"
          color: root.dim
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.spacing.sm

          Ui.Button {
            text: root.enabled ? "Turn off" : "Turn on"
            iconText: root.enabled ? "󰈉" : "󰈈"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.service !== null
            onClicked: root.toggleShield()
          }
          Ui.Button {
            text: "Recentre"
            iconText: "󰆾"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            tooltipText: "Call the way you are facing right now 'straight ahead'"
            enabled: root.enabled && root.live && root.live.present
            onClicked: root.recenter()
          }
          Ui.Button {
            text: root.service && root.service.snoozed ? "Wake" : "Snooze"
            iconText: root.service && root.service.snoozed ? "󰒲" : "󰒳"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.enabled
            onClicked: root.service && root.service.snoozed ? root.wake() : root.snooze()
          }
        }

        Ui.PanelSectionHeader {
          width: parent.width
          text: "Camera"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // Live readout, only while the panel is open: the numbers the shield
        // is deciding on, so a wrong recentre or a flipped camera is obvious.
        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Text {
            width: parent.width
            text: {
              if (!root.live || root.live.daemon !== "tracking") return "daemon: " + (root.live ? root.live.daemon : "—")
              if (!root.live.present) return "no face in view"
              var yaw = root.live.yaw === null ? "—" : root.live.yaw.toFixed(0) + "°"
              var rel = root.live.yaw === null ? "—" : (root.live.yaw - (root.service ? root.service.offset : 0)).toFixed(0) + "°"
              var pitch = root.live.pitch === null ? "—" : root.live.pitch.toFixed(0) + "°"
              return "yaw " + yaw + "  (" + rel + " from centre)   pitch " + pitch
            }
            color: root.foreground
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            width: parent.width
            text: "shields past " + (root.service ? root.service.settings.enterAngle : "—") + "°, clears within "
              + (root.service ? root.service.settings.exitAngle : "—") + "°"
              + (root.service && root.service.offset !== 0 ? ", centre at " + root.service.offset.toFixed(0) + "°" : "")
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            width: parent.width
            visible: !!root.live && root.live.reason !== ""
            text: root.live ? root.live.reason : ""
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          text: "Right-click the icon to toggle, middle-click to recentre. Nothing here captures your screen or your camera: the daemon sends two angles and a bool, and the veil takes no input."
          color: root.dim
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
