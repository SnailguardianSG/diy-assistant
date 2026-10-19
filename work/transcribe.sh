#!/bin/bash
# transcribe.sh <file from dump-queue.sh>  - a voice note or recording to text (English or Chinese).
# Errors go to logs/transcribe.log; on failure it prints one plain line saying why.
cd "$(dirname "$0")" || exit 1
mkdir -p logs
PY=${ASSISTANT_PYTHON:-/opt/assistant/venv/bin/python}
if ! out=$("$PY" -I transcribe-voice.py "$1" 2>>logs/transcribe.log); then
  echo "Transcription failed: $(grep -v -i warn logs/transcribe.log | tail -1)"
  exit 1
fi
printf '%s\n' "$out"
