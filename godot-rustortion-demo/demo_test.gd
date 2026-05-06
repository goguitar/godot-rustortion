extends SceneTree

const TARGET_BUS_NAME := "Rustortion"
const MIN_PASS_PEAK_DB := -55.0
const TIMEOUT_SECONDS := 8.0

var elapsed := 0.0
var max_peak_db := -120.0
var main_instance: Node = null
var quit_requested := false
var quit_code := 1
var quit_delay := 0.0


func _initialize() -> void:
	var main_scene: PackedScene = load("res://main.tscn")
	if main_scene == null:
		push_error("demo_test: failed to load res://main.tscn")
		quit(1)
		return

	main_instance = main_scene.instantiate()
	if main_instance == null:
		push_error("demo_test: failed to instantiate main scene")
		quit(1)
		return

	root.add_child(main_instance)


func _process(delta: float) -> bool:
	elapsed += delta

	if quit_requested:
		quit_delay -= delta
		if quit_delay <= 0.0:
			quit(quit_code)
		return false

	_sample_bus_peak()

	if elapsed < TIMEOUT_SECONDS:
		return false

	if max_peak_db > MIN_PASS_PEAK_DB:
		print("demo_test: PASS (max Rustortion peak %.2f dB)" % max_peak_db)
		_request_quit(0)
	else:
		push_error("demo_test: FAIL (Rustortion peak %.2f dB <= %.2f dB)" % [max_peak_db, MIN_PASS_PEAK_DB])
		_request_quit(1)

	return false


func _sample_bus_peak() -> void:
	var bus_idx := AudioServer.get_bus_index(TARGET_BUS_NAME)
	if bus_idx < 0:
		return

	var channels := AudioServer.get_bus_channels(bus_idx)
	if channels <= 0:
		return

	var left_db := AudioServer.get_bus_peak_volume_left_db(bus_idx, 0)
	var right_db := AudioServer.get_bus_peak_volume_right_db(bus_idx, 0)
	max_peak_db = maxf(max_peak_db, maxf(left_db, right_db))


func _request_quit(code: int) -> void:
	if quit_requested:
		return

	quit_requested = true
	quit_code = code
	quit_delay = 0.2
	_cleanup_main_scene()


func _cleanup_main_scene() -> void:
	if main_instance == null:
		return

	var playback_player := main_instance.find_child("PlaybackInputPlayer", true, false)
	if playback_player is AudioStreamPlayer:
		playback_player.stop()
		playback_player.stream = null

	var mic_player := main_instance.find_child("MicInputPlayer", true, false)
	if mic_player is AudioStreamPlayer:
		mic_player.stop()
		mic_player.stream = null

	main_instance.queue_free()
	main_instance = null
