extends VBoxContainer

signal pressed

const FIXED_WIDTH := 50.0

@onready var _label_node: Label = %Label
@onready var _button: Button = %Button

var _style_normal: StyleBox
var _style_hover: StyleBox
var _style_pressed: StyleBox
var _label := "Mode"
var _button_pressed := false

@export var label: String = "Mode":
	set(value):
		_label = value
		if _label_node != null:
			_label_node.text = value
	get:
		return _label

@export var button_pressed: bool = false:
	set(value):
		_button_pressed = value
		if _button != null:
			_button.set_pressed_no_signal(value)
			refresh_visual_state()
	get:
		if _button != null:
			return _button.button_pressed
		return _button_pressed


func _ready() -> void:
	_style_normal = _button.get("theme_override_styles/normal")
	_style_hover = _button.get("theme_override_styles/hover")
	_style_pressed = _button.get("theme_override_styles/pressed")
	resized.connect(_enforce_fixed_width)
	_enforce_fixed_width()
	_label_node.text = label
	_button.set_pressed_no_signal(_button_pressed)
	_button.toggled.connect(_on_toggled)
	_button.pressed.connect(_on_pressed)
	refresh_visual_state()


func _enforce_fixed_width() -> void:
	if _button != null:
		_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_button.custom_minimum_size.x = FIXED_WIDTH
		_button.size.x = FIXED_WIDTH


func _on_toggled(pressed_state: bool) -> void:
	_button_pressed = pressed_state
	refresh_visual_state()


func _on_pressed() -> void:
	emit_signal("pressed")
	call_deferred("refresh_visual_state")


func set_pressed_no_signal(value: bool) -> void:
	_button_pressed = value
	if _button != null:
		_button.set_pressed_no_signal(value)
		refresh_visual_state()


func refresh_visual_state() -> void:
	if _button == null:
		return
	if _button.button_pressed:
		_button.set("theme_override_styles/normal", _style_pressed)
		_button.set("theme_override_styles/hover", _style_pressed)
		_button.set("theme_override_styles/focus", _style_pressed)
	else:
		_button.set("theme_override_styles/normal", _style_normal)
		_button.set("theme_override_styles/hover", _style_hover)
		_button.set("theme_override_styles/focus", _style_hover)
