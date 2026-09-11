# blox-scripts

Blox Fruits automation + diagnostics. Built and tested against **Update 30**, executor **Solara**.

All commands below are copy-paste ready. Every URL carries `?cb=` .. `tick()` to defeat
GitHub's CDN cache and the executor's own HttpGet cache — without it you can silently run
an old version.

---

## Quick start

Just want to farm? Run this one line, then use the panel buttons.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/farm_pro.lua?cb=" .. tick()))()
```

---

## Scripts

### `farm_pro.lua` — main farm ✅

The one to use. Six tabs, everything toggleable in game, no console needed.

**Run**
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/farm_pro.lua?cb=" .. tick()))()
```

**Stop**
```lua
_G.BFP.stop()
```
…or press **STOP** on the panel. **CLOSE** stops it *and* closes the panel.

#### The tabs

**FARM**

| Control | Does |
|---|---|
| `START` / `STOP` | Toggle the loop |
| `ANY ENEMY` | Kills whatever is loaded nearby. Never travels. |
| `BY LEVEL` | Picks the enemy matching your level and travels there. |
| `< PREV` / `NEXT >` | Cycle the enemy types currently streamed in |
| `ADD` | Add that type to the selection (multi-select) |
| `ONLY THIS` | Clear the selection and farm just that one |
| `FARM SELECTED` | Farm every added type at once |
| `FARM TYPED` | Type names yourself, comma separated — works for enemies not yet loaded |
| `ROTATE` | **One type at a time** (default) or all at once |
| `CENTRE` | Move to the current type's own centre before fighting it |
| `NEXT TYPE` | Skip to the next selected type now |
| secs per type | How long one type gets before rotating |

**One type at a time.** Selecting Snow Bandit *and* Snowman does not mean dragging both
species into one pile — they live in different parts of the island, each has its own leash,
and a mixed pile is mostly enemies that cannot be hurt. The farm works Snow Bandit to
exhaustion at the Snow Bandit centre, then moves to the Snowman centre and works those.
The centre is computed from where each enemy was *first seen*, so it is the species' real
ground rather than a point skewed by enemies a previous pull already moved. The magnet
follows the focused type too — the other selected species are left alone until their turn.

**COMBAT** — attack mode (`SKILLS` / `M1` / `BOTH` / `M1HOLD`), weapon picker from your
live backpack, per-key skill toggles (Z X C V F — turn off what you have not unlocked),
swing gap, skill frequency.

**MOVE**

| Control | Does |
|---|---|
| `ANTI-GRAVITY` | Re-pins your height every frame. **On by default.** Off = you sink between attacks and melee NPCs reach you. |
| `HOLD HERE` | Freeze at your exact current position |
| `RELEASE` | Let go of the hold |
| hover height / boss hover / secs per target | Steppers |
| attack tilt | Pitch while attacking from above. Straight down puts the enemy behind the swing arc; tilt aims into it. |
| `MAGNET` | Drags enemies to you and holds them in weapon range |
| `ALL TYPES` | Magnet grabs every enemy, or only your selected names |
| magnet range / distance / max | How far it reaches, how far in front they sit, how many at once |
| **leash radius** | **The cap that keeps a pulled enemy damageable.** See below. |
| `GO TO PACK` | Moves you to the spot that can legally gather the most enemies |
| `PULL` | Older variant — stacks them *under* you instead of in front |

**The leash.** Every Blox Fruits NPC belongs to an area and stops taking damage once
dragged outside it. A magnet strong enough to reach across the map pulls them past that
limit — they arrive, and your hits do nothing. So the magnet now refuses any move that
would take an enemy further than `leash radius` from where it was found, and the MOVE tab
reports `held N | left alone (outside their area) N`. If a lot are being left alone, press
`GO TO PACK` — it repositions you to where the most enemies can be gathered legally.

**QUEST** — `TAKE QUEST NOW` walks to the giver and presses **E** (key events are the
only input path that reaches this game). `SCAN` lists the nearest NPCs, their distance,
and which quest signal each carries. `PROBE NEAREST NPC` dumps that NPC's full structure
to the panel and clipboard.

**QUEST GIVER NAME.** Givers are ordinary NPCs with island-specific names — `Adventurer`
in the Jungle, `Villager` in the snow village. Type the exact name and press `USE NAME`
and it becomes unmissable: an exact name outscores every other signal. Leave it blank and
detection falls back to the "?" QUEST billboard. A few names are built in already.

With `AUTO` on, a quest is re-taken as soon as the previous one finishes, and never while
one is active. With `AUTO` off nothing is ever taken — the right setting for a spot with
no quest.

`START QUEST DIRECTLY` skips the NPC entirely — type a quest name (`JungleQuest`), pick a
tier, press it. Leave the box empty and it looks the name up from the enemy you are
farming. This is the reliable path: no walking, no dialog, no clicking.

Quest givers carry **no ClickDetector and no ProximityPrompt** — the "E Interact" ring is
Blox Fruits' own proximity UI. Scanning for interactables found ziplines and campfires and
missed the giver standing in front of you. Detection is now the "?" QUEST billboard above
their head, which is the same signal the player uses.

**TRAVEL** — the fast-travel from `teliport.txt`, built in. Cycle the server's spawn
points or type a name, press `TRAVEL`. `FORCE RESPAWN` re-sends your team. Farming pauses
during the respawn and resumes on arrival.

Spawn names are **exact and case sensitive** — `middle town` is not `Middle Town`, and the
server silently ignores a name it does not know, which looks identical to the teleport
failing: you respawn where you already were. Typed names are now resolved against the real
spawn list first, and the panel reports what the server answered plus how far you actually
moved, ending in `<< DID NOT MOVE` when the spawn was rejected.

**INFO** — every counter: kills, kills/min, damage hits, swings, magnet count, weapon,
mode, hover, anti-grav state, level, health, escalations, travels, retreats, seconds
since the last damage landed.

#### Commands

```lua
_G.BFP.start()                       -- same as BY LEVEL
_G.BFP.start(nil, {anyEnemy = true}) -- same as ANY ENEMY
_G.BFP.start({"Swan Pirate"})        -- one specific enemy
_G.BFP.start({"Swan Pirate", "Factory Staff"})  -- several
_G.BFP.travelTo("Middle Town")       -- fast travel
_G.BFP.spawnList()                   -- every spawn name for your team
_G.BFP.questScan(300)                -- what the quest scan can see
_G.BFP.questProbe()                  -- dump the nearest NPC's structure
_G.BFP.takeQuest()                   -- walk to the giver, press E, accept
_G.BFP.startQuest("JungleQuest", 2)  -- ask the server directly
_G.BFP.startQuestForTarget()         -- look it up from what you are farming
_G.BFP.packCentre()                  -- where the most enemies can be gathered
_G.BFP.stats()                       -- kills, swings, escalations
_G.BFP.config.HoverHeight = 20       -- live tuning, every CFG key works
_G.BFP.config.Magnet = true
_G.BFP.config.LeashRadius = 150      -- live, like every other CFG key
_G.BFP.config.AttackTilt = -45
_G.BFP.config.RotateTypes = false    -- fight every selected type together
_G.BFP.config.QuestGiverName = "Adventurer"
_G.BFP.nextType()                    -- skip to the next type now
```

**Reading the panel** — `weapon:` must show your **sword** or **Combat**, never
`Light-Light`. A fruit fires fruit moves on M1, not melee. `last progress` counts seconds
since the last damage landed; if it climbs past 7 the escalation ladder kicks in and `esc`
increments.

---

### `attacktest.lua` — which attack actually lands ✅

Stand next to a live enemy, run it, wait ~30 seconds. It tries nine attack methods one at
a time and watches that enemy's Health after each, then names the winner. This is how the
farm's attack method was chosen instead of guessed.

**Run**
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/attacktest.lua?cb=" .. tick()))()
```

**Stop** — finishes on its own. Press **CLOSE** to dismiss the panel.

Measured results on Solara: every mouse path (VirtualUser Button1, VirtualInputManager
mouse click, `Tool:Activate`) dealt **zero**. Only `VirtualInputManager:SendKeyEvent`
landed — Light-Light `Z` 170, Combat `Z` 33, Pipe `Z` 28.

---

### `probe3.lua` — game + executor snapshot ✅

Read-only. Runs once, renders an on-screen panel, copies everything to clipboard.
Use when something behaves oddly and you want facts.

**Run**
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/probe3.lua?cb=" .. tick()))()
```

**Stop** — nothing to stop; it finishes on its own. Press **CLOSE** to dismiss the panel.

Reports: executor capabilities, PlayerScripts contents, weapon list and attributes,
enemy shape, streaming state, remotes.

---

### `tracker.lua` — live remote/respawn monitor ⚠️

Logs `CommF_` calls with return values, deaths, respawns, streaming window changes.

**Run**
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/tracker.lua?cb=" .. tick()))()
```

**Stop** — important, this one installs a hook:
```lua
_G.BFT.stop()
```

**Extra commands**
```lua
_G.BFT.testSpawn("Middle Town")  -- test a spawn WITHOUT dying
_G.BFT.spawns()                  -- list every spawn name
_G.BFT.dump()                    -- print + copy the full log
```

⚠️ On Solara the `__namecall` hook catches little or nothing — Blox Fruits caches its remote
method references, bypassing the metamethod. `testSpawn` and `spawns` still work, since
they need no hook.

---

### `sniffer.lua` — outbound remote logger ❌

Intended to capture the attack call by watching traffic. **Does not work on Solara** —
`calls 0`, same `__namecall` bypass as above. Kept for reference.

**Run**
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/sniffer.lua?cb=" .. tick()))()
```

**Stop**
```lua
_G.SNIFF.stop()
```

---

### `solo_farm_v2.lua` — original, superseded ❌

Combat is broken: it uses `Tool:Activate()`, which Blox Fruits ignores. It walks to an
enemy and stands there. Travel, island data and quest tables are sound; combat is not.

**Run**
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/solo_farm_v2.lua?cb=" .. tick()))()
```

**Stop** — press the **X / STOP** button on its own panel. There is no global stop function.

⚠️ **Never run this at the same time as `farm_pro.lua`.** Both drive your character and they
will fight each other.

---

### `probe.lua`, `probe2.lua` — superseded ❌

`probe.lua` works but its capability check is unreliable (used `rawget`, which skips the
`__index` chain, so it reported false FAILs). `probe2.lua` produces no output on a
console-less executor. **Use `probe3.lua` instead.**

---

## How stopping actually works

**Closing the Solara tab does NOT stop a running script.** Once you press Execute, the Lua
runs inside the Roblox client, not inside Solara. The editor is just a text box.

Three ways to stop something, weakest to strongest:

1. The script's own stop function — `_G.BFP.stop()`, `_G.BFT.stop()`, `_G.SNIFF.stop()`
2. The **X** button on its panel
3. **Rejoin the server** — fresh client, fresh Lua VM, everything dies. The guaranteed reset.

If behaviour is confusing and you're not sure what's still running, rejoin. It costs 20
seconds and removes all doubt.

---

## Solara notes

- **No console.** `print()` output is invisible. Every script here renders to an on-screen
  panel and writes to the clipboard instead.
- **F9** opens Roblox's own developer console, which *does* show `print`/`warn` — including
  error messages. Useful when a script does nothing.
- **Capabilities present:** `getreg`, `getrawmetatable`, `setreadonly`, `getnamecallmethod`,
  `newcclosure`, `fireclickdetector`, `firetouchinterest`, `queue_on_teleport`,
  `setclipboard`, `getloadedmodules`, `sethiddenproperty`
- **Capabilities missing:** `getgc`, `getupvalues`, `debug.getupvalues`, `getsenv`,
  `hookfunction`, `hookmetamethod`, `getconnections`

The missing ones are why the no-animation fast attack isn't available here — it needs
upvalue access to reach the combat controller.

---

## Known limits

**No fast attack.** Update 30 removed `CombatFramework` from `PlayerScripts`, so every
published fast-attack script targets a module that no longer exists. Solara also lacks the
upvalue access those scripts need. Attacks run at normal speed with the animation visible.

**M1 cannot be simulated.** Six different click paths were measured against a live enemy
and every one dealt zero damage, at point blank as well as at hover height. The click
never reaches Blox Fruits' combat handler, so this is not a range problem and widening the
hitbox would not help. **MAGNET is the answer to reach**: rather than making the swing
longer, it drags the enemy into the swing. `M1HOLD` mode holds the button down across
frames instead of clicking — untested, worth one try.

**Streaming window is small.** Only ~5–10 enemies load at a time. The client cannot see
chests or enemies on islands you aren't near — they don't exist client-side until you
travel. This is why "it can't find the far chest" is a visibility problem, not a distance
problem.

**Teleport is not 100% reliable.** `SetLastSpawnPoint` occasionally gets rejected by the
server, and the travel code destroys your character *before* checking. Use
`_G.BFT.testSpawn(name)` to test a spawn without dying.

---

## If something goes wrong

| Symptom | Do this |
|---|---|
| Script does nothing, no panel | Press **F9**, read the red error line |
| Character flies into the sky | Old cached version — re-run with `?cb=` |
| `weapon: Light-Light` on the panel | It grabbed the fruit; make sure a sword is in your backpack |
| `kills 0`, `esc` climbing | Attacks aren't landing — send me the status line |
| Two scripts fighting | Rejoin the server |
| Loading fails silently | Use the diagnostic loader below |

**Diagnostic loader** — reports which stage failed instead of dying silently:

```lua
local url = "https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/farm_pro.lua?cb=" .. tick()
local ok, src = pcall(game.HttpGet, game, url)
if not ok then return warn("FETCH FAILED: " .. tostring(src)) end
print("fetched " .. #src .. " bytes")
local fn, err = loadstring(src)
if not fn then return warn("COMPILE ERROR: " .. tostring(err)) end
local ran, runErr = pcall(fn)
if not ran then warn("RUNTIME ERROR: " .. tostring(runErr)) end
```

Swap the filename in the URL to test any other script.
