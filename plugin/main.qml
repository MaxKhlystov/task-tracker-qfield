import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.qfield
import org.qgis
import Theme

Item {
    id: pluginRoot

    property var taskLayer: null
    property string reportServerUrl: "http://192.168.1.101:5000/submit_task"
    property string serverBase: reportServerUrl.replace("/submit_task", "")
    property var activeXhr: null
    property var pendingCompletion: null
    property var currentShift: null  // {id, worker_name, status} — заполняется ShiftPanel.qml

    function isOnLine() {
        return currentShift && currentShift.status === "active"
    }

    function formatDuration(totalSeconds) {
        var s = Math.max(0, Math.floor(totalSeconds || 0))
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        function pad(n) { return (n < 10 ? "0" : "") + n }
        return pad(h) + ":" + pad(m) + ":" + pad(sec)
    }

    // Растёт раз в секунду и служит только "триггером" для перерисовки
    // таймеров в UI — реальное время по-прежнему приходит с сервера
    // (см. syncedAtMs), тут просто плавно досчитываем секунды между
    // серверными синхронизациями (каждые 15 сек), не дёргая сеть.
    property int uiTick: 0

    function liveSeconds(baseSeconds, status, syncedAtMs, tick) {
        if (status !== "active" || !syncedAtMs) return baseSeconds
        var extra = (Date.now() - syncedAtMs) / 1000
        return baseSeconds + Math.max(0, extra)
    }

    // ---- Обёртки над XMLHttpRequest для таймеров/чек-листа задач --------

    function postJson(path, payload, onDone) {
        try {
            var xhr = new XMLHttpRequest()
            xhr.open("POST", pluginRoot.serverBase + path, true)
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.timeout = 10000
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    var obj = null
                    try { obj = JSON.parse(xhr.responseText) } catch(e) {}
                    onDone(xhr.status === 200, obj)
                }
            }
            xhr.send(JSON.stringify(payload))
        } catch(e) {
            iface.mainWindow().displayToast("Ошибка запроса к серверу: " + e)
        }
    }

    function getJson(path, onDone) {
        try {
            var xhr = new XMLHttpRequest()
            xhr.open("GET", pluginRoot.serverBase + path, true)
            xhr.timeout = 10000
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    var obj = null
                    try { obj = JSON.parse(xhr.responseText) } catch(e) {}
                    onDone(xhr.status === 200, obj)
                }
            }
            xhr.send()
        } catch(e) {
            iface.mainWindow().displayToast("Ошибка запроса к серверу: " + e)
        }
    }

    // Подтягивает с сервера таймер и чек-лист по каждой задаче "в работе"
    // текущей смены одним запросом и сливает их в acceptedTasksModel.
    function syncShiftTaskState() {
        if (!currentShift || !currentShift.id) return
        getJson("/shift/status?shift_id=" + currentShift.id, function(ok, obj) {
            if (!ok || !obj || obj.status !== "ok") return

            currentShift = Object.assign({}, currentShift, { status: obj.shift.status })

            var byFeature = {}
            for (var i = 0; i < obj.tasks.length; i++) {
                byFeature[String(obj.tasks[i].feature_id)] = obj.tasks[i]
            }

            for (var r = 0; r < acceptedTasksModel.count; r++) {
                var row = acceptedTasksModel.get(r)
                var info = byFeature[String(row.featureId)]
                if (!info) continue
                var checked = info.checked || []
                var doneCount = 0
                for (var k = 0; k < checked.length; k++) if (checked[k]) doneCount++
                acceptedTasksModel.setProperty(r, "taskStatus", info.status)
                acceptedTasksModel.setProperty(r, "timeSpentSeconds", info.time_spent_seconds)
                acceptedTasksModel.setProperty(r, "syncedAtMs", Date.now())
                acceptedTasksModel.setProperty(r, "stepsJson", JSON.stringify(info.steps))
                acceptedTasksModel.setProperty(r, "checkedJson", JSON.stringify(checked))
                acceptedTasksModel.setProperty(r, "allChecklistDone", checked.length > 0 && doneCount === checked.length)
            }
        })
    }

    function startTaskTimer(itemData) {
        if (!isOnLine()) {
            iface.mainWindow().displayToast("Сначала выйдите на линию (кнопка смены на панели)")
            return
        }
        postJson("/task/start", {
            "shift_id": currentShift.id,
            "feature_id": String(itemData.featureId),
            "task_id": String(itemData.taskId),
            "name": itemData.name
        }, function(ok, obj) {
            if (ok) {
                syncShiftTaskState()
            } else {
                iface.mainWindow().displayToast("Не удалось запустить таймер задачи: " + (obj ? obj.message : "нет связи с сервером"))
            }
        })
    }

    function pauseTaskTimer(featureId) {
        postJson("/task/pause", { "shift_id": currentShift ? currentShift.id : null, "feature_id": String(featureId) }, function(ok, obj) {
            if (ok) { syncShiftTaskState() }
            else { iface.mainWindow().displayToast("Не удалось поставить задачу на паузу: " + (obj ? obj.message : "?")) }
        })
    }

    function resumeTaskTimer(featureId) {
        if (!isOnLine()) {
            iface.mainWindow().displayToast("Смена на паузе — сначала возобновите работу")
            return
        }
        postJson("/task/resume", { "shift_id": currentShift.id, "feature_id": String(featureId) }, function(ok, obj) {
            if (ok) { syncShiftTaskState() }
            else { iface.mainWindow().displayToast("Не удалось возобновить задачу: " + (obj ? obj.message : "?")) }
        })
    }

    function toggleChecklistStep(itemData, stepIndex, checked) {
        if (!currentShift) return
        postJson("/task/progress", {
            "shift_id": currentShift.id,
            "feature_id": String(itemData.featureId),
            "task_id": String(itemData.taskId),
            "step_index": stepIndex,
            "checked": checked
        }, function(ok, obj) {
            if (ok) { syncShiftTaskState() }
            else { iface.mainWindow().displayToast("Не удалось сохранить прогресс: " + (obj ? obj.message : "?")) }
        })
    }

    function findTaskLayer() {
        var project = qgisProject
        var names = ["tasks", "task", "задачи", "точки", "points"]
        for (var i = 0; i < names.length; i++) {
            var layers = project.mapLayersByName(names[i])
            if (layers && layers.length > 0) return layers[0]
        }
        return null
    }

    function calculateDaysLeft(plannedDateStr) {
        if (!plannedDateStr || plannedDateStr === "undefined") return "Срок не указан"

        var parts = plannedDateStr.toString().split("-")
        if (parts.length < 3) return plannedDateStr

        var plannedDate = new Date(parts[0], parts[1] - 1, parts[2])
        var today = new Date()
        today.setHours(0, 0, 0, 0)

        var diffTime = plannedDate.getTime() - today.getTime()
        var diffDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24))

        if (diffDays < 0) return "Просрочено на " + Math.abs(diffDays) + " дн."
        if (diffDays === 0) return "Срок сегодня!"
        return "Осталось: " + diffDays + " дн."
    }

    function readAttribute(feature, fieldName) {
        try {
            if (feature.attribute && typeof feature.attribute === 'function') {
                return feature.attribute(fieldName)
            }
            return feature[fieldName]
        } catch(e) {
            return null
        }
    }

    function readPlannedDate(feature) {
        var candidates = ["planned_data", "planned_date", "plan_date", "planned"]
        for (var i = 0; i < candidates.length; i++) {
            var v = readAttribute(feature, candidates[i])
            if (v !== null && v !== undefined && String(v) !== "") return String(v)
        }
        try {
            var names = feature.fields && feature.fields.names ? feature.fields.names : []
            for (var j = 0; j < names.length; j++) {
                var n = String(names[j]).toLowerCase()
                if (n.indexOf("plan") !== -1 && n.indexOf("dat") !== -1) {
                    var v2 = readAttribute(feature, names[j])
                    if (v2 !== null && v2 !== undefined && String(v2) !== "") return String(v2)
                }
            }
        } catch(e) {}
        return ""
    }

    function getFeatureById(fid) {
        try {
            if (!taskLayer) return null
            var expr = "fid = " + fid
            var it = LayerUtils.createFeatureIteratorFromExpression(taskLayer, expr)
            if (it.hasNext()) {
                return it.next()
            }
        } catch(e) {
            iface.mainWindow().displayToast("Ошибка поиска точки: " + e)
        }
        return null
    }

    function setFeatureStatus(fid, newStatus) {
        if (!taskLayer) return false

        try {
            var wasEditable = false
            try {
                wasEditable = taskLayer.isEditable && taskLayer.isEditable()
            } catch(e) {}

            if (!wasEditable) {
                taskLayer.startEditing()
            }

            var fieldIndex = -1

            try {
                var fldsProp = taskLayer.fields
                if (fldsProp && typeof fldsProp.indexFromName === 'function') {
                    fieldIndex = fldsProp.indexFromName("status")
                } else if (fldsProp && typeof fldsProp.indexOf === 'function') {
                    fieldIndex = fldsProp.indexOf("status")
                }
            } catch(e) {}

            if (fieldIndex === undefined || fieldIndex < 0) {
                try {
                    var fldsMethod = taskLayer.fields()
                    if (fldsMethod && typeof fldsMethod.indexFromName === 'function') {
                        fieldIndex = fldsMethod.indexFromName("status")
                    } else if (fldsMethod && typeof fldsMethod.indexOf === 'function') {
                        fieldIndex = fldsMethod.indexOf("status")
                    }
                } catch(e) {}
            }

            if (fieldIndex === undefined || fieldIndex < 0) {
                try {
                    taskLayer.changeAttributeValue(fid, "status", newStatus)
                    var committedByName = taskLayer.commitChanges()
                    return committedByName !== false
                } catch(e) {}
            }

            if (fieldIndex === undefined || fieldIndex < 0) {
                iface.mainWindow().displayToast("Не удалось найти поле status")
                return false
            }

            taskLayer.changeAttributeValue(fid, fieldIndex, newStatus)
            var committed = taskLayer.commitChanges()
            return committed !== false
        } catch(e) {
            iface.mainWindow().displayToast("Ошибка изменения статуса: " + e)
            return false
        }
    }

    function sendTaskReport(itemData) {
        try {
            pluginRoot.activeXhr = new XMLHttpRequest()
            var xhr = pluginRoot.activeXhr
            xhr.open("POST", pluginRoot.reportServerUrl, true)
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.timeout = 10000

            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    if (xhr.status === 200) {
                        iface.mainWindow().displayToast(xhr.responseText)
                    } else {
                        iface.mainWindow().displayToast("Сервер вернул ошибку (" + xhr.status + "): " + xhr.responseText)
                    }
                    pluginRoot.activeXhr = null
                }
            }

            xhr.send(JSON.stringify({
                "taskId": itemData.taskId,
                "featureId": itemData.featureId,
                "name": itemData.name,
                "status": itemData.status,
                "plannedData": itemData.plannedData,
                "description": itemData.description,
                "importance": itemData.importance || "",
                "executorName": itemData.executorName || "",
                "comment": itemData.comment || "",
                "shiftId": pluginRoot.currentShift ? pluginRoot.currentShift.id : null
            }))
        } catch(e) {
            iface.mainWindow().displayToast("Не удалось отправить отчёт: " + e)
            pluginRoot.activeXhr = null
        }
    }

    function updateMapFilter() {
        if (!taskLayer) return

        var isEditing = false
        try { isEditing = taskLayer.isEditable && taskLayer.isEditable() } catch(e) {}
        if (isEditing) return

        try {
            var expr = "status IS NULL OR status <> 'Завершена'"
            taskLayer.setSubsetString(expr)
        } catch(e) {
        }
    }

    function refreshTasks() {
        acceptedTasksModel.clear()
        availableTasksModel.clear()

        taskLayer = findTaskLayer()
        if (!taskLayer) {
            iface.mainWindow().displayToast("Слой задач не найден")
            return
        }

        updateMapFilter()

        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(taskLayer, "1=1")

            while (it.hasNext()) {
                var feature = it.next()
                if (!feature) continue

                var fid = feature.id
                var status = String(readAttribute(feature, "status") || "")
                var name = String(readAttribute(feature, "name") || ("Задача #" + fid))
                var plannedData = readPlannedDate(feature)
                var description = String(readAttribute(feature, "description") || "")
                var importance = String(readAttribute(feature, "importance") || "")
                var businessTaskId = String(readAttribute(feature, "task_id") || "")

                var itemData = {
                    "featureId": fid,
                    "taskId": businessTaskId !== "" ? businessTaskId : String(fid),
                    "name": name,
                    "status": status,
                    "plannedData": plannedData,
                    "description": description !== "" ? description : "Без описания",
                    "importance": importance,
                    "daysLeft": calculateDaysLeft(plannedData),
                    "taskStatus": "unknown",
                    "timeSpentSeconds": 0,
                    "syncedAtMs": 0,
                    "stepsJson": "[]",
                    "checkedJson": "[]",
                    "allChecklistDone": false
                }

                var statusLower = status.toLowerCase()
                if (statusLower === "в работе" || statusLower === "принята") {
                    acceptedTasksModel.append(itemData)
                } else if (statusLower !== "завершена") {
                    availableTasksModel.append(itemData)
                }
            }
        } catch(e) {
            iface.mainWindow().displayToast("Ошибка чтения точек: " + e)
        }

        syncShiftTaskState()
    }

    ListModel { id: acceptedTasksModel }
    ListModel { id: availableTasksModel }

    Dialog {
        id: completeDialog
        parent: iface.mainWindow().contentItem
        modal: true
        title: "Завершение задачи"
        standardButtons: Dialog.NoButton
        x: (parent.width - width) / 2
        y: (parent.height - height) / 2
        width: Math.min(parent.width * 0.9, 420)

        onOpened: {
            executorNameField.text = pluginRoot.currentShift ? (pluginRoot.currentShift.worker_name || "") : ""
            commentField.text = ""
        }

        ColumnLayout {
            width: parent.width
            spacing: 10

            Label { text: "ФИО исполнителя *"; font.bold: true }
            TextField {
                id: executorNameField
                Layout.fillWidth: true
                placeholderText: "Иванов Иван Иванович"
            }

            Label {
                text: "Обязательное поле"
                color: "#d32f2f"
                font.pixelSize: 11
                visible: executorNameField.text.trim().length === 0
            }

            Label { text: "Комментарий"; font.bold: true }
            TextArea {
                id: commentField
                Layout.fillWidth: true
                Layout.preferredHeight: 90
                wrapMode: TextArea.Wrap
                placeholderText: "Необязательно — например, что было сделано"
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                Item { Layout.fillWidth: true }
                Button {
                    text: "Отмена"
                    flat: true
                    onClicked: {
                        pluginRoot.pendingCompletion = null
                        completeDialog.close()
                    }
                }
                Button {
                    text: "Завершить"
                    highlighted: true
                    enabled: executorNameField.text.trim().length > 0
                    onClicked: {
                        if (!pluginRoot.pendingCompletion) {
                            completeDialog.close()
                            return
                        }

                        var itemSnapshot = pluginRoot.pendingCompletion
                        itemSnapshot.executorName = executorNameField.text.trim()
                        itemSnapshot.comment = commentField.text.trim()

                        if (pluginRoot.setFeatureStatus(itemSnapshot.featureId, "Завершена")) {
                            iface.mainWindow().displayToast("Задача завершена: " + itemSnapshot.taskId)
                            pluginRoot.sendTaskReport(itemSnapshot)
                            pluginRoot.refreshTasks()
                        }

                        pluginRoot.pendingCompletion = null
                        completeDialog.close()
                    }
                }
            }
        }
    }

    Drawer {
        id: taskDrawer
        parent: iface.mainWindow().contentItem
        edge: Qt.RightEdge
        width: Math.min(parent.width * 0.85, 450)
        height: parent.height
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        onOpened: refreshTasks()

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 10

            Label {
                text: "📋 Диспетчер задач"
                font.bold: true
                font.pixelSize: 18
                Layout.alignment: Qt.AlignHCenter
            }

            TabBar {
                id: tabBar
                Layout.fillWidth: true
                TabButton { text: "В работе (" + acceptedTasksModel.count + ")" }
                TabButton { text: "Доступные (" + availableTasksModel.count + ")" }
            }

            StackLayout {
                currentIndex: tabBar.currentIndex
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    model: acceptedTasksModel
                    clip: true
                    spacing: 8
                    delegate: Rectangle {
                        id: acceptedDelegate
                        width: ListView.view.width
                        height: contentCol.implicitHeight + 16
                        color: "#f5f5f5"
                        radius: 6
                        border.color: "#e0e0e0"

                        property var stepsList: { try { return JSON.parse(model.stepsJson || "[]") } catch(e) { return [] } }
                        property var checkedList: { try { return JSON.parse(model.checkedJson || "[]") } catch(e) { return [] } }
                        property var itemFeatureId: model.featureId
                        property var itemTaskId: model.taskId
                        property string itemTaskStatus: model.taskStatus

                        ColumnLayout {
                            id: contentCol
                            width: parent.width
                            anchors.margins: 8
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            spacing: 4

                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    text: model.name
                                    font.bold: true
                                    color: "#666666" // Цвет названия такой же, как у описания
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                Label {
                                    text: model.daysLeft
                                    font.pixelSize: 11
                                    color: model.daysLeft.indexOf("Просрочено") !== -1 ? "#d32f2f" : "#2e7d32"
                                    font.bold: true
                                }
                            }

                            Label { text: model.description; font.pixelSize: 12; color: "#666666"; elide: Text.ElideRight; Layout.fillWidth: true }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                Label {
                                    text: pluginRoot.formatDuration(pluginRoot.liveSeconds(model.timeSpentSeconds, model.taskStatus, model.syncedAtMs, pluginRoot.uiTick))
                                    font.pixelSize: 12
                                    color: model.taskStatus === "active" ? "#2e7d32" : "#888888"
                                }
                                Label {
                                    text: model.taskStatus === "paused" ? "(на паузе)" : (model.taskStatus === "active" ? "(идёт)" : "")
                                    font.pixelSize: 11
                                    color: "#888888"
                                }
                                Item { Layout.fillWidth: true }
                                Button {
                                    text: model.taskStatus === "active" ? "Пауза" : "Продолжить"
                                    visible: model.taskStatus === "active" || model.taskStatus === "paused"
                                    onClicked: {
                                        if (model.taskStatus === "active") {
                                            pluginRoot.pauseTaskTimer(model.featureId)
                                        } else {
                                            pluginRoot.resumeTaskTimer(model.featureId)
                                        }
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                visible: acceptedDelegate.stepsList.length > 0
                                Repeater {
                                    model: acceptedDelegate.stepsList
                                    delegate: CheckBox {
                                        id: stepCheckBox
                                        Layout.fillWidth: true
                                        text: modelData
                                        checked: acceptedDelegate.checkedList[index] === true
                                        enabled: acceptedDelegate.itemTaskStatus === "active"
                                        
                                        // Цвет текста этапа такой же, как у описания (#666666)
                                        contentItem: Text {
                                            text: stepCheckBox.text
                                            font: stepCheckBox.font
                                            color: "#666666"
                                            verticalAlignment: Text.AlignVCenter
                                            leftPadding: stepCheckBox.indicator.width + stepCheckBox.spacing
                                        }

                                        onToggled: {
                                            pluginRoot.toggleChecklistStep({
                                                "featureId": acceptedDelegate.itemFeatureId,
                                                "taskId": acceptedDelegate.itemTaskId
                                            }, index, checked)
                                        }
                                    }
                                }
                            }
                            Label {
                                Layout.fillWidth: true
                                visible: acceptedDelegate.stepsList.length > 0 && acceptedDelegate.itemTaskStatus === "paused"
                                text: "Задача на паузе — возобновите её, чтобы отмечать пункты"
                                font.pixelSize: 10
                                color: "#888888"
                                wrapMode: Text.WordWrap
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Item { Layout.fillWidth: true }
                                Button {
                                    text: "Завершить"
                                    highlighted: true
                                    enabled: acceptedDelegate.stepsList.length === 0 || model.allChecklistDone
                                    onClicked: {
                                        pluginRoot.pendingCompletion = {
                                            "featureId": model.featureId,
                                            "taskId": model.taskId,
                                            "name": model.name,
                                            "status": "Завершена",
                                            "plannedData": model.plannedData,
                                            "description": model.description,
                                            "importance": model.importance
                                        }
                                        completeDialog.open()
                                    }
                                }
                            }
                            Label {
                                Layout.fillWidth: true
                                visible: acceptedDelegate.stepsList.length > 0 && !model.allChecklistDone
                                text: "Отметьте все этапы чек-листа, чтобы завершить задачу"
                                font.pixelSize: 10
                                color: "#d32f2f"
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }

                ListView {
                    model: availableTasksModel
                    clip: true
                    spacing: 8
                    delegate: Rectangle {
                        width: ListView.view.width
                        height: 110
                        color: "#ffffff"
                        radius: 6
                        border.color: "#cccccc"

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4

                            Label {
                                text: model.name
                                font.bold: true
                                color: "#666666" // Цвет названия в доступных задачах
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            Label { text: model.description; font.pixelSize: 12; color: "#666666"; elide: Text.ElideRight; Layout.fillWidth: true }
                            Label { text: "Дата: " + model.plannedData; font.pixelSize: 11; color: "#888888" }

                            RowLayout {
                                Layout.fillWidth: true
                                Button {
                                    text: "Принять в работу"
                                    onClicked: {
                                        if (!pluginRoot.isOnLine()) {
                                            iface.mainWindow().displayToast("Сначала выйдите на линию (кнопка смены на панели инструментов)")
                                            return
                                        }
                                        if (pluginRoot.setFeatureStatus(model.featureId, "В работе")) {
                                            iface.mainWindow().displayToast("Задача принята в работу")
                                            pluginRoot.startTaskTimer({
                                                "featureId": model.featureId,
                                                "taskId": model.taskId,
                                                "name": model.name
                                            })
                                            pluginRoot.refreshTasks()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Button {
        id: openTaskListBtn
        text: "Список задач"
        onClicked: {
            taskLayer = findTaskLayer()
            if (!taskLayer) {
                iface.mainWindow().displayToast("Слой задач не найден!")
                return
            }
            taskDrawer.open()
        }
    }

    QuickAcceptButton {
        id: quickAcceptBtn
        pluginRootRef: pluginRoot
    }

    ShiftPanel {
        id: shiftPanelBtn
        pluginRootRef: pluginRoot
    }

    Timer {
        interval: 15000
        running: pluginRoot.currentShift !== null
        repeat: true
        onTriggered: pluginRoot.syncShiftTaskState()
    }

    Timer {
        interval: 1000
        running: pluginRoot.currentShift !== null
        repeat: true
        onTriggered: pluginRoot.uiTick++
    }

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(shiftPanelBtn)
        iface.addItemToPluginsToolbar(openTaskListBtn)
        iface.addItemToPluginsToolbar(quickAcceptBtn)
    }
}