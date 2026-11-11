# Лабораторная 2 — Docker

> Размеры образов и время сборки в этом отчёте относятся к версии `lab2-done`. Позже, для лабораторной 3, базовый образ в `Dockerfile.good` обновили из-за CRITICAL CVE. Результаты нового сканирования приведены в [отчёте лабораторной 3](lab3.md).

## Цель и состав

Цель работы — собрать два образа для Flask-бэкенда блокнота, сравнить их и запустить фронтенд, бэкенд и PostgreSQL через Docker Compose. Проверки выполнены на macOS с Docker Desktop; `uname -m` и архитектура образов — `arm64`. Дополнительное задание выполнено позднее и описано в конце отчёта.

В Compose frontend — Nginx со статикой из общей папки `frontend/`, backend — Flask из общего `backend/app.py`, db — PostgreSQL. Блокнот доступен на `http://127.0.0.1:8082/`. Лабораторная 1 на портах 80/443 осталась отдельной.

## Два Dockerfile

### Плохой: `lab2-docker/Dockerfile.bad`

```dockerfile
# BAD: the full Python image is much larger than the slim runtime image.
FROM python:3.11

WORKDIR /app

# BAD: changing app.py invalidates the following dependency-install layer.
COPY backend/ /app/
RUN pip install --no-cache-dir -r requirements.txt

# BAD: no USER directive, so the process runs as root.
EXPOSE 8000
CMD ["python", "app.py"]
```

### Хороший: `lab2-docker/Dockerfile.good`

```dockerfile
FROM python:3.11.14-slim-bookworm AS builder

WORKDIR /build
COPY backend/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.11.14-slim-bookworm

RUN groupadd --system notebook && useradd --system --gid notebook --home-dir /app notebook
WORKDIR /app
COPY --from=builder /install /usr/local
COPY backend/app.py .

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER notebook
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/notes', timeout=2)" || exit 1
CMD ["python", "app.py"]
```

Корневой `.dockerignore` исключает `.git`, `.venv`, `.env*`, ключи и сертификаты, локальные данные БД, `__pycache__`, документы заданий, отчёты, `frontend/` и файлы лабораторной 1 из контекста сборки. Он действует для обоих образов; отсутствие `.dockerignore` не считается одной из выбранных плохих практик.

| Плохая практика | Как исправлено |
| --- | --- |
| Полный `python:3.11` как база | В итоговом образе используется более лёгкий `python:3.11.14-slim-bookworm` с зафиксированной версией |
| Процесс Flask работает от root | Создан отдельный пользователь `notebook`; `USER notebook` |
| `COPY backend/` стоит перед установкой зависимостей | Сначала копируется `requirements.txt` и ставятся зависимости, затем копируется `app.py`; изменение кода сохраняет слой `pip install` в кеше |
| Нет проверки работоспособности контейнера | `HEALTHCHECK` вызывает существующий `GET /api/notes` стандартной библиотекой Python |

Хороший Dockerfile использует два этапа: `builder` ставит зависимости, итоговый этап содержит только runtime и приложение. Отдельная библиотека для healthcheck не добавлялась. В `backend/app.py` добавлено только ожидание готовности PostgreSQL при первом запуске Compose: `DB_STARTUP_RETRIES=30` задаётся в Compose, а запуск лабораторных 0 и 1 сохраняет прежнее значение по умолчанию `1`. API и поведение заметок не менялись.

## Сборка и сравнение образов

Оба образа собраны командами:

```zsh
docker build -f lab2-docker/Dockerfile.bad -t devops-lab2-bad:lab2 .
docker build -f lab2-docker/Dockerfile.good -t devops-lab2-good:lab2 .
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | rg '^devops-lab2-(bad|good):lab2 '
```

Вывод `docker images` после итоговой сборки:

```text
devops-lab2-bad:lab2 1.64GB
devops-lab2-good:lab2 246MB
```

`docker image inspect` показал точные размеры: плохой — **1 644 096 506 байт**, хороший — **246 068 410 байт**. Оба образа имеют архитектуру `arm64`. Хороший примерно в 6,7 раза меньше. Полный образ Python содержит больше системных пакетов, а multi-stage сборка оставляет в итоговом образе только необходимые зависимости и приложение.

Оба образа запускались во временных контейнерах сети `devops-lab2_data` с локальным `.env`, `DB_HOST=db`, `DB_PORT=5432`, `APP_HOST=0.0.0.0` и `APP_PORT=8000`. Команда `docker exec <container> whoami` и запрос к API внутри каждого контейнера дали следующие результаты:

```text
bad user=root
bad api=200
bad health=not configured
good user=notebook
good api=200
good health=starting
```

Статус `starting` получен сразу после запуска временного хорошего контейнера. После интервала проверки backend в Compose получил статус `healthy` (см. ниже). Временные контейнеры остановлены; контейнеры и тома других лабораторных не затронуты.

Повторная команда для постоянно работающего хорошего образа в Compose:

```zsh
docker exec devops-lab2-backend-1 whoami
docker inspect devops-lab2-backend-1 --format '{{.State.Health.Status}}'
```

Фактический вывод: `notebook`, затем `healthy`.

### Время повторной сборки после правки строки кода

Для измерения в `backend/app.py` временно изменилась **одна строка кода**: в вызове `Flask(...)` двойные кавычки вокруг путей заменили одинарными. Значения и поведение приложения остались прежними. Оба образа пересобрали командой `/usr/bin/time -p docker build --progress=plain -f lab2-docker/Dockerfile.<variant> -t devops-lab2-<variant>:codecache .`. Затем файл вернули к исходным байтам: SHA-256 до и после — `81e64f4a42e798f8fe35b15786e438dab7115fbd5ab97657cf0d49f49ee6a4cf`. Тестовая правка в коде не осталась.

| Повторная сборка | `real` | Слой установки зависимостей |
| --- | ---: | --- |
| Плохой образ | 8,23 с | `RUN pip install ...` выполнен снова, слой занял 6,5 с |
| Хороший образ | 0,35 с | `RUN pip install ...` — `CACHED` |

Фрагменты фактического вывода:

```text
bad  #8 [4/4] RUN pip install --no-cache-dir -r requirements.txt
bad  #8 DONE 6.5s
bad  real 8.23
good #6 [builder 4/4] RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
good #6 CACHED
good real 0.35
```

Изменение `app.py` в плохом образе меняет слой `COPY backend/`, поэтому Docker заново выполняет следующую установку зависимостей. В хорошем образе слой зависимостей зависит только от `requirements.txt`.

## Docker Compose

`lab2-docker/compose.yaml`:

```yaml
name: devops-lab2

services:
  frontend:
    image: nginx:1.28-alpine
    ports:
      - "127.0.0.1:8082:80"
    volumes:
      - ../frontend:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - backend
    networks:
      - web

  backend:
    build:
      context: ..
      dockerfile: lab2-docker/Dockerfile.good
    image: devops-lab2-good:local
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      DB_HOST: db
      DB_PORT: "5432"
      DB_STARTUP_RETRIES: "30"
      APP_HOST: 0.0.0.0
      APP_PORT: "8000"
    depends_on:
      - db
    networks:
      - web
      - data

  db:
    image: postgres:16
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - notes_data:/var/lib/postgresql/data
    networks:
      - data

networks:
  web:
  data:

volumes:
  notes_data:
```

`lab2-docker/nginx.conf` отдаёт файлы `frontend/`, а `/api` направляет на `backend:8000`. В корне проекта с уже подготовленным локальным `.env` стек запускается одной командой:

```zsh
docker compose --env-file .env -f lab2-docker/compose.yaml up -d --build
docker compose --env-file .env -f lab2-docker/compose.yaml ps
```

После первого запуска надо дождаться готовности PostgreSQL и статуса `healthy` у backend. После остановки и повторного запуска всех трёх сервисов получен вывод:

```text
NAME                     IMAGE                    SERVICE    STATUS                   PORTS
devops-lab2-backend-1    devops-lab2-good:local   backend    Up 3 minutes (healthy)   8000/tcp
devops-lab2-db-1         postgres:16              db         Up 3 minutes             5432/tcp
devops-lab2-frontend-1   nginx:1.28-alpine        frontend   Up 3 minutes             127.0.0.1:8082->80/tcp
```

Через опубликованный адрес `curl --noproxy '*' http://127.0.0.1:8082/` получил HTTP **200**, `GET /api/notes` получил HTTP **200**. Отдельные запросы к `/static/style.css` и `/static/app.js` тоже дали HTTP **200** с типами `text/css` и `application/javascript`; frontend обслуживает Nginx. Через этот же адрес операции с временной заметкой дали `POST 201`, `GET 200`, `PUT 200`, `DELETE 204`, затем `GET 200`; постоянная проверочная заметка осталась.

## Сохранность данных в именованном томе

Через `POST http://127.0.0.1:8082/api/notes` создана заметка `id=1`, заголовок `Лаба 2: сохранность`. До пересоздания контейнера SQL-запрос показывал строку. Затем выполнено:

```zsh
docker compose --env-file .env -f lab2-docker/compose.yaml stop db
docker rm devops-lab2-db-1
docker compose --env-file .env -f lab2-docker/compose.yaml up -d db
docker compose --env-file .env -f lab2-docker/compose.yaml exec -T db \
  psql -U notebook -d notebook -c 'SELECT id, title, content FROM notes ORDER BY id;'
```

ID контейнера БД изменился с `e5d0b6543aaa…` на `e3afa41b4313…`, а именованный том остался `devops-lab2_notes_data`. После пересоздания `pg_isready` ответил `accepting connections`, SQL вернул:

```text
 id |        title        |                        content
----+---------------------+--------------------------------------------------------
  1 | Лаба 2: сохранность | Эта заметка должна пережить пересоздание контейнера БД
(1 row)
```

Через Nginx `GET /api/notes` также вернул ту же заметку с HTTP 200. После дополнительного `docker compose stop` и `up -d` данные снова читались. `docker compose down -v` не выполнялся; том и заметка сохранены для демонстрации.

## Сетевая изоляция

Подключение контейнеров к сетям Compose проверено напрямую:

```text
frontend networks=devops-lab2_web
backend networks=devops-lab2_data devops-lab2_web
db networks=devops-lab2_data
```

Команда из frontend `wget -qO- http://backend:8000/api/notes` вернула JSON со строкой `id=1`. Из backend прямой SQL-запрос через `psycopg2` вернул `('notebook', 5432)`, то есть соединение установлено именно с PostgreSQL. Прямые попытки из frontend:

```text
nc -z -w 2 db 5432          → nc: bad address 'db'; код выхода 1
nc -z -w 2 172.20.0.2 5432 → код выхода 1
```

На момент проверки `172.20.0.2` был адресом контейнера БД в сети `devops-lab2_data`; его получили через `docker inspect`. Попытка по IP также завершилась ошибкой, значит дело не только в отсутствии DNS-имени: у frontend нет прямого сетевого маршрута к БД.

## Сохранение предыдущих лабораторных

После запуска Compose проверены `docker exec devops-lab1-nginx nginx -t`, HTTPS-страница лабораторной 1 и её `/api/notes`: конфигурация валидна, оба запроса дали HTTP 200. Отдельные контейнеры лабораторной 0 и 1 и их данные не удалялись.

## Скриншоты

### Три работающих контейнера

`docker compose ... ps`: frontend, backend, db; backend имеет статус `healthy`.

![Три работающих контейнера Compose](screenshots/lab2-containers.png)

### Размеры образов и пользователь

`docker images` показывает плохой образ 1,64 GB и хороший 246 MB; `docker exec ... whoami` возвращает `notebook`.

![Размеры образов и пользователь backend](screenshots/lab2-images-user.png)

### Сохранность данных и отсутствие прямого доступа frontend к БД

SQL показывает заметку после пересоздания контейнера БД. Попытка соединения `frontend → db:5432` по имени завершается ошибкой, код выхода `1`. Дополнительная проверка по IP приведена выше в текстовом выводе команд.

![SQL-запрос и ошибка соединения frontend с БД](screenshots/lab2-persistence-network.png)

### Страница блокнота

Блокнот открыт с сохранённой заметкой.

![Страница блокнота с сохранённой заметкой](screenshots/lab2-browser.png)

## Статус обязательных требований обычной лабораторной 2

| Требование DOCX | Статус | Проверка |
| --- | --- | --- |
| Два собираемых и запускаемых образа сервиса | PASS | Оба `docker build` и оба API 200 |
| Не менее трёх bad practices и исправления | PASS | Полная база, root, неудачный порядок слоёв; также отсутствует healthcheck |
| Multi-stage, отдельный пользователь, версия базы, `.dockerignore`, `HEALTHCHECK`, кеш | PASS | Dockerfile, `image inspect`, `whoami=notebook`, `healthy`, измерение кеша |
| Хороший образ меньше плохого | PASS | 246 MB против 1,64 GB |
| Пересборка после изменения одной строки | PASS | 0,35 с против 8,23 с; исходный файл восстановлен |
| Compose поднимает frontend, backend, БД одной командой | PASS | Ровно 3 сервиса, страница/API 200, SQL и CRUD |
| Данные сохраняются после удаления контейнера БД | PASS | Контейнер пересоздан, SQL и API вернули заметку `id=1` |
| Frontend не подключается прямо к БД | PASS | Отдельные сети; `nc` по имени и IP завершились ошибкой; backend SQL успешен |
| Скриншоты контейнеров и проверок в отчёте | PASS | Четыре реальные изображения добавлены выше |

## Дополнительное задание — устойчивый стек

### Отдельный проект и настройки

Испытания проведены в проекте `devops-lab2-bonus` на `127.0.0.1:8084`. Он использует тот же код блокнота и те же три сервиса из `compose.yaml`, но отдельные сети и том `devops-lab2-bonus_notes_data`. Обычный стек на порту 8082 и деплой лабораторной 3 на порту 8083 не перенастраивались. Для звёздочки добавлен только [Compose override](../lab2-docker/compose.bonus.yaml); исходный `compose.yaml` остался прежним.

Запуск из корня проекта с локальным `.env`:

```zsh
FRONTEND_PORT=8084 BACKEND_IMAGE=devops-lab2-bonus:local \
  docker compose -p devops-lab2-bonus --env-file .env \
  -f lab2-docker/compose.yaml -f lab2-docker/compose.bonus.yaml \
  up -d --build --wait --wait-timeout 120
```

`up --wait` дождался последовательности `db Healthy → backend Healthy → frontend Healthy`. У всех трёх сервисов `restart: unless-stopped`. `backend` зависит от `db: service_healthy`, а `frontend` — от `backend: service_healthy`. Проверка БД вызывает `pg_isready`; проверка backend делает `GET /api/notes` и поэтому проверяет также доступ к БД; проверка frontend запрашивает `/` через локальный Nginx. На старте `DB_STARTUP_RETRIES=30` остаётся запасным ожиданием в Flask. После запуска каждое обращение к API создаёт новое соединение с PostgreSQL, поэтому после перезапуска БД backend смог подключиться повторно без собственного рестарта.

| Сервис | CPU | RAM | Проверка здоровья |
| --- | ---: | ---: | --- |
| frontend | 0,5 CPU | 64 MiB | HTTP-запрос к `/` |
| backend | 1 CPU | 128 MiB | HTTP-запрос к `/api/notes` |
| db | 0,5 CPU | 256 MiB | `pg_isready` |

Это итоговые лимиты override. Переменные `BONUS_BACKEND_CPUS` и `BONUS_BACKEND_MEM_LIMIT` позволили временно менять только backend тестового проекта. `docker inspect` подтвердил реальные ограничения контейнеров: `NanoCpus=500000000/1000000000/500000000`, память `67108864/134217728/268435456` байт соответственно.

### Авария PostgreSQL и восстановление

Перед опытом через API тестового проекта создана заметка `id=1` с заголовком `Лаба 2★: сохранность` (`POST` вернул HTTP 201). Страница и API до аварии отвечали HTTP 200, все три контейнера были `healthy`.

Сначала выполнен `docker kill devops-lab2-bonus-db-1`. В этом Docker Desktop он **не** вызвал автоматический рестарт: контейнер остался `exited (137)`, `restart_count=0`, backend стал `unhealthy`. [Фактический вывод](evidence/lab2-bonus-docker-kill.txt) сохранён. Команда остановки контейнера через Docker API была учтена как ручная остановка; так же `docker stop` подавляет политику рестарта до ручного запуска контейнера или перезапуска демона. Это соответствует [описанию restart policies в Docker](https://docs.docker.com/engine/containers/start-containers-automatically/). БД тестового проекта запущена обратно вручную командой `docker start devops-lab2-bonus-db-1`.

Для проверки именно падения процесса выполнена команда **внутри тестового контейнера**:

```zsh
docker exec -u root devops-lab2-bonus-db-1 sh -c 'kill -QUIT 1'
```

PostgreSQL трактует SIGQUIT как [аварийное немедленное завершение](https://www.postgresql.org/docs/16/server-shutdown.html). Docker автоматически запустил тот же контейнер: PID процесса БД изменился с `62062` на `64323`, `restart_count` вырос с `0` до `1`. В журнале PostgreSQL есть `received immediate shutdown request`, затем `database system was not properly shut down; automatic recovery in progress` и `database system is ready to accept connections`. После восстановления `pg_isready` ответил `accepting connections`, все три healthcheck стали `healthy`; PID backend не менялся, его `restart_count=0`.

Повторные запросы дали `frontend HTTP 200` и `API HTTP 200`; JSON API по-прежнему содержал заметку `id=1`. Это одновременно проверяет сохранность тома и повторное подключение backend к БД. Полный вывод команд, состояний контейнеров, `curl` и журнала — в [файле восстановления](evidence/lab2-bonus-recovery.txt).

### CPU и память под нагрузкой

Нагрузку создавал короткий Python-скрипт из стандартной библиотеки (`urllib.request`, `ThreadPoolExecutor`) во временном файле `/private/tmp/lab2_bonus_load.py`. Каждый поток отправлял не более 150 `GET /api/notes`; общее время ограничено 15 секундами, ожидание одного ответа — 3 секунды. Для CPU использованы 4 потока (максимум 600 запросов), для памяти и итоговой проверки — 8 потоков (максимум 1200 запросов). Во время работы снимались `docker stats --no-stream`; счётчики CPU и памяти читались из `/sys/fs/cgroup/` внутри backend. Код генератора не добавляет зависимости в приложение.

Основные команды опыта (для памяти менялось только значение `BONUS_BACKEND_MEM_LIMIT` в такой же команде `up`):

```zsh
FRONTEND_PORT=8084 BACKEND_IMAGE=devops-lab2-bonus:local BONUS_BACKEND_CPUS=0.2 \
  docker compose -p devops-lab2-bonus --env-file .env \
  -f lab2-docker/compose.yaml -f lab2-docker/compose.bonus.yaml \
  up -d --no-build --wait --wait-timeout 120
python3 /private/tmp/lab2_bonus_load.py
docker stats --no-stream devops-lab2-bonus-frontend-1 \
  devops-lab2-bonus-backend-1 devops-lab2-bonus-db-1
docker exec devops-lab2-bonus-backend-1 cat /sys/fs/cgroup/cpu.stat
docker exec devops-lab2-bonus-backend-1 cat /sys/fs/cgroup/memory.events
```

Временный генератор использовал 4 потока для CPU и 8 для остальных прогонов. Эквивалентный код для повторения (поменяйте `workers` на 8 для прогона памяти):

```python
import concurrent.futures
import time
import urllib.request

workers = 4  # 8 для опытов с памятью и итоговой проверки
started = time.monotonic()
deadline = started + 15

def worker():
    ok = errors = 0
    for _ in range(150):
        if time.monotonic() >= deadline:
            break
        try:
            with urllib.request.urlopen('http://127.0.0.1:8084/api/notes', timeout=3) as response:
                response.read()
                ok += response.status == 200
                errors += response.status != 200
        except Exception:
            errors += 1
    return ok, errors

with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
    results = list(pool.map(lambda _: worker(), range(workers)))
print('ok=', sum(x for x, _ in results), 'errors=', sum(y for _, y in results),
      'elapsed=', time.monotonic() - started)
```

При `BONUS_BACKEND_CPUS=0.05` Compose не дождался здорового backend: лимит мешал даже стартовой проверке. При `0.2 CPU` backend стал `healthy`, затем за 15,16 с обработал 161 запрос без ошибок. `docker stats` под нагрузкой показал **20,41%, 20,93%, 19,52%, 19,42% CPU** и до **29,89 MiB / 128 MiB**. `cpu.max` был `20000 100000`. Счётчик `nr_throttled` вырос **с 190 до 343** (+153), `throttled_usec` — с `14637822` до `67145402`: CPU throttling действительно произошёл. Точные замеры — [в журнале CPU](evidence/lab2-bonus-cpu.txt).

Для памяти сначала проверены более тесные пределы при `1 CPU`:

| Лимит backend | Фактический результат |
| --- | --- |
| 32 MiB | 553 GET за 15,03 с, ошибок 0, `oom_kill=0`; [вывод](evidence/lab2-bonus-32m.txt) |
| 24 MiB | 592 GET за 15,19 с, ошибок 0, `oom_kill=0`; [вывод](evidence/lab2-bonus-24m.txt) |
| 20 MiB | 567 GET за 15,14 с, ошибок 0, `oom_kill=0`; [вывод](evidence/lab2-bonus-oom-20m.txt) |
| 18 MiB | Backend не прошёл healthcheck при старте; нагрузка не запускалась |
| 16 MiB | Backend не прошёл healthcheck; Docker зарегистрировал события `oom → die → start`, `restart_count` достиг 8; [вывод событий](evidence/lab2-bonus-oom-16m.txt) |

OOM при 16 MiB произошёл **при запуске/healthcheck, до HTTP-нагрузки**. При 20 MiB обычные GET не вызвали OOM. Попытка послать один POST с телом 8 MiB через Nginx получила HTTP 413 и до Flask не дошла; восемь одновременных POST по 800 KiB получили HTTP 400 из-за пустого заголовка заметки, без OOM и без записи в БД. Результаты сохранены в [журнале крупного запроса](evidence/lab2-bonus-oom-request.txt) и [журнале восьми запросов](evidence/lab2-bonus-oom-posts.txt).

Чтобы проверить OOM именно **во время обработки запроса**, при том же пределе backend `20 MiB` создан один временный клиентский контейнер с лимитами `0.5 CPU / 64 MiB` в сети `devops-lab2-bonus_web`. Он отправил один POST на `http://backend:8000/api/notes` напрямую, минуя ограничение Nginx. Тело JSON — 8 388 636 байт, заголовок заметки пустой, так что запись в БД не создаётся. Перед запросом backend был `healthy`, но `restart_count=2` уже показывал нестабильность этого лимита после пересоздания. Запрос оборвался с `RemoteDisconnected`; Docker зарегистрировал `oom → die → start`, счётчик рестартов вырос **с 2 до 3**. Это подтверждает OOM под HTTP-нагрузкой. `oom_killed=false` после перезапуска относится уже к текущему процессу, поэтому доказательством предыдущего OOM служат события Docker. Клиент удалён автоматически (`docker run --rm`), backend после опыта пересоздан со стабильными `128 MiB`. [Полный вывод](evidence/lab2-bonus-oom-direct.txt) содержит размер запроса, состояние backend и события Docker.

Команда клиентского контейнера (образ Python уже был загружен при сборке backend):

```zsh
docker run --rm -i --pull never --network devops-lab2-bonus_web \
  --memory 64m --cpus 0.5 --name devops-lab2-bonus-load-1 \
  python:3.11.18-alpine3.23 python - <<'PY'
import json
import urllib.error
import urllib.request
payload = json.dumps({'title': '', 'content': 'x' * (8 * 1024 * 1024)}).encode()
request = urllib.request.Request('http://backend:8000/api/notes', data=payload,
                                 headers={'Content-Type': 'application/json'}, method='POST')
try:
    with urllib.request.urlopen(request, timeout=10) as response:
        print('direct HTTP POST status=', response.status)
except urllib.error.HTTPError as error:
    print('direct HTTP POST status=', error.code)
except Exception as error:
    print('direct HTTP POST error=', type(error).__name__, str(error))
print('request bytes=', len(payload))
PY
```

После опытов лимиты возвращены к значениям таблицы выше. При итоговой нагрузке из 8 потоков backend обработал **560 GET за 15,13 с без ошибок**; все три контейнера остались `healthy`. `docker stats` во время нагрузки показал:

| Сервис | CPU, три замера | Память, три замера |
| --- | --- | --- |
| frontend | 3,29% / 1,01% / 1,09% | 8,863 / 9,176 / 8,723 MiB из 64 MiB |
| backend | 99,80% / 100,20% / 100,85% | 25,74 / 25,61 / 26,02 MiB из 128 MiB |
| db | 20,11% / 17,52% / 19,36% | 25,56 / 25,86 / 26,25 MiB из 256 MiB |

Стек после нагрузки отдавал страницу и API с HTTP 200, сохранённая до аварии заметка осталась в JSON. API обычной лабораторной 2 (`:8082`) и деплоя лабораторной 3 (`:8083`) также вернули HTTP 200. Полный вывод, включая `docker stats`, лимиты и состояния контейнеров, сохранён [здесь](evidence/lab2-bonus-stable.txt). После последнего OOM-опыта отдельная [финальная проверка](evidence/lab2-bonus-final.txt) вновь подтвердила три статуса `healthy`, лимиты, заметку `id=1` и HTTP 200 на портах 8084, 8082 и 8083. Итоговые лимиты устойчивы для измеренной короткой нагрузки; более длительная или иная нагрузка здесь не проверялась. Том `devops-lab2-bonus_notes_data` не удалялся.
