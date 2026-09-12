# glueops.proxmox_evpn

Build and operate Proxmox VE hypervisor fleets with a VXLAN tenant fabric and a
BGP-EVPN control plane driven by FRR.

Proxmox's own SDN stack is **not** used. FRR is configured directly and the host
bridges are plain Linux bridges that PVE consumes as `bridge:` types. That is a
deliberate choice: it keeps the control plane legible, lets the VLAN-to-VNI
mapping be stated explicitly, and means the interesting failures are debuggable
with `bridge`, `ip` and `vtysh` rather than through an abstraction.

Designed for tens of hypervisors and tens of tenants per fleet. Everything
site-specific lives in *your* inventory — this collection ships no addresses, no
hostnames and no credentials.

---

## Install

```sh
ansible-galaxy collection install glueops.proxmox_evpn
```

Or pin it in your inventory repository's `requirements.yml`
(see [examples/requirements.yml](examples/requirements.yml)):

```yaml
collections:
  - name: glueops.proxmox_evpn
    version: "1.0.0"
```

Requires `ansible-core` >= 2.15. Targets Debian 13 (trixie); Debian 12 works
with the repository defaults changed.

---

## The intended split

This collection is the **public, reusable half**. The other half is yours and
stays private:

```
your-private-inventory-repo/
  requirements.yml                  # pins this collection
  ansible.cfg                       # or one per fleet, selected by ANSIBLE_CONFIG
  inventories/
    <fleet>/
      hosts.yml                     # addresses, hostnames, toggle groups
      group_vars/pve_nodes.yml      # MTUs, VNIs, whitelists, backup IDs
```

Nothing in that tree needs to be public, and nothing in this collection needs to
be private. Start from [examples/](examples/) — it is a working skeleton with
RFC 5737 documentation addresses throughout.

---

## Architecture

### Bridges

Four bridges per host. The topology is this collection's opinion; the names are
configurable (`pve_bridge_public`, `pve_bridge_lan`, …).

| Bridge        | Backed by    | Carries                                   |
|---------------|--------------|-------------------------------------------|
| `vmbr_public` | the uplink NIC | Public WAN, the host IP and default route |
| `vmbr_lan`    | `vxlan_lan`  | Tenant LAN trunk, per-tenant 802.1Q tag   |
| `vmbr_nat`    | `vxlan_nat`  | Tenant NAT/exposed segment, per-tenant tag |
| `vmbr_sync`   | `vxlan_sync` | HA state sync (pfsync/CARP), untagged      |

Tenant separation lives in 802.1Q tags *inside* the VXLAN payload, so the host
bridges never need a per-tenant variant.

Bridge and VXLAN MTU is not hard-coded — it derives as
`min(pve_underlay_target_mtu, NIC maxmtu) - 50`. A 1500 underlay yields a 1450
inner MTU, which tenant guests must be lowered to match; a 1550 underlay yields
a clean 1500 and they need no tuning. Which you get is a property of your switch
ports, not a choice you make in a variable.

### Control plane

- iBGP within one ASN, between every host, over the underlay.
- Topology is **toggle-driven by inventory group membership**: hosts in
  `pve_route_reflectors` act as reflectors; an empty group means full mesh. No
  code or template changes either way.
- `advertise-all-vni` — FRR auto-discovers any locally configured VXLAN VNI.
- Type-3 (IMET) routes populate the BUM-flood VTEP list per VNI, so there is no
  static `vxlan-remoteip` anywhere.
- Type-2 (MAC/IP) routes carry guest MACs and enable ARP/ND suppression.

---

## Quickstart

```sh
# 1. Reachability and auth.
ansible pve_nodes -m ping

# 2. Install Proxmox VE onto stock Debian. serial: 1, reboots into the PVE kernel.
ansible-playbook glueops.proxmox_evpn.install

# 3. Host networking — bridges, VXLAN devices, underlay NIC. serial: 1.
ansible-playbook glueops.proxmox_evpn.network

# 4. FRR / BGP-EVPN. Reflectors serially, then clients in parallel.
ansible-playbook glueops.proxmox_evpn.evpn

# 5. sshd tuning for concurrent automation (recommended before any provisioner).
ansible-playbook glueops.proxmox_evpn.sshd

# 6. Monitoring agent and IPMI sensors.
ansible-playbook glueops.proxmox_evpn.zabbix

# 7. Host firewall. Read the lockout note below first.
ansible-playbook glueops.proxmox_evpn.firewall

# 8. Config backup to a Google Shared Drive.
ansible-playbook glueops.proxmox_evpn.backup
```

Or all of it, in order: `ansible-playbook glueops.proxmox_evpn.site`.

---

## Roles

| Role | Does |
|------|------|
| `proxmox_install` | Repos, PVE kernel, packages, Debian kernel cleanup, `iptables-persistent` baseline. Near no-op on an already-bootstrapped host. |
| `pve_network` | Canonical owner of `/etc/network/interfaces`. Bridges, VXLAN devices, underlay MTU and NIC tuning, bridge VID narrowing, and kernel reconciliation afterwards. |
| `pve_evpn` | Installs and configures FRR. Reflector or full-mesh topology from inventory groups, with a convergence gate that tolerates not-yet-bootstrapped peers. |
| `pve_firewall` | Public-wire DHCP filter, monitoring agent port whitelist, and an inventory-derived SSH whitelist with lockout safety. |
| `pve_backup` | rclone plus an hourly cron push of networking, FRR and DHCP config to a Google Shared Drive. |
| `pve_zabbix` | Zabbix Agent 2 and cached IPMI sensor exposure through UserParameters, with a one-binary sudo grant. |
| `pve_sshd` | sshd tuning for concurrent Ansible/Terraform automation. |
| `pve_passwords` | Sets local account passwords, hashed on the control node. |
| `pve_upgrade` | `apt dist-upgrade` with kernel-install and kernel-in-service verification, and a running-guest reboot guard. |
| `pve_diagnostics` | Read-only: LLDP port facts, underlay mesh and MTU tests, hardware and DIMM surveys. |

Each role's `defaults/main.yml` documents every variable it takes and why the
default is what it is.

---

## Playbooks

| Playbook | |
|---|---|
| `glueops.proxmox_evpn.site` | Everything, in dependency order |
| `glueops.proxmox_evpn.install` | Proxmox VE onto Debian |
| `glueops.proxmox_evpn.network` | Bridges and VXLAN, then a pairwise MTU check |
| `glueops.proxmox_evpn.evpn` | FRR / BGP-EVPN |
| `glueops.proxmox_evpn.firewall` | Host iptables policy |
| `glueops.proxmox_evpn.backup` | Config backup |
| `glueops.proxmox_evpn.zabbix` | Monitoring agent |
| `glueops.proxmox_evpn.sshd` | sshd tuning |
| `glueops.proxmox_evpn.passwords` | Account passwords (prompts) |
| `glueops.proxmox_evpn.upgrade` | Fleet patching |
| `glueops.proxmox_evpn.diagnostics` | Read-only diagnostics |
| `glueops.proxmox_evpn.link_check` | Underlay reachability only |

---

## Things that will bite you

These are the failure modes that cost real time to find. Each is guarded in
code; the guards are worth understanding rather than skipping.

**The control plane lies about the data plane.** FRR will report every VNI
bound, every remote VTEP present and the full MAC count while nothing forwards.
Every health check that reads `vtysh` output is necessary and none of them are
sufficient — you have to look at the kernel FDB, and at *which VLAN* the entries
landed in. See [docs/verification.md](docs/verification.md) §5.

**`pve_per_vlan_vni` is fleet-wide or nothing.** A converted host only forms an
L2 domain with other converted hosts, and route reflectors happily reflect
routes for VNIs they have no local config for — so a half-converted fabric
exchanges routes perfectly and forwards nothing.
See [docs/per-vlan-vni.md](docs/per-vlan-vni.md).

**A flat sync bridge under per-VLAN VNI is a silent layer-2 outage.** The role
refuses the combination. The reasoning is in the same document.

**`ifreload -a` succeeding does not mean the kernel matches the file.** VLAN
membership applies inconsistently, stale FDB entries are never purged, and a
bridge with a live guest tap will not flatten. `pve_network` reconciles all
three afterwards. See [docs/bridge-vid-narrowing.md](docs/bridge-vid-narrowing.md).

**The public bridge is the SSH path.** `pve_network` runs `serial: 1` by
default, writes a content-hashed backup of the previous config and drops
`/root/restore-network.sh` — runnable from an IPMI console — before touching
anything. Raise `pve_bridge_batch` only when the run demonstrably leaves the
public bridge alone.

**The SSH whitelist can lock you out.** The `ssh` tag refuses to run unless
`pve_ssh_whitelist_extra` is explicitly defined (set `[]` if your out-of-band
mesh is the only direct path), and pauses for confirmation when the address you
are connected from is not covered. `--skip-tags confirm` bypasses the pause for
unattended runs; `--skip-tags ssh` skips the whole thing. Established sessions
survive via conntrack — it is the *next* connection that fails.

**`upgrade: dist`, not `upgrade: safe`.** A Proxmox kernel bump changes the
package *name*, which apt sees as a new package rather than an upgrade. Plain
`upgrade` refuses to install new packages, holds the meta-package back and
silently leaves the kernel alone — no error, no hold to find later, just a fleet
that stops receiving kernel CVE fixes. `pve_upgrade` asserts that a kernel apt
offered was actually installed, and that a host which rebooted came back
*running* it.

**Reboots are refused under running guests.** Both `pve_upgrade` and the
`pve_network` FDB flush guard on this by default. They do not fail — they report
the host as still needing the action, so a fleet run completes and hands you a
list to schedule.

---

## Documentation

- [per-vlan-vni.md](docs/per-vlan-vni.md) — why FRR puts every remote MAC in
  VLAN 1, what the single-VXLAN-device model fixes, and the four ways a
  conversion goes wrong.
- [bridge-vid-narrowing.md](docs/bridge-vid-narrowing.md) — the `MACs × VIDs`
  FDB fan-out, measurements, safe rollout order, and why `ifreload` alone does
  not converge the kernel.
- [verification.md](docs/verification.md) — the ordered checklist for when
  something looks off, from L1 up to a data-plane smoke test.

---

## Extras

Not part of the collection's Ansible content, shipped alongside it:

- `extras/zabbix/pve-ipmi-template.yaml` — Zabbix 7.0 template for the IPMI
  items the `pve_zabbix` role exposes. Import via **Data collection → Templates
  → Import**, then link it to an autoregistration action keyed on
  `pve_zabbix_host_metadata`.
- `extras/scripts/idrac-flash.sh` — sequential BMC firmware update, run from the
  **control node** because it has to survive the BMC going away mid-run. Asserts
  the hostname before flashing, verifies the checksum on the target, never
  passes `-r` (which would reboot the host), aborts the whole run on first
  failure, and fails loudly if a host's uptime goes backwards.

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).
