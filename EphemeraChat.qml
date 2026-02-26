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
    property bool slideoutExpandable: false
    property bool slideoutExpanded: false
    signal hideRequested
    signal expandToggled

    function focusInput() {
        composer.forceActiveFocus();
    }

    onVisibleChanged: {
        if (!visible) {
            showSettings = false;
            _settingsClosing = false;
            if (aiService) aiService.scheduleIdleShutdown();
        } else {
            if (aiService) aiService.ensureOllamaReady();
            Qt.callLater(function() { composer.forceActiveFocus(); });
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
                color: {
                    if (aiService.missingApiKey || aiService.lastRequestFailed)
                        return Theme.withAlpha(Theme.error, 0.15);
                    if (_flashing)
                        return Theme.withAlpha(Theme.primary, 0.3);
                    return Theme.surfaceVariant;
                }
                border.color: (aiService.missingApiKey || aiService.lastRequestFailed) ? Theme.withAlpha(Theme.error, 0.4) : "transparent"
                border.width: (aiService.missingApiKey || aiService.lastRequestFailed) ? 1 : 0
                height: Theme.fontSizeSmall * 1.6
                Layout.preferredWidth: root.slideoutExpanded ? 320 : 160
                Layout.alignment: Qt.AlignVCenter

                Behavior on Layout.preferredWidth {
                    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                }
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
                    color: (aiService.missingApiKey || aiService.lastRequestFailed) ? Theme.error : Theme.surfaceVariantText
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
                iconName: "content_copy"
                tooltipText: "Copy conversation"
                visible: root.slideoutExpanded
                enabled: (aiService.messageCount || 0) > 0 && !aiService.isStreaming
                onClicked: {
                    aiService.exportConversation();
                    showToast("Conversation copied to clipboard");
                }
            }

            DankActionButton {
                iconName: "save_as"
                tooltipText: "Save conversation as .md"
                visible: root.slideoutExpanded
                enabled: (aiService.messageCount || 0) > 0 && !aiService.isStreaming
                onClicked: {
                    var file = aiService.exportConversationToFile();
                    showToast("Saved to " + file.split("/").pop());
                }
            }

            DankActionButton {
                iconName: "delete_sweep"
                tooltipText: "Clear chat"
                visible: root.slideoutExpanded
                enabled: (aiService.messageCount || 0) > 0 && !aiService.isStreaming
                onClicked: clearConfirmDialog.open()
            }

            DankActionButton {
                id: overflowBtn
                iconName: "more_vert"
                tooltipText: "More actions"
                visible: !root.slideoutExpanded
                onClicked: overflowMenu.open()

                Popup {
                    id: overflowMenu
                    x: overflowBtn.width - width
                    y: overflowBtn.height + Theme.spacingXS
                    width: 200
                    padding: Theme.spacingXS

                    background: Rectangle {
                        color: Theme.surfaceContainerHighest
                        radius: Theme.cornerRadius
                        border.color: Theme.outline
                        border.width: 1
                    }

                    Column {
                        width: parent.width
                        spacing: 0

                        ItemDelegate {
                            width: parent.width
                            height: 36
                            enabled: (aiService.messageCount || 0) > 0 && !aiService.isStreaming
                            onClicked: { aiService.exportConversation(); showToast("Conversation copied to clipboard"); overflowMenu.close(); }
                            background: Rectangle {
                                color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"
                                radius: Theme.cornerRadius
                            }

                            contentItem: Row {
                                spacing: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter

                                DankIcon {
                                    name: "content_copy"
                                    size: 16
                                    color: parent.parent.enabled ? Theme.surfaceText : Theme.surfaceTextMedium
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Copy conversation"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: parent.parent.enabled ? Theme.surfaceText : Theme.surfaceTextMedium
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        ItemDelegate {
                            width: parent.width
                            height: 36
                            enabled: (aiService.messageCount || 0) > 0 && !aiService.isStreaming
                            onClicked: { var f = aiService.exportConversationToFile(); showToast("Saved to " + f.split("/").pop()); overflowMenu.close(); }
                            background: Rectangle {
                                color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"
                                radius: Theme.cornerRadius
                            }

                            contentItem: Row {
                                spacing: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter

                                DankIcon {
                                    name: "save_as"
                                    size: 16
                                    color: parent.parent.enabled ? Theme.surfaceText : Theme.surfaceTextMedium
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Save as .md"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: parent.parent.enabled ? Theme.surfaceText : Theme.surfaceTextMedium
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        ItemDelegate {
                            width: parent.width
                            height: 36
                            enabled: (aiService.messageCount || 0) > 0 && !aiService.isStreaming
                            onClicked: { clearConfirmDialog.open(); overflowMenu.close(); }
                            background: Rectangle {
                                color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"
                                radius: Theme.cornerRadius
                            }

                            contentItem: Row {
                                spacing: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter

                                DankIcon {
                                    name: "delete_sweep"
                                    size: 16
                                    color: parent.parent.enabled ? Theme.surfaceText : Theme.surfaceTextMedium
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Clear chat"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: parent.parent.enabled ? Theme.surfaceText : Theme.surfaceTextMedium
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                }
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
                onClicked: root.hideRequested()
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
                expanded: root.slideoutExpanded
                canRegenerate: !aiService.isStreaming && aiService.lastUserText.length > 0
                onRegenerateRequested: aiService.regenerate()
                onVariantChangeRequested: (msgId, newIndex) => aiService.switchVariant(msgId, newIndex)
                onEditRequested: (msgId, newText) => aiService.editAndRegenerate(msgId, newText)
            }

            // Missing API key banner
            Rectangle {
                anchors.top: parent.top
                anchors.topMargin: Theme.spacingM
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - Theme.spacingL * 2
                height: apiKeyBannerCol.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.error, 0.08)
                border.color: Theme.withAlpha(Theme.error, 0.3)
                border.width: 1
                visible: aiService.missingApiKey
                z: 10

                Column {
                    id: apiKeyBannerCol
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingM * 2
                    spacing: Theme.spacingXS

                    Row {
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "vpn_key_off"
                            size: 18
                            color: Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "API key not found"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: {
                            var envVar = "";
                            switch (aiService.provider) {
                            case "openai": envVar = "OPENAI_API_KEY"; break;
                            case "anthropic": envVar = "ANTHROPIC_API_KEY"; break;
                            case "gemini": envVar = "GEMINI_API_KEY"; break;
                            default: envVar = "EPHEMERA_API_KEY"; break;
                            }
                            return "Set the " + envVar + " environment variable before starting Quickshell.";
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.fontFamily
                        color: Theme.surfaceTextMedium
                        wrapMode: Text.Wrap
                    }
                }
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

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) {
                                hideRequested();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Return && !(event.modifiers & Qt.ShiftModifier)) {
                                sendCurrentMessage();
                                event.accepted = true;
                            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Return) {
                                sendCurrentMessage();
                                event.accepted = true;
                            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_L) {
                                if (!aiService.isStreaming && (aiService.messageCount || 0) > 0)
                                    clearConfirmDialog.open();
                                composer.forceActiveFocus();
                                event.accepted = true;
                            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
                                if (!aiService.isStreaming) {
                                    aiService.clearChat();
                                    composer.text = "";
                                }
                                composer.forceActiveFocus();
                                event.accepted = true;
                            } else if ((event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) === (Qt.ControlModifier | Qt.ShiftModifier) && event.key === Qt.Key_S) {
                                if (showSettings) closeSettings();
                                else showSettings = true;
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up && composer.text.length === 0 && aiService.lastUserText.length > 0) {
                                composer.text = aiService.lastUserText;
                                composer.cursorPosition = composer.text.length;
                                event.accepted = true;
                            }
                        }
                    }
                }

                StyledText {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    text: aiService.missingApiKey ? "API key required \u2014 set env var" : "Ask something\u2026  (Shift+Enter for newline)"
                    font.pixelSize: Theme.fontSizeMedium
                    color: aiService.missingApiKey ? Theme.error : Theme.outlineButton
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
                    enabled: composer.text && composer.text.trim().length > 0 && !aiService.isStreaming && !aiService.missingApiKey
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

    // -- Toast notification --
    property string _toastMessage: ""

    Rectangle {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: composerRow.height + Theme.spacingL
        width: toastText.implicitWidth + Theme.spacingL * 2
        height: 36
        radius: 18
        color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.95)
        border.color: Theme.outline
        border.width: 1
        visible: opacity > 0
        opacity: 0
        z: 100

        Behavior on opacity {
            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }

        StyledText {
            id: toastText
            anchors.centerIn: parent
            text: root._toastMessage
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
        }

        Timer {
            id: toastTimer
            interval: 2000
            onTriggered: toast.opacity = 0
        }
    }

    function showToast(message) {
        _toastMessage = message;
        toast.opacity = 1;
        toastTimer.restart();
    }

    // -- Clear chat confirmation dialog --
    Popup {
        id: clearConfirmDialog
        anchors.centerIn: parent
        width: 280
        padding: Theme.spacingL
        modal: true

        background: Rectangle {
            color: Theme.surfaceContainerHighest
            radius: Theme.cornerRadius
            border.color: Theme.outline
            border.width: 1
        }

        Column {
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Clear conversation?"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StyledText {
                text: "This will permanently delete all messages."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceTextMedium
                wrapMode: Text.Wrap
                width: parent.width
            }

            Row {
                spacing: Theme.spacingS
                anchors.right: parent.right

                DankButton {
                    text: "Cancel"
                    onClicked: clearConfirmDialog.close()
                }

                DankButton {
                    text: "Clear"
                    backgroundColor: Theme.error
                    textColor: Theme.onPrimary
                    onClicked: {
                        aiService.clearChat();
                        clearConfirmDialog.close();
                    }
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

}
