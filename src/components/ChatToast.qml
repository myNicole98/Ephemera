import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root

    property real bottomMargin: 0

    function show(message) {
        _toastMessage = message;
        toast.opacity = 1;
        toastTimer.restart();
    }

    property string _toastMessage: ""

    Rectangle {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.bottomMargin
        width: toastText.implicitWidth + Theme.spacingL * 2
        height: 36
        radius: 18
        color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.95)
        border.color: Theme.outline
        border.width: 1
        visible: opacity > 0
        opacity: 0
        z: 100

        Behavior on opacity {
            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }

        StyledText {
            id: toastText
            anchors.centerIn: parent
            text: root._toastMessage
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
        }

        Timer {
            id: toastTimer
            interval: 2000
            onTriggered: toast.opacity = 0
        }
    }
}
