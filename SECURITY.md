# Security policy

MagicLogi runs in the background with sensitive macOS permissions (*Input
Monitoring*, and *Accessibility* when a button is remapped). Security reports
are welcome and taken seriously.

## Supported versions

Only the latest release receives fixes. Update before reporting.

| Version | Supported |
|---|---|
| 1.0.x (latest release) | Yes |
| Older, or unreleased builds | No |

## Reporting a vulnerability

**Please do not open a public issue.** Report privately through GitHub:

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe:
   - the version (`magiclogictl version`) and your macOS version;
   - what an attacker can do, and under which conditions (local user, another
     app, a modified file, a malicious Bluetooth device…);
   - the steps to reproduce, or a proof of concept.

You get an acknowledgement, usually within a week (one-person project). The
issue is confirmed or explained, fixed in a new release and published with a
GitHub security advisory; you are credited unless you prefer not to be. Please
give a reasonable time to fix the issue before disclosing it publicly.

## Scope

In scope: the agent (`magiclogid`) and the control command (`magiclogictl`);
the install and uninstall scripts and the disk image's installer apps; the
release chain (signing, notarization, the installer's signature check).

Out of scope: macOS itself, the mouse firmware, third-party tools, and attacks
that require administrator rights or full control of the user's account.

## What the tool promises

- **No network access**, no telemetry, no update checks, no data collection.
- **Never runs as root**; installs for the current user only.
- **Keystrokes are never recorded**: only the MX Anywhere 2S is opened (never
  a keyboard), and its reports other than HID++ are discarded on their first
  byte, never copied, stored or logged.
- **No event tap, no exclusive access**: events of other devices never pass
  through the agent.
- **Fails safe**: an invalid configuration leaves the mouse unchanged; without
  Accessibility, remapped buttons stay native instead of going silent; on stop
  the buttons are given back to the mouse.
- **Only public, documented Apple APIs**; no kernel or system extension.
- **The disk-image installer refuses** any agent that is not signed by the
  release team's Developer ID certificate, or that was modified after signing.

Documented choices, not vulnerabilities: see the limitations and the accepted
risk M2 (permissions bound to the signing team) in
[docs/architecture.md](docs/architecture.md).

## Verifying a release

Each release is signed with a Developer ID certificate (team `26N2RN6N67`),
notarized by Apple, and published with its SHA-256 checksum. Git commits and
tags are signed with an SSH key registered on the maintainer's GitHub account
(fingerprint `SHA256:WOf0wdC9u8pRnz0yN8ChPYUA6ttnKWN3SDJwpyD+rWA`); GitHub
shows them as *Verified*.

```bash
shasum -a 256 -c MagicLogi-<version>.dmg.sha256
```

```bash
spctl --assess --type open --context context:primary-signature -v MagicLogi-<version>.dmg
```

The second command must print `source=Notarized Developer ID`. The installed
agent must show `com.jcbaptiste.magiclogi` and `26N2RN6N67`:

```bash
codesign -dv ~/.local/bin/magiclogid 2>&1 | grep -E 'Identifier|TeamIdentifier'
```
