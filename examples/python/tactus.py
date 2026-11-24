"""Send haptics to Tactus from Python (standard library only).

    import tactus
    tactus.play("bump")                    # a named pattern
    tactus.play("heartbeat", level=0.5)
    tactus.pulse(150, 20, 0.9)             # one tone: Hz, ms, strength
    tactus.hold("engine", hz=60, level=0.4, ttl=250)   # steady vibration; resend to keep it going
    tactus.release("engine")

Run this file to try them all:  python3 examples/python/tactus.py
Tactus must be running with the bridge module on (it is by default).
"""

import json
import socket
import struct
import time

HOST, PORT = "127.0.0.1", 7477
_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def send_text(line: str) -> None:
    _sock.sendto(line.encode(), (HOST, PORT))


def play(name: str, level: float = 1.0) -> None:
    send_text(f"play {name} {level}")


def pulse(hz: float, ms: float, level: float = 1.0) -> None:
    send_text(f"pulse {hz} {ms} {level}")


def hold(source: str, hz: float, level: float, ttl: float = 250) -> None:
    send_text(f"hold {source} {hz} {level} {ttl}")


def release(source: str) -> None:
    send_text(f"release {source}")


def send_json(obj: dict) -> None:
    _sock.sendto(json.dumps(obj).encode(), (HOST, PORT))


def send_osc(address: str, *args) -> None:
    """A minimal OSC encoder (strings, floats, ints), for tools that speak OSC."""
    def pad(b: bytes) -> bytes:
        b += b"\0"
        return b + b"\0" * ((4 - len(b) % 4) % 4)
    tags, payload = ",", b""
    for a in args:
        if isinstance(a, str):
            tags += "s"; payload += pad(a.encode())
        elif isinstance(a, int):
            tags += "i"; payload += struct.pack(">i", a)
        else:
            tags += "f"; payload += struct.pack(">f", float(a))
    _sock.sendto(pad(address.encode()) + pad(tags.encode()) + payload, (HOST, PORT))


if __name__ == "__main__":
    print("Rest a finger on the trackpad.")
    for name in ["tick", "bump", "heartbeat", "success", "explosion"]:
        print("play", name)
        play(name)
        time.sleep(0.8)
    print("an engine revving up (hold, refreshed every 50 ms)")
    for i in range(40):
        hold("engine", hz=45 + i * 2.5, level=0.4 + i / 80, ttl=120)
        time.sleep(0.05)
    release("engine")
    time.sleep(0.5)
    print("the same bump as JSON and as OSC")
    send_json({"play": "bump", "level": 0.8})
    time.sleep(0.6)
    send_osc("/tactus/play", "bump", 0.8)
    print("done")
