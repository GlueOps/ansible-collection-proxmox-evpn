# Per-VLAN VNI: why `pve_per_vlan_vni` exists

## The failure

The obvious VXLAN layout for multi-tenant Proxmox is one VXLAN device per
bridge, with tenants separated by 802.1Q tags *inside* the VXLAN payload:

```
vmbr_lan  (vlan-aware)  <- vxlan_lan  (vxlan-id 10001)
vmbr_nat  (vlan-aware)  <- vxlan_nat  (vxlan-id 10002)
```

This builds cleanly, FRR peers, `show evpn vni` lists both VNIs with every
remote VTEP present, and type-3 (IMET) routes populate the BUM-flood lists. Every
control-plane check you would think to run comes back green.

It still does not work, because **FRR binds an L2VNI to exactly one VLAN**. With
no VID-to-VNI map, it resolves the VNI to the VXLAN port's PVID — VLAN 1 — and
installs *every* remote MAC there. VLAN 1 is not a VLAN any tenant uses, so the
kernel FDB ends up holding the fleet's entire MAC table in a VLAN nothing
forwards in, while every tenant VLAN holds nothing.

The symptom is not an outage. It is permanent flooding: with no unicast FDB
entry for a remote MAC in the right VLAN, every frame to it is head-end
replicated to every VTEP in the fabric.

### How to see it

```sh
# The lie: FRR is happy, and reports the full MAC count.
vtysh -c "show evpn vni"
vtysh -c "show evpn mac vni 10001"

# The truth: which VLAN did the kernel actually put them in?
bridge fdb show dev vxlan_lan | grep extern_learn | grep -oE 'vlan [0-9]+' | sort | uniq -c
```

A healthy host shows counts spread across the tenant VLANs. A host with this
fault shows everything on `vlan 1`.

## The fix

Give each tenant VLAN its own VNI, and tell the kernel the mapping. That means
a **single VXLAN device** (SVD) in metadata mode, with a VLAN-to-VNI map instead
of a fixed `vxlan-id`:

```
auto vxlan_lan
iface vxlan_lan
    vxlan-local-tunnelip 10.0.0.2
    vxlan-vnifilter yes
    bridge-vlan-vni-map 101-220=10101-10220
```

Set `pve_per_vlan_vni: true` and the `pve_network` role renders exactly this,
deriving the ranges from `pve_lan_vlan_base`, `pve_nat_vlan_base`,
`pve_max_tenant_index` and the two VNI bases.

## Four things that will bite you

**1. It is all-or-nothing per host.** The kernel refuses to run external
(metadata-mode) and traditional VXLAN devices on the same UDP port, so all three
devices on a host convert together. The role does this; you cannot convert one
bridge.

**2. It isolates a host mid-rollout.** A host only forms a working L2 domain
with hosts that share its VNIs. Convert one host and it is cut off from every
unconverted peer — and the control plane will not tell you, because the
reflectors happily reflect routes for VNIs they have no local configuration for.
A mixed-model fabric exchanges routes and forwards nothing. Convert fleet-wide,
or maintain a deliberate test cell that you know is isolated.

Set it in the inventory rather than passing `-e`. With `-e`, a later run that
forgets the flag silently reverts a converted host to the legacy model.

**3. `vxlan-vnifilter yes` is required, not optional.** ifupdown2 defaults it
off. Without it each SVD is a plain `COLLECT_METADATA` device that claims UDP
4789 exclusively, so only the first one is created and the rest fail with
`cannot enslave link ...: No such device`. With VNI filtering on, each device
filters its own VNIs and they coexist.

**4. The two VNI bases must differ.** With LAN spanning VLAN 101-220 and NAT
spanning 201-320, VLAN 201-220 is a valid ID on *both* bridges at once. A shared
VNI base collides them onto the same VNI. The role asserts the derived ranges do
not overlap and refuses to render a config where they do.

## The sync bridge, specifically

The HA state-sync bridge carries untagged traffic, so it lands on VLAN 1 —
which under SVD means its egress VNI comes from `bridge-vlan-vni-map 1=10003`,
i.e. it is keyed on the frame being classified into VLAN 1.

A **non-vlan-aware bridge never assigns a VLAN at all**, so there is no tunnel
key and every frame is dropped. The failure is silent and looks perfect from the
control plane: FRR reports the VNI bound to `Vlan: 1` with every remote VTEP,
and all the IMET flood entries are present. Only the FDB gives it away — each
host holds its own local sync MACs and none from its peer.

That is why `pve_flat_bridges` containing `sync` is refused outright while
`pve_per_vlan_vni` is true. Flattening the sync bridge is a sensible FDB saving
under the legacy model and a layer-2 outage under this one.

If you hit it before the guard existed, this restores it immediately:

```sh
ip link set vmbr_sync type bridge vlan_filtering 1
```

## Restarting FRR after a conversion

Converting the kernel does not re-register the VNIs with FRR. A host can come
out of a conversion with correct kernel state and FRR registering a fraction of
its VNIs — on neither model, and reporting success. Restart FRR explicitly after
a conversion and confirm the VNI count:

```sh
systemctl restart frr
sleep 10
vtysh -c "show evpn vni" | wc -l
```

Allow for the post-boot delay: FRR takes tens of seconds after a reboot before
`show evpn vni` is populated, and a host checked too early reads as dead when it
is merely still starting.
