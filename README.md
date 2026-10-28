# Weapon Editor

In-game Imgui tool for tuning a balance mod's weapons. You edit values while playing, check
breakpoints, then export the changes as Lua to paste into the balance mod's weapon change
files. Every exported value carries a `-- official:` comment.

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

The `-- official:` comments and the breakpoint grid's official column need the weapon tables as
they were before the balance mod changed them:

- **Editor loads first:** it takes the snapshot itself.
- **Balance mod loads first:** the balance mod takes it on the editor's behalf, before any of
  its change files run, into the global `WEAPON_EDITOR_VANILLA_SNAPSHOT` (see below).
- **Neither** (a balance mod without that support, loaded first): chat warns at launch that
  the official comments are wrong. Move Weapon Editor above it in the launcher.

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
		-- only the DoT templates: entries listed in DotTypeLookup or with a sub-buff whose
		-- update_func is "apply_dot_damage" (see dot_templates in TB's dev_tools_support.lua)
		BuffTemplates = deep_copy(dot_templates(), seen),
	},
})
```

A snapshot without `BuffTemplates` still works; DoT templates' official values then show as
nil and chat says so at launch.

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
		patch_notes_markers = { "$BEGIN_MB", "$END_MB" }, -- around each weapon's notes in /we_sweep_weapons
		damage_calculation = do_damage_calculation, -- its own formula, if it replaces the game's
		stagger_multiplier = function (damage_profile, stagger_number, attacker_unit, difficulty_settings, target_index, hit_zone_name, is_critical_strike) ... end,
		stagger_calculation = do_stagger_calculation, -- its own, if it replaces the game's
		add_calculate_damage_observer = function (observer) ... end,      -- hit log, formula step
		add_apply_buffs_to_damage_wrapper = function (wrapper) ... end,   -- hit log, damage buff step
		-- where a former built-in editor saved its edits (moved over once, at the first launch)
		legacy_settings_mod = "MyBalanceMod", legacy_edits_setting = "...", legacy_forks_setting = "...",
	})
end
```

A balance mod without an `on_all_mods_loaded` of its own to call this from can instead leave
the same settings table in the global `WEAPON_EDITOR_BALANCE_MOD` from its support file; the
editor registers it once all mods have loaded. Class Balance does this (its `DevToolsSupport.lua`),
TourneyBalance calls `register_balance_mod` (`debugging/dev_tools_support.lua`).

The rest of this guide uses that example registration: its baseline label is "MB", forks are
named `mb_...` and its profile blocks are `NewDamageProfileTemplates.mb_x`.

## Commands

| Command | What it does |
|---|---|
| `/we` | Open/close the editor window |
| `/we_breakpoints` | Show/hide the breakpoint window |
| `/we_reequip` | Respawn the wielded weapon so wield/spawn-time fields apply |
| `/we_export` | Copy all edits as Lua to the clipboard (also printed to the console log) |
| `/we_export_notes` | Copy a patch-note draft (edits and their notes, as markdown) to the clipboard |
| `/we_status` | List pending edits and notes, and what happened to last session's at launch |
| `/we_revert_all` | Revert every edit to what the balance mod's files load |
| `/we_reset_windows` | Move both windows back on screen (they vanish if dragged outside the game window) |

**F3** switches between using the windows and playing. Using the windows shows the cursor and
blocks game input the way open chat does (no movement, attacks or other mods' keybinds; the
Esc menu and popups still work).
Chat can't be opened while the windows have input, so press F3 before typing a command.

**F2** opens and closes the editor window like `/we` (rebind it under **Mod Options → Weapon Editor → Open/close the editor**;
it works with menus open too).

## Finding things

- The editor opens on your **wielded weapon**. "Wielded weapon" re-selects it.
- **Search** finds weapon templates, `[profile]` entries (`DamageProfileTemplates`),
  `[explosion]` entries (`ExplosionTemplates`), `[spread]` entries (`SpreadTemplates`) and
  `[dot]` entries (the DoT templates of `BuffTemplates`), listed in that order.
- A profile opened from search shows the attacks **used by** it (**open weapon**,
  **breakpoints**), then the same view as under an attack, minus forking.
- A weapon shows its **actions** (action_one, action_two, ...) and their sub-actions, each
  labelled with the damage profile(s) it uses. Other template fields (dodge buffs, ammo,
  block angles, stamina) are under **other template fields**.
- Fields that name something open it right below them: `damage_profile*` fields open the
  profile, `explosion_template` / `aoe` / `aoe_name` open the explosion, and
  `default_spread_template` / `spread_template_override` open the spread template, and a
  profile's `dot_template_name` opens its DoT template.
- After a name (tree node or heading): a yellow `*` means something below it is edited, a blue
  `~` that something below differs from official (the balance mod's changes and your edits).
  Weapon trees roll these up: a sub-action counts the damage profiles it uses, an action its
  sub-actions, and the template heading everything in it.

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
- The windows call the game's own values (the vanilla snapshot) **official**.
- Colors are the same in all fields and the attack sheet: **yellow** = the **MB** value (as
  loaded from the files), **blue** = the **official** value.
  - Edited field: its MB value in yellow and its official value in blue, plus a **revert**
    button (all fields). There are also revert buttons per weapon, per profile, per
    explosion/spread entry, in the **All edits** list, and **Revert all**.
  - Untouched field: its official value in blue wherever the balance mod changed it ("not
    set"/`(none)`: a field the balance mod added). Inside a balance mod profile that's the value
    of the official profile its attacks used; that profile's name shows only where it differs,
    at the attack's damage profile field.
  - The attack sheet shows the bare values after each cell. An edited cell's yellow MB value is
    a button: click it to revert the cell. A long value is cut off by the column; hover over
    it for the full value.
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
- DoT templates (`BuffTemplates` entries such as `burning_dot_1tick`) hold the timing:
  `duration`, `time_between_dot_damages`, `update_start_delay`. Edits apply to DoTs applied
  from then on and export as `BuffTemplates.x...` lines. Tick damage comes from the template's
  `damage_profile`, which opens right below it. The game builds separate copies of some burns at
  load (Necromancer's `_balefire` variants, Pyromancer's infinite burn); the entry names them in
  red, since edits don't reach them.
- Projectiles are likewise per-weapon copies that nothing looks up by name, so they are edited
  (and exported) under the weapon's action (`projectile_info`), not as a separate entry.

### Switching numbers

The **Weapon numbers in game** row under the top bar picks which numbers the game uses, for
comparing a weapon in a live test without editing anything by hand. The current one is in
brackets:

- **official**: the vanilla snapshot
- **MB** (the balance mod's label): its files as loaded
- **MB + edits**: its files plus your edits, the normal mode

Switching swaps the weapon data (`Weapons`, damage profiles, explosions, spread, DoT templates)
for copies of that snapshot and re-equips the wielded weapon, so dodge and movement change too.
Your edits are put aside, not lost, and come back with **MB + edits**. Editing, reverting,
forking, exporting and the weapon sweep only work in that mode: in the other two the window is
read-only, showing the live numbers as text (with official values in blue where they differ)
and no edit, revert, structure, link or fork controls. Notes can still be written. Only weapon data swaps: the
balance mod's talents, traits, buffs and damage formula stay active in every mode. The
breakpoint window's **now** column shows whatever the game is using. A game restart always
starts in **MB + edits**.

## Breakpoints

Click **breakpoints** on any attack (or `/we_breakpoints`, which starts on the weapon's
first attack). The grid shows, per breed and target index:

    now | MB | official

- **now** = live data with your edits, **MB** = as loaded from the files, **official** = the
  profile the action used before the balance mod. All three use the balance mod's registered
  damage formula and stagger rule (the game's own without registration), so differences come
  only from the weapon data.
- Hits to kill show how much of the last hit's damage the kill needs: `2 (73%)` is two hits,
  the second needing only 73% of its damage. 100% is right on the breakpoint (any less damage
  takes another hit); a low % has room to spare.
- Green = your edit beats the MB value, red = worse.
- Options: your power level or a typed one, difficulty, hit zone (torso/head), crit, stagger
  stacks (by the registered stagger rule, or the game's: at most 2 count, ranged counts as at least 1),
  1-5 targets, hits-to-kill or raw damage, **combine dual-wield hands into one attack** (one
  table where each attack hits with both hands, instead of one table per hand; pushes keep
  their inner/outer profiles apart), and which categories to show: **Trash, Elite,
  Specials, Other, Boss, Lords** (taken from the categories used in `breakpoints.BREEDS`, so a
  new category there gets its own checkbox automatically).
- **Simulated buffs** (so you don't need a crafted trinket or a teammate):
  - **extra power %** (both sheets): works like a power buff, added to the ones you have
    (+10 next to Comrades in Arms' +10% gives +20%).
  - **extra damage %** (damage sheet): multiplies the result like a debuff on the enemy
    (Exploit Weakness, Bulwark's 10% debuff), separately from your own damage buffs. Bulwark's
    stagger mark (+1 stagger count) is separate: add it with stagger stacks.
  - **whc tag*** (damage sheet): the tag's damage-taken debuff (+20%), times
    Templar's Knowledge's +5% when you have the talent. TB's extra +25% Templar's Knowledge
    bonus sits inside its damage formula and needs a real target, so add it with extra damage %.
  - **bulwark** (damage sheet): the official Bulwark debuff (`tank_unbalance_buff`), +10% added
    to the stagger damage bonus (also at 0 stacks). For balance mods that still use
    it, such as Class Balance; TB replaced it with a plain 10% debuff (use extra damage %).
  - **extra stagger power %** (stagger sheet): works like Staggering Force / Bulwark,
    added to the ones you have.
  - The active ones are listed in green above the grid.
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
- **Stagger sheet**: the **sheet** dropdown at the top switches the grid to the stagger each
  hit causes, by the game's own stagger calculation (balance mods change stagger only through
  weapon data and buffs, which it reads live, so nothing needs registering):
  - Cells show the tier (`-` none, `W` weak, `M` medium, `H` heavy, `X` explosion, `P` pull)
    and how much of the next tier's threshold the hit reaches: `M 82%` is a medium stagger at
    82% of what heavy needs. "show: strength" gives the raw stagger strength instead. The
    **thresholds** column lists where weak / medium / heavy start for each breed (a push on
    an unstaggered enemy needs double for heavy; the cells account for that).
  - Green/red: a higher/lower tier than the MB value, then more/less strength.
  - **stagger stacks** are the enemy's stacks before the hit; each adds to the hit's stagger
    strength (up to double), so a 3rd still counts on breeds with a low per-stack bonus.
  - **opportunist (enemy attacking)**: the enemy is mid-attack and you have Opportunist. The
    trait only works against attacking enemies; without it equipped, the sheet adds its bonus.
  - With a combo, the stagger sheet has one column per attack (each on target 1), and each step
    gets its own **opportunist** checkbox.
  - The enemy's stacks and attack come from a stand-in for its state, which needs the game's
    `do_stagger_calculation` via `debug.getupvalue`. If that lookup fails, a red line says so
    and the sheet ignores stacks and Opportunist.
  - Not modelled: enemies ignoring staggers during specific attacks (Chaos Warrior overheads
    etc.), boss stagger immunity, repeat-heavy immunity, shield blocks, buffs on the target.
- **hit log**: tick "log damage" and/or "log stagger" to log real hits. Damage: damage dealt, stagger multiplier, damage
  buff multiplier, hits to kill. Each hit is checked twice: the damage formula, and the damage
  buff step that runs after it (`apply_buffs_to_damage`). Either disagreeing is flagged in red.
  Without a registered balance mod only the final damage is visible, so the formula check is
  skipped.
  Known gaps: instakill perks (Killing Shot, Murderous Prowess), buffs on the target (poison,
  bleed, balefire, target health), ranged falloff - these show up as mismatches.
  Stagger ("log stagger"): the real tier and strength next to the stagger sheet's prediction
  for the enemy's actual stacks and whether it was attacking. Expect mismatches where an
  attack has its own stagger rules (ignored staggers, its own stagger reduction) or a breed's
  repeat-heavy immunity kicks in.

## Exporting

`/we_export` (or **Export to clipboard** in the menu) copies Lua grouped by what was edited:

| Edited | Export |
|---|---|
| Weapon fields | One line per field: `Weapons.x... = 0.45 -- official: 0.5` (plus `prev MB:` if the balance mod already changed it) |
| Balance mod profiles (`NewDamageProfileTemplates`) | The whole `NewDamageProfileTemplates.mb_x = { ... }` block to replace the existing one, untouched presets kept as names, every field differing from the official profile it replaced commented, plus a `-- changed:` summary |
| Forks | A new block to add, `-- official:` against the forked profile |
| Vanilla profiles | One line per field, or the whole copied sub-table where a shared preset was copied |
| Explosion / spread / DoT entries | `ExplosionTemplates.x... = ...` / `SpreadTemplates.x... = ...` / `BuffTemplates.x... = ...` lines; explosion sections note weapons still on their own copy |
| Structural edits | A whole table (added field, rewritten list), `= nil` (removed) or `= ExplosionTemplates.x` (linked) |

Paste each part into the matching weapon change file, rebuild and restart.

## Notes

Notes record why a balance edit was made, for dev comments and patch notes.

- **Where:** a **note** button sits next to every edited field and every field that already has
  a note (and next to each edit in the **All edits** list), and next to entry headings - weapon
  template, attack (sub-action), damage profile, explosion/spread/DoT entry. Tick **note mode**
  at the top (next to structure mode) to get it on every other editable field too. **note**
  opens a text box (**save note**, **cancel**, **delete note**); saved notes show in grey under
  what they belong to, and tree nodes with a note below them get a grey `n` (next to `*` and
  `~`).
- **Attack sheet:** edited and noted cells (every cell in note mode) have a compact `n` (`n*`
  with a note; hover to read it). Its text box opens below the sheet.
- **Lifetime:** notes are saved per balance mod like edits, and outlive them: reverting an edit
  keeps its note, and so does the edit landing in the files at launch. A note written before
  its field was edited picks up the edit's starting value once it's edited. Notes without a
  pending edit (landed, reverted, or never edited) show under **Notes without edits** (and chat
  says how many at launch) until you delete them - export the patch notes first. In the
  patch-note draft, a note on a field that was never edited is a bullet of its own.
- **In `/we_export`:** each note prints as `-- note:` lines above what it belongs to: an entry
  note above the entry's first line, an attack's note above its first edit (or next to its
  "used by" line in a damage profile section), a field note above the field, inside whole
  profile blocks too.
- **Patch-note draft** (`/we_export_notes` or **Export patch notes** in the menu): markdown in
  the style of TourneyBalance's `$BEGIN_TB` patch notes, to tidy up and paste:

      ## Weapons
      **two_handed_halberds_template_1**

      *the weapon's note*
      *action_one.heavy_attack_left: the attack's note*
      * action_one.heavy_attack_left: Increased damage_profile to tb_x (from heavy_slashing). the field's note

  One heading per weapon (its template name), a bullet per change with
  "Increased/Reduced/Changed ... to X (from Y)", "Added" or "Removed". "from" is the MB value
  before the edit; for a note whose edit already landed, the value it remembered when written.
  Damage profile changes are listed under every weapon whose attacks use the profile, once per
  attack, so every line names a single attack and two patches' drafts diff line by line. Explosions, spread and DoTs get their own headings under `## Other`.

## Restarting

Edits, forks and notes are saved, so they survive a crash or restart. At launch the editor compares
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
| `we_diff.lua` | What changed: edit lookup, official values and differences, the tree roll-ups the window's `*` / `~` markers come from |
| `we_breakpoints.lua` | Breakpoint grid (damage and stagger sheets) and hit log |
| `we_predict.lua` | Damage and stagger prediction for the grid and hit log, simulated buffs |
