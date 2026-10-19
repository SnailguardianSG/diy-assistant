#!/bin/bash
# psql.sh [psql args]  - the assistant's database on the production server (SQL on stdin works).
cd "$(dirname "$0")" || exit 1
exec bash on-prod.sh docker compose exec -T db psql -U assistant -d assistant -v ON_ERROR_STOP=1 "$@"
