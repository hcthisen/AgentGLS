#!/bin/bash
# system-overview.sh — Generate system inventory as JSON
# Called by server-health.sh, outputs to stdout

python3 -c "
import json, os, glob, subprocess

home = os.path.expanduser('~')
overview = {}

# Scripts
try:
    overview['scripts'] = sorted(os.listdir('/opt/agentos/scripts/'))
except:
    overview['scripts'] = []

# Credentials (names only, never contents)
cred_dir = os.path.join(home, '.claude', 'credentials')
try:
    overview['credentials'] = sorted(os.listdir(cred_dir))
except:
    overview['credentials'] = []

# Cron jobs
try:
    r = subprocess.run(['crontab', '-l'], capture_output=True, text=True, timeout=5)
    overview['cronjobs'] = [l.strip() for l in r.stdout.strip().split('\n') if l.strip() and not l.startswith('#')]
except:
    overview['cronjobs'] = []

# Log files with sizes
log_dirs = ['/opt/agentos/logs', os.path.join(home, '.claude', 'logs')]
logs = []
for d in log_dirs:
    try:
        for f in os.listdir(d):
            fp = os.path.join(d, f)
            if os.path.isfile(fp):
                size = os.path.getsize(fp)
                logs.append({'name': f, 'size_bytes': size})
    except:
        pass
overview['logs'] = logs

# Skills
skill_dir = os.path.join(home, '.claude', 'skills')
try:
    overview['skills'] = sorted(os.listdir(skill_dir))
except:
    overview['skills'] = []

# Plugins
plugin_dir = os.path.join(home, '.claude', 'plugins')
try:
    overview['plugins'] = sorted(os.listdir(plugin_dir))
except:
    overview['plugins'] = []

# Git repos
repos = []
for search_dir in ['/opt/agentos', os.path.join(home, 'repos'), home]:
    try:
        for entry in os.listdir(search_dir):
            path = os.path.join(search_dir, entry)
            if os.path.isdir(os.path.join(path, '.git')):
                repos.append(entry)
    except:
        pass
overview['git_repos'] = sorted(set(repos))

print(json.dumps(overview))
"
