extends Control

const MIC_BUS_NAME := "GuitarMic"
const PLAY_BUS_NAME := "GuitarPlay"
const RUSTORTION_BUS_NAME := "Rustortion"
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

@onready var rustortion_effect: AudioEffectRustortion = _resolve_rustortion_effect()
var rustortion_bus_idx := -1
var mic_bus_idx := -1
var play_bus_idx := -1
var active_rig_name := ""

var rigs: Array = []
var playback_stream_paths := PackedStringArray()
var selected_playback_index := 0
var input_gain_value := 50.0
var output_gain_value := 50.0
var bass_value := 5.0
var middle_value := 5.0
var treble_value := 5.0

var active_payload: Dictionary = {}
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
@onready var input_vu_meter: Control = %InputVuMeter
@onready var output_vu_meter: Control = %OutputVuMeter


func _ready() -> void:
	setup_bus_effects()
	load_rigs()
	load_playback_stream_list()
	setup_playback_controls()
	populate_rig_list()
	apply_default_selection()
	set_source_bus_mute_states(true, false)
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

	rustortion_effect = null
	rustortion_bus_idx = -1
	mic_bus_idx = -1
	play_bus_idx = -1


func setup_bus_effects() -> void:
	mic_bus_idx = AudioServer.get_bus_index(MIC_BUS_NAME)
	play_bus_idx = AudioServer.get_bus_index(PLAY_BUS_NAME)
	rustortion_bus_idx = AudioServer.get_bus_index(RUSTORTION_BUS_NAME)

	if rustortion_bus_idx < 0:
		push_error("Missing audio bus: %s" % RUSTORTION_BUS_NAME)


func _resolve_rustortion_effect() -> AudioEffectRustortion:
	var bus_idx := AudioServer.get_bus_index(RUSTORTION_BUS_NAME)
	if bus_idx < 0:
		push_error("Missing audio bus: %s" % RUSTORTION_BUS_NAME)
		return null

	var effect_idx := find_rustortion_effect_index(bus_idx)
	if effect_idx < 0:
		push_error("Missing Rustortion effect on bus %s" % RUSTORTION_BUS_NAME)
		return null

	var effect := AudioServer.get_bus_effect(bus_idx, effect_idx) as AudioEffectRustortion
	if effect == null:
		push_error("Rustortion effect on bus %s is not AudioEffectRustortion" % RUSTORTION_BUS_NAME)
	return effect


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
	if mic_bus_idx >= 0:
		AudioServer.set_bus_mute(mic_bus_idx, mic_muted)

	if play_bus_idx >= 0:
		AudioServer.set_bus_mute(play_bus_idx, play_muted)


func load_rigs() -> void:
	rigs.clear()
	load_source_presets()


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
		rustortion_effect.load_amp_tone_and_ir_data(
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
	active_payload = translated.duplicate(true)
	_sync_knobs_from_payload(active_payload)
	_apply_input_trim_db()
	_apply_live_runtime_controls()


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

	var tone_preset := {
		"schema_version": 1,
		"name": "%s Tone" % str(preset.get("name", "Source")),
		"preamp_chain": preamp_chain
	}

	var amp_preset := {
		"schema_version": 1,
		"name": "%s Amp" % str(preset.get("name", "Source")),
		"input_filters": input_filters,
		"amp_chain": amp_chain
	}

	return {
		"tone_preset": tone_preset,
		"amp_preset": amp_preset,
		"tone_json": JSON.stringify(tone_preset),
		"amplifier_json": JSON.stringify(amp_preset),
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
	var input_peak_db := MIN_METER_DB
	var output_peak_db := MIN_METER_DB
	if rustortion_effect != null:
		input_peak_db = float(rustortion_effect.get_input_peak_db())
		output_peak_db = float(rustortion_effect.get_output_peak_db())

	input_meter_db = _smooth_meter_db(input_meter_db, input_peak_db)
	output_meter_db = _smooth_meter_db(output_meter_db, output_peak_db)

	if input_vu_meter != null and input_vu_meter.has_method("set_peak_db"):
		input_vu_meter.call("set_peak_db", input_meter_db)
	if output_vu_meter != null and output_vu_meter.has_method("set_peak_db"):
		output_vu_meter.call("set_peak_db", output_meter_db)

func _smooth_meter_db(current_db: float, target_db: float) -> float:
	target_db = maxf(target_db, MIN_METER_DB)
	if target_db > current_db:
		return lerpf(current_db, target_db, 0.55)
	return lerpf(current_db, target_db, 0.12)


func update_status() -> void:
	var playback_clip := "-"
	if not playback_stream_paths.is_empty():
		playback_clip = _clip_display_name(playback_stream_paths[selected_playback_index])

	var source_channels := AudioServer.get_bus_channels(play_bus_idx) if play_bus_idx >= 0 else 0
	var process_channels := AudioServer.get_bus_channels(rustortion_bus_idx) if rustortion_bus_idx >= 0 else 0
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
	_apply_live_runtime_controls()


func set_input_gain(v: float) -> void:
	input_gain_value = clampf(v, 0.0, 100.0)
	_apply_input_trim_db()


func set_output_gain(v: float) -> void:
	output_gain_value = clampf(v, 0.0, 100.0)
	_apply_live_runtime_controls()


func set_bass(v: float) -> void:
	bass_value = clampf(v, 0.0, 10.0)
	_apply_live_runtime_controls()


func set_middle(v: float) -> void:
	middle_value = clampf(v, 0.0, 10.0)
	_apply_live_runtime_controls()


func set_treble(v: float) -> void:
	treble_value = clampf(v, 0.0, 10.0)
	_apply_live_runtime_controls()


func _apply_live_runtime_controls() -> void:
	if rustortion_effect == null:
		return
	var tone_bass := lerpf(TONE_MIN, TONE_MAX, bass_value / 10.0)
	var tone_mid := lerpf(TONE_MIN, TONE_MAX, middle_value / 10.0)
	var tone_treble := lerpf(TONE_MIN, TONE_MAX, treble_value / 10.0)
	if not rustortion_effect.set_live_tonestack(tone_bass, tone_mid, tone_treble):
		push_warning("Failed to set live ToneStack: %s" % _get_effect_error())
	var output_trim_db := _value_to_db(output_gain_value, OUTPUT_GAIN_MIN_DB, OUTPUT_GAIN_MAX_DB)
	rustortion_effect.set_output_trim_db(output_trim_db)


func _sync_knobs_from_payload(payload: Dictionary) -> void:
	var tone_base := (payload.get("tone_preset", {}) as Dictionary).duplicate(true)
	var amp_base := (payload.get("amp_preset", {}) as Dictionary).duplicate(true)
	if tone_base.is_empty():
		tone_base = _parse_json_dict(str(payload.get("tone_json", "")))
	if amp_base.is_empty():
		amp_base = _parse_json_dict(str(payload.get("amplifier_json", "")))

	input_gain_value = _db_to_value(0.0, INPUT_GAIN_MIN_DB, INPUT_GAIN_MAX_DB)
	output_gain_value = _db_to_value(0.0, OUTPUT_GAIN_MIN_DB, OUTPUT_GAIN_MAX_DB)

	if not tone_base.is_empty():
		var preamp_chain: Array = tone_base.get("preamp_chain", [])
		if preamp_chain.is_empty():
			input_gain_value = _db_to_value(0.0, INPUT_GAIN_MIN_DB, INPUT_GAIN_MAX_DB)

	if not amp_base.is_empty():
		var amp_chain: Array = amp_base.get("amp_chain", [])
		for entry in amp_chain:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var stage_entry: Dictionary = entry
			if stage_entry.has("ToneStack"):
				var stack: Dictionary = stage_entry.get("ToneStack", {})
				bass_value = _tone_value_from_stack(float(stack.get("bass", 1.0)))
				middle_value = _tone_value_from_stack(float(stack.get("mid", 1.0)))
				treble_value = _tone_value_from_stack(float(stack.get("treble", 1.0)))

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


func _input_value_from_preamp_gain(gain: float) -> float:
	var norm := clampf((gain - 1.0) / (2.4 - 1.0), 0.0, 1.0)
	return norm * 100.0


func _tone_value_from_stack(stack_value: float) -> float:
	var norm := clampf((stack_value - TONE_MIN) / (TONE_MAX - TONE_MIN), 0.0, 1.0)
	return norm * 10.0
func _value_to_db(v: float, min_db: float, max_db: float) -> float:
	return lerpf(min_db, max_db, clampf(v / 100.0, 0.0, 1.0))


func _db_to_value(gain_db: float, min_db: float, max_db: float) -> float:
	var norm := clampf((gain_db - min_db) / (max_db - min_db), 0.0, 1.0)
	return norm * 100.0
func _apply_input_trim_db() -> void:
	if rustortion_effect == null:
		return
	var gain_db := _value_to_db(input_gain_value, INPUT_GAIN_MIN_DB, INPUT_GAIN_MAX_DB)
	rustortion_effect.set_input_trim_db(gain_db)


func _parse_json_dict(json_text: String) -> Dictionary:
	if json_text == "":
		return {}
	var parsed: Variant = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


func _get_effect_error() -> String:
	if rustortion_effect != null:
		return str(rustortion_effect.get_last_error())
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

	if input_mode_button != null and input_mode_button.button_pressed:
		return

	selected_playback_index = (selected_playback_index + 1) % playback_stream_paths.size()
	playback_clip_option.select(selected_playback_index)
	start_playback_current()


func _set_input_source_mode(playback_mode: bool) -> void:
	if playback_mode:
		set_source_bus_mute_states(true, false)
		if mic_input_player != null and mic_input_player.playing:
			mic_input_player.stop()
		if not playback_stream_paths.is_empty() and not playback_input_player.playing:
			start_playback_current()
		current_input_label.text = "Current Input: Guitar dataset playback"
		playback_clip_option.disabled = false
	else:
		set_source_bus_mute_states(false, true)
		if playback_input_player.playing:
			playback_input_player.stop()
		if mic_input_player != null and not mic_input_player.playing:
			mic_input_player.play()
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
