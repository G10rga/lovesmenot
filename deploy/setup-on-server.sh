#!/usr/bin/env bash
# Run on the Ubuntu server (bengbicho) as g1orga.
# Usage: bash deploy/setup-on-server.sh [port]
set -euo pipefail

APP_DIR="${APP_DIR:-/var/www/lovesmenot}"
PORT="${1:-5055}"
SERVICE_NAME="lovesmenot"
TUNNEL_CFG="${TUNNEL_CFG:-$HOME/.cloudflared/config.yml}"

echo "==> Using port ${PORT}"
if ss -tln | grep -qE ":${PORT}\\b"; then
  echo "Port ${PORT} is already in use. Pick another unused port and re-run:"
  echo "  bash deploy/setup-on-server.sh <port>"
  exit 1
fi

echo "==> Ensure app directory ${APP_DIR}"
sudo mkdir -p "${APP_DIR}"
sudo chown -R "$(whoami):$(whoami)" "${APP_DIR}"

# Expect this repo already copied/cloned into APP_DIR (or cwd is the repo).
REPO_SRC="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${REPO_SRC}" != "${APP_DIR}" ]]; then
  echo "==> Syncing files from ${REPO_SRC} -> ${APP_DIR}"
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.venv' \
    --exclude '__pycache__' \
    "${REPO_SRC}/" "${APP_DIR}/"
fi

cd "${APP_DIR}"

echo "==> Python venv + deps"
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "==> systemd unit on 127.0.0.1:${PORT}"
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=Loves Me Not Flask App
After=network.target

[Service]
User=$(whoami)
Group=$(whoami)
WorkingDirectory=${APP_DIR}
Environment=PATH=${APP_DIR}/.venv/bin
ExecStart=${APP_DIR}/.venv/bin/gunicorn --workers 2 --bind 127.0.0.1:${PORT} app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}.service"
sudo systemctl restart "${SERVICE_NAME}.service"
sudo systemctl --no-pager --full status "${SERVICE_NAME}.service" || true

echo "==> Litera tunnel ingress for lizi.g1orga.dev"
if [[ ! -f "${TUNNEL_CFG}" ]]; then
  if [[ -f /etc/cloudflared/config.yml ]]; then
    TUNNEL_CFG=/etc/cloudflared/config.yml
  else
    echo "Could not find cloudflared config. Set TUNNEL_CFG=/path/to/config.yml"
    exit 1
  fi
fi

echo "Tunnel config: ${TUNNEL_CFG}"
if grep -q 'hostname: lizi.g1orga.dev' "${TUNNEL_CFG}"; then
  echo "Ingress for lizi.g1orga.dev already present — update the service port manually if needed."
else
  # Insert hostname rule before the catch-all http_status:404 (or append near ingress list).
  TMP="$(mktemp)"
  python3 - "${TUNNEL_CFG}" "${PORT}" "${TMP}" <<'PY'
import re
import sys
path, port, out = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
rule = f"  - hostname: lizi.g1orga.dev\n    service: http://127.0.0.1:{port}\n"
catch_all = re.compile(r"(?m)^[ \t]*-[ \t]*service:[ \t]*http_status:404[ \t]*\n?")
if catch_all.search(text):
    text = catch_all.sub(rule + "  - service: http_status:404\n", text, count=1)
elif "ingress:" in text:
    text = text.replace("ingress:\n", "ingress:\n" + rule, 1)
else:
    raise SystemExit("No ingress section found in tunnel config")
open(out, "w", encoding="utf-8").write(text)
print("Prepared updated config")
PY
  if [[ "${TUNNEL_CFG}" == /etc/* ]]; then
    sudo cp "${TMP}" "${TUNNEL_CFG}"
  else
    cp "${TMP}" "${TUNNEL_CFG}"
  fi
  rm -f "${TMP}"
fi

echo "==> Restart cloudflared / litera tunnel service"
if systemctl list-unit-files | grep -q '^cloudflared.service'; then
  sudo systemctl restart cloudflared
elif systemctl list-unit-files | grep -q '^litera.service'; then
  sudo systemctl restart litera
else
  echo "Restart your litera/cloudflared unit manually after validating config."
fi

echo "==> DNS: ensure lizi.g1orga.dev CNAME/route points at the litera tunnel"
echo "Done. Local check: curl -sI http://127.0.0.1:${PORT}/"
echo "Public check: curl -sI https://lizi.g1orga.dev/"
