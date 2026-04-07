#!/bin/bash
# daily-summary.sh — Generate summaries for inactive sessions using Claude Code CLI
# Runs every 2 hours via cron. Uses `claude -p` (subscription auth, no API key needed).

set -euo pipefail

CRED_FILE="$HOME/.claude/credentials/supabase.env"
if [[ -f "$CRED_FILE" ]]; then source "$CRED_FILE"; else echo "$(date) ERROR: $CRED_FILE not found" >&2; exit 1; fi

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Check if claude CLI is available
if ! command -v claude &>/dev/null; then
  log "Claude Code CLI not found. Skipping summarization."
  exit 0
fi

# Find sessions needing summaries: have content, no summary, inactive 2+ hours
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

echo "$sessions" | python3 -c "
import json, sys, subprocess, os, re

sessions = json.load(sys.stdin)
supabase_url = os.environ.get('SUPABASE_URL', 'http://localhost:3001')
supabase_key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')

for session in sessions:
    sid = session['id']
    content = session.get('content', '')
    if not content or len(content.strip()) < 50:
        continue

    # Truncate: 40k head + 40k tail
    if len(content) > 80000:
        content = content[:40000] + '\n\n[...truncated...]\n\n' + content[-40000:]

    print(f'Summarizing session {sid[:8]}...')

    prompt = '''Analyze this Claude Code session and return ONLY a JSON object with these fields:
- \"summary\": 2-3 sentence overview of what was done
- \"detail_summary\": 10-15 line detailed summary with key decisions, problems, and outcomes
- \"tags\": array of 3-8 lowercase keywords

Return ONLY the JSON object, no markdown wrapping.

Session content:
''' + content

    # Call claude CLI in print mode with haiku model
    try:
        result = subprocess.run(
            ['claude', '-p', '--model', 'haiku', prompt],
            capture_output=True, text=True, timeout=120
        )
        text = result.stdout.strip()
    except subprocess.TimeoutExpired:
        print(f'  Timeout for session {sid[:8]}')
        continue
    except Exception as e:
        print(f'  Error calling claude: {e}')
        continue

    if not text:
        print(f'  Empty response for session {sid[:8]}')
        continue

    # Parse JSON (with fallback for markdown-wrapped)
    if text.startswith('\`\`\`'):
        text = re.sub(r'^\`\`\`(?:json)?\s*', '', text)
        text = re.sub(r'\s*\`\`\`$', '', text)

    try:
        summary_data = json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r'\{.*\}', text, re.DOTALL)
        if match:
            try:
                summary_data = json.loads(match.group())
            except:
                print(f'  Failed to parse summary JSON for {sid[:8]}')
                continue
        else:
            print(f'  No JSON found in response for {sid[:8]}')
            continue

    # Update session in Supabase
    update_data = json.dumps({
        'summary': summary_data.get('summary', ''),
        'detail_summary': summary_data.get('detail_summary', ''),
        'tags': summary_data.get('tags', [])
    })

    result = subprocess.run([
        'curl', '-sf', '-X', 'PATCH',
        f'{supabase_url}/cc_sessions?id=eq.{sid}',
        '-H', f'apikey: {supabase_key}',
        '-H', f'Authorization: Bearer {supabase_key}',
        '-H', 'Content-Type: application/json',
        '-d', update_data
    ], capture_output=True, text=True)

    if result.returncode == 0:
        summary_preview = summary_data.get('summary', '')[:80]
        print(f'  Summarized: {summary_preview}...')
    else:
        print(f'  Failed to update session: {result.stderr}')
"

log "Summarization complete"
