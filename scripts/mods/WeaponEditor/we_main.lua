local mod = get_mod("WeaponEditor")

--[[

	Weapon editor (dev tool - only enable it for balance work)

	Edit Weapons/DamageProfileTemplates values live in game, then export them as Lua to
	paste into a balance mod's weapon change files. Every exported value carries a
	"-- vanilla:" comment.

	Works with any balance mod. A balance mod that registers itself (register_balance_mod,
	see "Balance mod registration" below) gets the full feature set: its own damage formula in
	breakpoints, the hit log through its damage dispatchers, whole-block profile export in its
	own format. Unregistered, the editor falls back to the game's own formula and line-by-line
	exports. See README.md.

	Flow:
		/tbwe                open/close the editor window (F3 switches between using it and playing)
		edit values          action and damage profile edits apply to the next swing/hit. Template
		                     buffs (dodge, movement) and ammo_data need "re-equip" (or /tbwe_reequip),
		                     which the window flags when needed. Damage profiles
		                     open with an "attack sheet" (per-target columns, armor types named)
		structure mode       add/remove fields, add/remove/duplicate/reorder array entries (new
		                     targets, new chain actions); the sheet's "-" cells become "+"
		explosions, spread   searchable on their own, and opened from the fields naming them.
		                     Weapons fire their own table.clone'd copy of an explosion: "link to
		                     global" points the weapon at ExplosionTemplates.x so edits reach both
		fork                 copy a profile into a new tb_ profile and point this attack (or all
		                     attacks of the weapon using it) at it - exports as a new block
		breakpoints          button on any attack (or /tbwe_breakpoints): hits-to-kill grid comparing
		                     now / balance mod / vanilla, plus a hit log checking predictions against real hits
		/tbwe_export         copies the export to the clipboard (and the console log)
		paste, rebuild, restart
		                     on launch, edits that are now in the files are dropped automatically,
		                     anything else is re-applied, and /tbwe_status reports which is which

	Snapshots:
		vanilla      the tables before any balance mod changed them. Taken by this file when the
		             editor loads first, or - when the balance mod loads first - by the balance
		             mod on the editor's behalf (WEAPON_EDITOR_VANILLA_SNAPSHOT, see README.md),
		             so launcher load order doesn't matter
		baseline     taken once all mods have loaded, before any editor edit: what the balance
		             mod's files produce

	Solo/host only: the server resolves damage from its own tables.

	Shared tables: vanilla profiles hold PowerLevelTemplates presets (and sometimes each
	other's sub-tables) by reference. Editing a damage profile field inside one copies it into
	that profile first, so the edit can't leak into every other weapon using the same preset.
	Weapons tables shared between templates are only flagged - the change files share them too.

]]

local core = require("scripts/mods/WeaponEditor/we_core")
local export = require("scripts/mods/WeaponEditor/we_export")
local ui = require("scripts/mods/WeaponEditor/we_ui")
local breakpoints = require("scripts/mods/WeaponEditor/we_breakpoints")

-- Globals the editor can edit and export. Projectiles is deliberately absent: weapon templates
-- are built with table.clone, so every action fires its own embedded copy of its
-- projectile_info and nothing looks Projectiles up by name - those copies are edited (and
-- exported) through the Weapons path instead.
local SUPPORTED_ROOTS = {
	Weapons = true,
	DamageProfileTemplates = true,
	ExplosionTemplates = true,
	SpreadTemplates = true,
}

local INPUT_SERVICE_NAME = "weapon_editor"
local INPUT_CAPTURE_OWNER = "WeaponEditor"

-- Name of the global a balance mod fills with a vanilla snapshot when it loads before the editor
local VANILLA_SNAPSHOT_GLOBAL = "WEAPON_EDITOR_VANILLA_SNAPSHOT"

local function report(format, ...)
	local message = string.format(format, ...)

	mod:echo("[Weapon editor] " .. message)
	print("[Weapon editor] " .. message)
end

local function capture_tables()
	-- One shared `seen`, so a profile's reference to a PowerLevelTemplates preset is still
	-- the same table as the snapshot's own copy of that preset
	local seen = {}

	return {
		Weapons = core.deep_copy(Weapons, seen),
		DamageProfileTemplates = core.deep_copy(DamageProfileTemplates, seen),
		PowerLevelTemplates = core.deep_copy(PowerLevelTemplates, seen),
		ExplosionTemplates = core.deep_copy(ExplosionTemplates, seen),
		SpreadTemplates = core.deep_copy(SpreadTemplates, seen),
	}
end

-- Mods that ran before this one, i.e. whose changes a snapshot taken now would contain
-- (VMF and other framework mods are expected and ignored)
local IGNORED_EARLIER_MODS = {
	["Vermintide Mod Framework"] = true,
}

local function mods_loaded_before_editor()
	local mod_manager = Managers.mod
	local mods = mod_manager and rawget(mod_manager, "_mods")
	local own_index = mod_manager and rawget(mod_manager, "_mod_load_index")
	local names = {}

	if type(mods) == "table" and type(own_index) == "number" then
		for i = 1, own_index - 1 do
			local entry = mods[i]

			if entry and entry.enabled and entry.name and not IGNORED_EARLIER_MODS[entry.name] then
				names[#names + 1] = entry.name
			end
		end
	end

	return names
end

--[[
	State - kept in a global so it outlives a VMF hot reload, which re-runs the change files
	without resetting Weapons/DamageProfileTemplates
]]

local STATE_GLOBAL = "WEAPON_EDITOR_STATE"
local state = rawget(_G, STATE_GLOBAL)

if state then
	-- Change files just re-ran over the live tables and may have overwritten edits
	state.needs_reapply = true
else
	-- The balance mod's own snapshot (it loaded first) wins; otherwise the tables are still
	-- untouched as long as no balance mod has run yet
	local handed_over = rawget(_G, VANILLA_SNAPSHOT_GLOBAL)

	state = {
		vanilla = handed_over and handed_over.tables or capture_tables(),
		vanilla_source = handed_over and handed_over.taken_by or "WeaponEditor",
		-- Set when the editor took its own snapshot after a balance mod already changed the
		-- tables: NewDamageProfileTemplates is the TourneyBalance/Class Balance family's table
		vanilla_tainted = not handed_over and next(rawget(_G, "NewDamageProfileTemplates") or {}) ~= nil,
		mods_before = not handed_over and mods_loaded_before_editor() or {},
		baseline = nil,
		edits = {},
		cow = {},
		forks = {},
		needs_reapply = false,
	}

	rawset(_G, STATE_GLOBAL, state)
	rawset(_G, VANILLA_SNAPSHOT_GLOBAL, nil)
end

--[[
	Balance mod registration. A balance mod calls, from its on_all_mods_loaded:

		get_mod("WeaponEditor").register_balance_mod({ ... })

	Every field is optional; missing ones fall back to the game's own behavior:
		name                      key for saved edits/forks (edits of different mods never mix)
		label                     short name shown for its baseline column/values ("TB")
		profile_prefix            prefix for forked profiles ("tb_")
		authored_profiles_global  global its change files define new profiles in, resolved by
		                          its own setup code ("NewDamageProfileTemplates"); enables
		                          whole-block profile export and forks in that format
		export_key_order          { profile = {...}, target = {...} } key order for exported blocks
		damage_calculation        its do_damage_calculation (same arguments as the game's local one)
		stagger_multiplier        function (damage_profile, stagger_number, attacker_unit,
		                          difficulty_settings) -> damage multiplier for that stagger count
		add_calculate_damage_observer      function (observer): its calculate_damage observer list
		add_apply_buffs_to_damage_wrapper  function (wrapper): its apply_buffs_to_damage wrappers
		legacy_settings_mod, legacy_edits_setting, legacy_forks_setting
		                          where edits were saved before the editor was its own mod (moved
		                          over once)
]]

local GENERIC_HOST = {
	name = "generic",
	label = "base",
	profile_prefix = "new_",
}

local editor -- defined below

local function host()
	return editor.host
end

-- Vanilla game stagger rule (damage_utils.lua calculate_damage): ranged profiles count as at
-- least 1 stack, bonus per stack from the difficulty
local function generic_stagger_multiplier(damage_profile, stagger_number, attacker_unit, difficulty_settings)
	local stagger = stagger_number or 0

	if damage_profile.no_stagger_damage_reduction_ranged then
		stagger = math.max(1, stagger)
	end

	return difficulty_settings.min_stagger_damage_coefficient + stagger * (difficulty_settings.stagger_damage_multiplier or 0)
end

editor = {
	state = state,
	core = core,
	report = report,
	SUPPORTED_ROOTS = SUPPORTED_ROOTS,
	-- The registered balance mod's settings (GENERIC_HOST until one registers)
	host = GENERIC_HOST,
	selected_global = nil, -- { root = "ExplosionTemplates", name = "..." } when not showing a weapon
	window_open = false,
	interacting = false,
	selected_template = nil,
	ui_state = {},
	-- Bumped on every edit/revert so cached breakpoint grids know to recompute
	edit_generation = 0,
	breakpoints_open = false,
	breakpoint_target = nil, -- keys of the sub-action shown in the breakpoint window
	-- template name -> true when an edited field only takes effect after a re-equip
	reequip_needed = {},
	-- window name ("editor"/"breakpoints") -> true: move it back on screen the next time it's drawn
	pending_window_reset = {},
}

-- The breakpoint module predicts damage outside of any window draw (hit log), so it keeps
-- its own reference for the balance mod's damage formula
breakpoints.editor = editor

-- A fork was created or deleted: cached profile lists are stale
function editor.on_profiles_changed()
	ui.invalidate_profile_caches(editor)
end

-- The balance mod's table of profiles defined by its change files (NewDamageProfileTemplates
-- for TourneyBalance), or nil when it has none / none registered
function editor.authored_profiles()
	local global_name = host().authored_profiles_global

	return global_name and rawget(_G, global_name) or nil
end

-- Damage multiplier for a stagger count, by the balance mod's rule or the game's
function editor.stagger_multiplier(damage_profile, stagger_number, attacker_unit, difficulty_settings)
	local stagger_multiplier = host().stagger_multiplier or generic_stagger_multiplier

	return stagger_multiplier(damage_profile, stagger_number, attacker_unit, difficulty_settings)
end

-- Label for the balance mod's baseline (as loaded from its files)
function editor.baseline_label()
	return host().label or GENERIC_HOST.label
end

local function settings_key(kind)
	return string.format("%s_%s", host().name or GENERIC_HOST.name, kind)
end

--[[
	Shared-table lookups (built on first use)
]]

local preset_names = nil -- live PowerLevelTemplates table (and sub-table) -> "name.sub.path"
local profile_owner_counts = nil -- live DamageProfileTemplates sub-table -> number of profiles holding it
local weapon_owners = nil -- live Weapons actions sub-table -> { template names }

local function build_preset_names()
	preset_names = setmetatable({}, { __mode = "k" })

	local function visit(t, label, depth)
		if preset_names[t] or depth > 5 then
			return
		end

		preset_names[t] = label

		for k, v in pairs(t) do
			if type(v) == "table" then
				visit(v, label .. (type(k) == "number" and ("[" .. k .. "]") or ("." .. tostring(k))), depth + 1)
			end
		end
	end

	for name, preset in pairs(PowerLevelTemplates) do
		if type(preset) == "table" then
			visit(preset, name, 1)
		end
	end
end

local function build_profile_owner_counts()
	profile_owner_counts = setmetatable({}, { __mode = "k" })

	for _, profile in pairs(DamageProfileTemplates) do
		local seen = {}

		local function visit(t, depth)
			if seen[t] or depth > 6 then
				return
			end

			seen[t] = true
			profile_owner_counts[t] = (profile_owner_counts[t] or 0) + 1

			for _, v in pairs(t) do
				if type(v) == "table" then
					visit(v, depth + 1)
				end
			end
		end

		if type(profile) == "table" then
			visit(profile, 1)
		end
	end
end

local function build_weapon_owners()
	weapon_owners = setmetatable({}, { __mode = "k" })

	for template_name, template in pairs(Weapons) do
		local actions = type(template) == "table" and template.actions

		if type(actions) == "table" then
			local seen = {}

			local function visit(t, depth)
				if seen[t] or depth > 6 then
					return
				end

				seen[t] = true

				local owners = weapon_owners[t]

				if not owners then
					owners = {}
					weapon_owners[t] = owners
				end

				owners[#owners + 1] = template_name

				for k, v in pairs(t) do
					if type(v) == "table" and not core.EXCLUDED_KEYS[k] then
						visit(v, depth + 1)
					end
				end
			end

			visit(actions, 1)
		end
	end
end

-- Name of the live PowerLevelTemplates preset this table is (or lives inside), or nil
function editor.preset_name(t)
	if not preset_names then
		build_preset_names()
	end

	return preset_names[t]
end

local function is_shared_profile_table(t)
	if editor.preset_name(t) then
		return true
	end

	if not profile_owner_counts then
		build_profile_owner_counts()
	end

	return (profile_owner_counts[t] or 0) > 1
end

-- Other templates whose actions also hold this exact table, or nil
function editor.weapon_sharing(t, current_template_name)
	if not weapon_owners then
		build_weapon_owners()
	end

	local owners = weapon_owners[t]

	if not owners or #owners < 2 then
		return nil
	end

	local others = {}

	for _, name in ipairs(owners) do
		if name ~= current_template_name then
			others[#others + 1] = name
		end
	end

	table.sort(others)

	return others
end

-- Weapon action fields holding their own copy of this explosion instead of the global
-- (weapon templates are table.clone'd). The immediate blast uses that copy, so edits to
-- ExplosionTemplates[name] miss it until it's linked. Returns a list of key paths.
function editor.embedded_explosion_copies(name)
	local global = ExplosionTemplates[name]
	local copies = {}

	local function scan(t, keys, depth)
		for k, v in pairs(t) do
			if type(v) == "table" and not core.EXCLUDED_KEYS[k] then
				local child_keys = core.append_key(keys, k)

				if v.name == name and v ~= global and (v.explosion or v.aoe) then
					copies[#copies + 1] = child_keys
				elseif depth < 6 then
					scan(v, child_keys, depth + 1)
				end
			end
		end
	end

	for template_name, template in pairs(Weapons) do
		if type(template) == "table" and type(template.actions) == "table" then
			scan(template.actions, { "Weapons", template_name, "actions" }, 1)
		end
	end

	table.sort(copies, function (a, b)
		return core.format_path(a) < core.format_path(b)
	end)

	return copies
end

-- Every action field that points at this profile, plus what it pointed at in vanilla
function editor.profile_users(profile_name)
	local users = {}

	local function scan(t, keys, depth)
		for k, v in pairs(t) do
			if type(k) == "string" and v == profile_name and k:find("damage_profile", 1, true) then
				local field_keys = core.append_key(keys, k)

				users[#users + 1] = {
					keys = field_keys,
					vanilla_profile = core.snapshot_value(state.vanilla, field_keys),
				}
			elseif type(v) == "table" and depth < 3 and not core.EXCLUDED_KEYS[k] then
				scan(v, core.append_key(keys, k), depth + 1)
			end
		end
	end

	for template_name, template in pairs(Weapons) do
		local actions = type(template) == "table" and template.actions

		if type(actions) == "table" then
			for action_name, action in pairs(actions) do
				if type(action) == "table" then
					for sub_action_name, sub_action in pairs(action) do
						if type(sub_action) == "table" then
							scan(sub_action, { "Weapons", template_name, "actions", action_name, sub_action_name }, 1)
						end
					end
				end
			end
		end
	end

	table.sort(users, function (a, b)
		return core.format_path(a.keys) < core.format_path(b.keys)
	end)

	return users
end

--[[
	Edits
]]

-- Saved only after something changed: save_edits (called by every edit/revert) marks the list
-- dirty, and flush_saved_edits writes it SAVE_DELAY after the change (or on window close /
-- state change), so typing "0.375" - one edit per keystroke - is one save, not five. A change
-- that leaves the list as it was (a revert that matched nothing, an unchanged restore) writes
-- nothing.
local SAVE_DELAY = 1
local edits_dirty_since = nil
local last_saved_text = nil -- what the setting currently holds

local function main_time()
	return Managers.time and Managers.time:time("main") or 0
end

local function flush_saved_edits()
	if not edits_dirty_since then
		return
	end

	edits_dirty_since = nil

	local paths = {}

	for path in pairs(state.edits) do
		paths[#paths + 1] = path
	end

	table.sort(paths)

	local lines = {}

	for _, path in ipairs(paths) do
		lines[#lines + 1] = path .. "\t" .. core.encode_edit(state.edits[path])
	end

	local text = table.concat(lines, "\n")

	if last_saved_text == nil then
		last_saved_text = mod:get(settings_key("edits")) or ""
	end

	if text ~= last_saved_text then
		mod:set(settings_key("edits"), text)

		last_saved_text = text
	end
end

local function save_edits()
	edits_dirty_since = edits_dirty_since or main_time()
end

-- Template fields the game re-reads on every use (actions on each swing, max_fatigue_points
-- every update, block angles on each block). Everything else outside actions is read when
-- the weapon is wielded (template buffs: dodge, movement...) or when its units spawn
-- (ammo_data), so edits to it only apply after a re-equip.
local LIVE_TEMPLATE_FIELDS = {
	actions = true,
	max_fatigue_points = true,
	block_angle = true,
	outer_block_angle = true,
}

local function flag_reequip(keys)
	if keys[1] == "Weapons" and not LIVE_TEMPLATE_FIELDS[keys[3]] then
		editor.reequip_needed[keys[2]] = true
	end
end

local function flush_mechanism_cache()
	-- Templates with mechanism_overrides are shallow-copied and cached per mechanism
	if MechanismOverrides and MechanismOverrides.mechanism_switched then
		MechanismOverrides.mechanism_switched()
	end
end

-- Swaps each shared table on the way to the edited field for a private copy
local function copy_on_write(keys)
	local node = DamageProfileTemplates[keys[2]]

	for i = 3, #keys - 1 do
		local child = node[keys[i]]

		if type(child) ~= "table" then
			return
		end

		if is_shared_profile_table(child) then
			local clone = core.deep_copy(child)
			local prefix = core.sub_keys(keys, i)

			node[keys[i]] = clone
			state.cow[core.format_path(prefix)] = {
				keys = prefix,
				original = child,
			}
			child = clone
		end

		node = child
	end
end

-- Puts shared tables back once no edit underneath (or above) them is left. An edit above
-- one is a whole-table edit whose recorded contents include the private copy.
local function restore_unused_copies()
	for cow_path, record in pairs(state.cow) do
		local in_use = false

		for path in pairs(state.edits) do
			if core.path_is_under(path, cow_path) or core.path_is_under(cow_path, path) then
				in_use = true

				break
			end
		end

		if not in_use then
			local _, ancestors = core.live_value(record.keys)
			local parent = ancestors[#ancestors]

			if type(parent) == "table" then
				parent[record.keys[#record.keys]] = record.original
			end

			state.cow[cow_path] = nil
		end
	end
end

-- Deletes forks nothing points at anymore (assigned in the Forks section below). Paused while
-- saved edits are being restored, since a fork's rewiring edits are re-applied one at a time.
local remove_unused_forks = nil
local restoring = false

local function cleanup_forks()
	if not restoring and remove_unused_forks then
		remove_unused_forks()
	end
end

-- Puts an edited field back to what it held before the edit
local function restore_edit(edit)
	local _, ancestors = core.live_value(edit.keys)
	local parent = ancestors[#ancestors]

	if type(parent) == "table" and #ancestors == #edit.keys - 1 then
		local restored = edit.original_live

		if restored == nil then
			restored = type(edit.baseline) == "table" and core.deep_copy(edit.baseline) or edit.baseline
		end

		parent[edit.keys[#edit.keys]] = restored
	end
end

-- The closest edit above `keys` that isn't a plain value edit (whole table, removal, link)
local function covering_edit(keys)
	for last_index = #keys - 1, 3, -1 do
		local path = core.format_path(keys, nil, last_index)
		local edit = state.edits[path]

		if edit and (edit.kind or "value") ~= "value" then
			return edit, path
		end
	end

	return nil
end

local function is_unchanged(kind, value, baseline)
	if kind == "value" then
		return core.values_equal(value, baseline)
	elseif kind == "table" then
		return core.deep_equal(value, baseline)
	elseif kind == "removed" then
		return baseline == nil
	end

	-- A link can't be compared against a snapshot copy
	return false
end

-- Single write path for every edit kind (see we_core.lua): kind "value" payload is the new
-- leaf, "table" a table (stored as a copy), "removed" nothing, "ref" a global's path.
local function write_change(keys, kind, payload)
	if #keys < 3 or not SUPPORTED_ROOTS[keys[1]] then
		return false, "only fields inside Weapons, DamageProfileTemplates, ExplosionTemplates and SpreadTemplates entries can be edited"
	end

	local current, ancestors = core.live_value(keys)

	if #ancestors ~= #keys - 1 or type(ancestors[#ancestors]) ~= "table" then
		return false, "path doesn't resolve"
	end

	local new_value = nil

	if kind == "value" then
		if type(current) == "table" then
			return false, "not a leaf value"
		end

		if current ~= nil and type(current) ~= type(payload) then
			return false, string.format("type mismatch (field is %s, got %s)", type(current), type(payload))
		end

		new_value = payload
	elseif kind == "table" then
		if current ~= nil and type(current) ~= "table" then
			return false, "field holds a " .. type(current) .. ", not a table"
		end

		new_value = core.deep_copy(payload)
	elseif kind == "removed" then
		if current == nil then
			return false, "field doesn't exist"
		end
	elseif kind == "ref" then
		new_value = core.live_value(core.parse_path(payload))

		if type(new_value) ~= "table" then
			return false, "unknown global " .. tostring(payload)
		end
	else
		return false, "unknown edit kind " .. tostring(kind)
	end

	local covering, covering_path = covering_edit(keys)

	if covering and covering.kind ~= "table" then
		return false, string.format("%s is %s - edit that instead", covering_path, core.describe_edit(covering))
	end

	local path = core.format_path(keys)

	-- A structural change supersedes whatever was edited underneath it. Those edits are undone
	-- in the live table first, so the table remembered for a revert is the unedited one (the
	-- new value already carries their changes, since the UI built it from the live table).
	if not covering and kind ~= "value" then
		for edit_path, edit in pairs(state.edits) do
			if edit_path ~= path and core.path_is_under(edit_path, path) then
				restore_edit(edit)

				state.edits[edit_path] = nil
			end
		end

		current = core.live_value(keys)
	end

	if keys[1] == "DamageProfileTemplates" then
		copy_on_write(keys)
	end

	local _, write_ancestors = core.live_value(keys)

	write_ancestors[#write_ancestors][keys[#keys]] = new_value
	editor.edit_generation = editor.edit_generation + 1

	flag_reequip(keys)

	if covering then
		-- Folded into the whole-table edit above: it records that table's new contents
		covering.value = core.deep_copy(core.live_value(covering.keys))

		if is_unchanged("table", covering.value, covering.baseline) then
			state.edits[covering_path] = nil
		end
	else
		local existing = state.edits[path]
		local baseline = existing and existing.baseline

		if not existing then
			baseline = core.snapshot_value(state.baseline, keys)
		end

		if is_unchanged(kind, new_value, baseline) then
			state.edits[path] = nil
		else
			state.edits[path] = {
				keys = keys,
				kind = kind,
				value = kind == "table" and core.deep_copy(new_value) or (kind == "value" and new_value or nil),
				ref = kind == "ref" and payload or nil,
				baseline = baseline,
				-- The exact table this field held before the first structural edit, so a
				-- revert puts back that object (keeping shared-preset identity) not a copy
				original_live = existing and existing.original_live or (type(current) == "table" and current or nil),
			}
		end
	end

	-- Pointing an attack away from a fork (e.g. back to its old profile) can orphan it
	if type(keys[#keys]) == "string" and keys[#keys]:find("damage_profile", 1, true) then
		cleanup_forks()
	end

	restore_unused_copies()
	flush_mechanism_cache()
	save_edits()

	return true
end

function editor.apply_edit(keys, value)
	return write_change(keys, "value", value)
end

-- Sets a field to (a copy of) a whole table: adds a table field, or rewrites an array
function editor.set_table(keys, value)
	return write_change(keys, "table", value)
end

function editor.remove_field(keys)
	return write_change(keys, "removed")
end

-- Points a field at a live global table, e.g. "ExplosionTemplates.fireball_charged"
function editor.link_global(keys, global_path)
	return write_change(keys, "ref", global_path)
end

function editor.revert_matching(predicate)
	local count = 0

	for path, edit in pairs(state.edits) do
		if predicate(path, edit) then
			restore_edit(edit)

			flag_reequip(edit.keys)

			state.edits[path] = nil
			count = count + 1
		end
	end

	-- Reverting the edit that pointed an attack at a fork leaves the fork unused
	cleanup_forks()
	restore_unused_copies()
	flush_mechanism_cache()
	save_edits()

	editor.edit_generation = editor.edit_generation + 1

	return count
end

function editor.revert_edit(path)
	return editor.revert_matching(function (edit_path)
		return edit_path == path
	end)
end

function editor.revert_template(template_name)
	return editor.revert_matching(function (_, edit)
		return edit.keys[1] == "Weapons" and edit.keys[2] == template_name
	end)
end

function editor.revert_profile(profile_name)
	return editor.revert_matching(function (_, edit)
		return edit.keys[1] == "DamageProfileTemplates" and edit.keys[2] == profile_name
	end)
end

function editor.revert_all()
	return editor.revert_matching(function ()
		return true
	end)
end

function editor.edit_count()
	local count = 0

	for _ in pairs(state.edits) do
		count = count + 1
	end

	return count
end

--[[
	Forks: a copy of an existing profile under a new name (the balance mod's prefix), with the
	chosen actions pointed at it - what TourneyBalance's change files do by hand with
	NewDamageProfileTemplates.tb_x
]]

local function save_forks()
	local names = table.keys(state.forks)

	table.sort(names)

	local lines = {}

	for _, name in ipairs(names) do
		lines[#lines + 1] = name .. "\t" .. state.forks[name].source
	end

	mod:set(settings_key("forks"), table.concat(lines, "\n"))
end

-- Builds the profile the way TourneyBalance's change files + _damage_profile_setup.lua would:
-- an authored copy that names untouched PowerLevelTemplates presets (into the balance mod's
-- authored profiles table, if it has one), and a live copy that references them (so a later
-- edit copies the preset first, like any other shared table).
local function create_fork(source_name, new_name)
	local source = DamageProfileTemplates[source_name]
	local preset_by_table = {}

	for name, preset in pairs(PowerLevelTemplates) do
		if type(preset) == "table" then
			preset_by_table[preset] = name
		end
	end

	local authored, live = {}, {}

	for k, v in pairs(source) do
		if k == "name" then
			-- damage_profile_templates.lua stamps every vanilla profile with name = its own key
			-- (and asserts they match). Copying it would make the fork claim to be its source:
			-- the game then mixes the two up (missing network lookup entries, crashes).
		elseif type(v) == "table" and preset_by_table[v] then
			authored[k] = preset_by_table[v]
			live[k] = v
		else
			authored[k] = core.deep_copy(v)
			live[k] = core.deep_copy(v)
		end
	end

	local authored_profiles = editor.authored_profiles()

	if authored_profiles then
		authored_profiles[new_name] = authored
	end

	DamageProfileTemplates[new_name] = live

	-- The game (and TB's _damage_profile_setup.lua) gives every profile a zero-attack "_no_damage" twin, which
	-- area_damage_system.lua looks up by name at runtime
	local no_damage = core.deep_copy(live)

	for _, target in ipairs(type(no_damage.targets) == "table" and no_damage.targets or {}) do
		if target.power_distribution then
			target.power_distribution.attack = 0
		end
	end

	if type(no_damage.default_target) == "table" and no_damage.default_target.power_distribution then
		no_damage.default_target.power_distribution.attack = 0
	end

	DamageProfileTemplates[new_name .. "_no_damage"] = no_damage

	-- Hits send the profile as a NetworkLookup id. The table errors on unknown keys, hence rawget.
	local lookup = NetworkLookup.damage_profiles

	if not rawget(lookup, new_name) then
		local index = #lookup + 1

		lookup[index] = new_name
		lookup[new_name] = index
	end

	-- Edits inside the fork compare against (and revert to) its values at fork time
	state.baseline.DamageProfileTemplates[new_name] = core.deep_copy(live)
	state.forks[new_name] = {
		source = source_name,
	}

	if profile_owner_counts then
		build_profile_owner_counts()
	end

	if editor.on_profiles_changed then
		editor.on_profiles_changed()
	end
end

function editor.fork_profile(source_name, new_name, field_keys_list)
	local prefix = host().profile_prefix or GENERIC_HOST.profile_prefix
	local authored_profiles = editor.authored_profiles()

	if type(new_name) ~= "string" or new_name:sub(1, #prefix) ~= prefix or not new_name:match("^[%a_][%w_]*$") then
		return false, string.format("name must start with %s and contain only letters, digits and _", prefix)
	end

	if DamageProfileTemplates[new_name] or (authored_profiles and authored_profiles[new_name]) then
		return false, new_name .. " already exists"
	end

	if not DamageProfileTemplates[source_name] then
		return false, "unknown source profile " .. tostring(source_name)
	end

	create_fork(source_name, new_name)
	save_forks()

	for _, field_keys in ipairs(field_keys_list) do
		local ok, err = editor.apply_edit(field_keys, new_name)

		if not ok then
			report("Couldn't point %s at %s: %s", core.format_path(field_keys), new_name, err)
		end
	end

	-- If no attack could be pointed at it, don't keep an unused fork around
	cleanup_forks()
	save_edits()

	if not state.forks[new_name] then
		return false, "no attack could be pointed at the fork"
	end

	report("Forked %s into %s for %d attack(s).", source_name, new_name, #field_keys_list)

	return true
end

-- Removes a fork's tables, saved entry and every edit inside it (nothing to restore: the
-- tables themselves go away). Callers save the edit list afterwards.
local function drop_fork(name)
	for path, edit in pairs(state.edits) do
		if edit.keys[1] == "DamageProfileTemplates" and edit.keys[2] == name then
			state.edits[path] = nil
		end
	end

	for cow_path, record in pairs(state.cow) do
		if record.keys[1] == "DamageProfileTemplates" and record.keys[2] == name then
			state.cow[cow_path] = nil
		end
	end

	local authored_profiles = editor.authored_profiles()

	if authored_profiles then
		authored_profiles[name] = nil
	end

	DamageProfileTemplates[name] = nil
	DamageProfileTemplates[name .. "_no_damage"] = nil
	state.baseline.DamageProfileTemplates[name] = nil
	state.forks[name] = nil

	save_forks()

	if editor.on_profiles_changed then
		editor.on_profiles_changed()
	end
end

-- A fork no attack points at would otherwise linger: still exported as a new block, and
-- recreated every launch from the saved fork list
remove_unused_forks = function ()
	for name in pairs(state.forks) do
		if #editor.profile_users(name) == 0 then
			drop_fork(name)
			report("Removed fork %s - no attack uses it anymore.", name)
		end
	end
end

function editor.delete_fork(name)
	if not state.forks[name] then
		return
	end

	-- Pointing every field back to its old profile leaves the fork unused, which removes it
	editor.revert_matching(function (_, edit)
		return (edit.keys[1] == "Weapons" and edit.value == name) or (edit.keys[1] == "DamageProfileTemplates" and edit.keys[2] == name)
	end)

	if state.forks[name] then
		drop_fork(name)
		save_edits()
		report("Deleted fork %s.", name)
	end
end

local function restore_saved_forks()
	local saved = mod:get(settings_key("forks"))

	if type(saved) ~= "string" or saved == "" then
		return
	end

	for line in saved:gmatch("[^\n]+") do
		local name, source = line:match("^(.-)\t(.*)$")

		-- Already defined means the exported block made it into the files
		if name and not DamageProfileTemplates[name] then
			if DamageProfileTemplates[source] then
				create_fork(source, name)
			else
				report("Couldn't restore fork %s: source %s no longer exists", name, source)
			end
		end
	end

	save_forks()
end

-- After a hot reload the change files overwrote whatever they set, so put the edits back
local function reapply_edits()
	local edits = state.edits

	state.edits = {}
	restoring = true

	for _, edit in pairs(edits) do
		local kind = edit.kind or "value"

		write_change(edit.keys, kind, kind == "ref" and edit.ref or edit.value)
	end

	restoring = false
	state.needs_reapply = false
end

local function restore_saved_edits()
	local saved = mod:get(settings_key("edits"))

	if type(saved) ~= "string" or saved == "" then
		return
	end

	local restored, landed, failed = 0, 0, 0
	local entries = {}

	for line in saved:gmatch("[^\n]+") do
		local path, encoded = line:match("^(.-)\t(.*)$")

		if path then
			entries[#entries + 1] = {
				path = path,
				encoded = encoded,
			}
		end
	end

	-- Shorter paths first, so a table that was added exists before anything inside it
	table.sort(entries, function (a, b)
		return #a.path < #b.path
	end)

	for _, entry in ipairs(entries) do
		local keys = core.parse_path(entry.path)
		local kind, payload = core.decode_edit(entry.encoded)
		local in_files

		if kind == "ref" then
			-- Landed when the files now point the field at that global themselves
			in_files = core.live_value(keys) == core.live_value(core.parse_path(payload))
		elseif kind then
			in_files = is_unchanged(kind, payload, core.snapshot_value(state.baseline, keys))
		end

		if in_files then
			landed = landed + 1
		elseif kind and write_change(keys, kind, payload) then
			restored = restored + 1
		else
			failed = failed + 1
			report("Couldn't restore saved edit %s", entry.path)
		end
	end

	save_edits()

	editor.last_restore = {
		restored = restored,
		landed = landed,
		failed = failed,
	}

	report("Last session's edits: %d now in the files (dropped), %d re-applied, %d failed.", landed, restored, failed)
end

-- Edits saved while the editor was still part of the balance mod (its own settings) move
-- into the editor's settings once
local function migrate_legacy_settings()
	local legacy_mod_name = host().legacy_settings_mod
	local legacy_mod = legacy_mod_name and get_mod(legacy_mod_name)

	if not legacy_mod then
		return
	end

	local legacy_keys = {
		edits = host().legacy_edits_setting,
		forks = host().legacy_forks_setting,
	}

	for kind, legacy_key in pairs(legacy_keys) do
		local saved = legacy_key and legacy_mod:get(legacy_key)

		if type(saved) == "string" and saved ~= "" then
			if (mod:get(settings_key(kind)) or "") == "" then
				mod:set(settings_key(kind), saved)
				report("Moved saved %s over from %s.", kind, legacy_mod_name)
			end

			legacy_mod:set(legacy_key, "")
		end
	end
end

-- Hit log without a registered balance mod: hook the game's damage functions directly.
-- Hooks from different mods stack in VMF, so this also works when the balance mod replaces
-- them. Only the final damage is visible here, so the formula check is skipped.
local direct_hooks_installed = false

local function hook_damage_functions_directly()
	if direct_hooks_installed then
		return
	end

	direct_hooks_installed = true

	mod:hook(DamageUtils, "calculate_damage", function (func, ...)
		local damage = func(...)

		breakpoints.on_calculate_damage(damage, nil, ...)

		return damage
	end)
	mod:hook(DamageUtils, "apply_buffs_to_damage", breakpoints.on_apply_buffs_to_damage)
end

-- Runs on the first frame after all mods loaded: a balance mod registers from its own
-- on_all_mods_loaded, which may come after the editor's, and restoring forks needs it
local startup_pending = false

local function run_startup()
	startup_pending = false

	if not (host().add_calculate_damage_observer and host().add_apply_buffs_to_damage_wrapper) then
		hook_damage_functions_directly()
	end

	if state.baseline then
		if state.needs_reapply then
			reapply_edits()
		end

		return
	end

	state.baseline = capture_tables()

	migrate_legacy_settings()

	-- Forks first: saved edits may point actions at them or edit inside them
	restoring = true

	restore_saved_forks()
	restore_saved_edits()

	restoring = false

	-- Forks saved by older versions (or whose attacks all got reverted) and no longer used
	remove_unused_forks()
	save_edits()

	-- No weapon has spawned yet at launch, so restored edits need no re-equip
	editor.reequip_needed = {}
end

function mod.on_all_mods_loaded()
	startup_pending = true
end

-- See "Balance mod registration" at the top of this file
function mod.register_balance_mod(settings)
	if type(settings) ~= "table" then
		return
	end

	local registered = {}

	for key, value in pairs(GENERIC_HOST) do
		registered[key] = value
	end

	for key, value in pairs(settings) do
		registered[key] = value
	end

	editor.host = registered

	-- Hit log: observe the balance mod's own damage steps through its dispatchers
	if registered.add_calculate_damage_observer and registered.add_apply_buffs_to_damage_wrapper then
		registered.add_calculate_damage_observer(breakpoints.on_calculate_damage)
		registered.add_apply_buffs_to_damage_wrapper(breakpoints.on_apply_buffs_to_damage)
	end

	print(string.format("[Weapon editor] Registered balance mod %s.", tostring(registered.name)))
end

--[[
	Export
]]

local function put_on_clipboard(text)
	if not rawget(_G, "Clipboard") then
		return false
	end

	local ok = pcall(Clipboard.put, text)

	if not ok then
		return false
	end

	local read_ok, read_back = pcall(Clipboard.get)

	return read_ok and read_back == text
end

function editor.export()
	if editor.edit_count() == 0 and next(state.forks) == nil then
		report("Nothing to export.")
		return
	end

	local text, count = export.build(editor)

	print("[Weapon editor] ---- export begin ----")
	print(text)
	print("[Weapon editor] ---- export end ----")

	if put_on_clipboard(text) then
		report("Exported %d edit(s) to the clipboard.", count)
	else
		report("Clipboard unavailable - the export is in the console log between the begin/end markers.")
	end
end

--[[
	Window and input
]]

rawset(_G, "WeaponEditorKeymaps", rawget(_G, "WeaponEditorKeymaps") or {
	win32 = {
		weapon_editor_toggle = {
			"keyboard",
			"f3",
			"pressed",
		},
	},
})

local function set_interacting(interacting)
	if editor.interacting == interacting then
		return
	end

	local input_manager = Managers.input

	if input_manager then
		local ok, err = pcall(function ()
			if not input_manager:get_input_service(INPUT_SERVICE_NAME) then
				input_manager:create_input_service(INPUT_SERVICE_NAME, "WeaponEditorKeymaps")
				input_manager:map_device_to_service(INPUT_SERVICE_NAME, "keyboard")
				input_manager:map_device_to_service(INPUT_SERVICE_NAME, "mouse")
				input_manager:map_device_to_service(INPUT_SERVICE_NAME, "gamepad")
			end

			local method = interacting and "capture_input" or "release_input"

			input_manager[method](input_manager, ALL_INPUT_METHODS, 1, INPUT_SERVICE_NAME, INPUT_CAPTURE_OWNER)
		end)

		if not ok then
			report("Input capture failed: %s", tostring(err))
		end
	end

	if interacting then
		ShowCursorStack.show(INPUT_CAPTURE_OWNER)
		Imgui.enable_imgui_input_system(Imgui.KEYBOARD)
		Imgui.enable_imgui_input_system(Imgui.MOUSE)
	else
		ShowCursorStack.hide(INPUT_CAPTURE_OWNER)
		Imgui.disable_imgui_input_system(Imgui.KEYBOARD)
		Imgui.disable_imgui_input_system(Imgui.MOUSE)
	end

	editor.interacting = interacting
end

local function open_window()
	if editor.window_open then
		return
	end

	if state.needs_reapply then
		reapply_edits()
	end

	if not editor.selected_template then
		pcall(editor.select_wielded, true)
	end

	Imgui.open_imgui()

	editor.window_open = true

	set_interacting(true)
	report("F3 switches between using the editor and playing.")
end

local function close_window()
	if not editor.window_open then
		return
	end

	set_interacting(false)
	Imgui.close_imgui()
	flush_saved_edits()

	editor.window_open = false
end

function editor.close()
	close_window()
end

-- First attack (sorted by name, action_one first) of the selected template that has a damage profile
local function default_breakpoint_target()
	local template = editor.selected_template and Weapons[editor.selected_template]
	local actions = template and template.actions

	if type(actions) ~= "table" then
		return nil
	end

	local action_names = core.sorted_keys(actions)

	table.sort(action_names, function (a, b)
		if a == "action_one" or b == "action_one" then
			return a == "action_one"
		end

		return a < b
	end)

	for _, action_name in ipairs(action_names) do
		local action = actions[action_name]

		if type(action) == "table" then
			for _, sub_action_name in ipairs(core.sorted_keys(action)) do
				local sub_action = action[sub_action_name]

				if type(sub_action) == "table" then
					local left_name, right_name = ActionUtils.get_damage_profile_name(sub_action, sub_action.weapon_action_hand)

					if left_name or right_name then
						return { "Weapons", editor.selected_template, "actions", action_name, sub_action_name }
					end
				end
			end
		end
	end

	return nil
end

function editor.toggle_breakpoints()
	editor.breakpoints_open = not editor.breakpoints_open

	if editor.breakpoints_open and not editor.breakpoint_target then
		editor.breakpoint_target = default_breakpoint_target()
	end
end

-- keys: path of a sub-action, e.g. { "Weapons", template, "actions", action, sub_action }
function editor.show_breakpoints(keys)
	editor.breakpoint_target = keys
	editor.breakpoints_open = true
end

function editor.select_template(template_name)
	if Weapons[template_name] then
		editor.selected_template = template_name
		editor.selected_global = nil
	end
end

-- Shows a non-weapon entry (e.g. ExplosionTemplates.conflag) instead of a weapon template
function editor.select_global(root, name)
	local entries = SUPPORTED_ROOTS[root] and rawget(_G, root)

	if entries and type(entries[name]) == "table" then
		editor.selected_global = {
			root = root,
			name = name,
		}
	end
end

-- Generic revert for any root's entry (weapon template, explosion, spread template, profile)
function editor.revert_entry(root, name)
	return editor.revert_matching(function (_, edit)
		return edit.keys[1] == root and edit.keys[2] == name
	end)
end

function editor.select_wielded(silent)
	local player = Managers.player and Managers.player:local_player()
	local unit = player and player.player_unit

	if not (unit and Unit.alive(unit)) then
		if not silent then
			report("No player unit.")
		end

		return
	end

	local inventory_extension = ScriptUnit.extension(unit, "inventory_system")
	local slot_data = inventory_extension:get_slot_data(inventory_extension:get_wielded_slot_name())
	local item_data = slot_data and slot_data.item_data
	local template_name = item_data and (item_data.temporary_template or item_data.template)

	if template_name and Weapons[template_name] then
		editor.select_template(template_name)
	elseif not silent then
		report("Wielded item has no weapon template.")
	end
end

-- Despawns and respawns the wielded weapon so everything read at wield/spawn time (template
-- buffs, ammo_data) is read again. Mirrors SimpleInventoryExtension.create_equipment_in_slot,
-- which can't be used directly: it skips an item that's already equipped.
local function reequip_wielded()
	local player = Managers.player and Managers.player:local_player()
	local unit = player and player.player_unit

	if not (unit and Unit.alive(unit)) then
		report("No player unit.")
		return
	end

	local inventory_extension = ScriptUnit.extension(unit, "inventory_system")
	local slot_name = inventory_extension:get_wielded_slot_name()

	if slot_name ~= "slot_melee" and slot_name ~= "slot_ranged" then
		report("Wield a melee or ranged weapon first.")
		return
	end

	if inventory_extension:resyncing_loadout() then
		report("Still re-equipping - try again in a moment.")
		return
	end

	local slot_data = inventory_extension:get_slot_data(slot_name)
	local item_data = slot_data and slot_data.item_data

	if not item_data then
		return
	end

	-- Keep the ammo fraction; the respawned weapon applies it to its (possibly edited) max ammo
	local current_ammo, max_ammo = inventory_extension:current_ammo_status(slot_name)
	local ammo_percent = current_ammo and max_ammo and max_ammo > 0 and current_ammo / max_ammo or nil
	local item_units = BackendUtils.get_item_units(item_data, nil, nil, inventory_extension._career_name)

	inventory_extension:destroy_slot(slot_name, true)

	local default_state_machine = inventory_extension._profile and inventory_extension._profile.default_state_machine

	if default_state_machine then
		inventory_extension.first_person_extension:set_state_machine(default_state_machine)
	end

	inventory_extension:_queue_item_spawn(slot_name, item_data, item_units.skin, ammo_percent)

	-- Career skill weapons that borrow this slot's units (e.g. ult weapons) are respawned with it
	local talent_extension = inventory_extension.talent_extension
	local skill_index = talent_extension and talent_extension:get_talent_career_skill_index() or 1
	local weapon_index = talent_extension and talent_extension:get_talent_career_weapon_index()
	local career_skill_weapon_name = inventory_extension.career_extension:career_skill_weapon_name(skill_index, weapon_index)
	local career_item_data = career_skill_weapon_name and rawget(ItemMasterList, career_skill_weapon_name)

	if career_item_data and career_item_data.slot_to_use == slot_name then
		inventory_extension:destroy_slot("slot_career_skill_weapon", true)

		career_item_data.left_hand_unit = item_data.left_hand_unit
		career_item_data.right_hand_unit = item_data.right_hand_unit

		inventory_extension:_queue_item_spawn("slot_career_skill_weapon", career_item_data, item_units.skin)
	end

	local template_name = item_data.temporary_template or item_data.template

	if template_name then
		editor.reequip_needed[template_name] = nil
	end

	report("Re-equipped %s.", item_data.name)
end

function editor.reequip_wielded()
	local ok, err = pcall(reequip_wielded)

	if not ok then
		report("Re-equip failed: %s", tostring(err))
	end
end

function mod.update()
	if startup_pending then
		run_startup()
	end

	-- Before the window check: commands like /tbwe_revert_all change edits with it closed
	if edits_dirty_since and main_time() - edits_dirty_since >= SAVE_DELAY then
		flush_saved_edits()
	end

	if not editor.window_open then
		return
	end

	if Keyboard.pressed(Keyboard.button_index("f3")) then
		set_interacting(not editor.interacting)
	end

	local ok, do_close = pcall(ui.draw, editor)

	if not ok then
		report("Window error, closing: %s", tostring(do_close))
		close_window()

		return
	elseif do_close then
		close_window()

		return
	end

	if editor.breakpoints_open then
		local t = Managers.time and Managers.time:time("main") or 0
		local bp_ok, bp_close = pcall(breakpoints.draw, editor, t)

		if not bp_ok then
			report("Breakpoint window error, closing it: %s", tostring(bp_close))

			editor.breakpoints_open = false
		elseif bp_close then
			editor.breakpoints_open = false
		end
	end
end

-- Input services and the cursor stack don't survive a level/state change cleanly
function mod.on_game_state_changed()
	close_window()
	flush_saved_edits()
end

--[[
	Commands
]]

mod:command("tbwe", "Weapon editor: open/close the editor window.", function ()
	if editor.window_open then
		close_window()
	else
		open_window()
	end
end)

mod:command("tbwe_breakpoints", "Weapon editor: show/hide the breakpoint window (opens the editor too).", function ()
	open_window()
	editor.toggle_breakpoints()
end)

mod:command("tbwe_reequip", "Weapon editor: respawn the wielded weapon so wield/spawn-time fields (dodge buffs, ammo) apply.", function ()
	editor.reequip_wielded()
end)

mod:command("tbwe_reset_windows", "Weapon editor: move the editor and breakpoint windows back on screen (default position and size).", function ()
	editor.pending_window_reset.editor = true
	editor.pending_window_reset.breakpoints = true

	open_window()
end)

mod:command("tbwe_export", "Weapon editor: copy all edits as Lua (with vanilla comments) to the clipboard.", function ()
	editor.export()
end)

mod:command("tbwe_revert_all", "Weapon editor: revert every edit to what the balance mod's files load.", function ()
	report("Reverted %d edit(s).", editor.revert_all())
end)

mod:command("tbwe_status", "Weapon editor: list current edits and what happened to last session's.", function ()
	local restore = editor.last_restore

	if restore then
		report("At launch: %d edit(s) were in the files (dropped), %d re-applied, %d failed.", restore.landed, restore.restored, restore.failed)
	end

	local paths = {}

	for path in pairs(state.edits) do
		paths[#paths + 1] = path
	end

	table.sort(paths)
	report("%d edit(s) pending export.", #paths)

	for _, path in ipairs(paths) do
		local edit = state.edits[path]

		report("  %s = %s (%s %s)", path, core.describe_edit(edit), editor.baseline_label(), core.format_value(edit.baseline))
	end
end)

if state.vanilla_tainted then
	report("Vanilla snapshot was taken after a balance mod already changed the tables (%s loaded first) - move Weapon Editor above it in the launcher, or let the balance mod take the snapshot (see README), then restart.", #state.mods_before > 0 and table.concat(state.mods_before, ", ") or "something")
end
