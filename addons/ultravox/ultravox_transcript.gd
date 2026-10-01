class_name UltravoxTranscript
extends RefCounted
## A transcription of a single utterance.

## The participant responsible for an utterance.
enum Role { USER, AGENT }

## How a message was communicated.
enum Medium { VOICE, TEXT }

## The possibly-incomplete text of an utterance.
var text: String
## Whether the text is complete or the utterance is ongoing.
var is_final: bool
## Who emitted the utterance.
var speaker: Role
## The medium through which the utterance was emitted.
var medium: Medium
## The ordinal for sorting the transcript.
var ordinal: int


func _init(p_text: String, p_is_final: bool, p_speaker: Role, p_medium: Medium, p_ordinal: int) -> void:
	text = p_text
	is_final = p_is_final
	speaker = p_speaker
	medium = p_medium
	ordinal = p_ordinal


func _to_string() -> String:
	return "UltravoxTranscript(%d, %s, %s, final=%s): %s" % [
		ordinal, Role.keys()[speaker], Medium.keys()[medium], is_final, text
	]
