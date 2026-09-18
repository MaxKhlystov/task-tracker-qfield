import QtQuick
import QtQuick.Controls
import org.qfield
import org.qgis
import Theme

Button {
    id: quickAcceptRoot
    text: "Принять по клику"

    property var pluginRootRef: null
    property var pendingTaskLayer: null
    property var currentFormModel: null
    property var discoveredFid: null

    onClicked: {
        try {
            if (!pluginRootRef) {
                iface.mainWindow().displayToast("❌ Внутренняя ошибка: нет ссылки на основной плагин")
                return
            }

            if (!pluginRootRef.isOnLine()) {
                iface.mainWindow().displayToast("⚠️ Сначала выйдите на линию (кнопка смены на панели инструментов)")
                return
            }

            var taskLayer = pluginRootRef.findTaskLayer()
            if (!taskLayer) {
                iface.mainWindow().displayToast("❌ Слой задач не найден")
                return
            }
            pluginRootRef.taskLayer = taskLayer
            quickAcceptRoot.pendingTaskLayer = taskLayer

            var form = iface.findItemByObjectName("featureForm")
            if (!form || !form.model || form.model.count === 0) {
                iface.mainWindow().displayToast("⚠️ Сначала тапните по точке на карте")
                return
            }

            quickAcceptRoot.discoveredFid = null
            quickAcceptRoot.currentFormModel = form.model
            waitForRepeaterTimer.start()
        } catch(e) {
            iface.mainWindow().displayToast("❗ Ошибка: " + e)
        }
    }

    Timer {
        id: waitForRepeaterTimer
        interval: 400
        repeat: false
        onTriggered: quickAcceptRoot.continueAfterRepeater()
    }

    function continueAfterRepeater() {
        try {
            var taskLayer = quickAcceptRoot.pendingTaskLayer
            var fid = quickAcceptRoot.discoveredFid

            if (fid === null || fid === undefined) {
                iface.mainWindow().displayToast("⚠️ Не удалось определить точку, тапните по ней ещё раз")
                return
            }

            var feature = pluginRootRef.getFeatureById(fid)
            if (!feature) {
                iface.mainWindow().displayToast("❌ Не удалось прочитать данные точки")
                return
            }

            var status = String(pluginRootRef.readAttribute(feature, "status") || "").toLowerCase()
            if (status === "в работе" || status === "принята") {
                iface.mainWindow().displayToast("ℹ️ Эта задача уже в работе")
                return
            }
            if (status === "завершена") {
                iface.mainWindow().displayToast("ℹ️ Эта задача уже завершена")
                return
            }

            var name = String(pluginRootRef.readAttribute(feature, "name") || ("Задача #" + fid))
            var businessTaskId = String(pluginRootRef.readAttribute(feature, "task_id") || String(fid))

            if (pluginRootRef.setFeatureStatus(fid, "В работе")) {
                iface.mainWindow().displayToast("✅ Принято в работу: " + name)
                try {
                    taskLayer.removeSelection()
                } catch(e) {}
                pluginRootRef.updateMapFilter()
                pluginRootRef.startTaskTimer({
                    "featureId": fid,
                    "taskId": businessTaskId,
                    "name": name
                })
            }
        } catch(e) {
            iface.mainWindow().displayToast("❗ Ошибка: " + e)
        }
    }

    Repeater {
        id: diagRepeater
        model: quickAcceptRoot.currentFormModel

        delegate: Item {
            Component.onCompleted: {
                if (quickAcceptRoot.discoveredFid !== null) return

                if (model["FeatureId"] !== undefined && model["FeatureId"] !== null) {
                    quickAcceptRoot.discoveredFid = model["FeatureId"]
                } else if (model["featureId"] !== undefined && model["featureId"] !== null) {
                    quickAcceptRoot.discoveredFid = model["featureId"]
                }
            }
        }
    }
}
