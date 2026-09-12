#!/bin/bash
# Per-DIMM inventory, ECC error counts and the physical memory map.
#
#   ansible pve_nodes -f 20 -m script -a hw-memory-report.sh
#
# Written while triaging a host that had silently lost a DIMM. The tell is
# MemTotal being a whole module short of what the BIOS reports installed —
# the OS never complains, and the DIMM still appears healthy in dmidecode
# because SPD is read over I2C/SMBus, a path independent of the DDR data bus.
#
# Reading the output:
#   uncorrectable > 0        failing DIMM or slot. Do not run workloads on it.
#   mapped << installed      the BIOS has excluded a module from the address map
#   part numbers differing   which module was replaced (useful when a tech
#                            swapped the wrong slot — compare against the DIMM
#                            the SEL actually names)
#
# Distinguishing a bad DIMM from a bad slot needs a swap test: move the module
# to an empty slot. Fault follows the module -> DIMM. Fault stays -> slot/board.
set -u

echo "### DIMMs"
dmidecode -t 17 2>/dev/null | awk '
  /^Memory Device/ {loc="";size="";sn="";pn="";volt=""}
  /Locator:/ && !/Bank/ {sub(/^[ \t]+Locator: /,""); loc=$0}
  /^\tSize:/ {sub(/^[ \t]+Size: /,""); size=$0}
  /Serial Number:/ {sub(/^[ \t]+Serial Number: /,""); sn=$0}
  /Part Number:/ {sub(/^[ \t]+Part Number: /,""); pn=$0}
  /Configured Voltage:/ {sub(/^[ \t]+Configured Voltage: /,""); volt=$0
    if (loc!="" && size !~ /No Module/) printf "  %-6s %-10s %-22s %-14s %s\n", loc, size, pn, sn, volt}'

echo "### capacity"
SLOTS="$(dmidecode -t 16 2>/dev/null | awk -F': ' '/Number Of Devices/{print $2}' | tr -d ' ')"
# dmidecode reports SMBIOS "GB" which is really GiB.
INSTALLED="$(dmidecode -t 17 2>/dev/null | awk '/^\tSize: [0-9]+ GB/{s+=$2} END{print s+0}')"
MAPPED="$(dmidecode -t 19 2>/dev/null | awk -F': ' '/Range Size/{gsub(/ GB/,"",$2); s+=$2} END{print s+0}')"
MEMTOTAL="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
printf '  slots=%s installed=%sGiB mapped=%sGiB memtotal=%sGiB\n' \
  "${SLOTS:-?}" "$INSTALLED" "$MAPPED" "$MEMTOTAL"
[ "${INSTALLED:-0}" -gt 0 ] && [ "${MAPPED:-0}" -lt "${INSTALLED:-0}" ] && \
  echo "  !! $(( INSTALLED - MAPPED ))GiB installed but NOT mapped — BIOS has excluded a module"

echo "### EDAC (kernel, since last boot)"
if [ -d /sys/devices/system/edac/mc ]; then
  for d in /sys/devices/system/edac/mc/mc*/dimm*; do
    [ -d "$d" ] || continue
    printf '  %-10s ce=%-6s ue=%s\n' "$(cat "$d/dimm_label" 2>/dev/null)" \
      "$(cat "$d/dimm_ce_count" 2>/dev/null)" "$(cat "$d/dimm_ue_count" 2>/dev/null)"
  done
else
  echo "  (EDAC driver not loaded)"
fi

echo "### SEL"
TOT="$(ipmitool sel list 2>/dev/null | wc -l)"
UE="$(ipmitool sel list 2>/dev/null | grep -ci 'uncorrectable ecc')"
CE="$(ipmitool sel list 2>/dev/null | grep -ci 'correctable ecc')"
PPR="$(ipmitool sel list 2>/dev/null | grep -ci 'POST Pkg Repair')"
DIMMS="$(ipmitool sel list 2>/dev/null | grep -oiE 'DIMM[A-Z][0-9]+' | sort -u | tr '\n' ',' | sed 's/,$//')"
printf '  entries=%s uncorrectable=%s correctable=%s post_pkg_repair=%s dimms_named=%s\n' \
  "$TOT" "$UE" "$CE" "$PPR" "${DIMMS:-none}"
