import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry point. Owns the daemon connection and hosts Panel.qml, mirroring
// the first-party clock/audio widgets: one manifest kind, panel loaded inside.
BarWidget {
  id: root
  moduleName: "io.github.ricky.whatsapp"

  // nf-fa-whatsapp / nf-fa-comment_slash for the unlinked state.
  readonly property string glyphLinked: "\uf232"
  readonly property string glyphOffline: "\uf232"

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    if (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.substring(0, url.length - 1)
    return decodeURIComponent(url)
  }

  readonly property int unread: client.unread
  readonly property bool linked: client.ready
  readonly property bool showCount: root.setting("showUnreadCount", true) === true
  readonly property bool hideWhenEmpty: root.setting("hideWhenEmpty", false) === true

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.client = client
    panelLoader.item.settings = root.settings
    panelLoader.item.pluginDir = root.pluginDir
  }

  function openWebClient() {
    webLauncher.running = true
  }

  // A notification click routes through the daemon, which broadcasts `focus` to
  // every connected panel. Only select here: `omarchy-whatsapp-focus` asks the
  // shell to open one panel, so opening them all here would pop a panel on
  // every monitor at once.
  function focusChat(jid) {
    if (!jid || !panelLoader.item) return
    panelLoader.item.prepareChat(jid)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: !root.hideWhenEmpty || root.unread > 0 || root.opened

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  WhatsAppClient {
    id: client
    pluginDir: root.pluginDir
    socketPath: root.setting("socketPath", "")
    autostartDaemon: root.setting("autostartDaemon", true) === true
    onFocusRequested: function (jid) { root.focusChat(jid) }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Process {
    id: webLauncher
    command: [root.pluginDir + "/bin/omarchy-whatsapp-open", root.setting("webAppUrl", "https://web.whatsapp.com")]
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      var badge = Model.badgeText(root.unread)
      if (root.showCount && badge.length > 0) return root.glyphLinked + " " + badge
      return root.linked ? root.glyphLinked : root.glyphOffline
    }
    active: root.unread > 0
    dimmed: !root.linked
    tooltipText: {
      var label = Model.connectionLabel(client.connectionState, client.needsLogin,
        client.daemonOnline, client.pairingStopped)
      if (root.unread > 0) return label + " \u00b7 " + root.unread + " unread"
      return "WhatsApp \u00b7 " + label
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) root.openWebClient()
    }
  }
}
