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

The one to use. Hovers above enemy clusters, attacks, never silently stalls.

**Run**
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/JodLHarDxD/blox-scripts/main/farm_pro.lua?cb=" .. tick()))()
```

**Stop**
```lua
_G.BFP.stop()
```
…or press **STOP** on the panel. **X** stops it *and* closes the panel.

**Panel buttons**

| Button | Does |
|---|---|
| `ANY ENEMY` | Kills whatever is loaded nearby. Never travels. Try this first. |
| `BY LEVEL` | Picks the enemy matching your level and travels there. |
| `START` / `STOP` | Toggle |
| `X` | Stop + close |

**Optional commands**
```lua
_G.BFP.start()                       -- same as BY LEVEL
_G.BFP.start(nil, {anyEnemy = true}) -- same as ANY ENEMY
_G.BFP.start({"Swan Pirate"})        -- one specific enemy
_G.BFP.start({"Swan Pirate", "Factory Staff"})  -- several
_G.BFP.stats()                       -- kills, swings, escalations
_G.BFP.config.HoverHeight = 20       -- live tuning
```

**Reading the panel** — `weapon:` must show your **sword** or **Combat**, never `Light-Light`.
A fruit fires fruit moves on M1, not melee. `last progress` counts seconds since the last
damage landed; if it climbs past 7 the escalation ladder kicks in and `esc` increments.

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
