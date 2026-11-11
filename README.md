# Блокнот — DevOps-лабораторные 0–3

Во всех четырёх лабораторных используется один блокнот. Страница HTML/CSS/JavaScript из `frontend/` обращается к Flask API из `backend/`. Flask сохраняет заметки с полями `id`, `title` и `content` в PostgreSQL.

| Лабораторная | Файлы | Состояние | Отчёт |
| --- | --- | --- | --- |
| 0 — свой сервис | `backend/`, `frontend/` | Реализована и проверена локально | [reports/lab0.md](reports/lab0.md) |
| 1 — Nginx | `lab1-nginx/` | Реализована и проверена локально | [reports/lab1.md](reports/lab1.md) |
| 1★ — проверка безопасности Nginx | `reports/evidence/`, `reports/screenshots/` | Две завершённые проверки внешнего сайта и одна собственного локального Nginx | [reports/lab1-bonus.md](reports/lab1-bonus.md) |
| 2 — Docker | `lab2-docker/` | Реализована и проверена локально | [reports/lab2.md](reports/lab2.md) |
| 2★ — устойчивый стек | `lab2-docker/compose.bonus.yaml` | Проверена в отдельном Compose-проекте | [reports/lab2-bonus.md](reports/lab2-bonus.md) |
| 3 — CI/CD | `.github/workflows/` | Красные и зелёный прогоны GitHub проверены, образ опубликован и развёрнут на Mac | [reports/lab3.md](reports/lab3.md) |
| 3★ — откат | `lab2-docker/rollback.py` | Сломанный релиз и откат проверены локально | [reports/lab3-bonus.md](reports/lab3-bonus.md) |

Код блокнота общий для всех лабораторных; в отдельных каталогах находятся их конфигурации и проверки.

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

`check.sh` проверяет обязательные настройки. Для проверки отказоустойчивости он **временно останавливает только `backend-1`**, отправляет запросы через оставшийся экземпляр и снова запускает первый. При ошибке скрипт завершается ненулевым кодом и также пытается восстановить `backend-1`. Для просмотра в браузере можно добавить в `/etc/hosts` строку `127.0.0.1 notes.test other.test`; командам `curl` и скрипту это не требуется. Браузер предупредит о самоподписанном сертификате.

### Остановка

```zsh
docker stop devops-lab1-nginx
kill "$(cat lab1-nginx/run/backend-1.pid)" "$(cat lab1-nginx/run/backend-2.pid)"
```

Контейнер PostgreSQL и его том при этом остаются на месте. Для повторного запуска выполните `./lab1-nginx/start-backends.sh` и `docker start devops-lab1-nginx`.

## Лабораторная 2 — Docker

Тот же блокнот запускается в отдельном Compose-проекте `devops-lab2`: Nginx раздаёт `frontend/`, Flask из хорошего образа обслуживает `/api`, PostgreSQL хранит заметки в именованном томе `devops-lab2_notes_data`. Порт `127.0.0.1:8082` не конфликтует с лабораторной 1 на 80/443. Нужен запущенный Docker Desktop. Команды выполняются из корня проекта на macOS.

### Подготовка и запуск

Если локального `.env` ещё нет, создайте его по инструкции лабораторной 0 выше. Пароль хранится только в `.env`, который исключён из Git. Соберите оба варианта Flask-образа и поднимите три сервиса:

```zsh
docker build -f lab2-docker/Dockerfile.bad -t devops-lab2-bad:lab2 .
docker build -f lab2-docker/Dockerfile.good -t devops-lab2-good:lab2 .
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | rg '^devops-lab2-(bad|good):lab2 '
docker compose --env-file .env -f lab2-docker/compose.yaml up -d --build
docker compose --env-file .env -f lab2-docker/compose.yaml ps
```

При первом запуске PostgreSQL инициализирует том, а Flask ждёт готовности БД. Дождитесь статуса `healthy` у `devops-lab2-backend-1` в выводе `ps`. Затем откройте блокнот:

```zsh
open http://127.0.0.1:8082/
```

### Проверка

```zsh
curl --noproxy '*' -sS http://127.0.0.1:8082/api/notes
docker compose --env-file .env -f lab2-docker/compose.yaml exec -T db \
  psql -U notebook -d notebook -c 'SELECT id, title, content FROM notes ORDER BY id;'
docker compose --env-file .env -f lab2-docker/compose.yaml exec -T backend whoami
docker compose --env-file .env -f lab2-docker/compose.yaml exec -T frontend \
  wget -qO- http://backend:8000/api/notes
docker compose --env-file .env -f lab2-docker/compose.yaml exec -T frontend \
  nc -z -w 2 db 5432
```

Последняя команда должна завершиться ошибкой: frontend подключён только к сети `web`, а БД — только к `data`. Backend подключён к обеим сетям. Для демонстрации сохранности создайте заметку в браузере, остановите и удалите **только контейнер БД этого Compose-проекта**, затем поднимите его снова и проверьте заметку:

```zsh
docker compose --env-file .env -f lab2-docker/compose.yaml stop db
docker rm devops-lab2-db-1
docker compose --env-file .env -f lab2-docker/compose.yaml up -d db
docker compose --env-file .env -f lab2-docker/compose.yaml exec -T db \
  psql -U notebook -d notebook -c 'SELECT id, title, content FROM notes ORDER BY id;'
```

Том `devops-lab2_notes_data` при этом сохраняется. Размеры образов, время пересборки и результаты сетевой проверки приведены в [отчёте обычной лабораторной 2](reports/lab2.md). Дополнительное задание «Устойчивый стек» описано в [отдельном отчёте 2★](reports/lab2-bonus.md).

### Безопасная остановка

```zsh
docker compose --env-file .env -f lab2-docker/compose.yaml stop
```

Повторный запуск: `docker compose --env-file .env -f lab2-docker/compose.yaml up -d`. Не используйте `down -v`, если заметки нужно сохранить.

## Лабораторная 3 — CI/CD

В `.github/workflows/` находятся два workflow: учебный «плохой» запускается вручную, «хороший» проверяет Ruff и CRUD-тест с PostgreSQL, собирает образ для `linux/arm64`, сканирует его Trivy, публикует в GHCR и развёртывает на Mac через self-hosted runner. Последний шаг выполняет `curl`. [Успешный прогон](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860700694) опубликовал образ и развернул сервис; [прогон с ошибкой lint](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42859654550) и [прогон с CRITICAL CVE](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860754501) остановились до деплоя. Вывод команд, таблица проверок и скриншоты находятся в [отчёте](reports/lab3.md).

### Локальные проверки

```zsh
.venv/bin/python -m pip install -r requirements-ci.txt
.venv/bin/ruff check backend tests
set -a
source .env
set +a
DB_HOST=127.0.0.1 DB_PORT=55432 .venv/bin/python -m unittest discover -s tests -v
docker build -f lab2-docker/Dockerfile.good -t devops-lab3-good:local .
```

Последняя строка собирает только локальный образ для проверки. Рабочий деплой лабораторной 3 должен **скачать опубликованный GHCR-образ**, а не собирать его на Mac. Для повторения скана Trivy через Docker Desktop и таблицы CRITICAL/HIGH используйте команды в отчёте.

### GitHub и Mac

GitHub secret `LAB3_CI_DB_PASSWORD` и Mac runner `macbook-devops` уже настроены. Для повторного запуска нужен работающий Docker Desktop, локальный `.env` и запущенный runner под пользователем с доступом к Docker. Деплой использует отдельный Compose-проект `devops-lab3`, порт `127.0.0.1:8083` и том `devops-lab3_notes_data`.

Ручной плохой workflow запускается через **Actions → Lab 3 bad pipeline demo → Run workflow**. Для повторения security gate запустите **Lab 3 CI/CD → Run workflow** с `scan_bad_image=true`. Обычный push в `main` запускает полный pipeline; рабочий образ публикуется в GHCR с тегом полного SHA коммита. Секреты не пересылайте в чат и не записывайте в репозиторий.

После деплоя проверьте приложение на Mac:

```zsh
open http://127.0.0.1:8083/
curl --noproxy '*' -fsS http://127.0.0.1:8083/api/notes
docker compose -p devops-lab3 --env-file .env -f lab2-docker/compose.yaml ps
```

Для безопасной остановки **только** стека лабораторной 3 после демонстрации:

```zsh
docker compose -p devops-lab3 --env-file .env -f lab2-docker/compose.yaml stop
```

Не используйте `down -v`: том БД должен сохранять заметки.

## Лабораторная 3★ — откат

Для отката проекта `devops-lab3` укажите полный SHA ранее успешно задеплоенного образа, который уже есть на Mac. Проверенный в отчёте запуск:

```zsh
python3 lab2-docker/rollback.py \
  ghcr.io/marselo555/devops-lab-itmo-notebook:2f8ca801a2c39e1ff72e9c4e4fae15137baa8ea6
```

Скрипт возвращает backend и frontend к рабочей версии, не пересоздавая PostgreSQL. Команды и скриншоты демонстрации находятся в [отдельном отчёте 3★](reports/lab3-bonus.md).
