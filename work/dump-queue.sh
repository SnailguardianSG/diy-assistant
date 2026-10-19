#!/bin/bash
# dump-queue.sh  - what is waiting: new notes (with local file paths), open questions, counts.
cd "$(dirname "$0")" || exit 1
bash psql.sh -P pager=off <<'SQL'
\echo === WAITING (oldest first) ===
select coalesce(batch_id::text, '-') as batch, id, kind, coalesce(tg_display_name, 'unknown') as who,
       to_char(received_at, 'DD Mon HH24:MI') as at, coalesce(duration_s::text, '') as secs,
       coalesce(nullif(body, ''), '(media)') as message,
       coalesce(replace(file_path, '/data/feedback/', 'data/feedback/'), '') as file,
       coalesce('answers note ' || (select o.feedback_id::text from ops.bot_outbox o
                  where o.tg_chat_id = f.tg_chat_id and o.sent_message_id = f.reply_to_message_id
                    and o.kind = 'question' limit 1), '') as answers
from ops.feedback f where status = 'new' order by batch_id nulls last, batch_seq, received_at;
\echo === QUESTIONS STILL OPEN ===
select id as note, question, to_char(asked_at, 'DD Mon HH24:MI') as asked
from ops.feedback where asked_at is not null and answered_at is null order by asked_at;
select id as choice, question, options from ops.choice where chosen is null order by id;
\echo === COUNTS ===
select status, count(*) from ops.feedback group by 1 order by 1;
SQL
