--[[
	Weapon editor: what changed. The editor window (we_ui.lua) draws from these answers:
		edits       which paths are edited or have a note (has_edit_under, has_note_under)
		official    the official value of a field and whether the live value differs from it
		roll-ups    edited / differs / noted flags for whole weapon tree nodes, so a closed tree
		            still shows where changes are

	"official" in the windows means the vanilla snapshot (the game's own values). A balance mod
	profile compares against the official profile its attacks used before the balance mod.

	Everything here is derived from the edit list and the tables, which only change through
	edits, so it's cached until editor.edit_generation changes (every edit and revert bumps it).
	Tied to the editor table too: this module survives a hot reload, the editor (and its
	generation counter) doesn't.
]]

local core = require("scripts/mods/WeaponEditor/we_core")

local diff = {}

local cache_owner, cache_generation, cache_notes_generation = nil, nil, nil
local edited_prefixes = {} -- path of every edit and every table above one -> true
local noted_prefixes = {} -- path of every note and every table above one -> true
local official_differs_cache = {} -- table path -> whether anything below differs from official
local sub_action_profiles_cache = {} -- sub-action table -> sorted profile names
local flags_cache = {} -- weapon tree node key -> { edited, differs, noted } (see the roll-ups)

-- Adds path and every path above it (from the entry down) to prefixes
local function add_prefixes(prefixes, keys)
	for last_index = 2, #keys do
		prefixes[core.format_path(keys, nil, last_index)] = true
	end
end

local function refresh_caches(editor)
	if cache_owner == editor and cache_generation == editor.edit_generation and cache_notes_generation == editor.notes_generation then
		return
	end

	-- Notes only change the note markers: keep the (deep-compared) official answers
	if cache_owner ~= editor or cache_generation ~= editor.edit_generation then
		edited_prefixes, official_differs_cache = {}, {}
		sub_action_profiles_cache = setmetatable({}, {
			__mode = "k",
		})

		for _, edit in pairs(editor.state.edits) do
			add_prefixes(edited_prefixes, edit.keys)
		end
	end

	cache_owner, cache_generation, cache_notes_generation = editor, editor.edit_generation, editor.notes_generation
	noted_prefixes, flags_cache = {}, {}

	for path in pairs(editor.state.notes) do
		add_prefixes(noted_prefixes, core.parse_path(path))
	end
end

--[[
	Edits and notes
]]

-- True when `path` itself or anything below it is edited
function diff.has_edit_under(editor, path)
	refresh_caches(editor)

	return edited_prefixes[path] == true
end

-- True when `path` itself or anything below it has a note
function diff.has_note_under(editor, path)
	refresh_caches(editor)

	return noted_prefixes[path] == true
end

--[[
	Official values
]]

-- A balance mod's new profile (mb_x) has no official twin of the same name: compare against the
-- profile the actions now using it pointed at before the balance mod. Cached in ui_state, which
-- ui.invalidate_profile_caches clears when forks change.
function diff.official_counterpart(editor, profile_name)
	local s = editor.ui_state

	s.counterparts = s.counterparts or {}

	if s.counterparts[profile_name] == nil then
		local counterpart = false

		if editor.state.vanilla.DamageProfileTemplates[profile_name] then
			counterpart = profile_name
		else
			for _, user in ipairs(editor.profile_users(profile_name)) do
				if type(user.vanilla_profile) == "string" and user.vanilla_profile ~= profile_name then
					counterpart = user.vanilla_profile

					break
				end
			end
		end

		s.counterparts[profile_name] = counterpart
	end

	return s.counterparts[profile_name] or nil
end

-- The official value at keys, and the official profile it came from for a balance mod profile
function diff.official_value(editor, keys)
	if keys[1] == "DamageProfileTemplates" then
		local counterpart = diff.official_counterpart(editor, keys[2])

		if not counterpart then
			return nil, nil
		end

		local counterpart_keys = { "DamageProfileTemplates", counterpart }

		for i = 3, #keys do
			counterpart_keys[#counterpart_keys + 1] = keys[i]
		end

		return core.snapshot_value(editor.state.vanilla, counterpart_keys), counterpart
	end

	return core.snapshot_value(editor.state.vanilla, keys), nil
end

-- Something official doesn't have (a field or table the balance mod added) only counts as a
-- difference inside a table official has, so a table that's new as a whole doesn't flag every
-- field in it. True when official has the table holding keys.
local function official_has_parent(editor, keys)
	if #keys < 3 then
		return false
	end

	local parent_keys = {}

	for i = 1, #keys - 1 do
		parent_keys[i] = keys[i]
	end

	return type((diff.official_value(editor, parent_keys))) == "table"
end

-- Whether a leaf's value differs from official, and the official value
local function official_value_if_different(editor, keys, live_value)
	local official_value = diff.official_value(editor, keys)

	if official_value == live_value or type(official_value) == "table" then
		return false, nil
	end

	if official_value == nil and not official_has_parent(editor, keys) then
		return false, nil
	end

	return true, official_value
end

-- Whether a leaf shows its official value, and the value: always once edited, otherwise where
-- the balance mod changed it
function diff.official_to_show(editor, keys, live_value, edit)
	if edit then
		return true, (diff.official_value(editor, keys))
	end

	return official_value_if_different(editor, keys, live_value)
end

-- Whether anything inside the table at keys differs from official - the balance mod's changes
-- and edits alike - by the same rules as a leaf. Deep-compares the whole subtree, so it's cached
-- per path.
function diff.differs_from_official(editor, keys, path)
	refresh_caches(editor)

	local cached = official_differs_cache[path]

	if cached ~= nil then
		return cached
	end

	local official = diff.official_value(editor, keys)
	local differs

	if official == nil then
		differs = official_has_parent(editor, keys)
	else
		differs = not core.deep_equal(core.live_value(keys), official)
	end

	official_differs_cache[path] = differs

	return differs
end

--[[
	Weapon tree roll-ups: a sub-action counts the damage profiles it uses (balance mods and edits
	change attacks through those as much as through the action), an action its sub-actions, the
	template its actions and other fields. Each returns edited, differs, noted (a note below).
]]

-- Damage profile names a sub-action uses (also its tree label)
function diff.sub_action_profiles(editor, sub_action)
	refresh_caches(editor)

	if sub_action_profiles_cache[sub_action] then
		return sub_action_profiles_cache[sub_action]
	end

	local names = {}

	local function scan(t, depth)
		for k, v in pairs(t) do
			if type(k) == "string" and type(v) == "string" and k:find("damage_profile", 1, true) then
				names[#names + 1] = v
			elseif type(v) == "table" and depth < 2 and not core.EXCLUDED_KEYS[k] then
				scan(v, depth + 1)
			end
		end
	end

	scan(sub_action, 1)
	table.sort(names)

	sub_action_profiles_cache[sub_action] = names

	return names
end

local function cached_flags(editor, key, compute)
	refresh_caches(editor)

	local flags = flags_cache[key]

	if not flags then
		local edited, differs, noted = compute()

		flags = { edited, differs, noted }
		flags_cache[key] = flags
	end

	return flags[1], flags[2], flags[3]
end

-- Combines a child's flags into a running total
local function merge(edited, differs, noted, child_edited, child_differs, child_noted)
	return edited or child_edited, differs or child_differs, noted or child_noted
end

-- One table's own flags (its path and everything below it)
local function node_flags(editor, keys, path)
	return diff.has_edit_under(editor, path), diff.differs_from_official(editor, keys, path), diff.has_note_under(editor, path)
end

function diff.sub_action_flags(editor, sub_keys, sub_path, sub_action)
	return cached_flags(editor, sub_path, function ()
		local edited, differs, noted = node_flags(editor, sub_keys, sub_path)

		for _, profile_name in ipairs(diff.sub_action_profiles(editor, sub_action)) do
			if DamageProfileTemplates[profile_name] then
				local profile_keys = { "DamageProfileTemplates", profile_name }

				edited, differs, noted = merge(edited, differs, noted, node_flags(editor, profile_keys, core.format_path(profile_keys)))
			end
		end

		return edited, differs, noted
	end)
end

function diff.action_flags(editor, action_keys, action_path, action)
	return cached_flags(editor, action_path, function ()
		local edited, differs, noted = node_flags(editor, action_keys, action_path)

		for sub_action_name, sub_action in pairs(action) do
			if type(sub_action) == "table" then
				local sub_keys = core.append_key(action_keys, sub_action_name)

				edited, differs, noted = merge(edited, differs, noted, diff.sub_action_flags(editor, sub_keys, core.format_path(sub_keys), sub_action))
			end
		end

		return edited, differs, noted
	end)
end

-- All of a template's actions (the "actions" node)
function diff.actions_flags(editor, template_keys, actions)
	return cached_flags(editor, core.format_path(template_keys) .. "|actions", function ()
		local edited, differs, noted = false, false, false

		for action_name, action in pairs(actions) do
			if type(action) == "table" then
				local action_keys = { template_keys[1], template_keys[2], "actions", action_name }

				edited, differs, noted = merge(edited, differs, noted, diff.action_flags(editor, action_keys, core.format_path(action_keys), action))
			end
		end

		return edited, differs, noted
	end)
end

-- The template's fields outside actions ("other template fields")
function diff.other_fields_flags(editor, template_keys, template)
	return cached_flags(editor, core.format_path(template_keys) .. "|other", function ()
		local official = diff.official_value(editor, template_keys)
		local edited, differs, noted = false, false, false

		for key, value in pairs(template) do
			if key ~= "actions" and not core.EXCLUDED_KEYS[key] then
				local path = core.format_path(core.append_key(template_keys, key))

				edited = edited or diff.has_edit_under(editor, path)
				noted = noted or diff.has_note_under(editor, path)
				differs = differs or type(official) == "table" and not core.deep_equal(value, official[key])
			end
		end

		if type(official) == "table" and not differs then
			for key in pairs(official) do
				if key ~= "actions" and not core.EXCLUDED_KEYS[key] and template[key] == nil then
					differs = true
				end
			end
		end

		return edited, differs, noted
	end)
end

-- The whole template; its heading's own note counts too
function diff.template_flags(editor, template_keys, template)
	return cached_flags(editor, core.format_path(template_keys), function ()
		local edited, differs, noted = diff.other_fields_flags(editor, template_keys, template)

		if type(template.actions) == "table" then
			edited, differs, noted = merge(edited, differs, noted, diff.actions_flags(editor, template_keys, template.actions))
		end

		noted = noted or editor.state.notes[core.format_path(template_keys)] ~= nil

		return edited, differs, noted
	end)
end

return diff
