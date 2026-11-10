#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
set -a
source .env
set +a

notes_url=https://notes.test
other_url=https://other.test
notes_curl() {
    curl --noproxy '*' -ksS --resolve notes.test:443:127.0.0.1 "$@"
}
other_curl() {
    curl --noproxy '*' -ksS --resolve other.test:443:127.0.0.1 "$@"
}
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
pass() {
    echo "PASS: $*"
}
header_value() {
    local header_name=$1
    awk -F': ' -v wanted="$header_name" 'tolower($1) == wanted {gsub("\r", "", $2); print $2}'
}
response_status() {
    awk 'NR == 1 {print $2}'
}
api_headers() {
    notes_curl -D - -o /dev/null "$notes_url/api/notes"
}

restore_needed=0
restore_backend() {
    if [[ "$restore_needed" == 1 ]]; then
        echo 'Restoring backend-1 after interrupted check...'
        "$project_root/lab1-nginx/start-backends.sh" || true
    fi
}
trap restore_backend EXIT

nginx_test=$(docker exec devops-lab1-nginx nginx -t 2>&1) || fail "nginx -t: $nginx_test"
[[ "$nginx_test" == *'test is successful'* ]] || fail 'nginx -t did not report success'
pass 'nginx -t'

http_headers=$(curl --noproxy '*' -sSI --resolve notes.test:80:127.0.0.1 http://notes.test/) || fail 'HTTP request'
[[ $(printf '%s\n' "$http_headers" | response_status) == 301 ]] || fail 'HTTP status is not 301'
location=$(printf '%s\n' "$http_headers" | header_value location)
[[ "$location" == 'https://notes.test/' ]] || fail "Unexpected Location: $location"
other_http_headers=$(curl --noproxy '*' -sSI --resolve other.test:80:127.0.0.1 http://other.test/) || fail 'Second host HTTP request'
[[ $(printf '%s\n' "$other_http_headers" | response_status) == 301 ]] || fail 'Second host HTTP status is not 301'
other_location=$(printf '%s\n' "$other_http_headers" | header_value location)
[[ "$other_location" == 'https://other.test/' ]] || fail "Unexpected second host Location: $other_location"
pass "HTTP 301 -> $location and $other_location"

https_code=$(notes_curl -o /dev/null -w '%{http_code}' "$notes_url/") || fail 'HTTPS request'
[[ "$https_code" == 200 ]] || fail "HTTPS returned $https_code"
pass 'HTTPS 200 with self-signed certificate (-k)'

static_headers=$(notes_curl -I "$notes_url/static/app.js") || fail 'Static JavaScript'
[[ $(printf '%s\n' "$static_headers" | response_status) == 200 && "$static_headers" == *'Server: nginx'* ]] || fail 'Static file not served by Nginx'
[[ "$static_headers" != *'X-Instance-ID:'* ]] || fail 'Static file came from Flask'
css_headers=$(notes_curl -I "$notes_url/static/style.css") || fail 'Static CSS'
[[ $(printf '%s\n' "$css_headers" | response_status) == 200 && "$css_headers" != *'X-Instance-ID:'* ]] || fail 'CSS file not served by Nginx'
notes_html=$(notes_curl "$notes_url/") || fail 'Frontend HTML'
[[ "$notes_html" == *'Блокнот'* ]] || fail 'Frontend HTML missing'
pass 'Nginx serves frontend HTML, CSS and JavaScript'

api_response=$(api_headers) || fail 'API proxy request'
[[ $(printf '%s\n' "$api_response" | response_status) == 200 ]] || fail 'API proxy did not return 200'
api_id=$(printf '%s\n' "$api_response" | header_value x-instance-id)
[[ "$api_id" == backend-1 || "$api_id" == backend-2 ]] || fail 'API has no backend identifier'
api_root_response=$(notes_curl -D - -o /dev/null "$notes_url/api") || fail 'Exact /api proxy request'
[[ $(printf '%s\n' "$api_root_response" | response_status) == 404 && "$api_root_response" == *'X-Instance-ID: backend-'* ]] || fail 'Exact /api path did not reach Flask'
pass "API proxy 200 from $api_id; exact /api reaches Flask"

sleep 1
seen_ids=''
for _ in 1 2 3 4 5 6; do
    response=$(api_headers) || fail 'Load balancing request'
    [[ $(printf '%s\n' "$response" | response_status) == 200 ]] || fail 'Load balancing request did not return 200'
    instance_id=$(printf '%s\n' "$response" | header_value x-instance-id)
    [[ "$instance_id" == backend-1 || "$instance_id" == backend-2 ]] || fail "Unknown instance: $instance_id"
    seen_ids="$seen_ids $instance_id"
    sleep 0.2
done
[[ "$seen_ids" == *backend-1* && "$seen_ids" == *backend-2* ]] || fail "Only one backend seen:$seen_ids"
pass "Both backends served requests:$seen_ids"

pid_file=lab1-nginx/run/backend-1.pid
[[ -f "$pid_file" ]] || fail 'backend-1 PID file missing'
backend_pid=$(cat "$pid_file")
backend_command=$(ps -p "$backend_pid" -o command= 2>/dev/null) || fail 'backend-1 process missing'
[[ "$backend_command" == *'backend/app.py'* ]] || fail 'PID does not belong to this Flask app'
kill -TERM "$backend_pid" || fail 'Could not stop backend-1'
restore_needed=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! curl -fsS -o /dev/null http://127.0.0.1:8001/api/notes 2>/dev/null; then
        break
    fi
    sleep 0.2
done
if curl -fsS -o /dev/null http://127.0.0.1:8001/api/notes 2>/dev/null; then
    fail 'backend-1 did not stop'
fi
sleep 1
for _ in 1 2 3 4; do
    response=$(api_headers) || fail 'API failed after backend-1 stopped'
    [[ $(printf '%s\n' "$response" | response_status) == 200 ]] || fail 'API not 200 after backend-1 stopped'
    instance_id=$(printf '%s\n' "$response" | header_value x-instance-id)
    [[ "$instance_id" == backend-2 ]] || fail "Unexpected instance during failover: $instance_id"
    sleep 0.2
done
pass 'backend-1 stopped; 4/4 API requests returned 200 from backend-2'

"$project_root/lab1-nginx/start-backends.sh" || fail 'Could not restore backend-1'
restore_needed=0
restored_headers=$(curl -sS -D - -o /dev/null http://127.0.0.1:8001/api/notes) || fail 'Restored backend-1 not responding'
[[ $(printf '%s\n' "$restored_headers" | response_status) == 200 && "$restored_headers" == *'X-Instance-ID: backend-1'* ]] || fail 'backend-1 restoration failed'
pass 'backend-1 restored on port 8001'

docs_code=$(notes_curl -o /dev/null -w '%{http_code}' "$notes_url/docs/") || fail 'Docs request'
docs_body=$(notes_curl "$notes_url/docs/") || fail 'Docs body'
[[ "$docs_code" == 200 && "$docs_body" == *'Документация лабораторной 1'* ]] || fail '/docs alias failed'
pass '/docs alias 200'

other_code=$(other_curl -o /dev/null -w '%{http_code}' "$other_url/") || fail 'Second host request'
other_body=$(other_curl "$other_url/") || fail 'Second host body'
[[ "$other_code" == 200 && "$other_body" == *'Второй проект'* && "$other_body" != *'Блокнот'* ]] || fail 'Second host leaked notebook content'
[[ "$notes_html" != *'Второй проект'* ]] || fail 'Notebook host leaked second project'
unknown_code=$(curl --noproxy '*' -ksS --resolve unknown.test:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://unknown.test/) || fail 'Unknown Host request'
[[ "$unknown_code" == 404 ]] || fail "Unknown Host returned $unknown_code instead of 404"
pass 'Virtual hosts isolated; unknown Host 404'

admin_code=$(notes_curl -o /dev/null -w '%{http_code}' "$notes_url/admin") || fail 'Admin request'
[[ "$admin_code" == 401 ]] || fail "/admin without password returned $admin_code"
admin_auth_code=$(notes_curl -u "admin:$LAB1_ADMIN_PASSWORD" -o /dev/null -w '%{http_code}' "$notes_url/admin") || fail 'Authorized admin request'
[[ "$admin_auth_code" == 200 ]] || fail "/admin with password returned $admin_auth_code"
pass '/admin: 401 without password, 200 with htpasswd credentials'

sleep 2
limited=0
for _ in {1..40}; do
    code=$(notes_curl -o /dev/null -w '%{http_code}' "$notes_url/api/notes") || fail 'Rate-limit request'
    [[ "$code" == 200 || "$code" == 429 ]] || fail "Unexpected rate-limit response: $code"
    if [[ "$code" == 429 ]]; then
        limited=$((limited + 1))
    fi
done
[[ "$limited" -gt 0 ]] || fail 'No HTTP 429 from limit_req'
pass "limit_req returned 429 on $limited of 40 rapid requests"

missing_code=$(notes_curl -o /dev/null -w '%{http_code}' "$notes_url/no-such-page") || fail 'Missing page request'
missing_body=$(notes_curl "$notes_url/no-such-page") || fail 'Missing page body'
[[ "$missing_code" == 404 && "$missing_body" == *'Своя страница 404'* ]] || fail 'Custom 404 page missing'
pass 'Missing page: HTTP 404 with custom content'

echo 'ALL CHECKS PASSED'
