#!/bin/bash
# sync-media.sh  - bring the voice notes, photos and files the group sent over
# from the production server, into ./data/feedback, for transcribing and reading.
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091
. ./prod.env
mkdir -p data/feedback
rsync -a -e "ssh -o BatchMode=yes" "$PROD_SSH:$PROD_DIR/data/feedback/" data/feedback/
