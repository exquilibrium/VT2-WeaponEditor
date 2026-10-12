local mod = get_mod("WeaponEditor")

return {
	name = "Weapon Editor",
	description = mod:localize("mod_description"),
	-- Not togglable: switching it off mid-session would leave live edits, hooks and a captured
	-- cursor behind. Disable it in the launcher instead.
	is_togglable = false,
}
