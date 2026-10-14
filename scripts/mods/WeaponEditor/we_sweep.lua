--[[
	TEMPORARY - weapon sweep, for cleaning up a balance mod's weapon change files in one go.
	Delete this file and its one require line in we_main.lua when done.

	/we_sweep_weapons drafts, for every weapon the balance mod changes, everything that differs
	from official (official -> MB, as the files load - so it refuses to run with pending edits):

		-- ======== Halberd (two_handed_halberds_template_1) ========
		$BEGIN_TB ... $END_TB block       patch notes in a block comment, "## Halberd" (the site's
		                                  weapon changes page)
		Weapons.x... = v -- official: o   the template's changed fields
		NewDamageProfileTemplates.mb_x    the balance mod's own profiles, whole blocks with official
		                                  comments (as /we_export prints them)
		DamageProfileTemplates.x... = v   official profiles it changed in place, field by field -
		                                  flagged when the field is inside a shared preset
		ExplosionTemplates.x... = v       explosion / spread / DoT entries the weapon references

	A weapon covers the damage profiles its attacks name and the entries it references. A profile
	used by several weapons prints its Lua under the first (by name) and is pointed to from the
	others; its patch notes appear under each. Not covered: what the files change through hooks,
	buffs, mod_api calls or shared locals - only the tables the editor tracks.
]]

local core = require("scripts/mods/WeaponEditor/we_core")
local export = require("scripts/mods/WeaponEditor/we_export")
local diff = require("scripts/mods/WeaponEditor/we_diff")

local sweep = {}

-- String fields naming a global entry the weapon uses
local REFERENCE_FIELDS = {
	explosion_template = "ExplosionTemplates",
	aoe_name = "ExplosionTemplates",
	default_spread_template = "SpreadTemplates",
	spread_template_override = "SpreadTemplates",
	spread_template = "SpreadTemplates",
	dot_template_name = "BuffTemplates",
}

local CATEGORY_ORDER = {
	melee = 1,
	ranged = 2,
	other = 3,
}

-- Every leaf (or whole table) at which live differs from official, below keys
local function collect_changes(live, official, keys, changes)
	local function compare(key, live_value, official_value)
		local live_type, official_type = type(live_value), type(official_value)

		if core.EXCLUDED_KEYS[key] or live_type == "function" or official_type == "function" or live_type == "userdata" or official_type == "userdata" then
			return
		end

		-- Profiles get name = <own key> stamped at load: a balance mod profile's never matches
		-- its official counterpart's
		if key == "name" and keys[1] == "DamageProfileTemplates" and #keys == 2 then
			return
		end

		local child_keys = core.append_key(keys, key)

		if live_type == "table" and official_type == "table" then
			collect_changes(live_value, official_value, child_keys, changes)
		elseif live_value == nil then
			changes[#changes + 1] = { keys = child_keys, kind = "removed", official = official_value }
		elseif live_type == "table" then
			changes[#changes + 1] = { keys = child_keys, kind = "table", live = live_value, official = official_value }
		elseif not core.values_equal(live_value, official_value) then
			changes[#changes + 1] = { keys = child_keys, kind = "value", live = live_value, official = official_value }
		end
	end

	for key, live_value in pairs(live) do
		compare(key, live_value, official[key])
	end

	for key, official_value in pairs(official) do
		if live[key] == nil then
			compare(key, nil, official_value)
		end
	end

	table.sort(changes, function (a, b)
		return core.format_path(a.keys) < core.format_path(b.keys)
	end)

	return changes
end

-- Damage profile names and referenced global entries inside t: profiles[name] = true,
-- references[root][name] = true
local function collect_references(t, profiles, references, depth)
	for key, value in pairs(t) do
		if type(key) == "string" and type(value) == "string" then
			if key:find("damage_profile", 1, true) and DamageProfileTemplates[value] then
				profiles[value] = true
			elseif REFERENCE_FIELDS[key] then
				local root = REFERENCE_FIELDS[key]

				references[root] = references[root] or {}
				references[root][value] = true
			end
		elseif type(value) == "table" and depth < 8 and not core.EXCLUDED_KEYS[key] then
			-- A weapon's own copy of an explosion still names the global it was cloned from
			if type(value.name) == "string" and (value.explosion or value.aoe) and ExplosionTemplates[value.name] then
				references.ExplosionTemplates = references.ExplosionTemplates or {}
				references.ExplosionTemplates[value.name] = true
			end

			collect_references(value, profiles, references, depth + 1)
		end
	end
end

local function weapon_category(template)
	local buff_type = template.buff_type

	if buff_type and MeleeBuffTypes[buff_type] then
		return "melee"
	elseif buff_type and RangedBuffTypes[buff_type] then
		return "ranged"
	end

	return "other"
end

-- Lua lines for changes found by collect_changes, with official comments. A change inside a
-- shared PowerLevelTemplates preset is flagged: assigning it through one profile changes them all.
local function change_lines(editor, changes, out)
	for _, change in ipairs(changes) do
		local path = core.format_path(change.keys)
		local official_text = type(change.official) == "table" and "<table>" or core.format_value(change.official)
		local parent = core.live_value(core.sub_keys(change.keys, #change.keys - 1))
		local preset = type(parent) == "table" and editor.preset_name(parent)

		if preset then
			out[#out + 1] = string.format("-- in shared preset %s: this line changes every profile using it", preset)
		end

		if change.kind == "removed" then
			out[#out + 1] = string.format("%s = nil -- official: %s", path, official_text)
		elseif change.kind == "table" then
			out[#out + 1] = string.format("%s = { -- official: %s", path, official_text)

			for _, line in ipairs(export.table_lines(editor, change.live, type(change.official) == "table" and change.official or false, change.keys, "\t")) do
				out[#out + 1] = line
			end

			out[#out + 1] = "}"
		else
			out[#out + 1] = string.format("%s = %s -- official: %s", path, core.format_value(change.live), official_text)
		end
	end
end

-- Changes into the patch-note draft, with any note written on the field
local function add_changes_to_draft(draft, changes)
	local notes = draft.editor.state.notes

	for _, change in ipairs(changes) do
		local from = type(change.official) == "table" and "<table>" or core.format_value(change.official)
		local to = nil

		if change.kind ~= "removed" then
			to = type(change.live) == "table" and "<table>" or core.format_value(change.live)
		end

		draft:add_change(change.keys, change.kind, from, to, notes[core.format_path(change.keys)])
	end
end

--[[
	Builds the sweep text. Returns text, number of weapons; or nil, reason.
]]
function sweep.build(editor)
	local state = editor.state

	if next(state.edits) then
		return nil, "There are pending edits - the sweep describes the files as loaded. Export or revert them first."
	end

	-- profile_users scans every weapon; the draft asks it for every profile change
	local users_cache = {}
	local cached_editor = setmetatable({
		profile_users = function (profile_name)
			users_cache[profile_name] = users_cache[profile_name] or editor.profile_users(profile_name)

			return users_cache[profile_name]
		end,
	}, {
		__index = editor,
	})

	local authored_profiles = editor.authored_profiles() or {}
	local display_names = export.weapon_display_names()
	local printed_profiles, printed_entries = {}, {} -- name -> the template it was printed under
	local weapons, new_templates = {}, {}

	for template_name, template in pairs(Weapons) do
		if type(template) == "table" then
			local official = state.vanilla.Weapons[template_name]

			if type(official) ~= "table" then
				new_templates[#new_templates + 1] = template_name
			else
				weapons[#weapons + 1] = {
					name = template_name,
					template = template,
					official = official,
					category = weapon_category(template),
					display_name = display_names[template_name] or template_name,
				}
			end
		end
	end

	table.sort(weapons, function (a, b)
		if a.category ~= b.category then
			return CATEGORY_ORDER[a.category] < CATEGORY_ORDER[b.category]
		end

		if a.display_name ~= b.display_name then
			return a.display_name < b.display_name
		end

		return a.name < b.name
	end)

	local out = {
		"-- Weapon sweep (" .. tostring(editor.host.name) .. "): everything that differs from official, per weapon.",
		"-- Not covered: changes made through hooks, buffs, mod_api calls or shared locals.",
	}
	local weapon_count = 0
	local category = nil

	for _, weapon in ipairs(weapons) do
		local template_keys = { "Weapons", weapon.name }
		local template_changes = collect_changes(weapon.template, weapon.official, template_keys, {})
		local profiles, references = {}, {}

		collect_references(weapon.template, profiles, references, 1)

		-- What those name in turn: an explosion's damage profile, a profile's DoT. Scanned until
		-- nothing new turns up (from snapshots: scanning adds to the tables being walked).
		local scanned = {}
		local found_new = true

		while found_new do
			found_new = false

			local tables = {}

			for profile_name in pairs(profiles) do
				tables["DamageProfileTemplates." .. profile_name] = DamageProfileTemplates[profile_name]
			end

			for root, names in pairs(references) do
				for name in pairs(names) do
					tables[root .. "." .. name] = rawget(_G, root) and rawget(_G, root)[name]
				end
			end

			for key, t in pairs(tables) do
				if not scanned[key] and type(t) == "table" then
					scanned[key] = true
					found_new = true

					collect_references(t, profiles, references, 1)
				end
			end
		end

		local profile_names = table.keys(profiles)

		table.sort(profile_names)

		-- name -> changes against its official counterpart (the profile itself when official)
		local profile_changes = {}

		for _, profile_name in ipairs(profile_names) do
			local counterpart = state.vanilla.DamageProfileTemplates[profile_name] and profile_name or diff.official_counterpart(cached_editor, profile_name)
			local official_profile = counterpart and state.vanilla.DamageProfileTemplates[counterpart]

			if official_profile then
				profile_changes[profile_name] = collect_changes(DamageProfileTemplates[profile_name], official_profile, { "DamageProfileTemplates", profile_name }, {})
			end
		end

		local entry_changes = {} -- "Root.name" -> { root, name, changes }

		for root, names in pairs(references) do
			for name in pairs(names) do
				local live_entry = rawget(_G, root)[name]
				local official_entry = state.vanilla[root] and state.vanilla[root][name]

				if type(live_entry) == "table" and type(official_entry) == "table" and (root ~= "BuffTemplates" or core.is_dot_template(name, live_entry)) then
					local changes = collect_changes(live_entry, official_entry, { root, name }, {})

					if #changes > 0 then
						entry_changes[root .. "." .. name] = {
							root = root,
							name = name,
							changes = changes,
						}
					end
				end
			end
		end

		local changed = #template_changes > 0 or next(entry_changes) ~= nil

		for _, changes in pairs(profile_changes) do
			changed = changed or #changes > 0
		end

		for _, profile_name in ipairs(profile_names) do
			changed = changed or authored_profiles[profile_name] ~= nil
		end

		if changed then
			weapon_count = weapon_count + 1

			if weapon.category ~= category then
				category = weapon.category
				out[#out + 1] = ""
				out[#out + 1] = "-- ################ " .. category .. " ################"
			end

			-- Patch notes
			local draft = export.new_patch_draft(cached_editor, weapon.name, display_names)

			add_changes_to_draft(draft, template_changes)

			for _, profile_name in ipairs(profile_names) do
				add_changes_to_draft(draft, profile_changes[profile_name] or {})
			end

			for _, entry in pairs(entry_changes) do
				add_changes_to_draft(draft, entry.changes)
			end

			local notes_text = draft:render("site")

			out[#out + 1] = ""
			out[#out + 1] = string.format("-- ======== %s (%s) ========", weapon.display_name, weapon.name)
			out[#out + 1] = ""
			out[#out + 1] = "--[["
			out[#out + 1] = "\t$BEGIN_TB"

			for line in (notes_text .. "\n"):gmatch("(.-)\n") do
				out[#out + 1] = line ~= "" and ("\t\t" .. line) or ""
			end

			out[#out + 1] = "\t$END_TB"
			out[#out + 1] = "]]"

			-- Lua: the template's own changes
			if #template_changes > 0 then
				out[#out + 1] = ""

				change_lines(cached_editor, template_changes, out)
			end

			-- Damage profiles
			for _, profile_name in ipairs(profile_names) do
				local printed_under = printed_profiles[profile_name]
				local is_authored = authored_profiles[profile_name] ~= nil
				local changes = profile_changes[profile_name] or {}

				if printed_under then
					if is_authored or #changes > 0 then
						out[#out + 1] = ""
						out[#out + 1] = string.format("-- uses %s (exported under %s)", profile_name, printed_under)
					end
				elseif is_authored then
					printed_profiles[profile_name] = weapon.name

					for _, line in ipairs(export.profile_block(cached_editor, profile_name)) do
						out[#out + 1] = line
					end
				elseif #changes > 0 then
					printed_profiles[profile_name] = weapon.name
					out[#out + 1] = ""
					out[#out + 1] = "-- " .. profile_name .. " (official profile, changed in place)"

					change_lines(cached_editor, changes, out)
				end
			end

			-- Explosions, spread, DoTs
			local entry_keys = table.keys(entry_changes)

			table.sort(entry_keys)

			for _, entry_key in ipairs(entry_keys) do
				local entry = entry_changes[entry_key]

				out[#out + 1] = ""

				if printed_entries[entry_key] then
					out[#out + 1] = string.format("-- uses %s (exported under %s)", entry_key, printed_entries[entry_key])
				else
					printed_entries[entry_key] = weapon.name
					out[#out + 1] = "-- " .. entry_key

					change_lines(cached_editor, entry.changes, out)
				end
			end
		end
	end

	if #new_templates > 0 then
		table.sort(new_templates)
		out[#out + 1] = ""
		out[#out + 1] = "-- Templates with no official counterpart (not swept): " .. table.concat(new_templates, ", ")
	end

	return table.concat(out, "\n"), weapon_count
end

-- /we_sweep_weapons. put_on_clipboard(text) -> whether it got there.
function sweep.register(mod, editor, put_on_clipboard)
	mod:command("we_sweep_weapons", "Weapon editor (temporary): patch notes and a Lua re-export of every weapon's changes from official, to the clipboard.", function ()
		local ok, text, count = pcall(sweep.build, editor)

		if not ok then
			editor.report("Weapon sweep failed: %s", tostring(text))

			return
		elseif not text then
			editor.report(count)

			return
		end

		print("[Weapon editor] ---- weapon sweep begin ----")
		print(text)
		print("[Weapon editor] ---- weapon sweep end ----")

		if put_on_clipboard(text) then
			editor.report("Weapon sweep: %d weapon(s) copied to the clipboard (also in the console log).", count)
		else
			editor.report("Weapon sweep: %d weapon(s) - clipboard unavailable, it's in the console log between the begin/end markers.", count)
		end
	end)
end

return sweep
