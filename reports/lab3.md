# Лабораторная 3 — CI/CD

## Цель и результат

Обычное задание из `DevOps-лабы-2-курс (2).docx`: плохой код и образ с CRITICAL CVE должны остановить pipeline до деплоя; исправленный блокнот должен автоматически пройти `Lint/Test → Docker Build → Trivy Scan → Push → Deploy → Health Check`. Откат со звёздочкой не выполнялся.

Проверено 10 ноября 2026 года. Хост — macOS `arm64`, Docker Desktop Engine 29.9.3. Деплой выполнен на зарегистрированном self-hosted runner `macbook-devops` (macOS, ARM64). Существующие лаборатории 0–2 и их данные не удалялись; API лабораторной 2 после деплоя по-прежнему отвечает HTTP 200.

| Прогон | Результат | Доказательство |
| --- | --- | --- |
| [Плохой код, commit `9d618a7`](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42859654550) | Красный: Ruff `F821`; build и deploy пропущены | Реальный GitHub Actions run |
| [Исправленная демонстрационная ветка, commit `b8afe18`](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860991565) | Зелёный: lint/test, сборка и Trivy прошли; публикация и deploy для демонстрационной ветки не предусмотрены | Реальный GitHub Actions run |
| [Уязвимый образ, `scan_bad_image=true`](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860754501) | Красный: 15 CRITICAL; GHCR push и deploy пропущены | Реальный GitHub Actions run |
| [Исправленный `main`, commit `2d3cdaa`](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860700694) | Зелёный: все три jobs, GHCR push, Mac deploy, curl | Реальный GitHub Actions run |
| [Ручной плохой pipeline](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860748214) | Сборка прошла без lint/test/Trivy | Реальный GitHub Actions run |

Первый запуск `main` на commit `fbd8559` был [красным](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42859626377): lint прошёл, тест получил `password authentication failed`. Причина — завершающий перевод строки в CI secret: официальный PostgreSQL-образ использует первую строку при инициализации пароля. Это воспроизведено во временной Docker-сети: пароль с переводом строки не проходил TCP-аутентификацию, без него проходил. Commit `2d3cdaa` убирает завершающие CR/LF только в окружении тестового процесса, не печатая пароль. Повторный GitHub-прогон прошёл.

## Workflow и исправленные практики

### Плохой: `.github/workflows/lab3-bad.yml`

Запускается только вручную (`workflow_dispatch`), действительно собирает образ и не публикует его. Реальный успешный запуск: [42860748214](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860748214).

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

Actions закреплены полными SHA, образы — конкретными версиями. Job permissions ограничены нужными: `contents: read`, `packages: write` только у публикации, `packages: read` у деплоя. Для GHCR используется `GITHUB_TOKEN`; пароль временной CI-БД хранится в GitHub secret `LAB3_CI_DB_PASSWORD`, а пароль локальной БД — в игнорируемом `.env`. Значения секретов в Git не записаны.

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

Образ для `linux/arm64` строится и проверяется на GitHub-hosted Ubuntu. На Mac runner запускаются только `checkout`, shell, Docker CLI и Docker Desktop; service containers и container actions там не используются. `build_scan_push` зависит от `lint_test`, `deploy` зависит от `build_scan_push`. Публикация и deploy разрешены только из `main`, а ручной `scan_bad_image=true` проверяет плохой Dockerfile до публикации. Compose запускается с `--no-build` и скачанным GHCR-тегом по полному SHA. PostgreSQL использует отдельный именованный том `devops-lab3_notes_data`; команда `down -v` не применяется.

Синтаксис обоих YAML проверен `actionlint:1.7.12` (код 0). Локальный `.venv/bin/ruff check backend tests` вернул `All checks passed!`; CRUD-тест с реальной PostgreSQL лабораторной 0 завершился `Ran 1 test ... OK`. Эти локальные проверки не подменяют GitHub-прогоны выше.

## Плохой код и блокировка деплоя

В отдельной ветке `lab3-demo-lint-fail` commit `9d618a7` добавил `tests/test_ci_lint_failure.py` с неопределённым именем. [Красный run](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42859654550) содержит:

```text
F821 Undefined name `undefined_ci_symbol`
Found 1 error.
Process completed with exit code 1.
```

`lint_test` завершился failure, `build_scan_push` и `deploy` имеют статус skipped. Ошибка затем исправлена в отдельном commit `b8afe18`, стабильный `main` намеренно сломанного кода не содержит. [Повторный run ветки](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860991565) завершился success; в нём lint, CRUD-тест и Trivy прошли. Публикация и deploy у демонстрационной ветки остались skipped по условию workflow.

## Trivy: до и после

Trivy `v0.76.1`, сканеры `vuln`, уровень `HIGH,CRITICAL`. Числа ниже взяты из реальных GitHub Actions логов. Локальное предварительное сканирование другой сборки плохого образа дало 15 CRITICAL / 275 HIGH; в удалённом run база уязвимостей и сборка дали 15 / 373, поэтому для финального доказательства используются именно числа GitHub.

| Образ | CRITICAL | HIGH | Gate |
| --- | ---: | ---: | --- |
| Плохой `lab2-docker/Dockerfile.bad` на полном `python:3.11`, [run 42860754501](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860754501) | 15 | 373 | FAIL, `Block CRITICAL findings` exit 1 |
| Хороший `lab2-docker/Dockerfile.good` на `python:3.11.18-alpine3.23`, [run 42860700694](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860700694) | 0 | 2 | PASS, публикация разрешена |

В плохом образе Trivy нашёл CRITICAL, в частности `CVE-2026-44172` у MariaDB, `CVE-2026-42216` у OpenEXR, `CVE-2026-6653` у libxml2 и `CVE-2026-60002` у OpenSSH. Тяжёлый базовый образ содержит эти ненужные блокноту системные пакеты. Хороший multi-stage образ использует свежий Alpine и не содержит этих CRITICAL. Две оставшиеся HIGH в скане хорошего образа относятся к `jaraco.context 5.3.0` (`CVE-2026-23949`) и `wheel 0.45.1` (`CVE-2026-24049`), доставшимся от Python-образа; gate по условию задания блокирует CRITICAL, HIGH видны в журнале. Ignore-файлы Trivy и обход gate не использовались.

В [красном security-run](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860754501) журнал содержит:

```text
Total: 388 (HIGH: 373, CRITICAL: 15)
Total: 15 (CRITICAL: 15)
Process completed with exit code 1.
```

После этого шаги `Login to GHCR` и `Publish checked image` отмечены skipped, весь `deploy` — skipped. В зелёном run журнал Trivy содержит `Total: 2 (HIGH: 2, CRITICAL: 0)`; шаг блокировки CRITICAL прошёл. Результат зависит от базы Trivy на дату запуска, поэтому перед каждым push образ сканируется заново.

## GHCR, Mac deploy и финальный curl

[Зелёный run 42860700694](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860700694) прошёл `lint_test`, `build_scan_push` и `deploy` со статусом success. В логе публикации образа:

```text
2d3cdaa3362f2f6d6e10fbd431bc60610776ca09: digest: sha256:b6311e5e8ffde984010a38411ae819e61575fa4166a84cd8f29855b2b5710b68 size: 1989
```

Полный тег: `ghcr.io/marselo555/devops-lab-itmo-notebook:2d3cdaa3362f2f6d6e10fbd431bc60610776ca09`. Job на Mac показал `Docker Engine 29.9.3`, `Status: Downloaded newer image` для этого тега и успешный запуск трёх контейнеров. Проверка `docker image inspect` и `docker inspect devops-lab3-backend-1` дала одинаковый image ID `sha256:b6311e5e8ffde984010a38411ae819e61575fa4166a84cd8f29855b2b5710b68`; архитектура `arm64`, backend `healthy`. Том `devops-lab3_notes_data` существует. Это подтверждает деплой опубликованного образа, а не локальную пересборку.

Финальный шаг **Final HTTP health check** в том же GitHub run:

```text
GET /api/notes HTTP 200
[]
```

Повторная проверка на Mac: `curl --fail --silent --show-error http://127.0.0.1:8083/api/notes` вывела `[]`; `docker compose -p devops-lab3 --env-file .env -f lab2-docker/compose.yaml ps` показала frontend, backend и db запущенными. Страница доступна на `http://127.0.0.1:8083/`. Пустой список означает, что в новой базе лабораторной 3 пока нет заметок; это не ошибка.

## Команды для повторения и безопасной остановки

```zsh
open http://127.0.0.1:8083/
curl --fail --silent --show-error http://127.0.0.1:8083/api/notes
docker compose -p devops-lab3 --env-file .env -f lab2-docker/compose.yaml ps
docker volume inspect devops-lab3_notes_data --format '{{.Name}}'
```

Ручной плохой workflow запускается в Actions → **Lab 3 bad pipeline demo** → Run workflow. Демонстрация Trivy запускается в **Lab 3 CI/CD** → Run workflow с `scan_bad_image=true`; обычный push исправленного `main` запускает полный pipeline. Для безопасной остановки только стека лабораторной 3:

```zsh
docker compose -p devops-lab3 --env-file .env -f lab2-docker/compose.yaml stop
```

Не используйте `down -v`: он удалит заметки из тома. Перед сдачей прочитайте указанную в DOCX [историю про Васю](https://habr.com/ru/articles/689234/).

## Скриншоты

Настоящие снимки интерфейса GitHub Actions:

**Красный lint-run:** `lint_test` failed, build и deploy skipped.

![Красный GitHub Actions run с lint-ошибкой](screenshots/lab3-lint-red.png)

**Красный Trivy-run:** `build_scan_push` failed, deploy skipped; в сводке видно сборку `Dockerfile.bad`.

![Красный GitHub Actions run с блокировкой Trivy](screenshots/lab3-trivy-red.png)

**Зелёный run:** `lint_test`, `build_scan_push` и `deploy` прошли успешно. Вывод финального curl приведён выше и доступен в журнале run.

![Зелёный GitHub Actions run с успешным деплоем](screenshots/lab3-green.png)

Снимок страницы блокнота после деплоя `reports/screenshots/lab3-deployed.png` — необязательное дополнение.

## Проверка требований обычной лабораторной 3

| Требование | Статус | Реальное подтверждение / действие |
| --- | --- | --- |
| Плохой и хороший работающие pipelines | PASS | Оба YAML прошли actionlint; ручной плохой [run 42860748214](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860748214) собрал образ |
| Минимум три bad practices и исправления | PASS | Нет lint/test, кеша, Trivy в плохом; все три есть в хорошем |
| Lint/test блокирует плохой код до деплоя | PASS | [Красный run 42859654550](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42859654550): Ruff F821, downstream jobs skipped |
| Исправленный код проходит повторную проверку | PASS | [Run 42860991565](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860991565) success |
| Кеш, закреплённые версии, минимальные permissions и секреты | PASS | Проверены YAML, actionlint и GitHub логи; секреты не в репозитории |
| Build образа лабораторной 2 для Mac | PASS | GitHub build success; скачанный на Mac образ `arm64` |
| Trivy до/после и блокировка CRITICAL | PASS | 15/373 → 0/2; [красный security-run](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860754501), push/deploy skipped |
| Публикация в GHCR только после проверок | PASS | [Зелёный run](https://github.com/Marselo555/DevOps_Lab_ITMO/actions/runs/42860700694), опубликованный digest и успешный `docker pull` на Mac |
| Self-hosted Mac runner и Docker Desktop | PASS | `macbook-devops` online; deploy job success, Docker Engine 29.9.3 |
| Деплой именно GHCR-образа без удаления тома | PASS | Совпали image ID; `devops-lab3_notes_data` существует, в workflow нет `down -v` |
| Финальный curl в GitHub Actions | PASS | В журнале зелёного run `GET /api/notes HTTP 200` и `[]` |
| Скрин красного и зелёного прогонов в отчёте | PASS | Три настоящих PNG из GitHub Actions вложены выше |
