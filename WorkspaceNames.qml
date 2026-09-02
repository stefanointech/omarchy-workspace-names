import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Workspace-Namen-Overlay.
//
// Zwei Flächen in einem Plugin:
//   * das HUD -- oben links unter der Bar, klick-durchlässig. Es erscheint
//     beim tatsächlichen Workspace-Wechsel (nicht schon beim Druck auf
//     SUPER) und schiebt dabei die Nummern auseinander, bis die Namen
//     dazwischen passen.
//   * der Umbenennen-Dialog -- nimmt Tastaturfokus, schreibt über das CLI.
//
// Die Namen liegen in ~/.config/omarchy/workspace-names.json und werden von
// der FileView unten gelesen und geschrieben. Ohne eigenen Namen zeigt ein
// Eintrag die offenen Apps des Workspaces.
Item {
  id: root

  readonly property string namesPath: Quickshell.env("HOME") + "/.config/omarchy/workspace-names.json"

  property var names: ({})
  property var rows: []
  property bool hasSub: false

  property bool hudOpen: false
  property bool renameOpen: false
  property int renameId: 1

  // Panel-Vertrag der Shell: `opened`, `open(payload)`, `close()`.
  readonly property bool opened: hudOpen || renameOpen

  // Nachlauf, wenn Hyprland das Loslassen von SUPER als Binding meldet.
  property int lingerMs: 900
  // Das Loslassen kommt nicht auf jedem Setup an, deshalb blendet sich das
  // HUD auch von allein aus; kommt das Release doch, gewinnt lingerMs.
  property int autoHideMs: 2200

  // 0 = Nummern liegen aneinander, 1 = Namen voll ausgefahren.
  property real spread: 0

  // ------------------------------------------------------------- Metrik
  readonly property int padH: Style.space(12)
  readonly property int padV: Style.space(9)
  readonly property int badgeWidth: Style.space(24)
  readonly property int badgeHeight: Style.space(22)
  readonly property int badgeGap: Style.space(7)
  readonly property int itemGap: Style.space(14)
  readonly property int subGap: Style.space(2)
  readonly property int maxLabelWidth: Style.space(170)

  readonly property int subLineHeight: root.hasSub ? Math.ceil(subLineMetrics.boundingRect.height) : 0
  readonly property int contentHeight: badgeHeight + (root.hasSub ? subGap + subLineHeight : 0)

  readonly property color cardColor: Util.alpha(Color.background, 0.97)
  readonly property color textColor: Color.popups.text
  readonly property color dimColor: Util.alpha(Color.popups.text, 0.55)

  readonly property var targetScreen: {
    var mon = Hyprland.focusedMonitor
    if (!mon) return null
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++)
      if (list[i].name === mon.name) return list[i]
    return null
  }

  // ------------------------------------------------------------- Daten
  function applyNames(raw) {
    var next = {}
    try {
      var parsed = JSON.parse(raw || "{}")
      for (var k in parsed) {
        var v = String(parsed[k] || "").trim()
        if (v.length > 0) next[String(parseInt(k, 10))] = v
      }
    } catch (e) {}
    root.names = next
    if (root.opened) root.refresh()
  }

  function nameFor(id) {
    var v = root.names[String(id)]
    return (typeof v === "string") ? v : ""
  }

  function titleCase(value) {
    var words = String(value || "").replace(/[_-]+/g, " ").split(" ")
    var out = []
    for (var i = 0; i < words.length; i++) {
      if (words[i].length === 0) continue
      out.push(words[i].charAt(0).toUpperCase() + words[i].slice(1))
    }
    return out.join(" ")
  }

  // "org.gnome.Nautilus" -> "Nautilus", "zen" -> "Zen", und die Chromium-
  // Webapps, die Omarchy als "chrome-open.spotify.com__-Default" anlegt,
  // auf ihre Domain herunter: "Spotify".
  function appLabel(appId) {
    var s = String(appId || "").trim()
    if (s.length === 0) return ""

    var web = s.match(/^(?:chrome|chromium|brave|msedge|vivaldi)-(.+?)(?:__.*)?$/)
    if (web) {
      var host = web[1].replace(/^www\./, "")
      var labels = host.split(".")
      return root.titleCase(labels.length >= 2 ? labels[labels.length - 2] : labels[0])
    }

    var parts = s.split(".")
    var last = parts[parts.length - 1]
    if (last.length < 2 && parts.length > 1) last = parts[parts.length - 2]
    return root.titleCase(last)
  }

  function appsFor(workspace) {
    if (!workspace || !workspace.toplevels) return ""
    var tops = workspace.toplevels.values
    var order = []
    var counts = {}
    for (var i = 0; i < tops.length; i++) {
      var t = tops[i]
      var id = ""
      if (t.wayland && t.wayland.appId) id = t.wayland.appId
      else if (t.lastIpcObject) id = t.lastIpcObject["class"] || t.lastIpcObject["initialClass"] || ""
      var label = root.appLabel(id)
      if (label.length === 0) continue
      if (counts[label] === undefined) { counts[label] = 0; order.push(label) }
      counts[label]++
    }
    var out = []
    for (var j = 0; j < order.length; j++) {
      var l = order[j]
      out.push(counts[l] > 1 ? l + " ×" + counts[l] : l)
    }
    return out.join(" · ")
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++)
      if (values[i].id === id) return values[i]
    return null
  }

  // 1-5 immer, dazu alles Belegte und alles Benannte bis 10 -- die gleiche
  // Menge, die auch das Bar-Widget zeigt, plus die benannten Workspaces.
  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }
    for (var k in root.names) {
      var n = parseInt(k, 10)
      if (n >= 1 && n <= 10 && ids.indexOf(n) === -1) ids.push(n)
    }
    ids.sort(function(a, b) { return a - b })
    return ids
  }

  function refresh() {
    var ids = root.workspaceIds()
    var focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    var built = []
    var anySub = false

    for (var i = 0; i < ids.length; i++) {
      var id = ids[i]
      var ws = root.workspaceById(id)
      var apps = root.appsFor(ws)
      var custom = root.nameFor(id)
      var label = custom.length > 0 ? custom : (apps.length > 0 ? apps : "—")
      var sub = custom.length > 0 ? apps : ""
      if (sub.length > 0) anySub = true

      labelMetrics.text = label
      subMetrics.text = sub
      var textWidth = Math.min(
        Math.ceil(Math.max(labelMetrics.advanceWidth, subMetrics.advanceWidth)) + 2,
        root.maxLabelWidth)

      built.push({
        id: id,
        label: label,
        sub: sub,
        named: custom.length > 0,
        occupied: apps.length > 0,
        focused: id === focusedId,
        textWidth: textWidth
      })
    }

    root.hasSub = anySub
    root.rows = built
  }

  // Breite bei aktuellem Spread: die Nummern stehen bei 0 aneinander und
  // schieben sich auseinander, während die Namen dazwischen aufgehen.
  readonly property int contentWidth: {
    var total = 0
    for (var i = 0; i < rows.length; i++)
      total += badgeWidth + Math.round((badgeGap + rows[i].textWidth) * spread)
    if (rows.length > 1) total += Math.round(itemGap * spread) * (rows.length - 1)
    return total
  }

  // ------------------------------------------------------------- Steuerung
  function showHud() {
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    root.refresh()
    lingerTimer.stop()

    if (!root.hudOpen) {
      root.spread = 0
      root.hudOpen = true
      spreadAnim.restart()
    }

    autoHideTimer.restart()
    // Hyprlands Zustand hinkt dem Event einen Wimpernschlag hinterher.
    refreshTimer.restart()
  }

  function hideHudSoon() { if (root.hudOpen) lingerTimer.restart() }

  function hideHud() {
    lingerTimer.stop()
    autoHideTimer.stop()
    root.hudOpen = false
  }

  function startRename(id) {
    var target = parseInt(id, 10)
    if (!(target >= 1 && target <= 10))
      target = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
    root.hideHud()
    root.renameId = target
    nameField.text = root.nameFor(target)
    root.renameOpen = true
    Qt.callLater(function() { nameField.forceActiveFocus(); nameField.selectAll() })
  }

  function commitRename() {
    var value = String(nameField.text || "").trim()
    var id = root.renameId

    var next = {}
    for (var k in root.names) next[k] = root.names[k]
    if (value.length > 0) next[String(id)] = value
    else delete next[String(id)]

    // Sofort spiegeln, damit das HUD nicht auf den Datei-Watcher wartet, und
    // dann selbst schreiben -- das Plugin soll ohne Fremdskript auskommen.
    // Ganzzahlige Schlüssel zählt JavaScript beim Iterieren aufsteigend
    // durch, die Datei bleibt also von allein nach Workspace sortiert.
    root.names = next
    namesFile.setText(JSON.stringify(next, null, 2) + "\n")

    root.renameOpen = false
  }

  function cancelRename() { root.renameOpen = false }

  // Shell-Vertrag
  function open(payloadJson) {
    var p = {}
    try { p = JSON.parse(payloadJson || "{}") } catch (e) {}
    if (p.rename !== undefined) root.startRename(p.rename)
    else root.showHud()
  }

  function close() {
    root.hideHud()
    root.renameOpen = false
  }

  NumberAnimation {
    id: spreadAnim
    target: root
    property: "spread"
    from: 0
    to: 1
    duration: 190
    easing.type: Easing.OutCubic
  }

  Timer {
    id: lingerTimer
    interval: root.lingerMs
    onTriggered: root.hideHud()
  }

  Timer {
    id: autoHideTimer
    interval: root.autoHideMs
    onTriggered: root.hideHud()
  }

  // Auslöser ist der Wechsel selbst, nicht die SUPER-Taste: so kommt das HUD
  // erst, wenn tatsächlich umgeschaltet wurde -- egal ob per SUPER + Zahl,
  // SUPER + TAB, Mausrad oder Klick in die Bar.
  //
  // Quickshell verarbeitet Hyprlands `workspace`-Ereignisse intern und reicht
  // sie nicht als rawEvent durch, deshalb hängt der Auslöser am Wechsel von
  // `focusedWorkspace`. Der allererste Wert nach dem Shell-Start ist kein
  // Wechsel und darf nichts einblenden.
  property int lastWorkspaceId: -1

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() {
      var ws = Hyprland.focusedWorkspace
      var id = ws ? ws.id : -1
      if (id === root.lastWorkspaceId) return
      var hadPrevious = root.lastWorkspaceId !== -1
      root.lastWorkspaceId = id
      if (hadPrevious && id > 0) root.showHud()
    }

    // Alles andere -- neue Fenster, geschlossene Fenster -- nur nachzeichnen,
    // solange das HUD ohnehin steht.
    function onRawEvent(event) {
      if (root.hudOpen) refreshTimer.restart()
    }
  }

  Timer {
    id: refreshTimer
    interval: 40
    onTriggered: if (root.hudOpen) root.refresh()
  }

  TextMetrics {
    id: labelMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.bold: true
  }

  TextMetrics {
    id: subMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  TextMetrics {
    id: subLineMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    text: "Xg"
  }

  FileView {
    id: namesFile
    path: root.namesPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyNames(text())
    onFileChanged: reload()
    onLoadFailed: root.applyNames("{}")
  }

  IpcHandler {
    target: "workspace-names"
    function show(): string { root.showHud(); return "ok" }
    function hide(): string { root.hideHudSoon(); return "ok" }
    function hideNow(): string { root.hideHud(); return "ok" }
    function toggle(): string { root.hudOpen ? root.hideHud() : root.showHud(); return "ok" }
    function rename(id: string): string { root.startRename(id); return "ok" }
    function state(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  // ------------------------------------------------------------- HUD
  PanelWindow {
    id: hud
    visible: root.hudOpen
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-workspace-names"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Reine Anzeigefläche: leere Input-Region, damit nichts geblockt wird.
    mask: Region {}

    BorderSurface {
      id: card
      // Bündig unter der Bar, linksbündig zu deren Innenrand.
      x: Style.space(8)
      y: Style.bar.sizeHorizontal + Style.space(6)
      width: card.borderLeft + root.padH + root.contentWidth + root.padH + card.borderRight
      height: card.borderTop + root.padV + root.contentHeight + root.padV + card.borderBottom
      color: root.cardColor
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.hudOpen ? 1 : 0

      Behavior on opacity { NumberAnimation { duration: 90 } }

      Row {
        id: strip
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: card.borderLeft + root.padH
        anchors.topMargin: card.borderTop + root.padV
        height: root.contentHeight
        spacing: Math.round(root.itemGap * root.spread)

        Repeater {
          model: root.rows

          Item {
            required property var modelData

            readonly property int textSlot: Math.round((root.badgeGap + modelData.textWidth) * root.spread)

            width: root.badgeWidth + textSlot
            height: root.contentHeight
            clip: true
            opacity: modelData.focused ? 1 : (modelData.occupied || modelData.named ? 0.85 : 0.4)

            Rectangle {
              id: badge
              width: root.badgeWidth
              height: root.badgeHeight
              radius: Style.cornerRadius
              color: modelData.focused ? Color.accent : Util.alpha(root.textColor, 0.1)

              Text {
                anchors.centerIn: parent
                text: modelData.id === 10 ? "0" : String(modelData.id)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                color: modelData.focused ? Color.background : root.textColor
              }
            }

            Text {
              id: label
              x: root.badgeWidth + root.badgeGap
              y: Math.round((root.badgeHeight - height) / 2)
              width: modelData.textWidth
              opacity: root.spread
              text: modelData.label
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: modelData.named
              color: modelData.named ? root.textColor : Util.alpha(root.textColor, 0.8)
              elide: Text.ElideRight
              maximumLineCount: 1
            }

            Text {
              visible: root.hasSub && modelData.sub !== ""
              x: label.x
              y: root.badgeHeight + root.subGap
              width: modelData.textWidth
              opacity: root.spread
              text: modelData.sub
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.dimColor
              elide: Text.ElideRight
              maximumLineCount: 1
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------- Umbenennen
  PanelWindow {
    id: renamer
    visible: root.renameOpen
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-workspace-rename"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.35)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancelRename()
    }

    BorderSurface {
      id: dialog
      width: Style.space(420)
      height: dialog.borderTop + Style.space(18) + heading.height + Style.space(10)
              + nameField.height + Style.space(18) + dialog.borderBottom
      anchors.centerIn: parent
      color: root.cardColor
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Text {
        id: heading
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: dialog.borderTop + Style.space(18)
        anchors.leftMargin: dialog.borderLeft + Style.space(18)
        anchors.rightMargin: dialog.borderRight + Style.space(18)
        text: "Name für Workspace " + root.renameId
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        color: root.textColor
      }

      TextField {
        id: nameField
        anchors.top: heading.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Style.space(10)
        anchors.leftMargin: dialog.borderLeft + Style.space(18)
        anchors.rightMargin: dialog.borderRight + Style.space(18)
        placeholderText: "leer lassen = offene Apps zeigen"

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelRename()
            event.accepted = true
          }
        }

        onAccepted: root.commitRename()
      }
    }
  }
}
