#!/usr/bin/env bash
set -euo pipefail

image=${1:?Usage: smoke-test-image.sh IMAGE PLATFORM}
platform=${2:?Usage: smoke-test-image.sh IMAGE PLATFORM}
case "$platform" in
  linux/amd64) machine=x86_64 ;;
  linux/arm64) machine=aarch64 ;;
  *) echo "Unsupported platform: $platform" >&2; exit 1 ;;
esac

test_dir=$(mktemp -d)
container="leapconnect-smoke-${RANDOM}-${RANDOM}"
cleanup() {
  result=$?
  if [[ $result -ne 0 ]]; then
    docker logs "$container" >&2 || true
  fi
  docker rm -fv "$container" >/dev/null 2>&1 || true
  rm -rf "$test_dir"
  exit "$result"
}
trap cleanup EXIT

actual_arch=$(docker image inspect "$image" --format '{{.Architecture}}')
[[ "$actual_arch" == "${platform#linux/}" ]]
docker run -d --name "$container" --platform "$platform" \
  -p 127.0.0.1::8099 -v /app/data \
  -e DATA_DIR=/app/data -e DB_PATH=/app/data/leapconnect.db "$image"
port=$(docker inspect "$container" --format '{{(index (index .NetworkSettings.Ports "8099/tcp") 0).HostPort}}')
url="http://127.0.0.1:$port"

ready=false
for ((attempt=0; attempt<60; attempt++)); do
  [[ $(docker inspect "$container" --format '{{.State.Running}}') == true ]]
  if curl --fail --silent --show-error --max-time 3 \
    "$url/api/setup/status" -o "$test_dir/status.json" 2>/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
[[ "$ready" == true ]]
python3 - "$test_dir/status.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as response:
    status = json.load(response)
for field in ("has_user", "has_account", "has_certificates", "authenticated"):
    assert status[field] is False, (field, status)
PY

curl --fail --silent --show-error --max-time 10 "$url/" -o "$test_dir/index.html"
asset=$(python3 - "$test_dir/index.html" <<'PY'
import re
import sys

with open(sys.argv[1]) as response:
    html = response.read()
assert '<div id="app">' in html, "Frontend root missing"
match = re.search(r'src="(/assets/[^\"]+\.js)"', html)
assert match, "Built frontend JavaScript missing"
print(match.group(1))
PY
)
curl --fail --silent --show-error --max-time 10 "$url$asset" -o "$test_dir/asset.js"
[[ -s "$test_dir/asset.js" ]]
docker exec "$container" /app/.venv/bin/python -c \
  'import platform, sys; assert platform.machine() == sys.argv[1], platform.machine()' "$machine"
echo "Smoke test passed: $image ($platform)"
