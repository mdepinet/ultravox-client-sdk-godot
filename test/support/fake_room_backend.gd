extends UltravoxRoomBackend
## An in-memory UltravoxRoomBackend that records what the session asks of it and lets tests
## simulate events from the room.

## The (url, token) of the most recent connect_room call.
var connect_args: Array = []
## Data messages published by the session, parsed as JSON.
var published: Array = []
var disconnect_count := 0
var mic_muted := false
var speaker_muted := false
var reconnecting := false
var mic_level := 0.0
var agent_level := 0.0


func connect_room(url: String, token: String, _session: UltravoxSession, _node_parent: Node) -> void:
	connect_args = [url, token]


func disconnect_room() -> void:
	disconnect_count += 1


func is_reconnecting() -> bool:
	return reconnecting


func publish_data(data: PackedByteArray) -> void:
	published.append(JSON.parse_string(data.get_string_from_utf8()))


func set_mic_muted(muted: bool) -> void:
	mic_muted = muted


func set_speaker_muted(muted: bool) -> void:
	speaker_muted = muted


func get_mic_level() -> float:
	return mic_level


func get_agent_level() -> float:
	return agent_level


func simulate_connected() -> void:
	connected.emit()


func simulate_data(message: Dictionary) -> void:
	data_received.emit(JSON.stringify(message).to_utf8_buffer())
