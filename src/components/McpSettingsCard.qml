import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets

SettingsCard {
    id: root

    required property var aiService

    // Header row
    Row {
        width: parent.width
        spacing: Theme.spacingM

        DankIcon {
            name: "build"
            size: Theme.iconSize
            color: Theme.primary
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            text: "MCP Tools"
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Column {
        width: parent.width
        spacing: Theme.spacingS

        // Enable toggle
        Row {
            width: parent.width
            spacing: Theme.spacingM

            DankIcon {
                name: "extension"
                size: Theme.iconSize
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS
                width: parent.width - parent.spacing * 2 - Theme.iconSize - mcpEnabledToggle.width

                StyledText {
                    text: "Enable MCP Tools"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }

                StyledText {
                    text: "Connect an MCP bridge for Ollama tool calling"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    width: parent.width
                }
            }

            Switch {
                id: mcpEnabledToggle
                checked: aiService.mcpEnabled
                enabled: aiService.isOllama
                anchors.verticalCenter: parent.verticalCenter
                onToggled: {
                    aiService.mcpEnabled = checked;
                    aiService.saveSettingValue("mcpEnabled", checked);
                    if (checked && aiService.isOllama)
                        aiService.mcpService.connectToServer();
                    else
                        aiService.mcpService.disconnectFromServer();
                }
            }
        }

        // URL + bridge command fields
        AccordionSection {
            show: aiService.mcpEnabled

            Row {
                width: parent.width
                spacing: Theme.spacingM

                DankIcon {
                    name: "verified_user"
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS
                    width: parent.width - parent.spacing * 2 - Theme.iconSize - toolRequestsToggle.width

                    StyledText {
                        text: "Allow Model Tool Requests"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        text: "Only selected tools may be requested; every tool run needs approval."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }

                Switch {
                    id: toolRequestsToggle
                    checked: aiService.mcpToolRequestsAllowed
                    enabled: aiService.isOllama
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: {
                        aiService.setMcpToolRequestsAllowed(checked);
                    }
                }
            }

            StyledText {
                text: "MCP Server URL"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankTextField {
                id: mcpUrlField
                width: parent.width
                text: aiService.mcpUrl
                placeholderText: "http://192.168.1.107:8811/sse"
                onEditingFinished: {
                    var url = text.trim();
                    aiService.setMcpUrl(url);
                }
            }

            StyledText {
                text: "Bridge Command"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankTextField {
                id: mcpCommandField
                width: parent.width
                text: aiService.mcpCommand
                placeholderText: "mcp-remote"
                enabled: false
                onEditingFinished: {
                    aiService.setMcpCommand("mcp-remote");
                }
            }

            // Connect / Disconnect button
            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankButton {
                    text: {
                        if (aiService.mcpService.connecting) return "Connecting…";
                        if (aiService.mcpService.isConnected) return "Reconnect";
                        return "Connect";
                    }
                    iconName: aiService.mcpService.isConnected ? "refresh" : "link"
                    width: (parent.width - parent.spacing) / 2
                    enabled: aiService.isOllama && !aiService.mcpService.connecting && aiService.mcpUrl.length > 0 && aiService.mcpCommand.length > 0
                    onClicked: aiService.mcpService.reconnectToServer()
                }

                DankButton {
                    text: "Disconnect"
                    iconName: "link_off"
                    width: (parent.width - parent.spacing) / 2
                    enabled: aiService.mcpService.isConnected || aiService.mcpService.connecting
                    backgroundColor: Theme.error
                    textColor: Theme.onPrimary
                    onClicked: aiService.mcpService.disconnectFromServer()
                }
            }
        }

        // Connection status
        AccordionSection {
            show: aiService.mcpEnabled

            // Error
            Rectangle {
                width: parent.width
                height: mcpErrorText.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.error, 0.08)
                border.color: Theme.withAlpha(Theme.error, 0.3)
                border.width: 1
                visible: aiService.mcpService.connectionError.length > 0

                StyledText {
                    id: mcpErrorText
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingS * 2
                    text: aiService.mcpService.connectionError
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                    wrapMode: Text.Wrap
                }
            }

            // Status pill
            Rectangle {
                width: parent.width
                height: 36
                radius: Theme.cornerRadius
                color: {
                    if (aiService.mcpService.isConnected) return Theme.withAlpha(Theme.primary, 0.10);
                    if (aiService.mcpService.connecting) return Theme.withAlpha(Theme.secondary, 0.10);
                    return Theme.withAlpha(Theme.outline, 0.10);
                }
                border.color: {
                    if (aiService.mcpService.isConnected) return Theme.withAlpha(Theme.primary, 0.25);
                    if (aiService.mcpService.connecting) return Theme.withAlpha(Theme.secondary, 0.25);
                    return Theme.withAlpha(Theme.outline, 0.15);
                }
                border.width: 1

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS

                    DankIcon {
                        name: {
                            if (aiService.mcpService.isConnected) return "check_circle";
                            if (aiService.mcpService.connecting) return "pending";
                            return "radio_button_unchecked";
                        }
                        size: 16
                        color: {
                            if (aiService.mcpService.isConnected) return Theme.primary;
                            if (aiService.mcpService.connecting) return Theme.secondary;
                            return Theme.surfaceVariantText;
                        }
                        anchors.verticalCenter: parent.verticalCenter

                        SequentialAnimation on rotation {
                            loops: Animation.Infinite
                            running: aiService.mcpService.connecting
                            NumberAnimation { from: 0; to: 360; duration: 1500; easing.type: Easing.Linear }
                        }
                    }

                    StyledText {
                        text: {
                            if (aiService.mcpService.isConnected)
                                return "Connected · " + aiService.mcpService.tools.length + " tools";
                            if (aiService.mcpService.connecting) return "Connecting…";
                            return "Not connected";
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: {
                            if (aiService.mcpService.isConnected) return Theme.primary;
                            if (aiService.mcpService.connecting) return Theme.secondary;
                            return Theme.surfaceVariantText;
                        }
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            // Tool list
            AccordionSection {
                show: aiService.mcpService.isConnected && aiService.mcpService.tools.length > 0

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS

                    StyledText {
                        text: "Allowed Tools"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: aiService.mcpService.tools

                        Rectangle {
                            required property var modelData
                            width: parent.width
                            height: toolRow.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)

                            Row {
                                id: toolRow
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: "functions"
                                    size: 14
                                    color: Theme.primary
                                    anchors.top: parent.top
                                    anchors.topMargin: 2
                                }

                                Column {
                                    width: parent.width - 14 - toolAllowedToggle.width - parent.spacing * 2
                                    spacing: 2

                                    StyledText {
                                        text: modelData.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: Theme.monoFontFamily
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        text: modelData.description || ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                        width: parent.width
                                        visible: text.length > 0
                                    }
                                }

                                Switch {
                                    id: toolAllowedToggle
                                    checked: aiService.isMcpToolAllowed(modelData.name)
                                    enabled: aiService.isOllama && aiService.mcpService.isConnected
                                    anchors.verticalCenter: parent.verticalCenter
                                    onToggled: aiService.setMcpToolAllowed(modelData.name, checked)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
