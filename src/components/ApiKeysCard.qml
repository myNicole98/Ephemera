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
        text: "API keys are read from environment variables.\nThey are never stored on disk."
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

            Row {
                required property var modelData
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
            }
        }
    }
}
