#!/bin/bash
# Отключение L2TP-туннеля. Запуск: sudo ./l2tp-disconnect.sh

if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root. Запусти: sudo $0"
    exit 1
fi

PIDFILE=/var/run/l2tp-office.pid
if [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill -TERM "$(cat "$PIDFILE")"
    rm -f "$PIDFILE"
    echo "Туннель отключён."
    exit 0
fi

if ! pgrep -x pppd >/dev/null; then
    echo "pppd не запущен, туннеля нет."
    exit 0
fi

pkill -TERM -x pppd
sleep 2
if pgrep -x pppd >/dev/null; then
    pkill -KILL -x pppd
fi
echo "Туннель отключён."
