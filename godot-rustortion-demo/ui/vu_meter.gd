extends VBoxContainer

const MIN_DB := -70.0

@onready var _label_node: Label = %Label
@onready var _meter_fill: TextureProgressBar = %MeterFill
@onready var _value_node: Label = %ValueLabel

var _label := "VU"

@export var label: String = "VU":
	set(value):
		_label = value
		if _label_node != null:
			_label_node.text = value
	get:
		return _label


func _ready() -> void:
	_label_node.text = label
	set_peak_db(MIN_DB)


func set_peak_db(peak_db: float) -> void:
	var clamped_db := maxf(peak_db, MIN_DB)
	var norm := clampf((clamped_db - MIN_DB) / -MIN_DB, 0.0, 1.0)
	_meter_fill.value = norm * 100.0
	_value_node.text = "%.1f dB" % clamped_db
