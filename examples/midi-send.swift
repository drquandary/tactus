// Sends MIDI to Tactus's "Tactus" MIDI destination: a bar of clock with drum hits, then a short melody.
// Run it while Tactus is running with the music module on:   swift examples/midi-send.swift
// It's also a minimal example of sending MIDI from Swift with CoreMIDI.

import CoreMIDI
import Foundation

var client = MIDIClientRef(), port = MIDIPortRef()
MIDIClientCreateWithBlock("tactus-midi-send" as CFString, &client, nil)
MIDIOutputPortCreate(client, "out" as CFString, &port)

// Find the destination named "Tactus".
let dest = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination).first { d in
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(d, kMIDIPropertyName, &name)
    return (name?.takeRetainedValue() as String?) == "Tactus"
}
guard let dest else { print("No \"Tactus\" MIDI destination. Start Tactus with the music module first."); exit(1) }

func send(_ bytes: [UInt8]) {
    var list = MIDIPacketList()
    let packet = MIDIPacketListInit(&list)
    _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
    MIDISend(port, dest, &list)
}

let bpm = 120.0
let clockInterval = 60 / bpm / 24
print("Two bars of MIDI clock at \(Int(bpm)) BPM, with kick on 1 and 3 and snare on 2 and 4…")
send([0xFA])                                              // Start
for i in 0..<(24 * 8) {
    send([0xF8])                                          // Clock
    if i % 24 == 0 {
        let beat = i / 24
        send([0x99, beat % 2 == 0 ? 36 : 38, 110])       // kick or snare, channel 10
    }
    if i % 12 == 0 { send([0x99, 42, 60]) }               // hats on eighths
    Thread.sleep(forTimeInterval: clockInterval)
}
send([0xFC])                                              // Stop
print("…and a melody (enable \"Other notes as pulses\" in the Music menu to feel these).")
for note: UInt8 in [60, 64, 67, 72, 67, 64, 60] {
    send([0x90, note, 100]); Thread.sleep(forTimeInterval: 0.25); send([0x80, note, 0])
}
print("Done.")
