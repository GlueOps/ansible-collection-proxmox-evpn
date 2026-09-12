# Verification — when something looks off, run these in order

Each step below only makes sense if the one before it passed. Working down the
list in order is what separates "the fabric is broken" from "one switch port is
in the wrong VLAN".

## 1. Underlay reachability and MTU

From any host, against another host's underlay address. The DF payload size is
`underlay_mtu - 28` (20 bytes IP + 8 bytes ICMP), so it differs per fleet:

```sh
# Baseline. MUST pass with 0% loss, everywhere.
ping -M do -s 1472 -c 3 <peer_link_ip>

# At a 1550 underlay. MUST pass if you have raised pve_underlay_target_mtu.
ping -M do -s 1522 -c 3 <peer_link_ip>
```

**Baseline failing** is L1/L2: cabling, or the port is not in the underlay VLAN
at all, in which case ARP never resolves either.

**Baseline passing while the DF-ping fails** is a switch port MTU below the
underlay MTU. This is a distinct fault and the two are easy to conflate: a port
in the right VLAN but left at the default 1514 will ARP and ping perfectly and
fail only on a full-size frame.

The switch is the only authority on both VLAN and port MTU. Read it off the
wire rather than from a provisioning email:

```sh
tcpdump -i eno2 -s1500 -vv -c1 'ether proto 0x88cc'   # PVID, VLAN name, port, MTU
```

Or fleet-wide, both NICs, parsed:

```sh
ansible-playbook glueops.proxmox_evpn.diagnostics --tags lldp
```

`pvid=ABSENT` means the port advertises no 802.1 VLAN membership at all — an
unconfigured switched port, which is not the same fault as being in the wrong
VLAN.

To test every pair at once rather than one peer by hand:

```sh
ansible-playbook glueops.proxmox_evpn.diagnostics --tags underlay
```

## 2. BGP sessions

```sh
ansible pve_nodes -m shell -a "vtysh -c 'show bgp summary'"
```

Each peer should be `Established` with a non-zero `Up/Down` and matching
`MsgRcvd`/`MsgSent`. In a full mesh of N hosts each host sees N-1 peers; under
route reflectors, a client sees only the reflectors.

## 3. EVPN VNI auto-discovery

```sh
ansible pve_nodes -m shell -a "vtysh -c 'show evpn vni'"
```

One row per local VXLAN device (or per tenant VLAN under `pve_per_vlan_vni`),
each with `# Remote VTEPs` equal to the number of peers carrying the same VNI.

A VNI missing on one side means FRR is not seeing the bridge — usually the VXLAN
device is not `master <bridge>`, or it is not UP.

Allow for the post-boot delay. FRR takes tens of seconds after a reboot before
this is populated, and a host checked too early reads as dead when it is merely
still starting.

## 4. Type-3 (IMET) routes — the BUM flood targets

```sh
ansible pve_nodes -m shell -a "vtysh -c 'show bgp l2vpn evpn route type multicast'"
```

Per host you should see `*>` (locally generated) one route per local VNI, and
`*>i` (received) one route per remote VNI per peer.

## 5. Kernel FDB — proof EVPN is programming the data plane

This is the step people skip, and it is the one that catches the failure the
control plane cannot see.

```sh
ansible pve_nodes -m shell -a "bridge fdb show dev vxlan_lan | grep -E 'extern_learn|^00:00:'"
```

Two entry shapes matter:

- `00:00:00:00:00:00 dst <peer_underlay_ip> self permanent` — a type-3
  IMET-installed BUM target.
- `<MAC> dst <peer_underlay_ip> self extern_learn` — a type-2 MAC-installed
  unicast entry. Only present when guests are running.

**Check which VLAN they landed in**, not just that they exist:

```sh
bridge fdb show dev vxlan_lan | grep extern_learn \
  | grep -oE 'vlan [0-9]+' | sort | uniq -c
```

Everything on `vlan 1` with the tenant VLANs empty is the VLAN-to-VNI binding
failure described in [per-vlan-vni.md](per-vlan-vni.md). FRR will report the
full MAC count throughout.

## 6. Type-2 (MAC) routes when guests are up

```sh
ansible pve_nodes -m shell -a "vtysh -c 'show evpn mac vni 10001'"
ansible pve_nodes -m shell -a "vtysh -c 'show bgp l2vpn evpn route type macip'"
```

Each guest vNIC MAC should be `local` on its own host and `remote` — with that
host's VTEP address — on every other host.

## 7. Hard-kill test: definitive proof FRR owns the FDB

```sh
# Kill FRR on one host; type-3 entries should vanish from the kernel FDB.
ssh hv01 systemctl stop frr
ssh hv01 'bridge fdb show dev vxlan_lan | grep "^00:00:"'   # expect: empty

# Restart; entries return within ~5s.
ssh hv01 systemctl start frr
sleep 5
ssh hv01 'bridge fdb show dev vxlan_lan | grep "^00:00:"'   # expect: peer entries back
```

If entries **persist** while FRR is stopped, something is installing them
statically — usually a leftover `vxlan-remoteip` in
`/etc/network/interfaces` from a pre-EVPN configuration. Clean it out; the
control plane is not actually in charge.

## 8. Data-plane smoke test on a fresh bridge

Before any guests exist, give two hosts link-local addresses on the same tenant
bridge and ping across the fabric:

```sh
# hv01:
ip addr add 169.254.99.1/30 dev vmbr_lan
# hv02:
ip addr add 169.254.99.2/30 dev vmbr_lan
# either side:
ping -c 3 169.254.99.<peer>
# clean up:
ip addr del 169.254.99.1/30 dev vmbr_lan
```

Note that under `pve_per_vlan_vni` this tests VLAN 1, which is not a tenant
VLAN — so it proves the tunnel is up, not that tenant forwarding works. For
that, put the addresses on a tagged sub-interface of a tenant VLAN.

## Hardware

```sh
ansible-playbook glueops.proxmox_evpn.diagnostics --tags hardware
```

Reports model, BIOS, BMC firmware, the DIMM inventory and ECC counts.

The memory report flags a host that has **silently lost a DIMM**: `MemTotal` a
whole module short of what the BIOS reports installed. The OS never complains,
and the module still looks healthy in `dmidecode`, because SPD is read over a
bus independent of the DDR data path.

`uncorrectable > 0` means take the host out of service. To tell a failing DIMM
from a failing slot, move the module to an empty slot: fault follows the module
means the DIMM, fault stays means the slot or the board.
