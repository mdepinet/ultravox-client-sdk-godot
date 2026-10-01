extends Control
## A minimal Ultravox voice call UI. Paste the joinUrl of a call created by your server (see
## https://docs.ultravox.ai/gettingstarted/quickstart) and press Join.
##
## If the call was created with a client tool named "changeBackgroundColor" (taking a "color"
## string parameter), the agent can change this scene's background color.

const Status := UltravoxSession.Status

@onready var session: UltravoxSession = $UltravoxSession

var _background := ColorRect.new()
var _join_url := LineEdit.new()
var _join_button := Button.new()
var _mic_button := Button.new()
var _speaker_button := Button.new()
var _status_label := Label.new()
var _agent_indicator := ColorRect.new()
var _mic_level := ProgressBar.new()
var _transcript_view := RichTextLabel.new()
var _text_input := LineEdit.new()


func _ready() -> void:
	_build_ui()
	session.status_changed.connect(_on_status_changed)
	session.transcripts_changed.connect(_render_transcripts)
	session.error.connect(func(message: String) -> void: _status_label.text = "Error: " + message)
	session.mic_muted_changed.connect(func(muted: bool) -> void: _mic_button.text = "Unmute mic" if muted else "Mute mic")
	session.speaker_muted_changed.connect(func(muted: bool) -> void:
		_speaker_button.text = "Unmute speaker" if muted else "Mute speaker")
	session.register_tool_implementation("changeBackgroundColor", _change_background_color)
	_on_status_changed(session.status)


func _process(_delta: float) -> void:
	var agent_level := session.get_agent_level()
	_agent_indicator.scale = Vector2.ONE * (1.0 + agent_level)
	_mic_level.value = session.get_mic_level()


func _change_background_color(parameters: Dictionary) -> String:
	var color := Color.from_string(str(parameters.get("color", "")), Color.TRANSPARENT)
	if color == Color.TRANSPARENT:
		return "Unknown color. Use a color name like 'teal' or a hex code like '#336699'."
	_background.color = color.darkened(0.6)
	return "Changed the background color."


func _on_join_pressed() -> void:
	if session.status == Status.DISCONNECTED:
		session.join_call(_join_url.text.strip_edges(), "godot-example")
	else:
		session.leave_call()


func _on_text_submitted(text: String) -> void:
	if text and session.send_text(text) == OK:
		_text_input.clear()


func _on_status_changed(status: Status) -> void:
	_status_label.text = "Status: " + Status.keys()[status].to_lower()
	_join_button.text = "Join" if status == Status.DISCONNECTED else "Leave"
	_text_input.editable = status in [Status.LISTENING, Status.THINKING, Status.SPEAKING]


func _render_transcripts() -> void:
	_transcript_view.clear()
	for transcript in session.transcripts:
		var speaker := "Agent" if transcript.speaker == UltravoxTranscript.Role.AGENT else "You"
		var color := "#8da5f3" if transcript.speaker == UltravoxTranscript.Role.AGENT else "#f3d38d"
		# Escaped since agent text can contain brackets (e.g. "[laughs]") that BBCode would parse.
		var text := transcript.text.strip_edges().replace("[", "[lb]")
		_transcript_view.append_text("[color=%s]%s:[/color] %s\n" % [color, speaker, text])


func _build_ui() -> void:
	_background.color = Color(0.1, 0.1, 0.12)
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var join_row := HBoxContainer.new()
	_join_url.placeholder_text = "Paste a call's joinUrl (wss://...)"
	_join_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_button.pressed.connect(_on_join_pressed)
	join_row.add_child(_join_url)
	join_row.add_child(_join_button)
	column.add_child(join_row)

	var controls := HBoxContainer.new()
	_mic_button.text = "Mute mic"
	_mic_button.pressed.connect(session.toggle_mic_mute)
	_speaker_button.text = "Mute speaker"
	_speaker_button.pressed.connect(session.toggle_speaker_mute)
	_mic_level.max_value = 1.0
	_mic_level.show_percentage = false
	_mic_level.custom_minimum_size = Vector2(120, 0)
	_mic_level.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var indicator_holder := Control.new()
	indicator_holder.custom_minimum_size = Vector2(32, 32)
	_agent_indicator.color = Color("#8da5f3")
	_agent_indicator.size = Vector2(16, 16)
	_agent_indicator.position = Vector2(8, 8)
	_agent_indicator.pivot_offset = Vector2(8, 8)
	indicator_holder.add_child(_agent_indicator)
	for control in [_mic_button, _speaker_button, _mic_level, indicator_holder, _status_label]:
		controls.add_child(control)
	column.add_child(controls)

	_transcript_view.bbcode_enabled = true
	_transcript_view.scroll_following = true
	_transcript_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_transcript_view)

	_text_input.placeholder_text = "Type a message and press Enter"
	_text_input.text_submitted.connect(_on_text_submitted)
	column.add_child(_text_input)
