#!/bin/bash
# memory-consolidate.sh - Consolidate session summaries into topic memories via provider-run.sh.

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
  log "No active provider configured. Skipping consolidation."
  exit 0
fi

if [[ ! -x "$PROVIDER_RUN_SCRIPT" ]]; then
  log "provider-run.sh is missing. Skipping consolidation."
  exit 0
fi

LAST_RUN=$(curl -sf "${SUPABASE_URL}/cc_memory?type=eq.system&topic=eq.last_consolidation&select=content" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" | \
  python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['content'] if data else '')" 2>/dev/null || echo "")

if [[ -z "$LAST_RUN" ]]; then
  LAST_RUN=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-30d '+%Y-%m-%dT%H:%M:%S')
fi

CUTOFF=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-24H '+%Y-%m-%dT%H:%M:%S')

SESSIONS=$(curl -sf "${SUPABASE_URL}/cc_sessions?select=id,session_date,summary,detail_summary,tags&summary=not.is.null&session_date=gte.${LAST_RUN}&session_date=lt.${CUTOFF}&order=session_date.desc&limit=50" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

COUNT=$(echo "$SESSIONS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "$COUNT" -lt 3 ]]; then
  log "Only $COUNT sessions in window, need at least 3. Skipping."
  exit 0
fi

log "Found $COUNT sessions to consolidate (window: $LAST_RUN to $CUTOFF)"

export SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY PROVIDER_RUN_SCRIPT
echo "$SESSIONS" | python3 -c "
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime

sessions = json.load(sys.stdin)
supabase_url = os.environ.get('SUPABASE_URL', 'http://localhost:3001')
supabase_key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
provider_run_script = os.environ.get('PROVIDER_RUN_SCRIPT', '')
today = datetime.utcnow().strftime('%Y-%m-%d')

def call_provider(prompt: str) -> str:
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', delete=False) as handle:
        handle.write(prompt)
        prompt_path = handle.name
    try:
        result = subprocess.run(
            ['bash', provider_run_script, 'summary', prompt_path],
            capture_output=True,
            text=True,
            timeout=240,
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

session_text = []
for session in sessions:
    date = (session.get('session_date', '') or '')[:10]
    summary = session.get('summary', '')
    detail = session.get('detail_summary', '') or ''
    tags = ', '.join(session.get('tags', []) or [])
    session_text.append(f'Date: {date}\\nSummary: {summary}\\nDetail: {detail}\\nTags: {tags}\\n')

all_sessions = '\\n---\\n'.join(session_text)
prompt = f'''Today is {today}. Analyze these {len(sessions)} session summaries and consolidate them into topic-based knowledge entries.

Rules:
- Group related sessions into topics such as infrastructure, onboarding, Telegram, or GoalLoop execution.
- Each topic should capture durable decisions, patterns, gotchas, or outcomes worth remembering.
- Convert relative dates to absolute dates where possible.
- Drop completed one-off tasks that have no lasting knowledge value.
- If sessions contradict each other, keep only the latest correct version.

Return ONLY a JSON array of objects, each with:
- \"topic\": short topic name (2-5 words)
- \"content\": consolidated knowledge (3-10 sentences)
- \"tags\": array of 3-6 lowercase keywords

Return ONLY the JSON array, with no markdown fences or commentary.

Session summaries:
{all_sessions}'''

try:
    text = call_provider(prompt)
except Exception as exc:
    print(f'Provider error: {exc}')
    sys.exit(1)

if not text:
    print('Empty response from provider')
    sys.exit(1)

if text.startswith('```'):
    text = re.sub(r'^```(?:json)?\\s*', '', text)
    text = re.sub(r'\\s*```$', '', text)

try:
    topics = json.loads(text)
except json.JSONDecodeError:
    match = re.search(r'\\[.*\\]', text, re.DOTALL)
    if not match:
        print('No JSON array found in response')
        sys.exit(1)
    try:
        topics = json.loads(match.group())
    except json.JSONDecodeError:
        print('Failed to parse consolidation JSON')
        sys.exit(1)

if not isinstance(topics, list):
    print('Response is not a JSON array')
    sys.exit(1)

success = 0
for topic in topics:
    name = str(topic.get('topic', '')).strip()
    content = str(topic.get('content', '')).strip()
    tags = topic.get('tags', [])
    if not name or not content:
        continue

    data = json.dumps({
        'type': 'consolidated',
        'topic': name,
        'content': content,
        'tags': tags,
        'project': 'root',
        'updated_at': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    })

    response = subprocess.run(
        [
            'curl',
            '-sf',
            '-X',
            'POST',
            f'{supabase_url}/cc_memory',
            '-H',
            f'apikey: {supabase_key}',
            '-H',
            f'Authorization: Bearer {supabase_key}',
            '-H',
            'Content-Type: application/json',
            '-H',
            'Prefer: resolution=merge-duplicates,return=minimal',
            '-d',
            data,
        ],
        capture_output=True,
        text=True,
    )

    if response.returncode == 0:
        print(f'  Upserted: {name}')
        success += 1
    else:
        print(f'  Failed: {name} -- {response.stderr}')

print(f'Consolidated {success} topic(s)')
"

NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
curl -sf -X POST "${SUPABASE_URL}/cc_memory" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge-duplicates,return=minimal" \
  -d "{\"type\":\"system\",\"topic\":\"last_consolidation\",\"content\":\"${CUTOFF}\",\"tags\":[],\"project\":\"root\",\"updated_at\":\"${NOW}\"}" >/dev/null 2>&1

log "Updated last_consolidation timestamp to $CUTOFF"
log "Consolidation complete"
