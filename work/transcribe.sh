#!/bin/bash
# transcribe.sh <file from dump-queue.sh>  - a voice note or recording to text (English or Chinese).
cd "$(dirname "$0")" || exit 1
exec /opt/assistant/venv/bin/python -I transcribe-voice.py "$1" 2>/dev/null
