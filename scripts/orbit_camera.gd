extends Camera3D
## 简单轨道相机：左键拖动旋转，滚轮缩放。

@export var focus := Vector3(0.3, 1.25, 0.0)
@export var distance := 3.0
@export var yaw := 0.5
@export var pitch := 0.14  # 俯视角（弧度），正值从上往下看
@export var min_distance := 1.0
@export var max_distance := 8.0

var _dragging := false

func _ready() -> void:
	apply()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance * 0.9, min_distance, max_distance)
			apply()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance * 1.1, min_distance, max_distance)
			apply()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		yaw -= mm.relative.x * 0.006
		pitch = clampf(pitch + mm.relative.y * 0.006, -0.9, 1.2)
		apply()

func apply() -> void:
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	) * distance
	position = focus + offset
	look_at(focus, Vector3.UP)
