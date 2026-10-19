#!/bin/bash
# say.sh "<text>"  - post a message in the group.
TEXT="$*"; [ -n "$TEXT" ] || { echo 'usage: say.sh "<text>"'; exit 1; }
cd "$(dirname "$0")" || exit 1
bash psql.sh -Atq -v body="$TEXT" <<'SQL'
insert into ops.bot_outbox (tg_chat_id, body, kind)
select value::bigint, :'body', 'update' from ops.bot_state where key = 'process_chat_id'
returning 'posted #' || id;
SQL
