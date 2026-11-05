import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// The Petal menu: everything that used to be terminal-only, as one calm
// panel. Opened from Petal's indicator in Omarchy's bar, from Omarchy's menu
// (Petal), from a mode's right-click menu ("Show held…") and with
// `omarchy-shell petal panel [page]`. Pages: home, held[:<mode>], schedule,
// summary, doctor, recipes.
PanelWindow {
  id: panel

  property var dock: null
  property bool open: false
  property string page: ""
  readonly property string pageName: page.split(":")[0]
  readonly property string pageArg: page.indexOf(":") >= 0 ? page.slice(page.indexOf(":") + 1) : ""
  readonly property var settings: dock ? dock.settings : null
  readonly property var activity: dock ? dock.activity : null
  readonly property string uiFont: dock ? dock.uiFont : "Adwaita Sans"
  readonly property string glyphFont: "JetBrainsMono Nerd Font"
  readonly property color ink: Commons.Color.popups.text
  readonly property color soft: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
  readonly property color accent: dock ? dock.accent : Commons.Color.accent
  readonly property string aiName: dock ? dock.chatName : "Claude"
  readonly property bool hasAi: !!dock && dock.chatProvider !== ""
  readonly property real s: Style.fontScale

  visible: open
  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock-search"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }

  onOpenChanged: {
    if (open) panel.enter()
    else panel.page = ""
  }
  onPageChanged: if (open) panel.enter()

  HyprlandFocusGrab {
    active: panel.open
    windows: [panel]
    onCleared: panel.open = false
  }

  function go(name) {
    panel.page = name
  }

  function back() {
    panel.page = ""
  }

  // Each page loads what it shows as it opens.
  function enter() {
    keys.forceActiveFocus()
    if (panel.pageName === "summary") panel.loadSummary()
    else if (panel.pageName === "doctor") panel.runDoctor(false)
    else if (panel.pageName === "recipes") {
      panel.plan = null
      panel.savedPath = ""
      panel.recipeResult = ""
      panel.recipeError = ""
      panel.findRecipes()
    }
  }

  function ago(at) {
    var mins = Math.max(0, Math.round((Date.now() - Number(at || 0)) / 60000))
    if (mins < 1) return "now"
    if (mins < 60) return mins + " min ago"
    if (mins < 24 * 60) return Math.round(mins / 60) + " h ago"
    return Math.round(mins / 1440) + " d ago"
  }

  function duration(minutes) {
    if (minutes < 60) return minutes + " min"
    var h = minutes / 60
    return (h >= 10 ? Math.round(h) : Math.round(h * 10) / 10) + " h"
  }

  // ── Summary ───────────────────────────────────────────────────────────
  property var summaryData: null
  property bool summaryLoading: false

  function loadSummary() {
    panel.summaryLoading = true
    panel.activity.tool("petal_summary", {}, function(r) {
      panel.summaryLoading = false
      panel.summaryData = r && !r.error ? r : null
    })
  }

  // ── Doctor and report ─────────────────────────────────────────────────
  property var findings: []
  property bool doctorRunning: false
  property bool reporting: false
  property string reportPreview: ""
  property string reportResult: ""
  property bool reportBusy: false

  function runDoctor(fix) {
    if (panel.doctorRunning) return
    panel.doctorRunning = true
    panel.activity.run([panel.activity.petalBin, "doctor", "--json"].concat(fix ? ["--fix"] : []), function(text) {
      panel.doctorRunning = false
      try {
        var start = String(text).indexOf("{")
        panel.findings = JSON.parse(String(text).slice(start)).findings || []
      } catch (e) {
        panel.findings = [{ level: "error", area: "doctor", text: "The doctor didn't answer. Is `petal` installed (~/.local/bin/petal)?" }]
      }
    })
  }

  readonly property bool anyProblem: findings.some(function(f) { return f.level !== "ok" && !f.fixed })

  function previewReport() {
    var what = reportField.text.trim()
    if (!what || panel.reportBusy) return
    panel.reportBusy = true
    panel.reportResult = ""
    panel.activity.run([panel.activity.petalBin, "report", what], function(text) {
      panel.reportBusy = false
      panel.reportPreview = String(text).replace(/\n*Run again with --yes to file it\.\s*$/, "").trim()
    })
  }

  function sendReport() {
    var what = reportField.text.trim()
    if (!what || panel.reportBusy) return
    panel.reportBusy = true
    panel.activity.run([panel.activity.petalBin, "report", what, "--yes"], function(text) {
      panel.reportBusy = false
      var lines = String(text).trim().split("\n")
      panel.reportResult = lines[lines.length - 1] || "Sent."
      panel.reportPreview = ""
    })
  }

  // ── Recipes ───────────────────────────────────────────────────────────
  property var recipeFiles: []
  property string savedPath: ""
  property string recipePath: ""
  property var plan: null
  property bool useLook: false
  property string recipeResult: ""
  property string recipeError: ""

  function findRecipes() {
    panel.activity.run(["bash", "-c", "find \"$HOME\" \"$HOME/Downloads\" \"$HOME/Desktop\" \"$HOME/Documents\" -maxdepth 1 -name '*.petal' -type f 2>/dev/null | head -n 12"], function(text) {
      panel.recipeFiles = String(text).split("\n").filter(function(l) { return l.trim() !== "" })
    })
  }

  function saveRecipe() {
    var name = nameField.text.trim() || "My Petal"
    panel.activity.tool("petal_export_recipe", { name: name }, function(r) {
      if (r && r.path) {
        panel.savedPath = r.path
        panel.findRecipes()
      } else panel.recipeError = r && r.error ? r.error : "Couldn't save it."
    })
  }

  function previewRecipe(path) {
    panel.recipePath = path
    panel.recipeResult = ""
    panel.recipeError = ""
    panel.activity.tool("petal_import_recipe", { path: path, look: panel.useLook, preview: true }, function(r) {
      if (r && !r.error) panel.plan = r
      else {
        panel.plan = null
        panel.recipeError = r && r.error ? r.error : "Couldn't read it."
      }
    })
  }

  function addRecipe() {
    if (!panel.plan) return
    panel.activity.tool("petal_import_recipe", { path: panel.recipePath, look: panel.useLook }, function(r) {
      panel.plan = null
      if (r && r.modes) panel.recipeResult = r.modes.length ? "Added " + panel.dock.namesText(r.modes.map(function(m) { return m.name })) + "." : "Nothing to add."
      else panel.recipeError = r && r.error ? r.error : "Couldn't add it."
    })
  }

  function appName(id) {
    var entry = DesktopEntries.byId(id)
    return entry && entry.name ? entry.name : id
  }

  function baseName(path) {
    return String(path).split("/").pop()
  }

  MouseArea {
    anchors.fill: parent
    onClicked: panel.open = false
  }

  Item {
    id: keys
    focus: true
    Keys.onEscapePressed: {
      if (panel.pageName !== "") panel.back()
      else panel.open = false
    }
  }

  Rectangle {
    id: card

    readonly property int pad: Math.round(16 * panel.s)
    width: Math.round(420 * panel.s)
    height: Math.min(content.implicitHeight + pad * 2, panel.height - Math.round(80 * panel.s))
    x: Math.round((panel.width - width) / 2)
    y: Math.round((panel.height - height) / 2.6)
    radius: Math.round(20 * panel.s)
    color: panel.dock ? panel.dock.popupFill : Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g, Commons.Color.popups.background.b, 0.74)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.1)
    clip: true

    Behavior on height { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

    // Clicks on the card stay on the card.
    MouseArea { anchors.fill: parent }

    Flickable {
      anchors.fill: parent
      anchors.margins: card.pad
      contentHeight: content.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      clip: true

      Column {
        id: content
        width: parent.width
        spacing: Math.round(4 * panel.s)

        // ── Header ──
        Item {
          width: parent.width
          height: Math.round(32 * panel.s)

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Math.round(8 * panel.s)

            RoundButton {
              visible: panel.pageName !== ""
              anchors.verticalCenter: parent.verticalCenter
              glyph: "‹"
              onClicked: panel.back()
            }
            Image {
              visible: panel.pageName === ""
              anchors.verticalCenter: parent.verticalCenter
              width: Math.round(20 * panel.s)
              height: width
              sourceSize: Qt.size(width * 2, height * 2)
              source: Qt.resolvedUrl("assets/petal.svg")
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: ({ "": "Petal", held: "Held notifications", schedule: "Schedule", summary: "Last week", doctor: "Check Petal", recipes: "Share a dock" })[panel.pageName] || "Petal"
              color: panel.ink
              font.family: panel.uiFont
              font.pixelSize: Math.round(15 * panel.s)
              font.weight: Font.DemiBold
            }
          }

          RoundButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            glyph: "×"
            onClicked: panel.open = false
          }
        }

        // ── Home ──
        Column {
          visible: panel.pageName === ""
          width: parent.width

          // The mode of the workspace in front.
          Row {
            visible: !!panel.dock && !!panel.dock.focusedMode
            x: Math.round(10 * panel.s)
            height: Math.round(30 * panel.s)
            spacing: Math.round(8 * panel.s)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: panel.dock && panel.dock.focusedMode ? (panel.dock.focusedMode.icon || "●") : ""
              color: panel.dock ? panel.dock.modeColor(panel.dock.focusedMode) : panel.accent
              font.family: panel.glyphFont
              font.pixelSize: Math.round(15 * panel.s)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: panel.dock && panel.dock.focusedMode ? "This workspace is in " + panel.dock.focusedMode.name + "." : ""
              color: panel.ink
              font.family: panel.uiFont
              font.pixelSize: Math.round(13 * panel.s)
            }
          }

          Header { text: "Settings" }
          Toggle { text: "Focus cards"; key: "focusGuard" }
          Toggle { text: "Hold notifications"; key: "holdNotifications" }
          Toggle { text: "Countdown before leaving a mode"; key: "countdown" }
          Toggle { text: "Keyboard shortcuts"; detail: "Super+Ctrl+Alt + 1–9, Space, ="; key: "shortcuts" }
          Toggle {
            text: "Mode in the top bar"
            custom: true
            checked: !!panel.dock && panel.dock.inBar
            onTriggered: panel.dock.setInBar(!panel.dock.inBar)
          }
          Toggle { text: "Activity history"; detail: "Private, on this computer only"; key: "activityLog" }
          Toggle { text: "Suggest modes"; key: "suggestModes"; enabled: panel.settings ? panel.settings.activityLog : false }
          Toggle { text: "Weekly summary"; key: "summary"; enabled: panel.settings ? panel.settings.activityLog : false }
          Toggle { visible: panel.hasAi; text: "Sort with " + panel.aiName; key: "ai" }
          Toggle { text: "Install updates"; key: "autoUpdate" }
          Toggle { text: "Other AI sessions can change Petal"; key: "otherAgents" }

          Header { text: "More" }
          Link {
            text: "Held notifications"
            detail: panel.dock && panel.dock.heldTotal > 0 ? String(panel.dock.heldTotal) : "None"
            onTriggered: panel.go("held")
          }
          Link {
            text: "Schedule"
            detail: panel.activity && panel.activity.scheduleBlocks().length ? panel.activity.scheduleBlocks().length + (panel.activity.scheduleBlocks().length === 1 ? " block" : " blocks") : "Off"
            onTriggered: panel.go("schedule")
          }
          Link { text: "Last week"; onTriggered: panel.go("summary") }
          Link { text: "Share or add a dock"; onTriggered: panel.go("recipes") }
          Link { text: "Check Petal"; onTriggered: panel.go("doctor") }
          Link {
            visible: panel.hasAi
            text: "Build my modes with " + panel.aiName + "…"
            onTriggered: panel.dock.openDescribe()
          }
          Link {
            visible: panel.hasAi
            text: "Anything else? Ask " + panel.aiName + "…"
            onTriggered: panel.dock.openAsk("")
          }
        }

        // ── Held notifications ──
        Column {
          visible: panel.pageName === "held"
          width: parent.width
          spacing: Math.round(2 * panel.s)

          readonly property var items: panel.dock && panel.pageName === "held" ? panel.dock.heldList(panel.pageArg) : []

          Note {
            visible: parent.items.length === 0
            text: panel.pageArg ? "Nothing held for this mode." : "Nothing held. In a mode that holds notifications, the ones from other apps wait here."
          }

          Repeater {
            model: parent.items
            delegate: Rectangle {
              id: heldRow
              required property var modelData
              readonly property var n: modelData.n
              readonly property var mode: panel.dock ? panel.dock.modeById(modelData.mode) : null
              width: parent ? parent.width : 0
              height: heldColumn.implicitHeight + Math.round(14 * panel.s)
              radius: Math.round(10 * panel.s)
              color: heldMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent"

              MouseArea { id: heldMouse; anchors.fill: parent; hoverEnabled: true }

              Image {
                id: heldIcon
                x: Math.round(8 * panel.s)
                y: Math.round(8 * panel.s)
                width: Math.round(26 * panel.s)
                height: width
                sourceSize: Qt.size(width * 2, height * 2)
                source: panel.dock && heldRow.n.key ? panel.dock.iconFor({ key: heldRow.n.key }) : Quickshell.iconPath("dialog-information", true)
                asynchronous: true
              }

              Column {
                id: heldColumn
                anchors.left: heldIcon.right
                anchors.leftMargin: Math.round(10 * panel.s)
                anchors.right: heldButtons.left
                anchors.rightMargin: Math.round(8 * panel.s)
                y: Math.round(7 * panel.s)
                spacing: 1
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: String(heldRow.n.summary || "") + "  ·  " + String(heldRow.n.app || "")
                  color: panel.ink
                  font.family: panel.uiFont
                  font.pixelSize: Math.round(13 * panel.s)
                  font.weight: Font.DemiBold
                }
                Text {
                  width: parent.width
                  visible: text !== ""
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: String(heldRow.n.body || "")
                  color: panel.ink
                  opacity: 0.85
                  font.family: panel.uiFont
                  font.pixelSize: Math.round(12.5 * panel.s)
                }
                Text {
                  textFormat: Text.PlainText
                  text: panel.ago(heldRow.n.at) + (heldRow.mode ? " · held for " + heldRow.mode.name : "")
                  color: panel.soft
                  font.family: panel.uiFont
                  font.pixelSize: Math.round(11.5 * panel.s)
                }
              }

              Row {
                id: heldButtons
                anchors.right: parent.right
                anchors.rightMargin: Math.round(6 * panel.s)
                y: Math.round(6 * panel.s)
                spacing: Math.round(4 * panel.s)
                Pill {
                  visible: !!heldRow.n.key
                  text: "Open"
                  onClicked: {
                    panel.dock.openHeld(heldRow.modelData.mode, heldRow.n)
                    panel.open = false
                  }
                }
                RoundButton { glyph: "×"; onClicked: panel.dock.dismissHeld(heldRow.modelData.mode, heldRow.n.hid) }
              }
            }
          }

          Item { width: 1; height: Math.round(4 * panel.s) }
          Pill {
            visible: parent.items.length > 0
            x: Math.round(8 * panel.s)
            text: panel.pageArg ? "Clear these" : "Clear all"
            onClicked: {
              if (panel.pageArg) panel.dock.clearHeld(panel.pageArg)
              else panel.dock.clearAllHeld()
            }
          }
        }

        // ── Schedule ──
        Column {
          visible: panel.pageName === "schedule"
          width: parent.width
          spacing: Math.round(2 * panel.s)

          readonly property var blocks: panel.activity && panel.pageName === "schedule" ? panel.activity.scheduleBlocks() : []

          Note {
            text: parent.blocks.length
              ? "When a block starts, the workspace in front switches to its mode."
              : "No schedule yet. A schedule puts the workspace in front in a mode when a block starts, like Building on weekday mornings."
          }

          Repeater {
            model: parent.blocks
            delegate: Item {
              id: blockRow
              required property var modelData
              required property int index
              readonly property var mode: panel.dock ? panel.dock.modeById(modelData.mode) : null
              width: parent ? parent.width : 0
              height: Math.round(34 * panel.s)

              Text {
                id: blockGlyph
                anchors.verticalCenter: parent.verticalCenter
                x: Math.round(10 * panel.s)
                width: Math.round(20 * panel.s)
                textFormat: Text.PlainText
                text: blockRow.mode ? (blockRow.mode.icon || "●") : "●"
                color: panel.dock ? panel.dock.modeColor(blockRow.mode) : panel.accent
                font.family: panel.glyphFont
                font.pixelSize: Math.round(14 * panel.s)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: blockGlyph.right
                anchors.leftMargin: Math.round(6 * panel.s)
                anchors.right: blockRemove.left
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: (blockRow.mode ? blockRow.mode.name : String(blockRow.modelData.mode) + " (no such mode)") + "  ·  " + panel.activity.describeBlock(blockRow.modelData)
                color: panel.ink
                font.family: panel.uiFont
                font.pixelSize: Math.round(13 * panel.s)
              }
              RoundButton {
                id: blockRemove
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                glyph: "×"
                onClicked: {
                  var list = panel.activity.scheduleBlocks().slice()
                  list.splice(blockRow.index, 1)
                  panel.settings.schedule = list
                }
              }
            }
          }

          Item { width: 1; height: Math.round(4 * panel.s) }
          Pill {
            visible: panel.hasAi
            x: Math.round(8 * panel.s)
            active: true
            text: parent.blocks.length ? "Change it with " + panel.aiName + "…" : "Make one with " + panel.aiName + "…"
            onClicked: panel.dock.openAsk("Set my Petal schedule: ")
          }
        }

        // ── Last week ──
        Column {
          visible: panel.pageName === "summary"
          width: parent.width
          spacing: Math.round(2 * panel.s)

          readonly property var week: panel.summaryData

          Note {
            visible: panel.summaryLoading || !parent.week || parent.week.modes.length === 0
            text: panel.summaryLoading ? "Adding it up…" : parent.week ? String(parent.week.lines[0] || "") : "Couldn't add it up."
          }

          Note {
            visible: !panel.summaryLoading && !!parent.week && parent.week.modes.length > 0
            text: parent.week ? panel.dock.shortDay(parent.week.from) + " – " + panel.dock.shortDay(parent.week.to) : ""
          }

          Repeater {
            model: !panel.summaryLoading && parent.week ? parent.week.modes : []
            delegate: Item {
              id: modeRow
              required property var modelData
              width: parent ? parent.width : 0
              height: Math.round(44 * panel.s)

              Text {
                id: modeGlyph
                x: Math.round(10 * panel.s)
                y: Math.round(6 * panel.s)
                width: Math.round(20 * panel.s)
                textFormat: Text.PlainText
                text: modeRow.modelData.icon || "●"
                color: modeRow.modelData.color || panel.accent
                font.family: panel.glyphFont
                font.pixelSize: Math.round(14 * panel.s)
              }
              Column {
                anchors.left: modeGlyph.right
                anchors.leftMargin: Math.round(6 * panel.s)
                anchors.right: parent.right
                anchors.rightMargin: Math.round(10 * panel.s)
                y: Math.round(5 * panel.s)
                Item {
                  width: parent.width
                  height: modeName.implicitHeight
                  Text {
                    id: modeName
                    textFormat: Text.PlainText
                    text: modeRow.modelData.name
                    color: panel.ink
                    font.family: panel.uiFont
                    font.pixelSize: Math.round(13 * panel.s)
                    font.weight: Font.DemiBold
                  }
                  Text {
                    anchors.right: parent.right
                    textFormat: Text.PlainText
                    text: panel.duration(modeRow.modelData.minutes)
                    color: panel.ink
                    font.family: panel.uiFont
                    font.pixelSize: Math.round(13 * panel.s)
                  }
                }
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: modeRow.modelData.apps.map(function(a) { return a.name + " " + panel.duration(a.minutes) }).join("  ·  ")
                  color: panel.soft
                  font.family: panel.uiFont
                  font.pixelSize: Math.round(12 * panel.s)
                }
              }
            }
          }

          Note {
            visible: !panel.summaryLoading && !!parent.week && parent.week.cards.shown > 0
            text: parent.week ? parent.week.lines[parent.week.lines.length - 1] : ""
          }
        }

        // ── Check Petal ──
        Column {
          visible: panel.pageName === "doctor"
          width: parent.width
          spacing: Math.round(2 * panel.s)

          Note {
            visible: panel.doctorRunning
            text: "Checking…"
          }

          Repeater {
            model: panel.doctorRunning ? [] : panel.findings
            delegate: Item {
              id: findingRow
              required property var modelData
              width: parent ? parent.width : 0
              height: findingText.implicitHeight + Math.round(10 * panel.s)

              Text {
                id: findingMark
                x: Math.round(10 * panel.s)
                y: Math.round(5 * panel.s)
                width: Math.round(18 * panel.s)
                textFormat: Text.PlainText
                text: findingRow.modelData.fixed ? "✓" : ({ ok: "✓", warn: "!", error: "✗" })[findingRow.modelData.level] || "·"
                color: findingRow.modelData.level === "error" && !findingRow.modelData.fixed ? "#ff6b8a"
                  : findingRow.modelData.level === "warn" && !findingRow.modelData.fixed ? "#ffb347" : panel.accent
                font.family: panel.uiFont
                font.pixelSize: Math.round(13 * panel.s)
                font.weight: Font.DemiBold
              }
              Text {
                id: findingText
                anchors.left: findingMark.right
                anchors.right: parent.right
                anchors.rightMargin: Math.round(8 * panel.s)
                y: Math.round(5 * panel.s)
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: String(findingRow.modelData.text || "") + (findingRow.modelData.fixed ? "  Fixed: " + findingRow.modelData.fixed + "." : "")
                color: panel.ink
                font.family: panel.uiFont
                font.pixelSize: Math.round(12.5 * panel.s)
              }
            }
          }

          Item { width: 1; height: Math.round(4 * panel.s) }
          Row {
            x: Math.round(8 * panel.s)
            spacing: Math.round(6 * panel.s)
            visible: !panel.doctorRunning
            Pill { visible: panel.anyProblem; active: true; text: "Fix what it can"; onClicked: panel.runDoctor(true) }
            Pill { text: "Check again"; onClicked: panel.runDoctor(false) }
            Pill { text: "Report a problem…"; active: panel.reporting; onClicked: panel.reporting = !panel.reporting }
          }

          Column {
            visible: panel.reporting
            width: parent.width
            spacing: Math.round(6 * panel.s)
            topPadding: Math.round(8 * panel.s)

            Note { text: "Tell Petal's maker what went wrong. You'll see the report first: no username, window titles or file contents." }
            Field {
              id: reportField
              placeholder: "What happened?"
              onAccepted: panel.previewReport()
            }
            Rectangle {
              visible: panel.reportPreview !== ""
              width: parent.width
              height: Math.min(previewText.implicitHeight + Math.round(16 * panel.s), Math.round(200 * panel.s))
              radius: Math.round(10 * panel.s)
              color: Qt.rgba(1, 1, 1, 0.04)
              border.width: 1
              border.color: Qt.rgba(1, 1, 1, 0.08)
              clip: true
              Flickable {
                anchors.fill: parent
                anchors.margins: Math.round(8 * panel.s)
                contentHeight: previewText.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                Text {
                  id: previewText
                  width: parent.width
                  wrapMode: Text.WrapAnywhere
                  textFormat: Text.PlainText
                  text: panel.reportPreview
                  color: panel.ink
                  font.family: panel.glyphFont
                  font.pixelSize: Math.round(11 * panel.s)
                }
              }
            }
            Note { visible: panel.reportResult !== ""; text: panel.reportResult }
            Row {
              x: Math.round(8 * panel.s)
              spacing: Math.round(6 * panel.s)
              Pill { text: panel.reportBusy ? "…" : "Show the report"; visible: panel.reportPreview === ""; onClicked: panel.previewReport() }
              Pill { text: panel.reportBusy ? "Sending…" : "Send it"; active: true; visible: panel.reportPreview !== ""; onClicked: panel.sendReport() }
            }
          }
        }

        // ── Recipes ──
        Column {
          visible: panel.pageName === "recipes"
          width: parent.width
          spacing: Math.round(6 * panel.s)

          Header { text: "Share my dock" }
          Note { text: "Saves your modes, their apps and your dock's look as one file to share. Nothing personal goes in it." }
          Row {
            width: parent.width
            spacing: Math.round(6 * panel.s)
            Field {
              id: nameField
              width: parent.width - savePill.width - parent.spacing
              placeholder: "My Petal"
              onAccepted: panel.saveRecipe()
            }
            Pill { id: savePill; anchors.verticalCenter: parent.verticalCenter; active: true; text: "Save"; onClicked: panel.saveRecipe() }
          }
          Row {
            visible: panel.savedPath !== ""
            x: Math.round(8 * panel.s)
            spacing: Math.round(8 * panel.s)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Saved " + panel.dock.tildePath(panel.savedPath)
              color: panel.ink
              font.family: panel.uiFont
              font.pixelSize: Math.round(12.5 * panel.s)
            }
            Pill { text: "Show in Files"; onClicked: panel.dock.openPath(String(panel.savedPath).replace(/\/[^\/]*$/, "")) }
          }

          Header { text: "Add a shared dock" }
          Note {
            visible: !panel.plan
            text: panel.recipeFiles.length ? "Petal recipes on this computer:" : "Put a .petal file in your home folder or Downloads, or type where it is."
          }
          Repeater {
            model: panel.plan ? [] : panel.recipeFiles
            delegate: Link {
              required property var modelData
              text: panel.baseName(modelData)
              detail: panel.dock.tildePath(String(modelData).replace(/\/[^\/]*$/, ""))
              onTriggered: panel.previewRecipe(modelData)
            }
          }
          Row {
            visible: !panel.plan
            width: parent.width
            spacing: Math.round(6 * panel.s)
            Field {
              id: pathField
              width: parent.width - openPill.width - parent.spacing
              placeholder: "~/Downloads/friend.petal"
              onAccepted: panel.previewRecipe(panel.dock.expandPath(pathField.text.trim()))
            }
            Pill { id: openPill; anchors.verticalCenter: parent.verticalCenter; text: "Open"; onClicked: panel.previewRecipe(panel.dock.expandPath(pathField.text.trim())) }
          }

          // What it would change, before anything does.
          Column {
            visible: !!panel.plan
            width: parent.width
            spacing: Math.round(2 * panel.s)

            Note {
              text: panel.plan ? panel.baseName(panel.recipePath) + " adds " + (panel.plan.modes.length === 1 ? "this mode:" : "these modes:") : ""
            }
            Repeater {
              model: panel.plan ? panel.plan.modes : []
              delegate: Item {
                id: planRow
                required property var modelData
                width: parent ? parent.width : 0
                height: Math.round(28 * panel.s)
                Text {
                  id: planGlyph
                  anchors.verticalCenter: parent.verticalCenter
                  x: Math.round(10 * panel.s)
                  width: Math.round(20 * panel.s)
                  textFormat: Text.PlainText
                  text: planRow.modelData.icon || "●"
                  color: planRow.modelData.color || panel.accent
                  font.family: panel.glyphFont
                  font.pixelSize: Math.round(14 * panel.s)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: planGlyph.right
                  anchors.leftMargin: Math.round(6 * panel.s)
                  anchors.right: parent.right
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: planRow.modelData.name + "  ·  " + ((planRow.modelData.apps || []).map(panel.appName).join(", ") || "no apps yet")
                  color: panel.ink
                  font.family: panel.uiFont
                  font.pixelSize: Math.round(13 * panel.s)
                }
              }
            }
            Note {
              visible: !!panel.plan && panel.plan.missing.length > 0
              text: panel.plan ? "Not installed here, so left out: " + panel.plan.missing.join(", ") + "." : ""
            }
            Toggle {
              text: "Use this look too"
              detail: panel.plan && panel.plan.settings ? (Object.keys(panel.plan.settings).length + (panel.plan.dock ? Object.keys(panel.plan.dock).length : 0)) + " changes" : ""
              custom: true
              checked: panel.useLook
              onTriggered: {
                panel.useLook = !panel.useLook
                panel.previewRecipe(panel.recipePath)
              }
            }
            Row {
              x: Math.round(8 * panel.s)
              spacing: Math.round(6 * panel.s)
              Pill { active: true; text: "Add"; onClicked: panel.addRecipe() }
              Pill { text: "Cancel"; onClicked: panel.plan = null }
            }
          }
          Note { visible: panel.recipeResult !== ""; text: panel.recipeResult }
          Note { visible: panel.recipeError !== ""; text: panel.recipeError; color: "#ff6b8a" }
        }
      }
    }
  }

  // ── Building blocks ───────────────────────────────────────────────────
  component Header: Text {
    width: parent ? parent.width : 0
    height: Math.round(28 * panel.s)
    verticalAlignment: Text.AlignBottom
    leftPadding: Math.round(10 * panel.s)
    bottomPadding: Math.round(5 * panel.s)
    textFormat: Text.PlainText
    color: panel.soft
    font.family: panel.uiFont
    font.pixelSize: Math.round(11 * panel.s)
    font.weight: Font.DemiBold
    font.letterSpacing: 0.4
  }

  component Note: Text {
    width: parent ? parent.width : 0
    leftPadding: Math.round(10 * panel.s)
    rightPadding: Math.round(10 * panel.s)
    topPadding: Math.round(4 * panel.s)
    bottomPadding: Math.round(4 * panel.s)
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    color: panel.soft
    font.family: panel.uiFont
    font.pixelSize: Math.round(12.5 * panel.s)
  }

  // An on/off row: a setting by `key`, or `custom` with its own checked.
  component Toggle: Rectangle {
    id: toggleRow
    property string text: ""
    property string detail: ""
    property string key: ""
    property bool custom: false
    property bool checked: !custom && !!panel.settings && panel.settings[key] === true
    signal triggered()
    width: parent ? parent.width : 0
    height: visible ? Math.round(32 * panel.s) : 0
    radius: Math.round(9 * panel.s)
    opacity: enabled ? 1 : 0.45
    color: toggleMouse.containsMouse && enabled ? Qt.rgba(1, 1, 1, 0.07) : "transparent"

    Text {
      id: toggleText
      anchors.verticalCenter: parent.verticalCenter
      x: Math.round(10 * panel.s)
      textFormat: Text.PlainText
      text: toggleRow.text
      color: panel.ink
      font.family: panel.uiFont
      font.pixelSize: Math.round(13 * panel.s)
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: toggleText.right
      anchors.leftMargin: Math.round(8 * panel.s)
      anchors.right: toggleSwitch.left
      anchors.rightMargin: Math.round(8 * panel.s)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: toggleRow.detail
      color: panel.soft
      font.family: panel.uiFont
      font.pixelSize: Math.round(11.5 * panel.s)
    }
    Rectangle {
      id: toggleSwitch
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Math.round(10 * panel.s)
      width: Math.round(28 * panel.s)
      height: Math.round(16 * panel.s)
      radius: height / 2
      color: toggleRow.checked ? panel.accent : Qt.rgba(1, 1, 1, 0.14)
      Behavior on color { ColorAnimation { duration: Style.duration(140) } }
      Rectangle {
        width: parent.height - 4
        height: width
        radius: width / 2
        y: 2
        x: toggleRow.checked ? parent.width - width - 2 : 2
        color: "white"
        Behavior on x { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
      }
    }
    MouseArea {
      id: toggleMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: toggleRow.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (toggleRow.custom) toggleRow.triggered()
        else if (panel.dock) panel.dock.toggleSetting(toggleRow.key)
      }
    }
  }

  // A row that opens something: a page, the chat.
  component Link: Rectangle {
    id: linkRow
    property string text: ""
    property string detail: ""
    signal triggered()
    width: parent ? parent.width : 0
    height: visible ? Math.round(32 * panel.s) : 0
    radius: Math.round(9 * panel.s)
    color: linkMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent"

    Text {
      id: linkText
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Math.round(10 * panel.s)
      anchors.right: linkDetail.left
      anchors.rightMargin: Math.round(8 * panel.s)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: linkRow.text
      color: panel.ink
      font.family: panel.uiFont
      font.pixelSize: Math.round(13 * panel.s)
    }
    Text {
      id: linkDetail
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Math.round(10 * panel.s)
      width: Math.min(implicitWidth, linkRow.width * 0.45)
      elide: Text.ElideMiddle
      textFormat: Text.PlainText
      text: (linkRow.detail ? linkRow.detail + "  " : "") + "›"
      color: panel.soft
      font.family: panel.uiFont
      font.pixelSize: Math.round(12.5 * panel.s)
    }
    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: linkRow.triggered()
    }
  }

  component Field: Rectangle {
    id: field
    property string placeholder: ""
    property alias text: fieldInput.text
    signal accepted()
    width: parent ? parent.width : 0
    height: Math.round(34 * panel.s)
    radius: height / 2
    color: Qt.rgba(1, 1, 1, 0.06)
    border.width: 1
    border.color: fieldInput.activeFocus ? Qt.rgba(panel.accent.r, panel.accent.g, panel.accent.b, 0.6) : Qt.rgba(1, 1, 1, 0.1)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      x: Math.round(14 * panel.s)
      visible: fieldInput.text.length === 0
      textFormat: Text.PlainText
      text: field.placeholder
      color: panel.soft
      font.family: panel.uiFont
      font.pixelSize: Math.round(13 * panel.s)
    }
    TextInput {
      id: fieldInput
      anchors.verticalCenter: parent.verticalCenter
      x: Math.round(14 * panel.s)
      width: parent.width - x * 2
      color: panel.ink
      selectionColor: panel.accent
      font.family: panel.uiFont
      font.pixelSize: Math.round(13 * panel.s)
      clip: true
      Keys.onEscapePressed: keys.forceActiveFocus()
      Keys.onReturnPressed: field.accepted()
      Keys.onEnterPressed: field.accepted()
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.IBeamCursor
      onClicked: fieldInput.forceActiveFocus()
    }
  }

  component Pill: Rectangle {
    id: pill
    property string text: ""
    property bool active: false
    signal clicked()
    width: pillText.implicitWidth + Math.round(22 * panel.s)
    height: Math.round(28 * panel.s)
    radius: height / 2
    color: pill.active ? (pillMouse.containsMouse ? Qt.lighter(panel.accent, 1.1) : panel.accent) : (pillMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05))
    border.width: pill.active ? 0 : 1
    border.color: Qt.rgba(1, 1, 1, 0.1)

    Text {
      id: pillText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: pill.text
      color: pill.active ? "white" : panel.ink
      font.family: panel.uiFont
      font.pixelSize: Math.round(12.5 * panel.s)
      font.weight: pill.active ? Font.DemiBold : Font.Normal
    }
    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }
  }

  component RoundButton: Rectangle {
    id: rb
    property string glyph: ""
    signal clicked()
    width: Math.round(28 * panel.s)
    height: width
    radius: width / 2
    color: rbMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent"

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: rb.glyph
      color: panel.ink
      font.family: panel.uiFont
      font.pixelSize: Math.round(16 * panel.s)
      font.weight: Font.DemiBold
    }
    MouseArea {
      id: rbMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rb.clicked()
    }
  }
}
