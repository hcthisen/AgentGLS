#!/bin/bash
# memory-load.sh — SessionStart hook wrapper
# Called by Claude Code at session start to load memory context
exec "$(dirname "$0")/memory.sh" load
