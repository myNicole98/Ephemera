import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Widgets
import qs.Services

Item {
    id: root
    property bool isVisible: false
    signal closeRequested

    required property var aiService

    visible: isVisible

    readonly property bool hasOpenaiKey: (Quickshell.env("OPENAI_API_KEY") || "").length > 0
    readonly property bool hasAnthropicKey: (Quickshell.env("ANTHROPIC_API_KEY") || "").length > 0
    readonly property bool hasGeminiKey: (Quickshell.env("GEMINI_API_KEY") || "").length > 0

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.98)
        radius: Theme.cornerRadius
        border.color: Theme.surfaceVariantAlpha
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            // Header
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingL

                StyledText {
                    text: "Ephemera Settings"
                    font.pixelSize: Theme.fontSizeLarge
                    color: Theme.surfaceText
                    font.weight: Font.Medium
                    Layout.alignment: Qt.AlignVCenter
                }

                Item { Layout.fillWidth: true }

                DankButton {
                    text: "Close"
                    iconName: "close"
                    onClicked: closeRequested()
                }
            }

            DankFlickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentHeight: settingsColumn.implicitHeight + Theme.spacingXL
                contentWidth: width

                Column {
                    id: settingsColumn
                    width: Math.min(550, parent.width - Theme.spacingL * 2)
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.spacingL

                    // ── Card 1: Provider ─────────────────────────────────
                    Rectangle {
                        width: parent.width
                        height: providerContent.height + Theme.spacingL * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                        border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.08)
                        border.width: 1

                        Column {
                            id: providerContent
                            width: parent.width - Theme.spacingL * 2
                            anchors.centerIn: parent
                            spacing: Theme.spacingM

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "dns"
                                    size: Theme.iconSize
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Provider"
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.spacingS

                                StyledText {
                                    text: "Provider"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                DankDropdown {
                                    width: parent.width
                                    options: ["ollama", "openai", "anthropic", "gemini", "custom"]
                                    currentValue: aiService.provider
                                    onValueChanged: value => {
                                        aiService.provider = value;
                                        aiService.saveSettingValue("provider", value);
                                        aiService.updateBaseUrl();
                                    }
                                }

                                // Ollama URL (only visible for Ollama)
                                StyledText {
                                    visible: aiService.provider === "ollama"
                                    text: "Ollama URL"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                DankTextField {
                                    visible: aiService.provider === "ollama"
                                    width: parent.width
                                    text: aiService.ollamaUrl
                                    placeholderText: "http://localhost:11434"
                                    onEditingFinished: {
                                        aiService.ollamaUrl = text.trim();
                                        aiService.saveSettingValue("ollamaUrl", text.trim());
                                    }
                                }

                                // Custom base URL (only for custom provider)
                                StyledText {
                                    visible: aiService.provider === "custom"
                                    text: "Base URL"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                DankTextField {
                                    visible: aiService.provider === "custom"
                                    width: parent.width
                                    text: aiService.baseUrl
                                    placeholderText: "https://api.openai.com"
                                    onEditingFinished: {
                                        aiService.baseUrl = text.trim();
                                        aiService.saveSettingValue("customBaseUrl", text.trim());
                                    }
                                }

                                // Model selector
                                StyledText {
                                    text: "Model"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                // Dropdown for Ollama (auto-discovered models)
                                DankDropdown {
                                    visible: aiService.provider === "ollama" && aiService.availableModels.count > 0
                                    width: parent.width
                                    options: {
                                        var opts = [];
                                        for (var i = 0; i < aiService.availableModels.count; i++) {
                                            opts.push(aiService.availableModels.get(i).name);
                                        }
                                        return opts;
                                    }
                                    currentValue: aiService.model
                                    onValueChanged: value => {
                                        aiService.model = value;
                                        aiService.saveSettingValue("model", value);
                                    }
                                }

                                // Text field for non-Ollama or when no models discovered
                                DankTextField {
                                    visible: aiService.provider !== "ollama" || aiService.availableModels.count === 0
                                    width: parent.width
                                    text: aiService.model
                                    placeholderText: {
                                        switch (aiService.provider) {
                                        case "openai": return "gpt-4o";
                                        case "anthropic": return "claude-sonnet-4-5";
                                        case "gemini": return "gemini-2.5-flash";
                                        default: return "model-name";
                                        }
                                    }
                                    onEditingFinished: {
                                        aiService.model = text.trim();
                                        aiService.saveSettingValue("model", text.trim());
                                    }
                                }

                                // Refresh models button (Ollama only)
                                DankButton {
                                    visible: aiService.provider === "ollama"
                                    text: "Refresh Models"
                                    iconName: "refresh"
                                    width: parent.width
                                    enabled: aiService.ollamaReady
                                    onClicked: aiService.discoverModels()
                                }
                            }
                        }
                    }

                    // ── Card 2: Model Parameters ─────────────────────────
                    Rectangle {
                        width: parent.width
                        height: paramsContent.height + Theme.spacingL * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                        border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.08)
                        border.width: 1

                        Column {
                            id: paramsContent
                            width: parent.width - Theme.spacingL * 2
                            anchors.centerIn: parent
                            spacing: Theme.spacingM

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "tune"
                                    size: Theme.iconSize
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Model Parameters"
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.spacingS

                                // System prompt
                                StyledText {
                                    text: "System Prompt"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                DankTextField {
                                    width: parent.width
                                    text: aiService.systemPrompt
                                    placeholderText: "You are a helpful assistant."
                                    onEditingFinished: {
                                        aiService.systemPrompt = text;
                                        aiService.saveSettingValue("systemPrompt", text);
                                    }
                                }

                                // Temperature
                                Item { width: 1; height: Theme.spacingXS }
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "thermostat"
                                        size: Theme.iconSize
                                        color: Theme.primary
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXS
                                        width: parent.width - parent.spacing - Theme.iconSize

                                        StyledText {
                                            text: "Temperature: " + aiService.temperature.toFixed(1)
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            text: "Controls randomness (0 = focused, 2 = creative)"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                            width: parent.width
                                        }
                                    }
                                }

                                DankSlider {
                                    width: parent.width
                                    height: 32
                                    minimum: 0
                                    maximum: 20
                                    value: Math.round(aiService.temperature * 10)
                                    showValue: false
                                    onSliderValueChanged: newValue => {
                                        aiService.temperature = newValue / 10;
                                        aiService.saveSettingValue("temperature", newValue / 10);
                                    }
                                }

                                // Max Tokens
                                Item { width: 1; height: Theme.spacingXS }
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "data_usage"
                                        size: Theme.iconSize
                                        color: Theme.primary
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXS
                                        width: parent.width - parent.spacing - Theme.iconSize

                                        StyledText {
                                            text: "Max Tokens: " + aiService.maxTokens
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            text: "Maximum response length"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                            width: parent.width
                                        }
                                    }
                                }

                                DankSlider {
                                    width: parent.width
                                    height: 32
                                    minimum: 256
                                    maximum: 16384
                                    step: 256
                                    value: aiService.maxTokens
                                    showValue: false
                                    onSliderValueChanged: newValue => {
                                        aiService.maxTokens = newValue;
                                        aiService.saveSettingValue("maxTokens", newValue);
                                    }
                                }

                                // Max Context Turns
                                Item { width: 1; height: Theme.spacingXS }
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "history"
                                        size: Theme.iconSize
                                        color: Theme.primary
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXS
                                        width: parent.width - parent.spacing - Theme.iconSize

                                        StyledText {
                                            text: "Context Turns: " + aiService.maxTurns
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            text: "Recent conversation turns sent to API"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                            width: parent.width
                                        }
                                    }
                                }

                                DankSlider {
                                    width: parent.width
                                    height: 32
                                    minimum: 2
                                    maximum: 40
                                    value: aiService.maxTurns
                                    showValue: false
                                    onSliderValueChanged: newValue => {
                                        aiService.maxTurns = newValue;
                                        aiService.saveSettingValue("maxTurns", newValue);
                                    }
                                }
                            }
                        }
                    }

                    // ── Card 3: API Keys (info only) ─────────────────────
                    Rectangle {
                        width: parent.width
                        height: keysContent.height + Theme.spacingL * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                        border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.08)
                        border.width: 1

                        Column {
                            id: keysContent
                            width: parent.width - Theme.spacingL * 2
                            anchors.centerIn: parent
                            spacing: Theme.spacingM

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "vpn_key"
                                    size: Theme.iconSize
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "API Keys"
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            StyledText {
                                text: "API keys are read from environment variables.\nThey are never stored on disk."
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.spacingS

                                // OpenAI
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    Rectangle {
                                        width: 8; height: 8; radius: 4
                                        color: root.hasOpenaiKey ? Theme.success : Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    StyledText {
                                        text: "OPENAI_API_KEY"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: Theme.monoFontFamily
                                        color: Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                // Anthropic
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    Rectangle {
                                        width: 8; height: 8; radius: 4
                                        color: root.hasAnthropicKey ? Theme.success : Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    StyledText {
                                        text: "ANTHROPIC_API_KEY"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: Theme.monoFontFamily
                                        color: Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                // Gemini
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    Rectangle {
                                        width: 8; height: 8; radius: 4
                                        color: root.hasGeminiKey ? Theme.success : Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    StyledText {
                                        text: "GEMINI_API_KEY"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: Theme.monoFontFamily
                                        color: Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
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
