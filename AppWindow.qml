import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "file:///usr/share/omarchy/shell/Commons" as Commons
import "Model.js" as Model

Scope {
  id: rootScope

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    if (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.substring(0, url.length - 1)
    return decodeURIComponent(url)
  }

  FloatingWindow {
    id: window
    title: "WhatsApp - Omarchy"
    visible: true
    implicitWidth: 1040
    implicitHeight: 680

    // Theme change tick counter for live theme reactivity
    property int themeTick: 0

    // Live theme file watchers that trigger immediate UI color updates on theme swap
    FileView {
      id: colorsThemeWatcher
      path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
      watchChanges: true
      printErrors: false
      onFileChanged: colorsThemeWatcher.reload()
      onLoaded: window.themeTick++
    }

    FileView {
      id: shellThemeWatcher
      path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/shell.toml"
      watchChanges: true
      printErrors: false
      onFileChanged: shellThemeWatcher.reload()
      onLoaded: window.themeTick++
    }

    // Dynamic Omarchy Theme System Colors (Synced live with OS Theme changes)
    readonly property color bgBase: { var t = window.themeTick; return Commons.Color.background }
    readonly property color bgSidebar: { var t = window.themeTick; return Qt.darker(Commons.Color.background, 1.15) }
    readonly property color bgSurface: { var t = window.themeTick; return Qt.lighter(Commons.Color.background, 1.15) }
    readonly property color bgHover: { var t = window.themeTick; return Qt.lighter(Commons.Color.background, 1.25) }
    readonly property color bgSelected: { var t = window.themeTick; return Qt.lighter(Commons.Color.background, 1.4) }
    readonly property color bgOverlay: { var t = window.themeTick; return Qt.lighter(Commons.Color.background, 1.2) }
    readonly property color borderColor: { var t = window.themeTick; return Qt.lighter(Commons.Color.background, 1.4) }
    readonly property color borderActive: { var t = window.themeTick; return Commons.Color.urgent || Commons.Color.accent }
    readonly property color fgMain: { var t = window.themeTick; return Commons.Color.foreground }
    readonly property color fgMuted: { var t = window.themeTick; return Qt.darker(Commons.Color.foreground, 1.35) }
    readonly property color fgDim: { var t = window.themeTick; return Qt.darker(Commons.Color.foreground, 1.5) }
    readonly property color accentColor: { var t = window.themeTick; return Commons.Color.accent }
    readonly property color urgentColor: { var t = window.themeTick; return Commons.Color.urgent }
    readonly property string fontFamily: { var t = window.themeTick; return Commons.Style.font.family }

    property bool sidebarCollapsed: false
    property string navMode: "chats" // "chats" | "unread" | "favorites"
    property string activeJid: ""
    property var activeChat: null
    property var messages: []
    property int loadedMessageLimit: 60
    property bool pinToLatest: true
    property string searchFilter: ""
    property string peekImagePath: ""
    property var favoriteJids: ({})
    property var replyingToMessage: null

    // Keyboard Shortcuts
    Shortcut { sequence: "Ctrl+F"; context: Qt.ApplicationShortcut; onActivated: searchInput.forceActiveFocus() }
    Shortcut { sequence: "Ctrl+/"; context: Qt.ApplicationShortcut; onActivated: searchInput.forceActiveFocus() }
    Shortcut { sequence: "Ctrl+1"; context: Qt.ApplicationShortcut; onActivated: window.navMode = "chats" }
    Shortcut { sequence: "Ctrl+2"; context: Qt.ApplicationShortcut; onActivated: window.navMode = "unread" }
    Shortcut { sequence: "Ctrl+3"; context: Qt.ApplicationShortcut; onActivated: window.navMode = "favorites" }
    Shortcut { sequence: "Ctrl+R"; context: Qt.ApplicationShortcut; onActivated: client.refresh() }
    Shortcut {
      sequence: "Esc"
      context: Qt.ApplicationShortcut
      onActivated: {
        if (window.peekImagePath !== "") {
          window.peekImagePath = ""
        } else if (window.replyingToMessage) {
          window.replyingToMessage = null
        } else if (searchInput.activeFocus || window.searchFilter !== "") {
          searchInput.text = ""
          searchInput.focus = false
        }
      }
    }

    // Custom Omarchy Styled ToolTip
    component AppToolTip: ToolTip {
      id: tt
      delay: 250
      padding: 6
      background: Rectangle {
        color: window.bgSurface
        border.color: window.borderActive
        border.width: 1
      }
      contentItem: Text {
        text: tt.text
        color: window.fgMain
        font.family: window.fontFamily
        font.pixelSize: 11
      }
    }

    WhatsAppClient {
      id: client
      pluginDir: rootScope.pluginDir
    }

    Connections {
      target: client

      function onMessagesLoaded(jid, chat, msgs) {
        if (jid !== window.activeJid) return
        window.activeChat = chat
        var isFirst = window.messages.length === 0
        if (isFirst || window.pinToLatest) {
          window.pinToLatest = true
          window.messages = msgs || []
          Qt.callLater(function () { messageList.positionViewAtEnd() })
        } else {
          var y = messageList.contentY
          window.messages = msgs || []
          Qt.callLater(function () { messageList.contentY = y })
        }
      }

      function onMessageArrived(jid, message, chat) {
        if (jid !== window.activeJid) return
        window.activeChat = chat
        var list = window.messages.slice()
        list.push(message)
        window.pinToLatest = true
        window.messages = list
        Qt.callLater(function () { messageList.positionViewAtEnd() })
        client.markRead(jid)
      }

      function onMessageDeleted(jid, messageId, chat) {
        if (jid !== window.activeJid) return
        var list = window.messages.filter(function (m) { return m && m.id !== messageId })
        window.messages = list
      }
    }

    function isFavorite(jid) {
      if (!jid) return false
      if (window.favoriteJids[jid] === true) return true
      var list = client.chats || []
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].jid === jid) {
          return !!(list[i].pinned || list[i].favorite || list[i].isFavorite)
        }
      }
      return false
    }

    function toggleFavorite(jid) {
      if (!jid) return
      var map = Object.assign({}, window.favoriteJids)
      map[jid] = !map[jid]
      window.favoriteJids = map
    }

    function selectChat(jid) {
      if (!jid) return
      window.activeJid = jid
      window.activeChat = null
      window.messages = []
      window.loadedMessageLimit = 60
      window.pinToLatest = true
      window.replyingToMessage = null
      client.loadMessages(jid, 60)
      client.markRead(jid)
      Qt.callLater(function () { composer.forceActiveFocus() })
    }

    function loadMoreMessages() {
      if (!window.activeJid) return
      window.loadedMessageLimit += 60
      window.pinToLatest = false
      client.loadMessages(window.activeJid, window.loadedMessageLimit)
    }

    function sendReply() {
      var text = composer.text
      if (!text || !text.trim().length) return
      if (!client.ready || !window.activeJid) return
      var quotedId = window.replyingToMessage ? window.replyingToMessage.id : ""
      if (client.sendMessage(window.activeJid, text, quotedId)) {
        composer.text = ""
        window.replyingToMessage = null
      }
    }

    Rectangle {
      anchors.fill: parent
      color: window.bgBase
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if ((event.modifiers & Qt.ControlModifier)) {
          if (event.key === Qt.Key_F || event.key === Qt.Key_Slash) {
            searchInput.forceActiveFocus()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_1) {
            window.navMode = "chats"
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_2) {
            window.navMode = "unread"
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_3) {
            window.navMode = "favorites"
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_R) {
            client.refresh()
            event.accepted = true
            return
          }
        }
        if (event.key === Qt.Key_Escape) {
          if (window.peekImagePath !== "") {
            window.peekImagePath = ""
            event.accepted = true
            return
          }
          if (window.replyingToMessage) {
            window.replyingToMessage = null
            event.accepted = true
            return
          }
          if (searchInput.activeFocus || window.searchFilter !== "") {
            searchInput.text = ""
            searchInput.focus = false
            event.accepted = true
            return
          }
        }
      }

      RowLayout {
        anchors.fill: parent
        spacing: 0

        // ── OMARCHY SIDEBAR (LEFT) ─────────────────────────────────────────
        Rectangle {
          id: sidebar
          Layout.fillHeight: true
          Layout.preferredWidth: window.sidebarCollapsed ? 56 : 230
          Layout.minimumWidth: window.sidebarCollapsed ? 56 : 200
          Layout.maximumWidth: window.sidebarCollapsed ? 56 : 260
          color: window.bgSidebar

          Behavior on Layout.preferredWidth {
            NumberAnimation { duration: 150; easing.type: Easing.InOutQuad }
          }

          // 1px Right Border
          Rectangle {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            width: 1
            color: window.borderColor
          }

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: window.sidebarCollapsed ? 8 : 14
            spacing: 16

            // Header Section: App Title, Subtitle, & Collapse Toggle Button
            RowLayout {
              Layout.fillWidth: true
              spacing: 8

              Text {
                text: "\uf232"
                font.family: window.fontFamily
                font.pixelSize: 18
                color: window.fgMain
              }

              ColumnLayout {
                visible: !window.sidebarCollapsed
                Layout.fillWidth: true
                spacing: 2

                Text {
                  text: "WhatsApp"
                  font.family: window.fontFamily
                  font.pixelSize: 16
                  font.bold: true
                  color: window.fgMain
                }

                Text {
                  text: "for Omarchy"
                  font.family: window.fontFamily
                  font.pixelSize: 11
                  color: window.fgMuted
                }
              }

              // Sidebar Toggle Button (\uf0c9 hamburger icon)
              Text {
                text: "\uf0c9"
                font.family: window.fontFamily
                font.pixelSize: 14
                color: toggleSidebarMouse.containsMouse ? window.fgMain : window.fgMuted

                AppToolTip {
                  visible: toggleSidebarMouse.containsMouse
                  text: window.sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"
                }

                MouseArea {
                  id: toggleSidebarMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: window.sidebarCollapsed = !window.sidebarCollapsed
                }
              }
            }

            // Divider Line
            Rectangle {
              Layout.fillWidth: true
              height: 1
              color: window.borderColor
            }

            // NAVIGATION Category Header
            Text {
              visible: !window.sidebarCollapsed
              text: "NAVIGATION"
              font.family: window.fontFamily
              font.pixelSize: 10
              font.bold: true
              color: window.fgDim
            }

            // Sidebar Menu Item 1: All Chats
            Rectangle {
              Layout.fillWidth: true
              height: 32
              color: window.navMode === "chats" ? window.bgSelected : (nav1Mouse.containsMouse ? window.bgHover : "transparent")
              border.color: window.navMode === "chats" ? window.borderActive : "transparent"
              border.width: 1

              AppToolTip {
                visible: window.sidebarCollapsed && nav1Mouse.containsMouse
                text: "All Chats"
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: window.sidebarCollapsed ? 0 : 10
                anchors.rightMargin: window.sidebarCollapsed ? 0 : 10
                spacing: 10

                Text {
                  Layout.alignment: window.sidebarCollapsed ? Qt.AlignHCenter : Qt.AlignLeft
                  text: "\uf086"
                  font.family: window.fontFamily
                  font.pixelSize: 13
                  color: window.fgMain
                }

                Text {
                  visible: !window.sidebarCollapsed
                  text: "All Chats"
                  font.family: window.fontFamily
                  font.pixelSize: 12
                  color: window.fgMain
                  Layout.fillWidth: true
                }

                Text {
                  visible: !window.sidebarCollapsed
                  text: client.chats ? client.chats.length : ""
                  font.family: window.fontFamily
                  font.pixelSize: 11
                  color: window.fgMuted
                }
              }

              MouseArea {
                id: nav1Mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: window.navMode = "chats"
              }
            }

            // Sidebar Menu Item 2: Unread
            Rectangle {
              Layout.fillWidth: true
              height: 32
              color: window.navMode === "unread" ? window.bgSelected : (nav2Mouse.containsMouse ? window.bgHover : "transparent")
              border.color: window.navMode === "unread" ? window.borderActive : "transparent"
              border.width: 1

              AppToolTip {
                visible: window.sidebarCollapsed && nav2Mouse.containsMouse
                text: "Unread"
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: window.sidebarCollapsed ? 0 : 10
                anchors.rightMargin: window.sidebarCollapsed ? 0 : 10
                spacing: 10

                Text {
                  Layout.alignment: window.sidebarCollapsed ? Qt.AlignHCenter : Qt.AlignLeft
                  text: "\uf0b0"
                  font.family: window.fontFamily
                  font.pixelSize: 13
                  color: window.fgMain
                }

                Text {
                  visible: !window.sidebarCollapsed
                  text: "Unread"
                  font.family: window.fontFamily
                  font.pixelSize: 12
                  color: window.fgMain
                  Layout.fillWidth: true
                }

                Rectangle {
                  visible: client.unread > 0 && !window.sidebarCollapsed
                  width: unreadTxt.implicitWidth + 8
                  height: 16
                  color: window.bgOverlay
                  border.color: window.borderActive
                  border.width: 1

                  Text {
                    id: unreadTxt
                    anchors.centerIn: parent
                    text: client.unread
                    font.family: window.fontFamily
                    font.pixelSize: 10
                    color: window.fgMain
                  }
                }
              }

              MouseArea {
                id: nav2Mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: window.navMode = "unread"
              }
            }

            // Sidebar Menu Item 3: Favorites
            Rectangle {
              Layout.fillWidth: true
              height: 32
              color: window.navMode === "favorites" ? window.bgSelected : (nav3Mouse.containsMouse ? window.bgHover : "transparent")
              border.color: window.navMode === "favorites" ? window.borderActive : "transparent"
              border.width: 1

              AppToolTip {
                visible: window.sidebarCollapsed && nav3Mouse.containsMouse
                text: "Favorites"
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: window.sidebarCollapsed ? 0 : 10
                anchors.rightMargin: window.sidebarCollapsed ? 0 : 10
                spacing: 10

                Text {
                  Layout.alignment: window.sidebarCollapsed ? Qt.AlignHCenter : Qt.AlignLeft
                  text: "\uf005"
                  font.family: window.fontFamily
                  font.pixelSize: 13
                  color: window.navMode === "favorites" ? window.borderActive : window.fgMain
                }

                Text {
                  visible: !window.sidebarCollapsed
                  text: "Favorites"
                  font.family: window.fontFamily
                  font.pixelSize: 12
                  color: window.fgMain
                  Layout.fillWidth: true
                }
              }

              MouseArea {
                id: nav3Mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: window.navMode = "favorites"
              }
            }

            Item { Layout.fillHeight: true } // Spacer

            // Bottom Section: Status & Refresh
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 8

              Rectangle {
                Layout.fillWidth: true
                height: 1
                color: window.borderColor
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                  Layout.alignment: window.sidebarCollapsed ? Qt.AlignHCenter : Qt.AlignLeft
                  text: "\uf007"
                  font.family: window.fontFamily
                  font.pixelSize: 12
                  color: window.fgMuted
                }

                Text {
                  visible: !window.sidebarCollapsed
                  text: client.me ? (client.me.name || client.me.user || "Linked") : (client.linkUp ? "Connecting..." : "Offline")
                  font.family: window.fontFamily
                  font.pixelSize: 11
                  color: window.fgMuted
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }

                Text {
                  visible: !window.sidebarCollapsed
                  text: "\uf021"
                  font.family: window.fontFamily
                  font.pixelSize: 12
                  color: refreshMouse.containsMouse ? window.fgMain : window.fgDim

                  MouseArea {
                    id: refreshMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: client.refresh()
                  }
                }
              }
            }
          }
        }

        // ── MAIN WORKSPACE (RIGHT) ─────────────────────────────────────────
        Rectangle {
          Layout.fillWidth: true
          Layout.fillHeight: true
          color: window.bgBase

          ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // Top Control Bar (Matching Spotify Omarchy top header: Title + Window Actions ?, ↻, ✕)
            Rectangle {
              Layout.fillWidth: true
              height: 48
              color: window.bgSurface

              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: window.borderColor
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 12

                ColumnLayout {
                  spacing: 1
                  RowLayout {
                    spacing: 8
                    Text {
                      text: window.activeChat ? Model.chatTitle(window.activeChat) : (window.navMode === "favorites" ? "Favorite Chats" : (window.navMode === "unread" ? "Unread Chats" : "Conversations"))
                      font.family: window.fontFamily
                      font.pixelSize: 14
                      font.bold: true
                      color: window.fgMain
                    }

                    // Star Favorite Toggle Icon for Active Chat
                    Text {
                      visible: !!window.activeJid
                      text: window.isFavorite(window.activeJid) ? "\uf005" : "\uf006"
                      font.family: window.fontFamily
                      font.pixelSize: 14
                      color: window.isFavorite(window.activeJid) ? window.borderActive : window.fgMuted

                      AppToolTip {
                        visible: favToggleMouse.containsMouse
                        text: window.isFavorite(window.activeJid) ? "Remove from favorites" : "Add to favorites"
                      }

                      MouseArea {
                        id: favToggleMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: window.toggleFavorite(window.activeJid)
                      }
                    }
                  }

                  Text {
                    text: window.activeJid ? Model.prettyJid(window.activeJid) : "Your WhatsApp messages"
                    font.family: window.fontFamily
                    font.pixelSize: 11
                    color: window.fgMuted
                  }
                }

                Item { Layout.fillWidth: true } // Spacer

                // Window action controls (?, ↻, ✕)
                RowLayout {
                  spacing: 12

                  Text {
                    text: client.notificationsMuted ? "\uf1f6" : "\uf0f3"
                    font.family: window.fontFamily
                    font.pixelSize: 12
                    color: client.notificationsMuted ? window.urgentColor : (muteMouse.containsMouse ? window.fgMain : window.fgMuted)

                    AppToolTip {
                      visible: muteMouse.containsMouse
                      text: client.notificationsMuted ? "Unmute desktop notifications" : "Mute desktop notifications"
                    }

                    MouseArea {
                      id: muteMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: client.toggleNotifications()
                    }
                  }

                  Text {
                    text: "?"
                    font.family: window.fontFamily
                    font.pixelSize: 13
                    color: helpMouse.containsMouse ? window.fgMain : window.fgMuted
                    MouseArea { id: helpMouse; anchors.fill: parent; hoverEnabled: true }
                  }

                  Text {
                    text: "\uf021"
                    font.family: window.fontFamily
                    font.pixelSize: 12
                    color: syncMouse.containsMouse ? window.fgMain : window.fgMuted
                    MouseArea {
                      id: syncMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: client.refresh()
                    }
                  }
                }
              }
            }

            // Full-width Thin Search Box (Matching Spotify Omarchy Search Input)
            Rectangle {
              Layout.fillWidth: true
              height: 38
              color: window.bgBase

              Rectangle {
                anchors.fill: parent
                anchors.margins: 6
                color: window.bgSurface
                border.color: searchInput.activeFocus ? window.borderActive : window.borderColor
                border.width: 1

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  spacing: 8

                  Text {
                    text: "\uf002"
                    font.family: window.fontFamily
                    font.pixelSize: 12
                    color: window.fgMuted
                  }

                  TextField {
                    id: searchInput
                    Layout.fillWidth: true
                    placeholderText: "Search WhatsApp..."
                    placeholderTextColor: window.fgDim
                    color: window.fgMain
                    font.family: window.fontFamily
                    font.pixelSize: 12
                    background: null
                    onTextChanged: window.searchFilter = text.toLowerCase().trim()
                  }
                }
              }
            }

            // Split View: Chat List Selector Column + Active Chat Conversation
            RowLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: 0

              // Chat Selector Column (Width: 290px)
              Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 290
                color: window.bgBase

                Rectangle {
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.right: parent.right
                  width: 1
                  color: window.borderColor
                }

                ListView {
                  id: mainChatList
                  anchors.fill: parent
                  anchors.margins: 4
                  clip: true
                  spacing: 2
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  model: {
                    var list = client.chats || []
                    var filter = window.searchFilter
                    var mode = window.navMode

                    if (mode === "unread") {
                      var unreadRes = []
                      for (var u = 0; u < list.length; u++) {
                        if (list[u] && list[u].unread > 0) unreadRes.push(list[u])
                      }
                      list = unreadRes
                    } else if (mode === "favorites") {
                      var favRes = []
                      for (var f = 0; f < list.length; f++) {
                        if (list[f] && window.isFavorite(list[f].jid)) favRes.push(list[f])
                      }
                      list = favRes
                    }

                    if (!filter) return list
                    var filtered = []
                    for (var j = 0; j < list.length; j++) {
                      var c = list[j]
                      if (!c) continue
                      var title = Model.chatTitle(c).toLowerCase()
                      var msg = String(c.lastText || "").toLowerCase()
                      if (title.indexOf(filter) !== -1 || msg.indexOf(filter) !== -1) {
                        filtered.push(c)
                      }
                    }
                    return filtered
                  }

                  delegate: Rectangle {
                    required property var modelData
                    width: mainChatList.width - 8
                    height: 50
                    color: modelData.jid === window.activeJid ? window.bgSelected : (chatRowMouse.containsMouse ? window.bgHover : "transparent")
                    border.color: modelData.jid === window.activeJid ? window.borderActive : window.borderColor
                    border.width: 1

                    MouseArea {
                      id: chatRowMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: window.selectChat(modelData.jid)
                    }

                    ColumnLayout {
                      anchors.fill: parent
                      anchors.margins: 8
                      spacing: 2

                      RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Text {
                          visible: window.isFavorite(modelData.jid)
                          text: "\uf005"
                          font.family: window.fontFamily
                          font.pixelSize: 11
                          color: window.borderActive
                        }

                        Text {
                          text: Model.chatTitle(modelData)
                          font.family: window.fontFamily
                          font.pixelSize: 13
                          font.bold: modelData.unread > 0
                          color: window.fgMain
                          elide: Text.ElideRight
                          Layout.fillWidth: true
                        }

                        Text {
                          text: Model.chatTimestamp(modelData.lastTs)
                          font.family: window.fontFamily
                          font.pixelSize: 11
                          color: window.fgMuted
                        }
                      }

                      RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Text {
                          text: String(modelData.lastText || "").replace(/[\r\n]+/g, " ")
                          font.family: window.fontFamily
                          font.pixelSize: 11
                          color: window.fgMuted
                          elide: Text.ElideRight
                          Layout.fillWidth: true
                        }

                        Rectangle {
                          visible: modelData.unread > 0
                          width: unreadCountTxt.implicitWidth + 8
                          height: 16
                          color: window.bgOverlay
                          border.color: window.borderActive
                          border.width: 1

                          Text {
                            id: unreadCountTxt
                            anchors.centerIn: parent
                            text: modelData.unread
                            font.family: window.fontFamily
                            font.pixelSize: 10
                            color: window.fgMain
                          }
                        }
                      }
                    }
                  }
                }
              }

              // Active Chat Conversation Pane
              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: window.bgBase

                ColumnLayout {
                  anchors.fill: parent
                  spacing: 0

                  // Empty State Placeholder
                  Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !window.activeJid

                    Text {
                      anchors.centerIn: parent
                      text: window.navMode === "favorites" ? "No favorite chats yet. Click the star icon to favorite a chat." : "Select a conversation from the list to view messages"
                      font.family: window.fontFamily
                      font.pixelSize: 12
                      color: window.fgDim
                    }
                  }

                  // Message List View
                  ListView {
                    id: messageList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 10
                    Layout.bottomMargin: 10
                    visible: !!window.activeJid
                    clip: true
                    spacing: 8
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    model: window.messages

                    header: Item {
                      width: messageList.width
                      height: (window.messages.length >= window.loadedMessageLimit && window.messages.length > 0) ? 32 : 0
                      visible: window.messages.length >= window.loadedMessageLimit && window.messages.length > 0

                      Rectangle {
                        anchors.centerIn: parent
                        width: 180
                        height: 22
                        color: window.bgSurface
                        border.color: window.borderColor
                        border.width: 1

                        Text {
                          anchors.centerIn: parent
                          text: "▲ Load older messages"
                          color: window.fgMuted
                          font.family: window.fontFamily
                          font.pixelSize: 11
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: window.loadMoreMessages()
                        }
                      }
                    }

                    delegate: Column {
                      id: msgRow
                      required property var modelData
                      required property int index

                      width: messageList.width
                      spacing: 4

                      readonly property var previous: msgRow.index > 0 ? window.messages[msgRow.index - 1] : null
                      readonly property bool showDay: !msgRow.previous || !Model.sameDay(msgRow.previous.ts, msgRow.modelData.ts)
                      readonly property bool isMe: !!msgRow.modelData.fromMe

                      // Day Divider Line
                      RowLayout {
                        width: parent.width
                        visible: msgRow.showDay
                        spacing: 10

                        Rectangle { Layout.fillWidth: true; height: 1; color: window.borderColor }
                        Text {
                          text: Model.dayLabel(msgRow.modelData.ts)
                          color: window.fgDim
                          font.family: window.fontFamily
                          font.pixelSize: 11
                        }
                        Rectangle { Layout.fillWidth: true; height: 1; color: window.borderColor }
                      }

                      // Omarchy Monochromatic Message Bubble Row
                      RowLayout {
                        width: parent.width
                        layoutDirection: msgRow.isMe ? Qt.RightToLeft : Qt.LeftToRight

                        Rectangle {
                          id: bubbleBox
                          Layout.maximumWidth: messageList.width * 0.72
                          implicitWidth: bubbleCol.implicitWidth + 20
                          implicitHeight: bubbleCol.implicitHeight + 14
                          radius: Commons.Style.cornerRadius > 0 ? Commons.Style.cornerRadius : 6
                          color: msgRow.isMe
                            ? Commons.Style.selectedFillFor(Commons.Color.foreground, Commons.Color.urgent || Commons.Color.accent)
                            : Commons.Style.normalFillFor(Commons.Color.foreground, Commons.Color.accent)

                          MouseArea {
                            id: bubbleMouse
                            anchors.fill: parent
                            hoverEnabled: true
                          }

                          // 3-Dots Action Menu Button (Appears on Hover)
                          Rectangle {
                            id: dotsBtn
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.topMargin: 4
                            anchors.rightMargin: 4
                            width: 20
                            height: 20
                            color: dotsMouse.containsMouse || menuPopup.opened ? window.bgSelected : "transparent"
                            radius: 3
                            visible: bubbleMouse.containsMouse || dotsMouse.containsMouse || menuPopup.opened
                            z: 10

                            Text {
                              anchors.centerIn: parent
                              text: "\uf142" // FontAwesome vertical ellipsis (⋮)
                              font.family: window.fontFamily
                              font.pixelSize: 11
                              color: dotsMouse.containsMouse || menuPopup.opened ? window.fgMain : window.fgMuted
                            }

                            MouseArea {
                              id: dotsMouse
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              onClicked: menuPopup.opened ? menuPopup.close() : menuPopup.open()
                            }

                            Popup {
                              id: menuPopup
                              y: parent.height + 2
                              x: parent.width - width
                              width: 110
                              padding: 4
                              closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

                              background: Rectangle {
                                color: window.bgSurface
                                border.color: window.borderActive
                                border.width: 1
                                radius: 4
                              }

                              contentItem: ColumnLayout {
                                spacing: 2

                                // Option 1: Reply
                                Rectangle {
                                  Layout.fillWidth: true
                                  height: 24
                                  color: replyItemMouse.containsMouse ? window.bgHover : "transparent"
                                  radius: 3

                                  RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    spacing: 6

                                    Text {
                                      text: "\uf112"
                                      font.family: window.fontFamily
                                      font.pixelSize: 11
                                      color: window.fgMain
                                    }

                                    Text {
                                      text: "Yanıtla"
                                      font.family: window.fontFamily
                                      font.pixelSize: 11
                                      color: window.fgMain
                                    }
                                  }

                                  MouseArea {
                                    id: replyItemMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                      menuPopup.close()
                                      window.replyingToMessage = msgRow.modelData
                                      composer.forceActiveFocus()
                                    }
                                  }
                                }

                                // Option 2: Delete (if sent by me)
                                Rectangle {
                                  visible: msgRow.isMe
                                  Layout.fillWidth: true
                                  height: 24
                                  color: deleteItemMouse.containsMouse ? window.bgHover : "transparent"
                                  radius: 3

                                  RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    spacing: 6

                                    Text {
                                      text: "\uf1f8"
                                      font.family: window.fontFamily
                                      font.pixelSize: 11
                                      color: window.urgentColor
                                    }

                                    Text {
                                      text: "Sil"
                                      font.family: window.fontFamily
                                      font.pixelSize: 11
                                      color: window.urgentColor
                                    }
                                  }

                                  MouseArea {
                                    id: deleteItemMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                      menuPopup.close()
                                      client.deleteMessage(window.activeJid, msgRow.modelData.id)
                                    }
                                  }
                                }
                              }
                            }
                          }

                          ColumnLayout {
                            id: bubbleCol
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4

                            // Sender Name for Groups
                            Text {
                              visible: !msgRow.isMe && window.activeChat && window.activeChat.isGroup && msgRow.modelData.senderName
                              text: msgRow.modelData.senderName || ""
                              color: Commons.Color.urgent || Commons.Color.accent
                              font.family: window.fontFamily
                              font.pixelSize: 11
                              font.bold: true
                            }

                            // Quoted Message Snippet Box
                            Rectangle {
                              visible: !!(msgRow.modelData && msgRow.modelData.quotedText)
                              Layout.fillWidth: true
                              implicitHeight: quotedCol.implicitHeight + 8
                              color: window.bgBase
                              border.color: window.borderColor
                              border.width: 1

                              RowLayout {
                                anchors.fill: parent
                                anchors.margins: 4
                                spacing: 6

                                Rectangle { width: 2; Layout.fillHeight: true; color: window.borderActive }

                                ColumnLayout {
                                  id: quotedCol
                                  Layout.fillWidth: true
                                  spacing: 2

                                  Text {
                                    text: msgRow.modelData.quotedSender || "Quoted message"
                                    color: window.borderActive
                                    font.family: window.fontFamily
                                    font.pixelSize: 10
                                    font.bold: true
                                  }

                                  Text {
                                    text: msgRow.modelData.quotedText || ""
                                    color: window.fgMuted
                                    font.family: window.fontFamily
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                  }
                                }
                              }
                            }

                            // Image Attachment Preview
                            Rectangle {
                              visible: !!msgRow.modelData.imagePath
                              width: Math.min(240, messageList.width * 0.6)
                              height: 160
                              color: window.bgBase
                              border.color: window.borderColor
                              border.width: 1
                              clip: true

                              Image {
                                anchors.fill: parent
                                source: msgRow.modelData.imagePath ? ("file://" + msgRow.modelData.imagePath) : ""
                                fillMode: Image.PreserveAspectCrop
                              }

                              MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: window.peekImagePath = msgRow.modelData.imagePath
                              }
                            }

                            // Body Text
                            Text {
                              Layout.fillWidth: true
                              text: msgRow.modelData.text || ""
                              color: window.fgMain
                              font.family: window.fontFamily
                              font.pixelSize: 12
                              wrapMode: Text.Wrap
                            }

                            // Timestamp & Status
                            RowLayout {
                              Layout.alignment: Qt.AlignRight
                              spacing: 4

                              Text {
                                text: Model.messageTimestamp(msgRow.modelData.ts)
                                color: window.fgMuted
                                font.family: window.fontFamily
                                font.pixelSize: 10
                              }

                              Text {
                                visible: msgRow.isMe
                                text: Model.statusGlyph(msgRow.modelData.status)
                                color: (msgRow.modelData && typeof msgRow.modelData.status === "number" && msgRow.modelData.status >= 3) ? window.accentColor : window.fgMuted
                                font.family: window.fontFamily
                                font.pixelSize: 10
                              }
                            }
                          }
                        }
                      }
                    }
                  }

                  // Omarchy Bordered Input Box (Composer with Quoted Reply Banner)
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    visible: !!window.activeJid

                    // Quoted Reply Preview Banner above Composer
                    Rectangle {
                      Layout.fillWidth: true
                      height: window.replyingToMessage ? 42 : 0
                      visible: !!window.replyingToMessage
                      color: window.bgSidebar
                      border.color: window.borderColor
                      border.width: 1

                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 8

                        Rectangle { width: 3; Layout.fillHeight: true; color: window.borderActive }

                        ColumnLayout {
                          Layout.fillWidth: true
                          spacing: 1

                          Text {
                            text: window.replyingToMessage ? (window.replyingToMessage.senderName || (window.replyingToMessage.fromMe ? "You" : "Sender")) : ""
                            font.family: window.fontFamily
                            font.pixelSize: 10
                            font.bold: true
                            color: window.borderActive
                          }

                          Text {
                            text: window.replyingToMessage ? (window.replyingToMessage.text || "") : ""
                            font.family: window.fontFamily
                            font.pixelSize: 11
                            color: window.fgMuted
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                          }
                        }

                        Text {
                          text: "✕"
                          font.family: window.fontFamily
                          font.pixelSize: 12
                          color: cancelReplyMouse.containsMouse ? window.fgMain : window.fgDim

                          MouseArea {
                            id: cancelReplyMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: window.replyingToMessage = null
                          }
                        }
                      }
                    }

                    // Main Text Composer Field
                    Rectangle {
                      Layout.fillWidth: true
                      height: 48
                      color: window.bgSurface

                      Rectangle {
                        anchors.top: parent.top
                        width: parent.width
                        height: 1
                        color: window.borderColor
                      }

                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 8

                        Rectangle {
                          Layout.fillWidth: true
                          height: 32
                          color: window.bgBase
                          border.color: composer.activeFocus ? window.borderActive : window.borderColor
                          border.width: 1

                          TextField {
                            id: composer
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            placeholderText: window.replyingToMessage ? "Type a reply..." : "Type a message..."
                            placeholderTextColor: window.fgDim
                            color: window.fgMain
                            font.family: window.fontFamily
                            font.pixelSize: 12
                            background: null
                            onAccepted: window.sendReply()
                          }
                        }

                        Rectangle {
                          width: 54
                          height: 32
                          color: sendMouse.containsMouse ? window.bgHover : window.bgSurface
                          border.color: window.borderActive
                          border.width: 1

                          Text {
                            anchors.centerIn: parent
                            text: "Send"
                            font.family: window.fontFamily
                            font.pixelSize: 11
                            color: window.fgMain
                          }

                          MouseArea {
                            id: sendMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: window.sendReply()
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      // Omarchy Full Image Peek Modal Overlay
      Rectangle {
        anchors.fill: parent
        visible: window.peekImagePath.length > 0
        color: Qt.rgba(0, 0, 0, 0.9)

        MouseArea {
          anchors.fill: parent
          onClicked: window.peekImagePath = ""
        }

        Rectangle {
          anchors.centerIn: parent
          width: imgPreview.width + 4
          height: imgPreview.height + 4
          color: window.bgSurface
          border.color: window.borderActive
          border.width: 1

          Image {
            id: imgPreview
            anchors.centerIn: parent
            width: Math.min(window.width * 0.85, implicitWidth)
            height: Math.min(window.height * 0.85, implicitHeight)
            source: window.peekImagePath.length > 0 ? ("file://" + window.peekImagePath) : ""
            fillMode: Image.PreserveAspectFit
          }
        }
      }
    }
  }
}
