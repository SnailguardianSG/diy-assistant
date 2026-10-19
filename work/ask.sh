#!/bin/bash
# ask.sh <note id> "<question>"  - ask about one note, threaded under it. The reply comes back as a new note.
set -euo pipefail
cd "$(dirname "$0")"
ID="${1:?usage: ask.sh <note id> \"<question>\"}"; shift; Q="$*"
[ -n "$Q" ] || { echo "empty question" >&2; exit 1; }
bash psql.sh -Atq -v q="$Q" -v id="$ID" <<'SQL'
select ops.fb_ask(:'id'::bigint, :'q');
select 'asked about note ' || :'id';
SQL
