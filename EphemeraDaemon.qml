import QtQuick
import Quickshell
import Quickshell.Io
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

    IpcHandler {
        target: "ephemera"

        function toggle(): string {
            root.toggle();
            return "EPHEMERA_TOGGLE_SUCCESS";
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
            title: ""
            slideoutWidth: 480
            expandable: true
            expandedWidthValue: 960

            content: EphemeraChat {
                aiService: ephemeraService
                slideoutExpandable: slideout.expandable
                slideoutExpanded: slideout.expandedWidth
                onExpandToggled: slideout.expandedWidth = !slideout.expandedWidth
                onHideRequested: slideout.hide()
            }
        }
    }
}
