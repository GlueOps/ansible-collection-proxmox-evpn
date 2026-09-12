# Changelog

All notable changes to this collection are documented here.
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-09-12

First public release.

### Added

- `proxmox_install` — Proxmox VE onto stock Debian, idempotent and a near no-op
  on an already-bootstrapped host.
- `pve_network` — canonical owner of `/etc/network/interfaces`: four-bridge
  VXLAN topology, NIC capability probing and MTU derivation, per-VLAN VNI
  (single-VXLAN-device) support, bridge VID narrowing, and post-`ifreload`
  kernel reconciliation.
- `pve_evpn` — FRR BGP-EVPN with route-reflector or full-mesh topology driven by
  inventory group membership, and a convergence gate that distinguishes a broken
  peer from a not-yet-bootstrapped one.
- `pve_firewall` — public-wire DHCP filter, monitoring agent whitelist, and an
  inventory-derived SSH whitelist with lockout pre-flight.
- `pve_backup` — hourly rclone push of host config to a Google Shared Drive.
- `pve_zabbix` — Zabbix Agent 2 with cached IPMI sensor UserParameters.
- `pve_sshd` — sshd tuning for concurrent automation.
- `pve_passwords` — control-node-hashed local account passwords.
- `pve_upgrade` — `apt dist-upgrade` with kernel-install and kernel-in-service
  verification and a running-guest reboot guard.
- `pve_diagnostics` — read-only LLDP, underlay mesh and hardware surveys.
- Playbooks for each role plus `site`, `link_check` and `diagnostics`.
- `docs/per-vlan-vni.md`, `docs/bridge-vid-narrowing.md`, `docs/verification.md`.
- `examples/` — a working inventory skeleton, `ansible.cfg` and
  `requirements.yml` for the private repository that consumes this collection.
