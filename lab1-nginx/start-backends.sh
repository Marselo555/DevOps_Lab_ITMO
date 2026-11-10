#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
set -a
source .env
set +a
mkdir -p lab1-nginx/run

start_backend() {
    local instance_id=$1
    local port=$2
    local pid_file="lab1-nginx/run/${instance_id}.pid"

    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null && [[ $(ps -p "$old_pid" -o command=) == *"backend/app.py"* ]]; then
            echo "$instance_id already running on port $port (PID $old_pid)"
            return
        fi
    fi
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null; then
        echo "Port $port is already in use" >&2
        exit 1
    fi

    APP_HOST=0.0.0.0 APP_PORT="$port" INSTANCE_ID="$instance_id" PYTHONDONTWRITEBYTECODE=1 \
        python3 - "$instance_id" <<'PY' > "$pid_file"
import os
import subprocess
import sys

instance_id = sys.argv[1]
with open(f"lab1-nginx/run/{instance_id}.log", "ab") as log:
    process = subprocess.Popen(
        [".venv/bin/python", "backend/app.py"],
        env=os.environ.copy(),
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
print(process.pid)
PY

    for _ in {1..30}; do
        if curl -fsS -o /dev/null "http://127.0.0.1:${port}/api/notes" 2>/dev/null; then
            echo "$instance_id ready on port $port (PID $(cat "$pid_file"))"
            return
        fi
        sleep 0.2
    done
    echo "$instance_id did not start; see lab1-nginx/run/${instance_id}.log" >&2
    exit 1
}

start_backend backend-1 8001
start_backend backend-2 8002
