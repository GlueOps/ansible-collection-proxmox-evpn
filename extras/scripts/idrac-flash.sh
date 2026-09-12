#!/usr/bin/env bash
# Apply a Dell iDRAC firmware DUP to one or more hosts, SEQUENTIALLY, verifying
# each host recovers before touching the next.
#
# Runs on the CONTROL NODE (unlike the other scripts here, which run on targets).
#
#   idrac-flash.sh <dup.BIN> <expected-sha256> <target-version> \
#       <ip>=<hostname> [<ip>=<hostname> ...]
#
#   IDRAC_SSH_KEY=~/.ssh/fleet_key idrac-flash.sh \
#       ~/Downloads/iDRAC-..._7.00.00.184_A00.BIN \
#       6659ac8e...cbb4 7.00 \
#       198.51.100.14=hv13 \
#       198.51.100.16=hv15
#
# Survey first with the pve_diagnostics role (--tags hardware) — most of a
# fleet is usually already current, and this is not a job to do to hosts that
# do not need it.
#
# Check applicability without flashing:   <dup.BIN> -c    (on the target)
# The DUP refuses and explains if the version jump is unsupported, which is the
# reliable way to answer "can 4.40 go straight to 7.00" rather than guessing.
#
# Safety properties, all of which exist because these hosts carry live VMs:
#   - asserts `hostname -s` matches before flashing, so a wrong-IP typo cannot
#     silently flash the wrong machine
#   - verifies the DUP checksum on the target before executing it
#   - does NOT pass -r to the DUP: that reboots the HOST. iDRAC firmware does
#     not need a host reboot, and these hosts have running guests
#   - aborts the whole run on the first failure, leaving later hosts untouched
#   - compares uptime before/after and fails loudly if a host rebooted anyway
#
# An iDRAC flash resets the BMC only — host OS, guests and networking continue.
# What you DO lose for ~5 min is out-of-band access and IPMI, so put the hosts
# in a monitoring maintenance window first or expect IPMI checks to alarm.
set -uo pipefail

BIN="${1:?usage: $0 <dup.BIN> <sha256> <target-version> <ip>=<host> ...}"
EXPECT_SHA="${2:?}"
TARGET_VER="${3:?}"
shift 3
[ $# -ge 1 ] || { echo "no targets given" >&2; exit 64; }

KEY="${IDRAC_SSH_KEY:?set IDRAC_SSH_KEY to the private key that reaches these hosts as root}"
DST="/var/tmp/$(basename "$BIN")"
SSH="ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i $KEY"

[ -f "$BIN" ] || { echo "no such DUP: $BIN" >&2; exit 66; }

for entry in "$@"; do
  IP="${entry%%=*}"; NAME="${entry##*=}"
  echo "################################ $NAME ($IP)"

  ACTUAL="$($SSH "root@$IP" 'hostname -s' 2>/dev/null)"
  if [ "$ACTUAL" != "$NAME" ]; then
    echo "ABORT: expected $NAME at $IP, got '$ACTUAL'"; exit 1
  fi

  PRE_FW="$($SSH "root@$IP" 'ipmitool mc info 2>/dev/null | awk -F": " "/Firmware Revision/{gsub(/ /,\"\",\$2); print \$2}"')"
  PRE_VMS="$($SSH "root@$IP" 'qm list 2>/dev/null | grep -c running')"
  PRE_UP="$($SSH "root@$IP" 'cut -d. -f1 /proc/uptime')"
  echo "  pre : idrac=$PRE_FW vms=$PRE_VMS uptime=${PRE_UP}s"

  if [ "$PRE_FW" = "$TARGET_VER" ]; then
    echo "  SKIP: already at $TARGET_VER"; continue
  fi

  SHA="$($SSH "root@$IP" "sha256sum $DST 2>/dev/null | cut -d' ' -f1")"
  if [ "$SHA" != "$EXPECT_SHA" ]; then
    echo "  staging $(du -h "$BIN" | cut -f1)..."
    scp -q -o StrictHostKeyChecking=no -i "$KEY" "$BIN" "root@$IP:$DST" \
      || { echo "ABORT: copy to $NAME failed"; exit 1; }
    SHA="$($SSH "root@$IP" "sha256sum $DST | cut -d' ' -f1")"
  fi
  [ "$SHA" = "$EXPECT_SHA" ] || { echo "ABORT: checksum mismatch on $NAME"; exit 1; }
  echo "  sha : ok"

  echo "  flashing at $(date -u +%H:%M:%SZ) ..."
  $SSH "root@$IP" "chmod +x $DST; $DST -q" >"/tmp/idrac-flash-$NAME.log" 2>&1
  RC=$?
  echo "  dup_exit=$RC at $(date -u +%H:%M:%SZ)"
  if [ "$RC" -ne 0 ]; then
    echo "ABORT: DUP exit $RC on $NAME — remaining hosts untouched"
    tail -5 "/tmp/idrac-flash-$NAME.log"; exit 1
  fi

  echo -n "  waiting for BMC"
  POST_FW=""
  for _ in $(seq 1 40); do
    POST_FW="$($SSH "root@$IP" 'timeout 15 ipmitool mc info 2>/dev/null | awk -F": " "/Firmware Revision/{gsub(/ /,\"\",\$2); print \$2}"' 2>/dev/null)"
    [ "$POST_FW" = "$TARGET_VER" ] && break
    echo -n "."; sleep 15
  done
  echo ""

  POST_VMS="$($SSH "root@$IP" 'qm list 2>/dev/null | grep -c running')"
  POST_UP="$($SSH "root@$IP" 'cut -d. -f1 /proc/uptime')"
  echo "  post: idrac=$POST_FW vms=$POST_VMS uptime=${POST_UP}s"

  [ "$POST_FW" = "$TARGET_VER" ] || { echo "ABORT: $NAME BMC returned '$POST_FW', wanted $TARGET_VER"; exit 1; }
  [ "$POST_UP" -ge "$PRE_UP" ] || { echo "ABORT: $NAME REBOOTED — investigate before continuing"; exit 1; }
  [ "$POST_VMS" = "$PRE_VMS" ] || echo "  WARNING: VM count $PRE_VMS -> $POST_VMS"
  echo "  RESULT: $NAME ok ($PRE_FW -> $POST_FW, no reboot, VMs intact)"
done

echo "################################ all targets complete"
