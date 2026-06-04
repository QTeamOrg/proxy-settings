#!/bin/bash
set -euo pipefail

# ===== helpers =====
prompt_default() {
  local prompt="$1" default="$2" var
  read -p "$prompt" var || true
  echo "${var:-$default}"
}

prompt_secret() {
  local prompt="$1" var
  read -s -p "$prompt" var || true
  echo
  echo "$var"
}

# ===== 1) базовые параметры =====
read -p "Укажите имя пользователя: " PROXY_USER
PROXY_PASS=$(prompt_secret "Укажите пароль пользователя: ")
HTTP_PORT=$(prompt_default "Укажите порт для HTTP/HTTPS (по умолчанию 3128): " "3128")
SOCKS_PORT=$(prompt_default "Укажите порт для SOCKS (по умолчанию 1080): " "1080")

# ===== 2) цепочка (родительский прокси) =====
#echo
#read -p "Подключаться ли с другого прокси? (y/N): " USE_PARENT_CHOICE
#USE_PARENT_CHOICE=${USE_PARENT_CHOICE,,}  # lower

USE_PARENT_CHOICE="no"
USE_PARENT="no"
PARENT_BLOCK=""
if [[ "$USE_PARENT_CHOICE" == "y" || "$USE_PARENT_CHOICE" == "yes" ]]; then
  USE_PARENT="yes"
  echo "Типы: http, https (через CONNECT), socks5, socks4"
  read -p "Тип родительского прокси [http/https/socks5/socks4] (по умолчанию http): " PARENT_TYPE
  PARENT_TYPE=${PARENT_TYPE:-http}
  PARENT_TYPE=${PARENT_TYPE,,}

  read -p "Хост/IP родительского прокси: " PARENT_HOST
  read -p "Порт родительского прокси: " PARENT_PORT
  read -p "Логин к родительскому прокси (оставьте пустым, если нет): " PARENT_USER
  if [[ -n "$PARENT_USER" ]]; then
    PARENT_PASS=$(prompt_secret "Пароль к родительскому прокси: ")
  else
    PARENT_PASS=""
  fi

  # 3proxy: parent <type> <maxfails> <host> <port> [user pass]
  # maxfails=1 и trick 'deny direct' через proxyonly: используем таблицу родителя и запрещаем прямой выход
  # Реализуем запрет «прямого» выхода с помощью ACL: всё, что не прошло через parent — запрещаем.
  # Для 3proxy достаточно определить parent до сервисов — запросы пойдут через родителя.
  # Для "https" используем тип http (CONNECT идет через http-прокси).
  case "$PARENT_TYPE" in
    https) PARENT_KIND="http" ;;
    http|socks5|socks4) PARENT_KIND="$PARENT_TYPE" ;;
    *) echo "Неверный тип '$PARENT_TYPE'. Допустимо: http/https/socks5/socks4"; exit 1 ;;
  esac

  if [[ -n "$PARENT_USER" ]]; then
    PARENT_BLOCK="parent $PARENT_KIND 1 $PARENT_HOST $PARENT_PORT $PARENT_USER $PARENT_PASS
"
  else
    PARENT_BLOCK="parent $PARENT_KIND 1 $PARENT_HOST $PARENT_PORT
"
  fi

  # Чтобы гарантированно не было «прямого» выхода при падении родителя, добавим запрещающее правило via parent ACL:
  # Используем internal ACL «!parent» запрещая прямые коннекты. В 3proxy это достигается правилом 'parent' + deny all после сервисов.
  # Мы решим это проще: включим 'parent' и добавим 'deny * *' как fallback если родитель недоступен (см. ниже).
fi

# ===== 3) установка =====
sudo apt update && sudo apt install -y git build-essential ufw curl libssl-dev

if [[ ! -d 3proxy ]]; then
  git clone https://github.com/z3APA3A/3proxy.git
fi
cd 3proxy
make -f Makefile.Linux

# бинарь
sudo mkdir -p /etc/3proxy/logs
sudo cp ./bin/3proxy /usr/local/bin/

# ===== 4) конфиг 3proxy =====
# Базовый конфиг + users + сервисы; если USE_PARENT=yes — вставим блок parent и запретим прямой выход.
CFG="/etc/3proxy/3proxy.cfg"

# Формируем список nserver: локальные резолверы можно заменить при желании
DNS1="8.8.8.8"
DNS2="1.1.1.1"

# Логи в дате/времени по одному файлу (D = daily)
read -r -d '' BASE_CFG <<EOF || true
nserver $DNS1
nserver $DNS2
nscache 65536
timeouts 1 5 30 60 180 1800 15 60

# Логирование
log /etc/3proxy/logs/3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%c %R:%r %O %I %h %T"

# Аутентификация
auth strong
users $PROXY_USER:CL:$PROXY_PASS
allow $PROXY_USER

EOF

# Если используем родителя — добавим блок parent (до сервисов)
if [[ "$USE_PARENT" == "yes" ]]; then
  BASE_CFG+="$PARENT_BLOCK"
  # Чтобы не было прямого выхода, используем строгую схему:
  # - Сразу после сервисов ставим 'deny * *' если родитель не сработает.
  # На практике 3proxy не пойдет напрямую при наличии parent.
  DENY_DIRECT='deny * *'
else
  DENY_DIRECT=''
fi

# Сервисы
read -r -d '' SRV_CFG <<EOF || true
# SOCKS5
socks -p$SOCKS_PORT

# HTTP/HTTPS прокси
proxy -p$HTTP_PORT

$DENY_DIRECT
EOF

# Пишем конфиг
sudo tee "$CFG" > /dev/null <<< "${BASE_CFG}${SRV_CFG}"

# ===== 5) systemd =====
sudo tee /etc/systemd/system/3proxy.service > /dev/null <<'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=2

# Можно добавить PrivateTmp=true и User/Group если заведёте отдельного пользователя

[Install]
WantedBy=multi-user.target
EOF

# ===== 6) UFW =====
sudo ufw allow ${SOCKS_PORT}/tcp
sudo ufw allow ${HTTP_PORT}/tcp
sudo ufw allow 'OpenSSH'
sudo ufw --force enable
sudo ufw reload

# ===== 7) запуск =====
sudo systemctl daemon-reexec
sudo systemctl enable 3proxy
sudo systemctl restart 3proxy

# ===== 8) вывод =====
SERVER_IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")

echo
echo "✓ Установка завершена. Данные прокси:"
echo
echo "HTTP:"
echo "${SERVER_IP}:${HTTP_PORT}:${PROXY_USER}:${PROXY_PASS}:http"
echo
echo "HTTPS:"
echo "${SERVER_IP}:${HTTP_PORT}:${PROXY_USER}:${PROXY_PASS}:https"
echo
echo "SOCKS5:"
echo "${SERVER_IP}:${SOCKS_PORT}:${PROXY_USER}:${PROXY_PASS}:socks5"
echo

if [[ "$USE_PARENT" == "yes" ]]; then
  echo "Цепочка активна. Все запросы проходят через родительский прокси:"
  echo "- Тип: ${PARENT_TYPE}"
  echo "- Адрес: ${PARENT_HOST}:${PARENT_PORT}"
  if [[ -n "$PARENT_USER" ]]; then
    echo "- Аутентификация к родителю: ${PARENT_USER}/********"
  else
    echo "- Аутентификация к родителю: нет"
  fi
fi
