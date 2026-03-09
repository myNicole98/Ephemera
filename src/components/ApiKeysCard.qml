import QtQuick
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
        text: aiService._keyringAvailable
            ? "Keys are stored encrypted in your system keyring.\nFallback: environment variables."
            : "API keys are read from environment variables.\nThey are never stored on disk."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        width: parent.width
    }

    Column {
        width: parent.width
        spacing: Theme.spacingS

        Repeater {
            // Show key status for providers that need an API key
            model: {
                var providers = Providers.getProviderNames();
                var items = [];
                for (var i = 0; i < providers.length; i++) {
                    var info = Providers.getProviderInfo(providers[i]);
                    if (info.envVar)
                        items.push({ envVar: info.envVar, provider: providers[i] });
                }
                return items;
            }

            Column {
                id: delegate
                required property var modelData
                width: parent.width
                spacing: 0

                property bool _editing: false
                property bool _hasKeyring: aiService.apiKeySource(modelData.provider) === "keyring"

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    Rectangle {
                        width: 8; height: 8; radius: 4
                        color: aiService.hasApiKeyForProvider(modelData.provider) ? Theme.success : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    StyledText {
                        text: modelData.envVar
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.monoFontFamily
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    StyledText {
                        text: {
                            var src = aiService.apiKeySource(modelData.provider);
                            if (src === "keyring") return "(keyring)";
                            if (src === "env") return "(env)";
                            return "";
                        }
                        visible: text.length > 0
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                AccordionSection {
                    show: aiService._keyringAvailable

                    // -- Stored confirmation --
                    Row {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: delegate._hasKeyring && !delegate._editing

                        DankIcon {
                            name: "check_circle"
                            size: 16
                            color: Theme.success
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "Stored in keyring"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Item { width: Theme.spacingXS; height: 1 }

                        DankButton {
                            text: "Replace"
                            onClicked: delegate._editing = true
                        }

                        DankButton {
                            text: "Clear"
                            onClicked: aiService.clearKeyringKey(modelData.provider)
                        }
                    }

                    // -- Key input --
                    Row {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: !delegate._hasKeyring || delegate._editing

                        DankTextField {
                            id: keyInput
                            width: parent.width - saveBtn.width - Theme.spacingS
                                   - (cancelBtn.visible ? cancelBtn.width + Theme.spacingS : 0)
                            placeholderText: delegate._editing ? "Paste new API key" : "Paste API key"
                            echoMode: TextInput.Password
                        }

                        DankButton {
                            id: saveBtn
                            text: "Save"
                            enabled: keyInput.text.trim().length > 0
                            onClicked: {
                                aiService.storeKeyringKey(modelData.provider, keyInput.text.trim());
                                keyInput.text = "";
                                delegate._editing = false;
                            }
                        }

                        DankButton {
                            id: cancelBtn
                            text: "Cancel"
                            visible: delegate._editing
                            onClicked: { delegate._editing = false; keyInput.text = ""; }
                        }
                    }
                }
            }
        }
    }
}
