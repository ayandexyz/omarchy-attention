// Loads the real Service.qml outside omarchy-shell and prints what the daemon
// state looks like once a second, so the runner can watch it recover.
import QtQuick
import Quickshell
import "Plugin" as Plugin

ShellRoot {
  Plugin.Service { id: svc }

  Timer {
    interval: 500
    repeat: true
    running: true
    onTriggered: console.log("PROBE daemon=" + svc.state.daemon + " yaw=" + svc.state.yaw)
  }

  Timer {
    interval: 12000
    running: true
    onTriggered: Qt.quit()
  }
}
