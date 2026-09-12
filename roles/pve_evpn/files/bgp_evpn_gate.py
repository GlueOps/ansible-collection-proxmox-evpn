#!/usr/bin/env python3
"""Report whether every reachable BGP EVPN peer has reached Established.

Installed by the glueops.proxmox_evpn pve_evpn role and polled by it until the
first word of the output is ALL_UP.

The distinction this makes is the whole point: a configured peer with nothing
listening on TCP/179 is a host that has not been bootstrapped yet, and must not
hold the gate. A peer that IS listening but is not Established is a real fault,
and must. Without that split, a first rollout can never converge — the route
reflectors gain neighbor statements for hosts that do not have FRR installed.
"""
import json
import socket
import subprocess
import sys

SUMMARY = "show bgp l2vpn evpn summary json"


def main() -> int:
    try:
        raw = subprocess.run(
            ["vtysh", "-c", SUMMARY],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout
        peers = json.loads(raw).get("peers", {})
    except (subprocess.SubprocessError, ValueError) as exc:
        print("ERROR %s" % exc, file=sys.stderr)
        return 1

    established, pending, skipped = [], [], []

    for ip, peer in peers.items():
        if peer.get("state") == "Established":
            established.append(ip)
            continue
        # Not up. Is there a bgpd on the far end at all?
        sock = socket.socket()
        sock.settimeout(2)
        try:
            sock.connect((ip, 179))
            pending.append(ip)      # listening but not Established -> real problem
        except OSError:
            skipped.append(ip)      # nothing listening -> not bootstrapped yet
        finally:
            sock.close()

    state = "ALL_UP" if (peers and not pending) else "WAIT"
    print("%s established=%d pending=%d skipped=%s" % (
        state, len(established), len(pending),
        ",".join(sorted(skipped)) if skipped else "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
