class_name AmpChainState
extends RefCounted

const DEFAULT_INPUT_FILTERS := {
	"hp_enabled": true,
	"hp_cutoff": 100.0,
	"lp_enabled": true,
	"lp_cutoff": 8000.0
}

var preset_name := ""
var stages: Array = []
var input_filters: Dictionary = DEFAULT_INPUT_FILTERS.duplicate(true)


func clear() -> void:
	preset_name = ""
	stages.clear()
	input_filters = DEFAULT_INPUT_FILTERS.duplicate(true)


func load_from_source_preset(preset: Dictionary) -> void:
	clear()
	preset_name = str(preset.get("name", "Preset"))
	for entry in preset.get("stages", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		stages.append((entry as Dictionary).duplicate(true))
	input_filters = (preset.get("input_filters", DEFAULT_INPUT_FILTERS) as Dictionary).duplicate(true)


func stages_json() -> String:
	return JSON.stringify(stages)


func input_filters_json() -> String:
	return JSON.stringify(input_filters)


func first_tonestack_index() -> int:
	return _find_first_stage_index("ToneStack")


func first_level_index() -> int:
	return _find_first_stage_index("Level")


func current_tonestack_values() -> Dictionary:
	var idx := first_tonestack_index()
	if idx < 0:
		return {"bass": 1.0, "mid": 1.0, "treble": 1.0}
	var stack: Dictionary = (stages[idx] as Dictionary).get("ToneStack", {})
	return {
		"bass": float(stack.get("bass", 1.0)),
		"mid": float(stack.get("mid", 1.0)),
		"treble": float(stack.get("treble", 1.0))
	}


func current_level_gain() -> float:
	var idx := first_level_index()
	if idx < 0:
		return 1.0
	var level: Dictionary = (stages[idx] as Dictionary).get("Level", {})
	return float(level.get("gain", 1.0))


func set_tonestack(bass: float, mid: float, treble: float) -> bool:
	var idx := first_tonestack_index()
	if idx < 0:
		return false
	var entry: Dictionary = (stages[idx] as Dictionary).duplicate(true)
	var stack: Dictionary = (entry.get("ToneStack", {}) as Dictionary).duplicate(true)
	stack["bass"] = bass
	stack["mid"] = mid
	stack["treble"] = treble
	entry["ToneStack"] = stack
	stages[idx] = entry
	return true


func set_level_gain(gain: float) -> bool:
	var idx := first_level_index()
	if idx < 0:
		return false
	var entry: Dictionary = (stages[idx] as Dictionary).duplicate(true)
	var level: Dictionary = (entry.get("Level", {}) as Dictionary).duplicate(true)
	level["gain"] = gain
	entry["Level"] = level
	stages[idx] = entry
	return true


func add_stage(parent_stage_idx: int, stage_entry: Dictionary, insert_after: bool) -> int:
	var entry := stage_entry.duplicate(true)
	if parent_stage_idx == -1:
		stages.append(entry)
		return stages.size() - 1
	if parent_stage_idx < 0 or parent_stage_idx >= stages.size():
		return -1
	var insert_idx := parent_stage_idx + 1 if insert_after else parent_stage_idx
	stages.insert(insert_idx, entry)
	return insert_idx


func remove_stage(stage_idx: int) -> bool:
	if stage_idx < 0 or stage_idx >= stages.size():
		return false
	stages.remove_at(stage_idx)
	return true


func swap_stages(a: int, b: int) -> bool:
	if a < 0 or b < 0 or a >= stages.size() or b >= stages.size():
		return false
	var temp = stages[a]
	stages[a] = stages[b]
	stages[b] = temp
	return true


func rebuild_stage(stage_idx: int, stage_entry: Dictionary) -> bool:
	if stage_idx < 0 or stage_idx >= stages.size():
		return false
	stages[stage_idx] = stage_entry.duplicate(true)
	return true


func stage_json(stage_idx: int) -> String:
	if stage_idx < 0 or stage_idx >= stages.size():
		return ""
	return JSON.stringify(stages[stage_idx])


func stage_display_name(stage_idx: int) -> String:
	if stage_idx < 0 or stage_idx >= stages.size():
		return ""
	if typeof(stages[stage_idx]) != TYPE_DICTIONARY:
		return "Unknown"
	var stage: Dictionary = stages[stage_idx]
	if stage.is_empty():
		return "Unknown"
	return str(stage.keys()[0])


func _find_first_stage_index(stage_name: String) -> int:
	for idx in range(stages.size()):
		if typeof(stages[idx]) != TYPE_DICTIONARY:
			continue
		var stage: Dictionary = stages[idx]
		if stage.has(stage_name):
			return idx
	return -1
