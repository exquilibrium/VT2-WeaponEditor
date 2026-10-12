--[[
	Weapon editor: breakpoint grid and hit log.

	Damage comes from the registered balance mod's own formula (its damage_calculation and
	stagger_multiplier) or, unregistered, the
	game's DamageUtils.custom_calculate_damage, with everything calculate_damage would read off a
	target unit taken from the breed instead. Checked against real hits with the hit log: it
	matches except for instakill perks (Killing Shot, Murderous Prowess), which aren't modelled.
	Target-side buffs and ranged falloff are left out too.

	Every cell compares three versions of the attack's damage profile, all through that same
	formula, so the difference is purely the weapon data:
		now       live tables, including editor edits
		baseline  the balance mod as loaded from its files (labelled with its registered label)
		vanilla   the profile the action used before the balance mod

	The stagger sheet does the same with the game's own stagger calculation (see "Stagger"
	below): which stagger tier each hit causes, and how close it gets to the next one.
]]

local core = require("scripts/mods/WeaponEditor/we_core")

local breakpoints = {
	editor = nil, -- set by we_main.lua
}

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

local function pack(...)
	return {
		n = select("#", ...),
		...,
	}
end

--[[
	Damage
]]

function breakpoints.local_player_unit()
	local player = Managers.player and Managers.player:local_player()
	local unit = player and player.player_unit

	return unit and Unit.alive(unit) and unit or nil
end

function breakpoints.breed_health(breed, difficulty_level)
	local difficulty_settings = DifficultySettings[difficulty_level]

	return breed.max_health and difficulty_settings and breed.max_health[difficulty_settings.rank] or 0
end

function breakpoints.hits_to_kill(health, damage)
	if not damage or damage <= 0 then
		return nil
	end

	return math.ceil(health / DamageUtils.networkify_damage(damage))
end

--[[
	Attacker-side damage buffs. DamageUtils.add_damage_network_player runs calculate_damage and
	then apply_buffs_to_damage on its result (which a balance mod may replace), which
	is where talent/property damage buffs live: Heroism (increased_weapon_damage_heavy_attack),
	Grail Knight's first-target perk (first_melee_hit_damage), melee/ranged/2h power-up
	properties, damage_dealt... That function has side effects (procs, Gromril, RPCs), so this
	mirrors only its attacker-side multipliers, in the same order. Target-side effects (target
	health, poison/bleed, balefire, the target's own buffs) aren't modelled - the hit log flags
	them when they change a hit.
]]
function breakpoints.attacker_buffed_damage(damage, attacker_unit, damage_source, damage_profile, first_hit)
	local buff_extension = attacker_unit and ScriptUnit.has_extension(attacker_unit, "buff_system")

	if not buff_extension then
		return damage
	end

	local item_data = rawget(ItemMasterList, damage_source)
	local weapon_template = item_data and item_data.template and rawget(Weapons, item_data.template)

	if weapon_template then
		local buff_type = weapon_template.buff_type

		if buff_type then
			damage = buff_extension:apply_buffs_to_value(damage, "increased_weapon_damage")
		end

		local is_melee = MeleeBuffTypes[buff_type]
		local is_ranged = RangedBuffTypes[buff_type]

		if is_melee then
			damage = buff_extension:apply_buffs_to_value(damage, "increased_weapon_damage_melee")

			if buff_type == "MELEE_1H" then
				damage = buff_extension:apply_buffs_to_value(damage, "increased_weapon_damage_melee_1h")
			elseif buff_type == "MELEE_2H" then
				damage = buff_extension:apply_buffs_to_value(damage, "increased_weapon_damage_melee_2h")
			end

			-- apply_buffs_to_damage gets the profile's charge_value as its attack type
			if damage_profile.charge_value == "heavy_attack" then
				damage = buff_extension:apply_buffs_to_value(damage, "increased_weapon_damage_heavy_attack")
			end

			if first_hit then
				damage = buff_extension:apply_buffs_to_value(damage, "first_melee_hit_damage")
			end
		elseif is_ranged then
			damage = buff_extension:apply_buffs_to_value(damage, "increased_weapon_damage_ranged")
		end

		local weapon_type = weapon_template.weapon_type
		local weapon_stat_buffs = weapon_type and WeaponSpecificStatBuffs[weapon_type]

		if weapon_stat_buffs then
			damage = buff_extension:apply_buffs_to_value(damage, weapon_stat_buffs.damage)
		end

		if is_melee or is_ranged then
			damage = buff_extension:apply_buffs_to_value(damage, "reduced_non_burn_damage")
		end
	end

	return buff_extension:apply_buffs_to_value(damage, "damage_dealt")
end

--[[
	Simulated buffs: the grid's custom power / stagger power options and the Opportunist toggle
	act like extra stat buffs on the attacker, for the duration of one calculation. They go in
	as an instance field shadowing BuffExtension.apply_buffs_to_value (removed right after), so
	whatever formula runs - the balance mod's or the game's - sees them wherever it reads that
	stat. The stats used here are all "stacking_multiplier": the game sums their multipliers
	into one (value * (1 + sum)), so an extra multiplier m adds value * m to the result.
]]

-- Calls func(...) with extra[stat] added as one more multiplier to each stat in extra (nil or
-- empty: a plain call)
local function with_extra_stat_buffs(buff_extension, extra, func, ...)
	if not buff_extension or not extra or next(extra) == nil or rawget(buff_extension, "apply_buffs_to_value") ~= nil then
		return func(...)
	end

	local apply_buffs_to_value = buff_extension.apply_buffs_to_value

	buff_extension.apply_buffs_to_value = function (self, value, stat_buff)
		local result, procced, id = apply_buffs_to_value(self, value, stat_buff)
		local multiplier = extra[stat_buff]

		if multiplier then
			result = result + value * multiplier
		end

		return result, procced, id
	end

	local results = pack(pcall(func, ...))

	buff_extension.apply_buffs_to_value = nil

	if not results[1] then
		error(results[2], 0)
	end

	return unpack(results, 2, results.n)
end

-- A buff template's multiplier as loaded (balance mod changes included): from BuffTemplates,
-- weapon trait or talent buff templates, or fallback
local function buff_template_multiplier(name, fallback)
	local template = BuffTemplates and rawget(BuffTemplates, name) or WeaponTraits and WeaponTraits.buff_templates and WeaponTraits.buff_templates[name]

	if not template and TalentBuffTemplates then
		for _, hero_templates in pairs(TalentBuffTemplates) do
			template = type(hero_templates) == "table" and hero_templates[name]

			if template then
				break
			end
		end
	end

	local buff = template and template.buffs and template.buffs[1]

	return buff and tonumber(buff.multiplier) or fallback
end

--[[
	Damage taken by an enemy tagged by Witch Hunt (defence_debuff_enemies), including Templar's
	Knowledge's extra debuff when the attacker has the talent. Differently named damage_taken
	buffs multiply ("stacking_multiplier_multiplicative"). A balance mod's own bonuses for
	tagged enemies inside its damage formula (TB: Templar's Knowledge's +25% direct damage)
	need a target unit, so they aren't included.
]]
function breakpoints.witch_hunt_multiplier(attacker_unit)
	local multiplier = 1 + buff_template_multiplier("defence_debuff_enemies", 0.2)
	local talent_extension = attacker_unit and ScriptUnit.has_extension(attacker_unit, "talent_system")

	if talent_extension and talent_extension:has_talent("victor_witchhunter_improved_damage_taken_ping") then
		multiplier = multiplier * (1 + buff_template_multiplier("victor_witchhunter_improved_damage_taken_ping", 0.05))
	end

	return multiplier
end

local function power_bonus_stats(power_bonus)
	return power_bonus and power_bonus ~= 0 and {
		power_level = power_bonus,
	} or nil
end

-- Returns the damage a hit deals (stagger multiplier and attacker damage buffs applied),
-- base damage (the formula alone) and the damage before attacker buffs. first_hit: the
-- first enemy a swing hits, which is what first_melee_hit_damage buffs check. power_bonus:
-- extra power (0.1 = +10%, like a power buff); damage_multiplier: on top of everything,
-- like a debuff on the enemy (Witch Hunt, the custom damage option).
function breakpoints.predict(attacker_unit, damage_source, power_level, damage_profile, target_index, is_critical_strike, breed, hit_zone_name, difficulty_level, boost_damage_multiplier, backstab_multiplier, stagger_number, first_hit, power_bonus, damage_multiplier)
	local editor = breakpoints.editor
	local do_damage_calculation = editor and editor.host.damage_calculation
	local target_settings = damage_profile.targets and damage_profile.targets[target_index] or damage_profile.default_target

	if not target_settings then
		return nil
	end

	local boost_curve = BoostCurves[target_settings.boost_curve_type]
	local armor, _, primary_armor = ActionUtils.get_target_armor(hit_zone_name, breed, nil)
	local buff_extension = attacker_unit and ScriptUnit.has_extension(attacker_unit, "buff_system")
	local has_power_boost = buff_extension and buff_extension:has_buff_perk("potion_armor_penetration") or false
	local difficulty_settings = DifficultySettings[difficulty_level]
	local max_health = breakpoints.breed_health(breed, difficulty_level)
	local extra_stats = power_bonus_stats(power_bonus)
	local base_damage

	if do_damage_calculation then
		base_damage = with_extra_stat_buffs(buff_extension, extra_stats, do_damage_calculation, attacker_unit, damage_source, power_level, DamageOutput, hit_zone_name, damage_profile, target_index, boost_curve, boost_damage_multiplier, is_critical_strike, backstab_multiplier, breed, 0, false, false, has_power_boost, difficulty_level, armor, primary_armor, false, false, max_health, nil)
	else
		-- The game's formula: its second return value is the damage before stagger
		local _, unstaggered = with_extra_stat_buffs(buff_extension, extra_stats, DamageUtils.custom_calculate_damage, attacker_unit, damage_source, power_level, damage_profile, target_index, 0, is_critical_strike, backstab_multiplier, has_power_boost, boost_damage_multiplier, breed, hit_zone_name, 0, difficulty_level)

		base_damage = unstaggered
	end

	if not base_damage then
		return nil
	end

	local final_damage = base_damage

	if not damage_profile.is_dot and editor then
		final_damage = base_damage * editor.stagger_multiplier(damage_profile, stagger_number or 0, attacker_unit, difficulty_settings)
	end

	local buffed_damage = breakpoints.attacker_buffed_damage(final_damage, attacker_unit, damage_source, damage_profile, first_hit) * (damage_multiplier or 1)

	return buffed_damage, base_damage, final_damage
end

--[[
	Stagger. Real hits go through the game's do_stagger_calculation (damage_utils.lua), which
	reads two things off the enemy's blackboard: its stagger stacks (each adds to the hit's
	stagger strength, up to double) and its current action (counter_push_power - the Opportunist
	trait - only applies while that action deals damage, i.e. the enemy is attacking). The
	function is local to damage_utils.lua, so it's taken from the upvalues of
	DamageUtils.calculate_stagger_player_tooltip (the game's unit-free wrapper around it) and
	called with a stand-in blackboard. If that lookup fails, the sheet falls back to the wrapper,
	which always assumes a fresh enemy that isn't attacking.

	Balance mods don't register anything for this: they change stagger through weapon data and
	buffs, both read live by the game's function.
]]

local STAGGER_TYPES = require("scripts/utils/stagger_types")
local OPPORTUNIST_BUFF = "traits_melee_counter_push_power"
-- Stand-in for the action of an attacking enemy: damage is the field the game checks. It has
-- no stagger_reduction (so the breed's applies) and no ignore_staggers of its own.
local ATTACKING_ACTION = {
	damage = 1,
}

-- Stagger type -> label and rank (for green/red). Ranged variants count as their melee tier.
local STAGGER_TIERS = {
	[STAGGER_TYPES.none] = { label = "-", rank = 0 },
	[STAGGER_TYPES.weak] = { label = "W", rank = 1 },
	[STAGGER_TYPES.ranged_weak] = { label = "W", rank = 1 },
	[STAGGER_TYPES.weakspot] = { label = "WS", rank = 1 },
	[STAGGER_TYPES.medium] = { label = "M", rank = 2 },
	[STAGGER_TYPES.ranged_medium] = { label = "M", rank = 2 },
	[STAGGER_TYPES.heavy] = { label = "H", rank = 3 },
	[STAGGER_TYPES.pulling] = { label = "P", rank = 3 },
	[STAGGER_TYPES.explosion] = { label = "X", rank = 4 },
}

-- A function-valued upvalue of func by name. Without debug names (stripped bytecode), the
-- only function upvalue when there is exactly one.
local function find_local_function(func, name)
	local debug_library = rawget(_G, "debug")
	local get_upvalue = type(debug_library) == "table" and debug_library.getupvalue

	if not get_upvalue or type(func) ~= "function" then
		return nil
	end

	local only_function, function_count, has_names = nil, 0, false

	for i = 1, 255 do
		local upvalue_name, value = get_upvalue(func, i)

		if upvalue_name == nil then
			break
		end

		if upvalue_name ~= "" and upvalue_name ~= "?" then
			has_names = true
		end

		if type(value) == "function" then
			if upvalue_name == name then
				return value
			end

			only_function = value
			function_count = function_count + 1
		end
	end

	return not has_names and function_count == 1 and only_function or nil
end

local stagger_calculation = nil
local stagger_lookup_done = false

-- The game's do_stagger_calculation, or nil when it couldn't be found (looked up once)
function breakpoints.stagger_calculation()
	if not stagger_lookup_done then
		stagger_lookup_done = true
		stagger_calculation = find_local_function(DamageUtils.calculate_stagger_player_tooltip, "do_stagger_calculation") or find_local_function(DamageUtils.calculate_stagger_player, "do_stagger_calculation")
	end

	return stagger_calculation
end

-- The simulated buffs of a stagger calculation (see with_extra_stat_buffs): power, stagger power
-- (power_level_impact) and, against an attacking enemy, Opportunist - unless something already
-- gives the attacker counter_push_power (the trait itself), which the game then applies itself
local function stagger_stats(buff_extension, attacking, opportunist, power_bonus, stagger_power_bonus)
	local extra = power_bonus_stats(power_bonus) or {}

	if stagger_power_bonus and stagger_power_bonus ~= 0 then
		extra.power_level_impact = stagger_power_bonus
	end

	if attacking and opportunist then
		local stat_buffs = buff_extension and buff_extension._stat_buffs
		local counter_push = stat_buffs and stat_buffs.counter_push_power

		if not (counter_push and next(counter_push) ~= nil) then
			extra.counter_push_power = buff_template_multiplier(OPPORTUNIST_BUFF, 0.5)
		end
	end

	return extra
end

local function is_ranged_source(damage_source)
	local item_data = rawget(ItemMasterList, damage_source)
	local weapon_template = item_data and item_data.template and rawget(Weapons, item_data.template)

	return weapon_template and weapon_template.buff_type and RangedBuffTypes[weapon_template.buff_type] and true or false
end

-- Stagger strength a breed's tiers start at, as do_stagger_calculation computes them for a
-- target without buffs. first_push: a push on an enemy that isn't staggered, which doubles the
-- heavy threshold.
function breakpoints.stagger_thresholds(breed, difficulty_level, is_ranged, first_push)
	local difficulty_settings = DifficultySettings[difficulty_level]
	local rank = difficulty_settings and difficulty_settings.rank or 2
	local resistance = breed.diff_stagger_resist and (breed.diff_stagger_resist[rank] or breed.diff_stagger_resist[2]) or is_ranged and breed.stagger_resistance_ranged or breed.stagger_resistance or 2
	local heavy = (breed.stagger_threshold_heavy or 2.5) * resistance

	return {
		light = (breed.stagger_threshold_light or 0.25) * resistance,
		medium = (breed.stagger_threshold_medium or 1) * resistance,
		heavy = first_push and heavy * 2 or heavy,
	}
end

--[[
	The stagger a hit causes: { type, label, rank, strength, stagger_value, progress }, where
	progress is the share of the next tier's threshold the strength reaches (nil at heavy and
	above, and wherever a breed rule, boss rule or block changed the tier the strength gives).
	stagger_stacks: the enemy's stacks before the hit. attacking: the enemy is mid-attack.
	opportunist: add the trait's bonus if the attacker doesn't have it. power_bonus /
	stagger_power_bonus: extra power / stagger power (0.1 = +10%, like a buff). Returns the
	result and whether the stand-in blackboard was used (false: fell back to the tooltip
	wrapper, stacks and attacking ignored).
]]
function breakpoints.predict_stagger(attacker_unit, damage_source, power_level, damage_profile, target_index, is_critical_strike, breed, hit_zone_name, difficulty_level, stagger_stacks, attacking, opportunist, blocked, power_bonus, stagger_power_bonus)
	local target_settings = damage_profile.targets and damage_profile.targets[target_index] or damage_profile.default_target

	if not target_settings then
		return nil
	end

	local calculate = breakpoints.stagger_calculation()
	local has_stacks = calculate and stagger_stacks and stagger_stacks > 0 or false
	local stagger_type, stagger_value, strength

	if damage_profile.no_stagger then
		-- server_apply_hit never staggers with these
		stagger_type, stagger_value, strength = STAGGER_TYPES.none, 0, 0
	else
		local buff_extension = attacker_unit and ScriptUnit.has_extension(attacker_unit, "buff_system")
		local has_power_boost = buff_extension and buff_extension:has_buff_perk("potion_armor_penetration") or false
		-- The fallback has no attacking enemy, so Opportunist never applies there
		local extra_stats = stagger_stats(buff_extension, calculate and attacking, opportunist, power_bonus, stagger_power_bonus)

		if calculate then
			-- Fields a fresh enemy has. stagger_count: staggers in its current chain, which some
			-- breed stagger rules compare without a nil check (Nurgloth's)
			local blackboard = {
				stagger = has_stacks and stagger_stacks or nil,
				stagger_count = 0,
				action = attacking and ATTACKING_ACTION or nil,
			}
			local results = pack(with_extra_stat_buffs(buff_extension, extra_stats, calculate, ImpactTypeOutput, breed, blackboard, attacker_unit, nil, hit_zone_name, power_level, nil, is_critical_strike, damage_profile, target_index, blocked or false, damage_source, 0, nil, difficulty_level, false, has_power_boost, nil))

			stagger_type, stagger_value, strength = results[1], results[4], results[5]
		else
			local _

			stagger_type, _, _, stagger_value, strength = with_extra_stat_buffs(buff_extension, extra_stats, DamageUtils.calculate_stagger_player_tooltip, breed, attacker_unit, hit_zone_name, power_level, is_critical_strike, damage_profile, target_index, blocked or false, damage_source, difficulty_level, has_power_boost, 0)
		end
	end

	stagger_type = stagger_type or STAGGER_TYPES.none
	strength = strength or 0

	local tier = STAGGER_TIERS[stagger_type] or { label = tostring(stagger_type), rank = 0 }
	local progress = nil

	if strength > 0 then
		local thresholds = breakpoints.stagger_thresholds(breed, difficulty_level, is_ranged_source(damage_source), damage_profile.is_push and not has_stacks)
		local implied_rank, next_threshold

		if strength < thresholds.light then
			implied_rank, next_threshold = 0, thresholds.light
		elseif strength < thresholds.medium then
			implied_rank, next_threshold = 1, thresholds.medium
		elseif strength < thresholds.heavy then
			implied_rank, next_threshold = 2, thresholds.heavy
		end

		if next_threshold and implied_rank == tier.rank and stagger_type ~= STAGGER_TYPES.weakspot then
			progress = strength / next_threshold
		end
	end

	return {
		type = stagger_type,
		label = tier.label,
		rank = tier.rank,
		strength = strength,
		stagger_value = stagger_value,
		progress = progress,
	}, calculate ~= nil
end

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

-- The damage profile(s) of one action in each version of the data. Each hand of a dual
-- weapon action is its own entry.
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

			local left_name, right_name = ActionUtils.get_damage_profile_name(sub_action, sub_action.weapon_action_hand)

			for hand_index, name in ipairs({ left_name or false, right_name or false }) do
				if name then
					local hand = hands[hand_index]

					if not hand then
						hand = {
							label = hand_index == 1 and "left" or "right",
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
		-- Simulated buffs, in percent
		power_percent = 0,
		damage_percent = 0,
		stagger_power_percent = 0,
		target_count_index = 3,
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
	local unit = breakpoints.local_player_unit()

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

	return {
		unit = unit,
		power_level = power_level,
		damage_source = slot_data and slot_data.item_data and slot_data.item_data.name or "default",
		difficulty_level = Difficulties[options.difficulty_index],
		hit_zone_name = HIT_ZONES[options.hit_zone_index],
		stagger_number = options.stagger_index - 1,
		critical = options.critical,
		opportunist = options.opportunist,
		-- Simulated buffs (see with_extra_stat_buffs). The damage multiplier (damage sheet) acts
		-- like debuffs on the enemy; stagger power is the stagger sheet's.
		power_bonus = (options.power_percent or 0) / 100,
		stagger_power_bonus = (options.stagger_power_percent or 0) / 100,
		damage_multiplier = (1 + (options.damage_percent or 0) / 100) * (options.witch_hunt and breakpoints.witch_hunt_multiplier(unit) or 1),
		target_count = options.target_count_index,
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

	if hand.profiles.baseline and hand.names.baseline == hand.names.now and not now_edited then
		same_as.baseline = "now"
	end

	if hand.profiles.vanilla and hand.profiles.baseline and core.deep_equal(hand.profiles.vanilla, hand.profiles.baseline) then
		same_as.vanilla = "baseline"
	end

	return same_as
end

-- Damage one hand of an attack deals to a breed's target_index, per column (nil where the
-- column has no profile or the prediction failed)
local function hand_damages(ctx, hand, breed, target_index)
	local damages = {}

	for _, variant in ipairs(VARIANTS) do
		local profile = hand.profiles[variant]

		if hand.same_as[variant] then
			damages[variant] = damages[hand.same_as[variant]]
		elseif profile then
			-- Target 1 is the swing's first hit (first_melee_hit_damage buffs)
			local ok, damage = pcall(breakpoints.predict, ctx.unit, ctx.damage_source, ctx.power_level, profile, target_index, ctx.critical, breed, ctx.hit_zone_name, ctx.difficulty_level, 0, 1, ctx.stagger_number, target_index == 1, ctx.power_bonus, ctx.damage_multiplier)

			if ok and damage then
				damages[variant] = damage
			end
		end
	end

	return damages
end

-- The stagger one hand of an attack causes on a breed's target_index, per column (nil where
-- the column has no profile or the prediction failed)
local function hand_staggers(ctx, hand, breed, target_index)
	local staggers = {}

	for _, variant in ipairs(VARIANTS) do
		local profile = hand.profiles[variant]

		if hand.same_as[variant] then
			staggers[variant] = staggers[hand.same_as[variant]]
		elseif profile then
			-- Opportunist means the enemy is attacking - the only time the trait applies
			local ok, stagger, full_calculation = pcall(breakpoints.predict_stagger, ctx.unit, ctx.damage_source, ctx.power_level, profile, target_index, ctx.critical, breed, ctx.hit_zone_name, ctx.difficulty_level, ctx.stagger_number, ctx.opportunist, ctx.opportunist, false, ctx.power_bonus, ctx.stagger_power_bonus)

			if ok and stagger then
				staggers[variant] = stagger

				if not full_calculation then
					ctx.problems.no_full_calculation = true
				end
			elseif not ok then
				ctx.problems.error = ctx.problems.error or string.format("%s: %s", tostring(breed.name), tostring(stagger))
			end
		end
	end

	return staggers
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

			local health = breakpoints.breed_health(breed, ctx.difficulty_level)
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

local function compute_attack_grid(editor, ctx)
	local grid = {
		power_level = ctx.power_level,
		difficulty_level = ctx.difficulty_level,
		hands = {},
	}

	for _, hand in ipairs(resolve_profiles(editor, editor.breakpoint_target)) do
		hand.same_as = column_reuse(editor, hand)

		local rows = build_rows(ctx, ctx.target_count, function (breed, health, target_index)
			local cell = {}

			for variant, damage in pairs(hand_damages(ctx, hand, breed, target_index)) do
				cell[variant] = {
					damage = damage,
					hits = breakpoints.hits_to_kill(health, damage),
				}
			end

			return cell
		end)

		grid.hands[#grid.hands + 1] = {
			hand = hand,
			rows = rows,
		}
	end

	return grid
end

-- Stagger grids: each cell variant is a list with the stagger of each hand that hits there
-- (false for a hand without a result), and each row carries its breed's tier thresholds
local function add_stagger_thresholds(grid, ctx)
	local is_ranged = is_ranged_source(ctx.damage_source)

	for _, hand_grid in ipairs(grid.hands) do
		for _, row in ipairs(hand_grid.rows) do
			if row.breed then
				row.thresholds = breakpoints.stagger_thresholds(row.breed, ctx.difficulty_level, is_ranged, false)
			end
		end
	end

	grid.stagger = true
	grid.problems = ctx.problems

	return grid
end

local function compute_attack_stagger_grid(editor, ctx)
	local grid = {
		power_level = ctx.power_level,
		difficulty_level = ctx.difficulty_level,
		hands = {},
	}

	for _, hand in ipairs(resolve_profiles(editor, editor.breakpoint_target)) do
		hand.same_as = column_reuse(editor, hand)

		local rows = build_rows(ctx, ctx.target_count, function (breed, health, target_index)
			local cell = {}

			for variant, stagger in pairs(hand_staggers(ctx, hand, breed, target_index)) do
				cell[variant] = { stagger }
			end

			return cell
		end)

		grid.hands[#grid.hands + 1] = {
			hand = hand,
			rows = rows,
		}
	end

	return add_stagger_thresholds(grid, ctx)
end

--[[
	Combos: a list of attacks repeated in order until the enemy dies. step_hits[i] holds the
	damage of each hand of attack i - every hand's hit is its own damage event, so each is
	rounded on its own, like hits_to_kill does. Returns the number of attacks needed.
]]
function breakpoints.combo_hits_to_kill(health, step_hits)
	local step_totals = {}
	local pass_damage = 0

	for i, hits in ipairs(step_hits) do
		local step_total = 0

		for _, damage in ipairs(hits) do
			step_total = step_total + DamageUtils.networkify_damage(damage)
		end

		step_totals[i] = step_total
		pass_damage = pass_damage + step_total
	end

	if pass_damage <= 0 then
		return nil
	end

	-- Skip the whole passes that can't kill yet; the kill then lands within the next two
	local skipped_passes = math.max(0, math.floor(health / pass_damage) - 1)
	local total = skipped_passes * pass_damage
	local attacks = skipped_passes * #step_totals

	for _ = 1, 2 do
		for _, step_total in ipairs(step_totals) do
			attacks = attacks + 1
			total = total + step_total

			if total >= health then
				return attacks
			end
		end
	end

	return nil
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
		local cell = {}

		for _, hand in ipairs(step.hands) do
			local staggers = hand_staggers(step.ctx, hand, breed, 1)

			for _, variant in ipairs(VARIANTS) do
				cell[variant] = cell[variant] or {}
				cell[variant][#cell[variant] + 1] = staggers[variant] or false
			end
		end

		return cell
	end)

	return add_stagger_thresholds({
		power_level = ctx.power_level,
		difficulty_level = ctx.difficulty_level,
		combo_steps = steps,
		column_titles = column_titles,
		hands = {
			{
				rows = rows,
			},
		},
	}, ctx)
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

		local cell = {}

		for _, variant in ipairs(VARIANTS) do
			-- A column missing any hit (no profile in that version of the data) leaves the
			-- whole combo out rather than showing a partial one
			local complete = #steps > 0
			local pass_damage = 0

			for i = 1, #steps do
				local hits = step_hits[variant][i]

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
				cell[variant] = {
					damage = pass_damage,
					hits = breakpoints.combo_hits_to_kill(health, step_hits[variant]),
				}
			end
		end

		return cell
	end)

	return {
		power_level = ctx.power_level,
		difficulty_level = ctx.difficulty_level,
		combo_steps = steps,
		hands = {
			{
				rows = rows,
			},
		},
	}
end

local function showing_combo(editor)
	return editor.breakpoint_show_combo and #editor.breakpoint_combo > 0
end

-- "simulated: +10% power, damage x1.26 (witch hunt x1.26)" for the grid's header, or nil when
-- the sheet simulates nothing
local function simulated_buffs_text(ctx, options, stagger)
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

		if options.witch_hunt then
			text = string.format("%s (witch hunt x%.3f)", text, breakpoints.witch_hunt_multiplier(ctx.unit))
		end

		parts[#parts + 1] = text
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
		grid = stagger and compute_attack_stagger_grid(editor, ctx) or compute_attack_grid(editor, ctx)
	end

	if grid then
		grid.simulated = simulated_buffs_text(ctx, options, stagger)
	end

	return grid
end

--[[
	Hit log - fed by two of the registered balance mod's dispatchers,
	called in this order for every hit:
		add_calculate_damage_observer     base + stagger damage, checked against the formula
		add_apply_buffs_to_damage_wrapper damage after damage buffs, checked against
		                                  breakpoints.attacker_buffed_damage
	Unregistered, we_main.lua hooks the game's functions directly instead; only the final
	damage is visible then, so the formula check is skipped.

	Staggers come from we_main.lua's hook on DamageUtils.calculate_stagger_player (always the
	game's own), each checked against breakpoints.predict_stagger with the enemy's real stagger
	stacks and whether it was attacking.
]]

local hit_log = {
	enabled = false,
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
	if not hit_log.enabled or not target_unit or not damage_profile or attacker_unit ~= breakpoints.local_player_unit() then
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
	local _, predicted_base = breakpoints.predict(attacker_unit, damage_source, original_power_level, damage_profile, target_index or 1, is_critical_strike, breed, hit_zone_name, difficulty_level, boost_damage_multiplier, backstab_multiplier, 0)
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
		health = breakpoints.breed_health(breed, difficulty_level),
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
	if not hit_log.enabled then
		return func(...)
	end

	local current_damage, attacked_unit, attacker_unit, damage_source, _, _, _, first_hit = ...
	local results = pack(func(...))
	local buffed = results[1]

	if type(buffed) == "number" and attacker_unit == breakpoints.local_player_unit() then
		-- The newest entry for this target that hasn't seen its buff step yet
		for i = 1, math.min(#hit_log.entries, 5) do
			local entry = hit_log.entries[i]

			if entry.target_unit == attacked_unit and entry.buffed == nil then
				local ok, predicted = pcall(breakpoints.attacker_buffed_damage, current_damage, attacker_unit, damage_source, entry.damage_profile, first_hit)

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
	if not hit_log.enabled then
		return func(...)
	end

	local _, target_unit, attacker_unit, hit_zone_name, power_level, _, is_critical_strike, damage_profile, target_index, blocked, damage_source = ...
	local blackboard = target_unit and BLACKBOARDS[target_unit]
	local breed = blackboard and blackboard.breed

	if attacker_unit ~= breakpoints.local_player_unit() or not breed or breed.is_hero or not damage_profile then
		return func(...)
	end

	-- Read before the hit: stagger_ai adds this hit's stacks after the calculation
	local stacks = blackboard.stagger or 0
	local attacking = blackboard.action and blackboard.action.damage and true or false
	local results = pack(func(...))
	local stagger_type, strength = results[1], results[5] or 0
	local difficulty_level = Managers.state.difficulty:get_difficulty()
	local ok, predicted = pcall(breakpoints.predict_stagger, attacker_unit, damage_source, power_level, damage_profile, target_index or 1, is_critical_strike, breed, hit_zone_name, difficulty_level, stacks, attacking, false, blocked)
	local tier = STAGGER_TIERS[stagger_type]
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

local function format_cell_value(cell_variant, display_index)
	if not cell_variant then
		return "-"
	end

	if display_index == 2 then
		return string.format("%.1f", cell_variant.damage)
	end

	return cell_variant.hits and tostring(cell_variant.hits) or "-"
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

		options.witch_hunt = Imgui.checkbox("witch hunt (tagged)##bp_witch_hunt", options.witch_hunt)
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
	local unit = breakpoints.local_player_unit()

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
	}, "|")
end

-- One hand's profile name (with the weapon mode it applies in), plus the baseline and vanilla
-- names when they differ
local function draw_hand_profiles(hand, prefix)
	local label = breakpoints.editor.baseline_label()

	Imgui.text(string.format("%s%s%s", prefix, hand.names.now, hand.weapon_mode and string.format(" (%s mode)", tostring(hand.weapon_mode)) or ""))

	if hand.names.baseline ~= hand.names.now or hand.names.vanilla ~= hand.names.now then
		text_colored(string.format("    %s profile %s, vanilla profile %s", label, tostring(hand.names.baseline or "-"), tostring(hand.names.vanilla or "-")), INFO_COLOR)
	end
end

local function draw_grid(grid, options)
	local label = breakpoints.editor.baseline_label()

	text_colored(string.format("power %d, %s - cells: now | %s | vanilla (green/red: now vs %s)", grid.power_level, grid.difficulty_level, label, label), INFO_COLOR)

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

		if grid.problems.error then
			text_colored("Stagger calculation failed: " .. grid.problems.error, WORSE_COLOR)
		end
	elseif grid.combo_steps then
		text_colored(string.format("combo of %d attacks, repeated in order - hits: attacks to kill, damage: one pass of the combo. Hit zone, stagger and crit are set per attack in the combo list.", #grid.combo_steps), INFO_COLOR)
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
	hit_log.enabled = Imgui.checkbox("record hits##bp_hitlog", hit_log.enabled)

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
			tostring(breakpoints.hits_to_kill(entry.health, dealt) or "-"), entry.health)

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

	if Imgui.collapsing_header(string.format("combo (%d attacks)##bp_combo", #editor.breakpoint_combo), #editor.breakpoint_combo > 0) then
		draw_combo(editor, grid, options)
	end

	if grid then
		if #grid.hands == 0 then
			Imgui.text("This action has no damage profile.")
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
