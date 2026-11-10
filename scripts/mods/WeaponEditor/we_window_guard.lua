--[[
	Window guard: keeps the editor's Imgui windows inside the game window, MARGIN pixels from its
	edges, both when moved and when resized.

	The game's Imgui has external viewports: a window that leaves the game window - or only
	touches its edge - becomes an OS window of its own, which breaks the game window (an engine
	bug). Imgui decides that inside begin_window, from the position and size the window has at
	that moment, so both must already be inside by then:
	  - Size: resizing happens inside begin_window, after that check. The guard reads the size
	    right after begin_window and shrinks it (set_window_size) before the next frame checks.
	  - Position: a drag moves the window in Imgui's new frame, before any Lua runs, so the guard
	    predicts it. A press on the window may drag it; while it does, the window follows the
	    mouse delta, and a predicted position past the margin is pulled back with
	    set_next_window_pos (applied before the check). A press that turns out to work a widget
	    instead (the window doesn't follow the mouse) stops the prediction.
	  - Opening: on a window's first frame Imgui would place it where imgui.ini says, which may be
	    outside. The guard places it itself: where it last was (saved in the mod settings,
	    relative to the game window) or at its default, fitted to the game window.

	Positions are Imgui coordinates, which are desktop coordinates with external viewports. The
	game window's corner comes from the main menu bar, which Imgui always places there - drawn
	every frame, empty and fully transparent. Its height comes from the game's resolution.

	Not covered: tooltips, combo dropdowns and other popups, which Imgui places itself.
]]

local guard = {}

guard.MARGIN = 10

-- Below this height a window is taken as collapsed (title bar only): its size isn't saved or
-- shrunk, which would also shrink it once expanded
local COLLAPSED_HEIGHT = 40
local SETTING_PREFIX = "window_"

local mod = nil
local frame = 0
-- The game window this frame: { x, y, w, h } in Imgui coordinates, or nil when unknown (the
-- guard then does nothing but resets)
local bounds = nil
-- Window name -> its guard state
local windows = {}

function guard.init(owner_mod)
	mod = owner_mod
end

local function window_state(name)
	local s = windows[name]

	if not s then
		local saved = mod and mod:get(SETTING_PREFIX .. name)
		local x, y, w, h = nil, nil, nil, nil

		if type(saved) == "string" then
			x, y, w, h = saved:match("^(%S+) (%S+) (%S+) (%S+)$")
		end

		s = {
			saved = x and {
				x = tonumber(x),
				y = tonumber(y),
				w = tonumber(w),
				h = tonumber(h),
			} or nil,
		}
		windows[name] = s
	end

	return s
end

local function measure_bounds()
	if not Imgui.begin_main_menu_bar() then
		return nil
	end

	local x, y = Imgui.get_window_pos()
	local w = Imgui.get_window_size()

	Imgui.end_main_menu_bar()

	local lookup = rawget(_G, "RESOLUTION_LOOKUP")
	local res_w = lookup and lookup.res_w
	local res_h = lookup and lookup.res_h

	if not (x and y and w and w > 0 and res_w and res_w > 0 and res_h and res_h > 0) then
		return nil
	end

	-- The bar spans the game window's width; its height in Imgui units is the resolution's,
	-- scaled the same way
	return {
		x = x,
		y = y,
		w = w,
		h = res_h * w / res_w,
	}
end

-- Once per frame, before any guarded window
function guard.update_bounds()
	frame = frame + 1

	Imgui.push_style_color(Imgui.COLOR_MENU_BAR_BG, 0, 0, 0, 0)
	Imgui.push_style_color(Imgui.COLOR_WINDOW_BG, 0, 0, 0, 0)
	Imgui.push_style_color(Imgui.COLOR_BORDER, 0, 0, 0, 0)
	Imgui.push_style_color(Imgui.COLOR_BORDER_SHADOW, 0, 0, 0, 0)

	local ok, result = pcall(measure_bounds)

	Imgui.pop_style_color(4)

	bounds = ok and result or nil
end

-- The game window's top-left in Imgui coordinates (0, 0 when unknown)
function guard.origin()
	return bounds and bounds.x or 0, bounds and bounds.y or 0
end

-- One axis of a window kept within [low, high]. A size that changed since last frame is a
-- resize, so the moving edge stops at the limit; otherwise the whole window moves back.
local function fit_axis(pos, size, last_size, low, high)
	local resizing = last_size ~= nil and math.abs(size - last_size) > 0.5

	size = math.min(size, high - low)

	if pos < low then
		if resizing then
			size = size - (low - pos)
		end

		pos = low
	end

	if pos + size > high then
		if resizing then
			size = high - pos
		else
			pos = high - size
		end
	end

	return pos, size
end

guard.fit_axis = fit_axis

local function limits()
	local margin = guard.MARGIN

	return bounds.x + margin, bounds.x + bounds.w - margin, bounds.y + margin, bounds.y + bounds.h - margin
end

-- Remembers where a window is, relative to the game window, once nothing is held
local function save(name, s, x, y, w, h, collapsed)
	local saved = s.saved
	local place = {
		x = x - bounds.x,
		y = y - bounds.y,
		w = collapsed and saved and saved.w or w,
		h = collapsed and saved and saved.h or (not collapsed and h) or nil,
	}

	if saved and math.abs(saved.x - place.x) < 0.5 and math.abs(saved.y - place.y) < 0.5 and math.abs((saved.w or 0) - place.w) < 0.5 and math.abs((saved.h or 0) - (place.h or 0)) < 0.5 then
		return
	end

	-- Collapsed before ever being saved: no full height known yet
	if not place.h then
		return
	end

	s.saved = place

	if mod then
		mod:set(SETTING_PREFIX .. name, string.format("%.1f %.1f %.1f %.1f", place.x, place.y, place.w, place.h))
	end
end

-- Before begin_window. default = { x, y, w, h }, x and y relative to the game window's corner.
function guard.before_begin(name, default)
	local s = window_state(name)

	if not bounds then
		-- Unguarded: a reset still places the window, relative to the desktop corner
		if s.reset then
			s.reset = nil

			Imgui.set_next_window_pos(default.x, default.y)
			Imgui.set_next_window_size(default.w, default.h)
		end

		s.drawn_frame = nil

		return
	end

	local low_x, high_x, low_y, high_y = limits()

	s.forced = false
	s.mouse_moved = false

	if s.drawn_frame ~= frame - 1 or s.reset then
		local place = not s.reset and s.saved or default
		local x, w = fit_axis(bounds.x + place.x, place.w or default.w, nil, low_x, high_x)
		local y, h = fit_axis(bounds.y + place.y, place.h or default.h, nil, low_y, high_y)

		s.reset = nil
		s.press = false
		s.pending_x, s.pending_y = nil, nil
		s.forced = true

		Imgui.set_next_window_pos(x, y)
		Imgui.set_next_window_size(w, h)

		return
	end

	local next_x, next_y = s.pending_x, s.pending_y

	s.pending_x, s.pending_y = nil, nil

	if Imgui.is_mouse_clicked(0) then
		-- moves: nil until a frame shows whether the press drags the window
		s.press = s.hovered
		s.moves = nil
		s.drag_x, s.drag_y = s.x, s.y
	elseif s.press and Imgui.is_mouse_dragging(0, 0) then
		local dx, dy = Imgui.get_mouse_delta()

		s.mouse_moved = dx ~= 0 or dy ~= 0
		s.drag_x, s.drag_y = s.drag_x + dx, s.drag_y + dy

		if s.moves ~= false then
			-- Same size as last frame: a move, so the whole window is kept in
			local x = fit_axis(s.drag_x, s.w, s.w, low_x, high_x)
			local y = fit_axis(s.drag_y, s.h, s.h, low_y, high_y)

			if x ~= s.drag_x or y ~= s.drag_y then
				next_x, next_y = x, y
			end
		end
	else
		s.press = false
	end

	if next_x then
		s.forced = true

		Imgui.set_next_window_pos(next_x, next_y)
	end
end

-- Right after begin_window, inside the window
function guard.after_begin(name)
	local s = window_state(name)

	if not bounds then
		return
	end

	local x, y = Imgui.get_window_pos()
	local w, h = Imgui.get_window_size()

	if not (x and y and w and h) then
		return
	end

	s.hovered = Imgui.is_window_hovered()

	-- Did the press drag the window? Only tellable in a frame the guard didn't place it
	if s.press and s.moves == nil and not s.forced and s.x then
		if x ~= s.x or y ~= s.y then
			s.moves = true
		elseif s.mouse_moved then
			s.moves = false
		end
	end

	local low_x, high_x, low_y, high_y = limits()
	local collapsed = h < COLLAPSED_HEIGHT
	local fitted_x, fitted_w = fit_axis(x, w, s.w, low_x, high_x)
	local fitted_y, fitted_h = fit_axis(y, h, collapsed and h or s.h, low_y, high_y)

	if not collapsed and (fitted_w ~= w or fitted_h ~= h) then
		Imgui.set_window_size(fitted_w, fitted_h)
	end

	if fitted_x ~= x or fitted_y ~= y then
		s.pending_x, s.pending_y = fitted_x, fitted_y
	end

	-- Where the window is next frame unless dragged: the drag prediction starts from here
	s.x, s.y = fitted_x, fitted_y
	s.w, s.h = collapsed and w or fitted_w, collapsed and h or fitted_h
	s.drawn_frame = frame

	if not Imgui.is_mouse_dragging(0, 0) then
		save(name, s, fitted_x, fitted_y, fitted_w, fitted_h, collapsed)
	end
end

-- The editor closed Imgui: every window counts as opening the next time it's drawn (frames
-- only count while the editor is open, so this can't be told from them)
function guard.on_closed()
	for _, s in pairs(windows) do
		s.drawn_frame = nil
	end
end

-- /we_reset_windows: back to the default place and size the next time it's drawn
function guard.reset(name)
	local s = window_state(name)

	s.reset = true
	s.saved = nil

	if mod then
		mod:set(SETTING_PREFIX .. name, "")
	end
end

return guard
