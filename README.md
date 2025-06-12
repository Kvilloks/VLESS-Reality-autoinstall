# Xray VLESS Reality Автоустановка

Скрипт для автоматической установки и настройки Xray-core с поддержкой VLESS + Reality, генерацией ключей, созданием systemd-сервиса и добавлением новых пользователей.

## Быстрый старт

Скопируйте и выполните следующие команды на вашем сервере (Ubuntu/Debian):

```bash
curl -fsSL https://raw.githubusercontent.com/Kvilloks/xray-vless-reality-autoinstall/main/install-xray-auto.sh -o /tmp/install-xray-auto.sh
dos2unix /tmp/install-xray-auto.sh 2>/dev/null || sed -i 's/\r$//' /tmp/install-xray-auto.sh
chmod +x /tmp/install-xray-auto.sh
bash /tmp/install-xray-auto.sh
```

## Что делает скрипт

- Устанавливает необходимые зависимости: `curl`, `wget`, `jq`, `qrencode`, `socat`, `unzip`
- Скачивает и устанавливает [Xray-core](https://github.com/XTLS/Xray-core)
- Генерирует ключи x25519 для протокола Reality
- Создаёт базовый конфиг для VLESS + Reality с одним пользователем
- Добавляет новых пользователей при повторном запуске скрипта
- Создаёт и активирует systemd-сервис для автозапуска Xray
- Генерирует ссылку формата VLESS и QR-код для удобного подключения

## Как добавить нового пользователя

Каждый повторный запуск скрипта добавляет нового пользователя (UUID) в конфиг, перезапускает Xray и выводит новую ссылку и QR-код.

## Где искать конфиги и ключи

- Бинарник Xray: `/usr/local/bin/xray`
- Конфиг Xray: `/etc/xray/config.json`
- Ключи Reality: `/etc/xray/private.key`, `/etc/xray/public.key`
- QR-код: `/tmp/vless_qr.png`

## Пример ссылки для подключения

```
vless://<UUID>@<SERVER_IP>:443?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.google.com&fp=chrome&alpn=h2&pbk=<PUBLIC_KEY>&sid=<SHORT_ID>#VLESS-Reality
```

## Требования

- Debian/Ubuntu сервер с правами root
- Открыт порт 443 (или другой, если измените в скрипте)

