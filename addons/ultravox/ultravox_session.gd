@icon("res://addons/ultravox/icon.svg")
class_name UltravoxSession
extends Node
## Manages a single session with Ultravox.
##
## Add an UltravoxSession to the scene tree, then call [method join_call] with the joinUrl of a
## call created by your server (see https://docs.ultravox.ai). The session reports progress through
## its signals.
## [codeblock]
## @onready var session: UltravoxSession = $UltravoxSession
##
## func _ready() -> void:
##     session.status_changed.connect(func(status): print("Status: ", status))
##     session.transcripts_changed.connect(func(): print(session.transcripts.back()))
##     session.join_call(join_url)
## [/codeblock]

## The session's status changed.
signal status_changed(status: Status)
## A transcript was added or updated.
signal transcripts_changed
## A data message was received. Call [method UltravoxDataMessageEvent.prevent_default] on the
## event to suppress the SDK's own handling of the message.
signal data_message(event: UltravoxDataMessageEvent)
## The session ended unexpectedly, for example because the network dropped the call's media
## connection. Emitted immediately before the session's final [signal status_changed] signals. Not
## emitted when a call ends normally.
signal error(message: String)
## The user's mic was muted or unmuted.
signal mic_muted_changed(muted: bool)
## The agent's audio output was muted or unmuted.
signal speaker_muted_changed(muted: bool)

## The current status of an UltravoxSession.
enum Status {
	## The session is not connected and not attempting to connect. This is the initial state.
	DISCONNECTED,
	## The client is disconnecting from the session.
	DISCONNECTING,
	## The client is attempting to connect to the session.
	CONNECTING,
	## The server has disconnected from the call.
	IDLE,
	## The client is connected and the server is listening for voice input.
	LISTENING,
	## The client is connected and the server is considering its response. The user can still
	## interrupt.
	THINKING,
	## The client is connected and the server is playing response audio. The user can interrupt as
	## needed.
	SPEAKING,
}

## How soon the agent should respond to a message sent via [method send_text].
enum TextMessageUrgency {
	## Use the server's default (currently [constant SOON]).
	DEFAULT,
	## Start a new response immediately, even if the agent is speaking.
	IMMEDIATE,
	## Don't interrupt the agent, but respond at the next opportunity.
	SOON,
	## Don't force a response. The message will be considered whenever the agent next responds.
	LATER,
}

## Where a message sent via [method send_text] should be placed if the user is speaking when it is
## received.
enum TextMessagePlacement {
	## Use the server's default (currently [constant BEFORE]).
	DEFAULT,
	## Place the message before any active (i.e. not-yet-responded-to) user speech.
	BEFORE,
	## Place the message after the most recent pause in active user speech.
	PREVIOUS_PAUSE,
}

## How the agent should proceed after a client tool invocation. Used as the "agentReaction" of a
## client tool result.
enum AgentReaction {
	## The agent should speak after the tool invocation. This is the default and is recommended for
	## tools that retrieve information for the agent to act on.
	SPEAKS,
	## The agent should listen after the tool invocation. This is recommended for tools the user is
	## expected to act on, such as certain clear UI changes.
	LISTENS,
	## The agent should speak after the tool invocation if and only if it did not speak immediately
	## before the tool invocation. This is recommended for tools whose primary purpose is a side
	## effect like recording information collected from the user.
	SPEAKS_ONCE,
}

const SDK_VERSION := "0.1.0"

const _CONNECTED_STATUSES: Array[Status] = [Status.LISTENING, Status.THINKING, Status.SPEAKING]
const _SERVER_STATUSES := {
	"idle": Status.IDLE,
	"listening": Status.LISTENING,
	"thinking": Status.THINKING,
	"speaking": Status.SPEAKING,
}
const _URGENCY_VALUES := {
	TextMessageUrgency.IMMEDIATE: "immediate",
	TextMessageUrgency.SOON: "soon",
	TextMessageUrgency.LATER: "later",
}
const _PLACEMENT_VALUES := {
	TextMessagePlacement.BEFORE: "before",
	TextMessagePlacement.PREVIOUS_PAUSE: "previous_pause",
}
const _AGENT_REACTION_VALUES := {
	AgentReaction.SPEAKS: "speaks",
	AgentReaction.LISTENS: "listens",
	AgentReaction.SPEAKS_ONCE: "speaks-once",
}
const _MEDIUM_VALUES := {
	UltravoxTranscript.Medium.VOICE: "voice",
	UltravoxTranscript.Medium.TEXT: "text",
}
## Messages that could exceed the WebRTC data channel's practical size limit go via websocket.
const _MAX_DATA_CHANNEL_MESSAGE_BYTES := 1024

## Additional data message types to enable (e.g. "debug"). Empty by default.
@export var additional_messages: PackedStringArray = []

@export_group("Audio")
## Where the agent's voice plays: an [AudioStreamPlayer], [AudioStreamPlayer2D] or
## [AudioStreamPlayer3D] (for example on an NPC, for positional audio). Its stream is replaced
## during calls. When unset, the session plays agent audio through an internal
## [AudioStreamPlayer] on [member agent_audio_bus].
@export var agent_audio_player: Node
## The bus for agent audio when [member agent_audio_player] is unset.
@export var agent_audio_bus: StringName = &"Master"
## Removes the agent's voice (and other game audio) from the user's mic signal. Requires a
## godot-livekit build providing LiveKitAudioProcessingModule; without it, players should wear
## headphones.
@export var echo_cancellation := true
## Reduces background noise in the user's mic signal. Requires LiveKitAudioProcessingModule.
@export var noise_suppression := true
## Normalizes the user's mic volume. Requires LiveKitAudioProcessingModule.
@export var auto_gain_control := true
## The stream providing the user's audio. Defaults to an [AudioStreamMicrophone], which requires
## the audio/driver/enable_input project setting. Takes effect at the next [method join_call].
var mic_stream: AudioStream

## The session's current status.
var status: Status:
	get:
		return _status

## All transcripts for the current call, ordered by ordinal.
var transcripts: Array[UltravoxTranscript]:
	get:
		var result: Array[UltravoxTranscript] = []
		for transcript in _transcripts:
			if transcript != null:
				result.append(transcript)
		return result

## Whether the user's mic is currently muted for the session. (Does not inspect hardware state.)
var is_mic_muted: bool:
	get:
		return _mic_muted

## Whether the user's speaker (i.e. agent output audio) is currently muted for the session. (Does
## not inspect system volume or hardware state.)
var is_speaker_muted: bool:
	get:
		return _speaker_muted

var _backend: UltravoxRoomBackend
var _status := Status.DISCONNECTED
var _transcripts: Array[UltravoxTranscript] = []
var _registered_tools: Dictionary[String, Callable] = {}
var _socket: WebSocketPeer
var _room_started := false
var _room_connected := false
var _mic_muted := false
var _speaker_muted := false
## Incremented per call so that late async results can't leak into a later call.
var _call_generation := 0


## [param backend] replaces the default [UltravoxLiveKitBackend], e.g. for tests.
func _init(backend: UltravoxRoomBackend = null) -> void:
	_backend = backend if backend else UltravoxLiveKitBackend.new()
	_backend.connected.connect(_on_room_connected)
	_backend.connection_failed.connect(_on_room_connection_failed)
	_backend.disconnected.connect(_on_room_disconnected)
	_backend.data_received.connect(_on_room_data_received)


func _process(_delta: float) -> void:
	if _socket:
		_poll_socket()
	if _room_started:
		_backend.poll()


func _exit_tree() -> void:
	leave_call()


## Registers a client tool implementation with the given name. If the call is started with a
## client-implemented tool, [param implementation] is called with the tool's parameters (a
## [Dictionary]) when the model calls the tool. It may be a coroutine (using [code]await[/code]).
##
## It should return either a [String] result or a [Dictionary] with [String] "result" and
## "responseType" keys and optional "agentReaction" (an [enum AgentReaction]) and
## "updateCallState" keys. To report a failure, return a [Dictionary] with an "error" key holding
## a [String] message.
##
## See https://docs.ultravox.ai/tools for more information.
func register_tool_implementation(tool_name: String, implementation: Callable) -> void:
	_registered_tools[tool_name] = implementation


## Convenience batch wrapper for [method register_tool_implementation], taking a [Dictionary] of
## tool names to [Callable]s.
func register_tool_implementations(implementations: Dictionary) -> void:
	for tool_name in implementations:
		register_tool_implementation(tool_name, implementations[tool_name])


## Connects to a call using the given joinUrl. [param client_version] optionally identifies your
## application to Ultravox.
func join_call(join_url: String, client_version := "") -> Error:
	if _status != Status.DISCONNECTED:
		push_error("Ultravox: cannot join a new call while already in a call.")
		return ERR_ALREADY_IN_USE
	if not is_inside_tree():
		push_error("Ultravox: the session must be in the scene tree to join a call.")
		return ERR_UNCONFIGURED
	# Clear any previous call's transcripts, notifying listeners that may be rendering them.
	if not _transcripts.is_empty():
		_transcripts.clear()
		transcripts_changed.emit()
	var uv_client_version := "godot_" + SDK_VERSION
	if client_version:
		uv_client_version += ":" + client_version
	var params := {"clientVersion": uv_client_version, "apiVersion": "1"}
	if not additional_messages.is_empty():
		params["additionalMessages"] = ",".join(additional_messages)

	_call_generation += 1
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(_with_query_params(join_url, params))
	if err != OK:
		_socket = null
		push_error("Ultravox: failed to connect to %s (%s)." % [join_url, error_string(err)])
		return err
	_set_status(Status.CONNECTING)
	return OK


## Leaves the current call (if any).
func leave_call() -> void:
	_disconnect()


## Sets the agent's output medium. If the agent is currently speaking, this takes effect at the end
## of the agent's utterance. Also see [method mute_speaker] and [method unmute_speaker].
func set_output_medium(medium: UltravoxTranscript.Medium) -> Error:
	if not _CONNECTED_STATUSES.has(_status):
		push_error("Ultravox: cannot set output medium while not connected. Current status is %s." % _status_name())
		return ERR_UNAVAILABLE
	return send_data({"type": "set_output_medium", "medium": _MEDIUM_VALUES[medium]})


## Sends a user message via text.
func send_text(
	text: String,
	urgency := TextMessageUrgency.DEFAULT,
	placement := TextMessagePlacement.DEFAULT,
) -> Error:
	if not _CONNECTED_STATUSES.has(_status):
		push_error("Ultravox: cannot send text while not connected. Current status is %s." % _status_name())
		return ERR_UNAVAILABLE
	var message := {"type": "user_text_message", "text": text}
	if urgency != TextMessageUrgency.DEFAULT:
		message["urgency"] = _URGENCY_VALUES[urgency]
	if placement != TextMessagePlacement.DEFAULT:
		message["placement"] = _PLACEMENT_VALUES[placement]
	return send_data(message)


## Sends an arbitrary data message to the server. See https://docs.ultravox.ai/datamessages for
## message types. If the call's transports are unavailable (before the call is joined or after it
## ends), the message is dropped with a warning.
func send_data(message: Dictionary) -> Error:
	if not message.has("type"):
		push_error("Ultravox: data messages must have a type field.")
		return ERR_INVALID_PARAMETER
	# Undeliverable messages warn rather than fail loudly: the loss is typically visible through
	# other means (call events, transcripts, etc.), and fire-and-forget callers can't do much.
	if not _room_connected or _socket == null:
		push_warning("Ultravox: dropping '%s' data message while not connected. Current status is %s." % [
			message["type"], _status_name()
		])
		return ERR_UNAVAILABLE
	var text := JSON.stringify(message)
	var bytes := text.to_utf8_buffer()
	if bytes.size() > _MAX_DATA_CHANNEL_MESSAGE_BYTES:
		return _socket.send_text(text)
	_backend.publish_data(bytes)
	return OK


## Mutes audio input from the user.
func mute_mic() -> void:
	_set_mic_muted(true)


## Unmutes audio input from the user.
func unmute_mic() -> void:
	_set_mic_muted(false)


## Toggles the mute state of the user's audio input.
func toggle_mic_mute() -> void:
	_set_mic_muted(not _mic_muted)


## Mutes audio output from the agent.
func mute_speaker() -> void:
	_set_speaker_muted(true)


## Unmutes audio output from the agent.
func unmute_speaker() -> void:
	_set_speaker_muted(false)


## Toggles the mute state of the agent's output audio.
func toggle_speaker_mute() -> void:
	_set_speaker_muted(not _speaker_muted)


## The user's current audio level, from 0 to 1, e.g. for a speech indicator. 0 while muted or not
## in a call.
func get_mic_level() -> float:
	return _backend.get_mic_level() if _room_connected else 0.0


## The agent's current audio level, from 0 to 1, e.g. for animating a character's mouth. 0 while
## muted or not in a call.
func get_agent_level() -> float:
	return _backend.get_agent_level() if _room_connected else 0.0


func _set_mic_muted(muted: bool) -> void:
	if _mic_muted == muted:
		return
	_mic_muted = muted
	_backend.set_mic_muted(muted)
	mic_muted_changed.emit(muted)


func _set_speaker_muted(muted: bool) -> void:
	if _speaker_muted == muted:
		return
	_speaker_muted = muted
	_backend.set_speaker_muted(muted)
	speaker_muted_changed.emit(muted)


func _poll_socket() -> void:
	_socket.poll()
	var state := _socket.get_ready_state()
	while _socket and _socket.get_available_packet_count() > 0:
		_handle_socket_message(_socket.get_packet().get_string_from_utf8())
	if _socket and state == WebSocketPeer.STATE_CLOSED:
		_handle_socket_close(_socket.get_close_code(), _socket.get_close_reason())


func _handle_socket_message(text: String) -> void:
	if _is_stopped():
		return
	var message = JSON.parse_string(text)
	if not message is Dictionary:
		push_warning("Ultravox: ignoring malformed socket message.")
		return
	if _room_started:
		# The first socket message contains room info. The server sends nothing else over the
		# socket today, but any later message would be an ordinary data message (mirroring how
		# this client sends its large data messages over the socket).
		_handle_data_message(message)
		return
	_room_started = true
	_backend.connect_room(str(message.get("roomUrl", "")), str(message.get("token", "")), self)


func _handle_socket_close(code: int, reason: String) -> void:
	if _is_stopped():
		return
	var closed_normally := code == 1000 or code == 1005
	if code == -1:
		# Godot reports -1 when no close frame was processed. Over TLS that includes the server's
		# prompt close after a normal call end: Godot discards a close frame that arrives in the
		# same read as the connection closing. The server closes the socket to end calls, so a
		# healthy media connection means the close was most likely intentional.
		closed_normally = _room_connected and not _backend.is_reconnecting()
	if not closed_normally:
		error.emit("Session socket closed abnormally. code=%d reason=%s" % [code, reason])
	elif _backend.is_reconnecting():
		# The server ended the call while we were trying to recover the call's media connection,
		# meaning the call was cut short by a network failure rather than ending normally.
		error.emit("Call ended due to unstable media connection")
	_disconnect()


func _on_room_connected() -> void:
	if not _is_stopped():
		_room_connected = true


func _on_room_connection_failed(message: String) -> void:
	if _is_stopped():
		return
	error.emit("Call media connection failed (%s)" % message)
	_disconnect()


func _on_room_disconnected(reason: String) -> void:
	if _is_stopped():
		return
	# The server ends calls by closing our socket, not by closing the room, so a room disconnect we
	# didn't initiate means the media connection was lost. The call cannot continue without media,
	# so we surface the failure and hang up rather than leaving the session in a stale "live" state.
	error.emit("Call media connection lost unexpectedly (%s)" % reason)
	_disconnect()


func _on_room_data_received(data: PackedByteArray) -> void:
	var message = JSON.parse_string(data.get_string_from_utf8())
	if message is Dictionary:
		_handle_data_message(message)
	else:
		push_warning("Ultravox: ignoring malformed data message.")


func _is_stopped() -> bool:
	return _status == Status.DISCONNECTING or _status == Status.DISCONNECTED


func _disconnect() -> void:
	if _is_stopped():
		return
	_set_status(Status.DISCONNECTING)
	_backend.disconnect_room()
	_room_started = false
	_room_connected = false
	if _socket:
		_socket.close()
		_socket = null
	_set_status(Status.DISCONNECTED)


func _set_status(new_status: Status) -> void:
	if _status == new_status:
		return
	_status = new_status
	status_changed.emit(new_status)


func _handle_data_message(message: Dictionary) -> void:
	if _is_stopped():
		# Late messages can still be delivered during teardown and must not resurrect the session
		# by mutating its status or transcripts.
		return
	var event := UltravoxDataMessageEvent.new(message)
	data_message.emit(event)
	# Handlers may have left the call.
	if event.is_default_prevented() or _is_stopped():
		return
	match message.get("type"):
		"state":
			var new_status = _SERVER_STATUSES.get(message.get("state"))
			if new_status != null:
				_set_status(new_status)
		"transcript":
			_handle_transcript(message)
		"client_tool_invocation":
			_invoke_client_tool(
				str(message.get("toolName", "")),
				str(message.get("invocationId", "")),
				message.get("parameters", {}),
			)


func _handle_transcript(message: Dictionary) -> void:
	var medium := UltravoxTranscript.Medium.VOICE if message.get("medium") == "voice" else UltravoxTranscript.Medium.TEXT
	var role := UltravoxTranscript.Role.AGENT if message.get("role") == "agent" else UltravoxTranscript.Role.USER
	var ordinal := int(message.get("ordinal", 0))
	var is_final := bool(message.get("final", false))
	var text = message.get("text")
	var delta = message.get("delta")
	if text is String and text:
		_add_or_update_transcript(ordinal, medium, role, is_final, text, "")
	elif delta is String and delta:
		_add_or_update_transcript(ordinal, medium, role, is_final, "", delta)


func _add_or_update_transcript(
	ordinal: int,
	medium: UltravoxTranscript.Medium,
	speaker: UltravoxTranscript.Role,
	is_final: bool,
	text: String,
	delta: String,
) -> void:
	while _transcripts.size() < ordinal:
		_transcripts.append(null)
	if _transcripts.size() == ordinal:
		_transcripts.append(UltravoxTranscript.new(text if text else delta, is_final, speaker, medium, ordinal))
	else:
		var prior := _transcripts[ordinal]
		var prior_text := prior.text if prior else ""
		_transcripts[ordinal] = UltravoxTranscript.new(
			text if text else prior_text + delta, is_final, speaker, medium, ordinal
		)
	transcripts_changed.emit()


func _invoke_client_tool(tool_name: String, invocation_id: String, parameters: Variant) -> void:
	var implementation: Callable = _registered_tools.get(tool_name, Callable())
	if not implementation.is_valid():
		send_data({
			"type": "client_tool_result",
			"invocationId": invocation_id,
			"errorType": "undefined",
			"errorMessage": "Client tool %s is not registered (Godot client)" % tool_name,
		})
		return
	var generation := _call_generation
	# Awaiting a non-coroutine's result returns it immediately, so this handles both kinds.
	var result = await implementation.call(parameters if parameters is Dictionary else {})
	if generation != _call_generation or _is_stopped():
		return
	send_data(_client_tool_result_message(invocation_id, result))


static func _client_tool_result_message(invocation_id: String, result: Variant) -> Dictionary:
	var message := {"type": "client_tool_result", "invocationId": invocation_id}
	if result is String:
		message["result"] = result
		return message
	if result is Dictionary and result.get("error") is String:
		message["errorType"] = "implementation-error"
		message["errorMessage"] = result["error"]
		return message
	if not (result is Dictionary and result.get("result") is String and result.get("responseType") is String):
		message["errorType"] = "implementation-error"
		message["errorMessage"] = (
			'Client tool result must be a String or a Dictionary with String "result" and '
			+ '"responseType" keys.'
		)
		return message
	message.merge(result)
	var agent_reaction = result.get("agentReaction")
	if agent_reaction is int:
		message["agentReaction"] = _AGENT_REACTION_VALUES.get(agent_reaction)
	return message


func _status_name() -> String:
	return Status.keys()[_status].to_lower()


## Returns [param url] with [param params] set in its query string, replacing any existing values.
static func _with_query_params(url: String, params: Dictionary) -> String:
	var parts := url.split("?", true, 1)
	var pairs: PackedStringArray = []
	if parts.size() > 1:
		for pair in parts[1].split("&", false):
			if not params.has(pair.get_slice("=", 0).uri_decode()):
				pairs.append(pair)
	for key in params:
		pairs.append("%s=%s" % [key.uri_encode(), str(params[key]).uri_encode()])
	return parts[0] + "?" + "&".join(pairs)
