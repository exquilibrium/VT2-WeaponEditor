--[[
	Weapon editor: turns the current edits into Lua for the weapon change files.

	(Examples assume a registration with label "MB", prefix "mb_", profiles in NewDamageProfileTemplates.)

	- Weapons edits             one assignment per field, "-- official: X" (plus "prev MB: Y"
	                            when the balance mod had already changed it)
	- balance mod's profiles    the whole NewDamageProfileTemplates.mb_x = { ... } block,
	                            re-printed to replace the existing one. Preset names that are
	                            still untouched stay names, every field that differs from the
	                            vanilla profile it replaced gets a "-- official:" comment
	- vanilla profiles          one assignment per field, or the whole sub-table where the
	                            editor copied a shared preset (a leaf assignment there would
	                            change the preset for every other weapon too)
	- ExplosionTemplates /      one section per entry, same line style as Weapons; explosion
	  SpreadTemplates           sections note weapons still firing their own copy

	Structural edits print as a whole table (added field, rewritten array), "= nil"
	(removed field) or "= ExplosionTemplates.x" (a weapon's copy linked to the global).

	Notes print as "-- note:" lines above what they belong to. export.patch_notes (bottom) turns
	the same edits and notes into a markdown patch-note draft.
]]

local core = require("scripts/mods/WeaponEditor/we_core")

local export = {}

local MAX_LISTED_USERS = 6

local function key_text(key, in_sequence)
	if in_sequence then
		return ""
	elseif type(key) == "number" then
		return "[" .. key .. "] = "
	elseif key:match("^[%a_][%w_]*$") then
		return key .. " = "
	end

	return string.format("[%q] = ", key)
end

local function key_label(key)
	return type(key) == "number" and ("[" .. key .. "]") or tostring(key)
end

-- vanilla_node: the matching vanilla table, or false when there is nothing to compare against
local function leaf_comment(value, vanilla_node, key)
	if vanilla_node == false then
		return ""
	end

	local vanilla_value = vanilla_node[key]

	if type(vanilla_value) == "table" then
		return " -- official: <table>"
	elseif core.values_equal(value, vanilla_value) then
		return ""
	end

	return " -- official: " .. core.format_value(vanilla_value)
end

local function preset_comment(ctx, preset_name, live_preset, vanilla_node, key)
	if vanilla_node == false then
		return ""
	end

	local vanilla_value = vanilla_node[key]

	if vanilla_value == nil then
		return " -- official: none"
	elseif type(vanilla_value) ~= "table" then
		return " -- official: " .. core.format_value(vanilla_value)
	elseif core.deep_equal(live_preset, vanilla_value) then
		return ""
	end

	local vanilla_preset = ctx.vanilla_preset_names[vanilla_value]

	if vanilla_preset == preset_name then
		return " -- preset values changed since official"
	elseif vanilla_preset then
		return string.format(" -- official: %q", vanilla_preset)
	end

	return " -- official: inline table (differs)"
end

--[[
	Key order for exported profile blocks comes from the registered balance mod
	(export_key_order), so replacing an existing block in its files reorders as little as
	possible:
		export_key_order = {
			profile = { order = { "armor_modifier", "charge_value", ... }, unknown_before = "default_target" },
			target = { order = { ... }, unknown_before = "armor_modifier" },
		}
	Keys not listed go just before `unknown_before` (or last), A-Z among themselves. Without
	one, and for every other table, keys are A-Z.
]]

local function rank_lookup(spec)
	local ranks = {}

	for i, key in ipairs(spec.order or {}) do
		ranks[key] = i
	end

	ranks.__unknown = spec.unknown_before and ranks[spec.unknown_before] and ranks[spec.unknown_before] - 0.5 or #(spec.order or {}) + 1

	return ranks
end

-- registered settings table -> context -> ranks
local key_ranks_cache = setmetatable({}, {
	__mode = "k",
})

local function key_ranks(ctx, context)
	local settings = ctx.editor.host
	local by_context = key_ranks_cache[settings]

	if not by_context then
		by_context = {}

		for name, spec in pairs(settings.export_key_order or {}) do
			by_context[name] = rank_lookup(spec)
		end

		key_ranks_cache[settings] = by_context
	end

	return by_context[context]
end

local function ordered_keys(ctx, t, context)
	local keys = core.sorted_keys(t)
	local ranks = key_ranks(ctx, context)

	if not ranks then
		return keys
	end

	local position = {}

	for i, key in ipairs(keys) do
		position[key] = i
	end

	table.sort(keys, function (a, b)
		local rank_a = ranks[a] or ranks.__unknown
		local rank_b = ranks[b] or ranks.__unknown

		if rank_a ~= rank_b then
			return rank_a < rank_b
		end

		return position[a] < position[b]
	end)

	return keys
end

-- Which ordering a child table gets: profile -> targets -> target, default_target -> target
local function child_context(context, key)
	if key == "default_target" or (context == "targets" and type(key) == "number") then
		return "target"
	elseif key == "targets" then
		return "targets"
	end

	return "other"
end

-- Ordering for a table printed on its own, from the last key of its path
function export.context_for_keys(keys)
	local last, previous = keys[#keys], keys[#keys - 1]

	if #keys == 2 then
		return "profile"
	end

	return child_context(previous == "targets" and "targets" or "other", last)
end

--[[
	Notes (editor.set_note) print as "-- note:" comment lines above what they belong to: an entry
	note above the entry's first line, a field note above the field. Each prints once.
]]
local function print_note(ctx, path, indent)
	local note = ctx.state.notes[path]

	if not note or ctx.printed_notes[path] then
		return
	end

	ctx.printed_notes[path] = true

	for line in note.text:gmatch("[^\n]+") do
		ctx.out[#ctx.out + 1] = (indent or "") .. "-- note: " .. line
	end
end

-- The notes of every table on the way down to keys (entry, action, sub-action...) and of keys
-- itself
local function print_notes_above(ctx, keys, indent)
	for last_index = 2, #keys do
		print_note(ctx, core.format_path(keys, nil, last_index), indent)
	end
end

-- keys: the path of `live`, for the notes of the fields inside it (nil: no notes)
local function print_table(ctx, authored, live, vanilla_node, indent, context, keys)
	local out = ctx.out
	local in_sequence = core.is_sequence(live)

	for _, key in ipairs(ordered_keys(ctx, live, context)) do
		local authored_value = type(authored) == "table" and authored[key] or nil
		local live_value = live[key]
		local child_keys = keys and core.append_key(keys, key)
		local skip = false

		-- _damage_profile_setup.lua adds an empty targets table to profiles that don't author one
		if type(authored) == "table" and authored_value == nil and type(live_value) == "table" and next(live_value) == nil then
			skip = true
		end

		-- The game stamps name = <its own key> onto profiles; never export it. A copied name makes
		-- the block claim to be another profile, which crashes the game (network lookup).
		if context == "profile" and key == "name" then
			skip = true
		end

		if not skip then
			local prefix = indent .. key_text(key, in_sequence)

			if child_keys then
				print_note(ctx, core.format_path(child_keys), indent)
			end

			if type(live_value) == "table" then
				if type(authored_value) == "string" and live_value == PowerLevelTemplates[authored_value] then
					-- Still the untouched shared preset: keep referencing it by name
					out[#out + 1] = prefix .. string.format("%q", authored_value) .. "," .. preset_comment(ctx, authored_value, live_value, vanilla_node, key)
				else
					local vanilla_child = false
					local open = prefix .. "{"

					if vanilla_node ~= false then
						local vanilla_value = vanilla_node[key]

						if type(vanilla_value) == "table" then
							vanilla_child = vanilla_value
						else
							open = open .. " -- official: " .. core.format_value(vanilla_value)
						end
					end

					out[#out + 1] = open

					print_table(ctx, type(authored_value) == "table" and authored_value or nil, live_value, vanilla_child, indent .. "\t", child_context(context, key), child_keys)

					out[#out + 1] = indent .. "},"
				end
			elseif type(live_value) ~= "function" and type(live_value) ~= "userdata" then
				out[#out + 1] = prefix .. core.format_value(live_value) .. "," .. leaf_comment(live_value, vanilla_node, key)
			end
		end
	end

	if vanilla_node then
		for _, key in ipairs(core.sorted_keys(vanilla_node)) do
			-- damage_profile_templates.lua stamps name onto every vanilla profile at load
			local stamped = key == "name" and type(vanilla_node[key]) == "string"

			if live[key] == nil and not stamped then
				local vanilla_value = vanilla_node[key]

				out[#out + 1] = indent .. "-- removed: " .. key_label(key) .. " (official: " .. (type(vanilla_value) == "table" and "<table>" or core.format_value(vanilla_value)) .. ")"
			end
		end
	end
end

local function vanilla_comment(ctx, keys, value, baseline)
	local vanilla_value = core.snapshot_value(ctx.state.vanilla, keys)
	local parts = { "official: " .. core.format_value(vanilla_value) }

	if not core.values_equal(baseline, vanilla_value) then
		parts[#parts + 1] = "prev " .. ctx.editor.baseline_label() .. ": " .. core.format_value(baseline)
	end

	return " -- " .. table.concat(parts, ", ")
end

local function sorted_edits(edits)
	table.sort(edits, function (a, b)
		return a.path < b.path
	end)

	return edits
end

local function short_value(value)
	return type(value) == "table" and "<table>" or core.format_value(value)
end

-- One edit as Lua, for every kind (see we_core.lua): a leaf assignment, a whole table,
-- a removal (= nil) or a link to a global table
local function print_edit(ctx, edit)
	local out = ctx.out
	local kind = edit.kind or "value"
	local vanilla_value = core.snapshot_value(ctx.state.vanilla, edit.keys)

	if kind == "value" then
		out[#out + 1] = edit.path .. " = " .. core.format_value(edit.value) .. vanilla_comment(ctx, edit.keys, edit.value, edit.baseline)
	elseif kind == "removed" then
		out[#out + 1] = edit.path .. " = nil -- official: " .. short_value(vanilla_value)
	elseif kind == "ref" then
		out[#out + 1] = edit.path .. " = " .. edit.ref .. " -- official: " .. (vanilla_value == nil and "none" or "the weapon's own copy")
	elseif kind == "table" then
		local live_table = core.live_value(edit.keys)
		local open = edit.path .. " = {"

		if type(vanilla_value) ~= "table" then
			open = open .. " -- official: " .. core.format_value(vanilla_value)
		end

		out[#out + 1] = open

		if type(live_table) == "table" then
			print_table(ctx, nil, live_table, type(vanilla_value) == "table" and vanilla_value or false, "\t", export.context_for_keys(edit.keys), edit.keys)
		end

		out[#out + 1] = "}"
	end
end

local function print_global_section(ctx, root, name, edits)
	local out = ctx.out

	out[#out + 1] = ""
	out[#out + 1] = "-- " .. root .. "." .. name

	if root == "ExplosionTemplates" then
		for _, copy_keys in ipairs(ctx.editor.embedded_explosion_copies(name)) do
			local copy_path = core.format_path(copy_keys)

			out[#out + 1] = "-- note: " .. copy_path .. " is the weapon's own copy - its immediate blast ignores these lines unless linked:"
			out[#out + 1] = "-- " .. copy_path .. " = ExplosionTemplates." .. name
		end
	end

	for _, edit in ipairs(sorted_edits(edits)) do
		print_notes_above(ctx, edit.keys)
		print_edit(ctx, edit)
	end
end

-- The attacks using a profile, each with its weapon's and its own note (a change made through
-- the profile is often explained on the attack)
local function print_users(ctx, users)
	local out = ctx.out

	for i, user in ipairs(users) do
		if i > MAX_LISTED_USERS then
			out[#out + 1] = string.format("-- ...and %d more", #users - MAX_LISTED_USERS)

			break
		end

		out[#out + 1] = "-- used by " .. core.format_path(user.keys)

		-- user.keys end at the damage_profile field: the weapon and the sub-action above it
		print_note(ctx, core.format_path(user.keys, nil, 2))
		print_note(ctx, core.format_path(user.keys, nil, #user.keys - 1))
	end
end

local function print_session_changes(ctx, edits)
	local out = ctx.out

	for _, edit in ipairs(edits) do
		out[#out + 1] = string.format("-- changed: %s %s -> %s", core.format_relative(edit.keys, 3), short_value(edit.baseline), core.describe_edit(edit))
	end
end

local function print_weapon_section(ctx, template_name, edits)
	local out = ctx.out

	out[#out + 1] = ""
	out[#out + 1] = "-- " .. template_name

	for _, edit in ipairs(sorted_edits(edits)) do
		print_notes_above(ctx, edit.keys)
		print_edit(ctx, edit)
	end
end

local function vanilla_counterparts(ctx, profile_name, users)
	if ctx.state.vanilla.DamageProfileTemplates[profile_name] then
		return { profile_name }
	end

	local names, seen = {}, {}

	for _, user in ipairs(users) do
		local name = user.vanilla_profile

		if type(name) == "string" and name ~= profile_name and not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end

	table.sort(names)

	return names
end

-- A whole profile block: the balance mod's own profiles (replacing their existing block) and
-- forks (a new block). Written into its authored profiles table (e.g. NewDamageProfileTemplates),
-- or straight into DamageProfileTemplates when it has none.
local function print_profile_block_section(ctx, profile_name, edits)
	local out = ctx.out
	local users = ctx.editor.profile_users(profile_name)
	local counterparts = vanilla_counterparts(ctx, profile_name, users)
	local counterpart = counterparts[1]
	local vanilla_root = counterpart and ctx.state.vanilla.DamageProfileTemplates[counterpart] or false
	local authored_profiles = ctx.editor.authored_profiles()
	local block_global = authored_profiles and ctx.editor.host.authored_profiles_global or "DamageProfileTemplates"
	local header = block_global .. "." .. profile_name .. " = {"

	if counterpart then
		header = header .. " -- official: " .. counterpart

		if #counterparts > 1 then
			header = header .. " (comments compare against it; also replaces " .. table.concat(counterparts, ", ", 2) .. ")"
		end
	else
		header = header .. " -- official: none (new profile)"
	end

	local fork = ctx.state.forks and ctx.state.forks[profile_name]

	out[#out + 1] = ""

	if fork then
		out[#out + 1] = string.format("-- %s: new profile (forked from %s), add this block", profile_name, fork.source)

		if not authored_profiles then
			out[#out + 1] = "-- also register it in NetworkLookup.damage_profiles (hits send profiles by lookup id)"
		end
	else
		out[#out + 1] = "-- " .. profile_name .. ": replaces the existing block"
	end

	print_note(ctx, core.format_path({ "DamageProfileTemplates", profile_name }))
	print_users(ctx, users)
	print_session_changes(ctx, sorted_edits(edits))

	out[#out + 1] = header

	print_table(ctx, authored_profiles and authored_profiles[profile_name], DamageProfileTemplates[profile_name], vanilla_root, "\t", "profile", { "DamageProfileTemplates", profile_name })

	out[#out + 1] = "}"
end

local function print_vanilla_profile_section(ctx, profile_name, edits)
	local out = ctx.out
	local state = ctx.state
	local emitted_copies = {}

	out[#out + 1] = ""
	out[#out + 1] = "-- " .. profile_name

	print_note(ctx, core.format_path({ "DamageProfileTemplates", profile_name }))
	print_users(ctx, ctx.editor.profile_users(profile_name))

	for _, edit in ipairs(sorted_edits(edits)) do
		-- Shortest copied prefix above a value edit, if the editor copied a shared preset.
		-- Structural edits already print their whole table (or = nil) themselves.
		local copy_path, copy_record = nil, nil

		if (edit.kind or "value") == "value" then
			for cow_path, record in pairs(state.cow) do
				if core.path_is_under(edit.path, cow_path) and edit.path ~= cow_path and (not copy_path or #cow_path < #copy_path) then
					copy_path, copy_record = cow_path, record
				end
			end
		end

		if copy_path then
			if not emitted_copies[copy_path] then
				emitted_copies[copy_path] = true

				local live_table = core.live_value(copy_record.keys)
				local vanilla_table = core.snapshot_value(state.vanilla, copy_record.keys)
				local shared_name = ctx.editor.preset_name(copy_record.original)
				local open = copy_path .. " = {"

				if shared_name then
					open = open .. " -- was shared preset " .. shared_name
				end

				out[#out + 1] = open

				print_table(ctx, nil, live_table, type(vanilla_table) == "table" and vanilla_table or false, "\t", export.context_for_keys(copy_record.keys), copy_record.keys)

				out[#out + 1] = "}"
			end
		else
			print_notes_above(ctx, edit.keys)
			print_edit(ctx, edit)
		end
	end
end

-- Returns the export text and how many edits it covers
function export.build(editor)
	local state = editor.state
	local ctx = {
		editor = editor,
		state = state,
		out = {},
		vanilla_preset_names = {},
		printed_notes = {}, -- note path -> true once printed (print_note)
	}

	for name, preset in pairs(state.vanilla.PowerLevelTemplates or {}) do
		if type(preset) == "table" then
			ctx.vanilla_preset_names[preset] = name
		end
	end

	local weapon_edits, profile_edits = {}, {}
	local global_edits = {} -- root -> entry name -> edits, for ExplosionTemplates/SpreadTemplates
	local count = 0

	for path, edit in pairs(state.edits) do
		local root = edit.keys[1]
		local bucket

		if root == "Weapons" then
			bucket = weapon_edits
		elseif root == "DamageProfileTemplates" then
			bucket = profile_edits
		else
			global_edits[root] = global_edits[root] or {}
			bucket = global_edits[root]
		end

		local name = edit.keys[2]

		bucket[name] = bucket[name] or {}
		bucket[name][#bucket[name] + 1] = {
			path = path,
			keys = edit.keys,
			kind = edit.kind,
			value = edit.value,
			ref = edit.ref,
			baseline = edit.baseline,
		}
		count = count + 1
	end

	local out = ctx.out

	out[#out + 1] = "-- Weapon editor export (" .. tostring(editor.host.name) .. ")"

	if state.vanilla_tainted then
		out[#out + 1] = "-- WARNING: vanilla snapshot was taken after a balance mod already changed the tables - official comments are wrong"
	end

	local template_names = table.keys(weapon_edits)

	table.sort(template_names)

	for _, template_name in ipairs(template_names) do
		print_weapon_section(ctx, template_name, weapon_edits[template_name])
	end

	local roots = table.keys(global_edits)

	table.sort(roots)

	for _, root in ipairs(roots) do
		local names = table.keys(global_edits[root])

		table.sort(names)

		for _, name in ipairs(names) do
			print_global_section(ctx, root, name, global_edits[root][name])
		end
	end

	-- Forks export as new blocks even with no edits inside them
	for fork_name in pairs(state.forks or {}) do
		profile_edits[fork_name] = profile_edits[fork_name] or {}
	end

	local profile_names = table.keys(profile_edits)

	table.sort(profile_names)

	local authored_profiles = editor.authored_profiles()

	for _, profile_name in ipairs(profile_names) do
		if (authored_profiles and authored_profiles[profile_name]) or state.forks[profile_name] then
			print_profile_block_section(ctx, profile_name, profile_edits[profile_name])
		else
			print_vanilla_profile_section(ctx, profile_name, profile_edits[profile_name])
		end
	end

	return table.concat(out, "\n"), count
end

--[[
	Patch-note draft (/we_export_notes): markdown in the style of the balance mod's patch notes
	(TourneyBalance's $BEGIN_TB ... $END_TB blocks), to tidy up and paste:

		**Halberd (es_halberd_template)**

		*the weapon's note*
		*action_one.heavy_attack_left: the attack's note*
		* action_one.heavy_attack_left: Increased damage_profile ... to X (from Y). the field's note

	"from" is the balance mod's value before the edit or, for a note whose edit already landed in
	the files, the value the note remembered. A damage profile's changes are listed under every
	weapon whose attacks use it, labelled with those attacks. Other entries get their own heading
	("**Explosion x**").
]]

local ENTRY_TITLES = {
	ExplosionTemplates = "Explosion",
	SpreadTemplates = "Spread",
	BuffTemplates = "DoT",
	DamageProfileTemplates = "Damage profile",
}

-- Weapon template -> its localized name (from the first item using it)
local function weapon_display_names()
	local names = {}
	local localize = rawget(_G, "Localize")

	if not localize then
		return names
	end

	for _, item in pairs(ItemMasterList) do
		local template = type(item) == "table" and item.template

		if type(template) == "string" and not names[template] and type(item.display_name) == "string" then
			local ok, localized = pcall(localize, item.display_name)

			-- A missing localization comes back as "<key>"
			if ok and type(localized) == "string" and localized ~= "" and not localized:find("<", 1, true) then
				names[template] = localized
			end
		end
	end

	return names
end

-- A shown value (core.format_value) as prose: strings without their quotes
local function plain(text)
	return text and (text:match('^"(.*)"$') or text) or "none"
end

local function one_line(text)
	return (text:gsub("%s*\n%s*", " "))
end

-- "Increased x to 0.6 (from 0.5)", "Changed", "Added", "Removed"
local function change_sentence(field, kind, from, to)
	if kind == "removed" then
		return string.format("Removed %s (was %s)", field, plain(from))
	elseif from == nil or from == "none" then
		return string.format("Added %s: %s", field, plain(to))
	end

	local from_number, to_number = tonumber(from), tonumber(to)
	local verb = "Changed"

	if from_number and to_number and from_number ~= to_number then
		verb = to_number > from_number and "Increased" or "Reduced"
	end

	return string.format("%s %s to %s (from %s)", verb, field, plain(to), plain(from))
end

function export.patch_notes(editor)
	local state = editor.state
	local display_names = weapon_display_names()
	local groups, group_list = {}, {}

	local function group_for(key, title, is_weapon)
		local group = groups[key]

		if not group then
			group = {
				title = title,
				is_weapon = is_weapon,
				sections = {},
				section_list = {},
			}
			groups[key] = group
			group_list[#group_list + 1] = group
		end

		return group
	end

	local function section_for(group, key, label)
		local section = group.sections[key]

		if not section then
			section = {
				label = label,
				bullets = {},
			}
			group.sections[key] = section
			group.section_list[#group.section_list + 1] = section
		end

		return section
	end

	local function weapon_group(template_name)
		return group_for("Weapons." .. template_name, string.format("%s (%s)", display_names[template_name] or template_name, template_name), true)
	end

	-- Where something at keys is listed: { section, field (relative label) }, one place per weapon
	-- for a damage profile used by several. The group of a place is reachable as place.group.
	local function places(keys)
		local root, name = keys[1], keys[2]

		if root == "Weapons" then
			local group = weapon_group(name)

			if keys[3] == "actions" and #keys >= 5 then
				local label = tostring(keys[4]) .. "." .. tostring(keys[5])

				return {
					{ group = group, section = section_for(group, label, label), field = core.format_relative(keys, 6) },
				}
			end

			return {
				{ group = group, section = section_for(group, "", ""), field = core.format_relative(keys, 3) },
			}
		end

		local field = core.format_relative(keys, 3)

		if root == "DamageProfileTemplates" then
			-- template -> the attacks of that weapon using the profile
			local attacks, templates = {}, {}

			for _, user in ipairs(editor.profile_users(name)) do
				local template = user.keys[2]
				local label = tostring(user.keys[4]) .. "." .. tostring(user.keys[5])

				if not attacks[template] then
					attacks[template] = {}
					templates[#templates + 1] = template
				end

				if not table.find(attacks[template], label) then
					table.insert(attacks[template], label)
				end
			end

			if #templates > 0 then
				local result = {}

				table.sort(templates)

				for _, template in ipairs(templates) do
					local group = weapon_group(template)

					table.sort(attacks[template])

					result[#result + 1] = {
						group = group,
						section = section_for(group, "profile:" .. name, table.concat(attacks[template], ", ")),
						field = field,
					}
				end

				return result
			end
		end

		local group = group_for(root .. "." .. tostring(name), string.format("%s %s", ENTRY_TITLES[root] or root, tostring(name)), false)

		return {
			{ group = group, section = section_for(group, "", ""), field = field },
		}
	end

	local function add_change(keys, kind, from, to, note)
		for _, place in ipairs(places(keys)) do
			local field = place.field ~= "" and place.field or tostring(keys[#keys])
			local bullet = change_sentence(field, kind, from, to)

			if note then
				bullet = bullet .. ". " .. one_line(note.text)
			end

			table.insert(place.section.bullets, bullet)
		end
	end

	-- Changes: every edit, and every field note whose edit already landed
	for path, edit in pairs(state.edits) do
		local kind = edit.kind or "value"
		local to = kind == "value" and core.format_value(edit.value) or core.describe_edit(edit)

		add_change(edit.keys, kind, core.format_value(edit.baseline), to, state.notes[path])
	end

	for path, note in pairs(state.notes) do
		if not state.edits[path] then
			local keys = core.parse_path(path)

			if note.from then
				local live = core.live_value(keys)

				add_change(keys, live == nil and "removed" or "value", note.from, core.format_value(live), note)
			else
				-- An entry note: the weapon's / entry's own goes under its heading, an attack's
				-- (or a damage profile's) at its attacks
				local is_entry = #keys == 2
				local is_attack = keys[1] == "Weapons" and keys[3] == "actions" and #keys == 5

				for _, place in ipairs(places(keys)) do
					if is_entry and (keys[1] ~= "DamageProfileTemplates" or place.section.label == "") then
						place.group.note = note.text
					elseif is_entry or is_attack then
						place.section.note = note.text
					else
						table.insert(place.section.bullets, string.format("%s: %s", place.field, one_line(note.text)))
					end
				end
			end
		end
	end

	-- Weapons first, then the other entries; A-Z within each
	table.sort(group_list, function (a, b)
		if a.is_weapon ~= b.is_weapon then
			return a.is_weapon
		end

		return a.title < b.title
	end)

	local out, count, heading = {}, 0, nil

	for _, group in ipairs(group_list) do
		local group_heading = group.is_weapon and "## Weapons" or "## Other"

		if group_heading ~= heading then
			heading = group_heading
			out[#out + 1] = heading
		end

		out[#out + 1] = "**" .. group.title .. "**"
		out[#out + 1] = ""

		if group.note then
			out[#out + 1] = "*" .. one_line(group.note) .. "*"
			count = count + 1
		end

		table.sort(group.section_list, function (a, b)
			return a.label < b.label
		end)

		for _, section in ipairs(group.section_list) do
			local prefix = section.label ~= "" and (section.label .. ": ") or ""

			if section.note then
				out[#out + 1] = "*" .. prefix .. one_line(section.note) .. "*"
				count = count + 1
			end

			table.sort(section.bullets)

			for _, bullet in ipairs(section.bullets) do
				out[#out + 1] = "* " .. prefix .. bullet
				count = count + 1
			end
		end

		out[#out + 1] = ""
	end

	return table.concat(out, "\n"), count
end

return export
