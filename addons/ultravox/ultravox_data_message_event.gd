class_name UltravoxDataMessageEvent
extends RefCounted
## Delivered by [signal UltravoxSession.data_message] for every data message received, including
## those the SDK handles itself. See https://docs.ultravox.ai/datamessages for message types.

## The parsed message.
var message: Dictionary

var _default_prevented := false


func _init(p_message: Dictionary) -> void:
	message = p_message


## Suppresses the SDK's default handling of this message (e.g. updating status or transcripts).
func prevent_default() -> void:
	_default_prevented = true


## Whether [method prevent_default] was called.
func is_default_prevented() -> bool:
	return _default_prevented
