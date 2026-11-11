# Лабораторная 3 — CI/CD

## От ошибки до деплоя

Для блокнота из лабораторной 0 я настроил цепочку `Lint/Test → Docker Build → Trivy Scan → Push → Deploy → Health Check`. Её проверяли реальные ошибки: Ruff остановил код с неопределённым именем, Trivy в отдельном ручном прогоне заблокировал образ с CRITICAL CVE. Исправленный `main` прошёл все стадии и запустил сервис на Mac. Ручную проверку уязвимого образа я провёл позже успешного прогона `main`; это отдельный опыт с security gate. Откат деплоя разобран в [отчёте 3★](lab3-bonus.md).

Прогоны выполнены 10 ноября 2026 года. Целевой хост — Mac с архитектурой `arm64` и Docker Desktop Engine 29.9.3; на нём работает self-hosted runner `macbook-devops` (macOS, ARM64). После деплоя API лабораторной 2 по-прежнему отвечал HTTP 200.

Ниже сначала показаны оба workflow, затем — проверки Ruff и Trivy и результат деплоя. Успешный прогон `main` и ручной security-run имеют собственные ссылки и даты запуска в GitHub Actions; их выводы не объединены в один прогон. Сбой тестовой БД при первом запуске `main` тоже сохранён: он объясняет дополнительное исправление перед зелёным прогоном.

## Workflow и исправленные практики

### Плохой: `.github/workflows/lab3-bad.yml`

Для сравнения я сделал ручной workflow без проверок качества и безопасности. Он собирает образ, но не публикует его. [Прогон 42860748214](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860748214) завершился успешно — именно это и опасно: сборка сама по себе ещё не говорит, что код и образ годятся для деплоя.

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
| Нет обязательных lint и тестов | Отдельный job `lint_test`: Ruff и CRUD-тест с PostgreSQL |
| Нет кеша зависимостей и Docker-слоёв | pip cache в `setup-python`, Buildx cache в GitHub Actions |
| Нет сканирования уязвимостей | Trivy показывает HIGH/CRITICAL; отдельный gate завершает job с кодом 1 при CRITICAL |

### Хороший: `.github/workflows/lab3-ci-cd.yml`

В рабочем workflow проверка предшествует сборке, сканирование — публикации, публикация — деплою. Используемые GitHub Actions закреплены полными SHA. Теги образов задают выбранные версии: `python:3.11.18-alpine3.23` для хорошего Dockerfile, `postgres:16.13-alpine` для CI, `nginx:1.28-alpine` и `postgres:16` для Compose. Docker-тег может быть перезаписан, а `postgres:16` допускает обновления в рамках 16-й версии; побайтовой воспроизводимости без digest `@sha256` здесь нет. Права выделены по заданиям: `contents: read`, `packages: write` только для публикации и `packages: read` для деплоя. GHCR использует `GITHUB_TOKEN`; пароль тестовой БД хранится в GitHub secret `LAB3_CI_DB_PASSWORD`, локальной — в исключённом из Git `.env`.

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
        run: |
          python - <<'PY'
          import os
          import subprocess

          env = os.environ.copy()
          env["POSTGRES_PASSWORD"] = env["POSTGRES_PASSWORD"].rstrip("\r\n")
          subprocess.run(
              ["python", "-m", "unittest", "discover", "-s", "tests", "-v"],
              env=env,
              check=True,
          )
          PY

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

Образ для `linux/arm64` собирается и сканируется на GitHub-hosted Ubuntu. На Mac runner выполняются `checkout` и shell/Docker CLI через Docker Desktop. Зависимости заданий не позволяют начать `build_scan_push` до `lint_test`, а `deploy` — до `build_scan_push`. Публикация и деплой включаются только для `main`; ручной `scan_bad_image=true` отправляет на скан плохой Dockerfile. Compose на Mac запускает скачанный из GHCR образ с тегом по полному SHA и `--no-build`. PostgreSQL хранит данные в отдельном томе `devops-lab3_notes_data`.

`LAB3_ENV_FILE=/Users/marsel/Desktop/itmo/Cloud/.env` указывает на локальный файл self-hosted runner, вне временного каталога `checkout`. GitHub-hosted задания этот путь не используют. Сам путь привязывает деплой к рабочей папке данного Mac; при переносе runner его придётся изменить.

Оба YAML прошли `actionlint:1.7.12` с кодом 0. Локально `.venv/bin/ruff check backend tests` вернул `All checks passed!`, а CRUD-тест с PostgreSQL лабораторной 0 завершился `Ran 1 test ... OK`. Дальше я проверил, как эти стадии ведут себя в GitHub Actions на намеренно плохих вариантах.

## Плохой код и блокировка деплоя

В отдельной ветке `lab3-demo-lint-fail` коммит `9d618a7` добавил `tests/test_ci_lint_failure.py` с неопределённым именем. В [журнале упавшего прогона](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42859654550):

```text
F821 Undefined name `undefined_ci_symbol`
Found 1 error.
Process completed with exit code 1.
```

`lint_test` завершился со статусом failure; `build_scan_push` и `deploy` были пропущены. Ошибка не доехала до контейнера. Её исправили отдельным коммитом `b8afe18`; в `main` намеренно сломанного кода не было. [Повторный прогон ветки](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860991565) завершился со статусом success: lint, CRUD-тест и Trivy прошли. Публикация и деплой для демонстрационной ветки по условию workflow остались пропущенными.

![Красный GitHub Actions run с lint-ошибкой](screenshots/lab3-lint-red.png)

Первый запуск `main` для коммита `fbd8559` [тоже завершился ошибкой](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42859626377), но уже по другой причине: lint прошёл, а тест получил `password authentication failed`. В CI secret оказался завершающий перевод строки. При инициализации официальный образ PostgreSQL использовал первую строку пароля. Проверка во временной Docker-сети воспроизвела сбой: пароль с переводом строки не прошёл TCP-аутентификацию, без него — прошёл. Коммит `2d3cdaa` убирает завершающие CR/LF только из переменной окружения тестового процесса, не выводя пароль в лог. Следующий прогон прошёл.

## Trivy: до и после

Trivy `v0.76.1` запускался со сканером `vuln` и уровнями `HIGH,CRITICAL`. В таблице приведены результаты GitHub Actions. Предварительное локальное сканирование другой сборки плохого образа дало 15 CRITICAL и 275 HIGH; в GitHub-прогоне — 15 CRITICAL и 373 HIGH. При сравнении использованы показатели из GitHub-прогонов.

| Образ | CRITICAL | HIGH | Gate |
| --- | ---: | ---: | --- |
| Плохой `lab2-docker/Dockerfile.bad` на полном `python:3.11`, [run 42860754501](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860754501) | 15 | 373 | FAIL, `Block CRITICAL findings` exit 1 |
| Хороший `lab2-docker/Dockerfile.good` на `python:3.11.18-alpine3.23`, [run 42860700694](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860700694) | 0 | 2 | PASS, публикация разрешена |

В плохом образе Trivy обнаружил, в частности, `CVE-2026-44172` в MariaDB, `CVE-2026-42216` в OpenEXR, `CVE-2026-6653` в libxml2 и `CVE-2026-60002` в OpenSSH. Эти системные пакеты входят в тяжёлый базовый образ и не нужны блокноту. Хороший multi-stage образ собран на свежем Alpine; перечисленных CRITICAL в нём нет. Две оставшиеся HIGH относятся к `jaraco.context 5.3.0` (`CVE-2026-23949`) и `wheel 0.45.1` (`CVE-2026-24049`) из Python-образа. По условию задания gate блокирует CRITICAL, а HIGH остаются видны в журнале. Уязвимости не скрывались через ignore-файлы Trivy; gate не обходили.

Позже успешного прогона `main` я вручную запустил [security-run с уязвимым образом](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860754501). В его журнале:

```text
Total: 388 (HIGH: 373, CRITICAL: 15)
Total: 15 (CRITICAL: 15)
Process completed with exit code 1.
```

Шаги `Login to GHCR` и `Publish checked image`, а также задание `deploy` были пропущены. В отдельном успешном прогоне `main` журнал Trivy содержит `Total: 2 (HIGH: 2, CRITICAL: 0)`; проверка на CRITICAL прошла. Security gate сработал буквально: образ с 15 CRITICAL остановился до GHCR. База Trivy обновляется, поэтому workflow сканирует образ перед каждой публикацией.

![Красный GitHub Actions run с блокировкой Trivy](screenshots/lab3-trivy-red.png)

Подпись к снимку: у Trivy строгий фейс-контроль — образ с 15 CRITICAL до GHCR не дошёл.

## GHCR, Mac deploy и финальный curl

[Прогон 42860700694](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860700694) исправленного `main` завершился со статусом success во всех трёх заданиях: `lint_test`, `build_scan_push` и `deploy`. Он произошёл до отдельного ручного сканирования плохого образа, описанного выше. В журнале публикации:

```text
2d3cdaa3362f2f6d6e10fbd431bc60610776ca09: digest: sha256:b6311e5e8ffde984010a38411ae819e61575fa4166a84cd8f29855b2b5710b68 size: 1989
```

Полный тег: `ghcr.io/marselo555/devops-lab-itmo-notebook:2d3cdaa3362f2f6d6e10fbd431bc60610776ca09`. Задание на Mac вывело `Docker Engine 29.9.3` и `Status: Downloaded newer image` для этого тега, затем запустило три контейнера. Команды `docker image inspect` и `docker inspect devops-lab3-backend-1` вернули один image ID: `sha256:b6311e5e8ffde984010a38411ae819e61575fa4166a84cd8f29855b2b5710b68`. Архитектура образа — `arm64`, статус бэкенда — `healthy`. Том `devops-lab3_notes_data` существует. Совпадение ID подтверждает запуск опубликованного образа без локальной пересборки.

Финальный шаг **Final HTTP health check** в том же GitHub run:

```text
GET /api/notes HTTP 200
[]
```

На Mac команда `curl --fail --silent --show-error http://127.0.0.1:8083/api/notes` также вывела `[]`. `docker compose -p devops-lab3 --env-file .env -f lab2-docker/compose.yaml ps` показала три запущенных сервиса: frontend, backend и db. Страница открывалась по `http://127.0.0.1:8083/`. Пустой список здесь нормален: у лабораторной 3 отдельная база, в которой на тот момент ещё не было заметок.

![Зелёный GitHub Actions run с успешным деплоем](screenshots/lab3-green.png)

## Команды для повторения и безопасной остановки

```zsh
open http://127.0.0.1:8083/
curl --fail --silent --show-error http://127.0.0.1:8083/api/notes
docker compose -p devops-lab3 --env-file .env -f lab2-docker/compose.yaml ps
docker volume inspect devops-lab3_notes_data --format '{{.Name}}'
```

Плохой workflow запускается вручную через Actions → **Lab 3 bad pipeline demo** → Run workflow. Для ручного прогона Trivy используется **Lab 3 CI/CD** → Run workflow с `scan_bad_image=true`. Отправка коммита в `main` запускает полный pipeline. Только стек лабораторной 3 останавливается командой:

```zsh
docker compose -p devops-lab3 --env-file .env -f lab2-docker/compose.yaml stop
```

Команда `down -v` удалит заметки из тома, поэтому для остановки здесь указан `stop`.

## Вывод

Красный прогон Ruff остановил код до сборки; красный прогон Trivy остановил образ до публикации. После исправлений [прогон `main` 42860700694](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860700694) собрал и опубликовал GHCR-образ, запустил его на Mac и получил `GET /api/notes HTTP 200`. Совпадение image ID в GHCR и контейнере подтверждает, что деплой использовал опубликованный образ. В скане хорошего образа видны 2 HIGH, а Docker-теги сами по себе не дают побайтовой неизменности.
