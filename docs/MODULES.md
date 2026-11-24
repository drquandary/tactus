# Modules

Turn each module on or off from the hand icon in the menu bar, or start Tactus with just the ones you want: `tactus run music bridge`. Tactus remembers which modules were on last time. Each module's submenu has its options.

## signals

Haptic signals like the Surface Mouse's, in every app:

- **Window snapping:** a bump when a window lands on full screen, half the screen or a quarter, and light ticks while you resize a window.
- **Scroll ticks:** a light tick every few lines, like a scroll wheel's notches. The glide after a flick has none, because your finger is already off the pad.
- **Drag and drop:** a bump when you pick up a file, text or an image, and another when you drop it.
- **Button hover:** a tick on buttons and links, and a double tick on a window's Close button.

Needs **Accessibility** permission for window snapping and button hover.

## access

Touch cues for blind and low-vision users. They work alongside VoiceOver or Zoom, or on their own.

- **Element cues:** each kind of control under the pointer feels different. A button is a tick and a link is a rising double tick. A text field is a soft hum. A checkbox gives a firm click when it's on and a soft one when it's off. A heading is three ticks and an image is a slow pulse.
- **Focus cues:** the same cues when keyboard focus moves (Tab, or VoiceOver navigation).
- **Edges:** a soft bump when the pointer crosses the edge of the front window, and a firm thud when it reaches the edge of the screen.
- **Screen texture** (off by default): feel whatever is on screen under the pointer. Contrast becomes ridges and buzz, as in the texture window.

Needs **Accessibility** permission, plus **Screen Recording** for screen texture. To feel focus cues while using the keyboard, rest a finger or the side of your hand on the trackpad, or start Tactus with `--always`. If both are on, turn off signals' Button hover so buttons don't tick twice.

## music

For producers, performers, and deaf or hard-of-hearing musicians. Tactus shows up as a MIDI destination called **Tactus**, and it also listens to every MIDI source on the Mac.

- **Beats from MIDI clock:** a tick on every beat and a bump on each bar's downbeat, following your DAW's tempo, start and stop.
- **Drum hits:** General MIDI drum notes become kick, snare, hat and crash patterns, with strength following velocity.
- **Other notes as pulses** (off by default): a pulse for each note. Its pitch follows the note, folded into the range fingertips feel best, and its strength follows velocity.
- **Metronome** (off by default): a built-in click at a tempo set in the menu, for practice with no DAW.

To try it, run `swift examples/midi-send.swift`.

## games

- **Audio rumble:** works with any game, film or song with no changes to it. Tactus listens to the Mac's sound output, keeps only the bass, and plays it as rumble, with a firm thud on each hit or explosion. Needs **Screen & System Audio Recording** permission. That is how macOS lets apps hear system audio; Tactus never records or saves anything.
- **Effects to try** from the menu: hit, explosion, pickup, damage, heartbeat, and an engine revving up.

Games that want precise effects can send them over the bridge (see `examples/godot` and `examples/unity`).

## bridge

Listens on UDP port 7477, on this Mac only, for commands from other programs: games, Max, Pure Data, TouchDesigner, scripts. See [PROTOCOL.md](PROTOCOL.md). On by default.

## texture (a window, not a menu bar module)

`tactus texture [image]` opens a window with an image, or with a test pattern of stripes, noise and a gradient. Rest a finger on the trackpad and move the pointer over the picture to feel it. Press 1 for Edges mode (light and dark ridges become clicks and buzz), or 2 for Darkness mode (dark areas feel rough). The other keys are + and - for strength, [ and ] for how big a brightness step counts as a ridge, t to turn the finger check off and on, and space to pause.
