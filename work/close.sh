#!/bin/bash
# close.sh <note id> done|quiet|wont "<what was done / why>"
#   done   - posts "Done." + your text under the note
#   quiet  - closes it with nothing posted (people talking to each other, a thank-you)
#   wont   - posts "Not doing this one." + your reason
set -euo pipefail
cd "$(dirname "$0")"
ID="${1:?usage: close.sh <note id> done|quiet|wont \"<text>\"}"; HOW="${2:?done|quiet|wont}"; shift 2; T="$*"
case "$HOW" in done) F=fb_done ;; quiet) F=fb_quiet ;; wont) F=fb_wont ;; *) echo "done|quiet|wont" >&2; exit 2 ;; esac
bash psql.sh -Atq -v id="$ID" -v t="$T" <<SQL
select ops.$F(:'id'::bigint, :'t');
select 'closed note ' || :'id' || ' ($HOW)';
SQL
