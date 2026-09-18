import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.qfield
import org.qgis
import Theme

// Кнопка на панели инструментов + диалоги для управления сменой работника:
// выход на линию, пауза (с причиной), возобновление, завершение смены.
// Состояние смены хранится на сервере (SQLite). Модуль Qt.labs.settings
// не входит в сборку QML-движка QField, поэтому локально ничего не
// сохраняем — вместо этого при старте смены сервер сам находит уже
// открытую смену работника по имени (/shift/active) и /shift/start не
// создаёт дубликат, если смена уже идёт. lastWorkerName живёт только в
// памяти текущего запуска — просто чтобы не перепечатывать имя лишний раз.
Button {
    id: shiftPanelRoot
    property var pluginRootRef: null
    property string lastWorkerName: ""

    text: statusText()

    function statusText() {
        var shift = pluginRootRef ? pluginRootRef.currentShift : null
        if (!shift) return "🔴 Не на линии"
        if (shift.status === "active") return "🟢 " + shift.worker_name
        if (shift.status === "paused") return "⏸ " + shift.worker_name
        return "🔴 Не на линии"
    }

    onClicked: {
        var shift = pluginRootRef ? pluginRootRef.currentShift : null
        if (!shift || shift.status === undefined) {
            startNameField.text = shiftPanelRoot.lastWorkerName
            startShiftDialog.open()
        } else {
            shiftMenu.open()
        }
    }

    Menu {
        id: shiftMenu
        MenuItem {
            text: (pluginRootRef && pluginRootRef.currentShift && pluginRootRef.currentShift.status === "paused")
                  ? "▶ Возобновить работу"
                  : "⏸ Поставить на паузу"
            onTriggered: {
                if (pluginRootRef.currentShift.status === "paused") {
                    resumeShift()
                } else {
                    pauseReasonCombo.currentIndex = 0
                    pauseCustomField.text = ""
                    pauseShiftDialog.open()
                }
            }
        }
        MenuItem {
            text: "🔴 Завершить смену"
            onTriggered: endShiftDialog.open()
        }
    }

    // ---- HTTP helpers -----------------------------------------------

    function serverBase() {
        return pluginRootRef ? pluginRootRef.serverBase : ""
    }

    function postJson(path, payload, onDone) {
        try {
            var xhr = new XMLHttpRequest()
            xhr.open("POST", serverBase() + path, true)
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.timeout = 10000
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    var obj = null
                    try { obj = JSON.parse(xhr.responseText) } catch(e) {}
                    onDone(xhr.status === 200, obj, xhr)
                }
            }
            xhr.send(JSON.stringify(payload))
        } catch(e) {
            iface.mainWindow().displayToast("❌ Ошибка запроса к серверу: " + e)
        }
    }

    function getJson(path, onDone) {
        try {
            var xhr = new XMLHttpRequest()
            xhr.open("GET", serverBase() + path, true)
            xhr.timeout = 10000
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    var obj = null
                    try { obj = JSON.parse(xhr.responseText) } catch(e) {}
                    onDone(xhr.status === 200, obj, xhr)
                }
            }
            xhr.send()
        } catch(e) {
            iface.mainWindow().displayToast("❌ Ошибка запроса к серверу: " + e)
        }
    }

    // ---- Восстановление состояния (в рамках текущего запуска QField) --

    function tryRestoreShift() {
        if (!shiftPanelRoot.lastWorkerName) return
        getJson("/shift/active?worker_name=" + encodeURIComponent(shiftPanelRoot.lastWorkerName), function(ok, obj) {
            if (ok && obj && obj.status === "ok" && obj.shift) {
                pluginRootRef.currentShift = obj.shift
                pluginRootRef.refreshTasks()
            }
        })
    }

    Component.onCompleted: {
        if (pluginRootRef) tryRestoreShift()
    }

    // ---- Действия -----------------------------------------------------

    function startShift(name) {
        postJson("/shift/start", { "worker_name": name }, function(ok, obj) {
            if (ok && obj && obj.status === "ok") {
                pluginRootRef.currentShift = obj.shift
                shiftPanelRoot.lastWorkerName = name
                iface.mainWindow().displayToast("🟢 На линии: " + name)
                pluginRootRef.refreshTasks()
            } else {
                iface.mainWindow().displayToast("❌ Не удалось выйти на линию: " + (obj ? obj.message : "нет связи с сервером"))
            }
        })
    }

    function pauseShift(reason) {
        var shift = pluginRootRef.currentShift
        if (!shift) return
        postJson("/shift/pause", { "shift_id": shift.id, "reason": reason }, function(ok, obj) {
            if (ok) {
                pluginRootRef.currentShift = Object.assign({}, pluginRootRef.currentShift, { status: "paused" })
                iface.mainWindow().displayToast("⏸ Смена на паузе: " + reason)
                pluginRootRef.refreshTasks()
            } else {
                iface.mainWindow().displayToast("❌ Не удалось поставить смену на паузу: " + (obj ? obj.message : "нет связи с сервером"))
            }
        })
    }

    function resumeShift() {
        var shift = pluginRootRef.currentShift
        if (!shift) return
        postJson("/shift/resume", { "shift_id": shift.id }, function(ok, obj) {
            if (ok) {
                pluginRootRef.currentShift = Object.assign({}, pluginRootRef.currentShift, { status: "active" })
                iface.mainWindow().displayToast("🟢 Работа возобновлена")
                pluginRootRef.refreshTasks()
            } else {
                iface.mainWindow().displayToast("❌ Не удалось возобновить смену: " + (obj ? obj.message : "нет связи с сервером"))
            }
        })
    }

    function endShift() {
        var shift = pluginRootRef.currentShift
        if (!shift) return
        postJson("/shift/end", { "shift_id": shift.id }, function(ok, obj) {
            if (ok) {
                pluginRootRef.currentShift = null
                var vkOk = obj && obj.vk && obj.vk.sent
                iface.mainWindow().displayToast(vkOk
                    ? "🔴 Смена завершена, отчёт отправлен в VK"
                    : "🔴 Смена завершена (отчёт в VK не отправлен: " + (obj && obj.vk ? obj.vk.error : "?") + ")")
                pluginRootRef.refreshTasks()
            } else {
                iface.mainWindow().displayToast("❌ Не удалось завершить смену: " + (obj ? obj.message : "нет связи с сервером"))
            }
        })
    }

    // ---- Диалог: выход на линию ---------------------------------------

    Dialog {
        id: startShiftDialog
        parent: iface.mainWindow().contentItem
        modal: true
        title: "Выход на линию"
        standardButtons: Dialog.NoButton
        x: (parent.width - width) / 2
        y: (parent.height - height) / 2
        width: Math.min(parent.width * 0.9, 420)

        ColumnLayout {
            width: parent.width
            spacing: 10

            Label { text: "ФИО работника *"; font.bold: true }
            TextField {
                id: startNameField
                Layout.fillWidth: true
                placeholderText: "Иванов Иван Иванович"
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                Item { Layout.fillWidth: true }
                Button {
                    text: "Отмена"
                    flat: true
                    onClicked: startShiftDialog.close()
                }
                Button {
                    text: "Выйти на линию"
                    highlighted: true
                    enabled: startNameField.text.trim().length > 0
                    onClicked: {
                        startShift(startNameField.text.trim())
                        startShiftDialog.close()
                    }
                }
            }
        }
    }

    // ---- Диалог: пауза смены -------------------------------------------

    Dialog {
        id: pauseShiftDialog
        parent: iface.mainWindow().contentItem
        modal: true
        title: "Причина паузы"
        standardButtons: Dialog.NoButton
        x: (parent.width - width) / 2
        y: (parent.height - height) / 2
        width: Math.min(parent.width * 0.9, 420)

        ColumnLayout {
            width: parent.width
            spacing: 10

            Label { text: "Все ваши активные задачи будут автоматически поставлены на паузу." ; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 12; color: "#666666" }

            ComboBox {
                id: pauseReasonCombo
                Layout.fillWidth: true
                model: ["Обед", "Технический перерыв", "Другое"]
            }

            TextField {
                id: pauseCustomField
                Layout.fillWidth: true
                visible: pauseReasonCombo.currentIndex === 2
                placeholderText: "Укажите причину"
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                Item { Layout.fillWidth: true }
                Button {
                    text: "Отмена"
                    flat: true
                    onClicked: pauseShiftDialog.close()
                }
                Button {
                    text: "На паузу"
                    highlighted: true
                    enabled: pauseReasonCombo.currentIndex !== 2 || pauseCustomField.text.trim().length > 0
                    onClicked: {
                        var reason = pauseReasonCombo.currentIndex === 2
                            ? pauseCustomField.text.trim()
                            : pauseReasonCombo.currentText
                        pauseShift(reason)
                        pauseShiftDialog.close()
                    }
                }
            }
        }
    }

    // ---- Диалог: подтверждение завершения смены -------------------------

    Dialog {
        id: endShiftDialog
        parent: iface.mainWindow().contentItem
        modal: true
        title: "Завершить смену?"
        standardButtons: Dialog.NoButton
        x: (parent.width - width) / 2
        y: (parent.height - height) / 2
        width: Math.min(parent.width * 0.9, 420)

        ColumnLayout {
            width: parent.width
            spacing: 10

            Label {
                text: "Все активные задачи встанут на паузу, будет сформирован и отправлен в VK итоговый отчёт по смене."
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                Item { Layout.fillWidth: true }
                Button {
                    text: "Отмена"
                    flat: true
                    onClicked: endShiftDialog.close()
                }
                Button {
                    text: "Завершить смену"
                    highlighted: true
                    onClicked: {
                        endShift()
                        endShiftDialog.close()
                    }
                }
            }
        }
    }
}
