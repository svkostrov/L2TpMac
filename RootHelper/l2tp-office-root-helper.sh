#!/bin/bash
set -u

LOG="/tmp/l2tp-office-app.log"
PIDF="/var/run/l2tp-office-app.pid"
OPTS="/etc/ppp/l2tp-office-app.opts"
APP_HELPER="/Applications/L2TP Office.app/Contents/MacOS/l2tp-office-helper"
PPP_MTU="1200"

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
  [[ "$1" =~ ^[A-Za-z0-9.-]{1,253}$ ]]
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

cleanup_ppp_state() {
  if ! /sbin/ifconfig ppp0 >/dev/null 2>&1; then
    for K in $(echo 'list State:/Network/Service/[^/]+/IPv4' | /usr/sbin/scutil | /usr/bin/awk '{print $NF}'); do
      if echo "show $K" | /usr/sbin/scutil | /usr/bin/grep -q 'InterfaceName : ppp0'; then
        printf 'remove %s\nquit\n' "$K" | /usr/sbin/scutil >/dev/null 2>&1 || true
      fi
    done
  fi
}

restore_network() {
  cleanup_ppp_state
  for T in 1 2 3 4 5; do
    /sbin/route -n get default 2>/dev/null | /usr/bin/grep -q 'interface: en' && break
    for IF in $(/sbin/ifconfig -lu); do
      case "$IF" in en*) ;; *) continue ;; esac
      /sbin/ifconfig "$IF" 2>/dev/null | /usr/bin/grep -q 'inet ' || continue
      GW=$(/usr/sbin/ipconfig getoption "$IF" router 2>/dev/null)
      if [ -n "$GW" ]; then
        /sbin/route -n delete default >/dev/null 2>&1 || true
        /sbin/route -n add default "$GW" >/dev/null 2>&1 || true
        break
      fi
    done
    sleep 1
  done
  for K in State:/Network/Global/DNS State:/Network/Global/IPv4; do
    printf 'remove %s\nquit\n' "$K" | /usr/sbin/scutil >/dev/null 2>&1 || true
  done
  for IF in $(/sbin/ifconfig -lu); do
    case "$IF" in en*) ;; *) continue ;; esac
    if /usr/sbin/ipconfig getpacket "$IF" 2>/dev/null | /usr/bin/grep -q yiaddr; then
      /usr/sbin/ipconfig set "$IF" DHCP >/dev/null 2>&1 || true
    fi
  done
  /usr/bin/dscacheutil -flushcache 2>/dev/null || true
  /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
}

disconnect_tunnel() {
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
  sleep 1
  restore_network
}

connect_tunnel() {
  local server username password networks route_all user_esc pass_esc base_gw pid ip peer rterr
  server="$(decode_key SERVER)"
  username="$(decode_key USERNAME)"
  password="$(decode_key PASSWORD)"
  networks="$(decode_key NETWORKS)"
  route_all="$(decode_key ROUTE_ALL)"

  [ "$route_all" = "false" ] || die "FULLTUNNEL-DISABLED"
  valid_host "$server" || die "BAD-SERVER"
  [ -x "$APP_HELPER" ] || die "HELPER-MISSING: $APP_HELPER"

  disconnect_tunnel >/dev/null 2>&1 || true
  cleanup_ppp_state

  base_gw=$(/sbin/route -n get "$server" 2>/dev/null | /usr/bin/awk '/gateway:/{print $2; exit}')
  if [ -n "$base_gw" ]; then
    /sbin/route -n add -host "$server" "$base_gw" >/dev/null 2>&1 || \
    /sbin/route -n change -host "$server" "$base_gw" >/dev/null 2>&1 || true
  fi

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
  : > "$LOG"; chmod 644 "$LOG"
  /usr/sbin/pppd file "$OPTS" >>"$LOG" 2>&1 &
  pid=$!
  echo "$pid" > "$PIDF"
  rterr=
  for i in $(seq 1 25); do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
      if /usr/bin/grep -qi 'auth.*fail\|CHAP.*fail' "$LOG"; then echo "AUTHFAIL"; else echo "FAILED"; fi
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
      if [ -n "$rterr" ]; then echo "CONNECTED-ROUTEWARN $ip"; else echo "CONNECTED $ip"; fi
      exit 0
    fi
  done
  kill "$pid" 2>/dev/null || true
  echo "TIMEOUT"
}

REQ="${1:-}"
[ -n "$REQ" ] || die "NO-REQUEST"
[ -f "$REQ" ] || die "REQUEST-NOT-FOUND"
action="$(decode_key ACTION)"
case "$action" in
  connect) connect_tunnel ;;
  disconnect) disconnect_tunnel; echo "DONE" ;;
  *) die "BAD-ACTION" ;;
esac
