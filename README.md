# Weapon Editor

In-game Imgui tool for tuning a balance mod's weapons. You edit values while playing, check
breakpoints, then export the changes as Lua to paste into the balance mod's weapon change
files. Every exported value carries a `-- vanilla:` comment.

It's a separate dev mod: only people doing balance work enable it, so it can't ship to
players by accident. It works with any balance mod; one that registers itself (see below) gets
its own damage formula in the breakpoint grid and exports in its own format.

## Setup

1. Enable **Weapon Editor** in the launcher alongside the balance mod. Load order doesn't
   matter if the balance mod supports the editor (see "Vanilla snapshot" below).
2. Build, then **fully restart the game**. A VMF hot reload is not enough: the `we_*.lua`
   files are loaded with `require`, which keeps the old copies until restart.
3. Play solo or as host. The server calculates damage from its own tables, so edits only
   affect hits in games you host.

### Vanilla snapshot

The `-- vanilla:` comments and the breakpoint grid's vanilla column need the weapon tables as
they were before the balance mod changed them:

- **Editor loads first:** it takes the snapshot itself.
- **Balance mod loads first:** the balance mod takes it on the editor's behalf, before any of
  its change files run, into the global `WEAPON_EDITOR_VANILLA_SNAPSHOT` (see below).
- **Neither** (a balance mod without that support, loaded first): chat warns at launch that
  the vanilla comments are wrong. Move Weapon Editor above it in the launcher.

## Balance mod support

A balance mod supports the editor with a small support file, dofile'd before any of its change
files. It does two things, both only while the editor is enabled.

**1. The vanilla snapshot.** Runs at load time, when the editor is enabled (check
`Managers.mod._mods` for Workshop id 3818239110 or the name "WeaponEditor" / "Weapon Editor")
and neither `WEAPON_EDITOR_STATE` nor `WEAPON_EDITOR_VANILLA_SNAPSHOT` exists yet:

```lua
local seen = {} -- one shared table, so profiles still share their presets in the copy

rawset(_G, "WEAPON_EDITOR_VANILLA_SNAPSHOT", {
	taken_by = "MyBalanceMod",
	tables = {
		Weapons = deep_copy(Weapons, seen),
		DamageProfileTemplates = deep_copy(DamageProfileTemplates, seen),
		PowerLevelTemplates = deep_copy(PowerLevelTemplates, seen),
		ExplosionTemplates = deep_copy(ExplosionTemplates, seen),
		SpreadTemplates = deep_copy(SpreadTemplates, seen),
	},
})
```

**2. Registration**, from its `on_all_mods_loaded`. Every field is optional; without
registration the editor uses the game's own damage formula, hooks the damage functions itself
(the hit log then can't check the formula step) and exports profile changes line by line.

```lua
local weapon_editor = get_mod("WeaponEditor")

if weapon_editor and weapon_editor.register_balance_mod then
	weapon_editor.register_balance_mod({
		name = "MyBalanceMod",                    -- key for saved edits/forks
		label = "MB",                             -- shown for its baseline values/column
		profile_prefix = "mb_",                   -- forked profile names
		authored_profiles_global = "NewDamageProfileTemplates", -- whole-block profile export + forks
		export_key_order = { profile = { order = {...}, unknown_before = "default_target" }, target = {...} },
		damage_calculation = do_damage_calculation, -- its own formula, if it replaces the game's
		stagger_multiplier = function (damage_profile, stagger_number, attacker_unit, difficulty_settings) ... end,
		add_calculate_damage_observer = function (observer) ... end,      -- hit log, formula step
		add_apply_buffs_to_damage_wrapper = function (wrapper) ... end,   -- hit log, damage buff step
		-- where a former built-in editor saved its edits (moved over once, at the first launch)
		legacy_settings_mod = "MyBalanceMod", legacy_edits_setting = "...", legacy_forks_setting = "...",
	})
end
```

The rest of this guide uses that example registration: its baseline label is "MB", forks are
named `mb_...` and its profile blocks are `NewDamageProfileTemplates.mb_x`.

## Commands

| Command | What it does |
|---|---|
| `/we` | Open/close the editor window |
| `/we_breakpoints` | Show/hide the breakpoint window |
| `/we_reequip` | Respawn the wielded weapon so wield/spawn-time fields apply |
| `/we_export` | Copy all edits as Lua to the clipboard (also printed to the console log) |
| `/we_status` | List pending edits, and what happened to last session's at launch |
| `/we_revert_all` | Revert every edit to what the balance mod's files load |
| `/we_reset_windows` | Move both windows back on screen (they vanish if dragged outside the game window) |

**F3** switches between using the windows (mouse cursor, game input blocked) and playing.
Chat can't be opened while the windows have input, so press F3 before typing a command.

## Finding things

- The editor opens on your **wielded weapon**. "Wielded weapon" re-selects it.
- **Search** finds weapon templates, `[explosion]` entries (`ExplosionTemplates`) and
  `[spread]` entries (`SpreadTemplates`).
- A weapon shows its **actions** (action_one, action_two, ...) and their sub-actions, each
  labelled with the damage profile(s) it uses. Other template fields (dodge buffs, ammo,
  block angles, stamina) are under **other template fields**.
- Fields that name something open it right below them: `damage_profile*` fields open the
  profile, `explosion_template` / `aoe` / `aoe_name` open the explosion, and
  `default_spread_template` / `spread_template_override` open the spread template.
- `*` after a name means something below it is edited.

## Editing

- **Numbers** are text fields showing the exact value. A value applies as soon as it parses
  as a number; unfinished input like `0.` or `-` waits.
- **Booleans** are checkboxes. `attack_template`, `boost_curve_type`, `charge_value`, damage
  profile and template-name fields are **dropdowns**. Other text fields need **apply**, so a
  half-typed value is never live.
- Edits apply to the next swing or hit - no re-equip needed - except fields only read when the
  weapon is wielded or spawned (template `buffs` such as dodge and movement, and `ammo_data`).
  Editing those shows a red warning with a **re-equip** button (also in the menu bar and as
  `/we_reequip`). Ammo is kept as a percentage of the new maximum.
- Every edited field shows its **MB** value (as loaded from the files) and its **vanilla**
  value, plus a **revert** button. There are also revert buttons per weapon, per profile, per
  explosion/spread entry, in the **All edits** list, and **Revert all**.
- **Shared presets.** Vanilla profiles share `PowerLevelTemplates` presets (armor modifiers,
  crit, cleave). Editing a field inside one first copies the preset into that profile, so other
  weapons are unaffected. Weapon action tables shared between templates are only flagged
  ("Shared table - edits also change: ..."), because the change files share them too.

### Attack sheet

Opening a damage profile shows the **attack sheet** first: top-level fields
(`charge_value`, `melee_boost_override`, `shield_break`, ...), cleave, then one column per
target plus `default_target`. Rows cover power attack/impact, attack template, boost curve and
coefficients, headshot boost, armor modifiers per armor type (infantry, armored, monster,
player, berserker, super armor) and crit power modifiers. A target without its own
`armor_modifier` shows the profile's. The full raw tree is under **all fields**.

### Structure mode

Tick **structure mode** at the top to add or remove fields and entries:

- Every field gets **x** (remove). Below each table, **+ field** takes a name and a value:
  a number, `true` / `false`, text, or `{}` for an empty table.
- List entries (`targets`, `allowed_chain_actions`, ...) get **dup**, **up**, **down** and **x**,
  and the list gets **+ entry** (a copy of the last entry; an empty `targets` list starts from
  `default_target`, an empty chain action list from a default chain action).
- Removed fields stay listed as "(removed)" with a **revert** button.
- In the attack sheet, "-" cells become **+** (adds the game's default), plus **+ target**,
  **x** per target column and **own armor** / **drop own armor** per column.

### Forking a profile

Under a profile opened from an attack, **fork into a new mb_ profile** copies it under a new
name (suggested `mb_<weapon>_<attack>`) and points **this attack** or **all attacks of this
weapon using it** at the copy. It exports as a new `NewDamageProfileTemplates` block.
**delete fork** points the attacks back and removes it. A fork is also removed automatically
once no attack points at it anymore (e.g. after reverting the edits that pointed attacks at it,
or **Revert all**), so it no longer exports or comes back next session.

### Explosions and spread

- Weapon templates are built with `table.clone`, so each weapon fires its **own copy** of its
  explosion. The immediate blast uses that copy; lingering area damage (and other players)
  use `ExplosionTemplates[name]`. A copy is labelled "own copy of ExplosionTemplates.x" with a
  **link to global** button, which points the weapon at the global entry (as
  `bw_fireball.lua` does by hand). After linking, edits reach both. Linking discards edits made
  inside that weapon's copy.
- Spread templates are read live: edits apply immediately.
- Projectiles are likewise per-weapon copies that nothing looks up by name, so they are edited
  (and exported) under the weapon's action (`projectile_info`), not as a separate entry.

## Breakpoints

Click **breakpoints** on any attack (or `/we_breakpoints`, which starts on the weapon's
first attack). The grid shows, per breed and target index:

    now | MB | vanilla

- **now** = live data with your edits, **MB** = as loaded from the files, **vanilla** = the
  profile the action used before the balance mod. All three use the balance mod's registered
  damage formula and stagger rule (the game's own without registration), so differences come
  only from the weapon data.
- Green = your edit beats the MB value, red = worse.
- Options: your power level or a typed one, difficulty, hit zone (torso/head), crit, stagger
  stacks (by the registered stagger rule, or the game's: ranged counts as at least 1),
  1-5 targets, hits-to-kill or raw damage, and which categories to show: **Trash, Elite,
  Specials, Other, Boss, Lords** (taken from the categories used in `breakpoints.BREEDS`, so a
  new category there gets its own checkbox automatically).
- Cells include your **damage buffs**: talents and properties like Grail Knight's
  first-target perk (target 1 counts as the first hit), melee/2h power-ups and `damage_dealt`.
  The grid recomputes whenever your buffs, power level, weapon, the options or an edit change.
  Conditional buffs only show while active - e.g. Heroism's charged-heavy bonus appears while
  you hold a charged heavy.
- Attacks with `weapon_mode_overrides` (the Bright Wizard scythe) use the profile of the mode
  the weapon starts in (its template's `custom_data`), shown next to the profile name.
- **Combos**: **+ combo** next to **breakpoints** (or **add attack** in the window's combo
  section) appends an attack. The grid then shows the combo repeated in order: hits = attacks
  needed to kill, damage = one pass of the combo. Each step has its own hit zone (torso/head),
  stagger stacks and crit, starting from the options when it's added; the other options
  (power, difficulty, targets, categories) apply to the whole combo. Steps can be moved up or
  removed; "show combo instead of the attack" switches back and forth. A dual-wield attack's
  hands each count as a hit within that attack.
- **hit log**: tick "record hits" to log real hits (damage dealt, stagger multiplier, damage
  buff multiplier, hits to kill). Each hit is checked twice: the damage formula, and the damage
  buff step that runs after it (`apply_buffs_to_damage`). Either disagreeing is flagged in red.
  Without a registered balance mod only the final damage is visible, so the formula check is
  skipped.
  Known gaps: instakill perks (Killing Shot, Murderous Prowess), buffs on the target (poison,
  bleed, balefire, target health), ranged falloff - these show up as mismatches.

## Exporting

`/we_export` (or **Export to clipboard** in the menu) copies Lua grouped by what was edited:

| Edited | Export |
|---|---|
| Weapon fields | One line per field: `Weapons.x... = 0.45 -- vanilla: 0.5` (plus `prev MB:` if the balance mod already changed it) |
| Balance mod profiles (`NewDamageProfileTemplates`) | The whole `NewDamageProfileTemplates.mb_x = { ... }` block to replace the existing one, untouched presets kept as names, every field differing from the vanilla profile it replaced commented, plus a `-- changed:` summary |
| Forks | A new block to add, `-- vanilla:` against the forked profile |
| Vanilla profiles | One line per field, or the whole copied sub-table where a shared preset was copied |
| Explosion / spread entries | `ExplosionTemplates.x... = ...` / `SpreadTemplates.x... = ...` lines; explosion sections note weapons still on their own copy |
| Structural edits | A whole table (added field, rewritten list), `= nil` (removed) or `= ExplosionTemplates.x` (linked) |

Paste each part into the matching weapon change file, rebuild and restart.

## Restarting

Edits and forks are saved, so they survive a crash or restart. At launch the editor compares
each saved edit against what the files now load: edits already in the files are **dropped**,
the rest are **re-applied**. The chat message (and `/we_status`) reports how many of each,
which doubles as a check that a paste landed.

Saved edits are kept per balance mod (by its registered `name`), so edits made for
different balance mods never mix. Edits saved by a balance mod's former built-in editor
(its `legacy_*` registration fields) are moved over once, at the first launch.

## Files

All in `scripts/mods/WeaponEditor/`:

| File | Contents |
|---|---|
| `WeaponEditor.lua` | Mod entry, loads `we_main.lua` |
| `we_main.lua` | Snapshots, balance mod registration, edit registry, copy-on-write, forks, persistence, re-equip, input, commands |
| `we_core.lua` | Shared helpers: paths, value formatting, edit encoding |
| `we_export.lua` | The Lua exporter (key order from the balance mod's registration) |
| `we_ui.lua` | The editor window, attack sheet, structure mode |
| `we_breakpoints.lua` | Breakpoint grid and hit log |
