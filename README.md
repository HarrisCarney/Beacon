# Beacon

A tiny macOS menu bar app that detects when you're on a call and reports it to
Home Assistant, so you can drive an "on air" light, mute a smart speaker, or
anything else off your call state.

## How detection works

Beacon watches a public Core Audio property,
`kAudioDevicePropertyDeviceIsRunningSomewhere`, on the default input device.
That flag flips the instant any app starts or stops using the microphone. No
polling, and no microphone permission prompt — Beacon reads device *state*, never
audio.

Two things worth knowing:

- **It fires for any mic use**, not just calls: dictation, Voice Memos, and
  QuickTime recordings all count.
- **Core Audio flaps the flag** while a device spins up (an app opening the mic
  can produce on/off/on inside a single second). Beacon debounces — 0.75 s before
  reporting "on", 3 s before "off" — so Home Assistant sees one clean transition
  and switching between two mic apps doesn't produce a false "off".

## The app

- Menu bar only, no Dock icon (`LSUIElement`). Click the icon for the panel.
- Status dot: 🟢 idle / 🔴 on a call / ⚪️ disabled. The menu bar icon mirrors it
  (`mic` / `mic.fill` / `mic.slash`).
- **Enabled** toggle pauses webhook sending without quitting. Turning it off
  sends a final `off` so Home Assistant isn't left stuck on.
- **Launch at login** via `SMAppService` — no separate LaunchAgent.
- Webhook URL field, saved as you type, with a delivery status line underneath
  so a wrong URL or a 404 is visible instead of failing silently.
- Quitting while on a call sends a final `off` too.

Beacon POSTs this to your webhook on every settled transition:

```json
{ "state": "on", "timestamp": "2026-09-03T00:38:30Z" }
```

## Home Assistant setup

1. **Create the helper.** Either add the `input_boolean` block from
   [`homeassistant/configuration.yaml`](homeassistant/configuration.yaml) and
   restart HA, or make it in the UI: *Settings → Devices & Services → Helpers →
   Create Helper → Toggle*, named **On a call**.

2. **Create the automation.** Copy the first automation from
   [`homeassistant/automations.yaml`](homeassistant/automations.yaml). **Change
   `webhook_id` from `beacon_on_air_CHANGE_ME` to something only you know** — the
   webhook ID is the only secret protecting the endpoint.

3. **Point Beacon at it.** Paste this into Beacon's URL field, substituting your
   webhook ID:

   ```
   http://homeassistant.local:8123/api/webhook/your_webhook_id
   ```

   The status line under the field turns into "Last delivered …" on success.
   The automation ships with `local_only: true`, so the Mac must be on the same
   network as HA — set it to `false` if you're going over Nabu Casa or a
   reverse proxy.

4. **Use `input_boolean.on_a_call`** in whatever automations you like. There's a
   worked example (an on-air light) as the second automation in that file.

## Building

Open `Beacon.xcodeproj` and run. Requires macOS 14+. Sparkle is pulled in via
Swift Package Manager and resolves automatically.

> **iCloud gotcha.** This repo lives in `~/Documents`, which iCloud Drive syncs.
> The file provider stamps `com.apple.FinderInfo` on every bundle it touches, and
> `codesign` rejects that with *"resource fork, Finder information, or similar
> detritus not allowed"* — and `xattr -c` can't strip it, because iCloud puts it
> straight back. `release.sh` therefore builds into `$TMPDIR`, outside the synced
> folder. If you ever build a signed Release by hand, pass a `-derivedDataPath`
> outside `~/Documents` too.

## Cutting a release

`release.sh` does the whole thing: builds (ad-hoc signed by Xcode, inside-out, so
Sparkle's XPC services stay valid), zips, signs the update with your Sparkle EdDSA
key, and inserts the `<item>` into `appcast.xml`.

```bash
./release.sh 1.1 3            # build + sign + update appcast.xml
./release.sh 1.1 3 --publish  # ...and create the GitHub release and push
```

The **build number** (second argument) is what Sparkle compares — it must
increase on every release, even if the marketing version doesn't.

### First release

Sparkle can only *update* an installed app, so v1.0 has to be handed out by hand:

```bash
gh repo create Beacon --public --source=. --remote=origin --push
./release.sh 1.0 1 --publish
```

Then send people the `Beacon-1.0.zip` URL from the GitHub release. From v1.1 on,
`./release.sh 1.1 2 --publish` is the entire process — installed copies pick it up
on their next daily check, or immediately via **Check for Updates…**.

Note the feed is `raw.githubusercontent.com`, so the repo must be **public** for
Sparkle to read `appcast.xml` (a private repo's raw URLs need an auth token).

The script needs Sparkle's CLI tools in `Tools/bin/`. They're gitignored (~12 MB
of binaries); re-download them with:

```bash
curl -sSL -o /tmp/sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
tar -xJf /tmp/sparkle.tar.xz -C . bin && mv bin Tools/bin
```

### Auto-update wiring

Already configured in the project:

| Key | Value |
|---|---|
| `SUFeedURL` | `https://raw.githubusercontent.com/HarrisCarney/Beacon/main/appcast.xml` |
| `SUPublicEDKey` | `HkC/XgCYONyQR6ni/kILKqX81qptTqRg0BTjp+8Ne6M=` |
| `SUEnableAutomaticChecks` | `YES` |
| `SUScheduledCheckInterval` | `86400` (daily) |

The matching **private key lives in your login Keychain** (item: "Private key for
signing Sparkle updates"). It is not in this repo and cannot be regenerated — if
you lose it, existing installs can never be updated again. Back it up:

```bash
./Tools/bin/generate_keys -x beacon-sparkle-private-key.txt   # then store it somewhere safe
```

### Gatekeeper, honestly

Sparkle's EdDSA signature proves an update is authentic and untampered, and that
works regardless of Apple code signing. But macOS *separately* quarantines
anything downloaded from the internet. Without a paid Apple Developer ID ($99/yr)
for signing and notarization, each install needs one manual approval —
right-click → Open, or *System Settings → Privacy & Security → Open Anyway*.
Releases here are ad-hoc signed, which is why that prompt appears.

If you get a Developer ID later, edit `release.sh` to swap `CODE_SIGN_IDENTITY="-"`
for your identity, then notarize before zipping:

```bash
codesign --force --deep --options runtime \
  --sign "Developer ID Application: Your Name (TEAMID)" Beacon.app
xcrun notarytool submit Beacon-1.1.zip --keychain-profile "notary" --wait
xcrun stapler staple Beacon.app
```

Updates then install with no prompts at all.
