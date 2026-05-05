extends Control

signal value_changed(value: float)

@export var knob_texture: Texture2D
@export var ring_color := Color(0.215686, 0.494118, 0.27451, 1.0)
@export var ring_bg_color := Color(0.2, 0.2, 0.2, 0.7)
@export var ring_width := 6.0
@export var ring_gap := 0.0
@export var start_angle_deg := 135.0
@export var end_angle_deg := 405.0
@export var texture_scale := 0.72
@export var wheel_step := 1.0
@export var value := 50.0
@export var value_min := 0.0
@export var value_max := 100.0
@export var knob_label := "Input gain"
@export var label_height := 24.0
@export var value_decimals := 0
@export var value_suffix := "%"
@export var display_min := 0.0
@export var display_max := 100.0

@onready var knob_label_node: Label = %KnobLabel
@onready var value_label_node: Label = %ValueLabel


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_set_value(value, false)
	_refresh_labels()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_value(value + wheel_step)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_value(value - wheel_step)
			accept_event()


func set_value(v: float, emit_signal_on_change := true) -> void:
	_set_value(v, emit_signal_on_change)


func get_value() -> float:
	return value


func _set_value(v: float, emit_signal_on_change := true) -> void:
	var next := clampf(v, value_min, value_max)
	if is_equal_approx(next, value):
		return
	value = next
	_refresh_labels()
	if emit_signal_on_change:
		value_changed.emit(value)
	queue_redraw()


func _refresh_labels() -> void:
	if knob_label_node != null:
		knob_label_node.text = knob_label
	if value_label_node != null:
		var t := 0.0
		if not is_equal_approx(value_max, value_min):
			t = clampf((value - value_min) / (value_max - value_min), 0.0, 1.0)
		var shown := lerpf(display_min, display_max, t)
		value_label_node.text = "%.*f%s" % [value_decimals, shown, value_suffix]


func _draw() -> void:
	var level_norm := 0.0
	if not is_equal_approx(value_max, value_min):
		level_norm = clampf((value - value_min) / (value_max - value_min), 0.0, 1.0)
	var meter_top := label_height
	var meter_height := maxf(1.0, size.y - label_height * 2.0)
	var center := Vector2(size.x * 0.5, meter_top + meter_height * 0.5)
	var max_radius := maxf(1.0, minf(size.x, meter_height) * 0.5 - ring_width)
	var start := deg_to_rad(start_angle_deg)
	var end := deg_to_rad(end_angle_deg)
	var meter_end := lerpf(start, end, level_norm)
	var radius := max_radius
	var tex_size := Vector2.ZERO
	if knob_texture != null:
		tex_size = knob_texture.get_size() * texture_scale
		var knob_radius := minf(tex_size.x, tex_size.y) * 0.5
		radius = clampf(knob_radius + ring_gap, 1.0, max_radius)

	draw_arc(center, radius, start, end, 64, ring_bg_color, ring_width, true)
	draw_arc(center, radius, start, meter_end, 64, ring_color, ring_width, true)

	if knob_texture != null:
		var target := Rect2(center - tex_size * 0.5, tex_size)
		draw_texture_rect(knob_texture, target, false)
