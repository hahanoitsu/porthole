# Porthole

A small Mac app that receives an iPhone's screen and sound over AirPlay and shows them in a
normal window. The window keeps the phone's shape and turns when the phone rotates. Porthole asks
the phone for its screen at its native resolution (HEVC, up to 60 fps) and plays frames back
evenly, holding them only as long as the Wi-Fi needs, with picture and sound kept in step.

## Install

Download the latest `Porthole-<version>.dmg` from the [Releases](../../releases) page, open it, and
drag Porthole to Applications. Porthole needs macOS 14 or later on an Apple silicon Mac. For an
Intel Mac, build it yourself (below).

The releases aren't notarized, so the first time, macOS refuses to open the app: go to System
Settings → Privacy & Security and click **Open Anyway**. macOS then asks whether Porthole may find
devices on the local network. Allow it, or iPhones can't see Porthole. Each new release asks
again.

## Use

On the iPhone, open Control Center, tap **Screen Mirroring**, and choose **Porthole**. The picture
and sound come to the Mac.

The Mac's own AirPlay Receiver can stay on: Porthole uses its own ports and shows up as a
separate entry in the phone's list.

### Window

- **View → Actual Size (⌘1):** one video pixel per screen pixel, or as close as fits.
- **View → Fit to Screen (⌘2):** as large as fits. If that's only slightly bigger than the picture
  (up to 10%), the window stays at one video pixel per screen pixel instead, which is sharper.
- **View → Float on Top (⌘T)**
- Drag anywhere on the picture to move the window. Resizing keeps the phone's aspect ratio, and
  Porthole remembers the size for the next rotation or session.

### Picture

**Resolution.** Porthole tells the phone it has a square 2868×2868 display. The phone scales its
screen to fill that, keeping its shape. A screen 2868 pixels tall therefore arrives at exactly its
native resolution both ways up: an iPhone 17 Pro Max sends 1320×2868 upright and 2868×1320 on its
side. Smaller screens are scaled up slightly. For a pixel-exact stream, set the display size to
your phone's screen height (see Settings).

**View → Smooth Playback** (on by default). The phone stamps every frame with the moment it should
appear. Showing frames the instant they arrive turns every Wi-Fi delay into a stutter, so Porthole
shows each frame at its stamp plus a delay. The delay is learned continuously:

- It covers how late 99% of the last 3 seconds' frames arrived.
- It rises at once when frames start arriving later.
- It drains at 2% speed, too slowly to see, when they arrive sooner again.
- It never exceeds 150 ms.

On a clean network that's a few milliseconds; on a network that keeps stalling, it grows to the
length of the stalls. Turn Smooth Playback off to show frames the moment they're decoded,
stutters and all.

**View → Frame Rate:** 60 or 30 fps. The phone reads it when it connects, so a change applies the
next time mirroring starts. At 30 fps each frame gets twice the bits, so it's sharper.

### Sound

- **Sound → Mute Sound on This Mac (⇧⌘M)**, or the speaker button at the top right of the window.
  Muting is instant and is remembered between launches.
- The phone's volume buttons control the volume on the Mac.
- iOS only starts sending sound when something on the phone plays audio.
- To listen with AirPods or other headphones, connect them to the Mac. During mirroring the sound
  always comes to the Mac (see the FAQ below).

**Picture and sound stay together.** The phone says when it wants each frame shown and each bit of
sound played, on its own clock:

- Frames carry the time in their header.
- Sound gets it from a sync packet about once a second.

Porthole presents both at those times plus one shared delay, as Apple's receivers do. The delay is
the smallest that nearly all recent frames and sound packets arrive in time for. For sound it also
counts the output device's own delay as macOS reports it.

- **Built-in speakers:** sound fits within the picture's own delay, so nothing waits.
- **Bluetooth headphones:** they add a lot (about 0.16 s for AirPods), so the picture waits that
  much longer while sound plays.
- **When the sound stops:** the picture drains back to its own shorter delay.
- **Muted:** sound isn't waited for.

## Troubleshooting

**The picture stutters or lags.** Every 10 seconds the log has a line like
`Video: 59.6 fps, 9.4 Mbit/s, ...; jitter 3/62/98 ms (median/95%/max); held 96 ms on average, 1 late`.
Jitter is how much later than the quickest frame each one arrived. Above 20–30 ms at the 95% mark,
the network is pausing, and Smooth Playback has to hold frames that much longer.

On a Mac the usual cause is AWDL, the peer-to-peer Wi-Fi behind AirDrop, AirPlay to this Mac,
Handoff, Universal Control and Sidecar. While it's active, the Wi-Fi radio keeps leaving the
network's channel to listen on its own, and anything that arrives meanwhile has to wait. It shows
up as ping spikes of up to about 100 ms at a steady interval:

```bash
ping -i 0.1 -c 300 "$(route -n get default | awk '/gateway/{print $2}')"
```

A healthy link answers in a few milliseconds every time. To see whether AWDL is the cause, turn it
off until the next restart and mirror again:

```bash
sudo ifconfig awdl0 down
```

AirDrop, AirPlay to this Mac, Universal Control and Sidecar stop working while it's down.
`sudo ifconfig awdl0 up` brings it back, and macOS may turn it back on by itself when one of those
features needs it.

**The iPhone doesn't list Porthole.** Check that the Mac and the phone are on the same network and
that Porthole has local network access (System Settings → Privacy & Security → Local Network).

**The picture freezes after a glitch.** The phone sends a full refresh frame only when mirroring
starts or the picture changes shape. If the Mac's decoder ever needs a restart mid-stream, the
picture waits for the next one: rotate the phone or restart mirroring.

## FAQ

**Can the sound stay on the iPhone while the picture goes to the Mac?** Not over AirPlay. During
screen mirroring, iOS insists on sending the sound to the receiver. Everything a receiver can
answer was tried with iOS 27.2:

| Receiver says | Where the sound went | What happened to mirroring |
| --- | --- | --- |
| it has no audio | iPhone | iOS ended it after 59 seconds, every time |
| it has audio, then turns the audio stream down | nowhere | kept going, while the phone retried about 3 times a second |
| it has audio, with AirPlay 2's format list showing no screen audio | nowhere | iOS ended it after 5 seconds |
| it has audio, then refuses the audio stream with an RTSP error | — | failed at once ("Unable to Connect") |
| it has audio, then gives the audio stream no ports | nowhere | iOS ended it after 17 seconds |
| anything, then the sound is moved to the iPhone during mirroring | — | iOS ended it at once, Apple's own receiver in macOS included |

Picture without sound would need a companion iPhone app using iOS's screen-broadcast feature
(ReplayKit), as video-call apps do.

**Why does the iPhone show an Apple TV icon?** Porthole identifies itself as an Apple TV, using
the older AirPlay protocol that open-source receivers use.

**Can two phones mirror at once?** No. A second phone takes over from the first.

## Settings

Besides the menus, these settings take effect on the next launch:

```bash
defaults write local.porthole.Porthole receiverName "Living Room Mac"
defaults write local.porthole.Porthole displayWidth -int 2868    # the display the phone fits its screen into
defaults write local.porthole.Porthole displayHeight -int 2868
defaults write local.porthole.Porthole allowHEVC -bool true
defaults write local.porthole.Porthole pictureOffsetMs -int 20   # show the picture 20 ms later than the sound (negative: earlier)
defaults write local.porthole.Porthole debugLogging -bool true
defaults write local.porthole.Porthole debugSnapshots -bool true  # then: notifyutil -p local.porthole.snapshot
```

The View menu saves Smooth Playback (`smoothPlayback`) and Frame Rate (`maxFPS`) the same way. Set
both display values to the phone's screen height in pixels (its longer side) for a stream at
exactly its native resolution.

## Logs

`~/Library/Logs/Porthole/porthole.log`, plus the last 10 runs as `porthole-<start time>.log`. In
the app: **Porthole → Show Log in Finder**. The log records each step of the connection, the video
format and the window size, and every 10 seconds:

- `Video:` frame rate, bitrate, jitter, how long Smooth Playback held frames, and the phone's frame
  spacing.
- `Display:` frames shown, and frames dropped because a newer one was already due.
- `Audio:` how sound playback coped, and how long after arriving it's heard.

## Building

Needs Xcode or its command line tools, on macOS 14 or later.

```bash
Scripts/build-app.sh
open build/Porthole.app
```

The script signs with an "Apple Development" certificate if one is installed, which lets macOS
remember the local network permission across rebuilds. `UNIVERSAL=1 Scripts/build-app.sh` builds
for Intel Macs too, and `Scripts/make-dmg.sh` packs the app into a DMG and a zip in `build/`.
`swift test` runs the tests.

Every push to `main` builds the app on GitHub Actions (`.github/workflows/release.yml`) and
publishes the DMG and zip as release `v0.1.<build number>`.

## How it works

| Piece | Where |
| --- | --- |
| Bonjour advertising (`_airplay._tcp`, `_raop._tcp`) | `Sources/PortholeCore/BonjourAdvertiser.swift` |
| RTSP control connection: `/info`, pairing, FairPlay, `SETUP`, `TEARDOWN` | `Sources/PortholeCore/AirPlayConnection.swift` |
| Pairing (Ed25519 and X25519 via CryptoKit) | `Sources/PortholeCore/PairingSession.swift` |
| FairPlay handshake (vendored C) | `Sources/CFairPlay` |
| Video stream: 128-byte packet headers, AES-CTR decryption, H.264/HEVC parameter sets | `Sources/PortholeCore/MirrorStreamReceiver.swift`, `VideoStreamFormat.swift` |
| Frame pacing | `Sources/PortholeCore/FramePacer.swift` |
| One schedule for picture and sound | `Sources/PortholeCore/PlayoutClock.swift` |
| Sound: RTP over UDP, AES-CBC per packet, sync packets, AAC-ELD decoding | `Sources/PortholeCore/AudioStreamReceiver.swift`, `AACELDDecoder.swift` |
| Sound output: scheduled playback, mute, volume, device changes | `Sources/PortholeCore/AudioPlayer.swift` |
| Video decoding and display (AVSampleBufferDisplayLayer on the host clock) | `Sources/Porthole/VideoView.swift` |
| Window and menus | `Sources/Porthole/MirrorWindowController.swift`, `AppDelegate.swift` |
| App icon | `Scripts/make-icon.swift`, which writes `Resources/AppIcon.icns` |

The end-to-end tests run a fake iPhone against a real receiver on localhost. It pairs, then
streams H.264 and HEVC video (from VideoToolbox's encoder), AAC-ELD sound (from AudioToolbox's
encoder) and sync packets, encrypted the way an iPhone does it.

## License

Porthole includes PlayFair, a reverse-engineered implementation of the FairPlay handshake that
AirPlay requires, under the GNU GPL. The app as distributed therefore falls under the GPL. See
[NOTICE.md](NOTICE.md) for the third-party code and its sources.
