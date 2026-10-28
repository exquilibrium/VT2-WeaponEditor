--[[
	Weapon editor: damage and stagger prediction, for the breakpoint grid and its hit log
	(we_breakpoints.lua).

	Damage comes from the registered balance mod's own formula (its damage_calculation and
	stagger_multiplier) or, unregistered, the game's DamageUtils.custom_calculate_damage, with
	everything calculate_damage would read off a target unit taken from the breed instead.
	Checked against real hits with the hit log: it matches except for instakill perks (Killing
	Shot, Murderous Prowess), which aren't modelled. Target-side buffs and ranged falloff are
	left out too.

	Stagger comes from the game's own stagger calculation (see "Stagger" below).
]]

local core = require("scripts/mods/WeaponEditor/we_core")

local pack = core.pack

local prediction = {
	editor = nil, -- set through prediction.set_editor (we_main.lua)
}

--[[
	Damage
]]

function prediction.local_player_unit()
	local player = Managers.player and Managers.player:local_player()
	local unit = player and player.player_unit

	return unit and Unit.alive(unit) and unit or nil
end

function prediction.breed_health(breed, difficulty_level)
	local difficulty_settings = DifficultySettings[difficulty_level]

	return breed.max_health and difficulty_settings and breed.max_health[difficulty_settings.rank] or 0
end

-- Hits to kill, and the share of the last hit's damage the kill needs (1 = right on the
-- breakpoint: any less damage takes another hit)
function prediction.hits_to_kill(health, damage)
	local per_hit = damage and damage > 0 and DamageUtils.networkify_damage(damage) or 0

	if per_hit <= 0 then
		return nil
	end

	local hits = math.ceil(health / per_hit)

	return hits, (health - (hits - 1) * per_hit) / per_hit
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
function prediction.attacker_buffed_damage(damage, attacker_unit, damage_source, damage_profile, first_hit)
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
function prediction.witch_hunt_multiplier(attacker_unit)
	local multiplier = 1 + buff_template_multiplier("defence_debuff_enemies", 0.2)
	local talent_extension = attacker_unit and ScriptUnit.has_extension(attacker_unit, "talent_system")

	if talent_extension and talent_extension:has_talent("victor_witchhunter_improved_damage_taken_ping") then
		multiplier = multiplier * (1 + buff_template_multiplier("victor_witchhunter_improved_damage_taken_ping", 0.05))
	end

	return multiplier
end

--[[
	Bonus to the stagger damage bonus of an enemy debuffed by Bulwark (tank_unbalance_buff, an
	unbalanced_damage_taken stacking_bonus): the game adds it to stagger stacks x per-stack bonus.
	Read from the live template; 0.1 if it's gone.
]]
function prediction.bulwark_bonus()
	local template = rawget(BuffTemplates, "tank_unbalance_buff")
	local buff = template and template.buffs and template.buffs[1]

	return buff and tonumber(buff.bonus) or 0.1
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
-- like a debuff on the enemy (Witch Hunt, the custom damage option); unbalanced_bonus: the
-- enemy's unbalanced_damage_taken (prediction.bulwark_bonus).
function prediction.predict(attacker_unit, damage_source, power_level, damage_profile, target_index, is_critical_strike, breed, hit_zone_name, difficulty_level, boost_damage_multiplier, backstab_multiplier, stagger_number, first_hit, power_bonus, damage_multiplier, unbalanced_bonus)
	local editor = prediction.editor
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
	local max_health = prediction.breed_health(breed, difficulty_level)
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
		local stagger_multiplier = editor.stagger_multiplier(damage_profile, stagger_number or 0, attacker_unit, difficulty_settings, target_index, hit_zone_name, is_critical_strike)

		-- Added to the stagger bonus the same way by the game, TB and Class Balance
		if unbalanced_bonus and not damage_profile.no_stagger_damage_reduction_ranged then
			stagger_multiplier = stagger_multiplier + unbalanced_bonus
		end

		final_damage = base_damage * stagger_multiplier
	end

	local buffed_damage = prediction.attacker_buffed_damage(final_damage, attacker_unit, damage_source, damage_profile, first_hit) * (damage_multiplier or 1)

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

	Balance mods usually change stagger only through weapon data and buffs, both read live by
	the game's function. One that replaces the function registers its own (stagger_calculation),
	which is then used instead - it takes the same arguments.
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

-- The balance mod's do_stagger_calculation, else the game's, or nil when it couldn't be found
-- (looked up once)
function prediction.stagger_calculation()
	local registered = prediction.editor and prediction.editor.host.stagger_calculation

	if registered then
		return registered
	end

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
function prediction.stagger_thresholds(breed, difficulty_level, is_ranged, first_push)
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
	The stagger a hit causes: { type, label, rank, strength, progress }, where
	progress is the share of the next tier's threshold the strength reaches (nil at heavy and
	above, and wherever a breed rule, boss rule or block changed the tier the strength gives).
	stagger_stacks: the enemy's stacks before the hit. attacking: the enemy is mid-attack.
	opportunist: add the trait's bonus if the attacker doesn't have it. power_bonus /
	stagger_power_bonus: extra power / stagger power (0.1 = +10%, like a buff). Returns the
	result and whether the stand-in blackboard was used (false: fell back to the tooltip
	wrapper, stacks and attacking ignored).
]]
function prediction.predict_stagger(attacker_unit, damage_source, power_level, damage_profile, target_index, is_critical_strike, breed, hit_zone_name, difficulty_level, stagger_stacks, attacking, opportunist, blocked, power_bonus, stagger_power_bonus)
	local target_settings = damage_profile.targets and damage_profile.targets[target_index] or damage_profile.default_target

	if not target_settings then
		return nil
	end

	local calculate = prediction.stagger_calculation()
	local has_stacks = calculate and stagger_stacks and stagger_stacks > 0 or false
	local stagger_type, strength

	if damage_profile.no_stagger then
		-- server_apply_hit never staggers with these
		stagger_type, strength = STAGGER_TYPES.none, 0
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

			stagger_type, strength = results[1], results[5]
		else
			local _

			stagger_type, _, _, _, strength = with_extra_stat_buffs(buff_extension, extra_stats, DamageUtils.calculate_stagger_player_tooltip, breed, attacker_unit, hit_zone_name, power_level, is_critical_strike, damage_profile, target_index, blocked or false, damage_source, difficulty_level, has_power_boost, 0)
		end
	end

	stagger_type = stagger_type or STAGGER_TYPES.none
	strength = strength or 0

	local tier = STAGGER_TIERS[stagger_type] or { label = tostring(stagger_type), rank = 0 }
	local progress = nil

	if strength > 0 then
		local thresholds = prediction.stagger_thresholds(breed, difficulty_level, is_ranged_source(damage_source), damage_profile.is_push and not has_stacks)
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
		progress = progress,
	}, calculate ~= nil
end

--[[
	Combos: a list of attacks repeated in order until the enemy dies. step_hits[i] holds the
	damage of each hand of attack i - every hand's hit is its own damage event, so each is
	rounded on its own, like hits_to_kill does. Returns the number of attacks needed and the
	share of the last attack's damage the kill needs.
]]
function prediction.combo_hits_to_kill(health, step_hits)
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
				return attacks, step_total > 0 and (health - (total - step_total)) / step_total or 1
			end
		end
	end

	return nil
end

-- Used by the breakpoint module: tiers for the hit log, ranged check for its thresholds column
prediction.STAGGER_TIERS = STAGGER_TIERS
prediction.is_ranged_source = is_ranged_source

return prediction
