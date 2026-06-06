#!/bin/bash
set -euo pipefail

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO="sudo"
fi

require_tty() {
  if [[ ! -r /dev/tty ]]; then
    echo "This script requires an interactive terminal."
    exit 1
  fi
}

prompt() {
  local text="$1" value
  read -r -p "$text" value < /dev/tty
  printf '%s' "$value"
}

prompt_default() {
  local text="$1" default="$2" value
  read -r -p "$text" value < /dev/tty
  printf '%s' "${value:-$default}"
}

prompt_secret() {
  local text="$1" value
  read -r -s -p "$text" value < /dev/tty
  printf '\n' > /dev/tty
  printf '%s' "$value"
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

is_valid_username() {
  local value="$1"
  [[ "$value" =~ ^[a-zA-Z0-9_.-]+$ ]]
}

is_valid_password() {
  local value="$1"
  [[ "$value" =~ ^[a-zA-Z0-9_.@%+=,-]+$ ]]
}

is_valid_host() {
  local value="$1"
  [[ -n "$value" && ! "$value" =~ [[:space:]] ]]
}

prompt_username() {
  local value

  while true; do
    value=$(prompt "Proxy username: ")

    if is_valid_username "$value"; then
      printf '%s' "$value"
      return
    fi

    echo "Invalid username. Use only letters, digits, dot, underscore and dash." > /dev/tty
  done
}

prompt_password() {
  local value

  while true; do
    value=$(prompt_secret "Proxy password: ")

    if is_valid_password "$value"; then
      printf '%s' "$value"
      return
    fi

    echo "Invalid password. Use only letters, digits and these symbols: . _ @ % + = , -" > /dev/tty
  done
}

prompt_port() {
  local text="$1" default="$2" value

  while true; do
    value=$(prompt_default "$text" "$default")

    if is_valid_port "$value"; then
      printf '%s' "$value"
      return
    fi

    echo "Invalid port. Use a number from 1 to 65535." > /dev/tty
  done
}

require_tty

PROXY_USER=$(prompt_username)
PROXY_PASS=$(prompt_password)
HTTP_PORT=$(prompt_port "HTTP/HTTPS port [default 3128]: " "3128")
SOCKS_PORT=$(prompt_port "SOCKS5 port [default 1080]: " "1080")

while [[ "$HTTP_PORT" == "$SOCKS_PORT" ]]; do
  echo "HTTP and SOCKS ports must be different." > /dev/tty
  SOCKS_PORT=$(prompt_port "SOCKS5 port [default 1080]: " "1080")
done

USE_PARENT_CHOICE=$(prompt_default "Use upstream/parent proxy? (y/N): " "n")
USE_PARENT_CHOICE=$(to_lower "$USE_PARENT_CHOICE")

USE_PARENT="no"
PARENT_BLOCK=""
PARENT_TYPE=""
PARENT_KIND=""
PARENT_HOST=""
PARENT_PORT=""
PARENT_USER=""
PARENT_PASS=""

if [[ "$USE_PARENT_CHOICE" == "y" || "$USE_PARENT_CHOICE" == "yes" ]]; then
  USE_PARENT="yes"

  while true; do
    PARENT_TYPE=$(prompt_default "Parent proxy type [http/https/socks5/socks4] default http: " "http")
    PARENT_TYPE=$(to_lower "$PARENT_TYPE")

    case "$PARENT_TYPE" in
      http|https)
        PARENT_KIND="connect"
        break
        ;;
      socks5)
        PARENT_KIND="socks5"
        break
        ;;
      socks4)
        PARENT_KIND="socks4"
        break
        ;;
      *)
        echo "Invalid parent proxy type. Allowed: http, https, socks5, socks4." > /dev/tty
        ;;
    esac
  done

  while true; do
    PARENT_HOST=$(prompt "Parent proxy host/IP: ")

    if is_valid_host "$PARENT_HOST"; then
      break
    fi

    echo "Invalid parent host/IP." > /dev/tty
  done

  PARENT_PORT=$(prompt_port "Parent proxy port: " "3128")

  PARENT_USER=$(prompt "Parent proxy username, empty if none: ")

  if [[ -n "$PARENT_USER" ]]; then
    if ! is_valid_username "$PARENT_USER"; then
      echo "Invalid parent username. Use only letters, digits, dot, underscore and dash."
      exit 1
    fi

    PARENT_PASS=$(prompt_secret "Parent proxy password: ")

    if ! is_valid_password "$PARENT_PASS"; then
      echo "Invalid parent password. Use only letters, digits and these symbols: . _ @ % + = , -"
      exit 1
    fi

    PARENT_BLOCK="parent 1000 $PARENT_KIND $PARENT_HOST $PARENT_PORT $PARENT_USER $PARENT_PASS"
  else
    PARENT_BLOCK="parent 1000 $PARENT_KIND $PARENT_HOST $PARENT_PORT"
  fi
fi

export DEBIAN_FRONTEND=noninteractive

$SUDO apt update
$SUDO apt install -y git build-essential ufw curl libssl-dev ca-certificates

SRC_DIR="/usr/local/src/3proxy"

$SUDO mkdir -p /usr/local/src

if [[ -d "$SRC_DIR/.git" ]]; then
  $SUDO git -C "$SRC_DIR" pull --ff-only
else
  $SUDO git clone https://github.com/z3APA3A/3proxy.git "$SRC_DIR"
fi

$SUDO make -C "$SRC_DIR" -f Makefile.Linux
$SUDO install -m 0755 "$SRC_DIR/bin/3proxy" /usr/local/bin/3proxy

$SUDO mkdir -p /etc/3proxy/logs

CFG="/etc/3proxy/3proxy.cfg"

if [[ "$USE_PARENT" == "yes" ]]; then
  CONFIG_CONTENT=$(cat <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /etc/3proxy/logs/3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%c %R:%r %O %I %h %T"
auth strong
users $PROXY_USER:CL:$PROXY_PASS
allow $PROXY_USER
$PARENT_BLOCK
socks -p$SOCKS_PORT
proxy -p$HTTP_PORT
EOF
)
else
  CONFIG_CONTENT=$(cat <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /etc/3proxy/logs/3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%c %R:%r %O %I %h %T"
auth strong
users $PROXY_USER:CL:$PROXY_PASS
allow $PROXY_USER
socks -p$SOCKS_PORT
proxy -p$HTTP_PORT
EOF
)
fi

printf '%s\n' "$CONFIG_CONTENT" | $SUDO tee "$CFG" > /dev/null
$SUDO chmod 600 "$CFG"

$SUDO tee /etc/systemd/system/3proxy.service > /dev/null <<'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

$SUDO ufw allow "$SOCKS_PORT/tcp"
$SUDO ufw allow "$HTTP_PORT/tcp"
$SUDO ufw allow OpenSSH || true

if [[ -n "${SSH_CONNECTION:-}" ]]; then
  SSH_PORT=$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}')

  if is_valid_port "$SSH_PORT"; then
    $SUDO ufw allow "$SSH_PORT/tcp" || true
  fi
fi

$SUDO ufw --force enable
$SUDO ufw reload

$SUDO systemctl daemon-reload
$SUDO systemctl enable 3proxy
$SUDO systemctl restart 3proxy

SERVER_IP=$(curl -fsS --connect-timeout 10 --noproxy '*' https://api.ipify.org || echo "YOUR_SERVER_IP")

echo
echo "Installation completed."
echo
echo "HTTP:"
echo "${SERVER_IP}:${HTTP_PORT}:${PROXY_USER}:${PROXY_PASS}:http"
echo
echo "HTTPS via HTTP CONNECT:"
echo "${SERVER_IP}:${HTTP_PORT}:${PROXY_USER}:${PROXY_PASS}:https"
echo
echo "SOCKS5:"
echo "${SERVER_IP}:${SOCKS_PORT}:${PROXY_USER}:${PROXY_PASS}:socks5"
echo

if [[ "$USE_PARENT" == "yes" ]]; then
  echo "Parent proxy chain is enabled:"
  echo "Type: $PARENT_TYPE"
  echo "3proxy parent type: $PARENT_KIND"
  echo "Address: $PARENT_HOST:$PARENT_PORT"

  if [[ -n "$PARENT_USER" ]]; then
    echo "Parent auth: $PARENT_USER/********"
  else
    echo "Parent auth: none"
  fi

  echo
fi

echo "Check service:"
echo "sudo systemctl status 3proxy --no-pager"
echo
echo "Test HTTP:"
echo "curl -x http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${HTTP_PORT} https://api.ipify.org"
echo
echo "Test SOCKS5:"
echo "curl -x socks5h://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${SOCKS_PORT} https://api.ipify.org"
