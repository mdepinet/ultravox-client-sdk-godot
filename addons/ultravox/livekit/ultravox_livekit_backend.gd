class_name UltravoxLiveKitBackend
extends UltravoxRoomBackend
## The default [UltravoxRoomBackend], built on the godot-livekit GDExtension
## (https://github.com/NodotProject/godot-livekit).
##
## Microphone audio is captured from a muted audio bus, optionally passed through WebRTC's audio
## processing (echo cancellation, noise suppression and gain control, when the installed
## godot-livekit build provides LiveKitAudioProcessingModule), and published to the call from a
## dedicated audio thread. Agent audio plays through an [AudioStreamGenerator] on the session's
## agent audio player.

## The sample rate audio is exchanged with LiveKit at.
const _SAMPLE_RATE := 48000
## LiveKit's direct capture mode and WebRTC's audio processing both require 10ms frames.
const _FRAME_SAMPLES := _SAMPLE_RATE / 100
const _CAPTURE_BUFFER_SECONDS := 0.5
## Capacity (not latency) of the agent audio buffer. It must absorb game frame hitches since
## agent audio is only moved into it once per frame.
const _AGENT_BUFFER_SECONDS := 0.5
const _MASTER_BUS := &"Master"
## How often the audio thread moves captured audio to LiveKit.
const _AUDIO_THREAD_INTERVAL_USEC := 5000

## Warns once per run rather than once per call.
static var _warned_missing_apm := false

var _session: UltravoxSession
var _room: Object
var _connected := false
var _reconnecting := false
var _mic_muted := false
var _speaker_muted := false

var _audio_source: Object
var _local_track: Object
var _mic_bus_name := ""
var _mic_player: AudioStreamPlayer
var _mic_capture: AudioEffectCapture
var _mic_resampler: _Resampler
var _mic_pending := PackedFloat32Array()
var _mic_level := 0.0

var _audio_thread: Thread
var _audio_thread_running := false

var _apm: Object
var _stream_delay_ms := 0
var _reference_capture: AudioEffectCapture
var _reference_resampler: _Resampler
var _reference_pending := PackedFloat32Array()

var _agent_stream: Object
var _agent_player: Node
var _owns_agent_player := false
var _agent_player_original_bus := &""
var _agent_bus_name := ""
var _agent_playback: AudioStreamGeneratorPlayback


## Whether the godot-livekit GDExtension is installed and loaded.
static func is_available() -> bool:
	return ClassDB.class_exists(&"LiveKitRoom")


func connect_room(url: String, token: String, host: Node) -> void:
	if not is_available():
		connection_failed.emit(
			"The godot-livekit GDExtension is not installed. See the Ultravox addon's README."
		)
		return
	_session = host as UltravoxSession
	_mic_muted = _session.is_mic_muted if _session else false
	_speaker_muted = _session.is_speaker_muted if _session else false
	_room = ClassDB.instantiate(&"LiveKitRoom")
	_room.connected.connect(_on_room_connected)
	_room.connection_failed.connect(_on_room_connection_failed)
	_room.disconnected.connect(_on_room_disconnected)
	_room.reconnecting.connect(func() -> void: _reconnecting = true)
	_room.reconnected.connect(func() -> void: _reconnecting = false)
	_room.data_received.connect(_on_room_data_received)
	_room.track_subscribed.connect(_on_track_subscribed)
	_room.track_unsubscribed.connect(_on_track_unsubscribed)
	_room.connect_to_room(url, token, {})


func disconnect_room() -> void:
	_connected = false
	_reconnecting = false
	if _agent_stream:
		_agent_stream.close()
		_agent_stream = null
	_teardown_agent_player()
	_teardown_mic()
	if _room:
		# disconnect_from_room discards pending room events, so no disconnected signal follows.
		_room.disconnect_from_room()
		_room = null
	_session = null


func poll() -> void:
	if _connected:
		_pump_agent_audio()


func is_reconnecting() -> bool:
	return _reconnecting


func publish_data(data: PackedByteArray) -> void:
	if not _connected:
		push_warning("Ultravox: dropping data message sent before the room connected.")
		return
	_room.get_local_participant().publish_data(data, true)


func set_mic_muted(muted: bool) -> void:
	_mic_muted = muted
	if _local_track:
		if muted:
			_local_track.mute()
		else:
			_local_track.unmute()


func set_speaker_muted(muted: bool) -> void:
	_speaker_muted = muted
	if _agent_player:
		_agent_player.stream_paused = muted
		if not muted and _agent_playback:
			# Audio queued before muting is stale by now.
			_agent_playback.clear_buffer()


func get_mic_level() -> float:
	return 0.0 if _mic_muted else _mic_level


func get_agent_level() -> float:
	var bus_idx := AudioServer.get_bus_index(_agent_bus_name) if _agent_bus_name else -1
	if bus_idx < 0 or _speaker_muted:
		return 0.0
	var peak_db := maxf(
		AudioServer.get_bus_peak_volume_left_db(bus_idx, 0),
		AudioServer.get_bus_peak_volume_right_db(bus_idx, 0),
	)
	return clampf(db_to_linear(peak_db), 0.0, 1.0)


func _on_room_connected() -> void:
	# godot-livekit also emits connected when the room's connection state recovers.
	if _connected:
		return
	_connected = true
	_setup_mic()
	connected.emit()


func _on_room_connection_failed(error: String) -> void:
	connection_failed.emit(error)


func _on_room_disconnected() -> void:
	var reason := "reconnect attempts exhausted" if _reconnecting else "disconnected by server"
	_connected = false
	disconnected.emit(reason)


func _on_room_data_received(data: PackedByteArray, _participant: Object, _kind: int, _topic: String) -> void:
	data_received.emit(data)


func _on_track_subscribed(track: Object, _publication: Object, _participant: Object) -> void:
	if track.get_kind() != ClassDB.class_get_integer_constant(&"LiveKitTrack", &"KIND_AUDIO"):
		return
	if _agent_stream:
		_agent_stream.close()
	_agent_stream = ClassDB.class_call_static(&"LiveKitAudioStream", &"from_track", track)
	if not _agent_player:
		_setup_agent_player()


func _on_track_unsubscribed(track: Object, _publication: Object, _participant: Object) -> void:
	if track.get_kind() == ClassDB.class_get_integer_constant(&"LiveKitTrack", &"KIND_AUDIO") and _agent_stream:
		_agent_stream.close()
		_agent_stream = null


func _setup_mic() -> void:
	var mic_stream: AudioStream = _session.mic_stream if _session else null
	if mic_stream == null:
		if not ProjectSettings.get_setting("audio/driver/enable_input", false):
			push_error(
				"Ultravox: microphone input is disabled. Enable Project Settings > Audio > Driver > Enable Input."
			)
		mic_stream = AudioStreamMicrophone.new()

	_mic_bus_name = "UltravoxMic#%d" % get_instance_id()
	_mic_capture = AudioEffectCapture.new()
	_mic_capture.buffer_length = _CAPTURE_BUFFER_SECONDS
	var bus_idx := _add_bus(_mic_bus_name)
	AudioServer.add_bus_effect(bus_idx, _mic_capture)
	# Captured audio is sent to the call, not played locally.
	AudioServer.set_bus_mute(bus_idx, true)

	_mic_resampler = _Resampler.new(AudioServer.get_mix_rate(), _SAMPLE_RATE)
	_setup_audio_processing()

	_audio_source = ClassDB.class_call_static(&"LiveKitAudioSource", &"create", _SAMPLE_RATE, 1, 0)
	_local_track = ClassDB.class_call_static(&"LiveKitLocalAudioTrack", &"create", "audio", _audio_source)
	if _mic_muted:
		_local_track.mute()

	_mic_player = AudioStreamPlayer.new()
	_mic_player.name = "UltravoxMicPlayer"
	_mic_player.stream = mic_stream
	_mic_player.bus = _mic_bus_name
	_session.add_child(_mic_player, false, Node.INTERNAL_MODE_BACK)
	_mic_player.play()

	# Publishing the track and audio processing both block for long enough (tens of ms up front,
	# then several ms per second of audio) to otherwise cause frame hitches.
	_audio_thread_running = true
	_audio_thread = Thread.new()
	_audio_thread.start(_run_audio_thread.bind(_room.get_local_participant()), Thread.PRIORITY_HIGH)


func _setup_audio_processing() -> void:
	var options := {
		"echo_cancellation": _session.echo_cancellation,
		"noise_suppression": _session.noise_suppression,
		"auto_gain_control": _session.auto_gain_control,
		"high_pass_filter": _session.echo_cancellation or _session.noise_suppression,
	}
	if not options.values().has(true):
		return
	if not ClassDB.class_exists(&"LiveKitAudioProcessingModule"):
		if not _warned_missing_apm:
			_warned_missing_apm = true
			push_warning(
				"Ultravox: the installed godot-livekit lacks LiveKitAudioProcessingModule, so echo "
				+ "cancellation and noise suppression are unavailable. Players should use headphones "
				+ "to keep the agent from hearing itself."
			)
		return
	_apm = ClassDB.class_call_static(&"LiveKitAudioProcessingModule", &"create", options)
	if _apm == null or not _session.echo_cancellation:
		return
	# The echo reference is everything the game plays, so other game audio is removed from the
	# mic signal too.
	_reference_capture = AudioEffectCapture.new()
	_reference_capture.buffer_length = _CAPTURE_BUFFER_SECONDS
	AudioServer.add_bus_effect(AudioServer.get_bus_index(_MASTER_BUS), _reference_capture)
	_reference_resampler = _Resampler.new(AudioServer.get_mix_rate(), _SAMPLE_RATE)
	# Echo in the mic signal lags its reference by roughly the output plus input latency.
	_stream_delay_ms = int(AudioServer.get_output_latency() * 2000.0)


func _teardown_mic() -> void:
	if _audio_thread:
		_audio_thread_running = false
		_audio_thread.wait_to_finish()
		_audio_thread = null
	if _mic_player:
		# Stopped first since removing its (muted) bus would otherwise route it to Master until freed.
		_mic_player.stop()
		_mic_player.queue_free()
		_mic_player = null
	if _mic_bus_name:
		_remove_bus(_mic_bus_name)
		_mic_bus_name = ""
	_mic_capture = null
	if _reference_capture:
		var master_idx := AudioServer.get_bus_index(_MASTER_BUS)
		for i in AudioServer.get_bus_effect_count(master_idx):
			if AudioServer.get_bus_effect(master_idx, i) == _reference_capture:
				AudioServer.remove_bus_effect(master_idx, i)
				break
		_reference_capture = null
	_apm = null
	_local_track = null
	_audio_source = null
	_mic_pending.clear()
	_reference_pending.clear()
	_mic_level = 0.0


func _run_audio_thread(local_participant: Object) -> void:
	local_participant.publish_track(
		_local_track,
		{"source": ClassDB.class_get_integer_constant(&"LiveKitTrack", &"SOURCE_MICROPHONE")},
	)
	while _audio_thread_running:
		_pump_reference()
		_pump_mic()
		OS.delay_usec(_AUDIO_THREAD_INTERVAL_USEC)


func _pump_reference() -> void:
	if not _reference_capture or not _apm:
		return
	_reference_pending = _read_capture(_reference_capture, _reference_resampler, _reference_pending)
	var whole := _whole_frames_size(_reference_pending)
	if whole > 0:
		_apm.process_reverse_stream(_reference_pending.slice(0, whole), _SAMPLE_RATE, 1)
		_reference_pending = _reference_pending.slice(whole)


func _pump_mic() -> void:
	if not _mic_capture or not _audio_source:
		return
	_mic_pending = _read_capture(_mic_capture, _mic_resampler, _mic_pending)
	var whole := _whole_frames_size(_mic_pending)
	if whole == 0:
		return
	var audio := _mic_pending.slice(0, whole)
	_mic_pending = _mic_pending.slice(whole)
	if _apm:
		if _reference_capture:
			_apm.set_stream_delay_ms(_stream_delay_ms)
		var processed: PackedFloat32Array = _apm.process_stream(audio, _SAMPLE_RATE, 1)
		if processed.size() == whole:
			audio = processed
	var sum_squares := 0.0
	for sample in audio:
		sum_squares += sample * sample
	_mic_level = clampf(sqrt(sum_squares / whole) * 2.0, 0.0, 1.0)
	# LiveKit's direct capture mode requires exactly 10ms per call.
	for offset in range(0, whole, _FRAME_SAMPLES):
		_audio_source.capture_frame(audio.slice(offset, offset + _FRAME_SAMPLES), _SAMPLE_RATE, 1, _FRAME_SAMPLES)


static func _whole_frames_size(audio: PackedFloat32Array) -> int:
	return audio.size() - audio.size() % _FRAME_SAMPLES


## Appends the mono, resampled contents of [param capture] to [param pending], returning the result.
func _read_capture(capture: AudioEffectCapture, resampler: _Resampler, pending: PackedFloat32Array) -> PackedFloat32Array:
	var frames := capture.get_frames_available()
	if frames == 0:
		return pending
	var stereo := capture.get_buffer(frames)
	var mono := PackedFloat32Array()
	mono.resize(stereo.size())
	for i in stereo.size():
		mono[i] = (stereo[i].x + stereo[i].y) * 0.5
	pending.append_array(resampler.process(mono))
	return pending


func _setup_agent_player() -> void:
	var player: Node = _session.agent_audio_player if _session else null
	if player and not (player is AudioStreamPlayer or player is AudioStreamPlayer2D or player is AudioStreamPlayer3D):
		push_error("Ultravox: agent_audio_player must be an AudioStreamPlayer, AudioStreamPlayer2D or AudioStreamPlayer3D.")
		player = null
	_owns_agent_player = player == null
	if _owns_agent_player:
		player = AudioStreamPlayer.new()
		player.name = "UltravoxAgentPlayer"
		player.bus = _session.agent_audio_bus
		_session.add_child(player, false, Node.INTERNAL_MODE_BACK)
	_agent_player = player

	# A dedicated bus (sending to the player's own) lets get_agent_level() read the agent's volume.
	_agent_player_original_bus = player.bus
	_agent_bus_name = "UltravoxAgent#%d" % get_instance_id()
	var bus_idx := _add_bus(_agent_bus_name)
	AudioServer.set_bus_send(bus_idx, _agent_player_original_bus)
	player.bus = _agent_bus_name

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = _SAMPLE_RATE
	generator.buffer_length = _AGENT_BUFFER_SECONDS
	player.stream = generator
	player.play()
	player.stream_paused = _speaker_muted
	_agent_playback = player.get_stream_playback()


func _teardown_agent_player() -> void:
	if _agent_player and is_instance_valid(_agent_player):
		_agent_player.stop()
		if _owns_agent_player:
			_agent_player.queue_free()
		else:
			_agent_player.stream = null
			_agent_player.bus = _agent_player_original_bus
	_agent_player = null
	_agent_playback = null
	if _agent_bus_name:
		_remove_bus(_agent_bus_name)
		_agent_bus_name = ""


func _pump_agent_audio() -> void:
	if _agent_stream and _agent_playback:
		_agent_stream.poll(_agent_playback)


static func _add_bus(bus_name: String) -> int:
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	return idx


static func _remove_bus(bus_name: String) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx > 0:
		AudioServer.remove_bus(idx)


## Streaming linear-interpolation resampler for mono audio.
class _Resampler:
	var _ratio: float
	var _position := 0.0
	var _previous := 0.0

	func _init(from_rate: float, to_rate: float) -> void:
		_ratio = from_rate / to_rate

	func process(input: PackedFloat32Array) -> PackedFloat32Array:
		if is_equal_approx(_ratio, 1.0):
			return input
		var output := PackedFloat32Array()
		# _position is relative to input[0], where index -1 is the previous chunk's last sample.
		while _position < input.size() - 1:
			var i := floori(_position)
			var a := _previous if i < 0 else input[i]
			var b := input[i + 1]
			output.append(lerpf(a, b, _position - i))
			_position += _ratio
		_position -= input.size()
		if input.size() > 0:
			_previous = input[input.size() - 1]
		return output
