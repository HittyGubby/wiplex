# wiplex

**WiFi client + access point on a single radio.**

wiplex lets a Linux machine stay connected to a WiFi network *and* broadcast
its own access point at the same time, using **one** WiFi adapter. The AP lives
on its own routed subnet and NATs out to whatever uplink the machine has.

Typical use: a laptop is on a campus/office WiFi, and you want your phone (or
another device) to share that connection through the laptop.

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
- A 5 GHz AP is often blocked by regulatory rules (`NO-IR`) on Intel cards using
  LAR. See **[kernel/README.md](kernel/README.md)** for the optional fix.

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
| `WIFI_IF` | auto | WiFi radio used for the AP. Auto = the WiFi interface on the default route. |
| `AP_IF` | `<WIFI_IF>ap` | AP interface name (max 15 chars). |
| `UPSTREAM_IF` | auto | Interface used for NAT. Auto = default-route interface. |
| `SSID` | `wiplex` | AP SSID. |
| `PSK` | – | WPA2 passphrase. Empty = open network. |
| `COUNTRY` | empty | ISO alpha-2 code for the regulatory domain. Empty = leave as-is. |
| `AP_BAND` / `AP_CHANNEL` | `5` / `36` | Fixed band/channel, used only when there is no STA link to follow (wired uplink). |
| `AP_IP` / `AP_CIDR` / `AP_NET` | `192.168.50.1` … | Gateway address and subnet. |
| `DHCP_START` / `DHCP_END` | `.100` / `.200` | DHCP pool. |
| `DHCP_MASK` / `DHCP_LEASE` | `255.255.255.0` / `12h` | DHCP mask and lease time. |
| `DNS_MODE` | `dnsmasq` | `dnsmasq` = serve DNS on `AP_IP`; `external` = DHCP only. |
| `DNS_IP` | `AP_IP` | DNS handed to clients in `external` mode. |
| `DNS_PORT` | `53` | dnsmasq DNS port (`dnsmasq` mode). |
| `WAIT_FOR_UPLINK_SECS` | `90` | How long to wait for the STA link before using a fixed channel. |

### Uplink modes

- **WiFi uplink (duplex).** `UPSTREAM_IF` is the WiFi client. wiplex waits for
  the client link, then keeps the AP on the client's channel, restarting
  hostapd whenever the client roams.
- **Wired uplink.** The default route is e.g. Ethernet. wiplex starts the AP on
  `AP_BAND`/`AP_CHANNEL` right away; if the WiFi client later connects, the AP
  follows its channel.

### DNS modes

- `dnsmasq` (default): wiplex runs dnsmasq with DNS on `AP_IP`, forwarding to
  the machine's resolvers. Self-contained — use this on most systems.
- `external`: another resolver already owns `:53` (systemd-resolved, unbound, a
  proxy, ...). wiplex runs DHCP only and hands clients `DNS_IP`.
  `tools/diagnose.sh` shows what owns `:53`.

---

## Operating

```sh
systemctl start|stop|restart|reload wiplex
systemctl status wiplex
journalctl -u wiplex -f            # service log
tail -f /run/wiplex-hostapd.log    # AP (hostapd)
tail -f /run/wiplex-dnsmasq.log    # DHCP/DNS (dnsmasq)
nft list table ip wiplex           # NAT rules
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

**Service restart-loops.**
Run `sudo /usr/local/bin/wiplex` in the foreground to see the error, and check
`tools/diagnose.sh`.

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
├── systemd/wiplex.service           # systemd unit
├── kernel/                          # optional Intel iwlwifi LAR patch + build/restore
├── tools/diagnose.sh                # read-only capability/regulatory checks
├── install.sh
└── uninstall.sh
```

## License

MIT — see [LICENSE](LICENSE).
