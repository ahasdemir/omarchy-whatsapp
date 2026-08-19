import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The WhatsApp surface: chat list, conversation, inline reply, and the QR
// pairing screen. Loaded by BarWidget.qml, which injects `bar`, `anchorItem`,
// `hostWidget`, and the shared `client`.
Panel {
  id: root
  moduleName: "io.github.ricky.whatsapp"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var client: null
  property string pluginDir: ""

  // "chats" | "chat" | "compose"; the login screen replaces all while unlinked.
  property string view: "chats"
  property string activeJid: ""
  property var activeChat: null
  property var messages: []
  property int cursorIndex: 0
  property string statusLine: ""
  property bool pinToLatest: true
  property bool logoutConfirmOpen: false
  property string peekImagePath: ""
  readonly property bool peekActive: peekImagePath.length > 0
  property bool unreadOnly: false
  // Chats marked read while the panel is open stay in the unread-only list
  // until the window hides, so the row does not vanish under the cursor.
  property var heldReadJids: ({})
  property string composeJid: ""
  property bool composePicking: false
  property bool searchOpen: false
  property string searchQuery: ""
  readonly property int searchLimit: 200

  readonly property var chats: client ? client.chats : []
  readonly property bool daemonOnline: client ? client.daemonOnline : false
  readonly property bool needsLogin: client ? client.needsLogin === true : false
  readonly property bool pairingPaused: client ? client.pairingStopped === true : false
  readonly property bool hasQr: client ? client.hasQr === true : false
  readonly property bool linked: client ? client.signedIn : false
  readonly property bool showLogin: needsLogin
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color secondaryForeground: Qt.darker(root.barForeground, 1.5)
  readonly property int chatLimit: root.setting("chatLimit", 40)
  readonly property int messageLimit: root.setting("messageLimit", 60)

  readonly property var favorites: {
    var raw = root.setting("favorites", [])
    if (typeof raw === "string") {
      try { raw = JSON.parse(raw) } catch (e) { raw = [] }
    }
    if (!raw || !raw.length) return []
    var names = {}
    var chats = root.chats || []
    for (var c = 0; c < chats.length; c++) {
      if (chats[c] && chats[c].jid) names[chats[c].jid] = Model.chatTitle(chats[c])
    }
    var out = []
    for (var i = 0; i < raw.length; i++) {
      var item = raw[i]
      var jid = typeof item === "string" ? item : (item && item.jid ? item.jid : "")
      if (!jid) continue
      var stored = (item && item.name) ? item.name : ""
      out.push({ jid: jid, name: names[jid] || stored || Model.prettyJid(jid) })
    }
    return out
  }

  readonly property var pickerChats: {
    var list = root.chats || []
    var query = (root.searchQuery || "").trim()
    var out = []
    for (var i = 0; i < list.length; i++) {
      var chat = list[i]
      if (!chat || root.isFavorite(chat.jid)) continue
      if (query && !Model.chatMatches(chat, query)) continue
      out.push(chat)
    }
    return out
  }

  readonly property var visibleFavorites: {
    var list = root.favorites
    var query = (root.searchQuery || "").trim()
    if (!query) return list
    var out = []
    for (var i = 0; i < list.length; i++) {
      if (Model.chatMatches(list[i], query)) out.push(list[i])
    }
    return out
  }

  readonly property var composeTarget: {
    var jid = root.composeJid
    if (!jid) return null
    var list = root.favorites
    for (var i = 0; i < list.length; i++) {
      if (list[i].jid === jid) return list[i]
    }
    return { jid: jid, name: Model.prettyJid(jid) }
  }

  function open() { root.controller.show() }
  function close() { root.controller.hide() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function chatAt(index) {
    var list = root.visibleChats
    if (index < 0 || index >= list.length) return null
    return list[index]
  }

  readonly property var visibleChats: {
    var list = root.chats || []
    var held = root.heldReadJids || {}
    var filter = root.unreadOnly
    var query = (root.searchQuery || "").trim()
    var out = []
    var limit = query ? Math.max(root.chatLimit, root.searchLimit) : Math.max(1, root.chatLimit)
    for (var i = 0; i < list.length; i++) {
      var chat = list[i]
      if (!chat) continue
      var unread = (chat.unread || 0) > 0
      if (filter && !unread && !held[chat.jid]) continue
      if (query && !Model.chatMatches(chat, query)) continue
      out.push(chat)
      if (out.length >= limit) break
    }
    return out
  }

  function holdChat(jid) {
    if (!jid) return
    var next = Object.assign({}, root.heldReadJids)
    next[jid] = true
    root.heldReadJids = next
  }

  function markChatRead(jid) {
    if (!jid || !root.client) return
    if (root.opened) root.holdChat(jid)
    root.client.markRead(jid)
  }

  function toggleUnreadOnly() {
    root.unreadOnly = !root.unreadOnly
    var count = root.visibleChats.length
    if (root.cursorIndex >= count) root.cursorIndex = Math.max(0, count - 1)
  }

  function requestedChatLimit() {
    return root.searchOpen || (root.searchQuery || "").trim().length > 0
      ? Math.max(root.chatLimit, root.searchLimit)
      : root.chatLimit
  }

  function openSearch() {
    if (root.view === "chat") {
      root.view = "chats"
      root.activeJid = ""
      root.activeChat = null
      root.messages = []
      composer.text = ""
    }
    root.searchOpen = true
    if (root.client) root.client.requestChats(root.requestedChatLimit())
    Qt.callLater(function () { searchField.forceActiveFocus() })
  }

  function closeSearch() {
    root.searchOpen = false
    root.searchQuery = ""
    root.cursorIndex = 0
    if (root.client) root.client.requestChats(root.chatLimit)
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function toggleSearch() {
    if (root.searchOpen) root.closeSearch()
    else root.openSearch()
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function isFavorite(jid) {
    if (!jid) return false
    var list = root.favorites
    for (var i = 0; i < list.length; i++) if (list[i].jid === jid) return true
    return false
  }

  function persistFavorites(list) {
    var stored = []
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || !list[i].jid) continue
      stored.push({ jid: list[i].jid, name: list[i].name || "" })
    }
    root.persistSettings({ favorites: stored })
  }

  function toggleFavorite(chat) {
    if (!chat || !chat.jid) return
    var list = root.favorites.slice()
    var idx = -1
    for (var i = 0; i < list.length; i++) {
      if (list[i].jid === chat.jid) { idx = i; break }
    }
    if (idx >= 0) {
      list.splice(idx, 1)
      if (root.composeJid === chat.jid) root.composeJid = ""
    } else {
      list.push({ jid: chat.jid, name: Model.chatTitle(chat) })
    }
    root.persistFavorites(list)
  }

  function addFavorite(chat) {
    if (!chat || !chat.jid || root.isFavorite(chat.jid)) return
    var list = root.favorites.slice()
    list.push({ jid: chat.jid, name: Model.chatTitle(chat) })
    root.persistFavorites(list)
    root.composeJid = chat.jid
    root.composePicking = false
    root.cursorIndex = Math.max(0, list.length - 1)
    Qt.callLater(function () { quickComposer.forceActiveFocus() })
  }

  function openCompose() {
    root.view = "compose"
    root.composePicking = root.favorites.length === 0
    root.cursorIndex = 0
    root.statusLine = ""
    if (!root.composeJid && root.favorites.length === 1)
      root.composeJid = root.favorites[0].jid
    if (root.composeJid) {
      var list = root.favorites
      for (var i = 0; i < list.length; i++) {
        if (list[i].jid === root.composeJid) { root.cursorIndex = i; break }
      }
    }
    Qt.callLater(function () {
      if (!root.composePicking && root.favorites.length > 0) quickComposer.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  function sendQuickMessage() {
    var text = quickComposer.text
    if (!text || !text.trim().length) return
    if (!root.composeJid) {
      root.statusLine = "Pick a favorite first"
      return
    }
    if (!root.client || !root.client.ready) {
      root.statusLine = "Not connected to WhatsApp"
      return
    }
    if (root.client.sendMessage(root.composeJid, text)) {
      quickComposer.text = ""
      var target = root.composeTarget
      root.statusLine = "Sent to " + (target ? target.name : Model.prettyJid(root.composeJid))
    }
  }

  property int loadedMessageLimit: 60

  function loadMoreMessages() {
    if (!root.activeJid || !root.client) return
    root.loadedMessageLimit += 60
    root.pinToLatest = false
    root.client.loadMessages(root.activeJid, root.loadedMessageLimit)
  }

  // Point the panel at a chat without touching read state. Used by the focus
  // broadcast: a notification must not clear the unread badge before the panel
  // is actually on screen. onOpenedChanged marks it read once it is.
  function prepareChat(jid) {
    if (!jid || !root.client) return
    root.activeJid = jid
    root.activeChat = null
    root.messages = []
    root.loadedMessageLimit = root.messageLimit
    root.pinToLatest = true
    root.view = "chat"
    root.client.loadMessages(jid, root.messageLimit)
  }

  // User-initiated open: marks the chat read and puts the cursor in the reply box.
  function selectChat(jid) {
    root.prepareChat(jid)
    root.markChatRead(jid)
    Qt.callLater(function () { composer.forceActiveFocus() })
  }

  function back() {
    if (root.view === "compose" && root.composePicking && root.favorites.length > 0) {
      root.composePicking = false
      root.cursorIndex = 0
      Qt.callLater(function () { quickComposer.forceActiveFocus() })
      return
    }
    root.view = "chats"
    root.activeJid = ""
    root.activeChat = null
    root.messages = []
    root.composePicking = false
    composer.text = ""
    quickComposer.text = ""
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function requestLogout() {
    logoutConfirm.selectedIndex = 1
    root.logoutConfirmOpen = true
    Qt.callLater(function () { logoutConfirm.forceActiveFocus() })
  }

  function cancelLogout() {
    root.logoutConfirmOpen = false
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function confirmLogout() {
    root.logoutConfirmOpen = false
    if (root.client) root.client.logout()
    root.back()
    root.statusLine = ""
  }

  function moveCursor(delta) {
    var list = null
    var view = null
    if (root.view === "chats") {
      list = root.visibleChats
      view = chatList
    } else if (root.view === "compose" && root.composePicking) {
      list = root.pickerChats
      view = favoritePicker
    } else if (root.view === "compose") {
      list = root.visibleFavorites
      view = favoriteList
    } else {
      return
    }
    var count = list.length
    if (count === 0) return
    var next = root.cursorIndex + delta
    if (next < 0) next = 0
    if (next > count - 1) next = count - 1
    root.cursorIndex = next
    if (view) view.positionViewAtIndex(next, ListView.Contain)
  }

  function activateCursor() {
    if (root.view === "chats") {
      var chat = root.chatAt(root.cursorIndex)
      if (chat) root.selectChat(chat.jid)
      return
    }
    if (root.view !== "compose") return
    if (root.composePicking) {
      var pick = root.pickerChats[root.cursorIndex]
      if (pick) root.addFavorite(pick)
      return
    }
    var fav = root.visibleFavorites[root.cursorIndex]
    if (fav) {
      root.composeJid = fav.jid
      Qt.callLater(function () { quickComposer.forceActiveFocus() })
    }
  }

  function sendReply() {
    var text = composer.text
    if (!text || !text.trim().length) return
    if (!root.client || !root.client.ready) {
      root.statusLine = "Not connected to WhatsApp"
      return
    }
    if (root.client.sendMessage(root.activeJid, text)) {
      composer.text = ""
      root.statusLine = ""
      typingTimer.stop()
      root.client.setTyping(root.activeJid, "paused")
    }
  }

  function openWebClient() {
    webLauncher.running = true
  }

  function keepMessagePlace(fn) {
    var atEnd = messageList.atYEnd || root.pinToLatest
    var y = messageList.contentY
    fn()
    Qt.callLater(function () {
      if (atEnd) {
        root.pinToLatest = true
        messageList.positionViewAtEnd()
      } else {
        messageList.contentY = y
      }
    })
  }

  function patchMessage(messageId, fields) {
    var list = root.messages.slice()
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === messageId) {
        list[i] = Object.assign({}, list[i], fields)
        root.keepMessagePlace(function () { root.messages = list })
        return true
      }
    }
    return false
  }

  function appendMessage(message) {
    if (!message) return
    if (root.patchMessage(message.id, message)) return
    var list = root.messages.slice()
    list.push(message)
    root.pinToLatest = true
    root.messages = list
    Qt.callLater(function () { messageList.positionViewAtEnd() })
  }

  onOpenedChanged: {
    if (!root.opened) {
      root.heldReadJids = ({})
      root.searchOpen = false
      root.searchQuery = ""
      return
    }
    root.statusLine = ""
    if (root.client) {
      root.client.refresh()
      root.client.requestChats(root.requestedChatLimit())
      if (root.view === "chat" && root.activeJid) {
        root.client.loadMessages(root.activeJid, root.messageLimit)
        root.markChatRead(root.activeJid)
        Qt.callLater(function () { composer.forceActiveFocus() })
      }
    }
  }

  Connections {
    target: root.client
    enabled: root.client !== null

    function onMessagesLoaded(jid, chat, messages) {
      if (jid !== root.activeJid) return
      root.activeChat = chat
      var isFirstLoad = root.messages.length === 0
      if (isFirstLoad || root.pinToLatest) {
        root.pinToLatest = true
        root.messages = messages || []
        Qt.callLater(function () { messageList.positionViewAtEnd() })
      } else {
        root.keepMessagePlace(function () {
          root.messages = messages || []
        })
      }
    }

    function onMessageArrived(jid, message, chat) {
      if (jid !== root.activeJid) return
      root.activeChat = chat
      root.appendMessage(message)
      // The conversation is on screen, so the message is read the moment it
      // lands rather than sitting as an unread the user has already seen.
      if (root.opened && root.client && root.client.ready) root.markChatRead(jid)
    }

    function onMessageStatusChanged(jid, messageId, status) {
      if (jid !== root.activeJid) return
      root.patchMessage(messageId, { status: status })
    }

    function onMessageMedia(jid, messageId, imagePath) {
      if (jid !== root.activeJid || !imagePath) return
      root.patchMessage(messageId, { imagePath: imagePath })
    }

    function onCommandFailed(command, message) {
      if (command === "send") root.statusLine = message
    }
  }

  Process {
    id: linkLauncher
    property string targetUrl: ""
    command: ["xdg-open", targetUrl]
    function open(url) {
      targetUrl = url
      running = true
    }
  }

  Process {
    id: webLauncher
    command: [root.pluginDir + "/bin/omarchy-whatsapp-open", root.setting("webAppUrl", "https://web.whatsapp.com")]
  }

  Process {
    id: daemonStarter
    command: ["systemctl", "--user", "start", "omarchy-whatsapp.service"]
    onExited: function (exitCode) {
      if (exitCode !== 0 && root.client) root.client.startDaemon()
    }
  }

  // Coalesces keystrokes into one "composing" presence, then one "paused" a
  // few seconds after the user stops.
  Timer {
    id: typingTimer
    interval: 3000
    repeat: false
    onTriggered: if (root.client && root.activeJid) root.client.setTyping(root.activeJid, "paused")
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Composer, logout confirm, search, and image peek own keys while they are up.
      blocked: composer.activeFocus || quickComposer.activeFocus || searchField.activeFocus || root.logoutConfirmOpen || root.peekActive

      onCloseRequested: {
        if (root.peekActive) root.peekImagePath = ""
        else if (root.logoutConfirmOpen) root.cancelLogout()
        else if (root.searchOpen) root.closeSearch()
        else if (root.view === "chat" || root.view === "compose") root.back()
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onTextKey: function (t) {
        if ((t === "/" || t === "?") && !root.showLogin && root.view !== "chat")
          root.openSearch()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(8)

        // ── Header ───────────────────────────────────────────────────────
        Item {
          width: parent.width
          implicitHeight: Math.max(headerText.implicitHeight, backButton.height, headerActions.implicitHeight)

          Rectangle {
            id: backButton
            visible: root.view === "chat" || root.view === "compose"
            width: Style.space(26)
            height: Style.space(26)
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            radius: 0
            color: backMouse.containsMouse
              ? Style.hoverFillFor(root.barForeground, root.bar ? root.bar.urgent : Color.accent)
              : Style.normalFillFor(root.barForeground, Color.accent)
            border.color: root.barForeground
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "\uf060"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
            }

            MouseArea {
              id: backMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.back()
            }
          }

          Column {
            id: headerText
            anchors.left: backButton.visible ? backButton.right : parent.left
            anchors.leftMargin: backButton.visible ? Style.space(8) : 0
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(1)

            Text {
              width: parent.width
              text: {
                if (root.view === "chat")
                  return Model.chatTitle(root.activeChat || { jid: root.activeJid, name: "" })
                if (root.view === "compose")
                  return root.composePicking ? "Add favorite" : "New message"
                return "WhatsApp"
              }
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: {
                if (root.statusLine.length > 0) return root.statusLine
                if (root.view === "chat") return ""
                if (root.view === "compose") {
                  if (root.composePicking) return "Star a conversation to add it"
                  if (root.composeTarget) return "To " + root.composeTarget.name
                  return root.favorites.length > 0 ? "Pick a favorite" : "Star someone to get started"
                }
                if (root.needsLogin) return root.hasQr ? "Scan the QR code" : ""
                var unread = root.client ? root.client.unread : 0
                return unread > 0 ? unread + " unread" : ""
              }
              visible: text.length > 0
              color: root.statusLine.length > 0 ? (root.bar ? root.bar.urgent : Color.urgent) : root.secondaryForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              visible: !root.showLogin && root.view !== "chat"
              iconText: "\uf002"
              tooltipText: root.searchOpen ? "Close search" : "Find contacts"
              foreground: root.barForeground
              hasCursor: root.searchOpen
              fontFamily: root.fontFamily
              onClicked: root.toggleSearch()
            }

            PanelActionButton {
              visible: !root.showLogin && root.view !== "compose"
              iconText: "\uf040"
              tooltipText: "New message to a favorite"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.openCompose()
            }

            PanelActionButton {
              iconText: "\uf24d"
              tooltipText: "Open the full WhatsApp Web client"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: {
                root.openWebClient()
                root.close()
              }
            }

            Button {
              visible: !root.showLogin && root.view === "chats"
              text: "Unread"
              selected: root.unreadOnly
              bordered: true
              tooltipText: root.unreadOnly ? "Showing unread only" : "Show unread only"
              foreground: root.barForeground
              accent: root.bar ? root.bar.urgent : Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: root.toggleUnreadOnly()
            }

            PanelActionButton {
              visible: !root.showLogin && root.view === "chats"
              iconText: "\uf011"
              tooltipText: "Log out of WhatsApp"
              foreground: root.barForeground
              hoverColor: root.bar ? root.bar.urgent : Color.urgent
              fontFamily: root.fontFamily
              onClicked: root.requestLogout()
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        TextField {
          id: searchField
          width: parent.width
          visible: root.searchOpen && !root.showLogin && root.view !== "chat"
          foreground: root.barForeground
          accent: root.bar ? root.bar.urgent : Color.accent
          placeholderText: root.view === "compose" ? "Find a contact\u2026" : "Find chats and contacts\u2026"
          text: root.searchQuery
          onTextChanged: {
            if (root.searchQuery === text) return
            root.searchQuery = text
            root.cursorIndex = 0
          }
          Keys.onEscapePressed: function (event) {
            if (searchField.text.length > 0) searchField.text = ""
            else root.closeSearch()
            event.accepted = true
          }
          Keys.onDownPressed: function (event) {
            root.moveCursor(1)
            event.accepted = true
          }
          Keys.onUpPressed: function (event) {
            root.moveCursor(-1)
            event.accepted = true
          }
          Keys.onReturnPressed: function (event) {
            root.activateCursor()
            event.accepted = true
          }
        }

        // ── Login ────────────────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showLogin

          Image {
            id: qrImage
            visible: root.hasQr && qrImage.status === Image.Ready
            width: Math.min(parent.width, Style.space(220))
            height: width
            anchors.horizontalCenter: parent.horizontalCenter
            fillMode: Image.PreserveAspectFit
            source: root.hasQr && root.client && root.client.qrPng
              ? Qt.resolvedUrl("file://" + root.client.qrPng)
              : ""
          }

          Text {
            width: parent.width
            visible: root.hasQr
            horizontalAlignment: Text.AlignHCenter
            text: "WhatsApp \u2192 Linked devices \u2192 Link a device"
            color: root.secondaryForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: !root.hasQr && root.client && root.client.pendingLogin
            horizontalAlignment: Text.AlignHCenter
            text: "Getting QR code\u2026"
            color: root.secondaryForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !root.hasQr
            text: "Login"
            foreground: root.barForeground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: {
              if (!root.daemonOnline) daemonStarter.running = true
              if (root.client) root.client.startLogin()
            }
          }
        }

        // ── Chat list ────────────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: !root.showLogin && root.view === "chats"

          Text {
            width: parent.width
            visible: root.visibleChats.length === 0
            text: {
              if ((root.searchQuery || "").trim().length > 0) return "No matches."
              if (root.unreadOnly) return "No unread conversations."
              return "No conversations yet."
            }
            color: root.secondaryForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          ListView {
            id: chatList
            width: parent.width
            visible: root.visibleChats.length > 0
            height: Math.min(contentHeight, Style.space(300))
            model: root.visibleChats
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            currentIndex: root.cursorIndex
            spacing: Style.space(1)
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: CursorSurface {
              id: chatRow
              required property var modelData
              required property int index

              width: ListView.view.width
              implicitHeight: rowText.implicitHeight + Style.space(10)
              height: implicitHeight
              foreground: root.barForeground
              accent: root.bar ? root.bar.urgent : Color.accent
              hasCursor: root.cursorIndex === chatRow.index

              Column {
                id: rowText
                anchors.left: parent.left
                anchors.right: (starBtn.visible ? starBtn.left : (markReadBtn.visible ? markReadBtn.left : rowMeta.left))
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: Model.chatTitle(chatRow.modelData)
                  color: root.barForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: (chatRow.modelData.unread || 0) > 0
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: Model.truncate(Model.chatPreview(chatRow.modelData), 64)
                  color: root.secondaryForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Column {
                id: rowMeta
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(2)
                width: Math.max(badge.implicitWidth, stamp.implicitWidth)

                Text {
                  id: stamp
                  anchors.right: parent.right
                  text: Model.chatTimestamp(chatRow.modelData.lastTs)
                  color: root.secondaryForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  id: badge
                  anchors.right: parent.right
                  visible: (chatRow.modelData.unread || 0) > 0
                  implicitWidth: badgeLabel.implicitWidth + Style.space(8)
                  implicitHeight: badgeLabel.implicitHeight + Style.space(2)
                  width: implicitWidth
                  height: implicitHeight
                  radius: height / 2
                  color: root.bar ? root.bar.urgent : Color.urgent

                  Text {
                    id: badgeLabel
                    anchors.centerIn: parent
                    text: Model.badgeText(chatRow.modelData.unread)
                    color: Color.background
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.cursorIndex = chatRow.index
                onClicked: root.selectChat(chatRow.modelData.jid)
              }

              // After the row MouseArea so the click lands here, not on the chat.
              PanelActionButton {
                id: starBtn
                z: 2
                anchors.right: markReadBtn.visible ? markReadBtn.left : rowMeta.left
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                visible: chatRow.hasCursor || root.isFavorite(chatRow.modelData.jid)
                iconText: root.isFavorite(chatRow.modelData.jid) ? "\uf005" : "\uf006"
                tooltipText: root.isFavorite(chatRow.modelData.jid) ? "Remove from favorites" : "Add to favorites"
                foreground: root.barForeground
                fontFamily: root.fontFamily
                size: Style.space(22)
                onClicked: root.toggleFavorite(chatRow.modelData)
              }

              PanelActionButton {
                id: markReadBtn
                z: 2
                anchors.right: rowMeta.left
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                visible: chatRow.hasCursor && (chatRow.modelData.unread || 0) > 0
                iconText: "\uf00c"
                tooltipText: "Mark as read"
                foreground: root.barForeground
                fontFamily: root.fontFamily
                size: Style.space(22)
                onClicked: root.markChatRead(chatRow.modelData.jid)
              }
            }
          }
        }

        // ── New message to a favorite ────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: !root.showLogin && root.view === "compose"

          Text {
            width: parent.width
            visible: !root.composePicking && root.visibleFavorites.length === 0
            text: (root.searchQuery || "").trim().length > 0
              ? "No matching favorites."
              : "No favorites yet. Star a conversation, or add one below."
            color: root.secondaryForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          ListView {
            id: favoriteList
            width: parent.width
            visible: !root.composePicking && root.visibleFavorites.length > 0
            height: Math.min(contentHeight, Style.space(220))
            model: root.visibleFavorites
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            currentIndex: root.cursorIndex
            spacing: Style.space(1)
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: CursorSurface {
              id: favRow
              required property var modelData
              required property int index

              width: ListView.view.width
              implicitHeight: favName.implicitHeight + Style.space(12)
              height: implicitHeight
              foreground: root.barForeground
              accent: root.bar ? root.bar.urgent : Color.accent
              hasCursor: !root.composePicking && root.cursorIndex === favRow.index
              current: root.composeJid === favRow.modelData.jid

              Text {
                id: favName
                anchors.left: parent.left
                anchors.right: favRemove.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                text: favRow.modelData.name || Model.prettyJid(favRow.modelData.jid)
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: root.composeJid === favRow.modelData.jid
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.cursorIndex = favRow.index
                onClicked: {
                  root.composeJid = favRow.modelData.jid
                  root.statusLine = ""
                  Qt.callLater(function () { quickComposer.forceActiveFocus() })
                }
              }

              PanelActionButton {
                id: favRemove
                z: 2
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\uf005"
                tooltipText: "Remove from favorites"
                foreground: root.barForeground
                fontFamily: root.fontFamily
                size: Style.space(22)
                onClicked: root.toggleFavorite(favRow.modelData)
              }
            }
          }

          Button {
            visible: !root.composePicking
            text: "Add favorite"
            bordered: true
            foreground: root.barForeground
            accent: root.bar ? root.bar.urgent : Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            onClicked: {
              root.composePicking = true
              root.cursorIndex = 0
              Qt.callLater(function () { keyCatcher.forceActiveFocus() })
            }
          }

          Text {
            width: parent.width
            visible: root.composePicking && root.pickerChats.length === 0
            text: (root.searchQuery || "").trim().length > 0
              ? "No matching conversations."
              : "No other conversations to add."
            color: root.secondaryForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          ListView {
            id: favoritePicker
            width: parent.width
            visible: root.composePicking && root.pickerChats.length > 0
            height: Math.min(contentHeight, Style.space(260))
            model: root.pickerChats
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            currentIndex: root.cursorIndex
            spacing: Style.space(1)
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: CursorSurface {
              id: pickRow
              required property var modelData
              required property int index

              width: ListView.view.width
              implicitHeight: pickName.implicitHeight + Style.space(12)
              height: implicitHeight
              foreground: root.barForeground
              accent: root.bar ? root.bar.urgent : Color.accent
              hasCursor: root.composePicking && root.cursorIndex === pickRow.index

              Text {
                id: pickName
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                text: Model.chatTitle(pickRow.modelData)
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.cursorIndex = pickRow.index
                onClicked: root.addFavorite(pickRow.modelData)
              }
            }
          }

          Item {
            width: parent.width
            visible: !root.composePicking
            implicitHeight: Math.max(quickComposer.implicitHeight, quickSend.implicitHeight)

            TextField {
              id: quickComposer
              anchors.left: parent.left
              anchors.right: quickSend.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              accent: root.bar ? root.bar.urgent : Color.accent
              placeholderText: root.composeTarget
                ? "Message " + root.composeTarget.name + "\u2026"
                : "Pick a favorite, then type\u2026"
              enabled: root.linked && root.composeJid.length > 0
              onAccepted: root.sendQuickMessage()
              Keys.onEscapePressed: function (event) {
                if (quickComposer.text.length > 0) quickComposer.text = ""
                else root.back()
                event.accepted = true
              }
            }

            PanelActionButton {
              id: quickSend
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf1d8"
              tooltipText: "Send"
              enabled: root.linked && root.composeJid.length > 0 && quickComposer.text.trim().length > 0
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.sendQuickMessage()
            }
          }
        }

        // ── Conversation ─────────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.showLogin && root.view === "chat"

          ListView {
            id: messageList
            width: parent.width
            height: Style.space(300)
            model: root.messages
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            onMovementEnded: root.pinToLatest = atYEnd
            onContentHeightChanged: if (root.pinToLatest) Qt.callLater(function () { messageList.positionViewAtEnd() })
            onAtYBeginningChanged: {
              if (atYBeginning && root.messages.length >= root.loadedMessageLimit && root.messages.length > 0) {
                root.loadMoreMessages()
              }
            }

            header: Item {
              width: messageList.width
              height: (root.messages.length >= root.loadedMessageLimit && root.messages.length > 0) ? Style.space(28) : 0
              visible: root.messages.length >= root.loadedMessageLimit && root.messages.length > 0
              Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.85
                height: Style.space(22)
                color: Qt.rgba(root.highlightColor.r, root.highlightColor.g, root.highlightColor.b, 0.15)
                radius: Style.space(4)
                Text {
                  anchors.centerIn: parent
                  text: "▲ Load older messages"
                  color: root.highlightColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.loadMoreMessages()
                }
              }
            }

            delegate: Column {
              id: messageRow
              required property var modelData
              required property int index

              width: ListView.view.width
              spacing: Style.space(3)

              readonly property var previous: messageRow.index > 0 ? root.messages[messageRow.index - 1] : null
              readonly property bool showDay: !messageRow.previous
                || !Model.sameDay(messageRow.previous.ts, messageRow.modelData.ts)

              Text {
                width: parent.width
                visible: messageRow.showDay
                horizontalAlignment: Text.AlignHCenter
                text: Model.dayLabel(messageRow.modelData.ts)
                color: root.secondaryForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Item {
                id: bubbleRow
                width: parent.width
                implicitHeight: bubble.height
                height: implicitHeight

                readonly property real pad: Style.space(8)
                // Each label's width comes from its own natural (unwrapped)
                // implicitWidth, and the bubble from those labels. Anchoring the
                // content to both bubble edges instead would make the bubble's
                // width depend on content that depends on the bubble: a binding
                // loop, which collapses every bubble to a few pixels.
                readonly property real maxInner: Math.max(Style.space(60), bubbleRow.width * 0.82 - bubbleRow.pad * 2)
                readonly property bool hasImage: messageRow.modelData.imagePath
                  && String(messageRow.modelData.imagePath).length > 0
                readonly property bool showBody: {
                  var text = messageRow.modelData.text || ""
                  if (!text.length) return false
                  if (bubbleRow.hasImage && Model.isPhotoPlaceholder(text)) return false
                  return true
                }
                readonly property bool showSender: !messageRow.modelData.fromMe
                  && root.activeChat !== null
                  && root.activeChat.isGroup === true

                Rectangle {
                  id: bubble
                  width: bubbleContent.width + bubbleRow.pad * 2
                  height: bubbleContent.implicitHeight + bubbleRow.pad
                  anchors.right: messageRow.modelData.fromMe ? parent.right : undefined
                  anchors.left: messageRow.modelData.fromMe ? undefined : parent.left
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
                  color: messageRow.modelData.fromMe
                    ? Style.selectedFillFor(root.barForeground, root.bar ? root.bar.urgent : Color.accent)
                    : Style.normalFillFor(root.barForeground, Color.accent)

                  Column {
                    id: bubbleContent
                    x: bubbleRow.pad
                    y: bubbleRow.pad / 2
                    spacing: Style.space(1)
                    width: Math.max(
                      bubbleRow.showSender ? senderLabel.width : 0,
                      bubbleRow.hasImage ? photo.width : 0,
                      bodyLabel.visible ? bodyLabel.width : 0,
                      Math.min(metaLabel.implicitWidth, bubbleRow.maxInner))

                    Text {
                      id: senderLabel
                      visible: bubbleRow.showSender
                      width: Math.min(implicitWidth, bubbleRow.maxInner)
                      text: messageRow.modelData.senderName || ""
                      color: root.bar ? root.bar.urgent : Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Image {
                      id: photo
                      visible: bubbleRow.hasImage && photo.status !== Image.Error
                      width: Math.min(bubbleRow.maxInner, Style.space(220))
                      height: photo.sourceSize.height > 0
                        ? Math.min(Style.space(200), photo.sourceSize.height * (width / Math.max(1, photo.sourceSize.width)))
                        : Style.space(140)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      cache: true
                      source: bubbleRow.hasImage
                        ? Qt.resolvedUrl("file://" + messageRow.modelData.imagePath)
                        : ""

                      MouseArea {
                        id: photoMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.peekImagePath = messageRow.modelData.imagePath

                        Rectangle {
                          anchors.fill: parent
                          color: photoMouse.containsMouse ? "#20ffffff" : "transparent"
                          radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)

                          Text {
                            anchors.centerIn: parent
                            visible: photoMouse.containsMouse
                            text: "\uf00e"
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            color: "#ffffff"
                          }
                        }
                      }
                    }

                    Text {
                      id: bodyLabel
                      visible: bubbleRow.showBody
                      width: Math.min(implicitWidth, bubbleRow.maxInner)
                      textFormat: Text.StyledText
                      text: Model.formatMessageText(messageRow.modelData.text, root.bar ? root.bar.urgent : Color.accent)
                      color: root.barForeground
                      linkColor: root.bar ? root.bar.urgent : Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.Wrap
                      onLinkActivated: function (link) {
                        if (link) {
                          if (!Qt.openUrlExternally(link)) linkLauncher.open(link)
                        }
                      }
                      MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        hoverEnabled: true
                        cursorShape: bodyLabel.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.IBeamCursor
                      }
                    }

                    Text {
                      id: metaLabel
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      text: {
                        var stampText = Model.messageTimestamp(messageRow.modelData.ts)
                        if (!messageRow.modelData.fromMe) return stampText
                        return stampText + " " + Model.statusGlyph(messageRow.modelData.status)
                      }
                      color: messageRow.modelData.fromMe && Model.statusIsRead(messageRow.modelData.status)
                        ? (root.bar ? root.bar.urgent : Color.accent)
                        : root.secondaryForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.messages.length === 0
            text: "No messages loaded yet."
            color: root.secondaryForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ── Inline reply ───────────────────────────────────────────────
          Item {
            width: parent.width
            implicitHeight: Math.max(composer.implicitHeight, sendButton.implicitHeight)

            TextField {
              id: composer
              anchors.left: parent.left
              anchors.right: sendButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              accent: root.bar ? root.bar.urgent : Color.accent
              placeholderText: root.linked ? "Reply\u2026" : "Not connected"
              enabled: root.linked
              onAccepted: root.sendReply()
              onTextChanged: {
                if (!root.client || !root.activeJid || !text.length) return
                if (!typingTimer.running) root.client.setTyping(root.activeJid, "composing")
                typingTimer.restart()
              }
              Keys.onEscapePressed: function (event) {
                if (composer.text.length > 0) composer.text = ""
                else root.back()
                event.accepted = true
              }
            }

            PanelActionButton {
              id: sendButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf1d8"
              tooltipText: "Send"
              enabled: root.linked && composer.text.trim().length > 0
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.sendReply()
            }
          }
        }
      }

      ConfirmDialog {
        id: logoutConfirm
        anchors.fill: parent
        opened: root.logoutConfirmOpen
        z: 10
        focus: opened
        message: "Log out and unlink this device?"
        confirmText: "Log out"
        foreground: root.barForeground
        fontFamily: root.fontFamily
        onCanceled: root.cancelLogout()
        onConfirmed: root.confirmLogout()

        Keys.onPressed: function (event) {
          if (handleKey(event)) event.accepted = true
        }
      }
    }
  }

  // ── Desktop Screen-Centered Image Peek Window ───────────────────────
  PanelWindow {
    id: imagePeekOverlay
    visible: root.peekActive
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-whatsapp-peek"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.peekActive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    onVisibleChanged: {
      if (visible) {
        Qt.callLater(function () { peekKeyCatcher.forceActiveFocus() })
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.82)

      MouseArea {
        anchors.fill: parent
        onClicked: root.peekImagePath = ""
      }
    }

    Item {
      id: peekKeyCatcher
      anchors.fill: parent
      focus: root.peekActive

      Keys.onEscapePressed: function (event) {
        root.peekImagePath = ""
        event.accepted = true
      }

      Item {
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.85, Style.space(950))
        height: Math.min(parent.height * 0.85, Style.space(850))

        Image {
          id: peekImage
          anchors.centerIn: parent
          width: Math.min(parent.width, sourceSize.width > 0 ? sourceSize.width : parent.width)
          height: Math.min(parent.height, sourceSize.height > 0 ? sourceSize.height : parent.height)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          source: root.peekActive ? Qt.resolvedUrl("file://" + root.peekImagePath) : ""

          MouseArea {
            anchors.fill: parent
            onClicked: function (event) { event.accepted = true }
          }
        }
      }
    }
  }
}
