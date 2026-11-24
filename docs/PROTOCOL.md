# The Tactus bridge protocol

Any program on the same Mac can play haptics by sending short commands to **UDP port 7477 on 127.0.0.1**. Tactus only listens on the loopback address, so other machines on the network can't reach it. Send one command per datagram. In text form, several commands can share a datagram, one per line.

The bridge module must be running. It is on by default; check the Bridge item in the menu bar menu.

## Commands

| Command | Text | JSON | OSC |
|---|---|---|---|
| Play a named pattern | `play bump 0.8` or just `bump` | `{"play":"bump","level":0.8}` | `/tactus/play ,sf bump 0.8` |
| Play a custom pattern | `pattern 230:9:0.5/55,230:9:0.5 0.8` | `{"pattern":"230:9:0.5/55,230:9:0.5","level":0.8}` | `/tactus/pattern ,sf <spec> 0.8` |
| Play one tone | `pulse 150 20 0.9` | `{"pulse":[150,20,0.9]}` | `/tactus/pulse ,fff 150 20 0.9` |
| Start or update a steady vibration | `hold engine 60 0.5 250` | `{"hold":"engine","hz":60,"level":0.5,"ttl":250}` | `/tactus/hold ,sfff engine 60 0.5 250` |
| Stop a steady vibration | `release engine` | `{"release":"engine"}` | `/tactus/release ,s engine` |
| Stop all steady vibrations | `stop` | `{"stop":true}` | `/tactus/stop` |

- **level** is 0 to 1 and is optional (default 1). It is multiplied by the overall strength set in the menu.
- **pulse** takes a frequency in Hz, a length in milliseconds and a level. The fingertip feels about 65 to 400 Hz best. The motor can play up to about 4 kHz, but you mostly hear high tones rather than feel them.
- **hold** keeps a vibration going until you `release` it, or until `ttl` milliseconds (default 250) pass without the hold being sent again. Resend it a few times a second to keep it going and to change its pitch or strength (an engine following RPM, rain getting heavier). When several holds run at once, the strongest one plays.
- OSC arguments can be ints, floats or doubles. OSC bundles are accepted, and their time tags are ignored: commands play as soon as they arrive.
- Text commands from Pure Data's `[netsend]` end with a semicolon, which is ignored.

## Pattern specs

A custom pattern is a comma-separated list of pulses, each written `hz:ms:level`. A pulse can add `/gap` for the milliseconds of silence after it:

```
230:9:0.5/55, 230:9:0.5        two light ticks 55 ms apart
100:20:0.5, 150:20:0.6, 220:20:0.7, 320:20:0.8      a rising sweep
```

Each pulse is rounded to a whole number of cycles of its tone, so it ends cleanly.

## Named patterns

Run `tactus patterns` for the full list with their specs. The groups are:

- **General:** tick, click, bump, thud, double, triple, heartbeat, success, error, alert, buzz, rumble, rise, fall
- **Interface:** snap, edge, button, close, link, field, toggle-on, toggle-off, slider, menu, heading, image, popup
- **Music:** beat, downbeat, kick, snare, hat
- **Games:** hit, explosion, pickup, damage

## Finger on the pad

Vibration can only be felt with a finger on the trackpad. By default Tactus plays only while a finger is on the pad, or just after it lifts, so nothing hums with nobody touching it. Turn this off with "Only when a finger is on the trackpad" in the menu, or start Tactus with `--always`.
