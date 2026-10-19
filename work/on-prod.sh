#!/bin/bash
# on-prod.sh <command...>  - run a command on the production server, in the
# assistant's folder there. prod.env (written by the installer):
#   PROD_SSH=root@<production address>    PROD_DIR=diy-assistant
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091
. ./prod.env
exec ssh -o BatchMode=yes -o ConnectTimeout=10 "$PROD_SSH" "cd $(printf '%q' "$PROD_DIR") && $(printf ' %q' "$@")"
