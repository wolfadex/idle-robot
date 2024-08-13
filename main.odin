package main

import "core:fmt"
import "core:log"
import math "core:math/big"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "core:unicode/utf8/utf8string"
import mu "vendor:microui"
import rl "vendor:raylib"

state := struct {
	log_buf:                      [1 << 16]byte,
	log_buf_len:                  int,
	log_buf_updated:              bool,
	bg:                           mu.Color,
	atlas_texture:                rl.Texture2D,
	// new game
	metal_ore:                    uint,
	has_reached_chassis_minimums: bool,
	chassis_to_assemble:          uint,
	chassis:                      uint,
	has_reached_battery_minimums: bool,
	batteries_to_assemble:        uint,
	batteries:                    uint,
	has_reached_robot_minimums:   bool,
	robots_to_assemble:           uint,
	robots:                       [dynamic]Robot,
	shovels_to_assemble:          uint,
	shovel_attachments:           uint,
	// resources
	ui_atlas:                     rl.Texture,
	ui_arrow:                     rl.Texture,
	ui_font:                      rl.Font,
	// UI state
	focus:                        union {
		FocusState,
	},
} {
	bg = {90, 95, 100, 255},
}

Robot :: struct {
	attachments:      Attachments,
	progress_in_goal: f32,
}
Attachment :: enum {
	Shovel,
}
Attachments :: distinct bit_set[Attachment]

InputId :: enum uint {
	GATHER_ORE_BUTTON = 1,
	ASSEMBLE_CHASSIS_BUTTON,
	ASSEMBLE_BATTERY_BUTTON,
	ASSEMBLE_ROBOT_BUTTON,
	ASSEMBLE_SHOVEL_BUTTON,
	ATTACH_SHOVEL_TO_ROBOT,
	CHASSIS_INPUT_NUMBER,
	BATTERY_INPUT_NUMBER,
	ROBOT_INPUT_NUMBER,
}

FocusState :: struct {
	id:         InputId,
	cursor_pos: uint,
}

// CHASSIS_INPUT_ID: uintptr = 0
// BATTERY_INPUT_ID: uintptr = 1
// ROBOT_INPUT_ID: uintptr = 2
// SHOVEL_INPUT_ID: uintptr = 3


main :: proc() {
	when ODIN_DEBUG {
		// setup debug logging
		logger := log.create_console_logger()
		context.logger = logger

		// setup tracking allocator for making sure all memory is cleaned up
		default_allocator := context.allocator
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, default_allocator)
		context.allocator = mem.tracking_allocator(&tracking_allocator)

		reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
			err := false

			for _, value in a.allocation_map {
				fmt.printfln("%v: Leaked %v bytes", value.location, value.size)
				err = true
			}

			mem.tracking_allocator_clear(a)

			return err
		}

		defer reset_tracking_allocator(&tracking_allocator)
	}

	rl.InitWindow(1368, 800, "More Robots!")
	defer rl.CloseWindow()

	pixels := make([][4]u8, mu.DEFAULT_ATLAS_WIDTH * mu.DEFAULT_ATLAS_HEIGHT)
	for alpha, i in mu.default_atlas_alpha {
		pixels[i] = {0xff, 0xff, 0xff, alpha}
	}
	defer delete(pixels)

	image := rl.Image {
		data    = raw_data(pixels),
		width   = mu.DEFAULT_ATLAS_WIDTH,
		height  = mu.DEFAULT_ATLAS_HEIGHT,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	state.atlas_texture = rl.LoadTextureFromImage(image)
	defer rl.UnloadTexture(state.atlas_texture)

	state.ui_atlas = rl.LoadTexture("resources/Ui Space Pack/Spritesheet/uipackSpace_sheet.png")
	defer rl.UnloadTexture(state.ui_atlas)
	state.ui_arrow = rl.LoadTexture("resources/Ui Base Pack/PNG/Blue/Default/arrow_basic_e.png")
	defer rl.UnloadTexture(state.ui_arrow)

	state.ui_font = rl.LoadFontEx(
		"resources/Ui Space Pack/Fonts/kenvector_future_thin.ttf",
		32,
		{},
		62,
	)
	defer rl.UnloadFont(state.ui_font)

	state.robots = {}

	rl.SetTargetFPS(60)
	main_loop: for !rl.WindowShouldClose() {
		game_tick()
		render()
	}
}

game_tick :: proc() {
	delta_time := rl.GetFrameTime()

	for &robot in state.robots {
		if .Shovel in robot.attachments {
			robot.progress_in_goal += delta_time

			if robot.progress_in_goal >= 3 {
				increment_metal_ore(2)
				robot.progress_in_goal -= 3
			}
		}
	}
}

render :: proc() {
	rl.ClearBackground(transmute(rl.Color)state.bg)

	rl.BeginDrawing()
	defer rl.EndDrawing()

	rl.BeginScissorMode(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight())
	defer rl.EndScissorMode()

	// BACKGROUND 1

	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 100, // Rectangle top-left corner position x
				y      = 0, // Rectangle top-left corner position y
				width  = 60, // Rectangle width
				height = 30, // Rectangle height
			}, // Texture source rectangle
			left = 8, // Left border offset
			top = 0, // Top border offset
			right = 12, // Right border offset
			bottom = 0, // Bottom border offset
			layout = rl.NPatchLayout.THREE_PATCH_HORIZONTAL, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		{x = 20, y = 20, width = 150, height = 31},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 160, // Rectangle top-left corner position x
				y      = 0, // Rectangle top-left corner position y
				width  = 40, // Rectangle width
				height = 30, // Rectangle height
			}, // Texture source rectangle
			left = 10, // Left border offset
			top = 10, // Top border offset
			right = 10, // Right border offset
			bottom = 10, // Bottom border offset
			layout = rl.NPatchLayout.THREE_PATCH_HORIZONTAL, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		{x = 170, y = 20, width = 750, height = 31},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 100, // Rectangle top-left corner position x
				y      = 31, // Rectangle top-left corner position y
				width  = 100, // Rectangle width
				height = 69, // Rectangle height
			}, // Texture source rectangle
			left = 10, // Left border offset
			top = 10, // Top border offset
			right = 10, // Right border offset
			bottom = 10, // Bottom border offset
			layout = rl.NPatchLayout.NINE_PATCH, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		{x = 20, y = 50, width = 900, height = 500},
		{0, 0},
		0,
		rl.WHITE,
	)

	rl.DrawTextEx(state.ui_font, "GATHER", {30, 20}, 32, 0, rl.WHITE)

	// BACKGROUND 2

	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 200, // Rectangle top-left corner position x
				y      = 0, // Rectangle top-left corner position y
				width  = 60, // Rectangle width
				height = 30, // Rectangle height
			}, // Texture source rectangle
			left = 8, // Left border offset
			top = 0, // Top border offset
			right = 12, // Right border offset
			bottom = 0, // Bottom border offset
			layout = rl.NPatchLayout.THREE_PATCH_HORIZONTAL, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		{x = 930, y = 20, width = 150, height = 31},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 260, // Rectangle top-left corner position x
				y      = 0, // Rectangle top-left corner position y
				width  = 40, // Rectangle width
				height = 30, // Rectangle height
			}, // Texture source rectangle
			left = 10, // Left border offset
			top = 10, // Top border offset
			right = 10, // Right border offset
			bottom = 10, // Bottom border offset
			layout = rl.NPatchLayout.THREE_PATCH_HORIZONTAL, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		{x = 1_080, y = 20, width = 250, height = 31},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 200, // Rectangle top-left corner position x
				y      = 31, // Rectangle top-left corner position y
				width  = 100, // Rectangle width
				height = 69, // Rectangle height
			}, // Texture source rectangle
			left = 10, // Left border offset
			top = 10, // Top border offset
			right = 10, // Right border offset
			bottom = 10, // Bottom border offset
			layout = rl.NPatchLayout.NINE_PATCH, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		{x = 930, y = 50, width = 400, height = 500},
		{0, 0},
		0,
		rl.WHITE,
	)

	rl.DrawTextEx(state.ui_font, "COUNTS", {940, 20}, 32, 0, rl.WHITE)


	// INPUTS

	if button({30, 55}, "GATHER ORE", .GATHER_ORE_BUTTON) {
		increment_metal_ore(1)
	}

	rl.DrawTextEx(state.ui_font, "METAL ORE:", {940, 59}, 32, 0, rl.WHITE)
	rl.DrawTextEx(
		state.ui_font,
		fmt.ctprintf("%d", state.metal_ore),
		{1_120, 59},
		32,
		0,
		rl.ORANGE,
	)

	if state.has_reached_chassis_minimums {
		if button({30, 110}, "ASSEMBLE", .ASSEMBLE_CHASSIS_BUTTON) {
			increment_chassis(state.chassis_to_assemble)
		}

		input_uint({230, 110}, 100, &state.chassis_to_assemble, .CHASSIS_INPUT_NUMBER)
		rl.DrawTextEx(
			state.ui_font,
			fmt.ctprintf(
				"CHASSIS, %d METAL ORE",
				CHASIS_METAL_ORE_COST * state.chassis_to_assemble,
			),
			{350, 115},
			32,
			0,
			rl.WHITE,
		)

		rl.DrawTextEx(state.ui_font, "CHASSIS:", {940, 114}, 32, 0, rl.WHITE)
		rl.DrawTextEx(
			state.ui_font,
			fmt.ctprintf("%d", state.chassis),
			{1_080, 114},
			32,
			0,
			rl.ORANGE,
		)
	}

	if state.has_reached_battery_minimums {
		if button({30, 170}, "ASSEMBLE", .ASSEMBLE_BATTERY_BUTTON) {
			increment_battery(state.batteries_to_assemble)
		}

		input_uint({230, 170}, 100, &state.batteries_to_assemble, .BATTERY_INPUT_NUMBER)
		rl.DrawTextEx(
			state.ui_font,
			fmt.ctprintf(
				"BATTERIES, %d METAL ORE",
				BATTERY_METAL_ORE_COST * state.batteries_to_assemble,
			),
			{350, 175},
			32,
			0,
			rl.WHITE,
		)

		rl.DrawTextEx(state.ui_font, "BATTERIES:", {940, 174}, 32, 0, rl.WHITE)
		rl.DrawTextEx(
			state.ui_font,
			fmt.ctprintf("%d", state.batteries),
			{1_115, 174},
			32,
			0,
			rl.ORANGE,
		)
	}

	if state.has_reached_robot_minimums {
		if button({30, 231}, "ASSEMBLE", .ASSEMBLE_ROBOT_BUTTON) {
			increment_robot(state.robots_to_assemble)
		}

		input_uint({230, 231}, 100, &state.robots_to_assemble, .ROBOT_INPUT_NUMBER)
		rl.DrawTextEx(
			state.ui_font,
			fmt.ctprintf(
				"ROBOTS, %d CHASSIS, %d BATTERIES",
				ROBOT_CHASSIS_COST * state.robots_to_assemble,
				ROBOT_BATTERY_COST * state.robots_to_assemble,
			),
			{350, 236},
			32,
			0,
			rl.WHITE,
		)

		rl.DrawTextEx(state.ui_font, "ROBOTS:", {940, 235}, 32, 0, rl.WHITE)
		rl.DrawTextEx(
			state.ui_font,
			fmt.ctprintf("%d", len(state.robots)),
			{1_080, 235},
			32,
			0,
			rl.ORANGE,
		)
		// 			mu.layout_row(ctx, {60, 60, 140, -1}, 0)
		// 			mu.label(ctx, "Robot")
		// 			uint_slider(
		// 				ctx,
		// 				&state.robots_to_assemble,
		// 				0,
		// 				min(
		// 					uint(state.chassis / ROBOT_CHASSIS_COST),
		// 					uint(state.batteries / ROBOT_BATTERY_COST),
		// 				),
		// 				ROBOT_INPUT_ID,
		// 			)
		// 			mu.label(
		// 				ctx,
		// 				fmt.tprintf(
		// 					"x %d chassis & x %d batteries",
		// 					ROBOT_CHASSIS_COST,
		// 					ROBOT_BATTERY_COST,
		// 				),
		// 			)

		// 			if .SUBMIT in button(ctx, "Assemble", mu.Id(InputId.ASSEMBLE_ROBOT_BUTTON)) {
		// 				increment_robot(state.robots_to_assemble)
		// 			}

		// 			mu.label(ctx, "Shovel")
		// 			uint_slider(
		// 				ctx,
		// 				&state.shovels_to_assemble,
		// 				0,
		// 				uint(state.metal_ore / SHOVEL_COST),
		// 				SHOVEL_INPUT_ID,
		// 			)
		// 			mu.label(ctx, fmt.tprintf("x %d ore", SHOVEL_COST))

		// 			if .SUBMIT in button(ctx, "Assemble", mu.Id(InputId.ASSEMBLE_SHOVEL_BUTTON)) {
		// 				increment_shovels(state.shovels_to_assemble)
		// 			}
	}
}

increment_metal_ore :: proc(increment_by: uint) {
	pre_max_chassis := uint(state.metal_ore / CHASIS_METAL_ORE_COST)
	at_max_chassis := pre_max_chassis == state.chassis_to_assemble

	state.metal_ore += increment_by

	if !state.has_reached_chassis_minimums && state.metal_ore >= CHASIS_METAL_ORE_COST {
		state.has_reached_chassis_minimums = true
	}

	if at_max_chassis {
		post_max_chassis := uint(state.metal_ore / CHASIS_METAL_ORE_COST)

		if post_max_chassis > pre_max_chassis {
			state.chassis_to_assemble = post_max_chassis
		}
	}
}

CHASIS_METAL_ORE_COST: uint = 20

increment_chassis :: proc(increment_by: uint) {
	for i := increment_by; i > 0; i -= 1 {
		if state.metal_ore >= CHASIS_METAL_ORE_COST {
			state.chassis += 1
			state.metal_ore -= CHASIS_METAL_ORE_COST
		} else {
			break
		}
	}

	if !state.has_reached_battery_minimums && state.chassis >= 2 {
		state.has_reached_battery_minimums = true
	}
}

BATTERY_METAL_ORE_COST: uint = 10

increment_battery :: proc(increment_by: uint) {
	for i := increment_by; i > 0; i -= 1 {
		if state.metal_ore >= BATTERY_METAL_ORE_COST {
			state.batteries += 1
			state.metal_ore -= BATTERY_METAL_ORE_COST

		} else {
			break
		}
	}

	if !state.has_reached_robot_minimums && state.batteries >= 3 {
		state.has_reached_robot_minimums = true
	}
}

ROBOT_CHASSIS_COST: uint = 1
ROBOT_BATTERY_COST: uint = 2

increment_robot :: proc(increment_by: uint) {
	for i := increment_by; i > 0; i -= 1 {
		if state.chassis >= ROBOT_CHASSIS_COST && state.batteries >= ROBOT_BATTERY_COST {
			append(&state.robots, Robot{})
			state.chassis -= ROBOT_CHASSIS_COST
			state.batteries -= ROBOT_BATTERY_COST
		} else {
			break
		}
	}
}

SHOVEL_COST: uint = 10

increment_shovels :: proc(increment_by: uint) {
	for i := increment_by; i > 0; i -= 1 {
		if state.metal_ore >= SHOVEL_COST {
			state.shovel_attachments += 1
			state.metal_ore -= SHOVEL_COST
		} else {
			break
		}
	}
}

// 	if mu.window(ctx, "State", {20, 20, 300, 400}, opts) {
// 		mu.layout_row(ctx, {60, -1}, 0)
// 		mu.label(ctx, "Metal ore:")
// 		mu.label(ctx, fmt.tprintf("%d", state.metal_ore))

// 		if state.has_reached_chassis_minimums {
// 			mu.label(ctx, "Chassis:")
// 			mu.label(ctx, fmt.tprintf("%d", state.chassis))
// 		}

// 		if state.has_reached_battery_minimums {
// 			mu.label(ctx, "Batteries:")
// 			mu.label(ctx, fmt.tprintf("%d", state.batteries))
// 		}

// 		if state.has_reached_robot_minimums {
// 			mu.label(ctx, "Shovels:")
// 			mu.label(ctx, fmt.tprintf("%d", state.shovel_attachments))

// 			mu.layout_row(ctx, {60}, 0)
// 			mu.label(ctx, "Robots:")
// 			mu.layout_row(ctx, {60, 100, -1}, 0)
// 			for &robot, i in state.robots {
// 				mu.label(ctx, fmt.tprintf("Robot %d:", i))
// 				mu.label(ctx, .Shovel in robot.attachments ? "Shoveling ore" : "Waiting for task")

// 				if .Shovel in robot.attachments {
// 					mu.label(
// 						ctx,
// 						fmt.tprintf("Progress %3.1f%%", robot.progress_in_goal / 3 * 100),
// 					)
// 				} else {
// 					if .SUBMIT in
// 					   button(
// 						   ctx,
// 						   "Attach shovel",
// 						   mu.Id(u32(InputId.ATTACH_SHOVEL_TO_ROBOT) + 1000 + u32(i)),
// 					   ) {
// 						if state.shovel_attachments > 0 {
// 							robot.attachments += {.Shovel}
// 							state.shovel_attachments -= 1
// 						}
// 					}
// 				}
// 			}


// 		}
// 	}

button :: proc(pos: rl.Vector2, text: string, id: InputId) -> bool {
	text_width := len(text)
	spaces := space_count(text)
	button_pos := rl.Rectangle {
		x      = pos.x,
		y      = pos.y,
		width  = f32(text_width - int(spaces)) * 20 + f32(spaces) * 6 + 10,
		height = 40,
	}

	mouse_pos := rl.GetMousePosition()
	mouse_over := rl.CheckCollisionPointRec(mouse_pos, button_pos)
	mouse_down := rl.IsMouseButtonDown(rl.MouseButton.LEFT)
	mouse_pressed := rl.IsMouseButtonPressed(rl.MouseButton.LEFT)
	is_focused: bool

	switch focused in state.focus {
	case nil:
		is_focused = false
	case FocusState:
		is_focused = focused.id == id
	}

	if !is_focused && mouse_over && mouse_pressed {
		state.focus = FocusState {
			id = id,
		}
	}

	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 200, // Rectangle top-left corner position x
				y      = 300, // Rectangle top-left corner position y
				width  = 100, // Rectangle width
				height = 100, // Rectangle height
			}, // Texture source rectangle
			left = 4, // Left border offset
			top = 8, // Top border offset
			right = 4, // Right border offset
			bottom = 8, // Bottom border offset
			layout = rl.NPatchLayout.NINE_PATCH, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		button_pos,
		{0, 0},
		0,
		mouse_over \
		? EXTRA_LIGHT_ORANGE \
		: mouse_over && mouse_pressed ? rl.ORANGE : is_focused ? LIGHT_ORANGE : rl.WHITE,
	)

	txt := strings.clone_to_cstring(text)
	defer delete_cstring(txt)

	rl.DrawTextEx(
		state.ui_font,
		txt,
		{pos.x + 8, pos.y + 4},
		32,
		0,
		mouse_over && mouse_down ? rl.ORANGE : rl.WHITE,
	)

	return mouse_over && mouse_pressed
}


space_count :: proc(str: string) -> uint {
	count: uint = 0

	for char in str {
		if char == ' ' {
			count += 1
		}
	}

	return count
}


input_uint :: proc(pos: rl.Vector2, width: f32, value: ^uint, id: InputId) {
	input_pos := rl.Rectangle {
		x      = pos.x,
		y      = pos.y,
		width  = width,
		height = 40,
	}
	input_border_pos := rl.Rectangle {
		x      = pos.x - 8,
		y      = pos.y - 8,
		width  = width + 16,
		height = 56,
	}

	mouse_pos := rl.GetMousePosition()
	mouse_over := rl.CheckCollisionPointRec(mouse_pos, input_border_pos)
	mouse_down := rl.IsMouseButtonDown(rl.MouseButton.LEFT)
	mouse_pressed := rl.IsMouseButtonPressed(rl.MouseButton.LEFT)
	is_focused: bool
	focus: ^FocusState

	switch &focused in state.focus {
	case nil:
		is_focused = false
	case FocusState:
		is_focused = focused.id == id
		focus = &focused
	}

	if is_focused {
		key_pressed := rl.GetKeyPressed()

		for key_pressed != nil {
			#partial switch key_pressed {
			case rl.KeyboardKey.UP:
				value^ += 1
			case rl.KeyboardKey.DOWN:
				value^ = max(value^ - 1, 0)
			}

			key_pressed = rl.GetKeyPressed()
		}
	} else if mouse_over && mouse_pressed {
		state.focus = FocusState {
			id = id,
		}
	}

	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 200, // Rectangle top-left corner position x
				y      = 200, // Rectangle top-left corner position y
				width  = 100, // Rectangle width
				height = 100, // Rectangle height
			}, // Texture source rectangle
			left = 10, // Left border offset
			top = 10, // Top border offset
			right = 10, // Right border offset
			bottom = 10, // Bottom border offset
			layout = rl.NPatchLayout.NINE_PATCH, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		input_border_pos,
		{0, 0},
		0,
		mouse_over \
		? EXTRA_LIGHT_ORANGE \
		: mouse_over && mouse_pressed ? rl.ORANGE : is_focused ? LIGHT_ORANGE : rl.WHITE,
	)

	rl.DrawTextureNPatch(
		state.ui_atlas,
		{
			source = {
				x      = 0, // Rectangle top-left corner position x
				y      = 0, // Rectangle top-left corner position y
				width  = 100, // Rectangle width
				height = 100, // Rectangle height
			}, // Texture source rectangle
			left = 4, // Left border offset
			top = 4, // Top border offset
			right = 4, // Right border offset
			bottom = 4, // Bottom border offset
			layout = rl.NPatchLayout.NINE_PATCH, // Layout of the n-patch: 3x3, 1x3 or 3x1
		},
		input_pos,
		{0, 0},
		0,
		rl.WHITE,
	)


	val_buf: [256]u8
	val_str := strconv.itoa(val_buf[:], int(value^))
	txt := strings.clone_to_cstring(val_str)
	defer delete_cstring(txt)

	rl.DrawTextEx(state.ui_font, txt, {pos.x + 8, pos.y + 4}, 32, 0, rl.WHITE)
}

LIGHT_ORANGE := rl.Color{255, 191, 30, 255}
EXTRA_LIGHT_ORANGE := rl.Color{255, 221, 60, 255}
