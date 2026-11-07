#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v supabase >/dev/null || { echo 'Install Supabase CLI first.'; exit 1; }
docker info >/dev/null 2>&1 || { echo 'Start Docker Desktop first.'; exit 1; }
log_dir=$(mktemp -d "${TMPDIR:-/tmp}/city-together.XXXXXX")
supabase start > "$log_dir/backend.log" 2>&1 || { cat "$log_dir/backend.log"; exit 1; }
supabase migration up
python3 - <<'PY'
import json, subprocess
from pathlib import Path
status = json.loads(subprocess.check_output(['supabase', 'status', '-o', 'json']))
Path('config.local.json').write_text(json.dumps({
    'SUPABASE_URL': status['API_URL'],
    'SUPABASE_ANON_KEY': status['ANON_KEY'],
}, indent=2) + '\n')
PY
supabase functions serve delete-account > "$log_dir/functions.log" 2>&1 &
function_pid=$!
trap 'kill "$function_pid" 2>/dev/null || true' EXIT
printf '\nApp: http://localhost:3000\nTest mailbox: http://127.0.0.1:54324\nLogs: %s\n\n' "$log_dir"
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 3000 --dart-define-from-file=config.local.json
