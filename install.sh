#!/bin/bash
# DIY Assistant installer - run on the WORK server, as root:
#
#   curl -fsSL https://raw.githubusercontent.com/SnailguardianSG/diy-assistant/main/install.sh | bash
#
# It sets up both servers: this work server (the AI, voice-to-text, the worker)
# and the production server (the Telegram bot and its database), which it
# reaches with the address and password you give it. It asks for three things:
# the production server's address, its root password, and your bot's token -
# and walks you through logging in to Claude. Safe to run again.
set -euo pipefail

KIT_REPO="${KIT_REPO:-https://github.com/SnailguardianSG/diy-assistant.git}"
USER_NAME=assistant
HOME_DIR=/home/$USER_NAME
WORK_DIR=$HOME_DIR/assistant
PROD_DIR=diy-assistant
MODEL_DIR=/opt/assistant/models/faster-whisper-large-v3-turbo
LOG=/var/log/diy-assistant-install.log

say()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m   OK\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m   Problem:\033[0m %s\n' "$*"; exit 1; }
ask()  { local v; read -r -p "   $1: " v </dev/tty; printf '%s' "$v"; }
ask_secret() { local v; read -r -s -p "   $1 (nothing shows while you paste - that's normal): " v </dev/tty; echo >&2; printf '%s' "$v"; }
as_user() { sudo -u "$USER_NAME" -H bash -c "$*"; }

[ "$(id -u)" = 0 ] || fail "Run this as root (log in to the work server as root)."
exec > >(tee -a "$LOG") 2>&1          # a log of what happened (no passwords or tokens are printed)
. /etc/os-release
[ "${VERSION_ID:-}" = "24.04" ] || echo "   Note: tested on Ubuntu 24.04; this is ${PRETTY_NAME:-unknown}."

say "Step 1 of 8: installing the basic tools (a few minutes)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl rsync ffmpeg python3-venv sshpass jq openssl ca-certificates >/dev/null
ok "tools installed"

say "Step 2 of 8: getting the assistant"
id "$USER_NAME" >/dev/null 2>&1 || useradd -m -s /bin/bash "$USER_NAME"
if [ -n "${KIT_DIR:-}" ]; then SRC=$KIT_DIR; else
  SRC=$(mktemp -d); git clone -q --depth 1 "$KIT_REPO" "$SRC"; fi
chmod -R a+rX "$SRC"                  # the assistant user copies from it
mkdir -p "$WORK_DIR"
rsync -a --exclude prod.env --exclude data --exclude logs --exclude workspace "$SRC/work/" "$WORK_DIR/"
chown -R "$USER_NAME:$USER_NAME" "$WORK_DIR"
[ -f "$HOME_DIR/.ssh/id_ed25519" ] || as_user "ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519"
ok "assistant files in $WORK_DIR"

say "Step 3 of 8: connecting to your production server"
echo "   Use the production server's address and root password from ReadyServer."
PROD_ADDR=$(ask "Production server address (e.g. 203.0.113.10)")
[ -n "$PROD_ADDR" ] || fail "No address given."
if ! as_user "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new root@$PROD_ADDR true" 2>/dev/null; then
  PROD_PW=$(ask_secret "Production server root password")
  SSHPASS="$PROD_PW" sudo -u "$USER_NAME" -H --preserve-env=SSHPASS \
    sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$HOME_DIR/.ssh/id_ed25519.pub" "root@$PROD_ADDR" >/dev/null 2>&1 \
    || fail "Couldn't log in to $PROD_ADDR. Check the address and password, then run the install command again."
  unset PROD_PW
fi
# One shared SSH connection to production, kept open and reused by every command
# (installer, worker, scripts). Hosts like ReadyServer rate-limit SSH (ufw LIMIT:
# ~6 new connections in 30 s, then refused), and the worker checks every 15 s.
mkdir -p "$HOME_DIR/.ssh"
python3 - "$HOME_DIR/.ssh/config" "$PROD_ADDR" <<'PYCFG'
import re, sys
path, addr = sys.argv[1], sys.argv[2]
try: s = open(path).read()
except FileNotFoundError: s = ""
s = re.sub(r"# diy-assistant production\nHost prod\n(?:  [^\n]*\n)*", "", s)
s += ("# diy-assistant production\nHost prod\n  HostName %s\n  User root\n"
      "  IdentityFile ~/.ssh/id_ed25519\n  StrictHostKeyChecking accept-new\n"
      "  ControlMaster auto\n  ControlPath ~/.ssh/cm-%%C\n  ControlPersist 10m\n"
      "  ServerAliveInterval 30\n" % addr)
open(path, "w").write(s)
PYCFG
chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh/config"; chmod 600 "$HOME_DIR/.ssh/config"
sleep 31                              # let the host's rate limit forget the logins above
as_user "ssh -o BatchMode=yes prod true" || fail "Couldn't connect to $PROD_ADDR."
printf 'PROD_SSH=prod\nPROD_DIR=%s\n' "$PROD_DIR" > "$WORK_DIR/prod.env"
chown "$USER_NAME:$USER_NAME" "$WORK_DIR/prod.env"
ok "connected to $PROD_ADDR"
# Run a command on the production server. The command string is passed to ssh as
# one argument, so the production server's shell - not this one - reads it.
P() {
  local i
  for i in 1 2 3; do
    sudo -u "$USER_NAME" -H ssh -o BatchMode=yes prod "$*" && return 0
    [ $? -ne 255 ] && return 1          # the command failed, not the connection
    echo "   (connection dropped - retrying in 30 s)"; sleep 30
  done
  return 1
}

say "Step 4 of 8: setting up the production server (a few minutes)"
P 'command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh >/dev/null 2>&1'
# Firewall: SSH from this work server always allowed; everyone else rate-limited.
P 'if command -v ufw >/dev/null; then ip=${SSH_CLIENT%% *};
     ufw insert 1 allow from "$ip" to any port 22 proto tcp >/dev/null 2>&1 || ufw allow from "$ip" to any port 22 proto tcp >/dev/null;
     ufw limit 22/tcp >/dev/null; ufw --force enable >/dev/null; fi'
P "mkdir -p $PROD_DIR/data/feedback"
sudo -u "$USER_NAME" -H rsync -a --exclude .env --exclude data -e "ssh -o BatchMode=yes" \
  "$SRC/production/" "prod:$PROD_DIR/" || fail "Couldn't copy the bot's files to $PROD_ADDR."
P "cd $PROD_DIR && touch .env && chmod 600 .env && (grep -q '^DB_PASSWORD=' .env || echo DB_PASSWORD=\$(openssl rand -hex 24) >> .env)"
ok "Docker, firewall and the bot's files are ready"

say "Step 5 of 8: your Telegram bot"
cat <<'TXT'
   In Telegram, open @BotFather (blue tick):
     1. Send /newbot, then a name, then a username ending in "bot".
     2. Send /setprivacy, choose your bot, choose Disable.
     3. Copy the token BotFather gave you (it looks like 123456789:AAH...).
TXT
TOKEN=""
if P "cd $PROD_DIR && grep -q '^TELEGRAM_BOT_TOKEN=.*:' .env"; then
  echo "   The bot's token is already set - keeping it."; TOKEN=keep
fi
until [[ "$TOKEN" == *:* || "$TOKEN" == keep ]]; do
  TOKEN=$(ask_secret "Paste the bot token")
  [[ "$TOKEN" == *:* ]] || echo "   That doesn't look like a bot token (no colon). Try again."
done
# The token travels on stdin, never as a command argument (those show up in process lists).
[ "$TOKEN" = keep ] || printf '%s\n' "$TOKEN" | P "cd $PROD_DIR && grep -v '^TELEGRAM_BOT_TOKEN=' .env > .env.tmp; mv .env.tmp .env; read -r t; echo \"TELEGRAM_BOT_TOKEN=\$t\" >> .env; chmod 600 .env"
unset TOKEN
P "cd $PROD_DIR && docker compose up -d --build >/dev/null 2>&1"
BOT=""
for _ in $(seq 1 24); do
  BOT=$(P "cd $PROD_DIR && docker compose logs bot 2>/dev/null | grep -o 'connected as @[A-Za-z0-9_]*' | tail -1" || true)
  [ -n "$BOT" ] && break; sleep 5
done
[ -n "$BOT" ] || fail "The bot didn't start. Check the token, then run the install command again."
ok "bot $BOT"
# Privacy mode on = the bot sees commands but not messages. Don't go on until it's off.
privacy_off() { P "cd $PROD_DIR && docker compose exec -T bot node -e 'fetch(\"https://api.telegram.org/bot\"+process.env.TELEGRAM_BOT_TOKEN+\"/getMe\").then(r=>r.json()).then(j=>console.log(j.result.can_read_all_group_messages))'" 2>/dev/null | grep -q true; }
until privacy_off; do
  echo "   Your bot can't read group messages yet. In @BotFather send /setprivacy, choose your bot, choose Disable."
  read -r -p "   Press Enter when done... " _ </dev/tty
done
ok "the bot can read group messages"
# A setup code only until the bot has an owner (a re-run must not open a new one).
OWNER=$(as_user "cd $WORK_DIR && bash psql.sh -Atq -c \"select value from ops.bot_state where key = 'owner_tg_user_id'\"" || true)
CODE=""
if [ -z "$OWNER" ]; then
  CODE=$(shuf -i 1000-9999 -n 1)
  as_user "cd $WORK_DIR && bash psql.sh -Atq -c \"insert into ops.bot_state (key, value) values ('setup_code', '$CODE') on conflict (key) do update set value = excluded.value\"" \
    || fail "Couldn't save the setup code."
fi

say "Step 6 of 8: logging in to Claude"
if [ ! -x "$HOME_DIR/.local/bin/claude" ]; then
  as_user 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null 2>&1 || fail "Couldn't install Claude."
fi
if ! as_user "cd $WORK_DIR && timeout 120 ~/.local/bin/claude -p 'Reply with the single word ready.' 2>/dev/null" | grep -qi ready; then
  cat <<'TXT'
   Claude opens next. Log in with your Claude account (follow the link it shows,
   then paste the code back). If it asks whether to trust this folder, choose Yes.
   When you see Claude's prompt, type /exit and press Enter.
TXT
  read -r -p "   Press Enter to open Claude... " _ </dev/tty
  # su, not sudo: Ubuntu 24.04's sudo runs commands in its own pseudo-terminal
  # (use_pty), which swallowed keys in Claude's full-screen login (rehearsal).
  su - "$USER_NAME" -c "cd $WORK_DIR && ~/.local/bin/claude" </dev/tty >/dev/tty 2>&1 || true
  as_user "cd $WORK_DIR && timeout 120 ~/.local/bin/claude -p 'Reply with the single word ready.' 2>/dev/null" | grep -qi ready \
    || fail "Claude isn't logged in yet. Run the install command again to retry."
fi
ok "Claude is ready"

say "Step 7 of 8: voice-to-text (downloads about 1.6 GB - takes a few minutes)"
mkdir -p /opt/assistant/models
[ -x /opt/assistant/venv/bin/python ] || python3 -m venv /opt/assistant/venv
/opt/assistant/venv/bin/pip install -q faster-whisper
[ -f "$MODEL_DIR/model.bin" ] || /opt/assistant/venv/bin/python -c \
  "from faster_whisper import download_model; download_model('large-v3-turbo', output_dir='$MODEL_DIR')" >/dev/null 2>&1
[ -f "$MODEL_DIR/model.bin" ] || fail "The voice-to-text download didn't finish. Run the install command again."
chmod -R a+rX /opt/assistant
ok "voice-to-text ready"

say "Step 8 of 8: starting the assistant"
cat > /etc/systemd/system/diy-assistant.service <<EOF
[Unit]
Description=DIY Assistant worker
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
WorkingDirectory=$WORK_DIR
Environment=PATH=$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash $WORK_DIR/worker.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now diy-assistant.service >/dev/null 2>&1
systemctl restart diy-assistant.service
sleep 3
systemctl is-active --quiet diy-assistant.service || fail "The assistant didn't start (systemctl status diy-assistant)."
ok "assistant running"

printf '\n\033[1;32m   All done!\033[0m\n\n'
if [ -z "$CODE" ]; then
  echo "   Updated. Your bot already has an owner - nothing to do in Telegram."; exit 0
fi
cat <<TXT
   Now, in Telegram:
     1. Create a group and add your bot $BOT
        (open the bot's profile -> its name -> Add to Group).
     2. In the group, send:

            /setup $CODE

   The bot introduces itself, and you're its owner. Then just talk to it.

   Your setup code: $CODE
TXT
