class_name VuMeter
extends VBoxContainer

const MIN_DB := -70.0

@onready var _label_node: Label = $Label
@onready var _meter_fill: Control = $MeterBorder/MeterMargin/MeterFill
@onready var _fill_rect: ColorRect = $MeterBorder/MeterMargin/MeterFill/FillRect
@onready var _value_node: Label = $ValueLabel

var _label := "VU"
var _last_db := MIN_DB

@export var label: String = "VU":
	set(value):
		_label = value
		if _label_node != null:
			_label_node.text = value
	get:
		return _label


func _ready() -> void:
	_label_node.text = label
	_meter_fill.resized.connect(_on_meter_resized)
	set_peak_db(MIN_DB)


func set_peak_db(peak_db: float) -> void:
	var clamped_db := maxf(peak_db, MIN_DB)
	_last_db = clamped_db
	var norm := clampf((clamped_db - MIN_DB) / -MIN_DB, 0.0, 1.0)
	_fill_rect.anchor_left = 0.0
	_fill_rect.anchor_right = 1.0
	_fill_rect.anchor_bottom = 1.0
	_fill_rect.anchor_top = 1.0 - norm
	_fill_rect.offset_left = 0.0
	_fill_rect.offset_right = 0.0
	_fill_rect.offset_top = 0.0
	_fill_rect.offset_bottom = 0.0
	_value_node.text = "%.1f dB" % clamped_db


func _on_meter_resized() -> void:
	# Keep fill geometry consistent after layout changes.
	set_peak_db(_last_db)
