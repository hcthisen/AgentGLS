#!/bin/bash
# memory-consolidate.sh — Consolidate session summaries into topic-based memories
# Runs daily at 3:00 AM via cron. Uses `claude -p --model haiku` (subscription auth).
# Inspired by Claude Code's auto-dream feature: groups sessions by topic, merges
# overlapping entries, converts relative dates, and prunes stale one-off tasks.

set -euo pipefail

CRED_FILE="$HOME/.claude/credentials/supabase.env"
if [[ -f "$CRED_FILE" ]]; then source "$CRED_FILE"; else echo "$(date) ERROR: $CRED_FILE not found" >&2; exit 1; fi

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Guard: check claude CLI is available
if ! command -v claude &>/dev/null; then
  log "Claude Code CLI not found. Skipping consolidation."
  exit 0
fi

# --- Step 1: Get last consolidation timestamp ---
LAST_RUN=$(curl -sf "${SUPABASE_URL}/cc_memory?type=eq.system&topic=eq.last_consolidation&select=content" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['content'] if d else '')" 2>/dev/null || echo "")

# Default: 30 days ago if never consolidated
if [[ -z "$LAST_RUN" ]]; then
  LAST_RUN=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-30d '+%Y-%m-%dT%H:%M:%S')
fi

# Cutoff: 24 hours ago (don't consolidate very recent sessions)
CUTOFF=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-24H '+%Y-%m-%dT%H:%M:%S')

# --- Step 2: Fetch unconsolidated sessions ---
SESSIONS=$(curl -sf "${SUPABASE_URL}/cc_sessions?select=id,session_date,summary,detail_summary,tags&summary=not.is.null&session_date=gte.${LAST_RUN}&session_date=lt.${CUTOFF}&order=session_date.desc&limit=50" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

COUNT=$(echo "$SESSIONS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "$COUNT" -lt 3 ]]; then
  log "Only $COUNT sessions in window, need at least 3. Skipping."
  exit 0
fi

log "Found $COUNT sessions to consolidate (window: $LAST_RUN to $CUTOFF)"

# --- Step 3: Build prompt, call Claude, upsert results ---
echo "$SESSIONS" | python3 -c "
import json, sys, subprocess, os, re
from datetime import datetime

sessions = json.load(sys.stdin)
supabase_url = os.environ.get('SUPABASE_URL', 'http://localhost:3001')
supabase_key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
today = datetime.utcnow().strftime('%Y-%m-%d')

# Build session listing for prompt
session_text = []
for s in sessions:
    date = (s.get('session_date','') or '')[:10]
    summary = s.get('summary', '')
    detail = s.get('detail_summary', '') or ''
    tags = ', '.join(s.get('tags', []) or [])
    session_text.append(f'Date: {date}\nSummary: {summary}\nDetail: {detail}\nTags: {tags}\n')

all_sessions = '\n---\n'.join(session_text)

prompt = f'''Today is {today}. Analyze these {len(sessions)} session summaries and consolidate them into topic-based knowledge entries.

Rules:
- Group related sessions into topics (e.g. \"Telegram Setup\", \"Security Hardening\", \"Bootstrap Script\")
- Each topic: concise summary of everything learned/done across all related sessions
- Convert any relative dates to absolute dates where possible
- Drop completed one-off tasks with no lasting knowledge value (e.g. \"fixed a typo\")
- Keep decisions, patterns, gotchas, and anything useful for future sessions
- If sessions contradict each other, keep only the latest/correct version

Return ONLY a JSON array of objects, each with:
- \"topic\": short topic name (2-5 words)
- \"content\": consolidated knowledge (3-10 sentences)
- \"tags\": array of 3-6 lowercase keywords

Return ONLY the JSON array, no markdown wrapping.

Session summaries:
{all_sessions}'''

# Call claude CLI
try:
    result = subprocess.run(
        ['claude', '-p', '--model', 'haiku', prompt],
        capture_output=True, text=True, timeout=180
    )
    text = result.stdout.strip()
except subprocess.TimeoutExpired:
    print('Timeout calling claude')
    sys.exit(1)
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)

if not text:
    print('Empty response from claude')
    sys.exit(1)

# Parse JSON (handle markdown wrapping)
if text.startswith('\`\`\`'):
    text = re.sub(r'^\`\`\`(?:json)?\s*', '', text)
    text = re.sub(r'\s*\`\`\`$', '', text)

try:
    topics = json.loads(text)
except json.JSONDecodeError:
    match = re.search(r'\[.*\]', text, re.DOTALL)
    if match:
        try:
            topics = json.loads(match.group())
        except:
            print('Failed to parse consolidation JSON')
            sys.exit(1)
    else:
        print('No JSON array found in response')
        sys.exit(1)

if not isinstance(topics, list):
    print('Response is not a JSON array')
    sys.exit(1)

# Upsert each topic into cc_memory
success = 0
for topic in topics:
    name = topic.get('topic', '').strip()
    content = topic.get('content', '').strip()
    tags = topic.get('tags', [])
    if not name or not content:
        continue

    data = json.dumps({
        'type': 'consolidated',
        'topic': name,
        'content': content,
        'tags': tags,
        'project': 'root',
        'updated_at': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    })

    r = subprocess.run([
        'curl', '-sf', '-X', 'POST',
        f'{supabase_url}/cc_memory',
        '-H', f'apikey: {supabase_key}',
        '-H', f'Authorization: Bearer {supabase_key}',
        '-H', 'Content-Type: application/json',
        '-H', 'Prefer: resolution=merge-duplicates,return=minimal',
        '-d', data
    ], capture_output=True, text=True)

    if r.returncode == 0:
        print(f'  Upserted: {name}')
        success += 1
    else:
        print(f'  Failed: {name} -- {r.stderr}')

print(f'Consolidated {success} topic(s)')
"

# --- Step 4: Update last consolidation timestamp ---
if [[ $? -eq 0 ]]; then
  NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  curl -sf -X POST "${SUPABASE_URL}/cc_memory" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: resolution=merge-duplicates,return=minimal" \
    -d "{\"type\":\"system\",\"topic\":\"last_consolidation\",\"content\":\"${CUTOFF}\",\"tags\":[],\"project\":\"root\"}" >/dev/null 2>&1
  log "Updated last_consolidation timestamp to $CUTOFF"
fi

log "Consolidation complete"
