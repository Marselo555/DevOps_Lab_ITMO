# Лабораторная 3 — CI/CD

## Цель и текущий статус

Цель обычного задания из DOCX: показать, что плохой код и CRITICAL CVE останавливают pipeline, а исправленная версия проходит `Lint/Test → Docker Build → Trivy Scan → Push → Deploy → Health Check` и доезжает до работающего блокнота на Mac. Откат со звёздочкой не выполняется.

**На 10 ноября 2026 года выполнены локальная подготовка и проверки. GitHub Actions ещё не запускались, образ в GHCR не опубликован, self-hosted runner не обнаружен, деплой и финальный curl в GitHub не проверены. Лабораторная 3 пока не завершена.** Не следует заменять эти доказательства локальными результатами ниже.

Исходный репозиторий — приватный `Marselo555/DevOps_Lab_ITMO`. Mac: `uname -m → arm64`; Docker Desktop Engine 29.9.3 доступен. `gh` и Trivy как программы на хосте не найдены, поэтому локальный Trivy запускался из образа `aquasec/trivy:0.76.1`. На Mac не найдены процесс или типовой каталог GitHub self-hosted runner; доступ GitHub Actions и GHCR из этой сессии не подтверждён.

## Два workflow

### Плохой workflow — `.github/workflows/lab3-bad.yml`

Он запускается только вручную (`workflow_dispatch`) и **не публикует образ и не деплоит**. После публикации файла в GitHub нужно действительно запустить его через Actions; пока это не сделано.

```yaml
name: Lab 3 bad pipeline demo

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      # BAD: no lint or tests before building.
      # BAD: no dependency or Docker layer cache.
      # BAD: no vulnerability scan.
      - name: Build without quality and security gates
        run: docker build -f lab2-docker/Dockerfile.good -t notebook-bad-pipeline .
```

| Плохая практика | Исправление в хорошем pipeline |
| --- | --- |
| Нет lint и тестов перед сборкой | Отдельная обязательная стадия `lint_test`: Ruff и CRUD-тест с PostgreSQL |
| Нет кеша зависимостей и Docker-слоёв | `setup-python` с pip-кешем; Buildx с GitHub Actions layer cache |
| Нет сканирования уязвимостей | Trivy сообщает HIGH/CRITICAL и отдельным шагом блокирует CRITICAL до публикации |

### Хороший workflow — `.github/workflows/lab3-ci-cd.yml`

Все внешние actions закреплены полными SHA релизных тегов, полученными через `git ls-remote`; Python-образ и образ PostgreSQL имеют конкретные версии. У jobs выданы только нужные permissions: чтение кода, запись пакета при публикации и чтение пакета при деплое. GHCR использует `GITHUB_TOKEN`, а тестовая БД — GitHub secret `LAB3_CI_DB_PASSWORD`. Секреты не записаны в YAML.

```yaml
name: Lab 3 CI/CD

on:
  push:
    branches:
      - main
      - 'lab3-demo-*'
  workflow_dispatch:
    inputs:
      scan_bad_image:
        description: 'Scan the vulnerable lab 2 image to demonstrate the security gate'
        type: boolean
        default: false

permissions: {}

jobs:
  lint_test:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    services:
      db:
        image: postgres:16.13-alpine
        env:
          POSTGRES_USER: notebook
          POSTGRES_DB: notebook_ci
          POSTGRES_PASSWORD: ${{ secrets.LAB3_CI_DB_PASSWORD }}
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U notebook -d notebook_ci"
          --health-interval 5s
          --health-timeout 3s
          --health-retries 10
    env:
      POSTGRES_USER: notebook
      POSTGRES_DB: notebook_ci
      POSTGRES_PASSWORD: ${{ secrets.LAB3_CI_DB_PASSWORD }}
      DB_HOST: 127.0.0.1
      DB_PORT: '5432'
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065 # v5.6.0
        with:
          python-version: '3.11'
          cache: pip
          cache-dependency-path: |
            backend/requirements.txt
            requirements-ci.txt
      - name: Install CI dependencies
        run: python -m pip install -r requirements-ci.txt
      - name: Lint
        run: ruff check backend tests
      - name: Test CRUD against PostgreSQL
        run: python -m unittest discover -s tests -v

  build_scan_push:
    needs: lint_test
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
    env:
      IMAGE_REF: ghcr.io/marselo555/devops-lab-itmo-notebook:${{ github.sha }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: docker/setup-qemu-action@29109295f81e9208d7d86ff1c6c12d2833863392 # v3.6.0
      - uses: docker/setup-buildx-action@e468171a9de216ec08956ac3ada2f0791b6bd435 # v3.11.1
      - name: Build the Mac-compatible image
        uses: docker/build-push-action@263435318d21b8e681c14492fe198d362a7d2c83 # v6.18.0
        with:
          context: .
          file: ${{ inputs.scan_bad_image && 'lab2-docker/Dockerfile.bad' || 'lab2-docker/Dockerfile.good' }}
          platforms: linux/arm64
          load: true
          tags: ${{ env.IMAGE_REF }}
          cache-from: type=gha,scope=notebook
          cache-to: type=gha,mode=max,scope=notebook
      - name: Report HIGH and CRITICAL findings
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          image-ref: ${{ env.IMAGE_REF }}
          version: v0.76.1
          scanners: vuln
          severity: HIGH,CRITICAL
          format: table
          exit-code: '0'
      - name: Block CRITICAL findings
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          image-ref: ${{ env.IMAGE_REF }}
          version: v0.76.1
          scanners: vuln
          severity: CRITICAL
          format: table
          exit-code: '1'
      - name: Login to GHCR
        if: github.ref == 'refs/heads/main'
        uses: docker/login-action@184bdaa0721073962dff0199f1fb9940f07167d1 # v3.5.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Publish checked image
        if: github.ref == 'refs/heads/main'
        run: docker push "$IMAGE_REF"

  deploy:
    if: github.ref == 'refs/heads/main'
    needs: build_scan_push
    runs-on: [self-hosted, macOS, ARM64]
    permissions:
      contents: read
      packages: read
    env:
      IMAGE_REF: ghcr.io/marselo555/devops-lab-itmo-notebook:${{ github.sha }}
      LAB3_ENV_FILE: /Users/marsel/Desktop/itmo/Cloud/.env
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - name: Check Mac and Docker Desktop
        shell: bash
        run: |
          test "$(uname -m)" = arm64
          test -f "$LAB3_ENV_FILE"
          docker info --format 'Docker Engine {{.ServerVersion}}'
      - name: Login to GHCR and pull published image
        shell: bash
        env:
          GHCR_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
          docker pull "$IMAGE_REF"
          test "$(docker image inspect "$IMAGE_REF" --format '{{.Architecture}}')" = arm64
      - name: Deploy three services without building
        shell: bash
        run: |
          BACKEND_IMAGE="$IMAGE_REF" FRONTEND_PORT=8083 \
            docker compose -p devops-lab3 --env-file "$LAB3_ENV_FILE" \
            -f lab2-docker/compose.yaml up --no-build --pull missing --wait --wait-timeout 120
          expected=$(docker image inspect "$IMAGE_REF" --format '{{.Id}}')
          running=$(docker inspect devops-lab3-backend-1 --format '{{.Image}}')
          test "$expected" = "$running"
      - name: Final HTTP health check
        shell: bash
        run: |
          response=$(curl --fail --silent --show-error http://127.0.0.1:8083/api/notes)
          printf 'GET /api/notes HTTP 200\n%s\n' "$response"
```

На ветках `lab3-demo-*` хороший pipeline запускает проверки, но публикация и deploy разрешены только для `main`. Ручной параметр `scan_bad_image=true` переключает **только демонстрационную сборку** на плохой Dockerfile; шаг Trivy с `exit-code: '1'` должен оборвать job до GHCR и deploy. При обычном push в `main` собирается `lab2-docker/Dockerfile.good` для `linux/arm64`.

На Mac выполняются только JavaScript action `checkout` и команды shell/Docker CLI. Docker container actions и GitHub Actions service containers на macOS runner не используются. Опубликованный GHCR-образ загружается `docker pull`; Compose получает его через `BACKEND_IMAGE` и запускается с `--no-build`. Отдельный проект `devops-lab3` использует порт 8083 и именованный том `devops-lab3_notes_data`; `down -v` не выполняется. Сравнение `docker image inspect` и `docker inspect` должно подтвердить, что backend запущен именно из скачанного образа.

## Локальные lint и тест

Установлен только CI-инструмент `ruff==0.14.8` в игнорируемое `.venv`; зависимости приложения остались из `backend/requirements.txt`. Выполнено:

```zsh
.venv/bin/python -m pip install -r requirements-ci.txt
.venv/bin/ruff check backend tests
set -a
source .env
set +a
DB_HOST=127.0.0.1 DB_PORT=55432 .venv/bin/python -m unittest discover -s tests -v
```

Фактический результат:

```text
All checks passed!
test_create_read_update_delete (test_notes.NotesApiTest) ... ok
Ran 1 test in 0.307s
OK
```

Тест отправляет реальные запросы Flask test client, а приложение читает и пишет в PostgreSQL лабораторной 0. Тест создаёт только свою заметку и удаляет её при завершении; существующие заметки не изменяет. Тестовая PostgreSQL в GitHub будет отдельным временным service container на Ubuntu.

Синтаксис обоих workflow проверен официальным `actionlint:1.7.12` через Docker: команда завершилась кодом 0 без ошибок. Это не является прогоном GitHub Actions.

## Trivy: до и после

Сканирование выполнено Trivy 0.76.1 с локально загруженной базой уязвимостей 10 ноября 2026 года. Считались находки `--scanners vuln --severity CRITICAL,HIGH` для OS и Python-пакетов; найденные в разных пакетах записи считаются отдельно, как в JSON Trivy.

| Образ | CRITICAL | HIGH | Результат локального gate |
| --- | ---: | ---: | --- |
| `devops-lab2-bad:lab2` — полный `python:3.11` | 15 | 275 | BLOCK: exit 1 |
| `devops-lab2-good:lab2` — прежний slim Bookworm | 9 | 77 | BLOCK: текущей CI-версией Trivy не проходит |
| `devops-lab3-good:local` — обновлённый `python:3.11.18-alpine3.23` | 0 | 2 | PASS: exit 0 |

В плохом образе среди CRITICAL найдены `CVE-2026-44172` и `CVE-2026-49261` в пакетах MariaDB, `CVE-2026-42216/42217` в OpenEXR, `CVE-2026-6653` в libxml2 и `CVE-2026-60002` в OpenSSH. У прежнего slim-образа были, в частности, CRITICAL в OpenSSL (`CVE-2026-31789`), SQLite (`CVE-2025-7458`) и zlib (`CVE-2023-45853`). Переход на проверенный актуальный Alpine-образ устранил CRITICAL в итоговом образе без изменения кода блокнота. Multi-stage сборка, отдельный пользователь, кешируемый порядок слоёв и HEALTHCHECK сохранились; после пересборки Flask вернул HTTP 200 и `whoami → notebook`.

Две оставшиеся HIGH относятся к пакетам инструментов Python в базовом образе: `jaraco.context 5.3.0` (`CVE-2026-23949`, исправление 6.1.0) и `wheel 0.45.1` (`CVE-2026-24049`, исправление 0.46.2). Они не являются зависимостями бизнес-кода блокнота; установленный gate блокирует CRITICAL, а HIGH показывает в логах. Уязвимости не скрывались через ignore-файлы или `ignore-unfixed`. При обновлении базы Trivy результат может измениться, поэтому реальный GitHub job обязан пересканировать образ перед публикацией.

Реальная проверка кода выхода:

```text
bad_gate_exit=1
good_gate_exit=0
Total: 15 (CRITICAL: 15)
```

Локальные JSON и полные логи скана хранятся только в `/private/tmp/devops-lab3-trivy-cache/` и `/private/tmp/devops-lab3-gate-*.log`; они не добавлены в Git. Повторить скан можно так:

```zsh
docker build -f lab2-docker/Dockerfile.bad -t devops-lab2-bad:lab2 .
docker build -f lab2-docker/Dockerfile.good -t devops-lab3-good:local .
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.76.1 \
  image --scanners vuln --severity CRITICAL,HIGH devops-lab2-bad:lab2
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.76.1 \
  image --scanners vuln --severity CRITICAL,HIGH devops-lab3-good:local
```

Для проверки gate добавьте `--severity CRITICAL --exit-code 1` к обоим вызовам: плохой должен завершиться кодом 1, исправленный — 0. Это локальное доказательство; красный GitHub-прогон security job ещё не получен.

## Демонстрация плохого кода и блокировки деплоя

Локальная ветка `lab3-demo-lint-fail` создана отдельно от `main` в рабочей копии `/private/tmp/devops-lab3-lint-demo`. Её коммит `9d618a7` добавляет только `tests/test_ci_lint_failure.py` с намеренной ошибкой `F821`; приложение не меняется. Локальная команда Ruff в этой ветке действительно вернула:

```text
F821 Undefined name `undefined_ci_symbol`
 --> tests/test_ci_lint_failure.py:2:12
Found 1 error.
lint_exit=1
```

Ветку нужно отправить **только после отдельного разрешения на push**. Workflow запускается на `lab3-demo-*`; lint job должен стать красным, а `build_scan_push` и `deploy` должны быть пропущены. После получения красного прогона ошибку нужно удалить отдельным коммитом и показать зелёную проверку. Фактические GitHub run ID, URL, статус и скриншот пока отсутствуют; локальный Ruff не подменяет этот результат.

| Доказательство | Фактический результат |
| --- | --- |
| Красный GitHub-прогон плохого кода | **BLOCKED** — локальная ветка `9d618a7` не отправлена, ссылки нет |
| Деплой не выполнялся в этом прогоне | **NOT TESTED** — нужен журнал красного прогона |
| Зелёная проверка после исправления | **NOT TESTED** — исправление отправляется после красного прогона |
| Красный GitHub-прогон с `scan_bad_image=true` | **NOT TESTED** — нужен ручной запуск workflow |

## Публикация и деплой

После успешных lint/test и Trivy workflow должен публиковать образ `ghcr.io/marselo555/devops-lab-itmo-notebook:<commit SHA>` с помощью `GITHUB_TOKEN` и `packages: write`. Mac runner должен скачать именно этот тег, запустить три сервиса без сборки и вывести результат `GET http://127.0.0.1:8083/api/notes` в логах шага **Final HTTP health check**. Сейчас GHCR-публикация, deploy и финальный curl имеют статус **NOT TESTED**: workflow ещё не опубликован и runner не зарегистрирован. Придумывать адрес пакета с опубликованным SHA, лог или зелёный run нельзя.

Локально проверено, что Compose с параметрами `-p devops-lab3`, `BACKEND_IMAGE=ghcr.io/marselo555/devops-lab-itmo-notebook:demo`, `FRONTEND_PORT=8083` разрешается в **ровно три сервиса**, порт 8083 и том `devops-lab3_notes_data`. Это проверка конфигурации, а не деплой из GHCR. Обычный стек лабораторной 2 после обновления образа снова запущен: frontend/API ответили HTTP 200, проверочная заметка осталась в PostgreSQL, backend работает как `notebook`.

## Что требуется в GitHub и на Mac

1. Рабочая подготовка сохранена локальным коммитом `91f9b2c` на `main`, плохой код — отдельным локальным коммитом `9d618a7` в `lab3-demo-lint-fail`. Отдельно разрешить push `main` и демонстрационной ветки; до разрешения ничего не отправлять. Приватный репозиторий уже существует; право Git push подтверждалось ранее, доступность Actions и GHCR ещё нужно проверить на GitHub.
2. В **Settings → Secrets and variables → Actions** создать `LAB3_CI_DB_PASSWORD` со случайным значением для временной БД теста. Пароль не присылать в чат. Проверьте, что Actions разрешены для репозитория; `GITHUB_TOKEN` создаётся GitHub автоматически.
3. В **Settings → Actions → Runners → New self-hosted runner** выбрать macOS/ARM64 и выполнить выдаваемые GitHub команды `config.sh`. Запустить `./run.sh` под пользователем, который имеет доступ к Docker Desktop и локальному `.env`. Убедиться в `Listening for Jobs` и статусе Idle. На Mac из терминала этого пользователя проверить `uname -m` (`arm64`) и `docker info`.
4. Если GHCR-пакет уже существует и не связан с репозиторием, предоставить этому репозиторию Actions-доступ к пакету в настройках GHCR. Для нового пакета workflow должен использовать `GITHUB_TOKEN` без персонального токена.
5. После публикации workflow запустить ручной плохой pipeline и security-демо (`scan_bad_image=true`), получить красные run URL. Отправить ветку с lint-ошибкой, затем исправить её и получить зелёный run. Отправить исправленный `main`, дождаться GHCR push, Mac deploy и финального curl. Добавить реальные ссылки и скриншоты в этот отчёт.

Инструкции GitHub по [регистрации self-hosted runner](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners), [GITHUB_TOKEN](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token) и [GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) подтверждают выбранный путь.

## Места для скриншотов и ссылок

- Красный GitHub run с lint-ошибкой, где deploy пропущен: **ожидается**. URL: —. Скриншот: `reports/screenshots/lab3-lint-red.png` после реального запуска.
- Красный GitHub run Trivy с CRITICAL, где push/deploy пропущены: **ожидается**. URL: —. Скриншот: `reports/screenshots/lab3-trivy-red.png`.
- Зелёный run с GHCR push, Mac deploy и финальным curl: **ожидается**. URL: —. Скриншот: `reports/screenshots/lab3-green.png`.
- Страница работающего деплоя на `http://127.0.0.1:8083/`: **ожидается**. Скриншот: `reports/screenshots/lab3-deployed.png`.

## Таблица обязательных требований

| Требование | Статус | Подтверждение / следующее действие |
| --- | --- | --- |
| Два workflow, плохой с тремя bad practices | PASS | YAML и `actionlint` проверены; плохой workflow ручной и не деплоит |
| Плохой workflow реально запущен в GitHub | BLOCKED | Нужны разрешение на push и ручной запуск в Actions |
| Lint/test перед сборкой | PASS | Локально Ruff и CRUD-тест с PostgreSQL прошли; GitHub-прогон ожидается |
| Кеш, SHA actions, версии образов, permissions, отсутствие открытых секретов | PASS | Статическая проверка YAML и файлов; `GITHUB_TOKEN`, secret CI-БД |
| Сборка Docker-образа для Mac | PASS | Локально собран и запущен `arm64`-образ; GitHub job ожидается |
| Trivy выявляет CRITICAL и блокирует плохой образ | PASS | Локально 15 CRITICAL, gate exit 1; GitHub security-демо ожидается |
| Исправленный образ без CRITICAL проходит gate | PASS | Локально 0 CRITICAL, 2 HIGH, gate exit 0; GitHub scan ожидается |
| Реальный красный GitHub-прогон Trivy до GHCR/deploy | BLOCKED | Нужны push workflow, ручной запуск `scan_bad_image=true` и ссылка на run |
| Реальный красный GitHub-прогон плохого кода и отсутствие deploy | BLOCKED | Нужны push демонстрационной ветки и ссылка на Actions run |
| Зелёный GitHub-прогон после исправления | BLOCKED | Нужны исправление ветки, push и ссылка на run |
| GHCR публикация после проверок | BLOCKED | Нужны Actions/GHCR, разрешение на push и ссылка на пакет/run |
| Self-hosted runner имеет доступ к Docker Desktop | BLOCKED | Зарегистрировать runner на Mac и проверить `docker info` в job |
| Деплой из опубликованного GHCR-образа с сохранением тома | BLOCKED | Запустить workflow на `main` после настройки runner; проверить image ID и volume |
| Финальный curl в GitHub Actions | BLOCKED | Нужен настоящий лог шага **Final HTTP health check** |
| Скриншоты и ссылки на красный/зелёный прогоны | BLOCKED | Добавить только после настоящих GitHub-прогонов |

Перед сдачей прочитайте указанную в задании [статью про Васю на Хабре](https://habr.com/ru/articles/689234/). Она является сатирическим контекстом курса и не меняет функциональность блокнота.
