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
    signal hideRequested

    onVisibleChanged: {
        if (!visible)
            showSettings = false;
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

    Column {
        anchors.fill: parent
        spacing: Theme.spacingM

        // ── Header ──────────────────────────────────────────────
        RowLayout {
            id: headerRow
            width: parent.width
            spacing: Theme.spacingS

            Rectangle {
                radius: Theme.cornerRadius
                color: Theme.surfaceVariant
                height: Theme.fontSizeSmall * 1.6
                Layout.preferredWidth: providerLabel.implicitWidth + Theme.spacingM
                Layout.alignment: Qt.AlignVCenter

                StyledText {
                    id: providerLabel
                    anchors.centerIn: parent
                    text: root.displayModel
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            Item { Layout.fillWidth: true }

            DankActionButton {
                iconName: "tune"
                tooltipText: showSettings ? "Hide settings" : "Settings"
                onClicked: showSettings = !showSettings
            }

            DankActionButton {
                iconName: "delete_sweep"
                tooltipText: "Clear chat"
                enabled: (aiService.messageCount || 0) > 0 && !aiService.isStreaming
                onClicked: aiService.clearChat()
            }
        }

        // ── Message area ────────────────────────────────────────
        Rectangle {
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

            StyledText {
                anchors.centerIn: parent
                visible: (aiService.messageCount || 0) === 0
                text: "Ask anything. Nothing is saved."
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceTextMedium
                wrapMode: Text.Wrap
                width: parent.width * 0.8
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // ── Composer ────────────────────────────────────────────
        Row {
            id: composerRow
            width: parent.width
            height: 120
            spacing: Theme.spacingM

            Rectangle {
                id: composerContainer
                width: parent.width - actionButtons.width - Theme.spacingM
                height: 120
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                border.color: composer.activeFocus ? Theme.primary : Theme.outlineMedium
                border.width: composer.activeFocus ? 2 : 1

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
                                hideRequested();
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

            Column {
                id: actionButtons
                spacing: Theme.spacingS
                width: 100

                DankButton {
                    text: "Send"
                    iconName: "send"
                    enabled: composer.text && composer.text.trim().length > 0 && !aiService.isStreaming
                    width: parent.width
                    onClicked: sendCurrentMessage()
                }

                DankButton {
                    text: "Stop"
                    iconName: "stop"
                    enabled: aiService.isStreaming
                    backgroundColor: Theme.error
                    textColor: Theme.errorText
                    width: parent.width
                    onClicked: aiService.cancel()
                }
            }
        }
    }

    // ── Settings overlay ────────────────────────────────────────
    Loader {
        id: settingsPanelLoader
        anchors.fill: parent
        active: showSettings
        sourceComponent: settingsPanelComponent
    }

    Component {
        id: settingsPanelComponent

        EphemeraSettings {
            anchors.fill: parent
            isVisible: true
            onCloseRequested: showSettings = false
            aiService: root.aiService
        }
    }
}
