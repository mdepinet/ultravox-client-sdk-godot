class_name UltravoxRoomBackend
extends RefCounted
## The media transport an [UltravoxSession] uses to exchange audio and data messages with an
## Ultravox call. [UltravoxLiveKitBackend] is the default implementation. Subclasses override
## every method below.

## The room connected (after [method connect_room]).
signal connected
## The room failed to connect.
signal connection_failed(error: String)
## The room disconnected without [method disconnect_room] being called, meaning the call's media
## connection was lost.
signal disconnected(reason: String)
## A data message arrived from the server.
signal data_received(data: PackedByteArray)


## Connects to the room given by the server's room_info message, for [param session]. Any nodes
## the backend needs (e.g. audio players) should be children of [param node_parent], which is in
## the scene tree and keeps processing while the game is paused.
func connect_room(_url: String, _token: String, _session: UltravoxSession, _node_parent: Node) -> void:
	push_error("UltravoxRoomBackend.connect_room is not implemented")


## Leaves the room and releases its resources. Must not emit [signal disconnected].
func disconnect_room() -> void:
	pass


## Called every frame while connected or connecting.
func poll() -> void:
	pass


## Whether the room is attempting to recover a lost media connection.
func is_reconnecting() -> bool:
	return false


## Reliably sends a data message to the server. Only valid once connected.
func publish_data(_data: PackedByteArray) -> void:
	push_error("UltravoxRoomBackend.publish_data is not implemented")


func set_mic_muted(_muted: bool) -> void:
	pass


func set_speaker_muted(_muted: bool) -> void:
	pass


## The user's current (microphone) audio level, from 0 to 1.
func get_mic_level() -> float:
	return 0.0


## The agent's current audio level, from 0 to 1.
func get_agent_level() -> float:
	return 0.0
