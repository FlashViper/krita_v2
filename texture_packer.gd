extends RefCounted

var verbose : bool

## Takes in an array of textures and some optional parameters
## Returns a dictionary containing the following:
## 	texture: an assembled texture atlas
## 	frames: an array of dictionaries with the following parameters
##		source_texture: the texture that is placed in the frame
##		atlas_region: the region the texture is placed in
##		source_region: the cropped region of the original texture that was copied over
##		pivot: the pivot offset due to cropping of the image
## Potential parameters: padding (default: 2), verbose (default: false)
func pack(textures: Array[Texture2D], parameters := {}) -> Dictionary:
	if textures == null:
		printerr("Tried to pass a null array to pack_textures in texture_packer.gd")
		return {}
	
	var verbose := parameters.get("verbose", false)
	# First, crop all of the sprites by their alpha
	# so we are left with the least empty space possible
	var frames : Array[SpriteRegion] = crop_to_frame(textures)
	
	# Assemble a list of the cropped regions of the textures
	var rects : Array[Rect2i] = []
	for f in frames:
		rects.append(f.region)
	
	# Pack the rects using out magical packer function
	var packed := pack_rects(rects, parameters.get("padding", 2))
	var data : Array[Dictionary] = []
	
	# Assemble some data about each of the textures
	for i in frames.size():
		var frame_data := frames[i].get_data()
		frame_data["source_texture"] = textures[i] # Texture we are pulling from
		frame_data["atlas_region"] = packed["result"][i] # Region on the final atlas
		
		data.append(frame_data)
		frames[i].region = packed.result[i]
	
	# Use our magical texture assembly function to pack all of the
	# textures together
	var tex := assemble_texture(data, packed.width, packed.height)
	
	# Return our result!
	return {
		"frames": data, # The individual frames, including their atlas position and their pivot
		"texture": tex  # The final assembled texture
	}


func crop_to_frame(textures : Array[Texture2D]) -> Array[SpriteRegion]:
	var frames : Array[SpriteRegion] = []
	
	# first, crop the textures into their usable rects
	for t in textures:
		var frame := SpriteRegion.new()
		frame.region = crop_rect_texture(t)
		frame.pivot = (t.get_size() * 0.5) - Vector2(frame.region.position)
		frames.append(frame)
	
	return frames


func pack_rects(rects: Array[Rect2i], padding := 0) -> Dictionary:
	# Store the original order of the rects so we can preserve their connections
	var remapped : Array[int] = []
	for i in rects.size():
		remapped.append(i)
	
	# sort the rects by order of ascending area (smallest come first)
	remapped.sort_custom(func(a: int, b: int): return rects[a].get_area() < rects[b].get_area())
	
	var placed := {} # Dictionary linking index in rects to final location
	var availible_points : Array[Vector2i] = [Vector2i.ZERO] # Points availible to place a rect
	var max_x := 0 # Current atlas size (x)
	var max_y := 0 # Current atlas size (y)
	
	for i in remapped.size():
		# Get the rect with the next most area
		# Create a new rect that we can try to place
		var index : int = remapped.pop_back()
		var rect : Rect2i = rects[index]
		var placed_rect := Rect2i(Vector2i(), rect.size)
		var min_cost := INF # The lowest cost we can find for this iteration
		
		# Loop through the points that we have determined can be placed at
		for n in availible_points.size():
			# Grab the next availible point and find the new atlas size
			var a := availible_points[n]
			var new_max_x := maxi(max_x, a.x + rect.size.x)
			var new_max_y := maxi(max_y, a.y + rect.size.y)
			
			# Compute the cost (length of the size vector)
			var cost := Vector2(new_max_x, new_max_y).length_squared()
			
			# If the cost is less than the current lowest cost, replace it
			# this is probably the most expensive part of the algorithm tbh
			# since we have to check it against every other rect we've placed so far
			if cost < min_cost:
				var overlaps := false
				for idx in placed:
					if placed[idx].intersects(Rect2i(a, rect.size)):
						overlaps = true
						break
				
				if overlaps:
					continue
				
				placed_rect.position = a
				min_cost = cost
		
		# Update the new size values
		max_x = maxi(max_x, placed_rect.end.x)
		max_y = maxi(max_y, placed_rect.end.y)
		
		# To save on memory, maybe?, remove all
		# availible points that lie inside the placed rect
		# ---do I even need this? probably?
		# ---turn on if you ever see problems with this script
		var expanded := placed_rect.grow(padding)
		for ii in range(availible_points.size(), 0, -1):
			if expanded.has_point(availible_points[ii - 1]):
				availible_points.remove_at(ii - 1)
		
		
		# To the availible points, add...
		#	- The bottom-right corner of the rect
		#	- The top-right corner of the rect
		#	- The bottom-left corner of the rect
		availible_points.append(placed_rect.end + Vector2i.ONE * padding)
		availible_points.append(Vector2i(placed_rect.position.x, placed_rect.end.y) + Vector2i(0, padding))
		availible_points.append(Vector2i(placed_rect.end.x, placed_rect.position.y) + Vector2i(padding, 0))
		availible_points.append(Vector2i(max_x, max_y))
		placed[index] = placed_rect
	
	# Create a new array by translating back from the mapping
	# into the correct indicies
	var result : Array[Rect2i] = rects.duplicate()
	for i in placed:
		result[i] = placed[i]
	
	var total_area := 0
	for i in rects.size():
		total_area += rects[i].get_area()
	
	if verbose:
		print("Efficiency: ", round(100 * (1 - (float(max_x*max_y) - float(total_area)) / float(total_area))), """%""")

	# Return a dictionary with key details about the calculations
	return {
		"result": result,
		"width": max_x,
		"height": max_y,
	}


func crop_rect_texture(texure: Texture2D, alpha_threshold := 0.1, padding := 0) -> Rect2i:
	return crop_rect(texure.get_image(), alpha_threshold, padding)

# Pretty self-explanatory. Given a texture, returns a Rect that
# represents the minimum region of the texture that conains an image
# If that sounds confusing, use your intuition for cropping
# Or just write a simple test script :)
func crop_rect(img: Image, alpha_threshold := 0.2, padding := 0) -> Rect2i:
	var result := Rect2i(Vector2i(), img.get_size())
	
	for x in img.get_width():
		var texture_starts := false
		for y in img.get_height():
			if img.get_pixel(x, y).a > alpha_threshold:
				texture_starts = true
				break
		if texture_starts:
			result.position.x = x - padding
			result.size.x -= x
			break
	
	for x in range(img.get_width() - 1, -1, -1):
		var texture_starts := false
		for y in range(img.get_height() - 1, -1, -1):
			if img.get_pixel(x, y).a > alpha_threshold:
				texture_starts = true
				break
		if texture_starts:
			result.size.x = x - result.position.x
			break
	
	for y in img.get_height():
		var texture_starts := false
		for x in img.get_width():
			if img.get_pixel(x, y).a > alpha_threshold:
				texture_starts = true
				break
		if texture_starts:
			result.position.y = y - padding
			result.size.y -= y
			break
	
	for y in range(img.get_height() - 1, -1, -1):
		var texture_starts := false
		for x in range(img.get_width() - 1, -1, -1):
			if img.get_pixel(x, y).a > alpha_threshold:
				texture_starts = true
				break
		if texture_starts:
			result.size.y = y - result.position.y
			break
	
	# hacky fix because I don't know how to code well
	# otherwise final result will be clipped by one pixel
	result.size += Vector2i.ONE
	return result


func assemble_texture(data: Array[Dictionary], width: int, height: int) -> Texture2D:
	# Create an image with the required specs
	var img := Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	for d in data:
		var source := d.source_texture as Texture2D
		var source_region := d.source_region as Rect2i
		var atlas_region := d.atlas_region as Rect2i
		
		# Lifesaving function that speeds up image creation immensly
		# Directly copies the image data from the source to the final image
		# Skips doing a super nasty double for-loop, which is slow even outside
		# of GDScript, where it takes up almost as much time as packing the rects,
		# sometimes even more
		img.blit_rect(source.get_image(), source_region, atlas_region.position)

	var tex := ImageTexture.create_from_image(img)
	return tex


class SpriteRegion:
	var region : Rect2i
	var pivot : Vector2
	
	func get_data() -> Dictionary:
		return {
			"source_region": region,
			"pivot": pivot,
		}
