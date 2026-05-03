extends Button

var _style_normal: StyleBox
var _style_hover: StyleBox
var _style_pressed: StyleBox


func _ready() -> void:
	_style_normal = get("theme_override_styles/normal")
	_style_hover = get("theme_override_styles/hover")
	_style_pressed = get("theme_override_styles/pressed")
	toggled.connect(_on_toggled)
	refresh_visual_state()


func _on_toggled(_pressed: bool) -> void:
	refresh_visual_state()


func refresh_visual_state() -> void:
	if button_pressed:
		set("theme_override_styles/normal", _style_pressed)
		set("theme_override_styles/hover", _style_pressed)
	else:
		set("theme_override_styles/normal", _style_normal)
		set("theme_override_styles/hover", _style_hover)
