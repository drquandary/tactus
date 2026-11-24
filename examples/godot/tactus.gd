# Tactus haptics for Godot 4. Add this script as an autoload named "Tactus", then call for example:
#
#     Tactus.play("hit")
#     Tactus.play("explosion", 0.8)
#     Tactus.engine(rpm)            # call every frame while driving; stops on its own when you stop calling
#
# Tactus must be running on the same Mac with the bridge module on (it is by default).
extends Node

const PORT := 7477
var _udp := PacketPeerUDP.new()

func _ready() -> void:
	_udp.set_dest_address("127.0.0.1", PORT)

func send(line: String) -> void:
	_udp.put_packet(line.to_utf8_buffer())

func play(pattern: String, level: float = 1.0) -> void:
	send("play %s %f" % [pattern, level])

func pulse(hz: float, ms: float, level: float = 1.0) -> void:
	send("pulse %f %f %f" % [hz, ms, level])

func hold(source: String, hz: float, level: float, ttl_ms: float = 150.0) -> void:
	send("hold %s %f %f %f" % [source, hz, level, ttl_ms])

func release(source: String) -> void:
	send("release %s" % source)

# An engine whose rumble follows RPM (800 to 8000 maps to 45 to 120 Hz).
func engine(rpm: float) -> void:
	var t: float = clamp((rpm - 800.0) / 7200.0, 0.0, 1.0)
	hold("engine", lerp(45.0, 120.0, t), lerp(0.3, 0.8, t), 150.0)
