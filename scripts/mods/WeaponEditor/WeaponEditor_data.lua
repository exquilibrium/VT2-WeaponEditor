local mod = get_mod("WeaponEditor")

return {
	name = "Weapon Editor",
	description = mod:localize("mod_description"),
	-- Not togglable: switching it off mid-session would leave live edits, hooks and a captured
	-- cursor behind. Disable it in the launcher instead.
	is_togglable = false,
	options = {
		widgets = {
			-- Same as /we, on F2 by default (F3 switches between using the window and playing).
			-- Global: also works with a menu open (the editor captures input itself).
			{
				setting_id = "toggle_window_keybind",
				type = "keybind",
				tooltip = "toggle_window_keybind_description",
				default_value = { "F2" },
				keybind_global = true,
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "toggle_window",
			},
		},
	},
}
