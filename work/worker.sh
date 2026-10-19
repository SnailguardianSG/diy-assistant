#!/bin/bash
# worker.sh  - keeps the assistant running (a systemd service, as the user "assistant").
#
# Every 15 s it checks the queue on the production server. When the group has
# been quiet for 45 s with something new, or someone sent /process, it copies
# the media over and wakes the AI to work the queue (claude -p, the rules in
# CLAUDE.md, only the tools in .claude/settings.json). It beats every 30 s, so
# the bot can tell the group when the assistant is offline.
cd "$(dirname "$0")" || exit 1
mkdir -p logs workspace
log() { echo "$(date '+%F %T') $*" >> logs/worker.log; }

beat() {
  bash psql.sh -Atq -c "insert into ops.bot_state (key, value, updated_at)
    values ('claude_heartbeat', extract(epoch from now())::text, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();" >/dev/null 2>&1
}
# Prints: <process marker> <READY|WAIT>:<count>:<max id>
state() {
  bash psql.sh -Aqt 2>/dev/null <<'SQL'
select coalesce((select value from ops.bot_state where key = 'process_requested'), '0') || ' ' ||
       (select case when count(*) > 0 and max(received_at) < now() - interval '45 seconds'
                    then 'READY' else 'WAIT' end || ':' || count(*) || ':' || coalesce(max(id), 0)
          from ops.feedback where status = 'new');
SQL
}

wake_ai() {
  bash sync-media.sh || log "media copy failed"
  ( while sleep 30; do beat; done ) & local beater=$!
  log "waking the AI ($1)"
  timeout 1800 claude -p "$(cat wake-prompt.txt)" --output-format text >> logs/ai.log 2>&1
  log "AI finished (exit $?)"
  kill "$beater" 2>/dev/null
}

log "worker started"
RETRY_AFTER=600                       # still waiting 10 min after a run: try again
last_run=0
read -r P0 S0 <<<"$(state)"
case "$S0" in READY*) wake_ai "waiting at start"; read -r P0 S0 <<<"$(state)" ;; esac
last=0
while true; do
  now=$(date +%s); [ $((now - last)) -ge 30 ] && { beat; last=$now; }
  read -r P S <<<"$(state)"
  if [ -n "$P" ]; then
    work=
    [ "$P" != "$P0" ] && work="/process"
    case "$S" in
      READY*) if [ "$S" != "$S0" ]; then work="group went quiet"
              elif [ $((now - last_run)) -ge $RETRY_AFTER ]; then work="still waiting - trying again"; fi ;;
      WAIT:0:*) S0="" ;;
    esac
    if [ -n "$work" ]; then
      wake_ai "$work"; last_run=$(date +%s)
      # What is still waiting now counts as seen; a new message wakes it again.
      read -r P0 S0 <<<"$(state)"
    fi
  fi
  sleep 15
done
