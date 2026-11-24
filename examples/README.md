# Examples

Each of these sends commands to a running Tactus over UDP port 7477 (see [../docs/PROTOCOL.md](../docs/PROTOCOL.md)). Start Tactus first with `tactus` (the bridge module is on by default).

| File | What it is | Tested |
|---|---|---|
| `python/tactus.py` | A tiny Python client (text, JSON and OSC) and a demo: `python3 examples/python/tactus.py` | Yes, on macOS 27 |
| `midi-send.swift` | Sends MIDI clock, drums and a melody to the "Tactus" MIDI destination: `swift examples/midi-send.swift` | Yes, on macOS 27 |
| `godot/tactus.gd` | A Godot 4 autoload: `Tactus.play("hit")`, `Tactus.engine(rpm)` | Not yet |
| `unity/TactusHaptics.cs` | A Unity static class: `TactusHaptics.Play("hit")` | Not yet |

## From Terminal

```sh
tactus send play bump 0.8
echo 'play heartbeat' | nc -u -w0 127.0.0.1 7477
```

## Max

Use a `[udpsend 127.0.0.1 7477]` object and send it OSC messages such as `/tactus/play bump 0.8`, `/tactus/pulse 150 20 0.9` or `/tactus/hold drone 80 0.4 300`.

## Pure Data

Connect a `[netsend -u]` object with the message `[connect 127.0.0.1 7477(`, then send it messages such as `[send play bump 0.8(` or `[send hold drone 80 0.4 300(`. Pure Data ends each message with a semicolon, which Tactus ignores. (The Max and Pure Data notes use standard objects but haven't been tested with Tactus yet.)

## A DAW

Send MIDI to the **Tactus** MIDI destination (it appears in your DAW's MIDI outputs while Tactus runs with the music module on):

- **MIDI clock** gives a tick on every beat and a bump on each downbeat.
- **Drum notes** (General MIDI: 36 kick, 38 snare, 42 hat…) play matching patterns.
- **Other notes** play pulses that follow pitch and velocity, once you turn that on in the Music menu.
