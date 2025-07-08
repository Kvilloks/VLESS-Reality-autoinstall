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

# Определение основного сетевого интерфейса
detect_main_interface() {
    # Получаем интерфейс по умолчанию из таблицы маршрутизации
    ip route show default | awk '{print $5}' | head -n1
}

# Определение используемого сетевого менеджера
detect_network_manager() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "NetworkManager"
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "systemd-networkd"
    elif [ -d /etc/netplan ] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
        echo "netplan"
    elif [ -f /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg ] || [ -f /var/lib/cloud/instance/network-config ]; then
        echo "cloud-init"
    else
        echo "unknown"
    fi
}

# Настройка MTU для оптимизации сети
configure_mtu() {
    echo "🔧 Настройка MTU для оптимизации сети..."
    
    local main_interface
    main_interface=$(detect_main_interface)
    
    if [ -z "$main_interface" ]; then
        echo "⚠️  Не удалось определить основной сетевой интерфейс"
        echo "ℹ️  Рекомендуется вручную установить MTU 1400 для интерфейса"
        return 1
    fi
    
    echo "📡 Основной интерфейс: $main_interface"
    
    local network_manager
    network_manager=$(detect_network_manager)
    echo "🔍 Обнаружен сетевой менеджер: $network_manager"
    
    # Безопасное значение MTU для Reality
    local safe_mtu=1400
    
    case "$network_manager" in
        "NetworkManager")
            echo "📝 Настройка MTU через NetworkManager..."
            if command -v nmcli >/dev/null 2>&1; then
                nmcli connection modify "$(nmcli -t -f NAME,DEVICE connection show --active | grep "$main_interface" | cut -d: -f1)" ethernet.mtu "$safe_mtu" 2>/dev/null || {
                    echo "⚠️  Не удалось автоматически настроить MTU через NetworkManager"
                    echo "ℹ️  Выполните вручную: nmcli connection modify <connection-name> ethernet.mtu $safe_mtu"
                    return 1
                }
                echo "✅ MTU установлен в $safe_mtu через NetworkManager"
            else
                echo "⚠️  nmcli не найден, автоматическая настройка невозможна"
                return 1
            fi
            ;;
        "systemd-networkd")
            echo "📝 Настройка MTU через systemd-networkd..."
            local network_file="/etc/systemd/network/50-$main_interface.network"
            if [ -f "$network_file" ]; then
                if ! grep -q "MTU=" "$network_file"; then
                    sed -i '/\[Link\]/a MTU='$safe_mtu "$network_file" 2>/dev/null || {
                        echo "⚠️  Не удалось автоматически настроить MTU"
                        echo "ℹ️  Добавьте в файл $network_file в секцию [Link]: MTU=$safe_mtu"
                        return 1
                    }
                    echo "✅ MTU установлен в $safe_mtu в $network_file"
                    systemctl restart systemd-networkd
                else
                    echo "ℹ️  MTU уже настроен в $network_file"
                fi
            else
                echo "⚠️  Файл конфигурации $network_file не найден"
                echo "ℹ️  Создайте файл с настройкой MTU=$safe_mtu в секции [Link]"
                return 1
            fi
            ;;
        "netplan")
            echo "📝 Настройка MTU через netplan..."
            echo "⚠️  Автоматическая настройка MTU через netplan требует ручного вмешательства"
            echo "ℹ️  Добавьте в ваш файл /etc/netplan/*.yaml:"
            echo "      $main_interface:"
            echo "        mtu: $safe_mtu"
            echo "ℹ️  Затем выполните: sudo netplan apply"
            return 1
            ;;
        "cloud-init")
            echo "📝 Обнаружен cloud-init..."
            echo "⚠️  Настройка MTU в cloud-init окружении может быть перезаписана"
            echo "ℹ️  Рекомендуется настроить MTU=$safe_mtu через панель управления провайдера"
            echo "ℹ️  Или добавить в cloud-init конфигурацию"
            return 1
            ;;
        *)
            echo "⚠️  Неизвестный сетевой менеджер"
            echo "ℹ️  Попытка прямой настройки через ip команду..."
            if command -v ip >/dev/null 2>&1; then
                if ip link set dev "$main_interface" mtu "$safe_mtu" 2>/dev/null; then
                    echo "✅ MTU временно установлен в $safe_mtu"
                    echo "⚠️  Настройка временная, добавьте постоянную настройку в сетевой конфиг"
                else
                    echo "⚠️  Не удалось установить MTU"
                    echo "ℹ️  Выполните вручную: ip link set dev $main_interface mtu $safe_mtu"
                    return 1
                fi
            else
                echo "⚠️  Команда ip не найдена, автоматическая настройка невозможна"
                return 1
            fi
            ;;
    esac
    
    return 0
}

# Проверка существования UUID в конфигурации
check_uuid_exists() {
    local uuid="$1"
    if [ -f "$XRAY_CONFIG" ]; then
        jq -e --arg uuid "$uuid" '.inbounds[0].settings.clients[] | select(.id == $uuid)' "$XRAY_CONFIG" >/dev/null 2>&1
    else
        return 1
    fi
}

# Установка необходимых зависимостей
install_dependencies() {
    echo "📦 Установка необходимых зависимостей..."
    echo "🔄 Обновление списка пакетов..."
    apt update
    echo "⬇️  Установка пакетов: curl, wget, jq, qrencode, socat, unzip..."
    apt install -y curl wget jq qrencode socat unzip
    echo "✅ Зависимости успешно установлены"
}

# Установка Xray-core, если он ещё не установлен
install_xray() {
    if [ ! -f "$XRAY_PATH" ]; then
        echo "⬇️  Скачивание Xray-core с GitHub..."
        wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
        echo "📂 Распаковка архива Xray..."
        unzip /tmp/xray.zip -d /tmp/xray
        echo "📁 Установка исполняемого файла Xray..."
        install -m 755 /tmp/xray/xray "$XRAY_PATH"
        mkdir -p /etc/xray
        rm -rf /tmp/xray /tmp/xray.zip
        echo "✅ Xray-core успешно установлен"
    else
        echo "ℹ️  Xray-core уже установлен, пропускаем"
    fi
}

# Генерация ключей для Reality (x25519), если их ещё нет
generate_keys() {
    if [ ! -f /etc/xray/private.key ] || [ ! -f /etc/xray/public.key ]; then
        echo "🔐 Генерация ключей Reality (x25519)..."
        "$XRAY_PATH" x25519 > /tmp/keys.txt
        PRIVATE_KEY=$(grep 'Private' /tmp/keys.txt | awk '{print $3}')
        PUBLIC_KEY=$(grep 'Public' /tmp/keys.txt | awk '{print $3}')
        echo "💾 Сохранение приватного ключа..."
        echo "$PRIVATE_KEY" > /etc/xray/private.key
        echo "💾 Сохранение публичного ключа..."
        echo "$PUBLIC_KEY" > /etc/xray/public.key
        rm /tmp/keys.txt
        echo "✅ Ключи Reality успешно сгенерированы"
    else
        echo "ℹ️  Ключи Reality уже существуют, пропускаем генерацию"
    fi
}

# Создание нового базового конфига Xray (только с 1 пользователем)
create_config() {
    UUID="$1"
    echo "📝 Создание конфигурации Xray с UUID: $UUID"
    PRIVATE_KEY=$(cat /etc/xray/private.key)
    SHORT_ID=$(openssl rand -hex 8)
    echo "🔢 Сгенерирован Short ID: $SHORT_ID"
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
    echo "✅ Конфигурация Xray успешно создана"
}

# Добавление нового пользователя (UUID) в clients в конфиге
add_user() {
    UUID="$1"
    echo "👤 Добавление нового пользователя с UUID: $UUID"
    
    # Проверка на существование UUID
    if check_uuid_exists "$UUID"; then
        echo "⚠️  UUID $UUID уже существует в конфигурации!"
        echo "🔄 Генерируем новый UUID..."
        UUID=$(cat /proc/sys/kernel/random/uuid)
        echo "🆕 Новый UUID: $UUID"
        
        # Повторная проверка (маловероятно, но для надёжности)
        while check_uuid_exists "$UUID"; do
            echo "🔄 UUID конфликт, генерируем ещё раз..."
            UUID=$(cat /proc/sys/kernel/random/uuid)
            echo "🆕 Новый UUID: $UUID"
        done
    fi
    
    echo "📝 Добавление UUID в конфигурацию..."
    jq --arg uuid "$UUID" \
       --arg flow "$FLOW" \
       '.inbounds[0].settings.clients += [{"id":$uuid,"flow":$flow}]' "$XRAY_CONFIG" > /tmp/config_new.json
    mv /tmp/config_new.json "$XRAY_CONFIG"
    echo "✅ Пользователь успешно добавлен"
    
    # Возвращаем финальный UUID для использования в main
    echo "$UUID"
}

# Перезапуск службы Xray
restart_xray() {
    echo "🔄 Перезапуск службы Xray..."
    echo "📁 Создание директории для логов..."
    mkdir -p /var/log/xray
    chown nobody:nogroup /var/log/xray 2>/dev/null || chown root:root /var/log/xray
    chmod 755 /var/log/xray

    echo "🔄 Перезагрузка конфигурации systemd..."
    systemctl daemon-reload
    echo "🚀 Перезапуск службы Xray..."
    systemctl restart xray
    echo "✅ Служба Xray успешно перезапущена"
}

# Создание systemd-сервиса для автозапуска Xray при загрузке сервера
setup_service() {
    if [ ! -f "$XRAY_SERVICE" ]; then
        echo "⚙️  Создание systemd сервиса для Xray..."
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
        echo "🔧 Включение автозапуска службы..."
        systemctl enable xray
        echo "✅ Systemd сервис успешно создан и включён"
    else
        echo "ℹ️  Systemd сервис уже существует, пропускаем"
    fi
}

# Генерация VLESS-ссылки для клиента (с параметрами Reality)
generate_vless_link() {
    UUID="$1"
    echo "🔗 Генерация VLESS-ссылки для подключения..."
    PUBLIC_KEY=$(cat /etc/xray/public.key)
    SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
    echo "🌐 Получение публичного IP-адреса сервера..."
    SERVER_IP=$(get_public_ip)
    echo "📡 IP-адрес сервера: $SERVER_IP"
    VLESS_LINK="vless://$UUID@$SERVER_IP:$PORT?encryption=none&security=reality&type=tcp&flow=$FLOW&sni=$MASK_DOMAIN&fp=chrome&alpn=$ALPN&pbk=$PUBLIC_KEY&sid=$SHORT_ID#VLESS-Reality"
    echo "✅ VLESS-ссылка успешно сгенерирована"
    echo "$VLESS_LINK"
}

# Генерация QR-кода по ссылке VLESS
generate_qr() {
    echo "📱 Генерация QR-кода для подключения..."
    qrencode -o "$QR_PATH" "$VLESS_LINK"
    echo "💾 QR-код сохранён в $QR_PATH"
    echo
    echo "📱 QR-код для подключения (можно сканировать прямо с экрана):"
    echo "$VLESS_LINK" | qrencode -t ANSIUTF8
    echo
}

# Главная функция (точка входа)
main() {
    echo "🚀 Запуск автоматической установки VLESS Reality..."
    echo "=================================================="
    
    install_dependencies
    install_xray
    generate_keys
    setup_service
    
    # Настройка MTU
    configure_mtu || echo "⚠️  Настройка MTU пропущена, продолжаем установку..."

    if [ ! -f "$XRAY_CONFIG" ]; then
        echo ""
        echo "🎉 Первый запуск. Создаю конфиг..."
        UUID=$(cat /proc/sys/kernel/random/uuid)
        create_config "$UUID"
        restart_xray
        echo ""
        echo "🔗 Генерация ссылки для подключения..."
        VLESS_LINK=$(generate_vless_link "$UUID")
        echo ""
        echo "🎯 Ссылка для подключения:"
        echo "$VLESS_LINK"
        echo ""
        generate_qr "$VLESS_LINK"
        echo "🎉 Установка завершена успешно!"
    else
        echo ""
        echo "👤 Добавление нового пользователя..."
        UUID=$(cat /proc/sys/kernel/random/uuid)
        FINAL_UUID=$(add_user "$UUID")
        restart_xray
        echo ""
        echo "🔗 Генерация ссылки для подключения..."
        VLESS_LINK=$(generate_vless_link "$FINAL_UUID")
        echo ""
        echo "🎯 Ссылка для подключения:"
        echo "$VLESS_LINK"
        echo ""
        generate_qr "$VLESS_LINK"
        echo "🎉 Новый пользователь успешно добавлен!"
    fi
    
    echo ""
    echo "=================================================="
    echo "✅ Процесс завершён успешно!"
}

main
