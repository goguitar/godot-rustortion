extends Control

const MIC_BUS_NAME := "GuitarMic"
const PLAY_BUS_NAME := "GuitarPlay"
const RUSTORTION_BUS_NAME := "Rustortion"
const RIG_PRESET_DIR := "res://assets/rustortion/rigs"
const SOURCE_PRESET_DIR := "res://assets/rustortion/source_presets"
const IR_BASE_DIR := "res://assets/rustortion/impulse_responses"
const PLAYBACK_SOURCE_DIR := "res://assets/rustortion/input_loops/rock_guitar"
const MIN_METER_DB := -60.0

const EQ_BAND_FREQS := [
	25.0, 40.0, 63.0, 100.0, 160.0, 250.0, 400.0, 630.0,
	1000.0, 1600.0, 2500.0, 4000.0, 6300.0, 10000.0, 16000.0, 20000.0
]

var rustortion_effect
var rustortion_bus_idx := -1
var play_bus_idx := -1
var active_rig_name := ""

var rigs: Array = []
var playback_stream_paths := PackedStringArray()
var selected_playback_index := 0

var input_meter_db := MIN_METER_DB
var output_meter_db := MIN_METER_DB

@onready var rig_list: ItemList = %RigList
@onready var status_label: Label = %StatusLabel
@onready var playback_clip_option: OptionButton = %PlaybackClipOption
@onready var playback_clip_label: Label = %PlaybackClipLabel
@onready var current_input_label: Label = %CurrentInputLabel
@onready var playback_input_player: AudioStreamPlayer = %PlaybackInputPlayer
@onready var input_vu_bar: ProgressBar = %InputVuBar
@onready var output_vu_bar: ProgressBar = %OutputVuBar
@onready var input_vu_value_label: Label = %InputVuValueLabel
@onready var output_vu_value_label: Label = %OutputVuValueLabel


func _ready() -> void:
	setup_bus_effects()
	load_rigs()
	load_playback_stream_list()
	setup_playback_controls()
	populate_rig_list()
	apply_default_selection()
	set_source_bus_mute_states(true, false)
	current_input_label.text = "Current Input: Guitar dataset playback"


func _process(_delta: float) -> void:
	update_vu_meters()
	update_status()


func _exit_tree() -> void:
	if playback_input_player != null and playback_input_player.playing:
		playback_input_player.stop()

	rustortion_effect = null
	rustortion_bus_idx = -1
	play_bus_idx = -1


func setup_bus_effects() -> void:
	play_bus_idx = AudioServer.get_bus_index(PLAY_BUS_NAME)
	rustortion_bus_idx = AudioServer.get_bus_index(RUSTORTION_BUS_NAME)

	if rustortion_bus_idx < 0:
		push_error("Missing audio bus: %s" % RUSTORTION_BUS_NAME)
		return

	var rustortion_effect_index := find_rustortion_effect_index(rustortion_bus_idx)
	if rustortion_effect_index < 0:
		push_error("Missing Rustortion effect on bus %s" % RUSTORTION_BUS_NAME)
		return

	rustortion_effect = AudioServer.get_bus_effect(rustortion_bus_idx, rustortion_effect_index)
	if rustortion_effect == null:
		push_error("Rustortion effect could not be retrieved from bus %s" % RUSTORTION_BUS_NAME)


func find_rustortion_effect_index(bus_idx: int) -> int:
	var effect_count := AudioServer.get_bus_effect_count(bus_idx)
	for idx in effect_count:
		var effect := AudioServer.get_bus_effect(bus_idx, idx)
		if effect == null:
			continue
		if effect.has_method("load_amp_tone_and_ir_data"):
			return idx
	return -1


func set_source_bus_mute_states(mic_muted: bool, play_muted: bool) -> void:
	var mic_bus_idx := AudioServer.get_bus_index(MIC_BUS_NAME)
	if mic_bus_idx >= 0:
		AudioServer.set_bus_mute(mic_bus_idx, mic_muted)

	if play_bus_idx >= 0:
		AudioServer.set_bus_mute(play_bus_idx, play_muted)


func load_rigs() -> void:
	rigs.clear()
	load_source_presets()

	for file_name in sorted_json_files(RIG_PRESET_DIR):
		var path := "%s/%s" % [RIG_PRESET_DIR, file_name]
		var data := load_json_dict(path)
		if data.is_empty():
			continue

		if typeof(data.get("GearList", null)) != TYPE_DICTIONARY:
			push_warning("Rig preset missing GearList: %s" % path)
			continue

		var payload := translate_rig_to_runtime_payload(data)
		if payload.is_empty():
			continue

		rigs.append({
			"name": str(data.get("Name", file_name.replace(".json", ""))),
			"mode": "runtime",
			"payload": payload
		})


func load_source_presets() -> void:
	for file_name in sorted_json_files(SOURCE_PRESET_DIR):
		var path := "%s/%s" % [SOURCE_PRESET_DIR, file_name]
		var preset := load_json_dict(path)
		if preset.is_empty():
			continue

		var payload := translate_source_preset_to_runtime_payload(preset)
		if payload.is_empty():
			push_warning("Skipping source preset (translation failed): %s" % path)
			continue

		rigs.append({
			"name": "[Source] %s" % str(preset.get("name", file_name.replace(".json", ""))),
			"mode": "runtime",
			"payload": payload
		})


func load_playback_stream_list() -> void:
	playback_stream_paths.clear()
	for file_name in sorted_wav_files(PLAYBACK_SOURCE_DIR):
		playback_stream_paths.append("%s/%s" % [PLAYBACK_SOURCE_DIR, file_name])


func setup_playback_controls() -> void:
	playback_input_player.bus = PLAY_BUS_NAME
	playback_clip_option.clear()

	for path in playback_stream_paths:
		playback_clip_option.add_item(_clip_display_name(path))

	if playback_stream_paths.is_empty():
		playback_clip_label.text = "Playback Clip (none)"
		playback_clip_option.disabled = true
		return

	selected_playback_index = clampi(selected_playback_index, 0, playback_stream_paths.size() - 1)
	playback_clip_label.text = "Playback Clip (%d)" % playback_stream_paths.size()
	playback_clip_option.select(selected_playback_index)
	start_playback_current()


func populate_rig_list() -> void:
	rig_list.clear()
	for rig in rigs:
		rig_list.add_item(str(rig.get("name", "Unknown Rig")))


func apply_default_selection() -> void:
	if not rigs.is_empty():
		var selected_idx := 0
		for i in range(rigs.size()):
			var n := str(rigs[i].get("name", ""))
			if n.contains("[Source] Clean"):
				selected_idx = i
				break
		rig_list.select(selected_idx)
		apply_rig(selected_idx)


func start_playback_current() -> bool:
	if playback_stream_paths.is_empty():
		return false

	selected_playback_index = clampi(selected_playback_index, 0, playback_stream_paths.size() - 1)
	var stream_path := playback_stream_paths[selected_playback_index]
	var stream_resource: Resource = load(stream_path)
	if stream_resource == null:
		push_warning("Failed to load playback stream: %s" % stream_path)
		return false

	var audio_stream := stream_resource as AudioStream
	if audio_stream == null:
		push_warning("Playback resource is not an AudioStream: %s" % stream_path)
		return false

	playback_input_player.stop()
	playback_input_player.stream = audio_stream
	playback_input_player.stream_paused = false
	playback_input_player.play(0.0)
	return playback_input_player.playing


func apply_rig(index: int) -> void:
	if rustortion_effect == null or index < 0 or index >= rigs.size():
		return

	var rig: Dictionary = rigs[index]
	var translated: Dictionary = rig.get("payload", {})
	if translated.is_empty():
		push_error("Failed to load rig payload: %s" % rig.get("name", "Unknown"))
		return

	var ir_path := str(translated.get("ir_path", ""))
	var ir_bytes := load_bytes_file(ir_path)
	if ir_bytes.is_empty():
		push_error("Failed to read IR bytes: %s" % ir_path)
		return

	var ok: bool = bool(
		rustortion_effect.call(
			"load_amp_tone_and_ir_data",
			str(translated.get("amplifier_json", "")),
			str(translated.get("tone_json", "")),
			str(rig.get("name", "Rig")),
			ir_bytes,
			float(translated.get("ir_gain", 0.1))
		)
	)

	if not ok:
		push_error("Failed to apply rig '%s': %s" % [rig.get("name", "Unknown"), _get_effect_error()])
		return

	active_rig_name = str(rig.get("name", ""))


func translate_rig_to_runtime_payload(data: Dictionary) -> Dictionary:
	var gear_list: Dictionary = data.get("GearList", {})
	var rack: Dictionary = gear_list.get("Rack1", {})
	var amp: Dictionary = gear_list.get("Amp", {})
	var cabinet: Dictionary = gear_list.get("Cabinet", {})

	var rack_knobs: Dictionary = rack.get("KnobValues", {})
	var amp_knobs: Dictionary = amp.get("KnobValues", {})
	var amp_key := str(amp.get("Key", "Amp_MarshallDSL100H"))
	var cab_key := str(cabinet.get("Key", "Cab_GB412CMKIII_57_Edge"))

	var gain_pct := _normalize_amp_knob(_get_knob(amp_knobs, "%s_Gain" % amp_key, 70.0))
	var bass_pct := _normalize_amp_knob(_get_knob(amp_knobs, "%s_Bass" % amp_key, 50.0))
	var mid_pct := _normalize_amp_knob(_get_knob(amp_knobs, "%s_Mid" % amp_key, 50.0))
	var treble_pct := _normalize_amp_knob(_get_knob(amp_knobs, "%s_Treble" % amp_key, 50.0))
	var pres_pct := _normalize_amp_knob(_get_knob(amp_knobs, "%s_Pres" % amp_key, 50.0))
	var res_pct := _normalize_amp_knob(_get_knob(amp_knobs, "%s_Res" % amp_key, 50.0))

	var tone_json := JSON.stringify({
		"schema_version": 1,
		"name": str(data.get("Name", "Rig Tone")),
		"preamp_chain": [
			{
				"gain": lerpf(1.0, 2.4, gain_pct / 100.0),
				"bias": 0.0,
				"clipper_type": "Triode",
				"bypassed": false
			},
			{
				"gain": lerpf(2.6, 5.6, gain_pct / 100.0),
				"bias": lerpf(0.0, 0.16, gain_pct / 100.0),
				"clipper_type": "Asymmetric",
				"bypassed": false
			}
		]
	})

	var eq_gains := [
		0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
		0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
	]
	_apply_eq_point(eq_gains, _get_knob(rack_knobs, "Rack_StudioEQ_BassFreq", 100.0), _get_knob(rack_knobs, "Rack_StudioEQ_Bass", 0.0))
	_apply_eq_point(eq_gains, _get_knob(rack_knobs, "Rack_StudioEQ_LoMidFreq", 250.0), _get_knob(rack_knobs, "Rack_StudioEQ_LoMid", 0.0))
	_apply_eq_point(eq_gains, _get_knob(rack_knobs, "Rack_StudioEQ_HiMidFreq", 1.6) * 1000.0, _get_knob(rack_knobs, "Rack_StudioEQ_HiMid", 0.0))
	_apply_eq_point(eq_gains, _get_knob(rack_knobs, "Rack_StudioEQ_TrebleFreq", 6.3) * 1000.0, _get_knob(rack_knobs, "Rack_StudioEQ_Treble", 0.0))

	var amplifier_json := JSON.stringify({
		"schema_version": 1,
		"name": str(data.get("Name", "Rig Amp")),
		"input_filters": {
			"hp_enabled": true,
			"hp_cutoff": lerpf(130.0, 80.0, res_pct / 100.0),
			"lp_enabled": true,
			"lp_cutoff": 6200.0
		},
		"amp_chain": [
			{
				"ToneStack": {
					"model": "British",
					"bass": lerpf(0.55, 1.55, bass_pct / 100.0),
					"mid": lerpf(0.55, 1.55, mid_pct / 100.0),
					"treble": lerpf(0.5, 1.35, treble_pct / 100.0),
					"presence": lerpf(0.0, 1.15, pres_pct / 100.0),
					"bypassed": false
				}
			},
			{
				"PowerAmp": {
					"drive": lerpf(0.06, 0.32, gain_pct / 100.0),
					"amp_type": "ClassAB",
					"sag": 0.2,
					"sag_release": 100.0,
					"bypassed": false
				}
			},
			{
				"Eq": {
					"gains": eq_gains,
					"bypassed": false
				}
			},
			{
				"Level": {
					"gain": 0.2,
					"bypassed": false
				}
			}
		]
	})

	return {
		"tone_json": tone_json,
		"amplifier_json": amplifier_json,
		"ir_path": _map_cab_key_to_ir_path(cab_key),
		"ir_gain": 0.1
	}


func translate_source_preset_to_runtime_payload(preset: Dictionary) -> Dictionary:
	var stages: Array = preset.get("stages", [])
	if stages.is_empty():
		return {}

	var preamp_chain: Array = []
	var amp_chain: Array = []

	for entry in stages:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var stage_entry: Dictionary = entry
		for stage_name in stage_entry.keys():
			var stage_config: Dictionary = stage_entry.get(stage_name, {})
			if typeof(stage_config) != TYPE_DICTIONARY:
				continue
			if stage_name == "Preamp":
				var preamp_cfg := stage_config.duplicate(true)
				if not preamp_cfg.has("bypassed"):
					preamp_cfg["bypassed"] = false
				preamp_chain.append(preamp_cfg)
			else:
				amp_chain.append({stage_name: stage_config})

	var input_filters: Dictionary = preset.get("input_filters", {
		"hp_enabled": true,
		"hp_cutoff": 100.0,
		"lp_enabled": true,
		"lp_cutoff": 8000.0
	})

	var ir_name := str(preset.get("ir_name", ""))
	var ir_path := ""
	if ir_name != "":
		ir_path = "%s/%s" % [IR_BASE_DIR, ir_name]
		if not FileAccess.file_exists(ir_path):
			push_warning("Source preset IR not found in demo assets: %s" % ir_name)
			ir_path = ""

	if ir_path == "":
		ir_path = _map_cab_key_to_ir_path("Cab_GB412CMKIII_57_Edge")

	var tone_json := JSON.stringify({
		"schema_version": 1,
		"name": "%s Tone" % str(preset.get("name", "Source")),
		"preamp_chain": preamp_chain
	})

	var amplifier_json := JSON.stringify({
		"schema_version": 1,
		"name": "%s Amp" % str(preset.get("name", "Source")),
		"input_filters": input_filters,
		"amp_chain": amp_chain
	})

	return {
		"tone_json": tone_json,
		"amplifier_json": amplifier_json,
		"ir_path": ir_path,
		"ir_gain": float(preset.get("ir_gain", 0.1))
	}


func _map_cab_key_to_ir_path(cab_key: String) -> String:
	match cab_key:
		"Cab_GB412CMKIII_57_Edge":
			return "res://assets/rustortion/impulse_responses/Science Amplification/4x12/G12H-75/SM57 Brighter.wav"
		_:
			return "res://assets/rustortion/impulse_responses/Science Amplification/4x12/G12H-75/SM57 Brighter.wav"


func _get_knob(knobs: Dictionary, key: String, default_value: float) -> float:
	if not knobs.has(key):
		return default_value
	return float(knobs.get(key, default_value))


func _normalize_amp_knob(value: float) -> float:
	if value <= 10.0:
		return clampf(value * 10.0, 0.0, 100.0)
	return clampf(value, 0.0, 100.0)


func _apply_eq_point(gains: Array, freq_hz: float, gain_db: float) -> void:
	var best_idx := 0
	var best_delta := INF
	for i in range(EQ_BAND_FREQS.size()):
		var delta := absf(EQ_BAND_FREQS[i] - freq_hz)
		if delta < best_delta:
			best_delta = delta
			best_idx = i
	gains[best_idx] = clampf(float(gains[best_idx]) + gain_db, -12.0, 12.0)


func update_vu_meters() -> void:
	if play_bus_idx >= 0:
		var in_peak := maxf(
			AudioServer.get_bus_peak_volume_left_db(play_bus_idx, 0),
			AudioServer.get_bus_peak_volume_right_db(play_bus_idx, 0)
		)
		input_meter_db = _smooth_meter_db(input_meter_db, in_peak)

	if rustortion_bus_idx >= 0:
		var out_peak := maxf(
			AudioServer.get_bus_peak_volume_left_db(rustortion_bus_idx, 0),
			AudioServer.get_bus_peak_volume_right_db(rustortion_bus_idx, 0)
		)
		output_meter_db = _smooth_meter_db(output_meter_db, out_peak)

	var in_norm := _db_to_meter_norm(input_meter_db)
	var out_norm := _db_to_meter_norm(output_meter_db)

	input_vu_bar.value = in_norm * 100.0
	output_vu_bar.value = out_norm * 100.0
	input_vu_value_label.text = "%.1f dB" % input_meter_db
	output_vu_value_label.text = "%.1f dB" % output_meter_db


func _smooth_meter_db(current_db: float, target_db: float) -> float:
	target_db = maxf(target_db, MIN_METER_DB)
	if target_db > current_db:
		return lerpf(current_db, target_db, 0.55)
	return lerpf(current_db, target_db, 0.12)


func _db_to_meter_norm(db: float) -> float:
	return clampf((db - MIN_METER_DB) / -MIN_METER_DB, 0.0, 1.0)


func update_status() -> void:
	var playback_clip := "-"
	if not playback_stream_paths.is_empty():
		playback_clip = _clip_display_name(playback_stream_paths[selected_playback_index])

	var source_channels := AudioServer.get_bus_channels(play_bus_idx) if play_bus_idx >= 0 else 0
	var process_channels := AudioServer.get_bus_channels(rustortion_bus_idx) if rustortion_bus_idx >= 0 else 0
	var effect_error := _get_effect_error()

	status_label.text = "Rig: %s\nPlayback Clip: %s\nSource Bus: %s (%d ch)\nProcess Bus: %s (%d ch)\nPlay Playing: %s\nMix Rate: %.0f Hz\nLast Error: %s" % [
		active_rig_name if active_rig_name != "" else "(none)",
		playback_clip,
		PLAY_BUS_NAME,
		source_channels,
		RUSTORTION_BUS_NAME,
		process_channels,
		str(playback_input_player.playing),
		AudioServer.get_mix_rate(),
		effect_error if effect_error != "" else "OK"
	]


func _get_effect_error() -> String:
	if rustortion_effect and rustortion_effect.has_method("get_last_error"):
		return str(rustortion_effect.call("get_last_error"))
	return "Unknown error"


func _clip_display_name(path: String) -> String:
	return path.get_file().replace(".wav", "")


func sorted_json_files(dir_path: String) -> PackedStringArray:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_warning("Failed to open rig directory: %s" % dir_path)
		return PackedStringArray()

	var files := PackedStringArray()
	for file_name in dir.get_files():
		if file_name.ends_with(".json"):
			files.append(file_name)

	files.sort()
	return files


func sorted_wav_files(dir_path: String) -> PackedStringArray:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_warning("Playback source directory missing: %s" % dir_path)
		return PackedStringArray()

	var files := PackedStringArray()
	for file_name in dir.get_files():
		if file_name.ends_with(".wav"):
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


func _on_rig_list_item_selected(index: int) -> void:
	apply_rig(index)


func _on_playback_clip_option_item_selected(index: int) -> void:
	if index < 0 or index >= playback_stream_paths.size():
		return

	selected_playback_index = index
	start_playback_current()


func _on_playback_input_player_finished() -> void:
	if playback_stream_paths.is_empty():
		return

	selected_playback_index = (selected_playback_index + 1) % playback_stream_paths.size()
	playback_clip_option.select(selected_playback_index)
	start_playback_current()
