local mod = get_mod("WeaponEditor")

--[[
	Weapon editor: in-game Imgui tool for tuning weapons of a balance mod and exporting the
	changes as Lua. Everything lives in we_main.lua (state, edits, commands) and the we_* modules
	it requires; see README.md for how to use it and how a balance mod registers itself.
]]

mod:dofile("scripts/mods/WeaponEditor/we_main")
