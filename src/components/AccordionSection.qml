import QtQuick
import qs.Common

Item {
    id: root

    property bool show: true
    default property alias content: innerColumn.children

    width: parent ? parent.width : implicitWidth
    height: show ? innerColumn.implicitHeight : 0
    clip: true

    Behavior on height {
        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }

    Column {
        id: innerColumn
        width: parent.width
        spacing: Theme.spacingS
    }
}
