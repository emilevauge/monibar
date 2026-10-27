# Monibar

A macOS menu bar app that shows the CPU load in a small capsule and, on hover, a panel with CPU, memory, network, disk and the apps that use the most, which you can quit from there. Built to cost next to nothing while it sits in the menu bar.

## Download

Grab `Monibar.dmg` from the [latest release](https://github.com/emilevauge/monibar/releases/latest), open it and drag Monibar onto the `Applications` shortcut. Or from the command line:

```sh
curl -L -o Monibar.dmg \
  https://github.com/emilevauge/monibar/releases/latest/download/Monibar.dmg
hdiutil attach Monibar.dmg
cp -R "/Volumes/Monibar/Monibar.app" /Applications/
hdiutil detach "/Volumes/Monibar"
xattr -dr com.apple.quarantine /Applications/Monibar.app   # not notarized, bypass Gatekeeper
open /Applications/Monibar.app
```

Monibar then updates itself: when a new release is out, a notification offers to install it. The update is installed only if the new app satisfies the installed one's designated requirement (same bundle id, signed with the same certificate); otherwise the installed app stays and is relaunched. The settings menu (gear icon) can also check for one. Requires macOS 14 or later.

## Features

- **CPU chip**: the menu bar icon is a small CPU chip, drawn with Calbar's stroke, whose body fills from the bottom with the load: green under 50 %, orange under 80 %, red above. The load is averaged over a window set in the settings menu (2 s to 60 s). When the Mac is offline or has no Internet access, a crossed-out Wi-Fi shows in the chip, in the outline's color.
- **Hover panel**: resting the pointer on the capsule opens the panel, which closes when the pointer leaves it. A click keeps it open until a click outside or Escape. Same behavior and layout as [Calbar](https://github.com/emilevauge/calbar).
- **CPU**: user, system and GPU load, and a history graph.
- **Memory**: used out of total, split into app, wired and compressed memory, and swap.
- **Network and disk**: read and write rates with mirrored graphs. Disk space: free space, a fill bar (orange under 10 % free, red under 5 %), used out of total.
- **Internet access**: online, no Internet access (a network but no route out, or a captive portal) or offline, beside the network title. Its history tints the network graph: orange where there was no Internet access, red where the Mac was offline. Checked once a minute, on each network change and when the panel opens, with the request macOS uses to detect captive portals.
- **History**: graphs over 1 min, 15 min or 1 h.
- **Top apps**: the 10 apps or processes using the most CPU or memory. Helper processes are grouped under their app (Chrome, Slack...). CPU is averaged over 10 s, 1 min, 1 h or 1 day, so the ranking stays steady.
- **Quit apps**: click the cross, then pick Quit, or Force for an app that hangs (SIGTERM or SIGKILL for a process).
- **What is this?**: hover a row and click the magnifying glass, or right-click it, to search the web for the app or process.
- **English and French**: follows the macOS language. To add a language, translate `Resources/fr.lproj/Localizable.strings` into `Resources/<lang>.lproj/` and list it under `CFBundleLocalizations` in `build.sh`.

## Resource use

With the panel closed, Monibar reads the total CPU load once every 2 s (one Mach call) for the icon. Once a minute, it reads memory, network, disk and GPU for the graphs, checks Internet access (one small HTTPS request), and takes a snapshot of each process's CPU counters (about 1 ms) for the 1 h and 1 day averages. Measured: about 0.03 % of one core and 32 MB of memory. While the panel is open, everything is read every 2 s, and its views are freed when it closes.

Network, disk and CPU come from counters the kernel cumulates since boot: a point taken once a minute is the exact average of that minute, nothing is lost between points. Memory and GPU are readings, so a spike shorter than a minute can fall between two points while the panel is closed.

All history lives in memory and is lost when Monibar quits:

| Data | Kept |
|---|---|
| CPU history | 1 h, one point every 2 s |
| Memory, network, disk, GPU history | 1 h, one point every 2 s with the panel open, every minute with it closed |
| Per-process CPU snapshots | 1 h at one per minute, 24 h at one per 15 min |

The graphs leave a gap where nothing was measured, while the Mac slept for instance.

Processes owned by other users (root daemons) cannot be read without privileges: they are missing from the list but counted in the total CPU.

## Build

```sh
./build.sh            # build/Monibar.app and build/Monibar.dmg
./build.sh --install  # also copies to /Applications and relaunches
```

`./snapshot.sh panel.png [--light]` renders the panel to a PNG, for checking a layout change.

Measuring:

- `MB_BENCH=1 .build/release/Monibar` times each sampling step and quits.
- `MB_CYCLES=40 .build/release/Monibar` opens and closes the panel 40 times off screen, then waits: run `leaks <pid>` to check that nothing grows with the openings.
- `MB_OFFLINE=1 build/Monibar.app/Contents/MacOS/Monibar` keeps the no-Internet alert shown, to check the icon.
- `MB_HOLD=60 .build/release/Monibar --snapshot` keeps an open panel off screen for 60 s, to measure its CPU with `ps -o time`.

## Release

1. Bump `VERSION` and `BUILD` in `build.sh`.
2. `./build.sh`
3. `gh release create vX.Y.Z build/Monibar.dmg --title "Monibar X.Y.Z" --notes "..."`

The updater reads the latest release from the GitHub API and installs its `Monibar.dmg` asset.

## License

MIT
