extends EditorImportPlugin

enum {RENDER_WHOLE = 0, RENDER_LAYERS = 1, RENDER_ANIMATION = 2}
const COLOR_FLAGS := "Transparent,Blue,Green,Yellow,Orange,Brown,Red,Pink,Gray"

const PRESETS := ["Whole Image", "Layers to Atlas", "Single Animation"]

const TexturePacker := preload("texture_packer.gd")

func _get_preset_count() -> int: return PRESETS.size()
func _get_preset_name(preset_index: int) -> String: return PRESETS[preset_index]


func _get_importer_name(): return "kra.importer"
func _get_visible_name(): return "Krita File Importer (.kra)"
func _get_recognized_extensions(): return ["kra"]
func _get_save_extension(): return "res"
func _get_resource_type(): return "Texture2D"
func _get_import_options(path: String, preset_index: int) -> Array[Dictionary]:
	return [
	{
		"name": "render_mode",
		"default_value": preset_index,
	},
	{
		"name": "colors_to_merge",
		"default_value": 1 << 3,
		"property_hint": PROPERTY_HINT_FLAGS,
		"hint_string": COLOR_FLAGS
	},
	{
		"name": "hidden_colors",
		"default_value": 1 << 8,
		"property_hint": PROPERTY_HINT_FLAGS,
		"hint_string": COLOR_FLAGS
	},
	]

func _get_option_visibility(path: String, option_name: StringName, options: Dictionary) -> bool:
	if option_name == "render_mode": return false
	return true

func _import(
		source_file: String, 
		save_path: String, 
		options: Dictionary, 
		platform_variants: Array[String], 
		gen_files: Array[String]) -> Error:
	
	var mode : int = options.get("render_mode", RENDER_WHOLE)
	
	match mode:
		RENDER_WHOLE: return import_whole_document(source_file, save_path, options, gen_files)
		RENDER_LAYERS: return import_layers_as_atlas(source_file, save_path, options, gen_files)
		RENDER_ANIMATION: pass
		_: printerr("Invalid option given for render mode (option given: %s) % mode")
	
	return OK


func import_whole_document(source_file: String, save_path: String, options: Dictionary, generated_files: Array[String]) -> Error:
	var reader := ZIPReader.new()
	var err := reader.open(source_file)
	if err != OK:
		return err
	
	var files := reader.get_files()
	if not "mergedimage.png" in files:
		return ERR_FILE_NOT_FOUND
	
	var img := Image.new()
	err = img.load_png_from_buffer(reader.read_file("mergedimage.png"))
	if err != OK:
		return err
	
	var tex := ImageTexture.create_from_image(img)
	err = ResourceSaver.save(tex, "%s.%s" % [save_path, _get_save_extension()])
	return err


func import_whole_image(source_file: String, save_path: String, exclude_layers: Array[String]) -> void:
	if exclude_layers.size() > 0:
		pass # render out the image ourselves
	else:
		pass # just grab mergedimage.png from the zip file


func import_layers_as_atlas(source_file: String, save_path: String, options: Dictionary, generated_files: Array[String]) -> Error:
	# load image and layer metadata from maindoc.xml
	var krita_document := KraDocument.create_from_file(source_file)
	if krita_document == null: return ERR_CANT_ACQUIRE_RESOURCE
	
	# filter layer list to the ones we need to remember
	var include_colors := options.get("colors_include", [])
	var exclude_colors := options.get("colors_exculde", [])
	var include_hidden := options.get("hidden_include", false)
	var colors_to_combine := options.get("combined_colors", 1 << 3)
	var colors_to_ignore := options.get("ignored_colors", 1 << 8)
	
	var all_layers : Array[LayerData] = krita_document.layers.duplicate()
	var layers_to_save : Array[LayerData] = []
	
	# remove all layers we say to ignore
	if colors_to_ignore > 0:
		var to_remove := PackedInt32Array()
		for i in all_layers.size():
			var layer := all_layers[i]
			if 1 << layer.color_index & colors_to_ignore:
				to_remove.append(i)
		for i in to_remove.size():
			all_layers.remove_at(to_remove[-1 - i])
	
	if not include_hidden:
		var to_remove := PackedInt32Array()
		for i in all_layers.size():
			if not all_layers[i].visible:
				to_remove.append(i)
		for i in to_remove.size():
			all_layers.remove_at(to_remove[-1 - i])

	
	# combine all the remaining layers that have the same color
	# we loop through the arrays backwards so we can edit them
	# during the loop without running into indexing issues
	if colors_to_combine > 0:
		var to_combine := {}
		for c in colors_to_combine: # initialize the dictionary
			to_combine[c] = []
		
		var sort_index := 0
		for i in all_layers.size():
			var layer := all_layers[sort_index]
			if 1 << layer.color_index & colors_to_combine:
				to_combine[layer.color_index].append(layer)
				all_layers.remove_at(sort_index)
			else:
				sort_index += 1
			
		for color in to_combine:
			var layers := to_combine[color] as Array
			if layers.size() < 1:
				continue
			
			print("COMBINING LAYERS OF COLOR %s:" % color)
			for l in layers:
				print(l.name)
			
			var combined := layers[0].duplicate() as LayerData
			var total_rect := combined.get_rect()
			for layer in layers:
				total_rect = total_rect.merge(layer.get_rect())
				if layer.name.begins_with("_"):
					combined.name = layer.name.substr(1)
			
			var merged_image := Image.create_empty(total_rect.size.x, total_rect.size.y, false, Image.FORMAT_RGBA8)
			for i in layers.size():
				var layer := layers[-1 - i] as LayerData # bottom first
				merged_image.blend_rect(layer.image, Rect2i(Vector2.ZERO, layer.size), Vector2i(layer.position) - total_rect.position)
			combined.size = total_rect.size
			combined.image = merged_image
			layers_to_save.append(combined)
	
	# add all remaining (unprocessed) layers to the layer list to save
	layers_to_save.append_array(all_layers)
	
	# save the atlas to disk
	# TODO: merge the first for loop in this step with the previous steps
	var textures : Array[Texture2D] = []
	var index : Dictionary[Texture2D, LayerData] = {}
	for layer in layers_to_save:
		var tex := ImageTexture.create_from_image(layer.image)
		textures.append(tex)
		index[tex] = layer
	var packer := TexturePacker.new()
	var result := packer.pack(textures) # magic function! thanks past me :)
	var atlas := result["texture"] as Texture2D
	var atlas_path := "%s.%s" % [save_path, _get_save_extension()]
	var err := ResourceSaver.save(atlas, atlas_path)
	if err != OK:
		return err
	
	# without this the atlas textures will save the main atlas 
	# within their own files, which would be bad
	atlas.take_over_path(atlas_path)
	
	
	# TODO: check if a folder exists and create one if not
	var sub_atlas_path := source_file + ".atlas"
	if !DirAccess.dir_exists_absolute(sub_atlas_path):
		DirAccess.make_dir_absolute(sub_atlas_path)
	
	# create atlas textures and generate a manifest
	var manifest := {}
	
	#var current_files
	
	for layer_data in result["frames"]:
		var tex := AtlasTexture.new()
		tex.atlas = atlas
		tex.region = layer_data["atlas_region"]
		manifest[index[layer_data["source_texture"]].name + ".tres"] = tex
	
	# save atlas textures to folder
	for filepath in manifest:
		err = ResourceSaver.save(manifest[filepath], sub_atlas_path + "/" + filepath)
		if err != OK: return err
		else: generated_files.append(sub_atlas_path + "/" + filepath)
	
	if FileAccess.file_exists(sub_atlas_path + "/" + ".manifest"):
		var file := FileAccess.open(sub_atlas_path + "/" + ".manifest", FileAccess.READ)
		var old_manifest := file.get_as_text().split("\n")
		var to_delete := []
		for layer_file in old_manifest:
			if not layer_file in manifest:
				to_delete.append(layer_file)
		for layer in to_delete:
			print(layer)
			DirAccess.remove_absolute(sub_atlas_path + "/" + layer)
		file.close()
	
	var new_manifest_file := FileAccess.open(sub_atlas_path + "/" + ".manifest", FileAccess.WRITE)
	for filepath in manifest:
		new_manifest_file.store_line(filepath)
		
	# TODO compare to old manifest
	# TODO delete all textures not in the new manifest
	EditorInterface.get_resource_filesystem().scan() # refresh the filesystem
	return OK
