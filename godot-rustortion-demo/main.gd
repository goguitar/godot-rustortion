extends Control

const GUITAR_BUS_NAME := "GuitarPlayer"
const CABINET_PRESET_DIR := "res://assets/rustortion/cabinets"
const TONE_PRESET_DIR := "res://assets/rustortion/tones"
const RUSTORTION_EFFECT_INDEX := 1
const SPECTRUM_EFFECT_INDEX := 2

var spectrum
var rustortion_effect
var guitar_bus_idx := -1
var cabinet_presets: Array = []
var tone_presets: Array = []

@onready var cabinet_list: ItemList = %CabinetList
@onready var tone_list: ItemList = %TonePresetList
@onready var status_label: Label = %StatusLabel
@onready var spectrum_area: Control = %SpectrumArea
@onready var guitar_input_player: AudioStreamPlayer = %GuitarInputPlayer


func _ready() -> void:
	setup_bus_effects()
	load_preset_lists()
	setup_audio_input()
	populate_lists()
	apply_default_selection()
	report_bus_effect_state()


func _process(_delta: float) -> void:
	update_status()


func _exit_tree() -> void:
	if guitar_input_player != null and guitar_input_player.playing:
		guitar_input_player.stop()

	spectrum = null
	rustortion_effect = null
	guitar_bus_idx = -1


func load_preset_lists() -> void:
	cabinet_presets.clear()
	tone_presets.clear()

	for file_name in sorted_json_files(CABINET_PRESET_DIR):
		var path := "%s/%s" % [CABINET_PRESET_DIR, file_name]
		var data := load_json_dict(path)
		if data.is_empty():
			continue

		var amp_data = data.get("amplifier", {})
		var ir_data = data.get("impulse_response", {})
		var ir_path: String = str(ir_data.get("ir_path", ""))
		if ir_path == "":
			push_warning("Cabinet preset missing impulse response path: %s" % path)
			continue

		if typeof(amp_data) != TYPE_DICTIONARY:
			push_warning("Cabinet preset missing amplifier dictionary: %s" % path)
			continue
		var amp_dict: Dictionary = (amp_data as Dictionary).duplicate(true)
		if amp_dict.has("schema_version"):
			amp_dict["schema_version"] = int(amp_dict["schema_version"])

		var amp_json := JSON.stringify(amp_dict)
		if amp_json == "":
			push_warning("Cabinet preset missing amplifier data: %s" % path)
			continue

		cabinet_presets.append({
			"name": data.get("name", file_name.replace(".json", "")),
			"amplifier_json": amp_json,
			"ir_path": ir_path,
			"ir_gain": float(ir_data.get("ir_gain", 0.1))
		})

	for file_name in sorted_json_files(TONE_PRESET_DIR):
		var path := "%s/%s" % [TONE_PRESET_DIR, file_name]
		var json_text := load_text_file(path)
		if json_text == "":
			continue

		var parsed: Variant = JSON.parse_string(json_text)
		if typeof(parsed) != TYPE_DICTIONARY:
			push_warning("Invalid tone preset JSON: %s" % path)
			continue
		var data: Dictionary = parsed

		tone_presets.append({
			"name": data.get("name", file_name.replace(".json", "")),
			"tone_json": json_text
		})


func sorted_json_files(dir_path: String) -> PackedStringArray:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("Failed to open preset directory: %s" % dir_path)
		return PackedStringArray()

	var files := PackedStringArray()
	for file_name in dir.get_files():
		if file_name.ends_with(".json"):
			files.append(file_name)

	files.sort()
	return files


func load_json_dict(path: String) -> Dictionary:
	var json_text := load_text_file(path)
	if json_text == "":
		return {}

	var parsed: Variant = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Invalid JSON dictionary: %s" % path)
		return {}

	return parsed as Dictionary


func load_text_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Failed to open text file: %s" % path)
		return ""
	return file.get_as_text()


func load_bytes_file(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Failed to open byte file: %s" % path)
		return PackedByteArray()
	return file.get_buffer(file.get_length())


func setup_audio_input() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not guitar_input_player.playing:
		guitar_input_player.play()


func setup_bus_effects() -> void:
	guitar_bus_idx = AudioServer.get_bus_index(GUITAR_BUS_NAME)
	if guitar_bus_idx < 0:
		push_error("Missing audio bus: %s" % GUITAR_BUS_NAME)
		return

	var effect_count := AudioServer.get_bus_effect_count(guitar_bus_idx)
	if effect_count <= RUSTORTION_EFFECT_INDEX:
		push_error("Missing Rustortion effect on bus %s" % GUITAR_BUS_NAME)
		return

	rustortion_effect = AudioServer.get_bus_effect(guitar_bus_idx, RUSTORTION_EFFECT_INDEX)
	if rustortion_effect == null:
		push_error("Rustortion effect could not be retrieved from bus %s" % GUITAR_BUS_NAME)
		return

	if effect_count <= SPECTRUM_EFFECT_INDEX:
		push_error("Missing spectrum analyzer effect on bus %s" % GUITAR_BUS_NAME)
		return

	spectrum = AudioServer.get_bus_effect_instance(guitar_bus_idx, SPECTRUM_EFFECT_INDEX)
	if spectrum_area != null and spectrum_area.has_method("set_spectrum"):
		spectrum_area.call("set_spectrum", spectrum)


func report_bus_effect_state() -> void:
	if guitar_bus_idx < 0 or rustortion_effect == null:
		return

	print(
		"Rustortion bus effect ready: bus=%s class=%s effects=%d spectrum=%s" % [
			GUITAR_BUS_NAME,
			rustortion_effect.get_class(),
			AudioServer.get_bus_effect_count(guitar_bus_idx),
			str(spectrum != null)
		]
	)


func populate_lists() -> void:
	cabinet_list.clear()
	for preset in cabinet_presets:
		cabinet_list.add_item(str(preset.get("name", "Unknown Cabinet")))

	tone_list.clear()
	for preset in tone_presets:
		tone_list.add_item(str(preset.get("name", "Unknown Tone")))


func apply_default_selection() -> void:
	if not cabinet_presets.is_empty():
		cabinet_list.select(0)
		apply_cabinet(0)

	if not tone_presets.is_empty():
		tone_list.select(0)
		apply_tone(0)


func update_status() -> void:
	var input_device := AudioServer.get_input_device()
	var bus_name := GUITAR_BUS_NAME if guitar_bus_idx >= 0 else "%s (missing)" % GUITAR_BUS_NAME
	var bus_channels := AudioServer.get_bus_channels(guitar_bus_idx) if guitar_bus_idx >= 0 else 0
	var effect_error := ""
	if rustortion_effect and rustortion_effect.has_method("get_last_error"):
		effect_error = str(rustortion_effect.call("get_last_error"))

	status_label.text = "Input: %s\nBus: %s (%d ch)\nMix Rate: %.0f Hz\nLast Error: %s" % [
		input_device,
		bus_name,
		bus_channels,
		AudioServer.get_mix_rate(),
		effect_error if effect_error != "" else "OK"
	]


func apply_cabinet(index: int) -> void:
	if rustortion_effect == null or index < 0 or index >= cabinet_presets.size():
		return

	var preset: Dictionary = cabinet_presets[index]
	var ir_path: String = str(preset.get("ir_path", ""))
	var ir_bytes := load_bytes_file(ir_path)
	if ir_bytes.is_empty():
		push_error("Failed to read cabinet IR bytes: %s" % ir_path)
		return

	var ok: bool = bool(
		rustortion_effect.call(
			"load_amp_and_ir_data",
			str(preset.get("amplifier_json", "")),
			str(preset.get("name", "Cabinet")),
			ir_bytes,
			float(preset.get("ir_gain", 0.1))
		)
	)
	if ok:
		print("Applied cabinet on bus %s: %s" % [GUITAR_BUS_NAME, preset.get("name", "Unknown Cabinet")])
	else:
		push_error("Failed to apply cabinet '%s': %s" % [preset.get("name", "Unknown Cabinet"), _get_effect_error()])


func apply_tone(index: int) -> void:
	if rustortion_effect == null or index < 0 or index >= tone_presets.size():
		return

	var preset: Dictionary = tone_presets[index]
	var ok: bool = bool(rustortion_effect.call("load_tone_data", str(preset.get("tone_json", ""))))
	if ok:
		print("Applied tone on bus %s: %s" % [GUITAR_BUS_NAME, preset.get("name", "Unknown Tone")])
	else:
		push_error("Failed to apply tone '%s': %s" % [preset.get("name", "Unknown Tone"), _get_effect_error()])


func _get_effect_error() -> String:
	if rustortion_effect and rustortion_effect.has_method("get_last_error"):
		return str(rustortion_effect.call("get_last_error"))
	return "Unknown error"


func _on_cabinet_list_item_selected(index: int) -> void:
	apply_cabinet(index)


func _on_tone_list_item_selected(index: int) -> void:
	apply_tone(index)
