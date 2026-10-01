extends GutTest
## End-to-end tests against the real Ultravox API and the godot-livekit backend. Skipped unless
## ULTRAVOX_API_KEY is set. Each test creates (and pays for) a short call.

const AcousticEcho := preload("res://test/support/acoustic_echo.gd")
const _API_URL := "https://api.ultravox.ai/api/calls"
const _TIMEOUT := 30.0
const Status := UltravoxSession.Status

var session: UltravoxSession
var _original_treat_engine_errors_as: int


func should_skip_script():
	# A missing godot-livekit fails the tests instead, since it likely means a broken setup.
	if not OS.get_environment("ULTRAVOX_API_KEY"):
		return "ULTRAVOX_API_KEY is not set"
	return false


func before_each() -> void:
	session = add_child_autofree(UltravoxSession.new())


func before_all() -> void:
	# Engine warnings here are outside this SDK's control (e.g. godot-livekit warns whenever its
	# audio reader thread briefly holds the lock poll() wants), so only push_error fails tests.
	_original_treat_engine_errors_as = gut.error_tracker.treat_engine_errors_as
	gut.error_tracker.treat_engine_errors_as = GutUtils.TREAT_AS.NOTHING


func after_all() -> void:
	gut.error_tracker.treat_engine_errors_as = _original_treat_engine_errors_as


func after_each() -> void:
	session.leave_call()


func _create_call(config: Dictionary) -> String:
	config.merge({"maxDuration": "60s", "recordingEnabled": false})
	var http: HTTPRequest = add_child_autofree(HTTPRequest.new())
	http.request(
		_API_URL,
		["X-API-Key: " + OS.get_environment("ULTRAVOX_API_KEY"), "Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		JSON.stringify(config),
	)
	var response: Array = await http.request_completed
	assert_eq(response[1], 201, "call creation failed: %s" % response[3].get_string_from_utf8())
	return JSON.parse_string(response[3].get_string_from_utf8()).get("joinUrl", "")


func _final_agent_text() -> String:
	var texts: PackedStringArray = []
	for transcript in session.transcripts:
		if transcript.speaker == UltravoxTranscript.Role.AGENT and transcript.is_final:
			texts.append(transcript.text)
	return " ".join(texts).to_lower()


func test_text_round_trip_plays_agent_audio() -> void:
	session.mic_stream = AudioStreamGenerator.new()  # Silence; headless runs have no mic.
	var join_url := await _create_call({
		"systemPrompt": "You are a test agent. Repeat exactly what the user says and nothing more.",
		"firstSpeakerSettings": {"user": {}},
	})
	session.join_call(join_url, "integration-test")
	await wait_until(func() -> bool: return session.status == Status.LISTENING, _TIMEOUT)
	session.send_text("the quick brown fox")
	var max_agent_level := [0.0]
	await wait_until(func() -> bool:
		max_agent_level[0] = maxf(max_agent_level[0], session.get_agent_level())
		return "fox" in _final_agent_text(), _TIMEOUT)
	assert_string_contains(_final_agent_text(), "quick brown fox")
	assert_gt(max_agent_level[0], 0.01, "agent audio should play")


func test_mic_audio_reaches_agent() -> void:
	var question := AudioStreamWAV.load_from_file("res://test/fixtures/capital_of_france.wav")
	# Repeated so a slow start (e.g. on a busy CI runner) can't clip the only copy of the question.
	question.loop_mode = AudioStreamWAV.LOOP_FORWARD
	question.loop_end = int(question.get_length() * question.mix_rate)
	session.mic_stream = question
	var join_url := await _create_call({
		"systemPrompt": "Answer the user's questions in one word.",
		"firstSpeakerSettings": {"user": {}},
	})
	session.join_call(join_url)
	await wait_until(func() -> bool: return "paris" in _final_agent_text(), _TIMEOUT)
	assert_string_contains(_final_agent_text(), "paris")


func test_server_ending_call_is_not_an_error() -> void:
	session.mic_stream = AudioStreamGenerator.new()
	var errors: Array = []
	session.error.connect(func(message: String) -> void: errors.append(message))
	var join_url := await _create_call({"systemPrompt": "Say hi.", "maxDuration": "8s"})
	session.join_call(join_url)
	await wait_until(func() -> bool: return session.status == Status.LISTENING, _TIMEOUT)
	await wait_until(func() -> bool: return session.status == Status.DISCONNECTED, _TIMEOUT)
	assert_eq([session.status, errors], [Status.DISCONNECTED, []])


func test_client_tool_round_trip() -> void:
	session.mic_stream = AudioStreamGenerator.new()
	var invocations: Array = []
	session.register_tool_implementation("getSecretWord", func(params: Dictionary) -> String:
		invocations.append(params)
		return "pineapple"
	)
	var join_url := await _create_call({
		"systemPrompt": (
			"When asked for the secret word, call the getSecretWord tool and then reply with only "
			+ "the word it returns."
		),
		"firstSpeakerSettings": {"user": {}},
		"selectedTools": [{"temporaryTool": {
			"modelToolName": "getSecretWord",
			"description": "Returns the secret word.",
			"client": {},
		}}],
	})
	session.join_call(join_url)
	await wait_until(func() -> bool: return session.status == Status.LISTENING, _TIMEOUT)
	session.send_text("What is the secret word?")
	await wait_until(func() -> bool: return "pineapple" in _final_agent_text(), _TIMEOUT)
	assert_eq([invocations.size(), "pineapple" in _final_agent_text()], [1, true], str(session.transcripts))


func test_echo_cancellation_keeps_agent_from_hearing_itself() -> void:
	if not ClassDB.class_exists(&"LiveKitAudioProcessingModule"):
		pending("the installed godot-livekit lacks LiveKitAudioProcessingModule")
		return
	var echo: AcousticEcho = add_child_autofree(AcousticEcho.new(session))
	session.mic_stream = echo.mic_stream
	var join_url := await _create_call({
		"systemPrompt": "Start the call by telling the user a four sentence story about a dragon.",
	})
	session.join_call(join_url)
	await wait_until(func() -> bool: return "dragon" in _final_agent_text(), _TIMEOUT)
	# Give any echoed speech time to be transcribed.
	await wait_seconds(3)
	var user_texts := session.transcripts.filter(
		func(t: UltravoxTranscript) -> bool: return t.speaker == UltravoxTranscript.Role.USER
	).map(func(t: UltravoxTranscript) -> String: return t.text)
	assert_eq([user_texts, "dragon" in _final_agent_text()], [[], true])
