# Лабораторная 2★ — устойчивый стек

Обычная лабораторная 2 описана в [отдельном отчёте](lab2.md). Ниже — только дополнительное задание.


## Отдельный проект и настройки

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

## Авария PostgreSQL и восстановление

Перед опытом через API тестового проекта создана заметка `id=1` с заголовком `Лаба 2★: сохранность` (`POST` вернул HTTP 201). Страница и API до аварии отвечали HTTP 200, все три контейнера были `healthy`.

Сначала выполнен `docker kill devops-lab2-bonus-db-1`. В этом Docker Desktop он **не** вызвал автоматический рестарт: контейнер остался `exited (137)`, `restart_count=0`, backend стал `unhealthy`. [Фактический вывод](evidence/lab2-bonus-docker-kill.txt) сохранён. Команда остановки контейнера через Docker API была учтена как ручная остановка; так же `docker stop` подавляет политику рестарта до ручного запуска контейнера или перезапуска демона. Это соответствует [описанию restart policies в Docker](https://docs.docker.com/engine/containers/start-containers-automatically/). БД тестового проекта запущена обратно вручную командой `docker start devops-lab2-bonus-db-1`.

Для проверки именно падения процесса выполнена команда **внутри тестового контейнера**:

```zsh
docker exec -u root devops-lab2-bonus-db-1 sh -c 'kill -QUIT 1'
```

PostgreSQL трактует SIGQUIT как [аварийное немедленное завершение](https://www.postgresql.org/docs/16/server-shutdown.html). Docker автоматически запустил тот же контейнер: PID процесса БД изменился с `62062` на `64323`, `restart_count` вырос с `0` до `1`. В журнале PostgreSQL есть `received immediate shutdown request`, затем `database system was not properly shut down; automatic recovery in progress` и `database system is ready to accept connections`. После восстановления `pg_isready` ответил `accepting connections`, все три healthcheck стали `healthy`; PID backend не менялся, его `restart_count=0`.

Повторные запросы дали `frontend HTTP 200` и `API HTTP 200`; JSON API по-прежнему содержал заметку `id=1`. Это одновременно проверяет сохранность тома и повторное подключение backend к БД. Полный вывод команд, состояний контейнеров, `curl` и журнала — в [файле восстановления](evidence/lab2-bonus-recovery.txt).

## CPU и память под нагрузкой

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
