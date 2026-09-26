extends Node
## An in-process stand-in for the Ultravox call websocket, sufficient for exercising
## UltravoxSession. Implements just enough of RFC 6455 to see the request URL and to close
## connections cleanly or abruptly.

const _WEBSOCKET_GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
const _OPCODE_TEXT := 0x1
const _OPCODE_CLOSE := 0x8

## The request path (including query) of the most recent connection.
var request_path := ""
## Text messages received from the client, parsed as JSON.
var received: Array = []
## Whether the client sent a close frame.
var client_closed := false

var _tcp_server := TCPServer.new()
var _peer: StreamPeerTCP
var _handshake_done := false
var _buffer := PackedByteArray()


func _init() -> void:
	var err := _tcp_server.listen(0, "127.0.0.1")
	assert(err == OK, "FakeUltravoxServer failed to listen: %s" % error_string(err))


func join_url(query := "") -> String:
	return "ws://127.0.0.1:%d/calls/test-call%s" % [_tcp_server.get_local_port(), query]


func is_client_connected() -> bool:
	return _handshake_done


## Returns the query parameters of the most recent connection's request.
func request_params() -> Dictionary:
	var params := {}
	var parts := request_path.split("?", true, 1)
	if parts.size() > 1:
		for pair in parts[1].split("&", false):
			params[pair.get_slice("=", 0).uri_decode()] = pair.get_slice("=", 1).uri_decode()
	return params


func send(message: Dictionary) -> void:
	_send_frame(_OPCODE_TEXT, JSON.stringify(message).to_utf8_buffer())


func send_room_info(room_url := "wss://room.example", token := "test-token") -> void:
	send({"type": "room_info", "roomUrl": room_url, "token": token})


## Closes the connection with a close frame carrying [param code].
func close(code := 1000, reason := "") -> void:
	var payload := PackedByteArray([code >> 8, code & 0xFF])
	payload.append_array(reason.to_utf8_buffer())
	_send_frame(_OPCODE_CLOSE, payload)
	_peer.disconnect_from_host()


## Drops the TCP connection without a close frame.
func drop() -> void:
	_peer.disconnect_from_host()


func _process(_delta: float) -> void:
	if _tcp_server.is_connection_available():
		_peer = _tcp_server.take_connection()
		_handshake_done = false
		_buffer.clear()
	if _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var available := _peer.get_available_bytes()
	if available > 0:
		_buffer.append_array(_peer.get_data(available)[1])
	if not _handshake_done:
		_try_handshake()
	if _handshake_done:
		_read_frames()


func _try_handshake() -> void:
	var text := _buffer.get_string_from_ascii()
	var end := text.find("\r\n\r\n")
	if end < 0:
		return
	var lines := text.substr(0, end).split("\r\n")
	request_path = lines[0].split(" ")[1]
	var key := ""
	for line in lines:
		if line.to_lower().begins_with("sec-websocket-key:"):
			key = line.get_slice(":", 1).strip_edges()
	var sha1 := HashingContext.new()
	sha1.start(HashingContext.HASH_SHA1)
	sha1.update((key + _WEBSOCKET_GUID).to_ascii_buffer())
	var accept := Marshalls.raw_to_base64(sha1.finish())
	var response := (
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
		+ "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
	)
	_peer.put_data(response.to_ascii_buffer())
	_buffer = _buffer.slice(end + 4)
	_handshake_done = true


func _read_frames() -> void:
	while _buffer.size() >= 2:
		var opcode := _buffer[0] & 0x0F
		var length := _buffer[1] & 0x7F
		var offset := 2
		if length == 126:
			if _buffer.size() < 4:
				return
			length = (_buffer[2] << 8) | _buffer[3]
			offset = 4
		elif length == 127:
			if _buffer.size() < 10:
				return
			length = 0
			for i in 8:
				length = (length << 8) | _buffer[2 + i]
			offset = 10
		# Client frames are always masked.
		if _buffer.size() < offset + 4 + length:
			return
		var mask := _buffer.slice(offset, offset + 4)
		var payload := _buffer.slice(offset + 4, offset + 4 + length)
		for i in payload.size():
			payload[i] ^= mask[i % 4]
		_buffer = _buffer.slice(offset + 4 + length)
		if opcode == _OPCODE_TEXT:
			received.append(JSON.parse_string(payload.get_string_from_utf8()))
		elif opcode == _OPCODE_CLOSE:
			client_closed = true


func _send_frame(opcode: int, payload: PackedByteArray) -> void:
	var frame := PackedByteArray([0x80 | opcode])
	if payload.size() < 126:
		frame.append(payload.size())
	elif payload.size() < 65536:
		frame.append_array([126, payload.size() >> 8, payload.size() & 0xFF])
	else:
		frame.append(127)
		for i in range(7, -1, -1):
			frame.append((payload.size() >> (8 * i)) & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)
