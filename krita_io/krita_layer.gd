@tool
class_name LayerData
extends RefCounted

const KraReader := preload("krita_reader.gd")
const TexturePacker := preload("res://addons/krita_v2/texture_packer.gd")

var name : String
var enabled := true
var relative_path : String

var image : Image
var visible : bool
var opacity : float

var pivot : Vector2
var position : Vector2
var size : Vector2i

var color_index : int

static func create_from_xml_data(xml_data: Dictionary) -> LayerData:
	var result := LayerData.new()
	result.name = xml_data.get("name", "Unnamed Layer")
	result.visible = xml_data.get("visible", 1) != "0"
	result.opacity = float(xml_data.get("opacity", "255")) / 255
	result.color_index = xml_data.get("colorlabel", 0)
	result.relative_path = "/layers/%s" % xml_data.get("filename", "FILE_NOT_SPECIFIED")
	return result


func get_rect() -> Rect2i: return Rect2i(position, size)


func set_filter(exclude_invisible: bool, excluded_colors: Array[int]) -> void:
	if exclude_invisible and not visible:
		enabled = true
	else:
		enabled = color_index in excluded_colors


func load_image(raw_data : PackedByteArray, max_size: Vector2i) -> void:
	print("LOADING LAYER DATA FOR " + name)
	var reader := KraReader.new()
	var packer := TexturePacker.new()
	var source_image := reader.parse_krita_layer(raw_data, max_size)
	
	# crop out unused alpha and store imagewide offset for later
	var region := packer.crop_rect(source_image)
	image = Image.create_empty(region.size.x, region.size.y, false, Image.FORMAT_RGBA8)
	image.blit_rect(source_image, region, Vector2i())
	position = region.position
	size = region.size


func duplicate() -> LayerData:
	var data := LayerData.new()
	for p in self.get_property_list():
		data.set(p["name"], self.get(p["name"]))
	return data
