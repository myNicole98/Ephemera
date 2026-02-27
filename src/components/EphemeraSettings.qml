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

                    // -- Card 1: Provider --
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

                                // Ollama URL — accordion container
                                Item {
                                    width: parent.width
                                    height: aiService.provider === "ollama" ? ollamaUrlCol.implicitHeight : 0
                                    clip: true
                                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                    Column {
                                        id: ollamaUrlCol
                                        width: parent.width
                                        spacing: Theme.spacingS

                                        StyledText {
                                            text: "Ollama URL"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }
                                        DankTextField {
                                            id: ollamaUrlField
                                            width: parent.width
                                            text: aiService.ollamaUrl
                                            placeholderText: "http://localhost:11434"
                                            onEditingFinished: {
                                                var url = text.trim();
                                                if (!url) {
                                                    ollamaUrlError.text = "";
                                                    return;
                                                }
                                                if (url.length > 2048) {
                                                    ollamaUrlError.text = "URL is too long (max 2048 characters).";
                                                    return;
                                                }
                                                if (!/^https?:\/\//i.test(url)) {
                                                    ollamaUrlError.text = "Must start with http:// or https://";
                                                    return;
                                                }
                                                if (!/^https?:\/\/[a-zA-Z0-9\-_.:]/.test(url)) {
                                                    ollamaUrlError.text = "Invalid hostname in URL.";
                                                    return;
                                                }
                                                ollamaUrlError.text = "";
                                                aiService.ollamaUrl = url;
                                                aiService.saveSettingValue("ollamaUrl", url);
                                            }
                                        }

                                        StyledText {
                                            id: ollamaUrlError
                                            width: parent.width
                                            text: ""
                                            visible: text.length > 0
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.error
                                            wrapMode: Text.Wrap
                                        }
                                    }
                                }

                                // Custom base URL — accordion container
                                Item {
                                    width: parent.width
                                    height: aiService.provider === "custom" ? customUrlCol.implicitHeight : 0
                                    clip: true
                                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                    Column {
                                        id: customUrlCol
                                        width: parent.width
                                        spacing: Theme.spacingS

                                        StyledText {
                                            text: "Base URL"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }
                                        DankTextField {
                                            id: customUrlField
                                            width: parent.width
                                            text: aiService.baseUrl
                                            placeholderText: "https://api.openai.com"
                                            onEditingFinished: {
                                                var url = text.trim();
                                                if (!url) {
                                                    customUrlError.text = "";
                                                    return;
                                                }
                                                if (url.length > 2048) {
                                                    customUrlError.text = "URL is too long (max 2048 characters).";
                                                    return;
                                                }
                                                if (!/^https?:\/\//i.test(url)) {
                                                    customUrlError.text = "Must start with http:// or https://";
                                                    return;
                                                }
                                                if (!/^https?:\/\/[a-zA-Z0-9\-_.:]/.test(url)) {
                                                    customUrlError.text = "Invalid hostname in URL.";
                                                    return;
                                                }
                                                customUrlError.text = "";
                                                aiService.baseUrl = url;
                                                aiService.saveSettingValue("customBaseUrl", url);
                                            }
                                        }

                                        StyledText {
                                            id: customUrlError
                                            width: parent.width
                                            text: ""
                                            visible: text.length > 0
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.error
                                            wrapMode: Text.Wrap
                                        }
                                    }
                                }

                                // Extended thinking toggle — accordion (Anthropic only)
                                Item {
                                    width: parent.width
                                    height: aiService.provider === "anthropic" ? thinkingCol.implicitHeight : 0
                                    clip: true
                                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                    Column {
                                        id: thinkingCol
                                        width: parent.width
                                        spacing: Theme.spacingS

                                        Row {
                                            width: parent.width
                                            spacing: Theme.spacingM

                                            DankIcon {
                                                name: "psychology"
                                                size: Theme.iconSize
                                                color: Theme.primary
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            Column {
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: Theme.spacingXS
                                                width: parent.width - parent.spacing * 2 - Theme.iconSize - thinkingToggle.width

                                                StyledText {
                                                    text: "Extended Thinking"
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    font.weight: Font.Medium
                                                    color: Theme.surfaceText
                                                }

                                                StyledText {
                                                    text: "Forces temperature to 1. Supported on claude-3.7-sonnet and newer."
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                    wrapMode: Text.WordWrap
                                                    width: parent.width
                                                }
                                            }

                                            Switch {
                                                id: thinkingToggle
                                                checked: aiService.thinkingEnabled
                                                anchors.verticalCenter: parent.verticalCenter
                                                onToggled: {
                                                    aiService.thinkingEnabled = checked;
                                                    aiService.saveSettingValue("thinkingEnabled", checked);
                                                }
                                            }
                                        }
                                    }
                                }

                                // Model selector
                                StyledText {
                                    text: "Model"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                // Dropdown for Ollama — accordion
                                Item {
                                    width: parent.width
                                    height: (aiService.provider === "ollama" && aiService.availableModels.count > 0) ? ollamaModelDropdown.implicitHeight : 0
                                    clip: true
                                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                    DankDropdown {
                                        id: ollamaModelDropdown
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
                                }

                                // Text field for non-Ollama or no models — accordion
                                Item {
                                    width: parent.width
                                    height: (aiService.provider !== "ollama" || aiService.availableModels.count === 0) ? modelTextField.implicitHeight : 0
                                    clip: true
                                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                    DankTextField {
                                        id: modelTextField
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
                                }

                                // Ollama action buttons — accordion (Ollama only)
                                Item {
                                    width: parent.width
                                    height: aiService.provider === "ollama" ? ollamaActionsCol.implicitHeight : 0
                                    clip: true
                                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                    Column {
                                        id: ollamaActionsCol
                                        width: parent.width
                                        spacing: Theme.spacingS

                                        DankButton {
                                            id: refreshBtn
                                            text: "Refresh Models"
                                            iconName: "refresh"
                                            width: parent.width
                                            enabled: aiService.ollamaReady
                                            onClicked: aiService.discoverModels()
                                        }

                                        DankButton {
                                            text: aiService.ollamaReady ? "Stop Ollama" : "Start Ollama"
                                            iconName: aiService.ollamaReady ? "stop" : "power"
                                            width: parent.width
                                            backgroundColor: aiService.ollamaReady ? Theme.error : Theme.primary
                                            textColor: Theme.onPrimary
                                            onClicked: {
                                                if (aiService.ollamaReady) {
                                                    if (aiService.ollamaWeStarted)
                                                        aiService.shutdownOllama();
                                                    else
                                                        aiService.forceShutdownExternalOllama();
                                                } else {
                                                    aiService.ensureOllamaReady();
                                                }
                                            }
                                        }

                                        // Idle auto-stop timeout
                                        Row {
                                            width: parent.width
                                            spacing: Theme.spacingM

                                            DankIcon {
                                                name: "timer_off"
                                                size: Theme.iconSize
                                                color: Theme.primary
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            Column {
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: Theme.spacingXS
                                                width: parent.width - parent.spacing - Theme.iconSize

                                                StyledText {
                                                    text: "Idle Auto-Stop: " + (aiService.ollamaIdleMinutes === 0 ? "Never" : aiService.ollamaIdleMinutes + " min")
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    font.weight: Font.Medium
                                                    color: Theme.surfaceText
                                                }

                                                StyledText {
                                                    text: "Auto-stop Ollama after inactivity (only if we started it)"
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                    wrapMode: Text.WordWrap
                                                    width: parent.width
                                                }
                                            }
                                        }

                                        DankDropdown {
                                            width: parent.width
                                            options: ["Never", "5 min", "10 min", "15 min", "30 min"]
                                            currentValue: {
                                                switch (aiService.ollamaIdleMinutes) {
                                                case 0: return "Never";
                                                case 5: return "5 min";
                                                case 10: return "10 min";
                                                case 15: return "15 min";
                                                case 30: return "30 min";
                                                default: return "5 min";
                                                }
                                            }
                                            onValueChanged: value => {
                                                var map = { "Never": 0, "5 min": 5, "10 min": 10, "15 min": 15, "30 min": 30 };
                                                var mins = map[value] !== undefined ? map[value] : 5;
                                                aiService.ollamaIdleMinutes = mins;
                                                aiService.saveSettingValue("ollamaIdleMinutes", mins);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // -- Card 2: Model Parameters --
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
                                DankDropdown {
                                    width: parent.width
                                    options: ["None", "Concise", "Code Expert", "Translator", "Writing Editor", "(custom)"]
                                    currentValue: "None"
                                    onValueChanged: value => {
                                        var presets = {
                                            "None": "",
                                            "Concise": "Be concise. Answer in as few words as possible while remaining helpful and accurate.",
                                            "Code Expert": "You are an expert programmer. Provide clean, well-structured code with brief explanations. Prefer practical solutions.",
                                            "Translator": "You are a translator. Translate the user's text to the target language they specify. If no language is specified, translate to English.",
                                            "Writing Editor": "You are a writing editor. Improve clarity, grammar, and flow while preserving the author's voice and intent."
                                        };
                                        if (presets.hasOwnProperty(value)) {
                                            aiService.systemPrompt = presets[value];
                                            aiService.saveSettingValue("systemPrompt", presets[value]);
                                        }
                                    }
                                }
                                Rectangle {
                                    width: parent.width
                                    height: Math.max(80, Math.min(160, systemPromptArea.contentHeight + Theme.spacingM * 2))
                                    radius: Theme.cornerRadius
                                    color: Theme.surfaceContainerHigh
                                    border.color: systemPromptArea.activeFocus ? Theme.primary : Theme.outlineMedium
                                    border.width: systemPromptArea.activeFocus ? 2 : 1

                                    Behavior on height {
                                        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                                    }

                                    ScrollView {
                                        anchors.fill: parent
                                        anchors.margins: Theme.spacingS
                                        clip: true
                                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                                        TextArea {
                                            id: systemPromptArea
                                            text: aiService.systemPrompt
                                            placeholderText: "You are a helpful assistant."
                                            wrapMode: TextArea.Wrap
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.family: Theme.fontFamily
                                            color: Theme.surfaceText
                                            background: null
                                            padding: 0

                                            onEditingFinished: {
                                                aiService.systemPrompt = text;
                                                aiService.saveSettingValue("systemPrompt", text);
                                            }
                                        }
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
                                    maximum: 100
                                    value: aiService.maxTurns
                                    showValue: false
                                    onSliderValueChanged: newValue => {
                                        aiService.maxTurns = newValue;
                                        aiService.saveSettingValue("maxTurns", newValue);
                                    }
                                }

                                // Request Timeout
                                Item { width: 1; height: Theme.spacingXS }
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "timer"
                                        size: Theme.iconSize
                                        color: Theme.primary
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXS
                                        width: parent.width - parent.spacing - Theme.iconSize

                                        StyledText {
                                            text: "Request Timeout: " + aiService.timeout + "s"
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            text: "Max time for a streaming response"
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
                                    minimum: 30
                                    maximum: 600
                                    step: 30
                                    value: aiService.timeout
                                    showValue: false
                                    onSliderValueChanged: newValue => {
                                        aiService.timeout = newValue;
                                        aiService.saveSettingValue("timeout", newValue);
                                    }
                                }
                            }
                        }
                    }

                    // -- Card 3: API Keys (info only) --
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

                    // -- Card 4: Chat History --
                    Rectangle {
                        width: parent.width
                        height: persistContent.height + Theme.spacingL * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                        border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.08)
                        border.width: 1

                        Column {
                            id: persistContent
                            width: parent.width - Theme.spacingL * 2
                            anchors.centerIn: parent
                            spacing: Theme.spacingM

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "save"
                                    size: Theme.iconSize
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXS
                                    width: parent.width - parent.spacing * 2 - Theme.iconSize - persistToggle.width

                                    StyledText {
                                        text: "Save Chat History"
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }

                                    StyledText {
                                        text: "Persist conversations across sessions. API keys are never stored."
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                        width: parent.width
                                    }
                                }

                                Switch {
                                    id: persistToggle
                                    checked: aiService.persistChat
                                    anchors.verticalCenter: parent.verticalCenter
                                    onToggled: {
                                        aiService.persistChat = checked;
                                        aiService.saveSettingValue("persistChat", checked);
                                        if (checked) aiService.saveChatHistory();
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
