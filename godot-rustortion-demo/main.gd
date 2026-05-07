extends Control

const MIC_BUS_NAME := "GuitarMic"
const PLAY_BUS_NAME := "GuitarPlay"
const RUSTORTION_BUS_NAME := "Rustortion"
const MIC_GATE_EFFECT_NAME := "Gate"
const SOURCE_PRESET_DIR := "res://assets/rustortion/source_presets"
const IR_BASE_DIR := "res://assets/rustortion/impulse_responses"
const PLAYBACK_SOURCE_DIR := "res://assets/rustortion/input_loops/rock_guitar"
const MIN_METER_DB := -70.0
const INPUT_GAIN_MIN_DB := -18.0
const INPUT_GAIN_MAX_DB := 18.0
const OUTPUT_GAIN_MIN_DB := -18.0
const OUTPUT_GAIN_MAX_DB := 18.0
const TONE_MIN := 0.2
const TONE_MAX := 2.2
const DEFAULT_STAGE_FLOW_STAGES := [
	"Input",
	"HP/LP",
	"Compressor",
	"TS",
	"Pre Amplifier",
	"Level",
	"EQ",
	"Cabinet",
	"Output"
]

@onready var mic_bus_idx := AudioServer.get_bus_index(MIC_BUS_NAME)
@onready var play_bus_idx := AudioServer.get_bus_index(PLAY_BUS_NAME)
@onready var rustortion_bus_idx := AudioServer.get_bus_index(RUSTORTION_BUS_NAME)
@onready var rustortion_effect_idx := _lookup_rustortion_effect_index_once(rustortion_bus_idx)
@onready var rustortion_effect: AudioEffectRustortion = AudioServer.get_bus_effect(rustortion_bus_idx, rustortion_effect_idx) as AudioEffectRustortion
@onready var mic_gate_effect_idx := _lookup_mic_gate_effect_index_once(mic_bus_idx)
var active_rig_name := ""

var rigs: Array = []
var playback_stream_paths := PackedStringArray()
var selected_playback_index := 0
var input_gain_value := 50.0
var output_gain_value := 50.0
var bass_value := 5.0
var middle_value := 5.0
var treble_value := 5.0

var amp_chain_state := AmpChainState.new()
var amp_chain_store := AmpChainStore.new()
var input_meter_db := MIN_METER_DB
var output_meter_db := MIN_METER_DB

@onready var rig_list: ItemList = %RigList
@onready var status_label: Label = %StatusLabel
@onready var playback_clip_option: OptionButton = %PlaybackClipOption
@onready var playback_clip_label: Label = %PlaybackClipLabel
@onready var current_input_label: Label = %CurrentInputLabel
@onready var playback_input_player: AudioStreamPlayer = %PlaybackInputPlayer
@onready var mic_input_player: AudioStreamPlayer = %MicInputPlayer
@onready var playback_mode_button: Control = %PlaybackModeButton
@onready var input_mode_button: Control = %InputModeButton
@onready var input_gain_knob: Control = %InputGainKnob
@onready var output_gain_knob: Control = %OutputGainKnob
@onready var bass_knob: Control = %BassKnob
@onready var middle_knob: Control = %MiddleKnob
@onready var treble_knob: Control = %TrebleKnob
@onready var input_vu_meter: VuMeter = %InputVuMeter
@onready var output_vu_meter: VuMeter = %OutputVuMeter
@onready var stage_flow_graph: GraphEdit = %StageFlowGraph


func _ready() -> void:
	assert(mic_bus_idx >= 0, "Missing audio bus: %s" % MIC_BUS_NAME)
	assert(play_bus_idx >= 0, "Missing audio bus: %s" % PLAY_BUS_NAME)
	assert(rustortion_bus_idx >= 0, "Missing audio bus: %s" % RUSTORTION_BUS_NAME)
	assert(rustortion_effect_idx >= 0, "Missing Rustortion effect on bus %s" % RUSTORTION_BUS_NAME)
	assert(rustortion_effect != null, "Rustortion effect on bus %s is not AudioEffectRustortion" % RUSTORTION_BUS_NAME)
	assert(mic_gate_effect_idx >= 0, "Missing AudioEffectGate named '%s' on bus %s" % [MIC_GATE_EFFECT_NAME, MIC_BUS_NAME])
	AudioServer.set_bus_mute(mic_bus_idx, false)
	AudioServer.set_bus_mute(play_bus_idx, false)
	if not amp_chain_store.set_preset_dir(SOURCE_PRESET_DIR):
		push_warning("Failed to set preset directory: %s" % amp_chain_store.get_last_error())
	load_rigs()
	load_playback_stream_list()
	setup_playback_controls()
	populate_rig_list()
	apply_default_selection()
	if rigs.is_empty():
		_refresh_stage_flow_graph()
	_set_input_source_mode(true)
	_setup_gain_knobs()
	status_label.visible = false


func _process(delta: float) -> void:
	update_vu_meters(delta)


func _exit_tree() -> void:
	if playback_input_player != null and playback_input_player.playing:
		playback_input_player.stop()
	if mic_input_player != null and mic_input_player.playing:
		mic_input_player.stop()


func _lookup_rustortion_effect_index_once(bus_idx: int) -> int:
	var effect_count := AudioServer.get_bus_effect_count(bus_idx)
	for idx in effect_count:
		var effect := AudioServer.get_bus_effect(bus_idx, idx)
		if effect.has_method("set_amp_chain"):
			return idx
	return -1


func _lookup_mic_gate_effect_index_once(bus_idx: int) -> int:
	var effect_count := AudioServer.get_bus_effect_count(bus_idx)
	for idx in effect_count:
		var effect := AudioServer.get_bus_effect(bus_idx, idx)
		if effect != null and effect.resource_name == MIC_GATE_EFFECT_NAME and effect.has_method("set_threshold_db"):
			return idx
	return -1


func set_source_player_enabled(player: AudioStreamPlayer, enabled: bool) -> void:
	if player == null:
		return
	player.volume_linear = 1.0 if enabled else 0.0


func load_rigs() -> void:
	rigs.clear()
	load_source_presets()


func load_source_presets() -> void:
	var preset_files := amp_chain_store.list_presets()
	if preset_files.is_empty():
		var store_error := amp_chain_store.get_last_error()
		if store_error != "":
			push_warning("Failed to list source presets: %s" % store_error)
		return

	for file_name in preset_files:
		var preset := amp_chain_store.load_preset(file_name)
		if preset.is_empty():
			var store_error := amp_chain_store.get_last_error()
			if store_error != "":
				push_warning("Skipping source preset (%s): %s" % [file_name, store_error])
			continue

		var payload := _build_source_payload(preset)
		if payload.is_empty():
			push_warning("Skipping source preset (invalid payload): %s" % file_name)
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
	if index < 0 or index >= rigs.size():
		return

	var rig: Dictionary = rigs[index]
	var payload: Dictionary = rig.get("payload", {})
	if payload.is_empty():
		push_error("Failed to load rig payload: %s" % rig.get("name", "Unknown"))
		return
	var source_preset: Dictionary = payload.get("source_preset", {})
	if source_preset.is_empty():
		push_error("Missing source_preset payload for rig '%s'" % rig.get("name", "Unknown"))
		return

	amp_chain_state.load_from_source_preset(source_preset)

	var ir_path := str(payload.get("ir_path", ""))
	var ir_bytes := load_bytes_file(ir_path)
	if ir_bytes.is_empty():
		push_error("Failed to read IR bytes: %s" % ir_path)
		return

	if not rustortion_effect.set_amp_chain(amp_chain_state.stages_json(), amp_chain_state.input_filters_json()):
		push_error("Failed to apply stage chain for rig '%s': %s" % [rig.get("name", "Unknown"), _get_effect_error()])
		return

	if not rustortion_effect.set_ir_data(
		str(rig.get("name", "Rig")),
		ir_bytes,
		float(payload.get("ir_gain", 0.1))
	):
		push_error("Failed to apply rig '%s': %s" % [rig.get("name", "Unknown"), _get_effect_error()])
		return

	active_rig_name = str(rig.get("name", ""))
	_sync_knobs_from_state()
	_apply_input_trim_db()
	_apply_stage_knob_controls()
	_refresh_stage_flow_graph()


func _build_source_payload(preset: Dictionary) -> Dictionary:
	var stages: Array = preset.get("stages", [])
	if stages.is_empty():
		return {}

	var ir_name := str(preset.get("ir_name", ""))
	var ir_path := ""
	if ir_name != "":
		ir_path = "%s/%s" % [IR_BASE_DIR, ir_name]
		if not FileAccess.file_exists(ir_path):
			push_warning("Source preset IR not found in demo assets: %s" % ir_name)
			ir_path = ""

	if ir_path == "":
		ir_path = _map_cab_key_to_ir_path("Cab_GB412CMKIII_57_Edge")

	return {
		"source_preset": preset.duplicate(true),
		"ir_path": ir_path,
		"ir_gain": float(preset.get("ir_gain", 0.1))
	}


func _map_cab_key_to_ir_path(cab_key: String) -> String:
	match cab_key:
		"Cab_GB412CMKIII_57_Edge":
			return "res://assets/rustortion/impulse_responses/Science Amplification/4x12/G12H-75/SM57 Brighter.wav"
		_:
			return "res://assets/rustortion/impulse_responses/Science Amplification/4x12/G12H-75/SM57 Brighter.wav"


func update_vu_meters(_delta: float) -> void:
	var input_peak_db := float(rustortion_effect.get_input_peak_db())
	var output_peak_db := float(rustortion_effect.get_output_peak_db())

	input_meter_db = _smooth_meter_db(input_meter_db, input_peak_db)
	output_meter_db = _smooth_meter_db(output_meter_db, output_peak_db)

	if input_vu_meter != null:
		input_vu_meter.set_peak_db(input_meter_db)
	if output_vu_meter != null:
		output_vu_meter.set_peak_db(output_meter_db)


func _smooth_meter_db(current_db: float, target_db: float) -> float:
	target_db = maxf(target_db, MIN_METER_DB)
	if target_db > current_db:
		return lerpf(current_db, target_db, 0.55)
	return lerpf(current_db, target_db, 0.12)


func update_status() -> void:
	var playback_clip := "-"
	if not playback_stream_paths.is_empty():
		playback_clip = _clip_display_name(playback_stream_paths[selected_playback_index])

	var source_channels := AudioServer.get_bus_channels(play_bus_idx)
	var process_channels := AudioServer.get_bus_channels(rustortion_bus_idx)
	var effect_error := _get_effect_error()
	var input_gain_db := _value_to_db(input_gain_value, INPUT_GAIN_MIN_DB, INPUT_GAIN_MAX_DB)
	var output_gain_db := _value_to_db(output_gain_value, OUTPUT_GAIN_MIN_DB, OUTPUT_GAIN_MAX_DB)

	status_label.text = "Rig: %s\nPlayback Clip: %s\nInput Gain: %.1f dB\nBass: %.1f  Mid: %.1f  Treble: %.1f\nOutput Gain: %.1f dB\nSource Bus: %s (%d ch)\nProcess Bus: %s (%d ch)\nPlay Playing: %s\nMix Rate: %.0f Hz\nLast Error: %s" % [
		active_rig_name if active_rig_name != "" else "(none)",
		playback_clip,
		input_gain_db,
		bass_value,
		middle_value,
		treble_value,
		output_gain_db,
		PLAY_BUS_NAME,
		source_channels,
		RUSTORTION_BUS_NAME,
		process_channels,
		str(playback_input_player.playing),
		AudioServer.get_mix_rate(),
		effect_error if effect_error != "" else "OK"
	]


func _setup_gain_knobs() -> void:
	if input_gain_knob == null:
		push_warning("InputGainKnob node missing")
	else:
		if input_gain_knob.has_signal("value_changed"):
			input_gain_knob.connect("value_changed", Callable(self, "set_input_gain"))
		if input_gain_knob.has_method("set_value"):
			input_gain_knob.call("set_value", input_gain_value, false)

	if output_gain_knob == null:
		push_warning("OutputGainKnob node missing")
	else:
		if output_gain_knob.has_signal("value_changed"):
			output_gain_knob.connect("value_changed", Callable(self, "set_output_gain"))
		if output_gain_knob.has_method("set_value"):
			output_gain_knob.call("set_value", output_gain_value, false)

	if bass_knob != null:
		if bass_knob.has_signal("value_changed"):
			bass_knob.connect("value_changed", Callable(self, "set_bass"))
		if bass_knob.has_method("set_value"):
			bass_knob.call("set_value", bass_value, false)

	if middle_knob != null:
		if middle_knob.has_signal("value_changed"):
			middle_knob.connect("value_changed", Callable(self, "set_middle"))
		if middle_knob.has_method("set_value"):
			middle_knob.call("set_value", middle_value, false)

	if treble_knob != null:
		if treble_knob.has_signal("value_changed"):
			treble_knob.connect("value_changed", Callable(self, "set_treble"))
		if treble_knob.has_method("set_value"):
			treble_knob.call("set_value", treble_value, false)

	_apply_input_trim_db()
	_apply_stage_knob_controls()


func _refresh_stage_flow_graph() -> void:
	if stage_flow_graph == null:
		return

	stage_flow_graph.clear_connections()
	for child in stage_flow_graph.get_children():
		if child is GraphNode:
			stage_flow_graph.remove_child(child)
			child.queue_free()

	var stage_names := _build_stage_flow_names_from_preset()
	if stage_names.is_empty():
		stage_names = DEFAULT_STAGE_FLOW_STAGES.duplicate()

	var stage_count := stage_names.size()
	for idx in range(stage_count):
		var stage_name := str(stage_names[idx])
		var node := GraphNode.new()
		node.name = "Stage%d" % idx
		node.title = stage_name
		node.position_offset = Vector2(24.0 + (idx * 180.0), 22.0)
		node.custom_minimum_size = Vector2(156.0, 62.0)
		node.draggable = false
		node.selectable = false

		var label := Label.new()
		label.text = stage_name
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		node.add_child(label)

		var has_input := idx > 0
		var has_output := idx < stage_count - 1
		node.set_slot(0, has_input, 0, Color(0.72, 0.72, 0.72, 1.0), has_output, 0, Color(0.72, 0.72, 0.72, 1.0))
		stage_flow_graph.add_child(node)

		if idx > 0:
			var from_name := StringName("Stage%d" % (idx - 1))
			var to_name := StringName("Stage%d" % idx)
			stage_flow_graph.connect_node(from_name, 0, to_name, 0)


func _build_stage_flow_names_from_preset() -> Array:
	var stage_names: Array = ["Input"]
	var filter_label := _filter_stage_label_from_state()
	if filter_label != "":
		stage_names.append(filter_label)

	for idx in range(64):
		var raw_name := str(amp_chain_state.stage_display_name(idx))
		if raw_name == "":
			break
		stage_names.append(_display_stage_name(raw_name))

	stage_names.append("Output")
	return stage_names


func _filter_stage_label_from_state() -> String:
	var parsed: Variant = JSON.parse_string(str(amp_chain_state.input_filters_json()))
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	var filters: Dictionary = parsed
	var hp_enabled := bool(filters.get("hp_enabled", false))
	var lp_enabled := bool(filters.get("lp_enabled", false))
	if hp_enabled and lp_enabled:
		return "HP/LP"
	if hp_enabled:
		return "HP"
	if lp_enabled:
		return "LP"
	return ""


func _display_stage_name(raw_name: String) -> String:
	match raw_name:
		"ToneStack":
			return "TS"
		"Preamp":
			return "Pre Amplifier"
		_:
			return raw_name


func set_input_gain(v: float) -> void:
	input_gain_value = clampf(v, 0.0, 100.0)
	_apply_input_trim_db()


func set_output_gain(v: float) -> void:
	output_gain_value = clampf(v, 0.0, 100.0)
	_apply_stage_knob_controls()


func set_bass(v: float) -> void:
	bass_value = clampf(v, 0.0, 10.0)
	_apply_stage_knob_controls()


func set_middle(v: float) -> void:
	middle_value = clampf(v, 0.0, 10.0)
	_apply_stage_knob_controls()


func set_treble(v: float) -> void:
	treble_value = clampf(v, 0.0, 10.0)
	_apply_stage_knob_controls()


func _apply_stage_knob_controls() -> void:
	var tone_bass := lerpf(TONE_MIN, TONE_MAX, bass_value / 10.0)
	var tone_mid := lerpf(TONE_MIN, TONE_MAX, middle_value / 10.0)
	var tone_treble := lerpf(TONE_MIN, TONE_MAX, treble_value / 10.0)
	if not amp_chain_state.set_tonestack(tone_bass, tone_mid, tone_treble):
		return

	var output_gain_db := _value_to_db(output_gain_value, OUTPUT_GAIN_MIN_DB, OUTPUT_GAIN_MAX_DB)
	var output_level := _db_to_level_gain(output_gain_db)
	amp_chain_state.set_level_gain(output_level)

	var tone_idx := amp_chain_state.first_tonestack_index()
	if tone_idx >= 0:
		if not rustortion_effect.set_stage_parameter(tone_idx, "bass", tone_bass):
			push_warning("Failed to set ToneStack bass: %s" % _get_effect_error())
		if not rustortion_effect.set_stage_parameter(tone_idx, "mid", tone_mid):
			push_warning("Failed to set ToneStack mid: %s" % _get_effect_error())
		if not rustortion_effect.set_stage_parameter(tone_idx, "treble", tone_treble):
			push_warning("Failed to set ToneStack treble: %s" % _get_effect_error())

	var level_idx := amp_chain_state.first_level_index()
	if level_idx >= 0:
		if not rustortion_effect.set_stage_parameter(level_idx, "gain", output_level):
			push_warning("Failed to set Level gain: %s" % _get_effect_error())


func _sync_knobs_from_state() -> void:
	var tone := amp_chain_state.current_tonestack_values()
	var level_gain := amp_chain_state.current_level_gain()

	input_gain_value = _db_to_value(0.0, INPUT_GAIN_MIN_DB, INPUT_GAIN_MAX_DB)
	output_gain_value = _db_to_value(_level_gain_to_db(level_gain), OUTPUT_GAIN_MIN_DB, OUTPUT_GAIN_MAX_DB)
	bass_value = _tone_value_from_stack(float(tone.get("bass", 1.0)))
	middle_value = _tone_value_from_stack(float(tone.get("mid", 1.0)))
	treble_value = _tone_value_from_stack(float(tone.get("treble", 1.0)))

	_set_knob_control_value(input_gain_knob, input_gain_value)
	_set_knob_control_value(output_gain_knob, output_gain_value)
	_set_knob_control_value(bass_knob, bass_value)
	_set_knob_control_value(middle_knob, middle_value)
	_set_knob_control_value(treble_knob, treble_value)


func _set_knob_control_value(knob: Control, v: float) -> void:
	if knob == null:
		return
	if knob.has_method("set_value"):
		knob.call("set_value", v, false)


func _tone_value_from_stack(stack_value: float) -> float:
	var norm := clampf((stack_value - TONE_MIN) / (TONE_MAX - TONE_MIN), 0.0, 1.0)
	return norm * 10.0


func _db_to_level_gain(db: float) -> float:
	return clampf(pow(10.0, db / 20.0), 0.0, 2.0)


func _level_gain_to_db(level_gain: float) -> float:
	return 20.0 * log(maxf(level_gain, 0.000001)) / log(10.0)


func _value_to_db(v: float, min_db: float, max_db: float) -> float:
	return lerpf(min_db, max_db, clampf(v / 100.0, 0.0, 1.0))


func _db_to_value(gain_db: float, min_db: float, max_db: float) -> float:
	var norm := clampf((gain_db - min_db) / (max_db - min_db), 0.0, 1.0)
	return norm * 100.0


func _apply_input_trim_db() -> void:
	var gain_db := _value_to_db(input_gain_value, INPUT_GAIN_MIN_DB, INPUT_GAIN_MAX_DB)
	rustortion_effect.set_input_trim_db(gain_db)


func _get_effect_error() -> String:
	return str(rustortion_effect.get_last_error())


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


func _set_input_source_mode(playback_mode: bool) -> void:
	if mic_input_player != null and not mic_input_player.playing:
		mic_input_player.play()
	if not playback_stream_paths.is_empty() and not playback_input_player.playing:
		start_playback_current()

	if playback_mode:
		if playback_input_player != null:
			playback_input_player.stream_paused = false
		set_source_player_enabled(mic_input_player, false)
		set_source_player_enabled(playback_input_player, true)
		current_input_label.text = "Current Input: Guitar dataset playback"
		playback_clip_option.disabled = false
	else:
		if playback_input_player != null:
			playback_input_player.stream_paused = true
		set_source_player_enabled(mic_input_player, true)
		set_source_player_enabled(playback_input_player, true)
		current_input_label.text = "Current Input: System input"
		playback_clip_option.disabled = true

	if playback_mode_button != null:
		playback_mode_button.set_pressed_no_signal(playback_mode)
		if playback_mode_button.has_method("refresh_visual_state"):
			playback_mode_button.call("refresh_visual_state")
	if input_mode_button != null:
		input_mode_button.set_pressed_no_signal(not playback_mode)
		if input_mode_button.has_method("refresh_visual_state"):
			input_mode_button.call("refresh_visual_state")


func _on_playback_mode_button_pressed() -> void:
	_set_input_source_mode(true)


func _on_input_mode_button_pressed() -> void:
	_set_input_source_mode(false)
