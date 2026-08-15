import QtQuick
import QtQuick.Controls
import Quickshell
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

  // "chats" | "chat"; the login screen replaces both while unlinked.
  property string view: "chats"
  property string activeJid: ""
  property var activeChat: null
  property var messages: []
  property int cursorIndex: 0
  property string statusLine: ""

  readonly property var chats: client ? client.chats : []
  readonly property bool daemonOnline: client ? client.daemonOnline : false
  readonly property bool needsLogin: client ? client.needsLogin === true : false
  readonly property bool pairingPaused: client ? client.pairingStopped === true : false
  readonly property bool linked: client ? client.ready : false
  readonly property bool showLogin: !daemonOnline || needsLogin
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color secondaryForeground: Qt.darker(root.barForeground, 1.5)
  readonly property int chatLimit: root.setting("chatLimit", 40)
  readonly property int messageLimit: root.setting("messageLimit", 60)

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
    return list.slice(0, Math.max(1, root.chatLimit))
  }

  // Point the panel at a chat without touching read state. Used by the focus
  // broadcast: a notification must not clear the unread badge before the panel
  // is actually on screen. onOpenedChanged marks it read once it is.
  function prepareChat(jid) {
    if (!jid || !root.client) return
    root.activeJid = jid
    root.activeChat = null
    root.messages = []
    root.view = "chat"
    root.client.loadMessages(jid, root.messageLimit)
  }

  // User-initiated open: marks the chat read and puts the cursor in the reply box.
  function selectChat(jid) {
    root.prepareChat(jid)
    if (!root.client) return
    root.client.markRead(jid)
    Qt.callLater(function () { composer.forceActiveFocus() })
  }

  function back() {
    root.view = "chats"
    root.activeJid = ""
    root.activeChat = null
    root.messages = []
    composer.text = ""
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function moveCursor(delta) {
    if (root.view !== "chats") return
    var count = root.visibleChats.length
    if (count === 0) return
    var next = root.cursorIndex + delta
    if (next < 0) next = 0
    if (next > count - 1) next = count - 1
    root.cursorIndex = next
    chatList.positionViewAtIndex(next, ListView.Contain)
  }

  function activateCursor() {
    if (root.view !== "chats") return
    var chat = root.chatAt(root.cursorIndex)
    if (chat) root.selectChat(chat.jid)
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

  function appendMessage(message) {
    if (!message) return
    var list = root.messages.slice()
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === message.id) {
        list[i] = message
        root.messages = list
        return
      }
    }
    list.push(message)
    root.messages = list
    Qt.callLater(function () { messageList.positionViewAtEnd() })
  }

  onOpenedChanged: {
    if (!root.opened) return
    root.statusLine = ""
    if (root.client) {
      root.client.refresh()
      root.client.requestChats(root.chatLimit)
      if (root.view === "chat" && root.activeJid) {
        root.client.loadMessages(root.activeJid, root.messageLimit)
        root.client.markRead(root.activeJid)
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
      root.messages = messages || []
      Qt.callLater(function () { messageList.positionViewAtEnd() })
    }

    function onMessageArrived(jid, message, chat) {
      if (jid !== root.activeJid) return
      root.activeChat = chat
      root.appendMessage(message)
      // The conversation is on screen, so the message is read the moment it
      // lands rather than sitting as an unread the user has already seen.
      if (root.opened && root.client) root.client.markRead(jid)
    }

    function onMessageStatusChanged(jid, messageId, status) {
      if (jid !== root.activeJid) return
      var list = root.messages.slice()
      for (var i = 0; i < list.length; i++) {
        if (list[i].id === messageId) {
          list[i] = Object.assign({}, list[i], { status: status })
          root.messages = list
          return
        }
      }
    }

    function onCommandFailed(command, message) {
      root.statusLine = message
    }
  }

  Process {
    id: webLauncher
    command: [root.pluginDir + "/bin/omarchy-whatsapp-open", root.setting("webAppUrl", "https://web.whatsapp.com")]
  }

  Process {
    id: loginLauncher
    command: ["omarchy-launch-floating-terminal-with-presentation", root.pluginDir + "/bin/omarchy-whatsapp-login"]
    onExited: function (exitCode) {
      if (exitCode !== 0) loginFallback.running = true
    }
  }

  Process {
    id: loginFallback
    command: ["setsid", root.pluginDir + "/bin/omarchy-whatsapp-daemon"]
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
      // The composer owns every key while it has focus, including j/k/x.
      blocked: composer.activeFocus

      onCloseRequested: root.view === "chat" ? root.back() : root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()

      Column {
        id: content
        width: parent.width
        spacing: Style.space(8)

        // ── Header ───────────────────────────────────────────────────────
        Item {
          width: parent.width
          implicitHeight: Math.max(headerText.implicitHeight, headerActions.implicitHeight)

          Column {
            id: headerText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(1)

            Text {
              width: parent.width
              text: root.view === "chat"
                ? Model.chatTitle(root.activeChat || { jid: root.activeJid, name: "" })
                : "WhatsApp"
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
                if (root.view === "chat") {
                  var chat = root.activeChat
                  if (chat && chat.isGroup) return "Group"
                  return Model.prettyJid(root.activeJid)
                }
                var label = Model.connectionLabel(
                  root.client ? root.client.connectionState : "unknown",
                  root.needsLogin, root.daemonOnline, root.pairingPaused)
                var unread = root.client ? root.client.unread : 0
                return unread > 0 ? label + " \u00b7 " + unread + " unread" : label
              }
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
              iconText: "\uf060"
              tooltipText: "Back to chats"
              visible: root.view === "chat"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.back()
            }

            PanelActionButton {
              iconText: "\uf021"
              tooltipText: "Reconnect"
              visible: root.view !== "chat" && root.daemonOnline
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: {
                root.statusLine = "Reconnecting\u2026"
                if (root.client) root.client.reconnectWhatsApp()
              }
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
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ── Login / daemon-offline screen ────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showLogin

          Text {
            width: parent.width
            text: !root.daemonOnline
              ? "The WhatsApp bridge is not running."
              : (root.pairingPaused
                ? "QR refresh paused after waiting for a scan. The code expires, so it is not left on screen."
                : "Link this device to your WhatsApp account.")
            color: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Image {
            id: qrImage
            visible: root.client !== null && root.client.hasQr && qrImage.status === Image.Ready
            width: Math.min(parent.width, Style.space(220))
            height: width
            anchors.horizontalCenter: parent.horizontalCenter
            fillMode: Image.PreserveAspectFit
            // The daemon writes a new qr.<n>.png per refresh, so this URL
            // changes on its own and never needs a cache-busting reassignment.
            source: root.client && root.client.hasQr && root.client.qrPng
              ? Qt.resolvedUrl("file://" + root.client.qrPng)
              : ""
          }

          Text {
            width: parent.width
            visible: root.client !== null && root.client.hasQr
            text: "WhatsApp on your phone \u2192 Settings \u2192 Linked devices \u2192 Link a device, then scan this code. The code refreshes every 20 seconds on its own."
            color: root.secondaryForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.daemonOnline && !root.pairingPaused && !(root.client && root.client.hasQr)
            text: "Waiting for a pairing code from WhatsApp\u2026"
            color: root.secondaryForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: {
                if (!root.daemonOnline) return "Start bridge"
                return root.pairingPaused ? "Show QR code" : "Link in terminal"
              }
              foreground: root.barForeground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                if (!root.daemonOnline) daemonStarter.running = true
                else if (root.pairingPaused) {
                  root.statusLine = "Requesting a fresh QR code\u2026"
                  if (root.client) root.client.reconnectWhatsApp()
                } else loginLauncher.running = true
              }
            }

            Button {
              text: "Open WhatsApp Web"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                root.openWebClient()
                root.close()
              }
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
            text: root.linked ? "No conversations yet." : "Waiting for WhatsApp\u2026"
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
                anchors.right: rowMeta.left
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
                      bodyLabel.width,
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

                    Text {
                      id: bodyLabel
                      width: Math.min(implicitWidth, bubbleRow.maxInner)
                      text: messageRow.modelData.text || ""
                      color: root.barForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.Wrap
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
    }
  }
}
