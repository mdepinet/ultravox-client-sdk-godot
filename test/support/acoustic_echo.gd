extends Node
## Simulates a speaker-to-microphone echo path by feeding everything the game plays back into
## [member mic_stream], attenuated and delayed (by roughly one audio mix).

const _ECHO_GAIN := 0.25

## Use as an UltravoxSession's mic_stream.
var mic_stream := AudioStreamGenerator.new()

var _session: UltravoxSession
var _capture := AudioEffectCapture.new()
var _playback: AudioStreamGeneratorPlayback


func _init(session: UltravoxSession) -> void:
	_session = session
	mic_stream.mix_rate = AudioServer.get_mix_rate()
	mic_stream.buffer_length = 1.0
	_capture.buffer_length = 1.0


func _enter_tree() -> void:
	AudioServer.add_bus_effect(AudioServer.get_bus_index(&"Master"), _capture, 0)


func _exit_tree() -> void:
	var master_idx := AudioServer.get_bus_index(&"Master")
	for i in AudioServer.get_bus_effect_count(master_idx):
		if AudioServer.get_bus_effect(master_idx, i) == _capture:
			AudioServer.remove_bus_effect(master_idx, i)
			break


func _process(_delta: float) -> void:
	var echo := _capture.get_buffer(_capture.get_frames_available())
	if _playback == null:
		# The session plays mic_stream on an internal player once its call connects.
		for child in _session.get_children(true):
			if child is AudioStreamPlayer and child.stream == mic_stream and child.playing:
				_playback = child.get_stream_playback()
		return
	for i in echo.size():
		echo[i] *= _ECHO_GAIN
	_playback.push_buffer(echo)
