# Блокнот — DevOps-лабораторные 0–3

Один минимальный блокнот используется во всех лабораторных. Страница HTML/CSS/JavaScript из `frontend/` обращается к Flask API из `backend/`, а Flask сохраняет заметки (`id`, `title`, `content`) в отдельной PostgreSQL.

| Лабораторная | Где будет конфигурация | Состояние | Отчёт |
| --- | --- | --- | --- |
| 0 — свой сервис | `backend/`, `frontend/` | Реализована и проверена локально | [reports/lab0.md](reports/lab0.md) |
| 1 — Nginx | `lab1-nginx/` | Реализована и проверена локально | [reports/lab1.md](reports/lab1.md) |
| 2 — Docker | `lab2-docker/` | Не начата | — |
| 3 — CI/CD | `.github/workflows/` | Не начата | — |

Папки ещё не начатых лабораторных будут созданы только при выполнении соответствующих заданий. Код блокнота остаётся общим.

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

## Лабораторная 1 — Nginx

Тот же блокнот работает за Nginx. Две копии Flask на Mac используют PostgreSQL из лабораторной 0. Nginx работает в официальном контейнере `nginx:1.28-alpine` на портах 80 и 443; Compose не нужен. Выполняйте команды из корня проекта. Перед первым запуском должны быть готовы `.env`, `.venv` и контейнер PostgreSQL из раздела лабораторной 0.

### Первый запуск

1. Если PostgreSQL остановлен, выполните `docker start devops-lab0-postgres`. Проверьте готовность:

   ```zsh
   docker exec devops-lab0-postgres pg_isready -U notebook -d notebook
   ```

2. Создайте локальный пароль администратора в уже существующем `.env`, если его ещё нет:

   ```zsh
   python3 - <<'PY'
   from pathlib import Path
   from secrets import token_urlsafe

   env_file = Path('.env')
   text = env_file.read_text()
   if not any(line.startswith('LAB1_ADMIN_PASSWORD=') for line in text.splitlines()):
       env_file.write_text(text.rstrip('\n') + '\nLAB1_ADMIN_PASSWORD=' + token_urlsafe(24) + '\n')
   PY
   chmod 600 .env
   ```

3. Создайте самоподписанный сертификат для двух локальных имён и файл `htpasswd`. Это локальные файлы, исключённые из Git:

   ```zsh
   mkdir -p lab1-nginx/certs
   openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
     -keyout lab1-nginx/certs/local.key -out lab1-nginx/certs/local.crt \
     -subj '/CN=notes.test' \
     -addext 'subjectAltName=DNS:notes.test,DNS:other.test'
   set -a
   source .env
   set +a
   printf '%s\n' "$LAB1_ADMIN_PASSWORD" | htpasswd -imc lab1-nginx/.htpasswd admin
   chmod 600 lab1-nginx/certs/local.key lab1-nginx/.htpasswd
   ```

4. Запустите две копии Flask:

   ```zsh
   ./lab1-nginx/start-backends.sh
   ```

   Скрипт запускает их на 8001 и 8002, записывает PID в игнорируемый каталог `lab1-nginx/run/`. Переменная `APP_HOST=0.0.0.0` позволяет контейнеру достучаться до Mac через `host.docker.internal`; обычный запуск лабораторной 0 по-прежнему слушает только `127.0.0.1:8000`.

5. Запустите Nginx:

   ```zsh
   docker run --name devops-lab1-nginx -d -p 80:80 -p 443:443 \
     -v "$PWD/lab1-nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
     -v "$PWD/frontend:/srv/frontend:ro" \
     -v "$PWD/lab1-nginx/docs:/srv/docs:ro" \
     -v "$PWD/lab1-nginx/other:/srv/other:ro" \
     -v "$PWD/lab1-nginx/pages:/srv/pages:ro" \
     -v "$PWD/lab1-nginx/certs:/etc/nginx/certs:ro" \
     -v "$PWD/lab1-nginx/.htpasswd:/etc/nginx/.htpasswd:ro" \
     nginx:1.28-alpine
   ```

   Если контейнер уже создан и остановлен, используйте `docker start devops-lab1-nginx`; если он работает, повторный `docker run` не нужен. После изменения `nginx.conf` выполните `docker exec devops-lab1-nginx nginx -t` и `docker exec devops-lab1-nginx nginx -s reload`.

### Проверка

`curl --resolve` задаёт локальный адрес для домена без изменения `/etc/hosts`; `-k` допускает локальный самоподписанный сертификат.

```zsh
curl --noproxy '*' -sSI --resolve notes.test:80:127.0.0.1 http://notes.test/
curl --noproxy '*' -skI --resolve notes.test:443:127.0.0.1 https://notes.test/
curl --noproxy '*' -skD - -o /dev/null --resolve notes.test:443:127.0.0.1 https://notes.test/api/notes
curl --noproxy '*' -sk --resolve other.test:443:127.0.0.1 https://other.test/
./lab1-nginx/check.sh
```

`check.sh` проверяет все обязательные пункты, **временно останавливает только `backend-1`**, проверяет ответы через оставшийся экземпляр и восстанавливает первый. При ошибке он завершается ненулевым кодом и тоже пытается восстановить первый экземпляр. Для просмотра в обычном браузере можно вручную добавить в `/etc/hosts` строку `127.0.0.1 notes.test other.test`; для команд и скрипта это не требуется. Браузер предупредит о самоподписанном сертификате.

### Остановка

```zsh
docker stop devops-lab1-nginx
kill "$(cat lab1-nginx/run/backend-1.pid)" "$(cat lab1-nginx/run/backend-2.pid)"
```

Контейнер PostgreSQL и его том при этом остаются на месте. Для повторного запуска выполните `./lab1-nginx/start-backends.sh` и `docker start devops-lab1-nginx`.
