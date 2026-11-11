#!/usr/bin/env python3
"""Restore a known good lab 3 image without touching PostgreSQL."""

import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import urlopen


IMAGE_PATTERN = r"ghcr\.io/marselo555/devops-lab-itmo-notebook:[0-9a-f]{40}"
if len(sys.argv) != 2 or re.fullmatch(IMAGE_PATTERN, sys.argv[1]) is None:
    raise SystemExit(
        f"Usage: {sys.argv[0]} "
        "ghcr.io/marselo555/devops-lab-itmo-notebook:<40-character-commit-sha>"
    )

target_image = sys.argv[1]
started = time.monotonic()
root = Path(__file__).resolve().parent.parent
env_file = root / ".env"
compose_file = root / "lab2-docker/compose.yaml"
if not env_file.is_file():
    raise SystemExit(f"Missing local environment file: {env_file}")


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def compose(service):
    env = os.environ.copy()
    env.update(BACKEND_IMAGE=target_image, FRONTEND_PORT="8083")
    subprocess.run(
        [
            "docker", "compose", "-p", "devops-lab3", "--env-file", str(env_file),
            "-f", str(compose_file), "up", "-d", "--no-deps", "--no-build",
            "--pull", "never", "--force-recreate", service,
        ],
        env=env,
        check=True,
    )


expected = output("docker", "image", "inspect", target_image, "--format", "{{.Id}}")
current = output(
    "docker", "inspect", "devops-lab3-backend-1", "--format", "{{.Config.Image}}"
)
print(f"Rollback target: {target_image}", flush=True)
print(f"Current backend: {current}", flush=True)

compose("backend")
compose("frontend")

running = output("docker", "inspect", "devops-lab3-backend-1", "--format", "{{.Image}}")
if running != expected:
    raise SystemExit(f"Wrong backend image: {running}; expected {expected}")

for attempt in range(120):
    try:
        with urlopen("http://127.0.0.1:8083/api/notes", timeout=2) as response:
            body = response.read().decode()
            if response.status != 200:
                raise SystemExit(f"Unexpected HTTP status: {response.status}")
        elapsed = time.monotonic() - started
        print(f"Recovery time: {elapsed:.3f} seconds")
        print(f"Running backend image: {target_image}")
        print(f"GET /api/notes: HTTP 200\n{body}")
        break
    except (URLError, TimeoutError):
        time.sleep(1)
else:
    raise SystemExit("Rollback did not restore HTTP 200 within 120 attempts")
