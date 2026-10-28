--[[
	Weapon editor: breakpoint grid and hit log. The numbers come from we_predict.lua (damage
	and stagger prediction).

	Every cell compares three versions of the attack's damage profile, all through the same
	formula, so the difference is purely the weapon data:
		now       live tables, including editor edits
		baseline  the balance mod as loaded from its files (labelled with its registered label)
		vanilla   the profile the action used before the balance mod (shown as "official")

	The damage sheet shows hits to kill (or damage); the stagger sheet which stagger tier each
	hit causes, and how close it gets to the next one.
]]

local core = require("scripts/mods/WeaponEditor/we_core")
local prediction = require("scripts/mods/WeaponEditor/we_predict")

local breakpoints = {
	editor = nil, -- set through breakpoints.set_editor
}

-- we_main.lua hands over the editor: the grid and prediction read the balance mod's formula,
-- edits and snapshots through it
function breakpoints.set_editor(editor)
	breakpoints.editor = editor
	prediction.editor = editor
end

-- The grid recomputes when its inputs change (see attacker_signature); this is only a safety
-- net for anything that signature doesn't capture
local REFRESH_INTERVAL = 5
local MAX_HIT_LOG = 25
local COMBO_SETTING_WIDTH = 70 -- hit zone / stagger dropdowns of each combo step
local BETTER_COLOR = { 120, 230, 120, 255 }
local WORSE_COLOR = { 255, 110, 90, 255 }
local INFO_COLOR = { 150, 200, 255, 255 }
local MISMATCH_COLOR = { 255, 110, 90, 255 }

-- Grid rows: { breed name, label, category }, shown grouped in this order. The breed list
-- follows changes/thp_stagger_damage_changes/00_bloodlust_health.lua (minus _dummy/_tutorial
-- variants); its "monster" breeds are split into bosses and lords. Categories (and their
-- filter checkboxes) come from this list, in order of first appearance.
breakpoints.BREEDS = {
	{ "skaven_slave", "Slave Rat", "Trash" },
	{ "skaven_clan_rat", "Clan Rat", "Trash" },
	{ "skaven_clan_rat_with_shield", "Shielded Clan Rat", "Trash" },
	{ "chaos_fanatic", "Fanatic", "Trash" },
	{ "chaos_marauder", "Marauder", "Trash" },
	{ "chaos_marauder_with_shield", "Shielded Marauder", "Trash" },
	{ "beastmen_ungor", "Ungor", "Trash" },
	{ "beastmen_ungor_archer", "Ungor Archer", "Trash" },
	{ "beastmen_gor", "Gor", "Trash" },

	{ "skaven_storm_vermin", "Stormvermin", "Elite" },
	{ "skaven_storm_vermin_with_shield", "Shielded Stormvermin", "Elite" },
	{ "skaven_storm_vermin_commander", "Stormvermin Commander", "Elite" },
	{ "skaven_plague_monk", "Plague Monk", "Elite" },
	{ "chaos_raider", "Mauler", "Elite" },
	{ "chaos_berzerker", "Savage", "Elite" },
	{ "chaos_warrior", "Chaos Warrior", "Elite" },
	{ "beastmen_bestigor", "Bestigor", "Elite" },

	{ "beastmen_standard_bearer", "Standard Bearer", "Specials" },
	{ "skaven_gutter_runner", "Gutter Runner", "Specials" },
	{ "skaven_pack_master", "Packmaster", "Specials" },
	{ "skaven_poison_wind_globadier", "Globadier", "Specials" },
	{ "skaven_ratling_gunner", "Ratling Gunner", "Specials" },
	{ "skaven_warpfire_thrower", "Warpfire", "Specials" },
	{ "chaos_vortex_sorcerer", "Blightstormer", "Specials" },
	{ "chaos_corruptor_sorcerer", "Leech", "Specials" },

	{ "skaven_loot_rat", "Sack Rat", "Other" },
	{ "skaven_explosive_loot_rat", "Explosive Loot Rat", "Other" },
	{ "chaos_mutator_sorcerer", "Mutator Sorcerer", "Other" },

	{ "skaven_rat_ogre", "Rat Ogre", "Boss" },
	{ "skaven_stormfiend", "Stormfiend", "Boss" },
	{ "chaos_spawn", "Chaos Spawn", "Boss" },
	{ "chaos_troll", "Bile Troll", "Boss" },
	{ "beastmen_minotaur", "Minotaur", "Boss" },

	{ "skaven_grey_seer", "Rasknitt", "Lords" },
	{ "skaven_stormfiend_boss", "Deathrattler", "Lords" },
	{ "skaven_storm_vermin_warlord", "Skarrik", "Lords" },
	{ "skaven_storm_vermin_champion", "Stormvermin Champion", "Lords" },
	{ "chaos_exalted_champion_warcamp", "Bodvarr", "Lords" },
	{ "chaos_exalted_sorcerer", "Burblespue", "Lords" },
	{ "chaos_exalted_sorcerer_drachenfels", "Nurgloth", "Lords" },
}

breakpoints.CATEGORIES = {}

do
	local seen = {}

	for _, entry in ipairs(breakpoints.BREEDS) do
		local category = entry[3]

		if not seen[category] then
			seen[category] = true
			breakpoints.CATEGORIES[#breakpoints.CATEGORIES + 1] = category
		end
	end
end

local HIT_ZONES = { "torso", "head" }
-- The enemy's stagger stacks. Damage counts at most 2 (3 with Mainstay); stagger strength
-- can still gain from a 3rd on breeds with a low stagger_multiplier (Marauders: 0.45 per stack)
local STAGGER_LEVELS = { "0", "1", "2", "3" }
local TARGET_COUNTS = { "1", "2", "3", "4", "5" }
local SHEETS = { "damage", "stagger" }
local DISPLAY_MODES = { "hits to kill", "damage" }
local STAGGER_DISPLAY_MODES = { "tier + % of next", "strength" }
local VARIANTS = { "now", "baseline", "vanilla" }

--[[
	Grid data
]]

-- Sub-actions with weapon_mode_overrides (the Bright Wizard scythe) swap settings such as their
-- damage profile by the weapon's mode (ActionSweep._populate_sweep_action_data). The grid uses
-- the mode the weapon starts in, from its template's custom_data - for the scythe that's scythe
-- mode, which it only leaves briefly after a discharge. Returns the sub-action as the attack
-- sees it and the mode used (nil when the sub-action has no overrides).
local function apply_mode_overrides(sub_action, template_name)
	local mode_key = sub_action.weapon_mode_key
	local mode_overrides = mode_key and sub_action.weapon_mode_overrides

	if type(mode_overrides) ~= "table" then
		return sub_action, nil
	end

	local template = rawget(Weapons, template_name)
	local mode = template and type(template.custom_data) == "table" and template.custom_data[mode_key]
	local overrides = mode ~= nil and mode_overrides[mode]

	if type(overrides) ~= "table" then
		return sub_action, nil
	end

	local resolved = setmetatable({}, { __index = sub_action })

	for key, value in pairs(overrides) do
		resolved[key] = value
	end

	return resolved, mode
end

-- A sub-action's profiles as { label, name } pairs, and whether it's a push. A push
-- (ActionPushStagger) has an inner and an outer profile, picked by the target's angle;
-- ActionUtils.get_damage_profile_name doesn't see those.
local function sub_action_profile_names(sub_action)
	if sub_action.damage_profile_inner or sub_action.damage_profile_outer then
		return {
			{ "inner", sub_action.damage_profile_inner },
			{ "outer", sub_action.damage_profile_outer },
		}, true
	end

	local left_name, right_name = ActionUtils.get_damage_profile_name(sub_action, sub_action.weapon_action_hand)

	return {
		{ "left", left_name },
		{ "right", right_name },
	}, false
end

-- The damage profile(s) of one action in each version of the data. Each hand of a dual
-- weapon action is its own entry, as are a push's inner and outer profiles.
local function resolve_profiles(editor, target_keys)
	local state = editor.state
	local sources = {
		now = {
			sub_action = core.live_value(target_keys),
			profiles = DamageProfileTemplates,
		},
		baseline = {
			sub_action = core.snapshot_value(state.baseline, target_keys),
			profiles = state.baseline and state.baseline.DamageProfileTemplates,
		},
		vanilla = {
			sub_action = core.snapshot_value(state.vanilla, target_keys),
			profiles = state.vanilla.DamageProfileTemplates,
		},
	}
	local hands = {}
	local weapon_mode = nil

	for _, variant in ipairs(VARIANTS) do
		local source = sources[variant]

		if type(source.sub_action) == "table" and source.profiles then
			local sub_action, mode = apply_mode_overrides(source.sub_action, target_keys[2])

			if variant == "now" then
				weapon_mode = mode
			end

			local entries, is_push = sub_action_profile_names(sub_action)

			for hand_index, entry in ipairs(entries) do
				local name = entry[2]

				if name then
					local hand = hands[hand_index]

					if not hand then
						hand = {
							label = entry[1],
							push = is_push,
							names = {},
							profiles = {},
						}
						hands[hand_index] = hand
					end

					hand.names[variant] = name
					hand.profiles[variant] = source.profiles[name]
				end
			end
		end
	end

	local result = {}

	for hand_index = 1, 2 do
		if hands[hand_index] and hands[hand_index].profiles.now then
			hands[hand_index].weapon_mode = weapon_mode
			result[#result + 1] = hands[hand_index]
		end
	end

	return result
end

local function default_options()
	local difficulty = Managers.state and Managers.state.difficulty and Managers.state.difficulty:get_difficulty()
	-- Category -> shown in the grid (all on)
	local categories = {}

	for _, category in ipairs(breakpoints.CATEGORIES) do
		categories[category] = true
	end

	return {
		sheet_index = 1,
		use_own_power = true,
		power_level = 650,
		difficulty_index = table.find(Difficulties, difficulty) or table.find(Difficulties, "cataclysm") or 1,
		hit_zone_index = 1,
		critical = false,
		stagger_index = 1,
		opportunist = false,
		witch_hunt = false,
		bulwark = false,
		-- Simulated buffs, in percent
		power_percent = 0,
		damage_percent = 0,
		stagger_power_percent = 0,
		target_count_index = 3,
		-- A dual-wield attack's hands in one table, each attack hitting with both
		combine_hands = false,
		display_index = 1,
		stagger_display_index = 1,
		categories = categories,
	}
end

local function stagger_sheet(options)
	return SHEETS[options.sheet_index] == "stagger"
end

-- Everything about the attacker and the chosen options that every cell shares, or nil without
-- a player unit
local function grid_context(options)
	local unit = prediction.local_player_unit()

	if not unit then
		return nil
	end

	local power_level = options.power_level

	if options.use_own_power then
		local career_extension = ScriptUnit.has_extension(unit, "career_system")

		power_level = career_extension and career_extension:get_career_power_level() or power_level
	end

	local inventory_extension = ScriptUnit.extension(unit, "inventory_system")
	local slot_data = inventory_extension:get_slot_data(inventory_extension:get_wielded_slot_name())
	local witch_hunt_multiplier = options.witch_hunt and prediction.witch_hunt_multiplier(unit) or 1

	return {
		unit = unit,
		power_level = power_level,
		damage_source = slot_data and slot_data.item_data and slot_data.item_data.name or "default",
		difficulty_level = Difficulties[options.difficulty_index],
		hit_zone_name = HIT_ZONES[options.hit_zone_index],
		stagger_number = options.stagger_index - 1,
		critical = options.critical,
		opportunist = options.opportunist,
		-- Simulated buffs (see with_extra_stat_buffs in we_predict.lua). The damage multiplier (damage sheet) acts
		-- like debuffs on the enemy; stagger power is the stagger sheet's.
		power_bonus = (options.power_percent or 0) / 100,
		stagger_power_bonus = (options.stagger_power_percent or 0) / 100,
		witch_hunt_multiplier = witch_hunt_multiplier,
		damage_multiplier = (1 + (options.damage_percent or 0) / 100) * witch_hunt_multiplier,
		unbalanced_bonus = options.bulwark and prediction.bulwark_bonus() or nil,
		target_count = options.target_count_index,
		combine_hands = options.combine_hands,
		categories = options.categories,
		-- Shared with the combo steps' contexts: the first error a cell hit, shown above the grid
		problems = {},
	}
end

-- Columns whose profile is identical to an earlier column's reuse its numbers instead of
-- recomputing: baseline = now when nothing in that profile is edited, vanilla = baseline
-- when the balance mod left the profile alone
local function column_reuse(editor, hand)
	local same_as = {}
	local now_path = "DamageProfileTemplates." .. tostring(hand.names.now)
	local now_edited = false

	for edit_path in pairs(editor.state.edits) do
		if core.path_is_under(edit_path, now_path) then
			now_edited = true

			break
		end
	end

	-- "now" is the live tables: official numbers while the editor shows those
	local mode = editor.data_mode()

	if hand.profiles.baseline and hand.names.baseline == hand.names.now and (mode == "baseline" or (mode == "edits" and not now_edited)) then
		same_as.baseline = "now"
	end

	if hand.profiles.vanilla and hand.profiles.baseline and core.deep_equal(hand.profiles.vanilla, hand.profiles.baseline) then
		same_as.vanilla = "baseline"
	end

	return same_as
end

-- Damage one hand of an attack deals to a breed's target_index, per column (nil where the
-- column has no profile or the prediction failed)
-- One hand's result per column: predict(profile) for each version of the data that has a
-- profile, reused where column_reuse found it identical. A failed prediction leaves the column
-- empty and its first error goes to ctx.problems, shown above the grid.
local function per_variant(ctx, hand, breed, predict)
	local results = {}

	for _, variant in ipairs(VARIANTS) do
		local profile = hand.profiles[variant]

		if hand.same_as[variant] then
			results[variant] = results[hand.same_as[variant]]
		elseif profile then
			local ok, result, full_calculation = pcall(predict, profile)

			if ok then
				results[variant] = result

				-- Stagger: fell back to the tooltip wrapper
				if result and full_calculation == false then
					ctx.problems.no_full_calculation = true
				end
			else
				ctx.problems.error = ctx.problems.error or string.format("%s: %s", tostring(breed.name), tostring(result))
			end
		end
	end

	return results
end

-- Damage one hand of an attack deals to a breed's target_index, per column
local function hand_damages(ctx, hand, breed, target_index)
	-- Pushes only stagger: ActionPushStagger sends its hits with can_damage false
	if hand.push then
		local results = {}

		for _, variant in ipairs(VARIANTS) do
			if hand.profiles[variant] then
				results[variant] = 0
			end
		end

		return results
	end

	return per_variant(ctx, hand, breed, function (profile)
		-- Target 1 is the swing's first hit (first_melee_hit_damage buffs)
		return (prediction.predict(ctx.unit, ctx.damage_source, ctx.power_level, profile, target_index, ctx.critical, breed, ctx.hit_zone_name, ctx.difficulty_level, 0, 1, ctx.stagger_number, target_index == 1, ctx.power_bonus, ctx.damage_multiplier, ctx.unbalanced_bonus))
	end)
end

-- The stagger one hand of an attack causes on a breed's target_index, per column
local function hand_staggers(ctx, hand, breed, target_index)
	return per_variant(ctx, hand, breed, function (profile)
		-- Opportunist means the enemy is attacking - the only time the trait applies
		return prediction.predict_stagger(ctx.unit, ctx.damage_source, ctx.power_level, profile, target_index, ctx.critical, breed, ctx.hit_zone_name, ctx.difficulty_level, ctx.stagger_number, ctx.opportunist, ctx.opportunist, false, ctx.power_bonus, ctx.stagger_power_bonus)
	end)
end

-- The grid's rows: shown breeds grouped under category headers, each with column_count cells
-- from cell_for(breed, health, column)
local function build_rows(ctx, column_count, cell_for)
	local rows = {}
	local current_category = nil

	for _, entry in ipairs(breakpoints.BREEDS) do
		local breed = Breeds[entry[1]]
		local category = entry[3]

		if breed and ctx.categories[category] then
			if category ~= current_category then
				current_category = category
				rows[#rows + 1] = {
					header = category,
				}
			end

			local health = prediction.breed_health(breed, ctx.difficulty_level)
			local cells = {}

			for column = 1, column_count do
				cells[column] = cell_for(breed, health, column)
			end

			rows[#rows + 1] = {
				label = entry[2],
				breed = breed,
				health = health,
				cells = cells,
			}
		end
	end

	return rows
end

local function new_grid(ctx)
	return {
		power_level = ctx.power_level,
		difficulty_level = ctx.difficulty_level,
		problems = ctx.problems,
		hands = {},
	}
end

-- Damage sheet cell variant: { damage, hits, last_share } from attacks repeated in order.
-- step_hits[variant] lists each attack's hand damages (false for a hand without a result); a
-- column missing any hit (no profile in that version of the data) is left out rather than
-- showing a partial attack.
local function attacks_damage_cell(health, step_hits)
	local cell = {}

	for _, variant in ipairs(VARIANTS) do
		local steps = step_hits[variant]
		local complete = #steps > 0
		local pass_damage = 0

		for _, hits in ipairs(steps) do
			if #hits == 0 then
				complete = false
			end

			for _, damage in ipairs(hits) do
				if damage then
					pass_damage = pass_damage + damage
				else
					complete = false
				end
			end
		end

		if complete then
			local hits, last_share = prediction.combo_hits_to_kill(health, steps)

			cell[variant] = {
				damage = pass_damage,
				hits = hits,
				last_share = last_share,
			}
		end
	end

	return cell
end

-- Damage sheet cell: one attack hitting with each of hands (one, or both of a dual-wield
-- attack when combined)
local function damage_cell(ctx, hands, breed, health, target_index)
	local step_hits = {}

	for _, variant in ipairs(VARIANTS) do
		step_hits[variant] = { {} }
	end

	for _, hand in ipairs(hands) do
		local damages = hand_damages(ctx, hand, breed, target_index)

		for _, variant in ipairs(VARIANTS) do
			local hits = step_hits[variant][1]

			hits[#hits + 1] = damages[variant] or false
		end
	end

	return attacks_damage_cell(health, step_hits)
end

-- Appends each hand's stagger to its cell variant's list (false for a hand without a result)
local function add_hand_staggers(cell, ctx, hands, breed, target_index)
	for _, hand in ipairs(hands) do
		local staggers = hand_staggers(ctx, hand, breed, target_index)

		for _, variant in ipairs(VARIANTS) do
			cell[variant] = cell[variant] or {}
			cell[variant][#cell[variant] + 1] = staggers[variant] or false
		end
	end

	return cell
end

-- Stagger sheet cell variant: a list of the stagger of each hand that hits there. A column
-- with no result from any hand is left out.
local function stagger_cell(ctx, hands, breed, health, target_index)
	local cell = add_hand_staggers({}, ctx, hands, breed, target_index)

	for _, variant in ipairs(VARIANTS) do
		local any = false

		for _, stagger in ipairs(cell[variant]) do
			any = any or stagger ~= false
		end

		if not any then
			cell[variant] = nil
		end
	end

	return cell
end

-- One grid per hand of the attack, cells from cell_for (damage_cell / stagger_cell). With
-- combine_hands, a dual-wield attack's hands share one grid: each attack hits with both. A
-- push's inner and outer profiles are alternatives (by the target's angle), never combined.
local function compute_attack_grid(editor, ctx, cell_for)
	local grid = new_grid(ctx)
	local groups = {}

	for _, hand in ipairs(resolve_profiles(editor, editor.breakpoint_target)) do
		hand.same_as = column_reuse(editor, hand)
		grid.push = grid.push or hand.push

		if ctx.combine_hands and not hand.push and groups[1] then
			table.insert(groups[1], hand)
		else
			groups[#groups + 1] = { hand }
		end
	end

	for _, hands in ipairs(groups) do
		local rows = build_rows(ctx, ctx.target_count, function (breed, health, target_index)
			return cell_for(ctx, hands, breed, health, target_index)
		end)

		grid.hands[#grid.hands + 1] = {
			hand = #hands == 1 and hands[1] or nil,
			combined = #hands > 1 and hands or nil,
			rows = rows,
		}
	end

	return grid
end

-- Stagger grids: each cell variant is a list with the stagger of each hand that hits there
-- (false for a hand without a result), and each row carries its breed's tier thresholds
local function add_stagger_thresholds(grid, ctx)
	local is_ranged = prediction.is_ranged_source(ctx.damage_source)

	for _, hand_grid in ipairs(grid.hands) do
		-- A push profile on an enemy without stagger stacks needs double for heavy (combos mix
		-- steps, so they show the normal thresholds)
		local profile = hand_grid.hand and hand_grid.hand.profiles.now
		local first_push = profile and profile.is_push and ctx.stagger_number == 0 or false

		for _, row in ipairs(hand_grid.rows) do
			if row.breed then
				row.thresholds = prediction.stagger_thresholds(row.breed, ctx.difficulty_level, is_ranged, first_push)
			end
		end
	end

	grid.stagger = true

	return grid
end

-- A combo's grid: one table of rows for the whole combo
local function new_combo_grid(ctx, steps, rows)
	local grid = new_grid(ctx)

	grid.combo_steps = steps
	grid.hands[1] = {
		rows = rows,
	}

	return grid
end


-- A combo step's attack: action.sub_action, with the weapon in front when it's not the first
-- step's weapon
local function combo_step_label(combo, keys)
	local label = core.format_relative(keys, 4)

	if combo[1] and keys[2] ~= combo[1].keys[2] then
		label = tostring(keys[2]) .. "." .. label
	end

	return label
end

local function combo_steps(editor, ctx)
	local steps = {}

	for i, entry in ipairs(editor.breakpoint_combo) do
		local hands = resolve_profiles(editor, entry.keys)

		for _, hand in ipairs(hands) do
			hand.same_as = column_reuse(editor, hand)
		end

		steps[i] = {
			keys = entry.keys,
			hands = hands,
			-- The step's own hit zone, stagger, crit and Opportunist over the shared context
			ctx = setmetatable({
				hit_zone_name = HIT_ZONES[entry.hit_zone_index],
				stagger_number = entry.stagger_index - 1,
				critical = entry.critical,
				opportunist = entry.opportunist or false,
			}, { __index = ctx }),
		}
	end

	return steps
end

-- The combo's stagger: one column per step, each on target 1
local function compute_combo_stagger_grid(editor, ctx)
	local steps = combo_steps(editor, ctx)
	local column_titles = {}

	for i, step in ipairs(steps) do
		column_titles[i] = string.format("%d. %s", i, combo_step_label(editor.breakpoint_combo, step.keys))
	end

	local rows = build_rows(ctx, #steps, function (breed, health, step_index)
		local step = steps[step_index]

		return add_hand_staggers({}, step.ctx, step.hands, breed, 1)
	end)

	local grid = new_combo_grid(ctx, steps, rows)

	grid.column_titles = column_titles

	return add_stagger_thresholds(grid, ctx)
end

local function compute_combo_grid(editor, ctx)
	local steps = combo_steps(editor, ctx)

	local rows = build_rows(ctx, ctx.target_count, function (breed, health, target_index)
		-- variant -> per step, the damage of each of its hands
		local step_hits = {}

		for _, variant in ipairs(VARIANTS) do
			step_hits[variant] = {}
		end

		for i, step in ipairs(steps) do
			for _, variant in ipairs(VARIANTS) do
				step_hits[variant][i] = {}
			end

			for _, hand in ipairs(step.hands) do
				local damages = hand_damages(step.ctx, hand, breed, target_index)

				for _, variant in ipairs(VARIANTS) do
					local hits = step_hits[variant][i]

					hits[#hits + 1] = damages[variant] or false
				end
			end
		end

		return attacks_damage_cell(health, step_hits)
	end)

	return new_combo_grid(ctx, steps, rows)
end

local function showing_combo(editor)
	return editor.breakpoint_show_combo and #editor.breakpoint_combo > 0
end

-- "simulated: +10% power, damage x1.26 (witch hunt x1.26)" for the grid's header, or nil when
-- the sheet simulates nothing
local function simulated_buffs_text(ctx, stagger)
	local parts = {}

	if ctx.power_bonus ~= 0 then
		parts[#parts + 1] = string.format("%+g%% power", ctx.power_bonus * 100)
	end

	if stagger then
		if ctx.stagger_power_bonus ~= 0 then
			parts[#parts + 1] = string.format("%+g%% stagger power", ctx.stagger_power_bonus * 100)
		end
	elseif ctx.damage_multiplier ~= 1 then
		local text = string.format("damage x%.3f", ctx.damage_multiplier)

		if ctx.witch_hunt_multiplier ~= 1 then
			text = string.format("%s (witch hunt x%.3f)", text, ctx.witch_hunt_multiplier)
		end

		parts[#parts + 1] = text
	end

	if not stagger and ctx.unbalanced_bonus then
		parts[#parts + 1] = string.format("%+g%% stagger bonus (bulwark)", ctx.unbalanced_bonus * 100)
	end

	return #parts > 0 and "simulated: " .. table.concat(parts, ", ") or nil
end

local function compute_grid(editor, options)
	local ctx = grid_context(options)

	if not ctx then
		return nil
	end

	local stagger = stagger_sheet(options)
	local grid

	if showing_combo(editor) then
		grid = stagger and compute_combo_stagger_grid(editor, ctx) or compute_combo_grid(editor, ctx)
	elseif editor.breakpoint_target then
		grid = stagger and add_stagger_thresholds(compute_attack_grid(editor, ctx, stagger_cell), ctx) or compute_attack_grid(editor, ctx, damage_cell)
	end

	if grid then
		grid.simulated = simulated_buffs_text(ctx, stagger)
	end

	return grid
end

--[[
	Hit log - fed by two of the registered balance mod's dispatchers,
	called in this order for every hit:
		add_calculate_damage_observer     base + stagger damage, checked against the formula
		add_apply_buffs_to_damage_wrapper damage after damage buffs, checked against
		                                  prediction.attacker_buffed_damage
	Unregistered, we_main.lua hooks the game's functions directly instead; only the final
	damage is visible then, so the formula check is skipped.

	Staggers come from we_main.lua's hook on DamageUtils.calculate_stagger_player (always the
	game's own), each checked against prediction.predict_stagger with the enemy's real stagger
	stacks and whether it was attacking.
]]

local hit_log = {
	-- Recorded separately: usually only one of the two is wanted
	log_damage = false,
	log_stagger = false,
	entries = {},
	stagger_entries = {},
	last_key = nil,
	last_t = -1,
}

local profile_name_lookup = {}

local function profile_name(damage_profile)
	local name = profile_name_lookup[damage_profile]

	if not name then
		for template_name, template in pairs(DamageProfileTemplates) do
			profile_name_lookup[template] = template_name
		end

		name = profile_name_lookup[damage_profile] or "?"
	end

	return name
end

function breakpoints.on_calculate_damage(final_damage, base_damage, damage_output, target_unit, attacker_unit, hit_zone_name, original_power_level, boost_curve, boost_damage_multiplier, is_critical_strike, damage_profile, target_index, backstab_multiplier, damage_source)
	if not hit_log.log_damage or not target_unit or not damage_profile or attacker_unit ~= prediction.local_player_unit() then
		return
	end

	local breed = AiUtils.unit_breed(target_unit)

	if not breed or breed.is_hero then
		return
	end

	-- The same hit can be calculated twice in one frame (prediction + server apply)
	local t = Managers.time:time("game") or 0
	local hit_key = tostring(target_unit) .. tostring(damage_profile) .. tostring(target_index)

	if hit_key == hit_log.last_key and t - hit_log.last_t < 0.05 then
		return
	end

	hit_log.last_key, hit_log.last_t = hit_key, t

	local difficulty_level = Managers.state.difficulty:get_difficulty()
	local _, predicted_base = prediction.predict(attacker_unit, damage_source, original_power_level, damage_profile, target_index or 1, is_critical_strike, breed, hit_zone_name, difficulty_level, boost_damage_multiplier, backstab_multiplier, 0)
	local entries = hit_log.entries
	-- Unchecked (nil) when the base damage isn't visible: no balance mod registered its observer
	local formula_match = nil

	if base_damage then
		formula_match = predicted_base ~= nil and math.abs(predicted_base - base_damage) < 0.01
	end

	table.insert(entries, 1, {
		breed_name = breed.name,
		hit_zone_name = hit_zone_name,
		target_index = target_index,
		is_critical_strike = is_critical_strike,
		profile_name = profile_name(damage_profile),
		damage_profile = damage_profile,
		damage_source = damage_source,
		target_unit = target_unit,
		health = prediction.breed_health(breed, difficulty_level),
		base = base_damage,
		calculated = final_damage,
		predicted_base = predicted_base,
		formula_match = formula_match,
		-- Filled in by on_apply_buffs_to_damage right after
		buffed = nil,
		predicted_buffed = nil,
		buff_match = nil,
	})

	entries[MAX_HIT_LOG + 1] = nil
end

-- Wrapper for the balance mod's apply_buffs_to_damage dispatcher: passes everything through untouched and
-- records the buffed damage on the hit's entry. Runs for every damage event in the game, so
-- with the hit log off it's a plain tail call.
function breakpoints.on_apply_buffs_to_damage(func, ...)
	if not hit_log.log_damage then
		return func(...)
	end

	local current_damage, attacked_unit, attacker_unit, damage_source, _, _, _, first_hit = ...
	local results = core.pack(func(...))
	local buffed = results[1]

	if type(buffed) == "number" and attacker_unit == prediction.local_player_unit() then
		-- The newest entry for this target that hasn't seen its buff step yet
		for i = 1, math.min(#hit_log.entries, 5) do
			local entry = hit_log.entries[i]

			if entry.target_unit == attacked_unit and entry.buffed == nil then
				local ok, predicted = pcall(prediction.attacker_buffed_damage, current_damage, attacker_unit, damage_source, entry.damage_profile, first_hit)

				entry.buffed = buffed
				entry.first_hit = first_hit
				entry.predicted_buffed = ok and predicted or nil
				entry.buff_match = ok and math.abs(predicted - buffed) < 0.01

				break
			end
		end
	end

	return unpack(results, 1, results.n)
end

-- Hook for DamageUtils.calculate_stagger_player: passes everything through untouched and logs
-- the local player's staggers with the prediction for them. The prediction runs after the
-- real calculation, not inside it, so procs paired around a calculation never nest.
function breakpoints.on_calculate_stagger(func, ...)
	if not hit_log.log_stagger then
		return func(...)
	end

	local _, target_unit, attacker_unit, hit_zone_name, power_level, _, is_critical_strike, damage_profile, target_index, blocked, damage_source = ...
	local blackboard = target_unit and BLACKBOARDS[target_unit]
	local breed = blackboard and blackboard.breed

	if attacker_unit ~= prediction.local_player_unit() or not breed or breed.is_hero or not damage_profile then
		return func(...)
	end

	-- Read before the hit: stagger_ai adds this hit's stacks after the calculation
	local stacks = blackboard.stagger or 0
	local attacking = blackboard.action and blackboard.action.damage and true or false
	local results = core.pack(func(...))
	local stagger_type, strength = results[1], results[5] or 0
	local difficulty_level = Managers.state.difficulty:get_difficulty()
	local ok, predicted = pcall(prediction.predict_stagger, attacker_unit, damage_source, power_level, damage_profile, target_index or 1, is_critical_strike, breed, hit_zone_name, difficulty_level, stacks, attacking, false, blocked)
	local tier = prediction.STAGGER_TIERS[stagger_type]
	local entries = hit_log.stagger_entries

	table.insert(entries, 1, {
		breed_name = breed.name,
		hit_zone_name = hit_zone_name,
		target_index = target_index,
		is_critical_strike = is_critical_strike,
		profile_name = profile_name(damage_profile),
		stacks = stacks,
		attacking = attacking,
		blocked = blocked,
		label = tier and tier.label or tostring(stagger_type),
		strength = strength,
		predicted = ok and predicted or nil,
		match = ok and predicted ~= nil and predicted.type == stagger_type and math.abs(predicted.strength - strength) < 0.01,
	})

	entries[MAX_HIT_LOG + 1] = nil

	return unpack(results, 1, results.n)
end

--[[
	Window
]]

local function text_colored(text, color)
	Imgui.text_colored(text, color[1], color[2], color[3], color[4])
end

-- "2 (73%)": hits to kill, and how much of the last hit's damage the kill needs - 100% is
-- right on the breakpoint (the share is floored like the stagger sheet's, but never shows 0%)
local function format_hits(hits, last_share)
	if not hits then
		return "-"
	end

	if not last_share then
		return tostring(hits)
	end

	return string.format("%d (%d%%)", hits, math.max(1, math.floor(last_share * 100 + 1e-6)))
end

local function format_cell_value(cell_variant, display_index)
	if not cell_variant then
		return "-"
	end

	if display_index == 2 then
		return string.format("%.1f", cell_variant.damage)
	end

	return format_hits(cell_variant.hits, cell_variant.last_share)
end

-- now vs baseline: fewer hits / more damage is better
local function cell_color(cell, display_index)
	local now, baseline = cell.now, cell.baseline

	if not (now and baseline) then
		return nil
	end

	local now_value = display_index == 2 and -now.damage or now.hits
	local baseline_value = display_index == 2 and -baseline.damage or baseline.hits

	if not (now_value and baseline_value) or math.abs(now_value - baseline_value) < 1e-3 then
		return nil
	end

	return now_value < baseline_value and BETTER_COLOR or WORSE_COLOR
end

-- One stagger cell variant: the tier with the share of the next tier's threshold reached
-- ("M 82%"), or the strength; hands joined with "+"
local function format_stagger_value(hands, display_index)
	if not hands or #hands == 0 then
		return "-"
	end

	local parts = {}

	for i, stagger in ipairs(hands) do
		if not stagger then
			parts[i] = "?"
		elseif display_index == 2 then
			parts[i] = string.format("%.2f", stagger.strength)
		elseif stagger.progress then
			parts[i] = string.format("%s %d%%", stagger.label, math.floor(stagger.progress * 100))
		else
			parts[i] = stagger.label
		end
	end

	return table.concat(parts, "+")
end

local function stagger_score(hands)
	local rank, strength = 0, 0

	for _, stagger in ipairs(hands) do
		if stagger then
			rank = rank + stagger.rank
			strength = strength + stagger.strength
		end
	end

	return rank, strength
end

-- now vs baseline: a higher tier is better, then more strength
local function stagger_cell_color(cell)
	if not (cell.now and cell.baseline) then
		return nil
	end

	local now_rank, now_strength = stagger_score(cell.now)
	local baseline_rank, baseline_strength = stagger_score(cell.baseline)

	if now_rank ~= baseline_rank then
		return now_rank > baseline_rank and BETTER_COLOR or WORSE_COLOR
	end

	if math.abs(now_strength - baseline_strength) < 1e-3 then
		return nil
	end

	return now_strength > baseline_strength and BETTER_COLOR or WORSE_COLOR
end

-- A number option in percent, as a text field
local function percent_field(label, options, key)
	local value, changed = Imgui.input_float(label, options[key] or 0)

	if changed and type(value) == "number" then
		options[key] = value
	end
end

local function draw_options(options)
	options.use_own_power = Imgui.checkbox("my power level##bp_own_power", options.use_own_power)

	if not options.use_own_power then
		Imgui.same_line()

		local power_level, changed = Imgui.input_float("power##bp_power", options.power_level)

		if changed then
			options.power_level = math.floor(power_level + 0.5)
		end
	end

	options.difficulty_index = Imgui.combo("difficulty##bp_difficulty", options.difficulty_index, Difficulties)
	options.hit_zone_index = Imgui.combo("hit zone##bp_zone", options.hit_zone_index, HIT_ZONES)
	options.stagger_index = Imgui.combo("stagger stacks##bp_stagger", options.stagger_index, STAGGER_LEVELS)
	options.target_count_index = Imgui.combo("targets##bp_targets", options.target_count_index, TARGET_COUNTS)
	options.combine_hands = Imgui.checkbox("combine dual-wield hands into one attack##bp_combine_hands", options.combine_hands or false)

	if Imgui.is_item_hovered() then
		Imgui.begin_tool_tip()
		Imgui.text("Off: one table per hand. On: one table where each attack hits with both hands -")
		Imgui.text("hits to kill counts attacks, damage is both hands' together. Pushes keep inner/outer apart.")
		Imgui.end_tool_tip()
	end

	if stagger_sheet(options) then
		options.stagger_display_index = Imgui.combo("show##bp_stagger_display", options.stagger_display_index, STAGGER_DISPLAY_MODES)
	else
		options.display_index = Imgui.combo("show##bp_display", options.display_index, DISPLAY_MODES)
	end

	options.critical = Imgui.checkbox("crit##bp_crit", options.critical)

	if stagger_sheet(options) then
		Imgui.same_line()

		options.opportunist = Imgui.checkbox("opportunist (enemy attacking)##bp_opportunist", options.opportunist)
	else
		Imgui.same_line()

		options.witch_hunt = Imgui.checkbox("whc tag##bp_witch_hunt", options.witch_hunt)

		Imgui.same_line()

		options.bulwark = Imgui.checkbox("bulwark##bp_bulwark", options.bulwark)

		if Imgui.is_item_hovered() then
			Imgui.begin_tool_tip()
			Imgui.text(string.format("Enemy debuffed by Bulwark (tank_unbalance_buff): +%g%% to the stagger damage bonus.", prediction.bulwark_bonus() * 100))
			Imgui.text("Only where the balance mod still applies that buff - TB replaced it with a plain damage taken debuff (use extra damage % there).")
			Imgui.end_tool_tip()
		end
	end

	-- Simulated buffs, on top of the ones you have
	percent_field("extra power %##bp_power_percent", options, "power_percent")

	if stagger_sheet(options) then
		percent_field("extra stagger power %##bp_stagger_power_percent", options, "stagger_power_percent")
	else
		percent_field("extra damage % (like a debuff on the enemy)##bp_damage_percent", options, "damage_percent")
	end

	Imgui.text("show:")

	for _, category in ipairs(breakpoints.CATEGORIES) do
		Imgui.same_line()

		options.categories[category] = Imgui.checkbox(category .. "##bp_category_" .. category, options.categories[category])
	end
end

-- Cheap per-frame fingerprint of everything on the attacker that feeds the grid: the buff
-- list (BuffExtension.id counts up on every add, the list shrinks on removal), power level
-- and wielded item (the damage source). Changes => recompute; otherwise the grid is reused.
local function attacker_signature()
	local unit = prediction.local_player_unit()

	if not unit then
		return "no unit"
	end

	local buff_extension = ScriptUnit.has_extension(unit, "buff_system")
	local career_extension = ScriptUnit.has_extension(unit, "career_system")
	local inventory_extension = ScriptUnit.has_extension(unit, "inventory_system")
	local slot_data = inventory_extension and inventory_extension:get_slot_data(inventory_extension:get_wielded_slot_name())
	local item_name = slot_data and slot_data.item_data and slot_data.item_data.name

	return string.format("%s:%s|%s|%s",
		buff_extension and buff_extension._buffs and #buff_extension._buffs or "-",
		buff_extension and buff_extension.id or "-",
		career_extension and career_extension:get_career_power_level() or "-",
		tostring(item_name))
end

local function options_key(editor, options)
	local shown_categories = {}

	for _, category in ipairs(breakpoints.CATEGORIES) do
		shown_categories[#shown_categories + 1] = options.categories[category] and category or "-"
	end

	local combo_paths = {}

	if showing_combo(editor) then
		for i, entry in ipairs(editor.breakpoint_combo) do
			combo_paths[i] = string.format("%s:%d:%d:%s:%s", core.format_path(entry.keys), entry.hit_zone_index, entry.stagger_index, tostring(entry.critical), tostring(entry.opportunist))
		end
	end

	return table.concat({
		tostring(options.sheet_index),
		tostring(options.opportunist),
		tostring(options.witch_hunt),
		tostring(options.bulwark),
		tostring(options.power_percent),
		tostring(options.damage_percent),
		tostring(options.stagger_power_percent),
		attacker_signature(),
		table.concat(shown_categories, ","),
		tostring(editor.edit_generation),
		editor.breakpoint_target and core.format_path(editor.breakpoint_target) or "none",
		table.concat(combo_paths, ">"),
		tostring(options.use_own_power),
		tostring(options.power_level),
		tostring(options.difficulty_index),
		tostring(options.hit_zone_index),
		tostring(options.critical),
		tostring(options.stagger_index),
		tostring(options.target_count_index),
		tostring(options.combine_hands),
	}, "|")
end

-- One hand's profile name (with the weapon mode it applies in), plus the baseline and vanilla
-- names when they differ
local function draw_hand_profiles(hand, prefix)
	local label = breakpoints.editor.baseline_label()

	Imgui.text(string.format("%s%s%s", prefix, hand.names.now, hand.weapon_mode and string.format(" (%s mode)", tostring(hand.weapon_mode)) or ""))

	if hand.names.baseline ~= hand.names.now or hand.names.vanilla ~= hand.names.now then
		text_colored(string.format("    %s profile %s, official profile %s", label, tostring(hand.names.baseline or "-"), tostring(hand.names.vanilla or "-")), INFO_COLOR)
	end
end

local function draw_grid(grid, options)
	local label = breakpoints.editor.baseline_label()

	text_colored(string.format("power %d, %s - cells: now | %s | official (green/red: now vs %s)", grid.power_level, grid.difficulty_level, label, label), INFO_COLOR)

	if grid.simulated then
		text_colored(grid.simulated, BETTER_COLOR)
	end

	if grid.stagger then
		text_colored("stagger: - none, W weak, M medium, H heavy, X explosion, P pull; % = share of the next tier's threshold reached. Thresholds: where weak / medium / heavy start (a push on an unstaggered enemy needs double for heavy).", INFO_COLOR)

		if grid.combo_steps then
			text_colored(string.format("combo of %d attacks - one column per attack, each on target 1. Hit zone, stagger stacks, crit and Opportunist are set per attack in the combo list.", #grid.combo_steps), INFO_COLOR)
		end

		if grid.problems.no_full_calculation then
			text_colored("The game's stagger calculation couldn't be reached (debug.getupvalue) - showing its tooltip version instead: stagger stacks and Opportunist are ignored.", WORSE_COLOR)
		end
	else
		if grid.combo_steps then
			text_colored(string.format("combo of %d attacks, repeated in order - hits: attacks to kill, damage: one pass of the combo. Hit zone, stagger and crit are set per attack in the combo list.", #grid.combo_steps), INFO_COLOR)
		end

		if options.display_index == 1 then
			text_colored("2 (73%) = 2 hits to kill, the last one needing 73% of its damage (100% = right on the breakpoint).", INFO_COLOR)
		end
	end

	-- A cell whose calculation threw is left empty; the first error says why
	if grid.problems.error then
		text_colored("Calculation failed (cells left empty): " .. grid.problems.error, WORSE_COLOR)
	end

	local column_titles = grid.column_titles

	if not column_titles then
		column_titles = {}

		for target_index = 1, options.target_count_index do
			column_titles[target_index] = "target " .. target_index
		end
	end

	local column_count = #column_titles

	for _, hand_grid in ipairs(grid.hands) do
		local hand = hand_grid.hand

		Imgui.separator()

		if hand then
			draw_hand_profiles(hand, #grid.hands > 1 and (hand.label .. ": ") or "")
		elseif hand_grid.combined then
			text_colored("hands combined: each attack hits with all of them", INFO_COLOR)

			for _, combined_hand in ipairs(hand_grid.combined) do
				draw_hand_profiles(combined_hand, combined_hand.label .. ": ")
			end
		end

		Imgui.columns(column_count + 2, true)
		Imgui.text("breed")
		Imgui.next_column()
		Imgui.text(grid.stagger and "thresholds" or "hp")

		for _, title in ipairs(column_titles) do
			Imgui.next_column()
			Imgui.text(title)
		end

		Imgui.next_column()
		Imgui.separator()

		for _, row in ipairs(hand_grid.rows) do
			if row.header then
				-- Category divider: label in the first column, the rest of the row left empty.
				-- column_count + 2 columns, so it takes that many next_column calls to wrap
				-- back to the first column of the next row.
				Imgui.separator()
				text_colored(row.header, INFO_COLOR)

				for _ = 1, column_count + 2 do
					Imgui.next_column()
				end
			else
				Imgui.text(row.label)
				Imgui.next_column()

				if row.thresholds then
					Imgui.text(string.format("%.2f / %.2f / %.2f", row.thresholds.light, row.thresholds.medium, row.thresholds.heavy))
				else
					Imgui.text(string.format("%.0f", row.health))
				end

				for column = 1, column_count do
					Imgui.next_column()

					local cell = row.cells[column]
					local text, color

					if grid.stagger then
						local display_index = options.stagger_display_index

						text = string.format("%s | %s | %s", format_stagger_value(cell.now, display_index), format_stagger_value(cell.baseline, display_index), format_stagger_value(cell.vanilla, display_index))
						color = stagger_cell_color(cell)
					else
						text = string.format("%s | %s | %s", format_cell_value(cell.now, options.display_index), format_cell_value(cell.baseline, options.display_index), format_cell_value(cell.vanilla, options.display_index))
						color = cell_color(cell, options.display_index)
					end

					if color then
						text_colored(text, color)
					else
						Imgui.text(text)
					end
				end

				Imgui.next_column()
			end
		end

		Imgui.columns(1)
	end
end

local function draw_hit_log()
	hit_log.log_damage = Imgui.checkbox("log damage##bp_hitlog_damage", hit_log.log_damage)

	Imgui.same_line()

	hit_log.log_stagger = Imgui.checkbox("log stagger##bp_hitlog_stagger", hit_log.log_stagger)

	Imgui.same_line()

	if Imgui.small_button("clear##bp_hitlog_clear") then
		hit_log.entries = {}
		hit_log.stagger_entries = {}
	end

	if #hit_log.stagger_entries > 0 then
		text_colored("staggers (predicted with the enemy's real stacks and whether it was attacking):", INFO_COLOR)
	end

	for _, entry in ipairs(hit_log.stagger_entries) do
		local predicted = entry.predicted
		local text = string.format("%s %s T%s%s [%s] %s stacks%s%s: %s (%.2f), predicted %s (%.2f)",
			entry.breed_name, entry.hit_zone_name, tostring(entry.target_index), entry.is_critical_strike and " crit" or "", entry.profile_name,
			tostring(entry.stacks), entry.attacking and ", attacking" or "", entry.blocked and ", blocked" or "",
			entry.label, entry.strength, predicted and predicted.label or "?", predicted and predicted.strength or -1)

		if entry.match then
			Imgui.text(text)
		else
			text_colored(text .. " - MISMATCH", MISMATCH_COLOR)
		end
	end

	if #hit_log.stagger_entries > 0 and #hit_log.entries > 0 then
		text_colored("damage:", INFO_COLOR)
	end

	for _, entry in ipairs(hit_log.entries) do
		-- Damage actually dealt: after the buff step when it ran (it doesn't for every hit)
		local dealt = entry.buffed or entry.calculated
		local buff_multiplier = entry.buffed and entry.calculated > 0 and entry.buffed / entry.calculated or 1
		local stagger_text = entry.base and entry.base > 0 and string.format("x%.2f", entry.calculated / entry.base) or "x?"
		local text = string.format("%s %s T%s%s%s [%s] %.2f dmg (%s stagger, x%.2f damage buffs) - %s hits of %.0f hp",
			entry.breed_name, entry.hit_zone_name, tostring(entry.target_index), entry.is_critical_strike and " crit" or "", entry.first_hit and " first hit" or "", entry.profile_name,
			dealt, stagger_text, buff_multiplier,
			format_hits(prediction.hits_to_kill(entry.health, dealt)), entry.health)

		if entry.formula_match == false then
			text_colored(string.format("%s - formula MISMATCH (base %.2f, predicted %.2f)", text, entry.base, entry.predicted_base or -1), MISMATCH_COLOR)
		elseif entry.buff_match == false then
			text_colored(string.format("%s - damage buff MISMATCH (actual x%.2f, predicted x%.2f)", text, buff_multiplier, entry.predicted_buffed and entry.calculated > 0 and entry.predicted_buffed / entry.calculated or 0), MISMATCH_COLOR)
		else
			Imgui.text(text)
		end
	end
end

-- Combo steps with move up / remove buttons. Structural changes apply after the loop so the
-- list isn't modified while it's being drawn.
local function draw_combo(editor, grid, options)
	local combo = editor.breakpoint_combo

	editor.breakpoint_show_combo = Imgui.checkbox("show combo instead of the attack##bp_show_combo", editor.breakpoint_show_combo)

	if editor.breakpoint_target then
		Imgui.same_line()

		if Imgui.small_button("add attack##bp_combo_add") then
			editor.add_to_combo(editor.breakpoint_target)
		end
	end

	if #combo == 0 then
		Imgui.text("Empty - add attacks with \"+ combo\" in the editor or \"add attack\" here.")

		return
	end

	Imgui.same_line()

	if Imgui.small_button("clear##bp_combo_clear") then
		editor.breakpoint_combo = {}

		return
	end

	local move_up, remove = nil, nil
	-- Profile names come from the computed grid, when it's the combo's
	local steps = grid and grid.combo_steps

	for i, entry in ipairs(combo) do
		if i > 1 and Imgui.small_button("^##bp_combo_up" .. i) then
			move_up = i
		end

		if i > 1 then
			Imgui.same_line()
		end

		if Imgui.small_button("x##bp_combo_remove" .. i) then
			remove = i
		end

		Imgui.same_line()
		Imgui.text(string.format("%d. %s", i, combo_step_label(combo, entry.keys)))

		-- The step's own hit zone, stagger stacks, crit and (stagger sheet) Opportunist
		Imgui.text("   ")
		Imgui.same_line()
		Imgui.push_item_width(COMBO_SETTING_WIDTH)

		entry.hit_zone_index = Imgui.combo("##bp_combo_zone" .. i, entry.hit_zone_index, HIT_ZONES)

		Imgui.same_line()

		entry.stagger_index = Imgui.combo("stagger##bp_combo_stagger" .. i, entry.stagger_index, STAGGER_LEVELS)

		Imgui.pop_item_width()
		Imgui.same_line()

		entry.critical = Imgui.checkbox("crit##bp_combo_crit" .. i, entry.critical)

		if stagger_sheet(options) then
			Imgui.same_line()

			entry.opportunist = Imgui.checkbox("opportunist##bp_combo_opportunist" .. i, entry.opportunist or false)
		end

		local step = steps and steps[i]

		if step then
			if #step.hands == 0 then
				text_colored("    no damage profile", WORSE_COLOR)
			end

			for _, hand in ipairs(step.hands) do
				draw_hand_profiles(hand, #step.hands > 1 and ("    " .. hand.label .. ": ") or "    ")
			end
		end
	end

	if move_up then
		combo[move_up], combo[move_up - 1] = combo[move_up - 1], combo[move_up]
	elseif remove then
		table.remove(combo, remove)
	end
end

local function draw_body(editor, t)
	local s = editor.ui_state

	s.breakpoint_options = s.breakpoint_options or default_options()

	local options = s.breakpoint_options

	if editor.edit_mode_problem() then
		text_colored(string.format("Live numbers: %s - the \"now\" column shows those, not your edits.", editor.data_mode_label(editor.data_mode())), WORSE_COLOR)
	end

	if editor.breakpoint_target then
		Imgui.text(core.format_relative(editor.breakpoint_target, 2))
	else
		Imgui.text("Pick an attack with its \"breakpoints\" button in the editor.")
	end

	options.sheet_index = Imgui.combo("sheet##bp_sheet", options.sheet_index, SHEETS)

	if Imgui.collapsing_header("options##bp_options", true) then
		draw_options(options)
	end

	local key = options_key(editor, options)
	local has_subject = editor.breakpoint_target or showing_combo(editor)

	if has_subject and (key ~= s.breakpoint_key or t - (s.breakpoint_time or -math.huge) > REFRESH_INTERVAL) then
		s.breakpoint_grid = compute_grid(editor, options)
		s.breakpoint_key = key
		s.breakpoint_time = t
	end

	local grid = has_subject and s.breakpoint_grid or nil

	if Imgui.collapsing_header(string.format("combo (%d attacks)###bp_combo", #editor.breakpoint_combo), #editor.breakpoint_combo > 0) then
		draw_combo(editor, grid, options)
	end

	if grid then
		if #grid.hands == 0 then
			Imgui.text("This action has no damage profile.")
		elseif grid.push and not grid.stagger and not grid.combo_steps then
			Imgui.text("Pushes deal no damage - see the stagger sheet.")
		else
			draw_grid(grid, options)
		end
	elseif has_subject then
		Imgui.text("Needs a player unit - open this in the keep or a level.")
	end

	Imgui.separator()

	if Imgui.collapsing_header("hit log##bp_hitlog_header", false) then
		draw_hit_log()
	end
end

-- Returns true when the window should close. The body runs in a pcall so end_window is
-- always reached - an error between begin/end would leave Imgui's window stack broken.
function breakpoints.draw(editor, t)
	-- /we_reset_windows: offset from the editor window so both stay grabbable
	if editor.pending_window_reset.breakpoints then
		editor.pending_window_reset.breakpoints = nil

		Imgui.set_next_window_pos(90, 90)
		Imgui.set_next_window_size(820, 700)
	end

	local do_close = Imgui.begin_window("Weapon Editor Breakpoints")

	Imgui.set_window_size(820, 700, "once")

	local ok, err = pcall(draw_body, editor, t)

	Imgui.end_window()

	if not ok then
		error(err, 0)
	end

	return do_close
end

return breakpoints
