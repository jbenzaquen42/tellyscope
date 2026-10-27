# TCL Smart TV Pro G05 US, AR71

Read-only inspection on 2026-10-27 identified this TV as:

| Property | Observed value |
|---|---|
| Manufacturer / brand | TCL / TCL |
| Model | Smart TV Pro |
| Device / product | G05 / G05_4K_US |
| Board / platform | C05 / mt5889 |
| Android / SDK | 11 / 30 |
| Build display / incremental | AR2101 / AR71 |
| Security patch | 2025-03-05 |
| Current Home | com.google.android.apps.tv.launcherx/.home.HomeActivity |

The inspection found 153 packages, 129 classified as system packages, and no disabled packages. No apps were disabled, stopped, uninstalled or installed, and no TV settings were changed. The retail model was not reported; this does not establish a particular screen size or retail SKU. Private identifiers, connection addresses and the owner's personal app inventory are not included in this profile.

Storage, CPU/memory and process commands returned usable data. No valid temperature value was exposed through the app's thermal read, so temperature remains unavailable.

## Profile behavior

The bundled `tcl-g05-us-ar71` profile requires TCL, Smart TV Pro, G05, G05_4K_US, incremental AR71 and SDK 30 together. AR68 and other regional products do not automatically match. The profile remains available offline and is combined with the community lists.

The 29 optional suggestions come from the pinned G05 community list and were confirmed installed during inspection. Every suggestion remains unselected: inventory inspection does not qualify the effects of disabling an app. The `tested.sdk` value stays null for that reason. Package notes explain loss of voice search, casting, AirPlay, ambient mode, USB media playback and other optional features where applicable.

The profile preserves 18 packages for the launcher, setup/Wi-Fi recovery, firmware updates, Input button, HDMI/tuner playback, settings, remote pairing, accessibility and unqualified vendor dependencies. These bundled keep rules also protect the Apps screen's disable, stop and uninstall paths. They conservatively apply wherever these package names occur; switching Home remains a separate explicit workflow with verification and rollback.

Important G05 details from the pinned upstream report:

- `com.tcl.ttvs` also contains the firmware updater on AR71, so it stays protected despite its analytics functions.
- `com.tcl.suspension` provides Quick Panel and the physical remote's Input button.
- `com.google.android.tungsten.setupwraith` can own the saved Wi-Fi configuration. It stays protected; this app does not migrate or forget networks.
- The upstream report says firmware can re-enable TCL account and Alexa packages after reboot. Those suggestions describe that limit.

## Sources and limits

The package choices and firmware caveats derive from [cleanyourtv's G05 notes at commit 575d73f](https://github.com/Gathin23/cleanyourtv/blob/575d73f0f30c329aa7ebaea2bc863943fd9bf7f9/examples/tcl-g05-google-tv/debloat.txt), with the MIT notice retained in the root `NOTICE`. The app-readable starting list is [tellyscope-devices' G05 profile](https://github.com/man15h/tellyscope-devices/blob/main/devices/tcl-g05-google-tv.json). Actual identity, installed candidate presence and Home were independently read from the TV.

Disabling, restoring, firmware updates, reboot persistence and launcher replacement were not tested on this TV. A different firmware needs its own review. Unknown vendor packages and the owner's other apps were not turned into removal suggestions.
