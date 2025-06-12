#!/bin/bash

set -e

# === Настройки ===
XRAY_PATH="/usr/local/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_SERVICE="/etc/systemd/system/xray.service"
PORT=443
MASK_DOMAIN="www.google.com"
ALPN="h2"
FLOW="xtls-rprx-vision"
QR_PATH="/tmp/vless_qr.png"

# Получение публичного IP-адреса сервера (используем ifconfig.me)
get_public_ip() {
    curl -s https://ifconfig.me
}

# Установка необходимых зависимостей
install_dependencies() {
    apt update
    apt install -y curl wget jq qrencode socat unzip
}

# Установка Xray-core, если он ещё не установлен
install_xray() {
    if [ ! -f "$XRAY_PATH" ]; then
        wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
        unzip /tmp/xray.zip -d /tmp/xray
        install -m 755 /tmp/xray/xray "$XRAY_PATH"
        mkdir -p /etc/xray
        rm -rf /tmp/xray /tmp/xray.zip
    fi
}

# Генерация ключей для Reality (x25519), если их ещё нет
generate_keys() {
    if [ ! -f /etc/xray/private.key ] || [ ! -f /etc/xray/public.key ]; then
        "$XRAY_PATH" x25519 > /tmp/keys.txt
        PRIVATE_KEY=$(grep 'Private' /tmp/keys.txt | awk '{print $3}')
        PUBLIC_KEY=$(grep 'Public' /tmp/keys.txt | awk '{print $3}')
        echo "$PRIVATE_KEY" > /etc/xray/private.key
        echo "$PUBLIC_KEY" > /etc/xray/public.key
        rm /tmp/keys.txt
    fi
}

# Создание нового базового конфига Xray (только с 1 пользователем)
create_config() {
    UUID="$1"
    PRIVATE_KEY=$(cat /etc/xray/private.key)
    SHORT_ID=$(openssl rand -hex 8)
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": "$UUID",
          "flow": "$FLOW"
        }
      ],
      "decryption": "none",
      "fallbacks": []
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$MASK_DOMAIN:443",
        "xver": 0,
        "serverNames": ["$MASK_DOMAIN"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"],
        "maxClient": 8
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
}

# Добавление нового пользователя (UUID) в clients в конфиге
add_user() {
    UUID="$1"
    jq --arg uuid "$UUID" \
       --arg flow "$FLOW" \
       '.inbounds[0].settings.clients += [{"id":$uuid,"flow":$flow}]' "$XRAY_CONFIG" > /tmp/config_new.json
    mv /tmp/config_new.json "$XRAY_CONFIG"
}

# Перезапуск службы Xray
restart_xray() {
    mkdir -p /var/log/xray
    chown nobody:nogroup /var/log/xray 2>/dev/null || chown root:root /var/log/xray
    chmod 755 /var/log/xray

    systemctl daemon-reload
    systemctl restart xray
}

# Создание systemd-сервиса для автозапуска Xray при загрузке сервера
setup_service() {
    if [ ! -f "$XRAY_SERVICE" ]; then
        cat > "$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=$XRAY_PATH run -c $XRAY_CONFIG
Restart=on-failure
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable xray
    fi
}

# Генерация VLESS-ссылки для клиента (с параметрами Reality)
generate_vless_link() {
    UUID="$1"
    PUBLIC_KEY=$(cat /etc/xray/public.key)
    SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
    SERVER_IP=$(get_public_ip)
    VLESS_LINK="vless://$UUID@$SERVER_IP:$PORT?encryption=none&security=reality&type=tcp&flow=$FLOW&sni=$MASK_DOMAIN&fp=chrome&alpn=$ALPN&pbk=$PUBLIC_KEY&sid=$SHORT_ID#VLESS-Reality"
    echo "$VLESS_LINK"
}

# Генерация QR-кода по ссылке VLESS
generate_qr() {
    qrencode -o "$QR_PATH" "$VLESS_LINK"
    echo "QR-код сохранён в $QR_PATH"
    echo
    echo "QR-код для подключения (можно сканировать прямо с экрана):"
    echo "$VLESS_LINK" | qrencode -t ANSIUTF8
    echo
}

# Главная функция (точка входа)
main() {
    install_dependencies
    install_xray
    generate_keys
    setup_service

    if [ ! -f "$XRAY_CONFIG" ]; then
        echo "Первый запуск. Создаю конфиг..."
        UUID=$(cat /proc/sys/kernel/random/uuid)
        create_config "$UUID"
        restart_xray
        VLESS_LINK=$(generate_vless_link "$UUID")
        echo "Ссылка для подключения:"
        echo "$VLESS_LINK"
        generate_qr "$VLESS_LINK"
    else
        echo "Добавление нового пользователя..."
        UUID=$(cat /proc/sys/kernel/random/uuid)
        add_user "$UUID"
        restart_xray
        VLESS_LINK=$(generate_vless_link "$UUID")
        echo "Ссылка для подключения:"
        echo "$VLESS_LINK"
        generate_qr "$VLESS_LINK"
    fi
}

main
