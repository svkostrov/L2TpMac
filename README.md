# L2TP-клиент для macOS (без IPsec)

Подключение к серверу `213.79.84.225` (Office) — аналог интерфейса `L2TP0` на Keenetic.

## Почему не штатный клиент macOS

В Системных настройках macOS есть только **L2TP over IPsec** (требует shared secret). В конфиге роутера IPsec нет (`security-level public`), это чистый L2TP — поэтому используется нативный `pppd` с плагином `L2TP.ppp` и опцией `l2tpnoipsec`.

## Использование

```bash
chmod +x l2tp-connect.sh l2tp-disconnect.sh   # один раз
sudo ./l2tp-connect.sh      # подключить
sudo ./l2tp-disconnect.sh   # отключить
ifconfig ppp0               # статус
```

Лог: `/tmp/l2tp-office.log` (pppd запущен с `debug`, там весь LCP/IPCP-обмен — удобно для отладки).

## Соответствие опций Keenetic → pppd

| Keenetic | pppd |
|---|---|
| `peer 213.79.84.225` | `remoteaddress` |
| `authentication identity/password` | `user` / `password` |
| `lcp echo 30 3` | `lcp-echo-interval 30`, `lcp-echo-failure 3` |
| `no ccp` | `noccp` |
| `ipcp default-route` | `defaultroute` |
| `ipcp dns-routes`, `ip dhcp client dns-routes` | `usepeerdns` |
| `ip mtu 1400` | `mtu 1400`, `mru 1400` |
| `ip tcp adjust-mss pmtu` | прямого аналога нет; MTU 1400 обычно достаточно |
| `no ipv6cp` | pppd macOS IPv6CP по умолчанию не поднимает |

## Важно: баг macOS 26 и `nodetach`

На macOS 26 pppd **падает (EXC_GUARD, mach port)** при демонизации: L2TP-плагин создаёт CFRunLoop/mach-порты, которые не переживают fork. Симптом: лог обрывается на «Flagging up», в `~/Library/Logs/DiagnosticReports` появляются `pppd-*.ips`. Поэтому в скрипте pppd запускается с `nodetach`, а в фон уходит средствами шелла (PID хранится в `/var/run/l2tp-office.pid`).

Сервер в данном случае — Cisco ISR4331, аутентификация CHAP (MD5), выданная сеть 10.10.10.0/24.

## GUI: L2TP Office.app

Нативное SwiftUI-приложение (окно + иконка в menu bar). Исходник — `L2TPOfficeApp/main.swift`, пересборка:

```bash
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
  L2TPOfficeApp/main.swift -o "L2TP Office.app/Contents/MacOS/L2TPOffice"
codesign --force -s - "L2TP Office.app"
```

Возможности: ввод сервера/логина/пароля в UI (сервер и логин — UserDefaults, пароль — Keychain, всё переживает перезапуск); выбор маршрутизации — весь трафик (`defaultroute` + DNS от сервера) или только указанные CIDR-сети; автозапуск при входе в систему (login item) и автоподключение при старте; живой лог pppd (`/tmp/l2tp-office-app.log`). Права root приложение получает через штатный системный диалог — пароль sudo в нём не хранится.

Передача другому человеку: скопировать `L2TP Office.app` (AirDrop/флешка). Подпись ad-hoc, поэтому при первом запуске на чужом Mac: ПКМ по приложению → «Открыть» → «Открыть» (или `xattr -cr "L2TP Office.app"`). Работает только на Apple Silicon (arm64); человек вводит свои логин/пароль в окне приложения.

## Замечания

- `defaultroute` заворачивает весь трафик в туннель. Для split tunnel убери эту строку и добавляй маршруты вручную: `sudo route add -net 192.168.x.0/24 -interface ppp0`.
- Пароль хранится в скрипте открытым текстом — не коммить в общий репозиторий.
- Если подключение падает сразу — смотри `/tmp/l2tp-office.log`: `CHAP authentication failed` = логин/пароль, отсутствие ответа на SCCRQ = сервер недоступен/порт UDP 1701 закрыт.
- Альтернатива для GUI: файл `/etc/ppp/options` со строками `plugin L2TP.ppp` и `l2tpnoipsec` заставляет штатное VPN-подключение работать без IPsec (действует на все L2TP-подключения системы).
