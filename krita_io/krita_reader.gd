@tool
extends RefCounted

const PIXEL_REMAPPING : Array[int] = [2, 1, 0, 3]
const ByteWalker := preload("byte_walker.gd")


func parse_krita_layer(layer_data : PackedByteArray, max_size : Vector2i) -> Image:
	var file := ByteWalker.create(layer_data)
	var _version_tag := file.get_simple_property()
	var tile_width := file.get_simple_property() # width in pixels of each tile
	var tile_height := file.get_simple_property() # height in px of each tile
	var pixel_size := file.get_simple_property() # bytes stored per pixel, used for size calculations
	var tile_count := file.get_simple_property() # amount of tiles making up the image
	
	# optimization: declare all variables beforehand to avoid overhead
	var x : int
	var y : int
	var compression : String
	var compressed_size : int
	var compressed_data : PackedByteArray
	var data : PackedByteArray
	var data_reorganized : PackedByteArray
	var n : int
	var img : Image
	
	var tiles : Dictionary[Vector2i, Image] = {}
	var img_size := Rect2i(0, 0, 0, 0) # a reference size for creating the base image later 
	
	for tile_idx in tile_count:
		# each tile beins with the following payload:
		# x position,y position,compression method,compressed length[NEW LINE]
		var tile_data := file.get_line().split(",")
		assert(tile_data.size() > 3)
		
		x = int(tile_data[0])
		y = int(tile_data[1])
		
		# update the image size so it encapsulates the whole layer
		img_size = img_size.merge(Rect2i(x, y, tile_width, tile_height))
		
		compression = tile_data[2] as String
		compressed_size = int(tile_data[3])
		compressed_data = file.get_buffer(compressed_size)
		
		data = PackedByteArray()
		match compression:
			"LZF": data = parse_lzf_chunk(compressed_data, pixel_size * (tile_width * tile_height))
			_: print("New compression format discovered: " + compression)
	
		# sooooo apparently instead of storing RGBARGBARGBA like you would think,
		# krita stores color data like this: BBBBB....GGGGGG....RRRRRR...AAAAA.... 
		# so the next bit is all dedicated to remapping the data we read to the order that
		# godot is expecting
		data_reorganized.resize(data.size())
		n = 0
		
		# could probably be optimized into one for loop like this:
		#for i in tile_width * tile_height * pixel_size:
			#data_reorganized[i] = data[PIXEL_REMAPPING[i % pixel_size] * tile_width * tile_height  + int(i / pixel_size)] 
		# double for loops are a major source of inefficieny especially in gdscript
		for px in tile_width * tile_height:
			for idx in pixel_size:
				data_reorganized[n] = data[PIXEL_REMAPPING[idx] * tile_width * tile_height + px] # grab every 4ish bytes and reorganize that way
				n += 1
		
		img = Image.create_from_data(tile_width, tile_height, false, Image.FORMAT_RGBA8, data_reorganized)
		tiles[Vector2i(x, y)] = img
	
	# assemble the main image. Similar to what is done in the texture packer script
	var main_image := Image.create_empty(mini(img_size.size.x, max_size.x), mini(img_size.size.y, max_size.y), false, Image.FORMAT_RGBA8)
	for tile_pos in tiles:
		var region := Rect2i(0, 0, tile_width, tile_height)
		main_image.blit_rect(tiles[tile_pos], region, tile_pos)

	return main_image


# implimented using the krita documentation and lots of help from generative AI to get me out of sticky situations
func parse_lzf_chunk(input_data: PackedByteArray, uncompressed_size: int) -> PackedByteArray:
	var output := PackedByteArray()
	output.resize(uncompressed_size)
	
	# the index we are reading from in the input array
	# this is one of those magic chatgpt fixes -- by setting it to one 
	# we avoid offset errors that make the image look weird
	var read_index := 1
	
	# the index we are writing to in the output array
	var write_index := 0 
	
	while write_index < uncompressed_size:
		# read the first bit in the next sequence. This tells us what the data that follows will be
		var control := input_data[read_index]
		# every time we read from input data we have to increase the spot we're reading from by 1
		read_index += 1
		
		# if we will exceed the size of the file, exit early
		# this fixes a lot of visual errors for some reason
		if write_index + control + 1 > uncompressed_size:
			#print("EOF EXCEEDED")
			break
		
		# if the control bit is less than 32, that means that there are exactly that many bits of
		# exact color data following. We can copy them directly over to the output array
		if control < 32:
			var length := control + 1 # since control bit could be 0, we read one more bit that it says
			
			# copy over the data
			for i in length:
				output[write_index] = input_data[read_index]
				read_index += 1
				# just like the read index, we have to increment the write index
				# every time we write to the output
				write_index += 1
		else:
			# if the control bit is 32 or more, that means that the next chunk is compressed
			# the length in bytes of the next segment is stored in the top 3 bits of the control byte
			var length := control >> 5
			# the algorithm compresses data by linking to sections earlier in the image that are
			# repeated now. the remaining bits of the control byte tell us how many times it is repeated
			var offset := (control & 0x1F) << 8
			
			# since the length value is only 8 bit, it has a max of 7
			# compressed streams are often longer than that though, so if it maxes out it encodes
			# the remaining length in the next byte after the control byte
			if length == 7:
				length += input_data[read_index]
				read_index += 1
			
			length += 2 # the minimum length is 2 apparently
			offset += input_data[read_index] # apparently it also encodes an additional backwards offset
			read_index += 1
			
			# the first value we will look back to in memory to copy over to current memory
			var backtrack_index := write_index - offset - 1
			
			# early exit scenarios and error catching 
			if write_index + length > uncompressed_size or backtrack_index < 0:
				print("WRITE INDEX EXCEEDED")
				break
			
			# copy over the requested bytes from further back in memory
			for i in length:
				output[write_index] = output[backtrack_index]
				backtrack_index += 1
				write_index += 1
	
	return output
