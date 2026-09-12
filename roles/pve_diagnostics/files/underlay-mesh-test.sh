#!/bin/bash
# Full-mesh underlay test from this host to every other fleet member: plain ping
# (reachability) and DF-ping at the configured underlay MTU (path can carry it).
#
#   ansible pve_nodes -f 20 -m script \
#     -a 'underlay-mesh-test.sh 10.0.0 2 38 1550 eno2'
#
# args: <underlay /24 prefix> <first octet> <last octet> <underlay MTU> [iface]
#
# The two tests fail independently and mean different things:
#   plain ping fails            -> L1/L2: cabling, or the port is not in the
#                                  underlay VLAN (ARP will not resolve either)
#   plain ok but DF-ping fails  -> the switch port MTU is below the underlay MTU.
#                                  Everything looks healthy until a large frame.
#
# DF payload is MTU-28 (20 IP + 8 ICMP), so 1550 -> 1522 and 1500 -> 1472.
set -u

PREFIX="${1:?usage: $0 <prefix e.g. 10.0.0> <first> <last> <mtu> [iface]}"
FIRST="${2:?}"; LAST="${3:?}"; MTU="${4:?}"; IFACE="${5:-eno2}"
PAYLOAD=$(( MTU - 28 ))

SELF="$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
ok=0; fail=0; dfok=0; dffail=0
failed=""; dffailed=""

for i in $(seq "$FIRST" "$LAST"); do
  PEER="$PREFIX.$i"
  [ "$PEER" = "$SELF" ] && continue
  if ping -c1 -W2 "$PEER" >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    fail=$((fail+1)); failed="$failed $PEER"
  fi
  if ping -c1 -W2 -M do -s "$PAYLOAD" "$PEER" >/dev/null 2>&1; then
    dfok=$((dfok+1))
  else
    dffail=$((dffail+1)); dffailed="$dffailed $PEER"
  fi
done

printf '%s ping=%s/%s dfping%s=%s/%s' \
  "$(hostname -s)" "$ok" "$((ok+fail))" "$PAYLOAD" "$dfok" "$((dfok+dffail))"
[ -n "$failed" ]   && printf ' PINGFAIL:%s' "$failed"
[ -n "$dffailed" ] && printf ' DFFAIL:%s' "$dffailed"
printf '\n'
