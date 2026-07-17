#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

export L2TP_ROOT_HELPER_LIB_ONLY=1
# shellcheck disable=SC1091
source RootHelper/l2tp-office-root-helper.sh

assert_ok() {
  "$@" || {
    echo "FAIL: expected success: $*" >&2
    exit 1
  }
}

assert_fail() {
  if "$@"; then
    echo "FAIL: expected failure: $*" >&2
    exit 1
  fi
}

assert_ok valid_host "vpn.example.com"
assert_ok valid_host "213.79.84.225"
assert_fail valid_host ""
assert_fail valid_host "vpn example.com"
assert_fail valid_host "vpn.example.com;rm"
assert_fail valid_host ".vpn.example.com"
assert_fail valid_host "vpn..example.com"
assert_fail valid_host "vpn-.example.com"
assert_fail valid_host "-vpn.example.com"

assert_ok valid_ipv4 "0.0.0.0"
assert_ok valid_ipv4 "255.255.255.255"
assert_fail valid_ipv4 "256.1.1.1"
assert_fail valid_ipv4 "1.2.3"
assert_fail valid_ipv4 "1.2.3.4.5"

assert_ok valid_cidr "172.16.99.0/24"
assert_ok valid_cidr "10.0.0.1"
assert_ok valid_cidr "0.0.0.0/0"
assert_fail valid_cidr "172.16.99.0/33"
assert_fail valid_cidr "999.16.99.0/24"
assert_fail valid_cidr "172.16.99/24"

escaped="$(printf 'u"ser\\name\nnext' | ppp_escape)"
if [ "$escaped" != 'u\"ser\\namenext' ]; then
  echo "FAIL: unexpected ppp_escape output: $escaped" >&2
  exit 1
fi

echo "root-helper tests OK"
