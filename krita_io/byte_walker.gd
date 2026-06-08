@tool
extends RefCounted

const ByteWalker := preload("byte_walker.gd")
var bytes : PackedByteArray
var cursor_position : int

func get_line() -> String:
	var result := ""
	var next := ""
	while cursor_position < bytes.size():
		next = char(bytes[cursor_position])
		cursor_position += 1 # incriment next counter regardless of new line
		
		if next == "\n": # 0x0A is a newline character in utf8
			break
		else:
			result += next
	return result


func get_simple_property() -> int:
	return int(get_line().split(" ")[1])


func get_buffer(length: int) -> PackedByteArray:
	cursor_position += length
	return bytes.slice(cursor_position - length, cursor_position + 1)


static func create(data) -> ByteWalker:
	var result := ByteWalker.new()
	result.bytes = data
	result.cursor_position = 0
	return result
