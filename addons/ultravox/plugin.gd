@tool
extends EditorPlugin
## Warns about missing project setup the Ultravox SDK depends on.


func _enable_plugin() -> void:
	if not UltravoxLiveKitBackend.is_available():
		push_warning(
			"Ultravox: the godot-livekit GDExtension was not found. Install it into "
			+ "res://addons/godot-livekit (see the Ultravox addon's README) and restart the editor."
		)
	if not ProjectSettings.get_setting("audio/driver/enable_input", false):
		push_warning(
			"Ultravox: enable Project Settings > Audio > Driver > Enable Input so calls can use "
			+ "the microphone."
		)
