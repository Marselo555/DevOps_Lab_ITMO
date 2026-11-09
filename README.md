# Блокнот — DevOps-лабораторные 0–3

Один минимальный блокнот используется во всех лабораторных. Страница HTML/CSS/JavaScript из `frontend/` обращается к Flask API из `backend/`, а Flask сохраняет заметки (`id`, `title`, `content`) в отдельной PostgreSQL.

| Лабораторная | Где будет конфигурация | Состояние | Отчёт |
| --- | --- | --- | --- |
| 0 — свой сервис | `backend/`, `frontend/` | Реализована и проверена локально | [reports/lab0.md](reports/lab0.md) |
| 1 — Nginx | `lab1-nginx/` | Не начата | — |
| 2 — Docker | `lab2-docker/` | Не начата | — |
| 3 — CI/CD | `.github/workflows/` | Не начата | — |

Папки будущих лабораторных будут созданы только при выполнении соответствующих заданий. Код блокнота остаётся общим.

## Лабораторная 0 — свой сервис

На macOS PostgreSQL запускается в Docker Desktop как отдельный сетевой сервис. Flask отдаёт страницу и API; Docker Compose, Nginx и CI/CD в лабораторной 0 не используются.

### Первый запуск на macOS

Нужны работающий Docker Desktop и Python 3.9 или новее. Выполняйте команды из корня проекта.

1. Создайте локальный `.env` с паролем. Файл исключён из Git; повторный запуск команды не заменит существующий пароль:

   ```zsh
   python3 - <<'PY'
   from pathlib import Path
   from secrets import token_hex

   path = Path('.env')
   if not path.exists():
       example = Path('.env.example').read_text()
       path.write_text(example.replace('replace-with-local-password', token_hex(24)))
   PY
   chmod 600 .env
   ```

2. Запустите PostgreSQL как отдельный сетевой сервис. Данные находятся в именованном томе `devops_lab0_notes_data`:

   ```zsh
   docker run --name devops-lab0-postgres --env-file .env -p 127.0.0.1:55432:5432 -v devops_lab0_notes_data:/var/lib/postgresql/data -d postgres:16
   docker exec devops-lab0-postgres pg_isready -U notebook -d notebook
   ```

   Если контейнер уже создан и остановлен, вместо `docker run` выполните `docker start devops-lab0-postgres`. Дождитесь ответа `accepting connections` от `pg_isready`.

3. Установите две Python-зависимости в локальное виртуальное окружение:

   ```zsh
   python3 -m venv .venv
   .venv/bin/python -m pip install -r backend/requirements.txt
   ```

4. Запустите Flask в том же терминале:

   ```zsh
   set -a
   source .env
   set +a
   .venv/bin/python backend/app.py
   ```

   При запуске создаётся таблица `notes`, если её ещё нет. Flask слушает `127.0.0.1:8000`; порт 5000 на проверенном Mac занят системным `ControlCenter`.

5. Откройте приложение в браузере (в другом терминале):

   ```zsh
   open http://127.0.0.1:8000/
   ```

   Создайте заметку, обновите страницу и проверьте, что она осталась. Кнопки рядом с заметкой изменяют и удаляют её.

### Проверка данных и API

```zsh
curl -sS http://127.0.0.1:8000/api/notes
docker exec devops-lab0-postgres psql -U notebook -d notebook -c 'SELECT id, title, content FROM notes ORDER BY id;'
```

Список API: `GET /api/notes`, `POST /api/notes`, `PUT /api/notes/<id>`, `DELETE /api/notes/<id>`. Для записи нужен JSON с `title` и `content`.

### Остановка и повторный запуск

Остановите Flask через `Ctrl+C` в его терминале. При необходимости остановите только контейнер этого проекта:

```zsh
docker stop devops-lab0-postgres
```

Для повторного запуска выполните `docker start devops-lab0-postgres`, дождитесь `pg_isready` и снова запустите Flask командами из шага 4. Не удаляйте контейнер или том, если хотите сохранить заметки.
