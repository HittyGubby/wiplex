# Optional kernel tweak: Intel `iwlwifi` + LAR

This is **only needed for some Intel WiFi cards** and only when the userspace
part of wiplex cannot start a 5 GHz AP.

## The problem

Recent Intel cards use **LAR** (Location Aware Regulatory). When LAR is
supported, the `iwlmvm` driver marks its wiphy `REGULATORY_WIPHY_SELF_MANAGED`
(`drivers/net/wireless/intel/iwlwifi/mvm/mac80211.c`). A self-managed wiphy
ignores the normal regulatory database and user hints such as
`iw reg set <CC>`; it uses whatever the firmware reports.

On many systems the firmware ends up at the world domain (`country 00`), where
**all 5 GHz channels are `NO-IR`**. `NO-IR` means "no initiating radiation",
i.e. you may not run an access point. Result:

```
hostapd: Frequency 5745 (primary) not allowed for AP mode, flags: 0x60853 NO-IR
```

The `lar_disable` module parameter that used to work around this **no longer
exists** in current kernels.

## How the patch fixes it

`iwlwifi-lar-disable.patch` removes the self-managed / custom-regulatory flags
and disables the runtime LAR regdomain update, so the wiphy follows the normal
cfg80211 regulatory domain. With a proper country set (e.g. `COUNTRY="US"` in
`/etc/wiplex.conf`), 5 GHz `NO-IR` channels become usable and hostapd can start.

## Do you need it?

Run `tools/diagnose.sh`. You need this patch if **both**:

1. `iw reg get` shows a `self-managed` phy (Intel LAR), **and**
2. an AP cannot start on your 5 GHz channel (`NO-IR`), even after setting a
   country with `iw reg set <CC>`.

## Apply

```sh
sudo ./build-iwlwifi-lar.sh
# then reload the driver (drops wifi briefly) or reboot:
sudo modprobe -r iwlmvm iwlwifi && sudo modprobe iwlwifi && sudo modprobe iwlmvm
```

Set `COUNTRY` in `/etc/wiplex.conf` and reload wiplex.

## Revert

```sh
sudo ./restore-iwlwifi.sh
```

## Caveats

- **Re-run `build-iwlwifi-lar.sh` after every kernel upgrade** — the package
  manager replaces the modules and your patched ones are gone.
- It compiles `iwlwifi.ko` and `mvm/iwlmvm.ko`. `CONFIG_MODULE_SIG_FORCE=y`
  kernels will reject the unsigned build; check your kernel config.
- Other vendors (Atheros, Broadcom, MediaTek, ...) use different mechanisms.
  This patch is Intel-specific.
- Even with the patch, some Intel firmware may still refuse certain channels;
  test before relying on it.
