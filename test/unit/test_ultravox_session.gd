extends GutTest

const FakeRoomBackend := preload("res://test/support/fake_room_backend.gd")
const FakeUltravoxServer := preload("res://test/support/fake_ultravox_server.gd")
const Status := UltravoxSession.Status
const _TIMEOUT := 2.0

var server: FakeUltravoxServer
var backend: FakeRoomBackend
var session: UltravoxSession
var statuses: Array = []
var errors: Array = []


func before_each() -> void:
	server = add_child_autofree(FakeUltravoxServer.new())
	backend = FakeRoomBackend.new()
	session = add_child_autofree(UltravoxSession.new(backend))
	statuses = []
	errors = []
	session.status_changed.connect(func(status: Status) -> void: statuses.append(status))
	session.error.connect(func(message: String) -> void: errors.append(message))


## Joins a call and connects its room, leaving the agent listening.
func _join_and_connect() -> void:
	assert_eq(session.join_call(server.join_url()), OK)
	await wait_until(server.is_client_connected, _TIMEOUT)
	server.send_room_info()
	await wait_until(func() -> bool: return not backend.connect_args.is_empty(), _TIMEOUT)
	backend.simulate_connected()
	backend.simulate_data({"type": "state", "state": "listening"})


func _transcript_tuples() -> Array:
	return session.transcripts.map(
		func(t: UltravoxTranscript) -> Array: return [t.ordinal, t.speaker, t.medium, t.is_final, t.text]
	)


func test_join_call_sends_client_version_and_options() -> void:
	session.additional_messages = ["debug"]
	session.join_call(server.join_url("?existing=1&apiVersion=0"), "my-game")
	await wait_until(server.is_client_connected, _TIMEOUT)
	assert_eq_deep(server.request_params(), {
		"existing": "1",
		"apiVersion": "1",
		"clientVersion": "godot_%s:my-game" % UltravoxSession.SDK_VERSION,
		"additionalMessages": "debug",
	})
	assert_eq(statuses, [Status.CONNECTING])


func test_room_info_connects_room() -> void:
	session.join_call(server.join_url())
	await wait_until(server.is_client_connected, _TIMEOUT)
	server.send_room_info("wss://room.example", "secret")
	await wait_until(func() -> bool: return not backend.connect_args.is_empty(), _TIMEOUT)
	assert_eq(backend.connect_args, ["wss://room.example", "secret"])


func test_join_call_while_in_call_fails() -> void:
	session.join_call(server.join_url())
	assert_eq(session.join_call(server.join_url()), ERR_ALREADY_IN_USE)
	assert_push_error("cannot join a new call while already in a call")


func test_state_messages_update_status() -> void:
	await _join_and_connect()
	for state in ["thinking", "speaking", "bogus", "idle"]:
		backend.simulate_data({"type": "state", "state": state})
	assert_eq(statuses, [Status.CONNECTING, Status.LISTENING, Status.THINKING, Status.SPEAKING, Status.IDLE])
	assert_eq(session.status, Status.IDLE)


func test_transcripts_accumulate_text_and_deltas() -> void:
	await _join_and_connect()
	var messages := [
		{"role": "agent", "medium": "voice", "text": "Hello", "final": false, "ordinal": 0},
		{"role": "agent", "medium": "voice", "delta": " there", "final": false, "ordinal": 0},
		{"role": "agent", "medium": "voice", "text": "Hello there!", "final": true, "ordinal": 0},
		# Ordinal 1 never arrives, so it is omitted.
		{"role": "user", "medium": "text", "delta": "Hi", "final": false, "ordinal": 2},
		{"role": "user", "medium": "text", "delta": " back", "final": true, "ordinal": 2},
	]
	var change_count := [0]
	session.transcripts_changed.connect(func() -> void: change_count[0] += 1)
	for message in messages:
		message["type"] = "transcript"
		backend.simulate_data(message)
	assert_eq_deep(_transcript_tuples(), [
		[0, UltravoxTranscript.Role.AGENT, UltravoxTranscript.Medium.VOICE, true, "Hello there!"],
		[2, UltravoxTranscript.Role.USER, UltravoxTranscript.Medium.TEXT, true, "Hi back"],
	])
	assert_eq(change_count[0], messages.size())


func test_rejoining_clears_transcripts() -> void:
	await _join_and_connect()
	backend.simulate_data({"type": "transcript", "role": "agent", "medium": "voice", "text": "Hi", "final": true, "ordinal": 0})
	session.leave_call()
	session.join_call(server.join_url())
	assert_eq(session.transcripts, [])


func test_data_message_handlers_can_prevent_default_handling() -> void:
	await _join_and_connect()
	var seen: Array = []
	session.data_message.connect(func(event: UltravoxDataMessageEvent) -> void:
		seen.append(event.message["type"])
		if event.message["type"] == "state":
			event.prevent_default()
	)
	backend.simulate_data({"type": "state", "state": "speaking"})
	backend.simulate_data({"type": "debug", "message": "hi"})
	assert_eq(seen, ["state", "debug"])
	assert_eq(session.status, Status.LISTENING)


func test_client_tool_results() -> void:
	session.register_tool_implementations({
		"plain": func(params: Dictionary) -> String: return "got %s" % params["x"],
		"structured": func(_params: Dictionary) -> Dictionary:
			return {
				"result": "ok",
				"responseType": "tool-response",
				"agentReaction": UltravoxSession.AgentReaction.SPEAKS_ONCE,
			},
		"failing": func(_params: Dictionary) -> Dictionary: return {"error": "no dice"},
		"invalid": func(_params: Dictionary) -> int: return 42,
	})
	await _join_and_connect()
	for tool_name in ["plain", "structured", "failing", "invalid", "unregistered"]:
		backend.simulate_data({
			"type": "client_tool_invocation",
			"toolName": tool_name,
			"invocationId": tool_name + "-id",
			"parameters": {"x": "y"},
		})
	var error_types := {}
	for message in backend.published:
		error_types[message["invocationId"]] = message.get("errorType")
	assert_eq_deep(backend.published.slice(0, 2), [
		{"type": "client_tool_result", "invocationId": "plain-id", "result": "got y"},
		{
			"type": "client_tool_result",
			"invocationId": "structured-id",
			"result": "ok",
			"responseType": "tool-response",
			"agentReaction": "speaks-once",
		},
	])
	assert_eq_deep(error_types, {
		"plain-id": null,
		"structured-id": null,
		"failing-id": "implementation-error",
		"invalid-id": "implementation-error",
		"unregistered-id": "undefined",
	})


func test_async_client_tool_result_is_sent_when_ready() -> void:
	var finish := [false]
	session.register_tool_implementation("slow", func(_params: Dictionary) -> String:
		await wait_until(func() -> bool: return finish[0], _TIMEOUT)
		return "done"
	)
	await _join_and_connect()
	backend.simulate_data({"type": "client_tool_invocation", "toolName": "slow", "invocationId": "id", "parameters": {}})
	assert_eq(backend.published, [])
	finish[0] = true
	await wait_until(func() -> bool: return not backend.published.is_empty(), _TIMEOUT)
	assert_eq_deep(backend.published, [{"type": "client_tool_result", "invocationId": "id", "result": "done"}])


func test_async_client_tool_result_is_dropped_after_call_ends() -> void:
	var finish := [false]
	session.register_tool_implementation("slow", func(_params: Dictionary) -> String:
		await wait_until(func() -> bool: return finish[0], _TIMEOUT)
		return "done"
	)
	await _join_and_connect()
	backend.simulate_data({"type": "client_tool_invocation", "toolName": "slow", "invocationId": "id", "parameters": {}})
	session.leave_call()
	await _join_and_connect()
	finish[0] = true
	await wait_process_frames(2)
	assert_eq(backend.published, [])


func test_send_text_serializes_options() -> void:
	await _join_and_connect()
	session.send_text("one")
	session.send_text("two", UltravoxSession.TextMessageUrgency.LATER, UltravoxSession.TextMessagePlacement.PREVIOUS_PAUSE)
	session.set_output_medium(UltravoxTranscript.Medium.TEXT)
	assert_eq_deep(backend.published, [
		{"type": "user_text_message", "text": "one"},
		{"type": "user_text_message", "text": "two", "urgency": "later", "placement": "previous_pause"},
		{"type": "set_output_medium", "medium": "text"},
	])


func test_send_text_requires_connection() -> void:
	assert_eq(session.send_text("hello"), ERR_UNAVAILABLE)
	assert_push_error("cannot send text while not connected")


func test_large_data_messages_use_websocket() -> void:
	await _join_and_connect()
	var large := {"type": "big", "payload": "x".repeat(2000)}
	session.send_data({"type": "small"})
	session.send_data(large)
	await wait_until(func() -> bool: return not server.received.is_empty(), _TIMEOUT)
	assert_eq_deep([backend.published, server.received], [[{"type": "small"}], [large]])


func test_send_data_before_room_connects_is_dropped() -> void:
	session.join_call(server.join_url())
	assert_eq([session.send_data({"type": "x"}), session.send_data({})], [ERR_UNAVAILABLE, ERR_INVALID_PARAMETER])
	assert_engine_error("dropping 'x' data message while not connected")
	assert_push_error("data messages must have a type field")


func test_leave_call_tears_down() -> void:
	await _join_and_connect()
	session.leave_call()
	backend.simulate_data({"type": "state", "state": "speaking"})
	await wait_until(func() -> bool: return server.client_closed, _TIMEOUT)
	assert_eq(statuses, [Status.CONNECTING, Status.LISTENING, Status.DISCONNECTING, Status.DISCONNECTED])
	assert_eq([backend.disconnect_count, server.client_closed, errors], [1, true, []])


func test_removing_session_from_tree_leaves_call() -> void:
	await _join_and_connect()
	remove_child(session)
	assert_eq([session.status, backend.disconnect_count], [Status.DISCONNECTED, 1])
	session.free()


func test_server_ending_call_normally_disconnects_without_error() -> void:
	await _join_and_connect()
	server.close(1000)
	await wait_until(func() -> bool: return session.status == Status.DISCONNECTED, _TIMEOUT)
	assert_eq([errors, backend.disconnect_count], [[], 1])


func test_socket_failures_are_reported() -> void:
	var cases := [
		["abnormal close", func() -> void: server.drop(), "Session socket closed abnormally"],
		["close while reconnecting", func() -> void:
			backend.reconnecting = true
			server.close(1000),
			"Call ended due to unstable media connection"],
	]
	for case in cases:
		errors.clear()
		backend.reconnecting = false
		await _join_and_connect()
		case[1].call()
		await wait_until(func() -> bool: return session.status == Status.DISCONNECTED, _TIMEOUT)
		assert_eq(errors.size(), 1, case[0])
		assert_string_starts_with(errors[0] if errors else "", case[2], case[0])


func test_room_failures_are_reported() -> void:
	var cases := [
		["lost", func() -> void: backend.disconnected.emit("network"), "Call media connection lost unexpectedly (network)"],
		["failed", func() -> void: backend.connection_failed.emit("timeout"), "Call media connection failed (timeout)"],
	]
	for case in cases:
		errors.clear()
		await _join_and_connect()
		case[1].call()
		assert_eq([errors, session.status], [[case[2]], Status.DISCONNECTED], case[0])


func test_mute_state_is_applied_and_reported() -> void:
	var events: Array = []
	session.mic_muted_changed.connect(func(muted: bool) -> void: events.append(["mic", muted]))
	session.speaker_muted_changed.connect(func(muted: bool) -> void: events.append(["speaker", muted]))
	session.mute_mic()
	session.mute_mic()
	session.toggle_speaker_mute()
	session.toggle_mic_mute()
	session.unmute_speaker()
	assert_eq_deep(events, [["mic", true], ["speaker", true], ["mic", false], ["speaker", false]])
	session.mute_mic()
	assert_eq([backend.mic_muted, backend.speaker_muted, session.is_mic_muted, session.is_speaker_muted], [true, false, true, false])


func test_audio_levels_are_zero_outside_calls() -> void:
	backend.mic_level = 0.5
	backend.agent_level = 0.25
	assert_eq([session.get_mic_level(), session.get_agent_level()], [0.0, 0.0])
	await _join_and_connect()
	assert_eq([session.get_mic_level(), session.get_agent_level()], [0.5, 0.25])
