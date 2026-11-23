# MagicLogi

**A minimal replacement for Logi Options+ for the Logitech MX Anywhere 2S, connected directly over Bluetooth, on macOS.**

MagicLogi is a tiny background agent with no window and no menu-bar icon. It
sets the mouse itself (DPI, wheel direction) and gives its buttons the actions
you choose, including the Options+ gesture button. No account, no network, no
telemetry, no automatic updates, no administrator rights.

*Not affiliated with or endorsed by Logitech. "Logitech", "Logi Options+" and
"MX Anywhere" are trademarks of their owner, used only to describe compatibility.*

> Français : [docs/README.fr.md](docs/README.fr.md)

| Feature | How | Verified on the device |
|---|---|---|
| Pointer resolution, 200–4000 DPI | set inside the mouse (HID++) | yes |
| Wheel direction for the mouse only | set inside the mouse; the trackpad is untouched | yes |
| Side buttons, button behind the wheel, wheel tilt | native, or remapped (shortcut, Mission Control, spaces, buttons 4/5…) | yes |
| Gesture button | short click = middle click; hold and move: previous/next space, Mission Control, app windows; gestures chain while held | yes |
| Horizontal scrolling | native (wheel tilt) | yes |
| Reconnection, mouse switched off and on | settings re-applied automatically (~1 s) | yes |
| Battery | read and logged, `magiclogictl status` | yes |

One model only: `046D:B01A` over direct Bluetooth (no Unifying receiver). No
other device is ever opened or changed: keyboards and trackpads are ignored.

## Install

macOS 13 or later, Apple silicon. Pick **one** way; both install the same
files for your user account only.

**Disk image (easiest).** Download `MagicLogi-<version>.dmg` from the
[Releases page](https://github.com/phocean/MagicLogi/releases), open it,
double-click **Install MagicLogi** and click **Continue** until it says *All
permissions granted*. Everything on the image is signed with a Developer ID
certificate and notarized by Apple.

**From source** (needs Xcode or its command line tools):

```bash
git clone https://github.com/phocean/MagicLogi.git
```

```bash
cd MagicLogi && make install
```

Then grant the permissions, in **System Settings > Privacy & Security**:

1. **Input Monitoring** → `magiclogid`: always needed. Over Bluetooth the
   mouse is a single HID device whose primary usage is *keyboard*; macOS
   refuses to open it without this permission.
2. **Accessibility** → `magiclogid`: only if you remap a button. Without it,
   remapped buttons simply stay native.

`magiclogictl permissions` restarts the agent, reports both and opens the
first missing one.

## Configure

Edit `~/.config/magiclogi/config.toml` (fully commented example:
[config/config.example.toml](config/config.example.toml)), then:

```bash
magiclogictl reload
```

A setup close to Options+:

```toml
[pointer]
dpi = 1200

[scroll]
invert = false         # true = reverse the mouse wheel only

[buttons]
middle = "gestures"    # button behind the wheel = gesture button
back = "back"
forward = "forward"

[gestures]
click = "middle-click"
left = "space-left"
right = "space-right"
up = "mission-control"
down = "app-expose"
threshold = 130
```

A missing key leaves that setting of the mouse alone. An invalid file is
rejected as a whole (`magiclogictl check` shows the faulty line): at startup
the mouse is left unchanged, on reload the previous configuration is kept.
Named actions such as `mission-control` send **your** current macOS shortcut;
`keys:` shortcuts follow **your** keyboard layout (AZERTY included).

## Commands

| Command | Effect |
|---|---|
| `magiclogictl status` | state, battery, DPI, remapped buttons, permissions, conflicting Logitech software |
| `magiclogictl permissions` | restart, report and open missing permissions |
| `magiclogictl reload` | re-read the configuration |
| `magiclogictl start` / `stop` / `restart` | control the agent |
| `magiclogictl log [minutes]` | log (Unified Logging, subsystem `com.jcbaptiste.magiclogi`) |
| `magiclogictl diag` | read-only HID++ report (features, DPI, controls, battery) |
| `magiclogictl events [s] [--divert]` | show what the buttons and wheel send |
| `magiclogictl reset` | native buttons, no inversion, factory DPI (agent stopped) |

## If the buttons stop responding

**Leftover Logitech software.** *Logi Plugin Service*, installed by Logi
Options+ in `/Applications/Utilities` and left behind when Options+ is
uninstalled, connects to the mouse each time the display turns on and takes
the remapped buttons over: they go silent. MagicLogi reports it in
`magiclogictl status` (`conflicts=…`), its log and the installer. Remove it
(administrator password):

```bash
sudo rm -rf /Applications/Utilities/LogiPluginService.app "/Library/Application Support/Logi"
```

```bash
sudo pkgutil --forget com.logi.installer.pluginservice.package
```

```bash
sudo pkgutil --forget com.logi.installer.pluginservice.media.package
```

Then `magiclogictl restart`. Uninstall Logi Options+ itself too, with its own
uninstaller.

**Agent killed.** `launchd` restarts it in under a second and it takes over
again. Last resort: switch the mouse off and on, or `magiclogictl reset`.

## Uninstall

Double-click **Uninstall MagicLogi** on the disk image, or `make uninstall`
(add `--purge` to `scripts/uninstall.sh` to also delete the settings). The
agent gives the buttons back to the mouse when it stops; DPI and wheel
direction stay in the mouse until it is switched off and on, or
`magiclogictl reset`.

## How it works, in short

- It **configures the mouse instead of intercepting events**: no event tap,
  no exclusive access. A button is taken over (HID++ "diversion") only if you
  remap it; the mouse then stops sending its native event, so there are no
  duplicates and nothing else is filtered.
- One process, one thread, event-driven: **0.0 % CPU and 1 wake-up per minute
  at rest**, about 5 MB of memory.
- A diversion survives a crash of the agent (verified): `launchd` restarts it
  in under a second and it takes over again; a clean stop gives the buttons
  back. Last resort: switch the mouse off and on.

## Privacy and security

No network access, no data collection, never runs as root, public Apple APIs
only. Mouse reports other than HID++ are dropped on their first byte, never
copied, stored or logged; keyboards are never opened. See
[SECURITY.md](SECURITY.md) and the permission and attack-surface analysis in
[docs/architecture.md](docs/architecture.md#4-permissions-et-surface-dattaque).

## Documentation

- [docs/etude-faisabilite.md](docs/etude-faisabilite.md) — feasibility study, evidence, HID++ feature matrix (French)
- [docs/architecture.md](docs/architecture.md) — architecture, permissions, verified limitations, tests and measurements (French)

## Credits and license

Free software under the **GNU GPL v3.0 or later** ([LICENSE](LICENSE)). No
third-party code: only HID++ protocol knowledge from Solaar, OpenLogi and
logiops (thanks to their authors).
