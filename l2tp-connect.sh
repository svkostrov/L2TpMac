#!/bin/bash
# Подключение к L2TP-серверу (без IPsec) через нативный pppd macOS.
# Аналог Keenetic-конфига "interface L2TP0 / description Office".
# Запуск: sudo ./l2tp-connect.sh

SERVER="213.79.84.225"
VPN_USER="svkostrov"
VPN_PASS="ieH9yeingichua"
LOG="$(cd "$(dirname "$0")" && pwd)/l2tp-office.log"
TIMEOUT=25

if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root. Запусти: sudo $0"
    exit 1
fi

if /sbin/ifconfig ppp0 2>/dev/null | grep -q 'inet '; then
    echo "Туннель уже поднят:"
    /sbin/ifconfig ppp0 | grep 'inet '
    exit 0
fi

: > "$LOG"

# nodetach обязателен: на macOS 26 pppd при демонизации (fork) падает
# с EXC_GUARD в CFRunLoop L2TP-плагина. Поэтому фоним средствами шелла.
/usr/sbin/pppd \
    nodetach \
    plugin L2TP.ppp \
    l2tpnoipsec \
    remoteaddress "$SERVER" \
    user "$VPN_USER" \
    password "$VPN_PASS" \
    noauth \
    noccp \
    mtu 1400 \
    mru 1400 \
    lcp-echo-interval 30 \
    lcp-echo-failure 3 \
    defaultroute \
    usepeerdns \
    debug \
    logfile "$LOG" \
    >/dev/null 2>&1 &
PPPD_PID=$!
echo "$PPPD_PID" > /var/run/l2tp-office.pid

# no ccp            -> noccp
# lcp echo 30 3     -> lcp-echo-interval 30, lcp-echo-failure 3
# ipcp default-route -> defaultroute (убери строку, если нужен split tunnel)
# ipcp dns-routes / dhcp dns-routes -> usepeerdns
# ip mtu 1400       -> mtu/mru 1400

echo "Подключаюсь к $SERVER (pppd pid $PPPD_PID, лог: $LOG)..."
for ((i = 0; i < TIMEOUT; i++)); do
    sleep 1
    if ! kill -0 "$PPPD_PID" 2>/dev/null; then
        echo "ОШИБКА: pppd завершился. Последние строки лога:"
        tail -n 25 "$LOG"
        exit 1
    fi
    IP=$(/sbin/ifconfig ppp0 2>/dev/null | awk '/inet /{print $2}')
    if [[ -n "$IP" ]]; then
        echo "OK: ppp0 поднят, IP $IP"
        /sbin/ifconfig ppp0 | grep 'inet '
        exit 0
    fi
done

echo "ОШИБКА: туннель не поднялся за ${TIMEOUT} с. Последние строки лога:"
tail -n 25 "$LOG"
exit 1
