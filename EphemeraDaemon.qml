import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Services
import "."

Item {
    id: root

    property var pluginService: null
    property string pluginId: "ephemera"

    function toggle() {
        if (variants.instances.length > 0) {
            variants.instances[0].toggle();
        }
    }

    EphemeraService {
        id: ephemeraService
        pluginId: root.pluginId
    }

    Variants {
        id: variants
        model: Quickshell.screens

        delegate: DankSlideout {
            id: slideout
            required property var modelData
            title: "Ephemera"
            slideoutWidth: 480
            expandable: true
            expandedWidthValue: 960

            content: EphemeraChat {
                aiService: ephemeraService
                onHideRequested: slideout.hide()
            }
        }
    }
}
