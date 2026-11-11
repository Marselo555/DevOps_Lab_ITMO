# Лабораторная 2★ — устойчивый стек

После запуска блокнота через Compose я проверил, как этот стек ведёт себя при сбое БД и тесных лимитах ресурсов. Сначала настроил порядок запуска и проверки здоровья, затем вызвал аварийное завершение PostgreSQL, а после нагрузил backend с разными ограничениями CPU и памяти. Обычная лабораторная 2 описана [отдельно](lab2.md).

## Испытательный стек

Опыты проводились в проекте `devops-lab2-bonus` на `127.0.0.1:8084`. Он использует тот же код блокнота и те же три сервиса из `compose.yaml`, но отдельные сети и том `devops-lab2-bonus_notes_data`. Изменения для опыта собраны в [Compose override](../lab2-docker/compose.bonus.yaml). Обычный стек на 8082 и деплой лабораторной 3 на 8083 продолжили работать со своими настройками.

Запуск из корня проекта с локальным `.env`:

```zsh
FRONTEND_PORT=8084 BACKEND_IMAGE=devops-lab2-bonus:local \
  docker compose -p devops-lab2-bonus --env-file .env \
  -f lab2-docker/compose.yaml -f lab2-docker/compose.bonus.yaml \
  up -d --build --wait --wait-timeout 120
```

`up --wait` дождался цепочки `db Healthy → backend Healthy → frontend Healthy`. Так frontend не стартует раньше работающего API, а backend — раньше готовой БД. У всех трёх сервисов стоит `restart: unless-stopped`; `backend` зависит от `db: service_healthy`, `frontend` — от `backend: service_healthy`. БД проверяется через `pg_isready`, backend — через `GET /api/notes` (заодно проверяется доступ к БД), frontend — запросом `/` к Nginx. `DB_STARTUP_RETRIES=30` остаётся запасным ожиданием при старте Flask. Поскольку каждый запрос API создаёт новое соединение с PostgreSQL, после рестарта БД backend может подключиться снова без собственного перезапуска.

| Сервис | CPU | RAM | Проверка здоровья |
| --- | ---: | ---: | --- |
| frontend | 0,5 CPU | 64 MiB | HTTP-запрос к `/` |
| backend | 1 CPU | 128 MiB | HTTP-запрос к `/api/notes` |
| db | 0,5 CPU | 256 MiB | `pg_isready` |

В таблице указаны итоговые лимиты. Для опытов я менял только backend через `BONUS_BACKEND_CPUS` и `BONUS_BACKEND_MEM_LIMIT`. `docker inspect` подтвердил ограничения контейнеров: `NanoCpus=500000000/1000000000/500000000`, память `67108864/134217728/268435456` байт соответственно.

## Авария PostgreSQL и восстановление

Перед опытом через API тестового проекта создана заметка `id=1` с заголовком `Лаба 2★: сохранность` (`POST` вернул HTTP 201). Страница и API до аварии отвечали HTTP 200, все три контейнера были `healthy`.

Первой попыткой был `docker kill devops-lab2-bonus-db-1`. В этом Docker Desktop он **не** вызвал автоматический рестарт: контейнер остался `exited (137)`, `restart_count=0`, backend стал `unhealthy`. [Вывод опыта](evidence/lab2-bonus-docker-kill.txt) сохранён. Для политики рестарта это оказалось ручной остановкой через Docker API; `docker stop` также подавляет рестарт до ручного запуска контейнера или перезапуска демона — такое поведение описано в [документации Docker](https://docs.docker.com/engine/containers/start-containers-automatically/). Контейнер «убили» вручную, и Docker послушно оставил его остановленным. Я вернул БД командой `docker start devops-lab2-bonus-db-1` и изменил способ проверки: завершил сам процесс PostgreSQL внутри контейнера.

Для проверки именно падения процесса выполнена команда **внутри тестового контейнера**:

```zsh
docker exec -u root devops-lab2-bonus-db-1 sh -c 'kill -QUIT 1'
```

PostgreSQL трактует SIGQUIT как [аварийное немедленное завершение](https://www.postgresql.org/docs/16/server-shutdown.html). На этот раз Docker автоматически запустил тот же контейнер: PID процесса БД изменился с `62062` на `64323`, `restart_count` вырос с `0` до `1`. В журнале видны `received immediate shutdown request`, затем `database system was not properly shut down; automatic recovery in progress` и `database system is ready to accept connections`. После восстановления `pg_isready` ответил `accepting connections`, все три healthcheck стали `healthy`; PID backend не менялся, его `restart_count=0`.

Повторные запросы дали `frontend HTTP 200` и `API HTTP 200`; JSON API по-прежнему содержал заметку `id=1`. Контейнер БД пережил аварию с тем же томом, а backend переподключился к ней без рестарта. Полные состояния, `curl` и журнал — в [файле восстановления](evidence/lab2-bonus-recovery.txt).

## CPU и память под нагрузкой

Дальше я проверил два разных эффекта: при тесном лимите CPU процесс должен попасть под throttling, а при слишком малой памяти — завершиться из-за OOM. После подбора лимитов я повторил нагрузку и посмотрел, остаётся ли стек здоровым. Запросы генерировал короткий Python-скрипт из стандартной библиотеки (`urllib.request`, `ThreadPoolExecutor`) во временном файле `/private/tmp/lab2_bonus_load.py`. Каждый поток отправлял не более 150 `GET /api/notes`; общий срок опыта — 15 секунд, таймаут одного ответа — 3 секунды. Для CPU использовал 4 потока (не больше 600 запросов), для памяти и финальной проверки — 8 (не больше 1200). Во время опыта снимал `docker stats --no-stream` и счётчики `/sys/fs/cgroup/` внутри backend.

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

Временный генератор использовал 4 потока для CPU и 8 для остальных прогонов. Ниже приведён эквивалентный код с `workers=4` для CPU; в опытах с памятью я задавал `workers=8`:

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

При `BONUS_BACKEND_CPUS=0.05` Compose даже не дождался здорового backend: лимит мешал стартовой проверке. На `0.2 CPU` backend стал `healthy` и за 15,16 с обработал 161 запрос без ошибок. `docker stats` показал **20,41%, 20,93%, 19,52%, 19,42% CPU** и до **29,89 MiB / 128 MiB**. При `cpu.max = 20000 100000` счётчик `nr_throttled` вырос **с 190 до 343** (+153), `throttled_usec` — с `14637822` до `67145402`. Это уже не догадка по процентам в `docker stats`: cgroup зарегистрировала throttling. [Журнал CPU](evidence/lab2-bonus-cpu.txt) содержит точные замеры.

Затем при `1 CPU` я постепенно снижал лимит памяти. Обычные GET сначала продолжали проходить; результаты каждого порога:

| Лимит backend | Фактический результат |
| --- | --- |
| 32 MiB | 553 GET за 15,03 с, ошибок 0, `oom_kill=0`; [вывод](evidence/lab2-bonus-32m.txt) |
| 24 MiB | 592 GET за 15,19 с, ошибок 0, `oom_kill=0`; [вывод](evidence/lab2-bonus-24m.txt) |
| 20 MiB | 567 GET за 15,14 с, ошибок 0, `oom_kill=0`; [вывод](evidence/lab2-bonus-oom-20m.txt) |
| 18 MiB | Backend не прошёл healthcheck при старте; нагрузка не запускалась |
| 16 MiB | Backend не прошёл healthcheck; Docker зарегистрировал события `oom → die → start`, `restart_count` достиг 8; [вывод событий](evidence/lab2-bonus-oom-16m.txt) |

OOM при 16 MiB произошёл **при запуске/healthcheck, до HTTP-нагрузки**. При 20 MiB обычные GET OOM не вызвали. Один POST с телом 8 MiB через Nginx получил HTTP 413 и до Flask не дошёл; восемь одновременных POST по 800 KiB получили HTTP 400 из-за пустого заголовка заметки — тоже без OOM и без записи в БД. Эти попытки есть в [журнале крупного запроса](evidence/lab2-bonus-oom-request.txt) и [журнале восьми запросов](evidence/lab2-bonus-oom-posts.txt). Значит, для опыта с OOM во время обработки запроса нужно было пройти мимо ограничения Nginx.

При лимите backend `20 MiB` я запустил временный клиентский контейнер с ограничениями `0.5 CPU / 64 MiB` в сети `devops-lab2-bonus_web`. Он отправил POST напрямую на `http://backend:8000/api/notes`, минуя Nginx. Тело JSON — 8 388 636 байт; пустой заголовок заметки исключал запись в БД. До запроса backend был `healthy`, хотя `restart_count=2` уже показывал нестабильность этого лимита после пересоздания. Запрос оборвался с `RemoteDisconnected`; Docker зарегистрировал `oom → die → start`, а число рестартов выросло **с 2 до 3**. Это OOM именно при HTTP-нагрузке. Значение `oom_killed=false` после рестарта относится уже к новому процессу; событие предыдущего OOM видно в Docker events. Временный клиент удалился через `docker run --rm`, а backend после опыта вернулся к `128 MiB`. [Полный вывод](evidence/lab2-bonus-oom-direct.txt) сохраняет размер запроса, состояния и события.

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

После опытов я вернул лимиты из первой таблицы. На итоговой нагрузке из 8 потоков backend обработал **560 GET за 15,13 с без ошибок**, все три контейнера остались `healthy`. `docker stats` в это время показал:

| Сервис | CPU, три замера | Память, три замера |
| --- | --- | --- |
| frontend | 3,29% / 1,01% / 1,09% | 8,863 / 9,176 / 8,723 MiB из 64 MiB |
| backend | 99,80% / 100,20% / 100,85% | 25,74 / 25,61 / 26,02 MiB из 128 MiB |
| db | 20,11% / 17,52% / 19,36% | 25,56 / 25,86 / 26,25 MiB из 256 MiB |

После нагрузки страница и API отвечали HTTP 200, а заметка, созданная до аварии, оставалась в JSON. API обычной лабораторной 2 (`:8082`) и деплоя лабораторной 3 (`:8083`) тоже вернули HTTP 200. [Протокол стабильной нагрузки](evidence/lab2-bonus-stable.txt) содержит `docker stats`, лимиты и состояния контейнеров. После последнего OOM-опыта [финальная проверка](evidence/lab2-bonus-final.txt) снова показала три статуса `healthy`, заметку `id=1` и HTTP 200 на портах 8084, 8082 и 8083. Подобранные лимиты выдержали эту короткую нагрузку; более длительную и другую по характеру нагрузку я не проверял. Том `devops-lab2-bonus_notes_data` остался на месте.
