@tool
class_name KraDocument
extends RefCounted

const KraLayer := preload("krita_layer.gd")

const MAIN_FILE_PATH := "maindoc.xml"

var name : String
var width : int
var height : int

var canvas_size : Vector2i:
	get: return Vector2i(width, height)
	set(new):
		width = new.x
		height = new.y

var layers : Array[KraLayer]

static func create_from_file(filepath: String) -> KraDocument:
	var document := KraDocument.new()
	var err := document.open(filepath)
	if err != OK:
		printerr(err)
		return null
	return document


func open(filepath: String) -> Error:
	var zip := ZIPReader.new()
	var err := zip.open(filepath)
	if err != OK: return err
	
	if not zip.file_exists(MAIN_FILE_PATH): return ERR_INVALID_DATA

	var xml_data := zip.read_file(MAIN_FILE_PATH)
	var parser := XMLParser.new()
	err = parser.open_buffer(xml_data)
	
	if err != OK: return err
	
	layers = []
	while parser.read() != ERR_FILE_EOF:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			var node_name = parser.get_node_name()
			var metadata = {}
			for idx in range(parser.get_attribute_count()):
				metadata[parser.get_attribute_name(idx)] = parser.get_attribute_value(idx)
			match node_name:
				"IMAGE": load_image_data(metadata)
				"layer": load_layer_data(metadata)
	
	for l in layers:
		var path := name + l.relative_path
		if not zip.file_exists(path):
			printerr("path %s not found in krita document" % path)
			continue
		
		var raw_data := zip.read_file(path)
		var default_pixels := zip.read_file(path + ".defaultpixel")
		print(default_pixels)
		l.load_image(raw_data, canvas_size)
	return OK


func load_image_data(metadata: Dictionary) -> void:
	name = metadata["name"]
	width = int(metadata["width"])
	height = int(metadata["height"])


func load_layer_data(layer_properties: Dictionary) -> void:
	var layer_type := layer_properties.get("nodetype", "unknown")
	var layer : KraLayer
	
	match layer_type: # in here for future layer type support (ie. masks, filters, etc)
		"paintlayer": layer = KraLayer.create_from_xml_data(layer_properties)
	
	if layer == null:
		printerr("LAYER GENERATION PROCESS FAILED FOR LAYER ", layer_type)
	else:
		layers.append(layer)
