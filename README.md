# Tactus

**Haptics for the Mac trackpad.** Tactus turns your MacBook's Force Touch trackpad into a haptic display you feel through your fingertip. It plays window snaps, scroll notches, the controls under the pointer, a song's beat, a game's explosions, and the texture of an image.

*Tactus* is Latin for touch, and in early music it is the beat a conductor marks by hand.

It is a modular framework. A small core drives the trackpad's haptic motor, and modules decide what to play:

| Module | What you feel | For |
|---|---|---|
| **signals** | Window snaps, scroll ticks, drag and drop, button hover (like the 2026 Surface Mouse's haptic signals) | Everyone |
| **access** | A different feel for each kind of control under the pointer or in keyboard focus, window and screen edges, and on-screen content as texture | Blind and low-vision users |
| **music** | MIDI clock beats and downbeats, drum hits, notes as pulses, a metronome | Producers, performers, deaf and hard-of-hearing musicians |
| **games** | Rumble from any game's audio, with no changes to the game, plus effects to try | Players |
| **bridge** | Lets any program send haptics over UDP or OSC: games, Max, Pure Data, scripts | Developers and artists |
| **texture** | A window where you feel an image | Experiments, low-vision exploration |

> **Heads up:** Apple doesn't offer a public way to play custom vibrations on the trackpad, so Tactus uses a private macOS framework (MultitouchSupport), as [nospeaker](https://github.com/os6/nospeaker) does. That framework is undocumented, so a macOS update could break Tactus, and apps built on it can't go on the Mac App Store. Tactus never drives the motor past its normal maximum strength.

## Requirements

- A Mac with a Force Touch trackpad: a MacBook from 2015 or later, or a Magic Trackpad 2 or newer (use `--external` for a Magic Trackpad)
- macOS 14 or later
- Xcode or the Command Line Tools (`xcode-select --install`)

Developed and tested on macOS 27 with Swift 6.4, on an Apple Silicon MacBook.

## Get started

```sh
git clone https://github.com/drquandary/tactus.git
cd tactus
swift build -c release
.build/release/tactus selftest        # rest a finger on the trackpad: you should feel a bump each second
.build/release/tactus                 # start the menu bar app (the hand icon)
```

Rest a finger on the trackpad. By default Tactus only plays while a finger is on the pad, since vibration with no finger on it can only be heard, not felt.

### Permissions

Some modules read other apps' windows and controls, or listen to system audio. macOS asks for permission for the app you run Tactus from (for example Terminal):

- **Accessibility:** signals (window snapping, button hover) and access. Turn it on in System Settings > Privacy & Security > Accessibility.
- **Screen & System Audio Recording:** games (audio rumble) and access (screen texture). This is how macOS lets an app hear system audio or see the screen. Tactus doesn't save or send anything it captures.

Each module's menu offers to grant whatever is missing. After granting, quit Tactus and start it again.

## Commands

```
tactus                      menu bar app, with the modules you had on last time (signals, music, bridge at first)
tactus run access music     menu bar app with just these modules
tactus texture [image]      feel an image in a window
tactus send play bump 0.8   send a command to a running Tactus
tactus patterns             list the named patterns
tactus modules              list the modules
tactus selftest             check the motor and finger detection

--external   use a Magic Trackpad instead of the built-in one
--always     play even with no finger on the trackpad (for keyboard users, or testing)
--verbose    print every command received and everything played
--port <n>   bridge port (default 7477)
```

## Send haptics from your own program

Send UDP to `127.0.0.1:7477`, as text, JSON or OSC:

```sh
tactus send play heartbeat
echo 'hold engine 60 0.5 250' | nc -u -w0 127.0.0.1 7477
```

```python
import socket
socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"play explosion 0.8", ("127.0.0.1", 7477))
```

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for every command, and [examples/](examples/) for Python, Godot, Unity, MIDI, Max and Pure Data.

## Documentation

- [docs/MODULES.md](docs/MODULES.md): what each module does and its options
- [docs/PROTOCOL.md](docs/PROTOCOL.md): the bridge protocol and the pattern format
- [docs/WRITING_A_MODULE.md](docs/WRITING_A_MODULE.md): add your own module, or use TactusCore in your own app

## How it's built

```
Sources/TactusCore      the motor and finger detection (Trackpad), playback (Haptics), patterns, the command
                        protocol, the bridge server, Accessibility helpers, and pure, tested signal logic
                        (TextureEngine, BassDetector, MIDIParser, BeatCounter, RoleCue)
Sources/TactusModules   signals, access, music, games, bridge, and the texture window
Sources/tactus          the command-line tool and menu bar host
Tests/TactusCoreTests   unit tests: swift test
```

The texture engine samples the image along the path the pointer just took and counts the light/dark ridges it crossed. Slow strokes give one click per ridge. Fast strokes fuse into a buzz whose pitch follows the number of ridges crossed per second, the way a real surface's vibration rises with the speed of your finger.

## Status

Tactus is a prototype. The core logic is unit tested. The motor, finger detection, bridge (text, JSON and OSC) and music module (MIDI clock and drums) have been tested on real hardware. The signals and access cues, screen texture and audio rumble run without errors, but haven't been tuned with users yet. Feedback is welcome, especially from blind and low-vision users and from musicians.

## Credits

The trackpad motor calls come from [nospeaker](https://github.com/os6/nospeaker) by Cody Collier (MIT licence; see [NOTICE](NOTICE)), which in turn credits the open-source Tactile project. The haptic signals were inspired by Microsoft's Surface Mouse (2nd Edition) and Windows 11 haptic signals.

## Licence

MIT. See [LICENSE](LICENSE).
