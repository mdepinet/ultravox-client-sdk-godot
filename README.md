# Ultravox Client SDK (Godot)

This is the Godot client library for [Ultravox](https://ultravox.ai). It lets games and apps built
with Godot 4.5+ hold real-time voice conversations with Ultravox agents. For example, an NPC can
talk with the player, with its voice playing from the NPC's position in the world.

The SDK is a pure GDScript addon built on the
[godot-livekit](https://github.com/NodotProject/godot-livekit) GDExtension, which provides the
WebRTC transport Ultravox calls use.

## Platform support

| Platform | Status |
| --- | --- |
| Linux (x86_64), Windows (x86_64), macOS (arm64, x86_64) | Supported (Linux is tested). |
| Android (arm64) | godot-livekit ships Android binaries, so this may work, but it hasn't been tested. |
| Web, iOS | Not supported. godot-livekit doesn't support them yet. |

## Installation

1. Install godot-livekit. Download `godot-livekit-release.zip` from its
   [releases](https://github.com/NodotProject/godot-livekit/releases) and copy its
   `addons/godot-livekit` folder into your project's `addons/` folder.
2. Copy this repository's `addons/ultravox` folder into your project's `addons/` folder.
3. Enable **Project Settings > Audio > Driver > Enable Input** so calls can use the microphone.
4. Optionally enable the Ultravox plugin (**Project > Project Settings > Plugins**). The plugin
   only warns about missing setup; the SDK works without it.
5. Restart the editor so the GDExtension loads.

On macOS, exported games also need a microphone usage description. Set it under **Export >
macOS > Privacy > Microphone Usage Description**.

### Echo cancellation

When players use speakers rather than headphones, the agent's voice (and other game audio)
reaches the microphone, and the agent may respond to itself. WebRTC's echo cancellation prevents
this. The SDK uses it automatically when godot-livekit provides the `LiveKitAudioProcessingModule`
class. Current godot-livekit releases don't include it yet. Until they do, build godot-livekit
with that class added (a small binding over the LiveKit C++ SDK's `AudioProcessingModule`), or
tell players to wear headphones. Without the class, the SDK logs a warning once and continues
without echo cancellation, noise suppression, or gain control.

## Quick start

Add an `UltravoxSession` node to your scene, then join a call:

```gdscript
@onready var session: UltravoxSession = $UltravoxSession

func _ready() -> void:
    session.status_changed.connect(func(status): print("Status: ", UltravoxSession.Status.keys()[status]))
    session.transcripts_changed.connect(func(): print(session.transcripts.back()))
    session.join_call(join_url)

func _exit_tree() -> void:
    session.leave_call()
```

Join URLs come from creating a call with the Ultravox API. Create calls on your server, because
the API key must never ship inside your game. See the [docs](https://docs.ultravox.ai) for more
info.

## Signals

- `status_changed(status)`: the session's status changed.
- `transcripts_changed`: a transcript was added or updated. Read them from `session.transcripts`.
- `data_message(event)`: any [data message](https://docs.ultravox.ai/datamessages) was received,
  including those the SDK handles itself. Call `event.prevent_default()` to suppress the SDK's
  handling of the message (`event.message` is the parsed message).
- `error(message)`: the session ended unexpectedly, for example because the network dropped the
  call's media connection. Emitted immediately before the session's final `status_changed`
  signals. Not emitted when a call ends normally.
- `mic_muted_changed(muted)` / `speaker_muted_changed(muted)`: mute state changed.

Methods that can fail (such as `join_call` and `send_text`) return a Godot `Error` and log the
reason with `push_error`.

## Session status

`session.status` is one of the `UltravoxSession.Status` values:

| Status | Description |
| --- | --- |
| `DISCONNECTED` | The session is not connected and not attempting to connect. This is the initial state. |
| `DISCONNECTING` | The client is disconnecting from the session. |
| `CONNECTING` | The client is attempting to connect to the session. |
| `IDLE` | The client is connected to the session and the server is warming up. |
| `LISTENING` | The client is connected and the server is listening for voice input. |
| `THINKING` | The client is connected and the server is considering its response. The user can still interrupt. |
| `SPEAKING` | The client is connected and the server is playing response audio. The user can interrupt as needed. |

## Transcripts

`session.transcripts` holds `UltravoxTranscript` objects with these fields:

- `text`: the possibly-incomplete text of an utterance.
- `is_final`: whether the text is complete or the utterance is ongoing.
- `speaker`: `UltravoxTranscript.Role.USER` or `.AGENT`.
- `medium`: `UltravoxTranscript.Medium.VOICE` or `.TEXT`.
- `ordinal`: the transcript's position in the conversation.

## Agent audio and positional voices

By default, agent audio plays through an internal `AudioStreamPlayer` on the `agent_audio_bus`
bus (`Master` by default). To place the voice in the world, set `agent_audio_player` to an
`AudioStreamPlayer2D` or `AudioStreamPlayer3D`, for example one attached to an NPC:

```gdscript
session.agent_audio_player = $Npc/VoicePlayer  # an AudioStreamPlayer3D
```

The SDK replaces that player's stream during calls. `session.get_agent_level()` and
`session.get_mic_level()` return current audio levels from 0 to 1. Use them for speech
indicators or simple mouth animation.

## Client tools

Register implementations for
[client tools](https://docs.ultravox.ai/tools/custom/client-tools) the call's agent may use.
The implementation receives the tool's parameters as a `Dictionary`. It returns a `String`
result, or a `Dictionary` with `"result"` and `"responseType"` keys and optional
`"agentReaction"` (an `UltravoxSession.AgentReaction`) and `"updateCallState"` keys. To report a
failure, return `{"error": "some message"}`. Implementations can be coroutines that use `await`.

```gdscript
session.register_tool_implementation("openDoor", func(params: Dictionary) -> String:
    var door := get_node(params["doorName"])
    await door.open()
    return "The door is open."
)
```

## Other methods

- `send_text(text, urgency, placement)`: sends a user message via text. `urgency` is an
  `UltravoxSession.TextMessageUrgency` and `placement` is an
  `UltravoxSession.TextMessagePlacement`. Both default to the server's defaults.
- `set_output_medium(medium)`: switches the agent between voice and text output
  (`UltravoxTranscript.Medium`).
- `send_data(message)`: sends any [data message](https://docs.ultravox.ai/datamessages).
- `mute_mic()`, `unmute_mic()`, `toggle_mic_mute()`, `is_mic_muted`: control the user's mic.
- `mute_speaker()`, `unmute_speaker()`, `toggle_speaker_mute()`, `is_speaker_muted`: control
  the agent's audio.

## Configuration

These are set on the `UltravoxSession` node, most of them in the Inspector:

- `additional_messages`: extra data message types to receive (e.g. `["debug"]`).
- `agent_audio_player` and `agent_audio_bus`: see above.
- `echo_cancellation`, `noise_suppression`, `auto_gain_control`: WebRTC audio processing for
  the mic (all on by default; each requires `LiveKitAudioProcessingModule`).
- `mic_stream`: the `AudioStream` that provides the user's audio. Defaults to an
  `AudioStreamMicrophone`. Set it to another stream to feed the call recorded or generated audio.

## Differences from the web SDK

- Agent video tracks are not supported.
- WebRTC configuration (e.g. forcing TURN relay) isn't supported because godot-livekit doesn't
  expose it.

## Example

`example/example.tscn` (this project's main scene) is a minimal call UI. Paste a call's joinUrl
and press Join. If the call includes a `changeBackgroundColor` client tool with a `color`
parameter, the agent can recolor the scene.

## Development

```shell
scripts/setup.sh   # installs godot-livekit and GUT into addons/
scripts/test.sh    # runs all tests headlessly (set GODOT to your Godot binary if it isn't `godot`)
```

Unit tests run against an in-memory room backend and a local websocket server. Integration tests
(`test/integration`) make real calls. They run only when `ULTRAVOX_API_KEY` is set, which can
come from a `.env` file at the repo root, and they cost a few cents per run. The echo
cancellation test also needs a godot-livekit build with `LiveKitAudioProcessingModule`.
