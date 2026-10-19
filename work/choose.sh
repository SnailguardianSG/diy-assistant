#!/bin/bash
# choose.sh "<question>" "<option 1>" "<option 2>" [...up to 6]  - ask with buttons to tap.
# The tap comes back as a new note "[Chose] <option>".
set -euo pipefail
cd "$(dirname "$0")"
Q="${1:?usage: choose.sh \"<question>\" \"<option>\" \"<option>\" ...}"; shift
[ $# -ge 2 ] || { echo "give at least two options" >&2; exit 1; }
OPTS=$(printf '%s\n' "$@" | python3 -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')
bash psql.sh -Atq -v q="$Q" -v opts="$OPTS" <<'SQL'
select 'asked choice #' || ops.ask_choice(
  (select value::bigint from ops.bot_state where key = 'process_chat_id'), :'q', :'opts'::jsonb);
SQL
