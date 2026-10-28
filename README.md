# wiplex

**WiFi client + access point on a single radio.**

wiplex shares a machine's internet as a routed, NATed hotspot. It prefers a
**wired** uplink when one is present (freeing the WiFi radio), and otherwise
shares the **WiFi client** radio on a single adapter. The AP lives on its own
subnet and NATs out the active uplink.

Typical use: a laptop on a campus/office WiFi (or Ethernet) that should let your
phone (or another device) share that connection through the laptop.

```
        upstream WiFi / Ethernet
                 |
            [ wiplex host ]
   STA ─────────────┤
   (client link)    │  DHCP + DNS, new subnet
                    ├──────── AP  (SSID "wiplex", 192.168.50.1/24)
                    │
             phone ─┘  192.168.50.x  ——— NAT ———> internet
```

---

## Why "single radio" needs care

A single WiFi card can run STA and AP at the same time on most modern drivers,
**but only on the same channel** (the driver advertises
`#{ managed } <= 1, #{ AP } <= 1, ..., #channels <= 1`). Consequences:

- If the uplink is the WiFi client, the AP is pinned to the client's channel.
  When the client roams, wiplex restarts hostapd on the new channel.
- A concurrent AP **cannot** run on a **DFS channel** (radar detection) on many
  drivers — starting one fails CAC or crashes the firmware. When the client is
  on a DFS channel wiplex keeps the AP down and pins the uplink to the strongest
  **non-DFS** BSSID of the same SSID (with a cooldown), then brings the AP up.
- A 5 GHz AP is often blocked by regulatory rules (`NO-IR`) on Intel cards using
  LAR. See **[kernel/README.md](kernel/README.md)** for the optional fix.
- **Never disconnect the WiFi client while an AP interface exists** — on some
  Intel firmware this crashes and can knock the card off the PCIe bus. wiplex
  always removes the AP interface *before* it touches the client.

wiplex is a **router**, not a bridge: the AP subnet is separate and NATed, so
AP clients do not appear on the upstream LAN.

---

## Requirements

- Linux with systemd.
- `hostapd`, `dnsmasq`, `nftables`, `iw` (the installer installs these).
- A WiFi driver that supports concurrent AP + managed interfaces.
  Check with `tools/diagnose.sh`.
- An uplink: a WiFi client connection, or a wired connection.

---

## Quick start

```sh
sudo ./install.sh                 # installs packages + files, enables the unit
sudoedit /etc/wiplex.conf         # set SSID / PSK / COUNTRY / subnet
sudo systemctl start wiplex
systemctl status wiplex
```

Then connect a device to the SSID you configured. It should receive an address
in the AP subnet, with the gateway (and, in the default mode, DNS) at `AP_IP`.

Run `sudo tools/diagnose.sh` first if you are unsure whether your card supports
this at all.

---

## Configuration — `/etc/wiplex.conf`

After editing the file, apply changes with:

```sh
sudo systemctl reload wiplex     # re-reads config, restarts dnsmasq + hostapd
sudo systemctl restart wiplex    # full reset (needed if you change interfaces)
```

| Key | Default | Meaning |
| --- | --- | --- |
| `WIFI_IF` | auto | WiFi radio used for the AP/client. Auto = the WiFi interface on the default route. |
| `AP_IF` | `<WIFI_IF>ap` | AP interface name (max 15 chars). |
| `ETH_IF` | auto | Wired uplink. Auto = the wired interface carrying the default route. |
| `SSID` | `wiplex` | AP SSID. |
| `PSK` | – | WPA2 passphrase. Empty = open network. |
| `COUNTRY` | empty | ISO alpha-2 code for the regulatory domain. Empty = leave as-is. |
| `AP_BAND` / `AP_CHANNEL` | `5` / `36` | Fixed band/channel for **wired** mode (must be non-DFS). |
| `AP_IP` / `AP_CIDR` / `AP_NET` | `192.168.50.1` … | Gateway address and subnet. |
| `DHCP_START` / `DHCP_END` | `.100` / `.200` | DHCP pool. |
| `DHCP_MASK` / `DHCP_LEASE` | `255.255.255.0` / `12h` | DHCP mask and lease time. |
| `IPV6_MODE` | `off` | `off`, `nat66`, or `routed` — see [IPv6 for AP clients](#ipv6-for-ap-clients). |
| `AP_IP6` | first address in prefix | IPv6 gateway address on the AP. |
| `AP_PREFIX6` | – | `/64` advertised to clients (required for `nat66`/`routed`). |
| `DNS_IP6` | `AP_IP6` | IPv6 DNS handed to clients. |
| `DNS_MODE` | `dnsmasq` | `dnsmasq` = serve DNS on `AP_IP`; `external` = DHCP only. |
| `DNS_IP` | `AP_IP` | DNS handed to clients in `external` mode. |
| `DNS_PORT` | `53` | dnsmasq DNS port (`dnsmasq` mode). |
| `AVOID_DFS` | `yes` | In WiFi-share mode, move the uplink off DFS channels automatically. |
| `DFS_COOLDOWN` | `90` | Minimum seconds between DFS-avoidance attempts. |
| `FREE_RADIO_ON_WIRED` | `yes` | Disconnect the WiFi client on a wired uplink (AP gets a fixed channel). |
| `STUCK_TIMEOUT` | `45` | Clear a stuck BSSID pin after this many seconds. |
| `UPLINK_CONN` | empty | Fix a specific NM connection for the uplink; empty = auto-detect. |

### Uplink modes (hybrid)

- **Wired present** (`ETH_IF` up with an address, or the default route is wired):
  wiplex removes the AP interface, disconnects the WiFi client (unless
  `FREE_RADIO_ON_WIRED="no"`), and runs the AP on `AP_BAND`/`AP_CHANNEL` with NAT
  out the wired interface.
- **No wired uplink (duplex):** the WiFi client is the uplink; the AP follows
  the client's channel, restarting hostapd on roam. On a **DFS** channel the AP
  stays down and the uplink is pinned to the strongest non-DFS BSSID.

Switching between the two is automatic. wiplex always tears the AP down before
changing the client, which is required for stability on some Intel firmware.

### DNS modes

- `dnsmasq` (default): wiplex runs dnsmasq with DNS on `AP_IP`, forwarding to
  the machine's resolvers. Self-contained — use this on most systems.
- `external`: another resolver already owns `:53` (systemd-resolved, unbound, a
  proxy, ...). wiplex runs DHCP only and hands clients `DNS_IP`.
  `tools/diagnose.sh` shows what owns `:53`.

### IPv6 for AP clients

`IPV6_MODE` controls IPv6 on the AP:

- `off` (default) — IPv4 only.
- `nat66` — clients receive addresses from `AP_PREFIX6` by SLAAC and are
  NAT66'd to the host's uplink address. Use a ULA (for example
  `fd42:9977:79:2::/64`) for `AP_PREFIX6`. The host needs a global IPv6
  address on its uplink (native IPv6, WireGuard, another tunnel).
- `routed` — clients receive global addresses from `AP_PREFIX6` and are routed
  without NAT. The upstream must already route the prefix to this host (a VPS
  `/64`, DHCPv6-PD, ...). Do not also assign the same `/64` to the tunnel
  interface; give the tunnel a `/128` and route the AP prefix to the host.

Both modes use SLAAC (`ra-stateless` in dnsmasq), because Android does not
implement DHCPv6. `AP_PREFIX6` must be a `/64`. The AP gateway is `AP_IP6`
(default: first address, `::1`).

wiplex also enables IPv6 forwarding and installs a TCP MSS clamp for forwarded
traffic, so a tunnel with a 1420-byte MTU (WireGuard) or smaller works behind
the 1500-byte AP. If WireGuard is configured with `AllowedIPs = ::/0`, wg-quick
adds its own clamp; having both is harmless.

Example (NAT66 over a WireGuard uplink that provides global IPv6):

```sh
IPV6_MODE="nat66"
AP_IP6="fd42:9977:79:2::1"
AP_PREFIX6="fd42:9977:79:2::/64"
```

Check on the host:

```sh
ip -6 addr show dev wlan0ap
sysctl net.ipv6.conf.all.forwarding
nft list table ip6 wiplex       # nat66 only
```

Check on a client: it should have an address from the prefix and a default
route learned from RA, and `curl -6 https://ifconfig.co` should work.

---

## Operating

```sh
systemctl start|stop|restart|reload wiplex
systemctl status wiplex
journalctl -u wiplex -f            # service log
tail -f /run/wiplex-hostapd.log    # AP (hostapd)
tail -f /run/wiplex-dnsmasq.log    # DHCP/DNS (dnsmasq)
nft list table ip wiplex           # IPv4 NAT rules
nft list table ip6 wiplex          # IPv6 NAT66 rules (NAT66 mode)
nft list table inet wiplex         # forwarded-traffic MSS clamp
iw dev                             # interfaces
```

**Uplink changes need no manual action.** Reconnecting to the upstream WiFi, or
roaming to another channel/BSSID, is handled automatically. A `reload` is only
needed after editing `/etc/wiplex.conf`; a `restart` is needed if you change
`WIFI_IF` or `AP_IF`.

---

## Troubleshooting

**hostapd: `not allowed for AP mode ... NO-IR` (5 GHz).**
The regulatory domain blocks 5 GHz AP. Set `COUNTRY` and/or apply the
[kernel tweak](kernel/README.md) for Intel LAR cards.

**hostapd: `Device or resource busy` / `EBUSY`.**
The AP tried to use a different channel than the STA. wiplex handles this
automatically by following the STA channel; if you see it during manual
testing, start the AP on the STA's current channel.

**Client connects but gets no IP.**
Check `tail /run/wiplex-dnsmasq.log`. If DHCP fails to bind, another DHCP server
may be running, or the AP interface address is missing (`ip -brief addr`).

**Client gets an IP but no DNS.**
In `dnsmasq` mode, `:53` must be free on `AP_IP`. If something already owns
`*:53`, switch to `DNS_MODE="external"` and set `DNS_IP` accordingly.

**Client gets an IP but no internet.**
Verify `sysctl net.ipv4.ip_forward` is `1`, that `nft list table ip wiplex`
shows the masquerade rule, and that `UPSTREAM_IF` matches the real default-route
interface (`ip route show default`).

**Client gets IPv4 but no IPv6.**
Set `IPV6_MODE` and check `sysctl net.ipv6.conf.all.forwarding` is `1`,
`ip -6 addr show dev wlan0ap` has `AP_IP6`, and (in `nat66` mode)
`nft list table ip6 wiplex` shows the masquerade rule. On the client, check it
received an address from `AP_PREFIX6` and a default route from RA. For a routed
prefix, verify the upstream really routes `AP_PREFIX6` to this host.

**Service restart-loops.**
Run `sudo /usr/local/bin/wiplex` in the foreground to see the error, and check
`tools/diagnose.sh`.

**AP stays down / uplink on a DFS channel.**
wiplex keeps the AP down while the client is on a DFS channel and auto-pins the
uplink to the strongest non-DFS BSSID (log: `DFS chN: pinning to non-DFS ...`).
If there is no non-DFS alternative it logs `no non-DFS alternative found` and
retries after `DFS_COOLDOWN`. You can pin manually with
`nmcli connection modify "<conn>" 802-11-wireless.bssid <non-DFS BSSID>`.
Non-DFS 5 GHz channels are 36–48 and 149–165 (region dependent).

**WiFi client stuck "connecting", or the card disappears.**
On some Intel firmware, disconnecting the client while an AP interface exists
crashes the firmware and can remove the card from the PCIe bus (a reboot is then
required). wiplex avoids this by deleting the AP interface *before* any client
change. If it still happens, prefer a wired uplink or set
`FREE_RADIO_ON_WIRED="no"`.

**Suspend/resume.**
The radio is re-initialised on resume. wiplex installs a sleep hook
(`/usr/lib/systemd/system-sleep/wiplex`) that stops the service on suspend and
starts it on resume. If the radio is still unhappy, reload the driver:
`modprobe -r iwlmvm iwlwifi && modprobe iwlwifi iwlmvm`.

---

## Optional kernel tweak (Intel + LAR)

Some Intel cards (LAR firmware) keep 5 GHz locked as `NO-IR` even after setting
a country. A small patch to `iwlwifi`/`iwlmvm` makes the wiphy follow the normal
regulatory database. It must be rebuilt after each kernel upgrade.

See **[kernel/README.md](kernel/README.md)**.

---

## Uninstall

```sh
sudo ./uninstall.sh              # KEEP_CONFIG=1 to keep /etc/wiplex.conf
sudo ./kernel/restore-iwlwifi.sh # only if you applied the kernel tweak
```

---

## Layout

```
wiplex/
├── bin/wiplex                       # the manager (installed to /usr/local/bin/wiplex)
├── etc/wiplex.conf.example          # config template (installed to /etc/wiplex.conf)
├── systemd/                          # unit + suspend/resume sleep hook
├── kernel/                          # optional Intel iwlwifi LAR patch + build/restore
├── tools/diagnose.sh                # read-only capability/regulatory checks
├── install.sh
└── uninstall.sh
```

## License

MIT — see [LICENSE](LICENSE).
