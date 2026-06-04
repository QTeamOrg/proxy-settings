#!/bin/bash
set -euo pipefail

prompt_default() { local prompt="$1" default="$2" var; read -p "$prompt" var || true; echo "${var:-$default}"; }
prompt_secret() { local prompt="$1" var; read -s -p "$prompt" var || true; echo; echo "$var"; }
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_valid_username() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }
is_nonempty() { [[ -n "$1" ]]; }
is_valid_choice() { local v="${1,,}"; [[ "$v" == "y" || "$v" == "yes" || "$v" == "n" || "$v" == "no" ]]; }
norm_choice() { local v="${1,,}"; [[ "$v" == "y" || "$v" == "yes" ]] && echo "yes" || echo "no"; }
is_valid_parent_type() { local v="${1,,}"; [[ "$v" == "http" || "$v" == "https" || "$v" == "socks5" || "$v" == "socks4" ]]; }
is_valid_host() { [[ -n "$1" ]]; }

while true; do read -p "Enter proxy username: " PROXY_USER || true; is_valid_username "$PROXY_USER" && break || echo "Invalid username. Use 1-32 chars: letters, digits, dot, underscore, hyphen."; done
while true; do PROXY_PASS=$(prompt_secret "Enter proxy password: "); is_nonempty "$PROXY_PASS" && break || echo "Password cannot be empty."; done

while true; do HTTP_PORT=$(prompt_default "Enter HTTP/HTTPS port [default 3128]: " "3128"); is_valid_port "$HTTP_PORT" && break || echo "Invalid port. Use 1-65535."; done
while true; do SOCKS_PORT=$(prompt_default "Enter SOCKS port [default 1080]: " "1080"); is_valid_port "$SOCKS_PORT" && break || echo "Invalid port. Use 1-65535."; done

while true; do read -p "Chain via another proxy? (y/N): " USE_PARENT_CHOICE || true; [[ -z "$USE_PARENT_CHOICE" ]] && USE_PARENT_CHOICE="n"; is_valid_choice "$USE_PARENT_CHOICE" && break || echo "Please answer y or n."; done
USE_PARENT=$(norm_choice "$USE_PARENT_CHOICE")

PARENT_BLOCK=""
DENY_DIRECT=""
if [[ "$USE_PARENT" == "yes" ]]; then
  while true; do read -p "Parent proxy type [http/https/socks5/socks4, default http]: " PARENT_TYPE || true; PARENT_TYPE=${PARENT_TYPE:-http}; is_valid_parent_type "$PARENT_TYPE" && break || echo "Invalid type. Use http, https, socks5, socks4."; done
  PARENT_KIND="${PARENT_TYPE,,}"; [[ "$PARENT_KIND" == "https" ]] && PARENT_KIND="http"
  while true; do read -p "Parent proxy host/IP: " PARENT_HOST || true; is_valid_host "$PARENT_HOST" && break || echo "Host cannot be empty."; done
  while true; do read -p "Parent proxy port: " PARENT_PORT || true; is_valid_port "$PARENT_PORT" && break || echo "Invalid port. Use 1-65535."; done
  read -p "Parent username (leave empty if none): " PARENT_USER || true
  if [[ -n "${PARENT_USER}" ]]; then
    while true; do PARENT_PASS=$(prompt_secret "Parent password: "); is_nonempty "$PARENT_PASS" && break || echo "Password cannot be empty."; done
    PARENT_BLOCK="parent $PARENT_KIND 1 $PARENT_HOST $PARENT_PORT $PARENT_USER $PARENT_PASS
"
  else
    PARENT_BLOCK="parent $PARENT_KIND 1 $PARENT_HOST $PARENT_PORT
"
  fi
  DENY_DIRECT='deny * *'
fi

sudo apt update
sudo apt install -y git build-essential ufw curl libssl-dev

if [[ -d 3proxy ]]; then git -C 3proxy pull --ff-only || true; else git clone https://github.com/z3APA3A/3proxy.git; fi
cd 3proxy
make -f Makefile.Linux

sudo mkdir -p /etc/3proxy/logs
sudo cp ./bin/3proxy /usr/local/bin/

CFG="/etc/3proxy/3proxy.cfg"
DNS1="8.8.8.8"
DNS2="1.1.1.1"

read -r -d '' BASE_CFG <<EOF || true
nserver $DNS1
nserver $DNS2
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /etc/3proxy/logs/3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%c %R:%r %O %I %h %T"
auth strong
users $PROXY_USER:CL:$PROXY_PASS
allow $PROXY_USER
EOF

read -r -d '' SRV_CFG <<EOF || true
socks -p$SOCKS_PORT
proxy -p$HTTP_PORT
$DENY_DIRECT
EOF

sudo tee "$CFG" > /dev/null <<< "${BASE_CFG}${PARENT_BLOCK}${SRV_CFG}"

sudo tee /etc/systemd/system/3proxy.service > /dev/null <<'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow ${SOCKS_PORT}/tcp
sudo ufw allow ${HTTP_PORT}/tcp
sudo ufw allow 'OpenSSH'
sudo ufw --force enable
sudo ufw reload

sudo systemctl daemon-reexec
sudo systemctl enable 3proxy
sudo systemctl restart 3proxy

SERVER_IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")

echo
echo "Installation completed."
echo "HTTP: ${SERVER_IP}:${HTTP_PORT}:${PROXY_USER}:${PROXY_PASS}:http"
echo "HTTPS: ${SERVER_IP}:${HTTP_PORT}:${PROXY_USER}:${PROXY_PASS}:https"
echo "SOCKS5: ${SERVER_IP}:${SOCKS_PORT}:${PROXY_USER}:${PROXY_PASS}:socks5"
if [[ "$USE_PARENT" == "yes" ]]; then
  echo "Chaining is enabled via parent:"
  echo "Type: ${PARENT_TYPE}"
  echo "Address: ${PARENT_HOST}:${PARENT_PORT}"
  if [[ -n "${PARENT_USER:-}" ]]; then echo "Auth: ${PARENT_USER}/********"; else echo "Auth: none"; fi
fi
