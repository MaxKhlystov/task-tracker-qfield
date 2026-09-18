# 🖥️ Сервер учёта задач и смен

Flask-приложение, которое:
- принимает данные о сменах и задачах от QField-плагина,
- ведёт таймеры и чек-листы в SQLite,
- генерирует отчёты `.docx`/`.pdf`,
- отправляет уведомления и отвечает на команды в VK.

---

## 📋 Требования

| Компонент | Версия | Зачем |
|-----------|--------|-------|
| Python | 3.9+ | запуск сервера |
| LibreOffice | любая | конвертация docx → pdf |
| pip-пакеты | см. `requirements.txt` | Flask, docxtpl, requests |

---

## 📦 Установка

### 1. Python

Скачай с https://www.python.org/downloads/.
⚠️ При установке на Windows обязательно поставь галочку **"Add python.exe to PATH"**.

### 2. LibreOffice

Скачай с https://www.libreoffice.org/download/download/.
На Windows по умолчанию встанет в:
```
C:\Program Files\LibreOffice\program\soffice.exe
```

### 3. Зависимости Python

```bash
cd server
pip install -r requirements.txt
```

### 4. Шаблоны отчётов

Если файлы `templates/report_template.docx` и `templates/shift_report_template.docx`

### 5. Переменные окружения

Скопируй `.env.example` в `.env` и заполни:

```bash
# Windows (cmd)
set VK_ACCESS_TOKEN=твой_токен
set VK_PEER_ID=2000000001
set VK_GROUP_ID=241290401
set SOFFICE_PATH=C:\Program Files\LibreOffice\program\soffice.exe

# Linux/macOS
export VK_ACCESS_TOKEN=...
export VK_PEER_ID=...
export VK_GROUP_ID=...
export SOFFICE_PATH=/usr/bin/soffice
```

> 💡 **VK_ACCESS_TOKEN** получается в разделе сообщества
> «Управление → Работа с API → Ключи доступа». Токену нужно право
> **«Управление сообществом»** и **«Сообщения сообщества»**.
>
> 💡 **VK_PEER_ID** — числовой ID куратора. Куратор должен **первым**
> написать сообществу, иначе VK не даст боту написать ему.

### 6. Long Poll API для бота

В настройках сообщества: **Управление → Long Poll API → Включить**,
тип событий — «Входящие сообщения».

---

## ▶️ Запуск

```bash
python app.py
```

Если увидишь:
```
Running on http://0.0.0.0:5000
[VK бот] Long Poll запущен, жду сообщений...
```
— всё работает.

---

## 🌐 Проверка

| Что | Как |
|-----|-----|
| Сервер жив | Открой http://localhost:5000/ping |
| Доступен из сети | Узнай IP: `ipconfig` (Windows) / `ip a` (Linux), открой `http://IP:5000/ping` с планшета |
| VK-бот | Напиши сообществу в VK слово `статус` |

### 🔥 Брандмауэр Windows

При первом запуске Windows спросит разрешение — **разреши для приватных сетей**,
иначе планшет не подключится.

---

## 📡 API-эндпоинты

### Базовые

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/ping` | Проверка живости |
| POST | `/submit_task` | Отчёт по завершённой задаче (docx + pdf + VK) |

### Смены

| Метод | Путь | Тело / параметры |
|-------|------|------------------|
| GET | `/shift/active?worker_name=X` | Найти открытую смену работника |
| POST | `/shift/start` | `{"worker_name": "..."}` |
| POST | `/shift/pause` | `{"shift_id": N, "reason": "..."}` |
| POST | `/shift/resume` | `{"shift_id": N}` |
| POST | `/shift/end` | `{"shift_id": N}` — генерирует итоговый отчёт |
| GET | `/shift/status?shift_id=N` | Полное состояние смены и задач |

### Задачи

| Метод | Путь | Тело |
|-------|------|------|
| POST | `/task/start` | `{shift_id, feature_id, task_id, name}` |
| POST | `/task/pause` | `{shift_id, feature_id}` |
| POST | `/task/resume` | `{shift_id, feature_id}` |
| GET | `/task/checklist?task_id=...&shift_id=...&feature_id=...` | — |
| POST | `/task/progress` | `{shift_id, feature_id, task_id, step_index, checked}` |

### Админ

| Метод | Путь | Тело |
|-------|------|------|
| POST | `/admin/checklist` | `{"task_id": "42", "steps": ["Замер", "Монтаж", ...]}` |

`task_id = "__default__"` переопределяет чек-лист по умолчанию.

---

## 🗄️ База данных

SQLite-файл `tasks.db` создаётся автоматически рядом с `app.py`.

**Таблицы:**
- `shifts` — смены работников
- `pauses` — паузы смены с причинами
- `task_progress` — таймер и статус каждой задачи в смене
- `checklist_templates` — настраиваемые чек-листы по `task_id`
- `checklist_state` — отметки пунктов чек-листа

Схема создаётся идемпотентно при старте — можно запускать сколько угодно раз.

---

## 📄 Где отчёты

`server/reports/` — рядом с `app.py`:
- `task_<ID>_<дата>_<время>.docx/.pdf` — по задаче
- `shift_<работник>_<дата>_<время>.docx/.pdf` — по смене

---

## 🛠️ Решение проблем

| Симптом | Причина | Решение |
|---------|---------|---------|
| `[WinError 2]` при конвертации | Windows не видит `soffice` | Задай `SOFFICE_PATH` или добавь в `PATH` |
| `"vk": {"sent": false, ...}` | Токен/peer_id/группа не настроены | Проверь `.env`, проверь, что куратор написал сообществу |
| Бот не отвечает | Long Poll выключен | Включи Long Poll API в настройках сообщества |
| Планшет не подключается | Брандмауэр / разные сети | Устройства должны быть в одной Wi-Fi сети, разреши Python в брандмауэре |
| `Шаблон не найден` | Нет docx-файлов | Запусти `python generate_template.py` |
