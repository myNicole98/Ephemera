import QtQuick
import qs.Common

Rectangle {
    id: root

    property string iconName: ""
    property string title: ""
    default property alias content: innerColumn.children

    width: parent ? parent.width : implicitWidth
    height: innerColumn.height + Theme.spacingL * 2
    radius: Theme.cornerRadius
    color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
    border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.08)
    border.width: 1

    Column {
        id: innerColumn
        width: parent.width - Theme.spacingL * 2
        anchors.centerIn: parent
        spacing: Theme.spacingM
    }
}
