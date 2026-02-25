import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import qs.Common
import qs.Widgets
import "./Markdown.js" as Markdown

Item {
    id: root
    property string role: "assistant"
    property string text: ""
    property string thinking: ""
    property bool thinkingExpanded: false
    property string status: "ok" // ok|streaming|error
    property string modelName: "Assistant"

    readonly property bool isUser: role === "user"
    readonly property real bubbleMaxWidth: isUser ? Math.max(240, Math.floor(width * 0.82)) : width
    readonly property color userBubbleFill: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1)
    readonly property color userBubbleBorder: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.3)
    readonly property color assistantBubbleFill: Theme.surfaceContainer
    readonly property color assistantBubbleBorder: Theme.outline

    readonly property var themeColors: ({
        "codeBg": Theme.surfaceContainerHigh,
        "blockquoteBg": Theme.withAlpha(Theme.surfaceContainerHighest, 0.5),
        "blockquoteBorder": Theme.outlineVariant,
        "inlineCodeBg": Theme.withAlpha(Theme.onSurface, 0.1)
    })

    readonly property bool useMarkdownRendering: !isUser && status !== "streaming"
    readonly property string renderedHtml: Markdown.markdownToHtml(root.text, themeColors)

    onTextChanged: {
        if (status === "streaming" && thinking.length > 0 && text.length > 0 && thinkingExpanded) {
            thinkingExpanded = false;
        }
    }
    onThinkingChanged: {
        if (thinkingExpanded) {
            Qt.callLater(function() {
                if (thinkingFlickable.contentHeight > thinkingFlickable.height) {
                    thinkingFlickable.contentY = thinkingFlickable.contentHeight - thinkingFlickable.height;
                }
            });
        }
    }

    width: parent ? parent.width : implicitWidth
    implicitHeight: bubble.implicitHeight

    // Error shake transform
    transform: Translate {
        id: shakeTranslate

        SequentialAnimation on x {
            id: shakeAnim
            running: false
            NumberAnimation { to: -4; duration: 50; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 4; duration: 50; easing.type: Easing.InOutQuad }
            NumberAnimation { to: -3; duration: 50; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 3; duration: 50; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0; duration: 50; easing.type: Easing.OutQuad }
        }
    }

    onStatusChanged: {
        if (status === "error") shakeAnim.start();
    }

    Rectangle {
        id: bubble
        width: Math.min(root.bubbleMaxWidth, root.width)
        x: root.isUser ? (root.width - width) : 0
        radius: Theme.cornerRadius
        color: {
            if (root.isUser) return root.userBubbleFill;
            return hoverHandler.hovered ? Qt.lighter(root.assistantBubbleFill, 1.08) : root.assistantBubbleFill;
        }
        border.color: status === "error" ? Theme.error : (root.isUser ? root.userBubbleBorder : root.assistantBubbleBorder)
        border.width: 1

        implicitHeight: contentColumn.implicitHeight + Theme.spacingM * 2
        height: implicitHeight

        Behavior on color {
            ColorAnimation { duration: 150; easing.type: Easing.OutCubic }
        }

        Behavior on x {
            NumberAnimation {
                duration: 120
                easing.type: Easing.OutCubic
            }
        }

        HoverHandler {
            id: hoverHandler
        }

        // Click anywhere on bubble to toggle thinking during streaming
        MouseArea {
            anchors.fill: parent
            enabled: root.status === "streaming" && root.thinking.length > 0
            visible: enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: root.thinkingExpanded = !root.thinkingExpanded
        }

        Column {
            id: contentColumn
            x: Theme.spacingM
            y: Theme.spacingM
            width: parent.width - Theme.spacingM * 2
            spacing: Theme.spacingS

            RowLayout {
                id: headerRow
                width: parent.width
                spacing: Theme.spacingXS

                Item { Layout.fillWidth: root.isUser }

                Rectangle {
                    radius: Theme.cornerRadius
                    color: root.isUser ? Theme.withAlpha(Theme.primary, 0.14) : Theme.surfaceVariant
                    Layout.preferredHeight: Theme.fontSizeSmall * 1.6
                    Layout.preferredWidth: Math.min(headerText.implicitWidth + Theme.spacingS * 2, 160)
                    clip: true

                    StyledText {
                        id: headerText
                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingS * 2
                        text: root.isUser ? "You" : root.modelName
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: root.isUser ? Theme.primary : Theme.surfaceVariantText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                Rectangle {
                    width: 18
                    height: 18
                    radius: 9
                    color: root.isUser ? Theme.withAlpha(Theme.primary, 0.20) : Theme.surfaceVariant
                    border.width: 1
                    border.color: root.isUser ? Theme.withAlpha(Theme.primary, 0.35) : Theme.surfaceVariantAlpha

                    DankIcon {
                        anchors.centerIn: parent
                        name: root.isUser ? "person" : "smart_toy"
                        size: 14
                        color: root.isUser ? Theme.primary : Theme.surfaceVariantText
                    }
                }

                Item { Layout.fillWidth: !root.isUser }

                DankActionButton {
                    visible: !root.isUser && root.status === "ok"
                    opacity: hoverHandler.hovered ? 1.0 : 0.0
                    iconName: "content_copy"
                    buttonSize: 24
                    iconSize: 14
                    backgroundColor: "transparent"
                    iconColor: Theme.surfaceVariantText
                    tooltipText: "Copy"
                    onClicked: {
                        Quickshell.execDetached(["wl-copy", root.text]);
                    }

                    Behavior on opacity {
                        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                    }
                }
            }

            // Header-content separator
            Rectangle {
                width: parent.width
                height: 1
                color: Theme.withAlpha(Theme.outline, 0.15)
            }

            // Thinking section (only visible when thinking exists)
            Column {
                width: parent.width
                visible: root.thinking.length > 0
                spacing: Theme.spacingXS

                MouseArea {
                    width: parent.width
                    height: thinkingHeader.implicitHeight
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.thinkingExpanded = !root.thinkingExpanded

                    Row {
                        id: thinkingHeader
                        spacing: Theme.spacingXS

                        DankIcon {
                            name: "psychology"
                            size: 14
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        DankIcon {
                            name: root.thinkingExpanded ? "expand_more" : "chevron_right"
                            size: 14
                            color: Theme.surfaceTextMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "Thinking" + (root.status === "streaming" && root.text.length === 0 ? "..." : "")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.surfaceTextMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                Flickable {
                    id: thinkingFlickable
                    visible: root.thinkingExpanded
                    width: parent.width
                    height: Math.min(contentHeight, 200)
                    contentHeight: thinkingTextArea.implicitHeight
                    clip: true
                    flickableDirection: Flickable.VerticalFlick

                    TextArea {
                        id: thinkingTextArea
                        width: thinkingFlickable.width
                        text: root.thinking
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceTextMedium
                        readOnly: true
                        selectByMouse: true
                        background: null
                        leftPadding: 4
                        rightPadding: 4
                    }

                    ScrollBar.vertical: ScrollBar {}
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.withAlpha(Theme.outline, 0.10)
                    visible: root.thinkingExpanded
                }
            }

            StyledText {
                visible: root.status === "error"
                text: "Error"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.error
                width: parent.width
            }

            TextArea {
                text: root.useMarkdownRendering ? root.renderedHtml : root.text
                textFormat: root.useMarkdownRendering ? Text.RichText : Text.PlainText
                wrapMode: Text.Wrap
                font.pixelSize: Theme.fontSizeMedium
                font.family: Theme.fontFamily
                color: status === "error" ? Theme.error : Theme.surfaceText
                width: parent.width

                readOnly: true
                selectByMouse: true
                selectionColor: Theme.primary
                selectedTextColor: Theme.onPrimary
                background: null
                leftPadding: 4
                rightPadding: 4

                onLinkActivated: link => {
                    // Only allow http/https — security fix
                    if (/^https?:\/\//i.test(link))
                        Qt.openUrlExternally(link);
                }

                hoverEnabled: true
            }

            // Pulsing streaming dots (clickable to toggle thinking)
            Item {
                visible: status === "streaming"
                width: streamingRow.width
                height: visible ? streamingRow.height : 0
                x: root.isUser ? (parent.width - width) : 0

                Row {
                    id: streamingRow
                    spacing: 6
                    height: Theme.fontSizeSmall * 1.6

                    DankIcon {
                        visible: root.thinking.length > 0
                        name: "psychology"
                        size: 16
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: root.thinkingExpanded ? 0.5 : 1.0

                        Behavior on opacity {
                            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                        }
                    }

                    Repeater {
                        model: 3
                        Rectangle {
                            width: 7
                            height: 7
                            radius: 3.5
                            color: Theme.primary
                            opacity: 0.4
                            scale: 1.0
                            anchors.verticalCenter: parent.verticalCenter

                            SequentialAnimation on opacity {
                                loops: Animation.Infinite
                                PauseAnimation { duration: index * 160 }
                                NumberAnimation { to: 1.0; duration: 400; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 0.4; duration: 400; easing.type: Easing.InOutSine }
                                PauseAnimation { duration: (2 - index) * 160 }
                            }

                            SequentialAnimation on scale {
                                loops: Animation.Infinite
                                PauseAnimation { duration: index * 160 }
                                NumberAnimation { to: 1.4; duration: 400; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: 400; easing.type: Easing.InOutSine }
                                PauseAnimation { duration: (2 - index) * 160 }
                            }
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: root.thinking.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (root.thinking.length > 0)
                            root.thinkingExpanded = !root.thinkingExpanded;
                    }
                }
            }
        }
    }
}
