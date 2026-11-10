local mod = get_mod("WeaponEditor")

return {
	name = "Weapon Editor",
	description = mod:localize("mod_description"),
	-- Not togglable: switching it off mid-session would leave live edits, hooks and a captured
	-- cursor behind. Disable it in the launcher instead.
	is_togglable = false,
	options = {
		widgets = {
			-- Same as /we, on F2 by default (the next keybind switches between using the window
			-- and playing). Global: also works with a menu open (the editor captures input itself).
			{
				setting_id = "toggle_window_keybind",
				type = "keybind",
				tooltip = "toggle_window_keybind_description",
				default_value = { },
				keybind_global = true,
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "toggle_window",
			},
			-- Switches between using the windows (cursor, game input blocked) and playing, on F3
			-- by default. Global, so it also fires while the editor holds the input.
			{
				setting_id = "toggle_input_keybind",
				type = "keybind",
				tooltip = "toggle_input_keybind_description",
				default_value = { "f3" },
				keybind_global = true,
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "toggle_input",
			},
			-- Text size of both windows in percent (Imgui's window font scale)
			{
				setting_id = "font_size",
				type = "numeric",
				tooltip = "font_size_description",
				default_value = 100,
				range = { 75, 200 },
				decimals_number = 0,
			},
		},
	},
}
