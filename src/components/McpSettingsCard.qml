import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets
import "../lib/Mcp.js" as Mcp
import "../lib/Providers.js" as Providers

SettingsCard {
    id: root

    required property var aiService
    property string _urlError: ""

    function commitMcpUrl() {
        var url = mcpUrlField.text.trim();
        if (!url) {
            _urlError = "";
            aiService.setMcpUrl("");
            return false;
        }
        var validated = Providers.validateUrl(url);
        if (!validated.valid) {
            _urlError = validated.error || "Invalid MCP URL.";
            return false;
        }
        var safetyError = Mcp.mcpUrlSafetyError(url);
        if (safetyError) {
            _urlError = safetyError;
            return false;
        }
        _urlError = "";
        aiService.setMcpUrl(url);
        return true;
    }

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
            text: "MCP Tools · Experimental"
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
                    text: "Opt-in bridge support for Ollama. Expect transport and OAuth compatibility issues."
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
                onToggled: aiService.setMcpEnabled(checked)
            }
        }

        // MCP server configuration
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
                onEditingFinished: root.commitMcpUrl()
            }

            StyledText {
                width: parent.width
                text: root._urlError
                visible: text.length > 0
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
                wrapMode: Text.Wrap
            }

            Row {
                width: parent.width
                spacing: Theme.spacingM
                visible: Mcp.requiresInsecureHttpConsent(aiService.mcpUrl)

                DankIcon {
                    name: "warning"
                    size: Theme.iconSize
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS
                    width: parent.width - parent.spacing * 2 - Theme.iconSize - insecureHttpToggle.width

                    StyledText {
                        text: "Allow Unencrypted Remote HTTP"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: "Traffic can be intercepted. Use only on a trusted private network."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }
                }

                Switch {
                    id: insecureHttpToggle
                    checked: aiService.mcpInsecureHttpAllowed
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: aiService.setMcpInsecureHttpAllowed(checked)
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
                    enabled: {
                        var pendingUrl = mcpUrlField.text.trim();
                        var insecureConsentReady = pendingUrl === aiService.mcpUrl
                            && aiService.mcpInsecureHttpAllowed;
                        return aiService.isOllama
                            && !aiService.mcpService.connecting
                            && pendingUrl.length > 0
                            && (!Mcp.requiresInsecureHttpConsent(pendingUrl) || insecureConsentReady);
                    }
                    onClicked: {
                        if (root.commitMcpUrl())
                            aiService.reconnectMcp();
                    }
                }

                DankButton {
                    text: "Disconnect"
                    iconName: "link_off"
                    width: (parent.width - parent.spacing) / 2
                    enabled: aiService.mcpService.isConnected || aiService.mcpService.connecting
                    backgroundColor: Theme.error
                    textColor: Theme.onPrimary
                    onClicked: aiService.disconnectMcp()
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
                    textFormat: Text.PlainText
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
                                return "Connected · " + aiService.mcpService.tools.length + " tools · bridge " + aiService.mcpService.bridgeVersion;
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

            StyledText {
                width: parent.width
                visible: aiService.mcpService.ignoredToolCount > 0
                text: aiService.mcpService.ignoredToolCount + " invalid or unsupported tools were ignored."
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            // Tool list
            AccordionSection {
                show: aiService.mcpService.isConnected && aiService.mcpService.tools.length > 0

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS

                    StyledText {
                        text: "Available MCP Tools"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: aiService.mcpService.tools

                        Rectangle {
                            id: toolCard
                            required property var modelData
                            property bool reviewingContract: false
                            readonly property bool contractApproved: aiService.isMcpToolApproved(modelData.name)
                            width: parent.width
                            height: toolCardColumn.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)

                            Column {
                                id: toolCardColumn
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "functions"
                                        size: 14
                                        color: Theme.primary
                                        anchors.top: parent.top
                                        anchors.topMargin: 2
                                    }

                                    Column {
                                        width: parent.width - 14 - contractButton.width - parent.spacing * 2
                                        spacing: 2

                                        StyledText {
                                            text: modelData.name
                                            textFormat: Text.PlainText
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.family: Theme.monoFontFamily
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                            width: parent.width
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            text: Mcp.formatReviewText(modelData.description || "")
                                            textFormat: Text.PlainText
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                            maximumLineCount: 4
                                            elide: Text.ElideRight
                                            width: parent.width
                                            visible: text.length > 0
                                        }
                                    }

                                    DankButton {
                                        id: contractButton
                                        text: toolCard.contractApproved ? "Approved" : "Review"
                                        iconName: toolCard.contractApproved ? "verified" : "policy"
                                        enabled: aiService.isOllama && aiService.mcpService.isConnected
                                        anchors.verticalCenter: parent.verticalCenter
                                        onClicked: toolCard.reviewingContract = !toolCard.reviewingContract
                                    }
                                }

                                AccordionSection {
                                    show: toolCard.reviewingContract

                                    StyledText {
                                        width: parent.width
                                        text: "Exact approval contract"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 220
                                        radius: Theme.cornerRadius * 0.75
                                        color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.75)
                                        border.color: Theme.outlineMedium
                                        border.width: 1
                                        clip: true

                                        ScrollView {
                                            anchors.fill: parent
                                            anchors.margins: Theme.spacingS
                                            clip: true
                                            ScrollBar.horizontal.policy: ScrollBar.AsNeeded

                                            TextArea {
                                                width: parent.width
                                                text: Mcp.formatToolContract(modelData)
                                                readOnly: true
                                                selectByMouse: true
                                                wrapMode: Text.NoWrap
                                                textFormat: Text.PlainText
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.family: Theme.monoFontFamily
                                                color: Theme.surfaceText
                                                background: null
                                                padding: 0
                                            }
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: "Approval is invalidated automatically if any displayed field changes. Every invocation still requires confirmation."
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }

                                    Row {
                                        anchors.right: parent.right
                                        spacing: Theme.spacingS

                                        DankButton {
                                            text: "Cancel"
                                            onClicked: toolCard.reviewingContract = false
                                        }

                                        DankButton {
                                            text: toolCard.contractApproved ? "Revoke" : "Approve exact contract"
                                            iconName: toolCard.contractApproved ? "remove_moderator" : "verified_user"
                                            backgroundColor: toolCard.contractApproved ? Theme.error : Theme.primary
                                            textColor: Theme.onPrimary
                                            onClicked: {
                                                aiService.setMcpToolApproved(modelData.name, !toolCard.contractApproved);
                                                toolCard.reviewingContract = false;
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
}
