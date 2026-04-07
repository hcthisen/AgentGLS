#!/bin/bash
# daily-summary.sh - Generate summaries for inactive sessions via provider-run.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_RUN_SCRIPT="$SCRIPT_DIR/provider-run.sh"
CRED_FILE="$HOME/.claude/credentials/supabase.env"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

if [[ -f "$CRED_FILE" ]]; then
  source "$CRED_FILE"
else
  echo "$(date) ERROR: $CRED_FILE not found" >&2
  exit 1
fi

load_agentgls_env

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

if ! resolve_active_provider >/dev/null 2>&1; then
  log "No active provider configured. Skipping summarization."
  exit 0
fi

if [[ ! -x "$PROVIDER_RUN_SCRIPT" ]]; then
  log "provider-run.sh is missing. Skipping summarization."
  exit 0
fi

TWO_HOURS_AGO=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-2H '+%Y-%m-%dT%H:%M:%S')

sessions=$(curl -sf "${SUPABASE_URL}/cc_sessions?select=id,content,session_date&summary=is.null&content=neq.&session_date=lt.${TWO_HOURS_AGO}&order=session_date.desc&limit=10" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

count=$(echo "$sessions" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "$count" == "0" ]]; then
  log "No sessions need summarization"
  exit 0
fi

log "Found $count session(s) to summarize"

export SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY PROVIDER_RUN_SCRIPT
echo "$sessions" | python3 -c "
import json
import os
import re
import subprocess
import sys
import tempfile

sessions = json.load(sys.stdin)
supabase_url = os.environ.get('SUPABASE_URL', 'http://localhost:3001')
supabase_key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
provider_run_script = os.environ.get('PROVIDER_RUN_SCRIPT', '')

def call_provider(prompt: str) -> str:
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', delete=False) as handle:
        handle.write(prompt)
        prompt_path = handle.name
    try:
        result = subprocess.run(
            ['bash', provider_run_script, 'summary', prompt_path],
            capture_output=True,
            text=True,
            timeout=180,
        )
    finally:
        try:
            os.unlink(prompt_path)
        except FileNotFoundError:
            pass

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f'provider-run exited {result.returncode}'
        raise RuntimeError(detail)
    return result.stdout.strip()

for session in sessions:
    sid = session['id']
    content = session.get('content', '')
    if not content or len(content.strip()) < 50:
        continue

    if len(content) > 80000:
        content = content[:40000] + '\\n\\n[...truncated...]\\n\\n' + content[-40000:]

    print(f'Summarizing session {sid[:8]}...')

    prompt = (
        'Analyze this coding session transcript and return ONLY a JSON object with these fields:\\n'
        '- \"summary\": 2-3 sentence overview of what was done\\n'
        '- \"detail_summary\": 10-15 line detailed summary with key decisions, problems, and outcomes\\n'
        '- \"tags\": array of 3-8 lowercase keywords\\n\\n'
        'Return ONLY the JSON object, with no markdown fences or commentary.\\n\\n'
        'Session content:\\n' + content
    )

    try:
        text = call_provider(prompt)
    except subprocess.TimeoutExpired:
        print(f'  Timeout for session {sid[:8]}')
        continue
    except Exception as exc:
        print(f'  Provider error for {sid[:8]}: {exc}')
        continue

    if not text:
        print(f'  Empty response for session {sid[:8]}')
        continue

    if text.startswith('```'):
        text = re.sub(r'^```(?:json)?\\s*', '', text)
        text = re.sub(r'\\s*```$', '', text)

    try:
        summary_data = json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r'\\{.*\\}', text, re.DOTALL)
        if not match:
            print(f'  No JSON found in response for {sid[:8]}')
            continue
        try:
            summary_data = json.loads(match.group())
        except json.JSONDecodeError:
            print(f'  Failed to parse summary JSON for {sid[:8]}')
            continue

    update_data = json.dumps({
        'summary': summary_data.get('summary', ''),
        'detail_summary': summary_data.get('detail_summary', ''),
        'tags': summary_data.get('tags', []),
    })

    result = subprocess.run(
        [
            'curl',
            '-sf',
            '-X',
            'PATCH',
            f'{supabase_url}/cc_sessions?id=eq.{sid}',
            '-H',
            f'apikey: {supabase_key}',
            '-H',
            f'Authorization: Bearer {supabase_key}',
            '-H',
            'Content-Type: application/json',
            '-d',
            update_data,
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode == 0:
        preview = summary_data.get('summary', '')[:80]
        print(f'  Summarized: {preview}...')
    else:
        print(f'  Failed to update session: {result.stderr}')
" 

log "Summarization complete"
