import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets
import "../lib/Providers.js" as Providers

SettingsCard {
    id: root

    required property var aiService

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
            options: Providers.getProviderNames()
            currentValue: aiService.provider
            onValueChanged: value => {
                aiService.provider = value;
                aiService.saveSettingValue("provider", value);
                aiService.updateBaseUrl();
            }
        }

        // Ollama URL
        AccordionSection {
            show: aiService.provider === "ollama"

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
                    if (!url) { ollamaUrlError.text = ""; return; }
                    var result = Providers.validateUrl(url);
                    if (!result.valid) { ollamaUrlError.text = result.error; return; }
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

        // Ollama thinking mode
        AccordionSection {
            show: aiService.provider === "ollama"

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
                    width: parent.width - parent.spacing - Theme.iconSize

                    StyledText {
                        text: "Ollama Thinking"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        text: "Controls reasoning effort for Ollama models that support it."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }
            }

            DankDropdown {
                width: parent.width
                options: ["Default", "Off", "Low", "Medium", "High"]
                currentValue: root._ollamaThinkingLabel(aiService.ollamaThinkingMode)
                onValueChanged: value => {
                    var mode = root._ollamaThinkingMode(value);
                    aiService.ollamaThinkingMode = mode;
                    aiService.saveSettingValue("ollamaThinkingMode", mode);
                }
            }
        }

        // Custom base URL
        AccordionSection {
            show: aiService.provider === "custom"

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
                    if (!url) { customUrlError.text = ""; return; }
                    var result = Providers.validateUrl(url);
                    if (!result.valid) { customUrlError.text = result.error; return; }
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

        // Extended thinking toggle (Anthropic only)
        AccordionSection {
            show: aiService.provider === "anthropic"

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

        // Model selector
        StyledText {
            text: "Model"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        // Dropdown (shown when provider has model choices)
        AccordionSection {
            show: aiService.modelChoices.length > 0

            DankDropdown {
                width: parent.width
                options: aiService.modelChoices
                currentValue: aiService.model
                onValueChanged: value => {
                    aiService.model = value;
                    aiService.saveSettingValue("model", value);
                }
            }
        }

        // Text field for manual model entry (always visible)
        DankTextField {
            width: parent.width
            text: aiService.model
            placeholderText: {
                var info = Providers.getProviderInfo(aiService.provider);
                return info.modelPlaceholder || "model-name";
            }
            onEditingFinished: {
                aiService.model = text.trim();
                aiService.saveSettingValue("model", text.trim());
            }
        }

        // Ollama action buttons
        AccordionSection {
            show: aiService.provider === "ollama"

            DankButton {
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

    // Validate pending text fields on settings close
    function validatePendingFields() {
        if (aiService.provider === "custom" && customUrlField.text.trim())
            customUrlField.editingFinished();
        if (aiService.provider === "ollama" && ollamaUrlField.text.trim())
            ollamaUrlField.editingFinished();
    }

    function _ollamaThinkingLabel(mode) {
        switch (String(mode || "default").toLowerCase()) {
        case "none": return "Off";
        case "low": return "Low";
        case "medium": return "Medium";
        case "high": return "High";
        default: return "Default";
        }
    }

    function _ollamaThinkingMode(label) {
        switch (label) {
        case "Off": return "none";
        case "Low": return "low";
        case "Medium": return "medium";
        case "High": return "high";
        default: return "default";
        }
    }
}
