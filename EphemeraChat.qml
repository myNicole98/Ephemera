import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    required property var aiService
    property bool showSettings: false
    property bool _settingsClosing: false
    property bool showShutdownDialog: false
    property bool slideoutExpandable: false
    property bool slideoutExpanded: false
    signal hideRequested
    signal expandToggled

    onVisibleChanged: {
        if (!visible) {
            showSettings = false;
            _settingsClosing = false;
        } else {
            if (aiService) aiService.ensureOllamaReady();
        }
    }

    readonly property string displayModel: {
        if (!aiService) return "";
        var p = aiService.provider || "ollama";
        var m = aiService.model || "";
        if (m) return p.toUpperCase() + " / " + m;
        return p.toUpperCase();
    }

    function sendCurrentMessage() {
        if (!composer.text || composer.text.trim().length === 0) return;
        if (!aiService) return;
        aiService.sendMessage(composer.text.trim());
        composer.text = "";
    }

    function closeSettings() {
        if (_settingsClosing) return;
        _settingsClosing = true;
        if (settingsPanelLoader.item)
            settingsPanelLoader.item.opacity = 0;
        settingsCloseTimer.start();
    }

    function requestClose() {
        if (aiService && aiService.isOllama && aiService.ollamaReady) {
            if (aiService.ollamaWeStarted) {
                // We started it — stop automatically
                aiService.shutdownOllama();
                hideRequested();
            } else if (aiService.ollamaExternallyManaged) {
                // External — ask user
                showShutdownDialog = true;
            } else {
                hideRequested();
            }
        } else {
            hideRequested();
        }
    }

    Column {
        anchors.fill: parent
        spacing: Theme.spacingM

        // -- Header --
        RowLayout {
            id: headerRow
            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                text: "Ephemera"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
                Layout.alignment: Qt.AlignVCenter
            }

            // Provider pill with fixed max width and truncation
            Rectangle {
                id: providerPill
                radius: Theme.cornerRadius
                color: _flashing ? Theme.withAlpha(Theme.primary, 0.3) : Theme.surfaceVariant
                height: Theme.fontSizeSmall * 1.6
                Layout.preferredWidth: 160
                Layout.alignment: Qt.AlignVCenter
                clip: true

                property bool _flashing: false

                Behavior on color {
                    ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                }

                Timer {
                    id: providerFlashTimer
                    interval: 150
                    onTriggered: providerPill._flashing = false
                }

                StyledText {
                    id: providerLabel
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingS * 2
                    text: root.displayModel
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter

                    onTextChanged: {
                        providerPill._flashing = true;
                        providerFlashTimer.start();
                    }
                }
            }

            Item { Layout.fillWidth: true }

            DankActionButton {
                iconName: "tune"
                tooltipText: showSettings ? "Hide settings" : "Settings"
                onClicked: {
                    if (showSettings) closeSettings();
                    else showSettings = true;
                }
            }

            DankActionButton {
                iconName: "delete_sweep"
                tooltipText: "Clear chat"
                enabled: (aiService.messageCount || 0) > 0 && !aiService.isStreaming
                onClicked: aiService.clearChat()
            }

            DankActionButton {
                id: expandBtn
                iconName: root.slideoutExpanded ? "unfold_less" : "unfold_more"
                iconSize: Theme.iconSize - 4
                iconColor: Theme.surfaceText
                visible: root.slideoutExpandable
                tooltipText: root.slideoutExpanded ? "Collapse" : "Expand"
                onClicked: root.expandToggled()

                transform: Rotation {
                    angle: 90
                    origin.x: expandBtn.width / 2
                    origin.y: expandBtn.height / 2
                }
            }

            DankActionButton {
                iconName: "close"
                iconSize: Theme.iconSize - 4
                iconColor: Theme.surfaceText
                tooltipText: "Close"
                onClicked: root.requestClose()
            }
        }

        // -- Message area --
        Rectangle {
            id: messageArea
            width: parent.width
            height: parent.height - headerRow.height - composerRow.height - Theme.spacingM * 3
            radius: Theme.cornerRadius
            color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, SettingsData.popupTransparency)
            border.color: Theme.surfaceVariantAlpha
            border.width: 1

            MessageList {
                id: list
                anchors.fill: parent
                messages: aiService.messagesModel
                modelName: aiService.model || "Assistant"
            }

            // Breathing empty state
            Column {
                id: emptyState
                anchors.centerIn: parent
                spacing: Theme.spacingS
                visible: opacity > 0
                opacity: (aiService.messageCount || 0) === 0 ? 1.0 : 0.0
                width: parent.width * 0.8

                Behavior on opacity {
                    NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                }

                // Breathing vapor icon
                DankIcon {
                    id: vaporIcon
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "blur_on"
                    size: 48
                    color: Theme.primary
                    opacity: 0.5

                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.75; duration: 1200; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 0.5; duration: 1200; easing.type: Easing.InOutSine }
                    }

                    SequentialAnimation on scale {
                        loops: Animation.Infinite
                        NumberAnimation { to: 1.06; duration: 1200; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1200; easing.type: Easing.InOutSine }
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Ask anything. Nothing is saved."
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceTextMedium
                    wrapMode: Text.Wrap
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                }

                StyledText {
                    id: subtitleText
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "ephemeral by design"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    opacity: 0.5
                    horizontalAlignment: Text.AlignHCenter

                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.75; duration: 1600; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 0.5; duration: 1600; easing.type: Easing.InOutSine }
                    }
                }
            }

            // Scroll-to-bottom pill
            Rectangle {
                id: scrollPill
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Theme.spacingM
                width: scrollPillRow.implicitWidth + Theme.spacingM * 2
                height: 32
                radius: 16
                color: Theme.withAlpha(Theme.primary, 0.85)
                visible: opacity > 0
                opacity: list.stickToBottom ? 0.0 : 1.0
                scale: list.stickToBottom ? 0.8 : 1.0

                Behavior on opacity {
                    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                }
                Behavior on scale {
                    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                }

                Row {
                    id: scrollPillRow
                    anchors.centerIn: parent
                    spacing: Theme.spacingXS

                    DankIcon {
                        name: "keyboard_arrow_down"
                        size: 16
                        color: Theme.onPrimary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "New messages"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.onPrimary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: list.scrollToBottom()
                }
            }
        }

        // -- Composer --
        Row {
            id: composerRow
            width: parent.width
            height: composerContainer.height
            spacing: Theme.spacingM

            Rectangle {
                id: composerContainer
                width: parent.width - actionButtonArea.width - Theme.spacingM
                height: Math.max(44, Math.min(160, composer.contentHeight + Theme.spacingM * 2))
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                border.color: composer.activeFocus ? Theme.primary : Theme.outlineMedium
                border.width: composer.activeFocus ? 2 : 1

                Behavior on height {
                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }

                Behavior on border.width {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }

                ScrollView {
                    id: scrollView
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    clip: true
                    padding: 0
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                    TextArea {
                        id: composer
                        implicitWidth: scrollView.availableWidth
                        wrapMode: TextArea.Wrap
                        background: Rectangle { color: "transparent" }
                        font.pixelSize: Theme.fontSizeMedium
                        font.family: Theme.fontFamily
                        font.weight: Theme.fontWeight
                        color: Theme.surfaceText
                        Material.accent: Theme.primary
                        padding: 0
                        leftPadding: 0
                        rightPadding: 0
                        topPadding: 0
                        bottomPadding: 0

                        Keys.onReleased: event => {
                            if (event.key === Qt.Key_Escape) {
                                requestClose();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Return && !(event.modifiers & Qt.ShiftModifier)) {
                                sendCurrentMessage();
                                event.accepted = true;
                            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Return) {
                                sendCurrentMessage();
                                event.accepted = true;
                            }
                        }

                        // Prevent Enter from inserting newline when sending
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return && !(event.modifiers & Qt.ShiftModifier)) {
                                event.accepted = true;
                            }
                        }
                    }
                }

                StyledText {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    text: "Ask something\u2026"
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.outlineButton
                    verticalAlignment: Text.AlignTop
                    visible: composer.text.length === 0
                    wrapMode: Text.Wrap
                }
            }

            // Compact send/stop crossfade area
            Item {
                id: actionButtonArea
                width: 44
                height: composerContainer.height

                // Send button
                DankActionButton {
                    id: sendBtn
                    anchors.centerIn: parent
                    iconName: "send"
                    buttonSize: 40
                    iconSize: 20
                    backgroundColor: Theme.primary
                    iconColor: Theme.onPrimary
                    tooltipText: "Send"
                    enabled: composer.text && composer.text.trim().length > 0 && !aiService.isStreaming
                    opacity: aiService.isStreaming ? 0.0 : 1.0
                    scale: aiService.isStreaming ? 0.6 : 1.0
                    visible: opacity > 0
                    onClicked: sendCurrentMessage()

                    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                }

                // Stop button
                DankActionButton {
                    id: stopBtn
                    anchors.centerIn: parent
                    iconName: "stop"
                    buttonSize: 40
                    iconSize: 20
                    backgroundColor: Theme.error
                    iconColor: Theme.onPrimary
                    tooltipText: "Stop"
                    enabled: aiService.isStreaming
                    opacity: aiService.isStreaming ? 1.0 : 0.0
                    scale: aiService.isStreaming ? 1.0 : 0.6
                    visible: opacity > 0
                    onClicked: aiService.cancel()

                    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                }
            }
        }
    }

    // -- Settings overlay with fade in/out --
    Loader {
        id: settingsPanelLoader
        anchors.fill: parent
        active: showSettings || _settingsClosing
        sourceComponent: settingsPanelComponent

        onLoaded: {
            if (item) {
                item.opacity = 0;
                Qt.callLater(function() {
                    if (settingsPanelLoader.item)
                        settingsPanelLoader.item.opacity = 1;
                });
            }
        }
    }

    Timer {
        id: settingsCloseTimer
        interval: 220
        repeat: false
        onTriggered: {
            showSettings = false;
            _settingsClosing = false;
        }
    }

    Component {
        id: settingsPanelComponent

        EphemeraSettings {
            anchors.fill: parent
            isVisible: true
            onCloseRequested: root.closeSettings()
            aiService: root.aiService

            Behavior on opacity {
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }
        }
    }

    // -- Ollama shutdown confirmation dialog --
    Rectangle {
        id: shutdownDialog
        anchors.fill: parent
        color: Theme.withAlpha(Theme.onSurface, 0.5)
        visible: opacity > 0
        opacity: showShutdownDialog ? 1.0 : 0.0
        z: 200

        Behavior on opacity {
            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: showShutdownDialog = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(320, parent.width - Theme.spacingL * 2)
            height: dialogContent.implicitHeight + Theme.spacingL * 2
            radius: Theme.cornerRadius * 2
            color: Theme.surfaceContainerHigh
            border.color: Theme.outlineMedium
            border.width: 1

            // Prevent click-through to scrim
            MouseArea { anchors.fill: parent }

            Column {
                id: dialogContent
                anchors.centerIn: parent
                width: parent.width - Theme.spacingL * 2
                spacing: Theme.spacingM

                StyledText {
                    text: "Stop Ollama?"
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    width: parent.width
                }

                StyledText {
                    text: "Ollama was already running before Ephemera started. Do you want to stop the server?"
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceTextMedium
                    width: parent.width
                    wrapMode: Text.Wrap
                }

                Row {
                    spacing: Theme.spacingS
                    anchors.right: parent.right

                    DankButton {
                        text: "Keep running"
                        onClicked: {
                            showShutdownDialog = false;
                            hideRequested();
                        }
                    }

                    DankButton {
                        text: "Stop Ollama"
                        backgroundColor: Theme.error
                        textColor: Theme.onPrimary
                        onClicked: {
                            aiService.forceShutdownExternalOllama();
                            showShutdownDialog = false;
                            hideRequested();
                        }
                    }
                }
            }
        }
    }
}
