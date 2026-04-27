extends Control

const VU_COUNT := 16
const FREQ_MAX := 11050.0
const HEIGHT_SCALE := 8.0
const MIN_DB := 60.0
const ANIMATION_SPEED := 0.1

var spectrum
var min_values: Array[float] = []
var max_values: Array[float] = []


func _ready() -> void:
	min_values.resize(VU_COUNT)
	max_values.resize(VU_COUNT)
	min_values.fill(0.0)
	max_values.fill(0.0)


func set_spectrum(effect_instance) -> void:
	spectrum = effect_instance
	queue_redraw()


func _process(_delta: float) -> void:
	if spectrum == null:
		return

	var values: Array[float] = []
	var prev_hz := 0.0
	var visual_height: float = maxf(size.y * 0.5, 1.0)

	for i in range(1, VU_COUNT + 1):
		var hz: float = i * FREQ_MAX / VU_COUNT
		var magnitude: float = spectrum.get_magnitude_for_frequency_range(prev_hz, hz).length()
		var energy: float = clampf((MIN_DB + linear_to_db(magnitude)) / MIN_DB, 0.0, 1.0)
		values.append(energy * visual_height * HEIGHT_SCALE)
		prev_hz = hz

	for i in range(VU_COUNT):
		if values[i] > max_values[i]:
			max_values[i] = values[i]
		else:
			max_values[i] = lerpf(max_values[i], values[i], ANIMATION_SPEED)

		if values[i] <= 0.0:
			min_values[i] = lerpf(min_values[i], 0.0, ANIMATION_SPEED)

	queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return

	var width := size.x / VU_COUNT
	var center_y := size.y * 0.5

	for i in range(VU_COUNT):
		var min_height := min_values[i]
		var max_height := max_values[i]
		var height: float = minf(lerpf(min_height, max_height, ANIMATION_SPEED), center_y - 4.0)
		var hue: float = float(VU_COUNT * 0.6 + i * 0.5) / VU_COUNT
		var bar_color := Color.from_hsv(hue, 0.5, 0.6)
		var line_color := Color.from_hsv(hue, 0.5, 1.0)
		var x := width * i

		draw_rect(Rect2(x, center_y - height, width - 2.0, height), bar_color)
		draw_line(Vector2(x, center_y - height), Vector2(x + width - 2.0, center_y - height), line_color, 2.0, true)

		draw_rect(Rect2(x, center_y, width - 2.0, height), bar_color * Color(1, 1, 1, 0.125))
		draw_line(Vector2(x, center_y + height), Vector2(x + width - 2.0, center_y + height), line_color * Color(1, 1, 1, 0.125), 2.0, true)
