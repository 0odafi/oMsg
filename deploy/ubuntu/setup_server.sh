#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/ubuntu/setup_server.sh"
  exit 1
fi

APP_USER="omsg"
BASE_DIR="/opt/omsg"
APP_DIR="$BASE_DIR"
VENV_DIR="$BASE_DIR/venv"
RELEASES_DIR="$BASE_DIR/releases"
ENV_DIR="/etc/omsg"
DEPLOY_USER="${SUDO_USER:-$(id -un)}"

apt update
apt install -y python3 python3-venv python3-pip nginx git rsync unzip ufw postgresql redis-server

systemctl enable --now postgresql
systemctl enable --now redis-server

id -u "$APP_USER" >/dev/null 2>&1 || useradd -r -m -d "$BASE_DIR" -s /usr/sbin/nologin "$APP_USER"

mkdir -p "$APP_DIR" "$RELEASES_DIR" "$ENV_DIR"
chown -R "$APP_USER:$APP_USER" "$BASE_DIR"
if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  chown -R "$DEPLOY_USER:$DEPLOY_USER" "$RELEASES_DIR"
fi
chmod -R 775 "$RELEASES_DIR"

if [[ ! -d "$VENV_DIR" ]]; then
  sudo -u "$APP_USER" python3 -m venv "$VENV_DIR"
fi

echo "Server base setup complete."
echo "Next:"
echo "1) Copy project to $APP_DIR"
echo "2) Copy deploy/ubuntu/api.env.example to $ENV_DIR/api.env and edit values"
echo "3) Install service and nginx configs from deploy/ubuntu/"
echo "4) Use DEPLOY_USER=$DEPLOY_USER in GitHub secrets for release upload"
