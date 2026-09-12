#!/bin/bash
# Report what the SWITCH says about this host's uplinks: chassis, model, OS
# version, port ID, VLAN (PVID + name) and the port's advertised MTU.
#
# usage: lldp-port-facts.sh [iface ...]    (default: eno1 eno2)
#
# Run against a fleet with:
#   ansible pve_nodes -f 20 -m script -a "lldp-port-facts.sh eno1 eno2"
#
# Why this exists: colo VLAN IDs and port MTUs are routinely taken from a
# provisioning email, and a wrong one sends a support ticket chasing the wrong
# VLAN. The switch is the only authority on either. It is also
# the only way to see a port sitting at the default MTU 1514 — such a port ARPs
# and pings perfectly and fails only a full-size DF-ping.
#
# LLDP is advertised roughly every 30s, hence the 80s ceiling per interface.
set -u

command -v tcpdump >/dev/null 2>&1 || apt-get install -y -qq tcpdump >/dev/null 2>&1

grab() {
  local IF="$1"
  [ -e "/sys/class/net/$IF" ] || { printf '%s %s ABSENT\n' "$(hostname -s)" "$IF"; return; }

  local MTU ADDR OUT CH PORT PVID VNAME SWMTU MODEL JUNOS
  MTU="$(cat "/sys/class/net/$IF/mtu")"
  ADDR="$(ip -4 -br addr show "$IF" 2>/dev/null | awk '{print $3}')"
  OUT="$(timeout 80 tcpdump -i "$IF" -s1500 -vv -c1 'ether proto 0x88cc' 2>/dev/null)"

  if [ -z "$OUT" ]; then
    printf '%s %s host_mtu=%s addr=%s NO_LLDP_IN_80s\n' \
      "$(hostname -s)" "$IF" "$MTU" "${ADDR:--}"
    return
  fi

  CH="$(printf '%s' "$OUT"    | grep -A1 'Chassis ID TLV' | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}')"
  PORT="$(printf '%s' "$OUT"  | grep -oE '(xe|ge|et)-[0-9/]+' | head -1)"
  PVID="$(printf '%s' "$OUT"  | grep -oE 'PVID\): [0-9]+' | grep -oE '[0-9]+$')"
  VNAME="$(printf '%s' "$OUT" | grep -oE 'vlan name: [A-Za-z0-9._-]+' | head -1 | sed 's/vlan name: //')"
  SWMTU="$(printf '%s' "$OUT" | grep -oE 'MTU size [0-9]+' | grep -oE '[0-9]+$')"
  MODEL="$(printf '%s' "$OUT" | grep -oE 'qfx[0-9a-z-]+|ex[0-9]+-[0-9a-z-]+' | head -1)"
  JUNOS="$(printf '%s' "$OUT" | grep -oE 'JUNOS [0-9][0-9A-Za-z.-]+' | head -1 | sed 's/JUNOS //')"

  printf '%s %s host_mtu=%s addr=%s chassis=%s model=%s junos=%s port=%s pvid=%s vlan=%s sw_mtu=%s\n' \
    "$(hostname -s)" "$IF" "$MTU" "${ADDR:--}" "${CH:-NONE}" "${MODEL:-?}" \
    "${JUNOS:-?}" "${PORT:-?}" "${PVID:-ABSENT}" "${VNAME:-ABSENT}" "${SWMTU:-?}"
}

# pvid=ABSENT means the port advertises no 802.1 VLAN membership at all — that is
# what an unconfigured switched port looks like, and it is not the same fault as
# being in the wrong VLAN.
[ $# -gt 0 ] || set -- eno1 eno2
for iface in "$@"; do grab "$iface"; done
