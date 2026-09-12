#!/bin/bash
# Report server model, BIOS, iDRAC (BMC) firmware and staging space per host.
#
#   ansible pve_nodes -f 20 -m script -a idrac-survey.sh
#
# Use before any firmware campaign. Surveying first routinely turns an assumed
# fleet-wide push into a handful of hosts, because most are already current.
#
# Needs ipmitool (the pve_zabbix role installs it). Without it the BMC version
# reads '?'. The dmidecode fields are vendor-neutral; 'iDRAC' is simply what
# Dell calls the BMC whose firmware revision this reports.
set -u

MODEL="$(dmidecode -s system-product-name 2>/dev/null | tr -d '\n')"
BIOS="$(dmidecode -s bios-version 2>/dev/null | tr -d '\n')"
SERIAL="$(dmidecode -s system-serial-number 2>/dev/null | tr -d '\n')"
# BMC "Firmware Revision" is the iDRAC version.
FW="$(ipmitool mc info 2>/dev/null | awk -F': ' '/Firmware Revision/{gsub(/ /,"",$2); print $2}')"
# Dell DUPs are ~200MB and self-extract, so check there is room to stage one.
FREE="$(df -BM --output=avail /var/tmp 2>/dev/null | tail -1 | tr -d ' ')"

printf '%s model=%s serial=%s bios=%s idrac=%s free_var_tmp=%s\n' \
  "$(hostname -s)" "${MODEL:-?}" "${SERIAL:-?}" "${BIOS:-?}" "${FW:-?}" "${FREE:-?}"
