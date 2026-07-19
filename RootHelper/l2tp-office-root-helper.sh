#!/bin/bash
set -u

LOG="/tmp/l2tp-office-app.log"
PIDF="/var/run/l2tp-office-app.pid"
OPTS="/etc/ppp/l2tp-office-app.opts"
APP_HELPER="/Applications/L2TP Office.app/Contents/MacOS/l2tp-office-helper"
PPP_MTU="1200"
ROOT_HELPER_VERSION="1.68"

die() {
  echo "$1"
  exit 0
}

decode_key() {
  /usr/bin/awk -F= -v k="$1" '$1 == k {print substr($0, length(k) + 2); exit}' "$REQ" | /usr/bin/base64 -D 2>/dev/null
}

ppp_escape() {
  /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | /usr/bin/tr -d '\r\n'
}

valid_host() {
  local host="$1" label
  [[ "$host" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || return 1
  [[ "$host" != .* && "$host" != *. && "$host" != -* && "$host" != *- ]] || return 1
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ -n "$label" ] || return 1
    [[ "$label" != -* && "$label" != *- ]] || return 1
  done
  return 0
}

valid_cidr() {
  local cidr="$1" ip prefix
  ip="${cidr%/*}"
  if [[ "$cidr" == */* ]]; then
    prefix="${cidr##*/}"
  else
    prefix="32"
  fi
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
  return 0
}

valid_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<< "$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
  return 0
}

cleanup_ppp_state() {
  if /sbin/ifconfig ppp0 >/dev/null 2>&1; then
    return 0
  fi
  for K in $(printf 'list State:/Network/Service/[^/]+/IPv4\nlist State:/Network/Service/[^/]+/DNS\nlist State:/Network/Service/[^/]+/PPP\nquit\n' | /usr/sbin/scutil | /usr/bin/awk '{print $NF}'); do
    if printf 'show %s\nquit\n' "$K" | /usr/sbin/scutil | /usr/bin/grep -q 'InterfaceName : ppp0'; then
      printf 'remove %s\nquit\n' "$K" | /usr/sbin/scutil >/dev/null 2>&1 || true
    fi
  done
}

active_en_interfaces() {
  for IF in $(/sbin/ifconfig -lu); do
    case "$IF" in en*) ;; *) continue ;; esac
    /sbin/ifconfig "$IF" 2>/dev/null | /usr/bin/grep -q 'status: active' || continue
    /sbin/ifconfig "$IF" 2>/dev/null | /usr/bin/grep -q 'inet ' || continue
    printf '%s\n' "$IF"
  done
}

default_route_is_en() {
  /sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}' | /usr/bin/grep -q '^en'
}

dns_has_server() {
  /usr/sbin/scutil --dns 2>/dev/null | /usr/bin/grep -q 'nameserver\[[0-9][0-9]*\]'
}

restore_default_route() {
  local ifc gw i
  for i in 1 2 3 4 5 6 7 8; do
    default_route_is_en && return 0
    for ifc in $(active_en_interfaces); do
      gw=$(/usr/sbin/ipconfig getoption "$ifc" router 2>/dev/null)
      [ -n "$gw" ] || continue
      /sbin/route -n delete default >/dev/null 2>&1 || true
      /sbin/route -n add default "$gw" >/dev/null 2>&1 || true
      default_route_is_en && return 0
    done
    sleep 1
  done
  return 1
}

restore_dns() {
  local ifc gw i
  dns_has_server && return 0
  for ifc in $(active_en_interfaces); do
    if /usr/sbin/ipconfig getpacket "$ifc" 2>/dev/null | /usr/bin/grep -q yiaddr; then
      /usr/sbin/ipconfig set "$ifc" DHCP >/dev/null 2>&1 || true
    fi
  done
  for i in 1 2 3 4 5; do
    dns_has_server && return 0
    sleep 1
  done
  for ifc in $(active_en_interfaces); do
    gw=$(/usr/sbin/ipconfig getoption "$ifc" router 2>/dev/null)
    [ -n "$gw" ] || continue
    printf 'd.init\nd.add ServerAddresses * %s\nset State:/Network/Global/DNS\nquit\n' "$gw" | /usr/sbin/scutil >/dev/null 2>&1 || true
    dns_has_server && return 0
  done
  return 1
}

delete_split_routes() {
  local networks="$1" net
  for net in $networks; do
    valid_cidr "$net" || continue
    /sbin/route -n delete -net "$net" >/dev/null 2>&1 || true
  done
}

restore_network() {
  local networks="${1:-}"
  cleanup_ppp_state
  delete_split_routes "$networks"
  for K in State:/Network/Global/DNS State:/Network/Global/IPv4; do
    printf 'remove %s\nquit\n' "$K" | /usr/sbin/scutil >/dev/null 2>&1 || true
  done
  restore_default_route || true
  restore_dns || true
  /usr/bin/dscacheutil -flushcache 2>/dev/null || true
  /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
  restore_default_route || true
}

stop_tunnel_processes() {
  local pids oldpid alive
  pids=$(/usr/bin/pgrep -f "$OPTS" || true)
  oldpid=$(cat "$PIDF" 2>/dev/null || true)
  if [ -n "$oldpid" ]; then
    case "$(ps -p "$oldpid" -o comm= 2>/dev/null)" in
      *pppd) pids="$pids $oldpid" ;;
    esac
  fi
  rm -f "$PIDF"
  if [ -n "$(/bin/echo "$pids" | /usr/bin/tr -d ' ')" ]; then
    for P in $pids; do kill -TERM "$P" 2>/dev/null || true; done
    for i in 1 2 3 4 5; do
      alive=
      for P in $pids; do kill -0 "$P" 2>/dev/null && alive=1; done
      [ -z "$alive" ] && break
      sleep 1
    done
    for P in $pids; do kill -KILL "$P" 2>/dev/null || true; done
  fi
  rm -f "$OPTS"
}

stop_pid_bounded() {
  local pid="$1" i
  kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

disconnect_tunnel() {
  local networks server log_message
  networks="$(decode_key NETWORKS)"
  server="$(decode_key SERVER)"
  log_message="$(decode_key LOG_MESSAGE)"
  if [ -n "$log_message" ]; then
    append_log "$log_message"
  fi
  stop_tunnel_processes
  if [ -n "$server" ]; then
    /sbin/route -n delete -host "$server" >/dev/null 2>&1 || true
  fi
  sleep 1
  restore_network "$networks"
}

clear_log() {
  : > "$LOG"
  chmod 644 "$LOG" 2>/dev/null || true
}

append_log() {
  printf '%s : %s\n' "$(/bin/date '+%a %b %d %H:%M:%S %Y')" "$1" >> "$LOG" 2>/dev/null || true
}

ensure_server_route() {
  local server="$1" info gw iface i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    # Важно: сначала убираем наш старый host-route, иначе route get покажет не
    # текущий системный путь, а зафиксированный предыдущим запуском маршрут.
    /sbin/route -n delete -host "$server" >/dev/null 2>&1 || true

    info=$(/sbin/route -n get "$server" 2>/dev/null || true)
    gw=$(printf '%s\n' "$info" | /usr/bin/awk '/gateway:/{print $2; exit}')
    iface=$(printf '%s\n' "$info" | /usr/bin/awk '/interface:/{print $2; exit}')

    # Пинним транспорт L2TP к тому же пути, который macOS выбрала бы сейчас сама:
    # en0/Wi‑Fi, Ethernet, Amnezia/WireGuard utun или любой другой default-туннель.
    if [ -n "$gw" ] && valid_ipv4 "$gw"; then
      /sbin/route -n add -host "$server" "$gw" >/dev/null 2>&1 || \
      /sbin/route -n change -host "$server" "$gw" >/dev/null 2>&1 || true
    elif [ -n "$iface" ]; then
      /sbin/route -n add -host "$server" -interface "$iface" >/dev/null 2>&1 || \
      /sbin/route -n change -host "$server" -interface "$iface" >/dev/null 2>&1 || true
    fi

    info=$(/sbin/route -n get "$server" 2>/dev/null || true)
    if [ -n "$iface" ] && printf '%s\n' "$info" | /usr/bin/grep -q "interface: $iface"; then
      return 0
    fi

    # Fallback для случая, когда SystemConfiguration ещё не успел вернуть route.
    for IF in $(/sbin/ifconfig -lu); do
      case "$IF" in en*) ;; *) continue ;; esac
      /sbin/ifconfig "$IF" 2>/dev/null | /usr/bin/grep -q 'inet ' || continue
      gw=$(/usr/sbin/ipconfig getoption "$IF" router 2>/dev/null)
      [ -n "$gw" ] || continue
      /sbin/route -n add default "$gw" >/dev/null 2>&1 || true
      /sbin/route -n add -host "$server" "$gw" >/dev/null 2>&1 || \
      /sbin/route -n change -host "$server" "$gw" >/dev/null 2>&1 || true
      break
    done
    sleep 1
  done
  return 1
}

connect_tunnel() {
  local server username password networks route_all user_esc pass_esc pid ip peer rterr start_line attempt retry
  trap 'rm -f "$OPTS"' EXIT
  server="$(decode_key SERVER)"
  username="$(decode_key USERNAME)"
  password="$(decode_key PASSWORD)"
  networks="$(decode_key NETWORKS)"
  route_all="$(decode_key ROUTE_ALL)"

  [ "$route_all" = "false" ] || die "FULLTUNNEL-DISABLED"
  valid_host "$server" || die "BAD-SERVER"
  [ -x "$APP_HELPER" ] || die "HELPER-MISSING: $APP_HELPER"

  stop_tunnel_processes >/dev/null 2>&1 || true
  cleanup_ppp_state

  ensure_server_route "$server" || die "NO-SERVER-ROUTE"

  user_esc="$(printf '%s' "$username" | ppp_escape)"
  pass_esc="$(printf '%s' "$password" | ppp_escape)"
  umask 077
  cat > "$OPTS" <<PPPEOF
nodetach
pty "'$APP_HELPER' -server '$server' -log '$LOG'"
user "$user_esc"
password "$pass_esc"
noauth
noipdefault
ipcp-accept-local
ipcp-accept-remote
nodefaultroute
noccp
noacsp
novj
novjccomp
nopcomp
noaccomp
receive-all
asyncmap 0
mtu $PPP_MTU
mru $PPP_MTU
lcp-echo-interval 30
lcp-echo-failure 3
debug
logfile $LOG
PPPEOF
  touch "$LOG" 2>/dev/null || true
  chmod 644 "$LOG" 2>/dev/null || true
  for attempt in 1 2; do
    start_line=$(( $(/usr/bin/wc -l < "$LOG" 2>/dev/null || echo 0) + 1 ))
    /usr/sbin/pppd file "$OPTS" >>"$LOG" 2>&1 &
    pid=$!
    echo "$pid" > "$PIDF"
    rterr=
    retry=
    for i in $(seq 1 25); do
      sleep 1
      if /usr/bin/tail -n +"$start_line" "$LOG" 2>/dev/null | /usr/bin/grep -Fq 'l2tp handshake failed: peer closed control/session during handshake'; then
        stop_pid_bounded "$pid"
        if [ "$attempt" -eq 1 ]; then
          append_log "L2TP Office: L2TP handshake was closed by peer on first attempt; retrying once."
          cleanup_ppp_state
          sleep 2
          retry=1
          break
        fi
        echo "FAILED"
        exit 0
      fi
      if ! kill -0 "$pid" 2>/dev/null; then
        if /usr/bin/tail -n +"$start_line" "$LOG" 2>/dev/null | /usr/bin/grep -qi 'auth.*fail\|CHAP.*fail'; then echo "AUTHFAIL"; else echo "FAILED"; fi
        exit 0
      fi
      ip=$(/sbin/ifconfig ppp0 2>/dev/null | /usr/bin/awk '/inet /{print $2; exit}')
      if [ -n "$ip" ]; then
        sleep 1
        peer=$(/sbin/ifconfig ppp0 2>/dev/null | /usr/bin/awk '/inet /{print $4; exit}')
        for net in $networks; do
          valid_cidr "$net" || { rterr=1; continue; }
          if [ -n "$peer" ]; then
            /sbin/route -n add -net "$net" "$peer" >/dev/null 2>&1 || /sbin/route -n change -net "$net" "$peer" >/dev/null 2>&1 || rterr=1
          else
            /sbin/route -n add -net "$net" -interface ppp0 >/dev/null 2>&1 || rterr=1
          fi
        done
        if [ -n "$rterr" ]; then
          append_log "L2TP Office: tunnel is up, but some routes were not installed. Local IP: $ip, PPP server: ${peer:-unknown}, VPN networks: ${networks:-none}."
        else
          append_log "L2TP Office: tunnel is up. Local IP: $ip, PPP server: ${peer:-unknown}, VPN networks: ${networks:-none}."
        fi
        if [ -n "$rterr" ]; then echo "CONNECTED-ROUTEWARN $ip"; else echo "CONNECTED $ip"; fi
        exit 0
      fi
    done
    [ -n "$retry" ] && continue
    kill "$pid" 2>/dev/null || true
    echo "TIMEOUT"
    exit 0
  done
  echo "FAILED"
}

if [ "${L2TP_ROOT_HELPER_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

REQ="${1:-}"
[ -n "$REQ" ] || die "NO-REQUEST"
[ -f "$REQ" ] || die "REQUEST-NOT-FOUND"
action="$(decode_key ACTION)"
case "$action" in
  version) echo "ROOT-HELPER-VERSION $ROOT_HELPER_VERSION" ;;
  connect) connect_tunnel ;;
  disconnect) disconnect_tunnel; echo "DONE" ;;
  clearlog) clear_log; echo "DONE" ;;
  *) die "BAD-ACTION" ;;
esac
