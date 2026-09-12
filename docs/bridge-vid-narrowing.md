# Bridge VID narrowing: why `pve_narrow_bridge_vids` exists

## The cost

A vlan-aware Linux bridge replicates FDB entries **per configured VID**. With
`bridge-vids 2-4094` the cost of the forwarding database is

    entries ≈ MACs × VIDs

not `MACs`. That applies to EVPN-learned (`extern_learn`) entries *and* to local
and permanent ones, so a bridge pays for 4093 VLANs it will never carry.

Measured on one host of a 37-node fleet carrying ~10 tenants:

| Bridge        | Entries  | Composition                            |
|---------------|----------|----------------------------------------|
| `vmbr_nat`    | 234,147  | 61 remote MACs × 4094 VIDs             |
| `vmbr_lan`    | 127,311  | 34 remote MACs × 4094 VIDs             |
| `vmbr_sync`   | 12,285   | untagged HA sync: 4,094 local + 8,188 extern |
| `vmbr_public` | 4,141    | no VXLAN; 1 port MAC × 4094, permanent  |
| **total**     | **377,995** | ~13.5M across the fleet             |

Narrowing `lan` and `nat` to the tenant span alone gets that to ~28,200 (~13×).
Narrowing all four gets it to ~12,600 (~30×), confirmed as a steady state rather
than a transient — the fan-out re-accumulates to `MACs × VIDs` immediately, so
it is the VID count that bounds it, not any one-time flush.

## How to enable it

`pve_narrow_bridge_vids` is a list drawn from `[lan, nat, sync, public]`; `[]`
disables the feature. It was a boolean in an earlier revision, so the role
asserts the type rather than letting `-e pve_narrow_bridge_vids=true` narrow
nothing silently.

- `lan` and `nat` narrow to the derived tenant span (`pve_lan_vlan_base + 1`
  through `+ pve_max_tenant_index`, and likewise for NAT).
- `sync` and `public` carry no tenant tags and have no scheme to derive from,
  so they take `pve_untagged_bridge_vids` (default `2-10`). Their real traffic
  is untagged on PVID 1, which sits outside `bridge-vids` either way.

For `sync` and `public` there is a better option than an arbitrary small range:
`pve_flat_bridges` renders them `bridge-vlan-aware no`, which removes the VLAN
dimension from their FDB entirely rather than shrinking it. Read the warning in
[per-vlan-vni.md](per-vlan-vni.md) about the sync bridge before doing that.

## Stage it, and stage it in this order

Unlike `pve_per_vlan_vni`, narrowing does **not** change VNI membership, so it
does not isolate a host and it is safe to roll out one host at a time.

What is not equally safe is which bridge you start with:

1. `lan`, `nat` — carry no management traffic.
2. `sync` — functional only on the hosts running an HA pair.
3. `public` — **holds the host IP, the default gateway and the SSH path.**
   Getting this wrong is an out-of-band recovery, not an SSH one.

Prove `public` on a **drained host through a full cold boot**, not just an
`ifreload`. They are different code paths: `ifreload -a` on a live system and
`ifup` at boot behave differently, and the management IP rides that bridge.

## The guard, and its blind spot

Narrowing silently blackholes any guest whose tag falls outside the new range,
so the role refuses to apply a range that would. It reads `/etc/pve`, which is
cluster-wide, so one host sees every guest's config.

**It can only see `tag=` on PVE guest NICs.** A guest that terminates VLANs
internally on a trunk vNIC — a firewall or router VM, typically — is invisible
to it. The check is therefore weakest on exactly the hosts that carry the most
tenant VLANs. Confirm those by hand before narrowing them.

Set `pve_check_guest_vlan_tags: false` to skip the check entirely; do that only
when you have established the answer another way.

## `ifreload` does not converge the kernel

This is the part that surprises people. `ifreload -a` reporting success does
**not** mean the kernel matches `/etc/network/interfaces`. Two divergences show
up repeatedly:

**VLAN membership is applied inconsistently.** With `bridge-vids` narrowed on
all four bridges, the uplink and the LAN/NAT VXLAN devices took the new range on
every host, while the sync device kept all 4094 VIDs on some hosts and took the
new range on others — same play, same run, same config. It is not a reliable
"sync is always skipped", so every port has to be checked rather than
special-cased.

**Existing FDB entries are never purged.** Narrowing bounds what the kernel will
install *next*; entries already present for now-unmember VLANs stay forever.
Hosts finished a rollout with the narrowed config on disk and FDBs still at
~400k, indistinguishable from untouched hosts.

**Flat bridges do not always flatten.** `ifreload` will not flip
`vlan_filtering` to 0 on a bridge that has a live guest tap attached, because
ifupdown2 will not change it out from under a port it does not manage. The file
says `vlan-aware no`, the kernel keeps filtering on with all 4094 VIDs, and
nothing reports a problem.

The `pve_network` role corrects all three after the reload, so it converges the
kernel and not just the file.

## The flush is guarded

Flushing stale FDB entries is momentarily disruptive: the entries vanish and FRR
reinstalls them over the next few seconds, so a guest on that host floods or
blackholes until it does. The role refuses to flush — and refuses to force-flatten
a bridge — while any guest is running.

The host is still left correct on disk and in VLAN membership. Only the eviction
of stale entries waits. They are harmless but never expire, so clear them at the
next reboot of that host, or during a change window with:

```sh
ansible-playbook glueops.proxmox_evpn.network \
  --limit hv07 -e pve_fdb_flush_requires_empty=false
```

## A caution worth recording

On one fleet, hosts that had been VID-narrowed were later measured holding far
*fewer* EVPN MAC entries than unnarrowed hosts — 1 remote MAC instead of ~30 on
11 of 17 narrowed hosts, while unnarrowed hosts were uniformly healthy. That is
the opposite of the intended effect, and it points at the VLAN-to-VNI binding
problem described in [per-vlan-vni.md](per-vlan-vni.md) rather than at narrowing
itself.

Narrow and verify, rather than narrowing and assuming. Count the entries per
VLAN before and after:

```sh
bridge fdb show dev vxlan_lan | grep extern_learn \
  | grep -oE 'vlan [0-9]+' | sort | uniq -c
```
