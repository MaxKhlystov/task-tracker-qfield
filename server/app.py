"""
Локальный сервер для приёма данных о выполненных задачах и о сменах
работников из QField-плагина.

Новое по сравнению с версией 1:
  - SQLite-база tasks.db (создаётся автоматически рядом с app.py) хранит
    смены, паузы смены, таймеры по каждой задаче и прогресс по чек-листу.
  - Эндпоинты /shift/* — выход на линию, пауза, возобновление, завершение
    смены (с автоматической постановкой всех активных задач на паузу и
    отправкой итогового отчёта по смене в VK).
  - Эндпоинты /task/* — старт/пауза/резюм таймера задачи, чек-лист
    прогресса по задаче.
  - Отчёт по одной задаче (/submit_task) работает как раньше.

Запуск не изменился:
    pip install -r requirements.txt
    python app.py
"""

import json
import os
import random
import sqlite3
import subprocess
import threading
import time
import traceback
from contextlib import closing
from datetime import datetime

import requests
from flask import Flask, jsonify, request
from docxtpl import DocxTemplate

app = Flask(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_PATH = os.path.join(BASE_DIR, "templates", "report_template.docx")
SHIFT_TEMPLATE_PATH = os.path.join(BASE_DIR, "templates", "shift_report_template.docx")
OUTPUT_DIR = os.path.join(BASE_DIR, "reports")
DB_PATH = os.path.join(BASE_DIR, "tasks.db")

os.makedirs(OUTPUT_DIR, exist_ok=True)

VK_ACCESS_TOKEN = os.environ.get("VK_ACCESS_TOKEN", "")
VK_PEER_ID = os.environ.get("VK_PEER_ID", "")
VK_GROUP_ID = os.environ.get("VK_GROUP_ID", "")
VK_API_VERSION = "5.199"

DEFAULT_CHECKLIST = ["Этап 1", "Этап 2", "Этап 3", "Этап 4", "Этап 5"]


# ---------------------------------------------------------------------------
# База данных
# ---------------------------------------------------------------------------

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db():
    with closing(get_db()) as conn, conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS shifts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                worker_name TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                started_at TEXT NOT NULL,
                ended_at TEXT
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS pauses (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                shift_id INTEGER NOT NULL REFERENCES shifts(id),
                reason TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS task_progress (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                shift_id INTEGER NOT NULL REFERENCES shifts(id),
                feature_id TEXT NOT NULL,
                task_id TEXT,
                name TEXT,
                status TEXT NOT NULL DEFAULT 'active',
                time_spent_seconds INTEGER NOT NULL DEFAULT 0,
                last_resumed_at TEXT,
                started_at TEXT NOT NULL,
                completed_at TEXT,
                UNIQUE(shift_id, feature_id)
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS checklist_templates (
                task_id TEXT PRIMARY KEY,
                steps_json TEXT NOT NULL
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS checklist_state (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                shift_id INTEGER NOT NULL,
                feature_id TEXT NOT NULL,
                step_index INTEGER NOT NULL,
                checked INTEGER NOT NULL DEFAULT 0,
                UNIQUE(shift_id, feature_id, step_index)
            )
        """)
        conn.execute(
            "INSERT OR IGNORE INTO checklist_templates (task_id, steps_json) VALUES ('__default__', ?)",
            (json.dumps(DEFAULT_CHECKLIST, ensure_ascii=False),),
        )


def now_iso():
    return datetime.now().isoformat(timespec="seconds")


def parse_iso(s):
    return datetime.fromisoformat(s)


def fmt_duration(seconds):
    seconds = int(seconds or 0)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


# ---------------------------------------------------------------------------
# VK
# ---------------------------------------------------------------------------

def vk_api_call(method, params):
    params = dict(params)
    params["access_token"] = VK_ACCESS_TOKEN
    params["v"] = VK_API_VERSION
    if VK_GROUP_ID:
        params.setdefault("group_id", VK_GROUP_ID)
    resp = requests.post(f"https://api.vk.com/method/{method}", data=params, timeout=15)
    data = resp.json()
    if "error" in data:
        raise RuntimeError(f"{method}: {data['error'].get('error_msg', 'неизвестная ошибка VK API')}")
    return data["response"]


def vk_upload_document(peer_id, filepath):
    upload_info = vk_api_call("docs.getMessagesUploadServer", {"type": "doc", "peer_id": peer_id})
    with open(filepath, "rb") as f:
        files = {"file": (os.path.basename(filepath), f, "application/pdf")}
        upload_resp = requests.post(upload_info["upload_url"], files=files, timeout=30)
    upload_result = upload_resp.json()
    saved = vk_api_call("docs.save", {"file": upload_result["file"], "title": os.path.basename(filepath)})
    doc = saved.get("doc", saved)
    return f"doc{doc['owner_id']}_{doc['id']}"


def send_vk_notification(text, pdf_path=None):
    if not VK_ACCESS_TOKEN or not VK_PEER_ID:
        return {"sent": False, "error": "VK_ACCESS_TOKEN или VK_PEER_ID не заданы"}

    attachment = ""
    attachment_error = None
    if pdf_path and os.path.exists(pdf_path):
        try:
            attachment = vk_upload_document(VK_PEER_ID, pdf_path)
        except Exception as e:
            attachment_error = str(e)

    try:
        vk_api_call("messages.send", {
            "peer_id": VK_PEER_ID,
            "message": text,
            "random_id": random.randint(1, 2_000_000_000),
            "attachment": attachment,
        })
        result = {"sent": True}
        if attachment_error:
            result["attachment_error"] = attachment_error
        return result
    except Exception as e:
        result = {"sent": False, "error": str(e)}
        if attachment_error:
            result["attachment_error"] = attachment_error
        return result


# ---------------------------------------------------------------------------
# VK-бот (Long Poll API)
# ---------------------------------------------------------------------------
# В отличие от простой отправки уведомлений (send_vk_notification), это
# отдельный фоновый цикл, который слушает входящие сообщения сообщества и
# отвечает на них. Чтобы это заработало, в настройках сообщества нужно
# включить Long Poll API — см. README.

def vk_bot_get_long_poll_server():
    return vk_api_call("groups.getLongPollServer", {"group_id": VK_GROUP_ID})


def vk_bot_send_text(peer_id, text):
    try:
        vk_api_call("messages.send", {
            "peer_id": peer_id,
            "message": text,
            "random_id": random.randint(1, 2_000_000_000),
        })
    except Exception as e:
        print(f"[VK бот] Не удалось ответить {peer_id}: {e}")


def vk_bot_active_shifts_text():
    with closing(get_db()) as conn:
        rows = conn.execute(
            "SELECT * FROM shifts WHERE status != 'ended' ORDER BY started_at"
        ).fetchall()
    if not rows:
        return "Сейчас никто не на линии."
    lines = ["На линии сейчас:"]
    for r in rows:
        icon = "🟢" if r["status"] == "active" else "🔴"
        lines.append(f"{icon} {r['worker_name']} — с {parse_iso(r['started_at']).strftime('%H:%M')}")
    return "\n".join(lines)


def vk_bot_help_text():
    return (
        "Я бот учёта задач и смен.\n\n"
        "Доступные команды:\n"
        "«статус» — кто сейчас на линии и на паузе"
    )


def vk_bot_handle_message(peer_id, text):
    """Простой командный роутер. Чтобы добавить новую команду — добавь ещё
    одно условие сюда."""
    normalized = (text or "").strip().lower()
    if normalized in ("статус", "/status", "кто на линии", "кто в работе"):
        vk_bot_send_text(peer_id, vk_bot_active_shifts_text())
    else:
        vk_bot_send_text(peer_id, vk_bot_help_text())


def vk_bot_long_poll_loop():
    """Фоновый цикл Bots Long Poll API. Работает, пока жив процесс сервера
    (демон-поток — см. запуск в самом низу файла)."""
    if not VK_ACCESS_TOKEN or not VK_GROUP_ID:
        print("[VK бот] VK_ACCESS_TOKEN/VK_GROUP_ID не заданы — бот не запущен")
        return

    try:
        server_info = vk_bot_get_long_poll_server()
    except Exception as e:
        print(f"[VK бот] Не удалось получить Long Poll сервер: {e}")
        print("[VK бот] Проверь, что в настройках сообщества включён Long Poll API")
        print("[VK бот] и что у токена есть право «Управление сообществом».")
        return

    server = server_info["server"]
    key = server_info["key"]
    ts = server_info["ts"]
    print("[VK бот] Long Poll запущен, жду сообщений...")

    while True:
        try:
            resp = requests.get(server, params={
                "act": "a_check", "key": key, "ts": ts, "wait": 25,
            }, timeout=30)
            data = resp.json()

            if "failed" in data:
                # ключ/ts устарели или история событий сброшена —
                # запрашиваем новый сервер и продолжаем
                server_info = vk_bot_get_long_poll_server()
                server, key, ts = server_info["server"], server_info["key"], server_info["ts"]
                continue

            ts = data.get("ts", ts)
            for update in data.get("updates", []):
                if update.get("type") != "message_new":
                    continue
                message = update.get("object", {}).get("message", {})
                peer_id = message.get("peer_id")
                text = message.get("text", "")
                if peer_id:
                    vk_bot_handle_message(peer_id, text)
        except requests.RequestException as e:
            print(f"[VK бот] Сетевая ошибка Long Poll: {e}")
            time.sleep(5)
        except Exception as e:
            print(f"[VK бот] Ошибка в цикле Long Poll: {e}")
            time.sleep(5)


# ---------------------------------------------------------------------------
# Вспомогательное
# ---------------------------------------------------------------------------

def safe_filename_part(value):
    value = str(value)
    keep = "-_.() "
    return "".join(c if (c.isalnum() or c in keep) else "_" for c in value).strip()


def convert_docx_to_pdf(docx_path, output_dir):
    soffice_cmd = os.environ.get("SOFFICE_PATH", "soffice")
    result = subprocess.run(
        [soffice_cmd, "--headless", "--convert-to", "pdf", "--outdir", output_dir, docx_path],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"LibreOffice вернул ошибку: {result.stderr or result.stdout}")


def get_checklist_steps(conn, task_id):
    row = conn.execute("SELECT steps_json FROM checklist_templates WHERE task_id = ?", (task_id,)).fetchone()
    if not row:
        row = conn.execute("SELECT steps_json FROM checklist_templates WHERE task_id = '__default__'").fetchone()
    return json.loads(row["steps_json"])


def get_checklist_state(conn, shift_id, feature_id, steps_count):
    rows = conn.execute(
        "SELECT step_index, checked FROM checklist_state WHERE shift_id = ? AND feature_id = ?",
        (shift_id, feature_id),
    ).fetchall()
    checked = [False] * steps_count
    for r in rows:
        if 0 <= r["step_index"] < steps_count:
            checked[r["step_index"]] = bool(r["checked"])
    return checked


def pause_task_row(conn, row, ts):
    """Ставит одну строку task_progress на паузу, накапливая время."""
    if row["status"] != "active":
        return
    elapsed = 0
    if row["last_resumed_at"]:
        elapsed = (ts - parse_iso(row["last_resumed_at"])).total_seconds()
    conn.execute(
        "UPDATE task_progress SET status = 'paused', time_spent_seconds = time_spent_seconds + ?, last_resumed_at = NULL WHERE id = ?",
        (max(0, int(elapsed)), row["id"]),
    )


def task_elapsed_seconds(row, now):
    total = row["time_spent_seconds"] or 0
    if row["status"] == "active" and row["last_resumed_at"]:
        total += (now - parse_iso(row["last_resumed_at"])).total_seconds()
    return int(total)


# ---------------------------------------------------------------------------
# Базовые эндпоинты
# ---------------------------------------------------------------------------

@app.route("/ping", methods=["GET"])
def ping():
    return jsonify({"status": "ok", "message": "Сервер задач работает"})


@app.route("/submit_task", methods=["POST"])
def submit_task():
    try:
        data = request.get_json(force=True, silent=True)
        if not data:
            return jsonify({"status": "error", "message": "Тело запроса пустое или не является JSON"}), 400

        task_id = data.get("taskId", data.get("featureId", "unknown"))
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename_base = f"task_{safe_filename_part(task_id)}_{timestamp}"

        context = {
            "task_id": str(task_id),
            "name": data.get("name", ""),
            "criticality": data.get("importance", ""),
            "status": data.get("status", ""),
            "planned_data": data.get("plannedData", ""),
            "description": data.get("description", ""),
            "executor_name": data.get("executorName", ""),
            "comment": data.get("comment", ""),
            "completed_date": datetime.now().strftime("%d.%m.%Y %H:%M"),
        }

        if not os.path.exists(TEMPLATE_PATH):
            return jsonify({"status": "error", "message": f"Шаблон не найден: {TEMPLATE_PATH}"}), 500

        doc = DocxTemplate(TEMPLATE_PATH)
        doc.render(context)

        docx_path = os.path.join(OUTPUT_DIR, filename_base + ".docx")
        doc.save(docx_path)

        pdf_created = False
        pdf_error = None
        pdf_full_path = os.path.join(OUTPUT_DIR, filename_base + ".pdf")
        try:
            convert_docx_to_pdf(docx_path, OUTPUT_DIR)
            pdf_created = os.path.exists(pdf_full_path)
        except Exception as e:
            pdf_error = str(e)

        vk_message_text = (
            "Задача завершена\n"
            f"ID: {context['task_id']}\n"
            f"Название: {context['name']}\n"
            f"Критичность: {context['criticality']}\n"
            f"Плановая дата: {context['planned_data']}\n"
            f"Дата завершения: {context['completed_date']}\n"
            f"Исполнитель: {context['executor_name']}\n"
            f"Комментарий: {context['comment']}"
        )
        vk_result = send_vk_notification(vk_message_text, pdf_full_path if pdf_created else None)

        # Если задача была под таймером в рамках смены — закрываем её прогресс
        shift_id = data.get("shiftId")
        feature_id = data.get("featureId")
        if shift_id and feature_id:
            with closing(get_db()) as conn, conn:
                row = conn.execute(
                    "SELECT * FROM task_progress WHERE shift_id = ? AND feature_id = ?",
                    (shift_id, str(feature_id)),
                ).fetchone()
                if row:
                    ts = datetime.now()
                    pause_task_row(conn, row, ts)
                    conn.execute(
                        "UPDATE task_progress SET status = 'completed', completed_at = ? WHERE id = ?",
                        (now_iso(), row["id"]),
                    )

        response = {
            "status": "ok",
            "docx_file": filename_base + ".docx",
            "pdf_created": pdf_created,
            "vk": vk_result,
        }
        if pdf_error:
            response["pdf_error"] = pdf_error

        return jsonify(response), 200

    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


# ---------------------------------------------------------------------------
# Смены
# ---------------------------------------------------------------------------

@app.route("/shift/active", methods=["GET"])
def shift_active():
    """Найти незакрытую смену работника — для восстановления состояния
    после перезапуска приложения на планшете."""
    worker_name = request.args.get("worker_name", "").strip()
    if not worker_name:
        return jsonify({"status": "error", "message": "worker_name обязателен"}), 400

    with closing(get_db()) as conn:
        row = conn.execute(
            "SELECT * FROM shifts WHERE worker_name = ? AND status != 'ended' ORDER BY id DESC LIMIT 1",
            (worker_name,),
        ).fetchone()
        if not row:
            return jsonify({"status": "ok", "shift": None})
        return jsonify({"status": "ok", "shift": dict(row)})


@app.route("/shift/start", methods=["POST"])
def shift_start():
    data = request.get_json(force=True, silent=True) or {}
    worker_name = str(data.get("worker_name", "")).strip()
    if not worker_name:
        return jsonify({"status": "error", "message": "worker_name обязателен"}), 400

    with closing(get_db()) as conn, conn:
        existing = conn.execute(
            "SELECT * FROM shifts WHERE worker_name = ? AND status != 'ended' ORDER BY id DESC LIMIT 1",
            (worker_name,),
        ).fetchone()
        if existing:
            return jsonify({"status": "ok", "shift": dict(existing), "note": "уже есть открытая смена"})

        cur = conn.execute(
            "INSERT INTO shifts (worker_name, status, started_at) VALUES (?, 'active', ?)",
            (worker_name, now_iso()),
        )
        shift = conn.execute("SELECT * FROM shifts WHERE id = ?", (cur.lastrowid,)).fetchone()
        return jsonify({"status": "ok", "shift": dict(shift)})


@app.route("/shift/pause", methods=["POST"])
def shift_pause():
    data = request.get_json(force=True, silent=True) or {}
    shift_id = data.get("shift_id")
    reason = str(data.get("reason", "")).strip() or "Без причины"
    if not shift_id:
        return jsonify({"status": "error", "message": "shift_id обязателен"}), 400

    with closing(get_db()) as conn, conn:
        shift = conn.execute("SELECT * FROM shifts WHERE id = ?", (shift_id,)).fetchone()
        if not shift or shift["status"] == "ended":
            return jsonify({"status": "error", "message": "Смена не найдена или уже завершена"}), 404
        if shift["status"] == "paused":
            return jsonify({"status": "ok", "note": "смена уже на паузе"})

        ts = datetime.now()
        conn.execute("UPDATE shifts SET status = 'paused' WHERE id = ?", (shift_id,))
        conn.execute(
            "INSERT INTO pauses (shift_id, reason, started_at) VALUES (?, ?, ?)",
            (shift_id, reason, now_iso()),
        )

        active_tasks = conn.execute(
            "SELECT * FROM task_progress WHERE shift_id = ? AND status = 'active'", (shift_id,)
        ).fetchall()
        paused_feature_ids = []
        for row in active_tasks:
            pause_task_row(conn, row, ts)
            paused_feature_ids.append(row["feature_id"])

        return jsonify({"status": "ok", "paused_tasks": paused_feature_ids})


@app.route("/shift/resume", methods=["POST"])
def shift_resume():
    data = request.get_json(force=True, silent=True) or {}
    shift_id = data.get("shift_id")
    if not shift_id:
        return jsonify({"status": "error", "message": "shift_id обязателен"}), 400

    with closing(get_db()) as conn, conn:
        shift = conn.execute("SELECT * FROM shifts WHERE id = ?", (shift_id,)).fetchone()
        if not shift or shift["status"] == "ended":
            return jsonify({"status": "error", "message": "Смена не найдена или уже завершена"}), 404

        conn.execute("UPDATE shifts SET status = 'active' WHERE id = ?", (shift_id,))
        conn.execute(
            "UPDATE pauses SET ended_at = ? WHERE shift_id = ? AND ended_at IS NULL",
            (now_iso(), shift_id),
        )
        # Задачи НЕ возобновляются автоматически — работник сам решает,
        # какую задачу продолжать; см. /task/resume.
        return jsonify({"status": "ok"})


@app.route("/shift/end", methods=["POST"])
def shift_end():
    data = request.get_json(force=True, silent=True) or {}
    shift_id = data.get("shift_id")
    if not shift_id:
        return jsonify({"status": "error", "message": "shift_id обязателен"}), 400

    with closing(get_db()) as conn, conn:
        shift = conn.execute("SELECT * FROM shifts WHERE id = ?", (shift_id,)).fetchone()
        if not shift:
            return jsonify({"status": "error", "message": "Смена не найдена"}), 404
        if shift["status"] == "ended":
            return jsonify({"status": "error", "message": "Смена уже завершена"}), 400

        ts = datetime.now()
        conn.execute(
            "UPDATE pauses SET ended_at = ? WHERE shift_id = ? AND ended_at IS NULL",
            (now_iso(), shift_id),
        )
        active_tasks = conn.execute(
            "SELECT * FROM task_progress WHERE shift_id = ? AND status = 'active'", (shift_id,)
        ).fetchall()
        for row in active_tasks:
            pause_task_row(conn, row, ts)

        conn.execute(
            "UPDATE shifts SET status = 'ended', ended_at = ? WHERE id = ?",
            (now_iso(), shift_id),
        )

        shift = conn.execute("SELECT * FROM shifts WHERE id = ?", (shift_id,)).fetchone()
        all_tasks = conn.execute(
            "SELECT * FROM task_progress WHERE shift_id = ? ORDER BY started_at", (shift_id,)
        ).fetchall()
        pauses = conn.execute(
            "SELECT * FROM pauses WHERE shift_id = ? ORDER BY started_at", (shift_id,)
        ).fetchall()

        total_pause_seconds = 0
        for p in pauses:
            end = parse_iso(p["ended_at"]) if p["ended_at"] else ts
            total_pause_seconds += (end - parse_iso(p["started_at"])).total_seconds()

        started_at = parse_iso(shift["started_at"])
        ended_at = parse_iso(shift["ended_at"])
        total_shift_seconds = (ended_at - started_at).total_seconds()
        total_work_seconds = sum(task_elapsed_seconds(t, ts) for t in all_tasks)

        tasks_ctx = []
        for t in all_tasks:
            steps = get_checklist_steps(conn, t["task_id"] or "__default__")
            checked = get_checklist_state(conn, shift_id, t["feature_id"], len(steps))
            done = sum(1 for c in checked if c)
            tasks_ctx.append({
                "task_id": t["task_id"] or t["feature_id"],
                "name": t["name"] or "",
                "status_label": {"active": "в работе", "paused": "на паузе", "completed": "завершена"}.get(t["status"], t["status"]),
                "time_spent": fmt_duration(task_elapsed_seconds(t, ts)),
                "progress": f"{done}/{len(steps)}",
            })

    # генерация отчёта по смене
    report = None
    vk_result = {"sent": False, "error": "отчёт не сформирован"}
    if os.path.exists(SHIFT_TEMPLATE_PATH):
        try:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename_base = f"shift_{safe_filename_part(shift['worker_name'])}_{timestamp}"
            doc = DocxTemplate(SHIFT_TEMPLATE_PATH)
            doc.render({
                "worker_name": shift["worker_name"],
                "shift_start": started_at.strftime("%d.%m.%Y %H:%M"),
                "shift_end": ended_at.strftime("%d.%m.%Y %H:%M"),
                "total_shift_time": fmt_duration(total_shift_seconds),
                "total_work_time": fmt_duration(total_work_seconds),
                "total_pause_time": fmt_duration(total_pause_seconds),
                "tasks_count": len(all_tasks),
                "tasks_completed": sum(1 for t in all_tasks if t["status"] == "completed"),
                "tasks": tasks_ctx,
            })
            docx_path = os.path.join(OUTPUT_DIR, filename_base + ".docx")
            doc.save(docx_path)

            pdf_full_path = os.path.join(OUTPUT_DIR, filename_base + ".pdf")
            pdf_created = False
            try:
                convert_docx_to_pdf(docx_path, OUTPUT_DIR)
                pdf_created = os.path.exists(pdf_full_path)
            except Exception as e:
                report = {"docx_file": filename_base + ".docx", "pdf_created": False, "pdf_error": str(e)}

            if pdf_created:
                report = {"docx_file": filename_base + ".docx", "pdf_created": True}

            vk_text = (
                "Отчёт по смене\n"
                f"Работник: {shift['worker_name']}\n"
                f"Начало: {started_at.strftime('%d.%m.%Y %H:%M')}\n"
                f"Конец: {ended_at.strftime('%d.%m.%Y %H:%M')}\n"
                f"Общее время смены: {fmt_duration(total_shift_seconds)}\n"
                f"Время в работе: {fmt_duration(total_work_seconds)}\n"
                f"Время на паузах: {fmt_duration(total_pause_seconds)}\n"
                f"Задач завершено: {sum(1 for t in all_tasks if t['status'] == 'completed')}/{len(all_tasks)}"
            )
            vk_result = send_vk_notification(vk_text, pdf_full_path if pdf_created else None)
        except Exception as e:
            print("[shift/end] Ошибка формирования отчёта по смене:")
            traceback.print_exc()
            report = {"error": str(e)}
            vk_result = {"sent": False, "error": f"Отчёт по смене не сформирован: {e}"}
    else:
        report = {"error": f"Шаблон отчёта по смене не найден: {SHIFT_TEMPLATE_PATH}"}
        vk_result = {"sent": False, "error": report["error"]}

    return jsonify({
        "status": "ok",
        "shift": dict(shift),
        "summary": {
            "total_shift_time": fmt_duration(total_shift_seconds),
            "total_work_time": fmt_duration(total_work_seconds),
            "total_pause_time": fmt_duration(total_pause_seconds),
            "tasks": tasks_ctx,
        },
        "report": report,
        "vk": vk_result,
    })


@app.route("/shift/status", methods=["GET"])
def shift_status():
    """Полное текущее состояние смены — используется плагином, чтобы
    восстановить UI после перезапуска приложения."""
    shift_id = request.args.get("shift_id")
    if not shift_id:
        return jsonify({"status": "error", "message": "shift_id обязателен"}), 400

    with closing(get_db()) as conn:
        shift = conn.execute("SELECT * FROM shifts WHERE id = ?", (shift_id,)).fetchone()
        if not shift:
            return jsonify({"status": "error", "message": "Смена не найдена"}), 404
        tasks = conn.execute(
            "SELECT * FROM task_progress WHERE shift_id = ?", (shift_id,)
        ).fetchall()
        ts = datetime.now()
        tasks_out = []
        for t in tasks:
            steps = get_checklist_steps(conn, t["task_id"] or "__default__")
            checked = get_checklist_state(conn, shift_id, t["feature_id"], len(steps))
            tasks_out.append({
                "feature_id": t["feature_id"],
                "task_id": t["task_id"],
                "name": t["name"],
                "status": t["status"],
                "time_spent_seconds": task_elapsed_seconds(t, ts),
                "steps": steps,
                "checked": checked,
            })
        return jsonify({"status": "ok", "shift": dict(shift), "tasks": tasks_out})


# ---------------------------------------------------------------------------
# Задачи (таймер + чек-лист)
# ---------------------------------------------------------------------------

@app.route("/task/start", methods=["POST"])
def task_start():
    data = request.get_json(force=True, silent=True) or {}
    shift_id = data.get("shift_id")
    feature_id = str(data.get("feature_id", ""))
    task_id = str(data.get("task_id", ""))
    name = data.get("name", "")
    if not shift_id or not feature_id:
        return jsonify({"status": "error", "message": "shift_id и feature_id обязательны"}), 400

    with closing(get_db()) as conn, conn:
        shift = conn.execute("SELECT * FROM shifts WHERE id = ?", (shift_id,)).fetchone()
        if not shift or shift["status"] != "active":
            return jsonify({"status": "error", "message": "Смена не активна — сначала выйдите на линию / снимите паузу"}), 409

        existing = conn.execute(
            "SELECT * FROM task_progress WHERE shift_id = ? AND feature_id = ?", (shift_id, feature_id)
        ).fetchone()
        ts_iso = now_iso()
        if existing:
            if existing["status"] == "completed":
                return jsonify({"status": "error", "message": "Задача уже завершена"}), 409
            conn.execute(
                "UPDATE task_progress SET status = 'active', last_resumed_at = ? WHERE id = ?",
                (ts_iso, existing["id"]),
            )
        else:
            conn.execute(
                "INSERT INTO task_progress (shift_id, feature_id, task_id, name, status, started_at, last_resumed_at) "
                "VALUES (?, ?, ?, ?, 'active', ?, ?)",
                (shift_id, feature_id, task_id, name, ts_iso, ts_iso),
            )
        return jsonify({"status": "ok"})


@app.route("/task/pause", methods=["POST"])
def task_pause():
    data = request.get_json(force=True, silent=True) or {}
    shift_id = data.get("shift_id")
    feature_id = str(data.get("feature_id", ""))
    with closing(get_db()) as conn, conn:
        row = conn.execute(
            "SELECT * FROM task_progress WHERE shift_id = ? AND feature_id = ?", (shift_id, feature_id)
        ).fetchone()
        if not row:
            return jsonify({"status": "error", "message": "Задача не найдена в текущей смене"}), 404
        pause_task_row(conn, row, datetime.now())
        return jsonify({"status": "ok"})


@app.route("/task/resume", methods=["POST"])
def task_resume():
    data = request.get_json(force=True, silent=True) or {}
    shift_id = data.get("shift_id")
    feature_id = str(data.get("feature_id", ""))
    with closing(get_db()) as conn, conn:
        shift = conn.execute("SELECT * FROM shifts WHERE id = ?", (shift_id,)).fetchone()
        if not shift or shift["status"] != "active":
            return jsonify({"status": "error", "message": "Смена не активна — сначала снимите паузу со смены"}), 409
        row = conn.execute(
            "SELECT * FROM task_progress WHERE shift_id = ? AND feature_id = ?", (shift_id, feature_id)
        ).fetchone()
        if not row:
            return jsonify({"status": "error", "message": "Задача не найдена в текущей смене"}), 404
        conn.execute(
            "UPDATE task_progress SET status = 'active', last_resumed_at = ? WHERE id = ?",
            (now_iso(), row["id"]),
        )
        return jsonify({"status": "ok"})


@app.route("/task/checklist", methods=["GET"])
def task_checklist():
    task_id = request.args.get("task_id", "__default__")
    shift_id = request.args.get("shift_id")
    feature_id = request.args.get("feature_id", "")
    with closing(get_db()) as conn:
        steps = get_checklist_steps(conn, task_id)
        checked = get_checklist_state(conn, shift_id, feature_id, len(steps)) if shift_id else [False] * len(steps)
        return jsonify({"status": "ok", "steps": steps, "checked": checked})


@app.route("/task/progress", methods=["POST"])
def task_progress_update():
    data = request.get_json(force=True, silent=True) or {}
    shift_id = data.get("shift_id")
    feature_id = str(data.get("feature_id", ""))
    task_id = str(data.get("task_id", "__default__")) or "__default__"
    step_index = data.get("step_index")
    checked = bool(data.get("checked", False))

    if shift_id is None or step_index is None:
        return jsonify({"status": "error", "message": "shift_id и step_index обязательны"}), 400

    with closing(get_db()) as conn, conn:
        task_row = conn.execute(
            "SELECT * FROM task_progress WHERE shift_id = ? AND feature_id = ?", (shift_id, feature_id)
        ).fetchone()
        if not task_row:
            return jsonify({"status": "error", "message": "Задача не найдена в текущей смене"}), 404
        if task_row["status"] != "active":
            return jsonify({"status": "error", "message": "Задача на паузе — сначала возобновите её, чтобы отмечать пункты чек-листа"}), 409

        conn.execute(
            "INSERT INTO checklist_state (shift_id, feature_id, step_index, checked) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(shift_id, feature_id, step_index) DO UPDATE SET checked = excluded.checked",
            (shift_id, feature_id, step_index, int(checked)),
        )
        steps = get_checklist_steps(conn, task_id)
        checked_arr = get_checklist_state(conn, shift_id, feature_id, len(steps))
        all_done = all(checked_arr) and len(checked_arr) > 0
        return jsonify({"status": "ok", "checked": checked_arr, "all_done": all_done})


@app.route("/admin/checklist", methods=["POST"])
def admin_set_checklist():
    """Задать индивидуальный чек-лист для конкретной задачи.
    task_id = '__default__' переопределяет чек-лист по умолчанию.
    Пример: POST {"task_id": "42", "steps": ["Замер", "Демонтаж", "Монтаж", "Проверка", "Уборка"]}"""
    data = request.get_json(force=True, silent=True) or {}
    task_id = str(data.get("task_id", "")).strip()
    steps = data.get("steps")
    if not task_id or not isinstance(steps, list) or not steps:
        return jsonify({"status": "error", "message": "task_id и непустой список steps обязательны"}), 400

    with closing(get_db()) as conn, conn:
        conn.execute(
            "INSERT INTO checklist_templates (task_id, steps_json) VALUES (?, ?) "
            "ON CONFLICT(task_id) DO UPDATE SET steps_json = excluded.steps_json",
            (task_id, json.dumps(steps, ensure_ascii=False)),
        )
        return jsonify({"status": "ok"})


init_db()

if __name__ == "__main__":
    threading.Thread(target=vk_bot_long_poll_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=5000)