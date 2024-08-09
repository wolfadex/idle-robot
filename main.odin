package main

import "core:fmt"
import "core:log"
import math "core:math/big"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import mu "vendor:microui"
import rl "vendor:raylib"

state := struct {
	mu_ctx:                       mu.Context,
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
	ui_font:                      rl.Font,
	// UI state
	focused_input:                union {
		InputId,
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

	rl.InitWindow(960, 540, "More Robots!")
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
	state.ui_font = rl.LoadFontEx(
		"resources/Ui Space Pack/Fonts/kenvector_future_thin.ttf",
		32,
		{},
		62,
	)
	defer rl.UnloadFont(state.ui_font)


	ctx := &state.mu_ctx
	mu.init(ctx)

	ctx.text_width = mu.default_atlas_text_width
	ctx.text_height = mu.default_atlas_text_height

	state.robots = {}
	//
	rl.SetTargetFPS(60)
	main_loop: for !rl.WindowShouldClose() {
		// { 	// text input
		// 	text_input: [512]byte = ---
		// 	text_input_offset := 0
		// 	for text_input_offset < len(text_input) {
		// 		ch := rl.GetCharPressed()
		// 		if ch == 0 {
		// 			break
		// 		}
		// 		b, w := utf8.encode_rune(ch)
		// 		copy(text_input[text_input_offset:], b[:w])
		// 		text_input_offset += w
		// 	}
		// 	mu.input_text(ctx, string(text_input[:text_input_offset]))
		// }

		// mouse coordinates
		mouse_pos := [2]i32{rl.GetMouseX(), rl.GetMouseY()}
		mu.input_mouse_move(ctx, mouse_pos.x, mouse_pos.y)
		mu.input_scroll(ctx, 0, i32(rl.GetMouseWheelMove() * -30))

		// mouse buttons
		@(static)
		buttons_to_key := [?]struct {
			rl_button: rl.MouseButton,
			mu_button: mu.Mouse,
		}{{.LEFT, .LEFT}, {.RIGHT, .RIGHT}, {.MIDDLE, .MIDDLE}}
		for button in buttons_to_key {
			if rl.IsMouseButtonPressed(button.rl_button) {
				mu.input_mouse_down(ctx, mouse_pos.x, mouse_pos.y, button.mu_button)
			} else if rl.IsMouseButtonReleased(button.rl_button) {
				mu.input_mouse_up(ctx, mouse_pos.x, mouse_pos.y, button.mu_button)
			}

		}

		// keyboard
		@(static)
		keys_to_check := [?]struct {
			rl_key: rl.KeyboardKey,
			mu_key: mu.Key,
		} {
			{.LEFT_SHIFT, .SHIFT},
			{.RIGHT_SHIFT, .SHIFT},
			{.LEFT_CONTROL, .CTRL},
			{.RIGHT_CONTROL, .CTRL},
			{.LEFT_ALT, .ALT},
			{.RIGHT_ALT, .ALT},
			{.ENTER, .RETURN},
			{.KP_ENTER, .RETURN},
			{.BACKSPACE, .BACKSPACE},
		}
		for key in keys_to_check {
			if rl.IsKeyPressed(key.rl_key) {
				mu.input_key_down(ctx, key.mu_key)
			} else if rl.IsKeyReleased(key.rl_key) {
				mu.input_key_up(ctx, key.mu_key)
			}
		}

		game_tick()

		// mu.begin(ctx)
		// all_windows(ctx)
		// mu.end(ctx)

		render(ctx)
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

render :: proc(ctx: ^mu.Context) {
	// render_texture :: proc(rect: mu.Rect, pos: [2]i32, color: mu.Color) {
	// 	source := rl.Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	// 	position := rl.Vector2{f32(pos.x), f32(pos.y)}

	// 	rl.DrawTextureRec(state.atlas_texture, source, position, transmute(rl.Color)color)
	// }

	rl.ClearBackground(transmute(rl.Color)state.bg)

	rl.BeginDrawing()
	defer rl.EndDrawing()

	rl.BeginScissorMode(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight())
	defer rl.EndScissorMode()

	if button({50, 50}, "GATHER ORE", .GATHER_ORE_BUTTON) {
		increment_metal_ore(1)
	}

	rl.DrawTextEx(
		state.ui_font,
		fmt.ctprintf("METAL ORE: %d", state.metal_ore),
		{260, 54},
		32,
		0,
		rl.WHITE,
	)

	// if state.has_reached_chassis_minimums {
	// mu.layout_row(ctx, {60, 60, 140, -1}, 0)
	// mu.label(ctx, "Chassis")
	// uint_slider(
	// 	ctx,
	// 	&state.chassis_to_assemble,
	// 	0,
	// 	uint(state.metal_ore / CHASIS_METAL_ORE_COST),
	// 	CHASSIS_INPUT_ID,
	// )
	// mu.label(ctx, fmt.tprintf("x %d metal ore", CHASIS_METAL_ORE_COST))

	// if .SUBMIT in button(ctx, "Assemble", mu.Id(InputId.ASSEMBLE_CHASSIS_BUTTON)) {
	// 	increment_chassis(state.chassis_to_assemble)
	// }
	if button({50, 100}, "ASSEMBLE", .ASSEMBLE_CHASSIS_BUTTON) {
		increment_chassis(state.chassis_to_assemble)
	}

	input_uint({250, 100}, 100, &state.chassis_to_assemble, .CHASSIS_INPUT_NUMBER)
	// }


}

uint_slider :: proc(
	ctx: ^mu.Context,
	val: ^uint,
	lo, hi: uint,
	id: uintptr,
) -> (
	res: mu.Result_Set,
) {
	mu.push_id(ctx, id)

	@(static)
	tmp: mu.Real
	tmp = mu.Real(val^)
	res = mu.slider(ctx, &tmp, mu.Real(lo), mu.Real(hi), 0, "%.0f", {.ALIGN_CENTER})
	val^ = uint(tmp)
	mu.pop_id(ctx)
	return
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


// all_windows :: proc(ctx: ^mu.Context) {
// 	@(static)
// 	opts := mu.Options{.NO_CLOSE}

// 	if mu.window(ctx, "Actions", {340, 20, 500, 300}, opts) {
// 		mu.layout_row(ctx, {268, -1}, 0)
// 		mu.label(ctx, "")
// 		if .SUBMIT in button(ctx, "Gather ore by hand", mu.Id(InputId.GATHER_ORE_BUTTON)) {
// 			increment_metal_ore(1)
// 		}

// 		if state.has_reached_chassis_minimums {
// 			mu.layout_row(ctx, {60, 60, 140, -1}, 0)
// 			mu.label(ctx, "Chassis")
// 			uint_slider(
// 				ctx,
// 				&state.chassis_to_assemble,
// 				0,
// 				uint(state.metal_ore / CHASIS_METAL_ORE_COST),
// 				CHASSIS_INPUT_ID,
// 			)
// 			mu.label(ctx, fmt.tprintf("x %d metal ore", CHASIS_METAL_ORE_COST))

// 			if .SUBMIT in button(ctx, "Assemble", mu.Id(InputId.ASSEMBLE_CHASSIS_BUTTON)) {
// 				increment_chassis(state.chassis_to_assemble)
// 			}
// 		}

// 		if state.has_reached_battery_minimums {
// 			mu.layout_row(ctx, {60, 60, 140, -1}, 0)
// 			mu.label(ctx, "Batteries")
// 			uint_slider(
// 				ctx,
// 				&state.batteries_to_assemble,
// 				0,
// 				uint(state.metal_ore / BATTERY_METAL_ORE_COST),
// 				BATTERY_INPUT_ID,
// 			)
// 			mu.label(ctx, fmt.tprintf("x %d metal ore", BATTERY_METAL_ORE_COST))

// 			if .SUBMIT in button(ctx, "Assemble", mu.Id(InputId.ASSEMBLE_BATTERY_BUTTON)) {
// 				increment_battery(state.batteries_to_assemble)
// 			}
// 		}

// 		if state.has_reached_robot_minimums {
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
// 		}
// 	}

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

// 	// if mu.window(ctx, "Demo Window", {40, 40, 300, 450}, opts) {
// 	// 	if .ACTIVE in mu.header(ctx, "Window Info") {
// 	// 		win := mu.get_current_container(ctx)
// 	// 		mu.layout_row(ctx, {54, -1}, 0)
// 	// 		mu.label(ctx, "Position:")
// 	// 		mu.label(ctx, fmt.tprintf("%d, %d", win.rect.x, win.rect.y))
// 	// 		mu.label(ctx, "Size:")
// 	// 		mu.label(ctx, fmt.tprintf("%d, %d", win.rect.w, win.rect.h))
// 	// 	}

// 	// 	if .ACTIVE in mu.header(ctx, "Window Options") {
// 	// 		mu.layout_row(ctx, {120, 120, 120}, 0)
// 	// 		for opt in mu.Opt {
// 	// 			state := opt in opts
// 	// 			if .CHANGE in mu.checkbox(ctx, fmt.tprintf("%v", opt), &state) {
// 	// 				if state {
// 	// 					opts += {opt}
// 	// 				} else {
// 	// 					opts -= {opt}
// 	// 				}
// 	// 			}
// 	// 		}
// 	// 	}

// 	// 	if .ACTIVE in mu.header(ctx, "Test Buttons", {.EXPANDED}) {
// 	// 		mu.layout_row(ctx, {86, -110, -1})
// 	// 		mu.label(ctx, "Test buttons 1:")
// 	// 		if .SUBMIT in mu.button(ctx, "Button 1") {write_log("Pressed button 1")}
// 	// 		if .SUBMIT in mu.button(ctx, "Button 2") {write_log("Pressed button 2")}
// 	// 		mu.label(ctx, "Test buttons 2:")
// 	// 		if .SUBMIT in mu.button(ctx, "Button 3") {write_log("Pressed button 3")}
// 	// 		if .SUBMIT in mu.button(ctx, "Button 4") {write_log("Pressed button 4")}
// 	// 	}

// 	// 	if .ACTIVE in mu.header(ctx, "Tree and Text", {.EXPANDED}) {
// 	// 		mu.layout_row(ctx, {140, -1})
// 	// 		mu.layout_begin_column(ctx)
// 	// 		if .ACTIVE in mu.treenode(ctx, "Test 1") {
// 	// 			if .ACTIVE in mu.treenode(ctx, "Test 1a") {
// 	// 				mu.label(ctx, "Hello")
// 	// 				mu.label(ctx, "world")
// 	// 			}
// 	// 			if .ACTIVE in mu.treenode(ctx, "Test 1b") {
// 	// 				if .SUBMIT in mu.button(ctx, "Button 1") {write_log("Pressed button 1")}
// 	// 				if .SUBMIT in mu.button(ctx, "Button 2") {write_log("Pressed button 2")}
// 	// 			}
// 	// 		}
// 	// 		if .ACTIVE in mu.treenode(ctx, "Test 2") {
// 	// 			mu.layout_row(ctx, {53, 53})
// 	// 			if .SUBMIT in mu.button(ctx, "Button 3") {write_log("Pressed button 3")}
// 	// 			if .SUBMIT in mu.button(ctx, "Button 4") {write_log("Pressed button 4")}
// 	// 			if .SUBMIT in mu.button(ctx, "Button 5") {write_log("Pressed button 5")}
// 	// 			if .SUBMIT in mu.button(ctx, "Button 6") {write_log("Pressed button 6")}
// 	// 		}
// 	// 		if .ACTIVE in mu.treenode(ctx, "Test 3") {
// 	// 			@(static)
// 	// 			checks := [3]bool{true, false, true}
// 	// 			mu.checkbox(ctx, "Checkbox 1", &checks[0])
// 	// 			mu.checkbox(ctx, "Checkbox 2", &checks[1])
// 	// 			mu.checkbox(ctx, "Checkbox 3", &checks[2])

// 	// 		}
// 	// 		mu.layout_end_column(ctx)

// 	// 		mu.layout_begin_column(ctx)
// 	// 		mu.layout_row(ctx, {-1})
// 	// 		mu.text(
// 	// 			ctx,
// 	// 			"Lorem ipsum dolor sit amet, consectetur adipiscing " +
// 	// 			"elit. Maecenas lacinia, sem eu lacinia molestie, mi risus faucibus " +
// 	// 			"ipsum, eu varius magna felis a nulla.",
// 	// 		)
// 	// 		mu.layout_end_column(ctx)
// 	// 	}

// 	// 	if .ACTIVE in mu.header(ctx, "Background Colour", {.EXPANDED}) {
// 	// 		mu.layout_row(ctx, {-78, -1}, 68)
// 	// 		mu.layout_begin_column(ctx)
// 	// 		{
// 	// 			mu.layout_row(ctx, {46, -1}, 0)
// 	// 			mu.label(ctx, "Red:");u8_slider(ctx, &state.bg.r, 0, 255)
// 	// 			mu.label(ctx, "Green:");u8_slider(ctx, &state.bg.g, 0, 255)
// 	// 			mu.label(ctx, "Blue:");u8_slider(ctx, &state.bg.b, 0, 255)
// 	// 		}
// 	// 		mu.layout_end_column(ctx)

// 	// 		r := mu.layout_next(ctx)
// 	// 		mu.draw_rect(ctx, r, state.bg)
// 	// 		mu.draw_box(ctx, mu.expand_rect(r, 1), ctx.style.colors[.BORDER])
// 	// 		mu.draw_control_text(
// 	// 			ctx,
// 	// 			fmt.tprintf("#%02x%02x%02x", state.bg.r, state.bg.g, state.bg.b),
// 	// 			r,
// 	// 			.TEXT,
// 	// 			{.ALIGN_CENTER},
// 	// 		)
// 	// 	}
// 	// }

// 	// if mu.window(ctx, "Log Window", {350, 40, 300, 200}, opts) {
// 	// 	mu.layout_row(ctx, {-1}, -28)
// 	// 	mu.begin_panel(ctx, "Log")
// 	// 	mu.layout_row(ctx, {-1}, -1)
// 	// 	mu.text(ctx, read_log())
// 	// 	if state.log_buf_updated {
// 	// 		panel := mu.get_current_container(ctx)
// 	// 		panel.scroll.y = panel.content_size.y
// 	// 		state.log_buf_updated = false
// 	// 	}
// 	// 	mu.end_panel(ctx)

// 	// 	@(static)
// 	// 	buf: [128]byte
// 	// 	@(static)
// 	// 	buf_len: int
// 	// 	submitted := false
// 	// 	mu.layout_row(ctx, {-70, -1})
// 	// 	if .SUBMIT in mu.textbox(ctx, buf[:], &buf_len) {
// 	// 		mu.set_focus(ctx, ctx.last_id)
// 	// 		submitted = true
// 	// 	}
// 	// 	if .SUBMIT in mu.button(ctx, "Submit") {
// 	// 		submitted = true
// 	// 	}
// 	// 	if submitted {
// 	// 		write_log(string(buf[:buf_len]))
// 	// 		buf_len = 0
// 	// 	}
// 	// }

// 	// if mu.window(ctx, "Style Window", {350, 250, 300, 240}) {
// 	// 	@(static)
// 	// 	colors := [mu.Color_Type]string {
// 	// 		.TEXT         = "text",
// 	// 		.BORDER       = "border",
// 	// 		.WINDOW_BG    = "window bg",
// 	// 		.TITLE_BG     = "title bg",
// 	// 		.TITLE_TEXT   = "title text",
// 	// 		.PANEL_BG     = "panel bg",
// 	// 		.BUTTON       = "button",
// 	// 		.BUTTON_HOVER = "button hover",
// 	// 		.BUTTON_FOCUS = "button focus",
// 	// 		.BASE         = "base",
// 	// 		.BASE_HOVER   = "base hover",
// 	// 		.BASE_FOCUS   = "base focus",
// 	// 		.SCROLL_BASE  = "scroll base",
// 	// 		.SCROLL_THUMB = "scroll thumb",
// 	// 		.SELECTION_BG = "selection bg",
// 	// 	}

// 	// 	sw := i32(f32(mu.get_current_container(ctx).body.w) * 0.14)
// 	// 	mu.layout_row(ctx, {80, sw, sw, sw, sw, -1})
// 	// 	for label, col in colors {
// 	// 		mu.label(ctx, label)
// 	// 		u8_slider(ctx, &ctx.style.colors[col].r, 0, 255)
// 	// 		u8_slider(ctx, &ctx.style.colors[col].g, 0, 255)
// 	// 		u8_slider(ctx, &ctx.style.colors[col].b, 0, 255)
// 	// 		u8_slider(ctx, &ctx.style.colors[col].a, 0, 255)
// 	// 		mu.draw_rect(ctx, mu.layout_next(ctx), ctx.style.colors[col])
// 	// 	}
// 	// }
// }


// button :: proc(
// 	ctx: ^mu.Context,
// 	label: string,
// 	id: mu.Id,
// 	icon: mu.Icon = .NONE,
// 	opt: mu.Options = {mu.Opt.ALIGN_CENTER},
// ) -> (
// 	res: mu.Result_Set,
// ) {
// 	r := mu.layout_next(ctx)
// 	mu.update_control(ctx, id, r, opt)
// 	/* handle click */
// 	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id {
// 		res += {.SUBMIT}
// 	}

// 	/* draw */
// 	mu.draw_control_frame(ctx, id, r, mu.Color_Type.BUTTON, opt)
// 	if len(label) > 0 {
// 		mu.draw_control_text(ctx, label, r, mu.Color_Type.TEXT, opt)
// 	}
// 	if icon != .NONE {
// 		mu.draw_icon(ctx, icon, r, ctx.style.colors[.TEXT])
// 	}
// 	return
// }

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
	is_focused := state.focused_input == id

	if !is_focused && mouse_over && mouse_pressed {
		state.focused_input = id
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
	is_focused := state.focused_input == id

	if !is_focused && mouse_over && mouse_pressed {
		state.focused_input = id
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
