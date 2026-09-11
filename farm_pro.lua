--[[
    BLOX FRUITS FARM PRO
    ====================
    Built to never silently stall. Every state has a timeout, every failure has
    an escalation, and the HUD always shows WHY it is doing what it is doing.

    WHAT WAS WRONG BEFORE
      * solo_farm_v2 used Tool:Activate(), which Blox Fruits ignores -> walked
        to the enemy and stopped. Confirmed in the field.
      * It fought on the ground, so enemies hit back and pathing fought terrain.
      * Specific Farm accepted one enemy name, but an island has several types.
      * A failing target was retried forever with no escape hatch.

    HOW THIS ONE WORKS
      STATE MACHINE : RESOLVE -> TRAVEL -> ENGAGE, each with a hard timeout.
      WATCHDOG      : tracks cluster health. No damage for StuckSeconds triggers
                      an escalation ladder (reanchor -> re-equip -> reinstall
                      fast attack -> blacklist target -> travel). It cannot sit
                      still doing nothing.
      MULTI-TARGET  : farms a SET of enemy names. Quest enemy is preferred, any
                      other loaded enemy is a valid fallback for EXP.
      HOVER         : direct CFrame write plus per-frame velocity injection.

    CONTROL
        _G.BFP.start()                      -- auto: pick enemies from your level
        _G.BFP.start({"Swan Pirate"})       -- explicit target set
        _G.BFP.start(nil, {anyEnemy=true})  -- kill anything loaded (max EXP)
        _G.BFP.stop()
        _G.BFP.config
]]

if _G.BFP and _G.BFP.stop then pcall(_G.BFP.stop) end

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local VIM         = game:GetService("VirtualInputManager")
local player      = Players.LocalPlayer

-- =========================================================
-- CONFIG
-- =========================================================
local CFG = {
    HoverHeight        = 14,  -- Z lands at 14; high enough that melee NPCs cannot reach
    BossHoverHeight    = 22,
    ClusterRange       = 260,
    ReanchorDistance   = 30,

    -- "M1"     : left click only (default)
    -- "SKILLS" : cycle SkillKeys only
    -- "BOTH"   : M1 every swing, a skill every SkillEvery-th swing
    -- Switch live:  _G.BFP.config.AttackMode = "SKILLS"
    AttackMode         = "SKILLS",  -- M1 measured as zero damage on Solara
    SkillEvery         = 4,
    -- Only list skills you have actually UNLOCKED. Pressing a locked key
    -- burns a cycle slot and deals nothing.
    SkillKeys          = { Enum.KeyCode.Z, Enum.KeyCode.X },
    -- Exact tool name to force-equip, e.g. "Light-Light" or "Pipe".
    -- nil = pick automatically (highest measured damage first).
    ForceWeapon        = nil,

    HitboxMagnitude    = 150,
    ComboIncrement     = 4,
    AttackHold         = 0.04,
    AttackGap          = 0.05,

    StuckSeconds       = 7,      -- no cluster damage for this long -> escalate
    MaxEscalation      = 4,
    EngageTimeout      = 120,    -- hard cap on one engagement
    TravelTimeout      = 45,
    TargetTimeout      = 25,   -- max seconds on one enemy before moving on

    MinHealthPercent   = 0.30,
    RetreatHeight      = 200,
    RegenWait          = 5,

    AutoQuest          = false,  -- DANGER: re-invoking StartQuest resets
                                 -- an active quest's kill count to zero.
                                 -- Accept quests by hand.
    QuestRetrySeconds  = 45,

    -- ENEMY PULL
    -- Roblox hands the nearest player network ownership of unanchored NPCs,
    -- so their CFrame can be written from the client and it replicates. That
    -- is how enemies get stacked under you and held there.
    PullEnemies        = false,  -- toggle with the PULL button
    PullRange          = 170,    -- gather targets within this radius
    PullRadius         = 7,      -- how tightly they are stacked
    PullDrop           = 10,     -- studs BELOW you they are held

    -- MAGNET
    -- There is no way to widen the M1 hitbox on this executor, so instead of
    -- reaching further we drag the enemy into range. Same result, and it works
    -- on every weapon. Held every Heartbeat because the server fights it.
    Magnet             = false,
    MagnetRange        = 5000,   -- whole loaded map; streaming caps it anyway
    MagnetDistance     = 6,      -- studs in FRONT of you they are stacked
    MagnetDrop         = 2,      -- studs below your root
    MagnetMax          = 40,     -- cap the stack so the client does not choke
    MagnetAllTypes     = true,   -- false = only your selected enemy names

    -- ALTITUDE
    -- Hovering sinks between attacks because a one-shot CFrame write is undone
    -- by physics within a frame. Holding it means re-asserting every Heartbeat.
    HoldAltitude       = true,

    AnyEnemyFallback   = true,   -- if quest enemies absent, hit whatever is loaded
    Debug              = false,
}

local P = { running = false, config = CFG }
_G.BFP = P

-- =========================================================
-- LEVEL -> ENEMY -> LOCATION
-- =========================================================
local LEVELS = {
    {1,9,"Bandit",Vector3.new(1059.4,16.5,1546.6)},
    {10,14,"Monkey",Vector3.new(-1445.1,23.5,-48.8)},
    {15,29,"Gorilla",Vector3.new(-1119.8,40.5,1839.0)},
    {30,39,"Pirate",Vector3.new(-1181.3,4.5,3803.5)},
    {40,59,"Brute",Vector3.new(-1145.2,14.8,4321.7)},
    {60,74,"Desert Bandit",Vector3.new(932.2,6.5,4482.0)},
    {75,89,"Desert Officer",Vector3.new(1609.1,6.5,4369.8)},
    {90,99,"Snow Bandit",Vector3.new(1386.8,87.3,-1297.1)},
    {100,119,"Snowman",Vector3.new(1198.2,105.5,-1237.0)},
    {120,149,"Chief Petty Officer",Vector3.new(-4881.1,4.5,4257.4)},
    {150,174,"Sky Bandit",Vector3.new(-4841.7,717.8,-2666.9)},
    {175,189,"Dark Master",Vector3.new(-5217.1,12.5,-4836.7)},
    {190,209,"Prisoner",Vector3.new(5309.8,0.5,475.5)},
    {210,249,"Dangerous Prisoner",Vector3.new(5086.1,2,466.4)},
    {250,274,"Toga Warrior",Vector3.new(-3625.0,7.5,-3003.7)},
    {275,299,"Gladiator",Vector3.new(-1309.9,7.5,-3251.6)},
    {300,324,"Military Soldier",Vector3.new(-5316.2,12.5,-2842.5)},
    {325,374,"Military Spy",Vector3.new(-5815.4,84.5,-8972.3)},
    {375,399,"Fishman Warrior",Vector3.new(61122.7,18.5,1569.1)},
    {400,449,"Fishman Commando",Vector3.new(61922.6,18.5,1493.9)},
    {450,474,"God's Guard",Vector3.new(-4721.9,845.3,-1954.4)},
    {475,524,"Shanda",Vector3.new(-7685.1,5567.8,-502.1)},
    {525,549,"Royal Squad",Vector3.new(-7665.2,5839.5,-1818.8)},
    {550,624,"Royal Soldier",Vector3.new(-7836.8,5607.8,-1540.5)},
    {625,649,"Galley Pirate",Vector3.new(5551.0,42.5,3946.3)},
    {650,699,"Galley Captain",Vector3.new(5436.0,38.5,4757.8)},
    {700,724,"Raider",Vector3.new(-728.3,16.5,2345.9)},
    {725,774,"Mercenary",Vector3.new(-972.5,73.0,1419.1)},
    {775,799,"Swan Pirate",Vector3.new(1036.5,125.0,1321.8)},
    {800,874,"Marine Commodore",Vector3.new(-3855.7,73.0,-3295.8)},
    {875,899,"Magma Ninja",Vector3.new(-5426.3,12.0,-5769.7)},
    {900,949,"Lava Pirate",Vector3.new(-5234.4,12.0,-4898.6)},
    {950,974,"Head Baker",Vector3.new(-2088.0,38.0,-12464.8)},
    {975,999,"Dark Master",Vector3.new(-2088.9,38.0,-12488.7)},
    {1000,1049,"Ice Admiral",Vector3.new(-5520.3,12.0,-5235.2)},
    {1050,1099,"Tide Keeper",Vector3.new(-3711.3,123.0,-11208.9)},
    {1100,1124,"Forest Pirate",Vector3.new(-13479.6,332.4,-7625.4)},
    {1125,1174,"Mythological Pirate",Vector3.new(-13545.2,470.0,-6917.2)},
    {1175,1199,"Jungle Pirate",Vector3.new(-12073.2,332.4,-10141.2)},
    {1200,1249,"Musketeer Pirate",Vector3.new(-13274.5,332.4,-7896.7)},
    {1250,1274,"Reborn Skeleton",Vector3.new(-8760.8,142.1,6062.5)},
    {1275,1299,"Living Zombie",Vector3.new(-10144.8,139.0,5932.9)},
    {1300,1324,"Demonic Soul",Vector3.new(-9513.9,172.1,6145.7)},
    {1325,1349,"Posessed Mummy",Vector3.new(-9546.7,6.0,6336.5)},
    {1350,1374,"Peanut Scout",Vector3.new(-2104.0,38.0,-10192.3)},
    {1375,1399,"Peanut President",Vector3.new(-2150.5,38.0,-10194.6)},
    {1400,1424,"Ice Cream Chef",Vector3.new(-641.2,38.0,-12824.0)},
    {1425,1449,"Ice Cream Commander",Vector3.new(-789.9,65.9,-10967.3)},
    {1450,1474,"Cookie Crafter",Vector3.new(-2365.4,38.0,-12099.5)},
    {1475,1499,"Cake Guard",Vector3.new(-1570.3,38.0,-12355.9)},
    {1500,1524,"Baking Staff",Vector3.new(-1927.2,38.0,-12850.9)},
    {1525,1574,"Head Baker",Vector3.new(-2088.0,38.0,-12464.8)},
    {1575,1599,"Cocoa Warrior",Vector3.new(231.8,25.0,-12197.5)},
    {1600,1624,"Chocolate Bar Battler",Vector3.new(620.6,25.0,-12619.6)},
    {1625,1649,"Sweet Thief",Vector3.new(2433.6,25.0,-12225.7)},
    {1650,1699,"Candy Rebel",Vector3.new(2519.2,25.0,-11847.6)},
    {1700,1724,"Candy Pirate",Vector3.new(-1106.6,11.6,-14204.9)},
    {1725,1774,"Snow Demon",Vector3.new(-5412.5,12.0,-5269.2)},
    {1775,1799,"Isle Outlaw",Vector3.new(-5622.0,8.0,-276.5)},
    {1800,1849,"Island Boy",Vector3.new(-4898.4,8.0,-185.5)},
    {1850,1899,"Sun-Kissed Warrior",Vector3.new(-2010.8,38.0,-10194.5)},
    {1900,1924,"Cave Dweller",Vector3.new(-2104.0,38.0,-10192.3)},
    {1925,1974,"Magma Ninja",Vector3.new(-5426.3,12.0,-5769.7)},
    {1975,1999,"Lava Pirate",Vector3.new(-5234.4,12.0,-4898.6)},
    {2000,2024,"Tide Keeper",Vector3.new(-3711.3,123.0,-11208.9)},
    {2025,2049,"Fishman Raider",Vector3.new(-10533.2,332.0,-8788.5)},
    {2050,2074,"Fishman Captain",Vector3.new(-10961.0,332.0,-8940.5)},
    {2075,2099,"Forest Pirate",Vector3.new(-13479.6,332.4,-7625.4)},
    {2100,2124,"Jungle Pirate",Vector3.new(-12073.2,332.4,-10141.2)},
    {2125,2149,"Sea Soldier",Vector3.new(-5850.8,16.0,-285.3)},
    {2150,2199,"Ship Deckhand",Vector3.new(1232.9,125.0,33059.2)},
    {2200,2224,"Ship Engineer",Vector3.new(919.0,44.0,32917.4)},
    {2225,2249,"Ship Steward",Vector3.new(915.4,126.0,33518.1)},
    {2250,2299,"Ship Officer",Vector3.new(915.4,181.0,33331.8)},
    {2300,2324,"Arctic Warrior",Vector3.new(5823.5,23.7,-6302.3)},
    {2325,2349,"Snow Lurker",Vector3.new(5518.8,28.0,-6859.6)},
    {2350,2374,"Sea Soldier",Vector3.new(-5850.8,16.0,-285.3)},
    {2375,2399,"Haunted Castle",Vector3.new(-9515.8,142.0,5543.9)},
    {2400,2450,"Isle Champion",Vector3.new(5283.7,51.5,1036.2)},
}

-- =========================================================
-- STATE
-- =========================================================
local stats = {
    kills = 0, swings = 0, reanchors = 0, retreats = 0,
    escalations = 0, travels = 0, damaging = 0, pulled = 0, startedAt = 0,
}

local conns = {}
local function track(c) table.insert(conns, c) return c end

local state          = "BOOT"
local stateEnteredAt = 0
local statusLine     = "starting"
local escalation     = 0
local lastProgressAt = 0
local lastClusterHP  = nil
local anchor         = nil
local blacklist      = {}          -- model -> expiry clock
local countedDead    = {}          -- model -> clock, so a corpse counts once
local targetNames    = nil         -- set of names, or nil = any
local activeNames    = nil         -- resolved target set (hoisted: pullStep reads it)
local anyEnemyMode   = false
local travelGoal     = nil

local function log(m) if CFG.Debug then print("[BFP] " .. tostring(m)) end end

local function setState(s)
    if state ~= s then
        state = s
        stateEnteredAt = os.clock()
        log("state -> " .. s)
    end
end

local function say(s) statusLine = tostring(s) end

local function progress()
    lastProgressAt = os.clock()
    if escalation > 0 then
        escalation = 0
        log("escalation reset")
    end
end

-- =========================================================
-- CHARACTER
-- =========================================================
local function parts()
    local char = player.Character
    if not char or not char:IsDescendantOf(workspace) then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if root and hum and hum.Health > 0 then return char, root, hum end
    return nil
end

local function healthPct()
    local _, _, hum = parts()
    if not hum or hum.MaxHealth <= 0 then return 1 end
    return hum.Health / hum.MaxHealth
end

local function playerLevel()
    for _, container in ipairs({ player:FindFirstChild("Data"), player:FindFirstChild("leaderstats") }) do
        if container then
            local lv = container:FindFirstChild("Level")
            if lv and lv.Value then return math.floor(lv.Value) end
        end
    end
    return nil
end

-- Weapon choice decides whether anything lands at all. A Devil Fruit fires
-- fruit moves on M1, and the mobile ConsoleTool is not a weapon, so neither
-- can be left equipped. Melee tools carry WeaponType="Melee".
-- Ranked by MEASURED damage on this account, not by assumption:
--   Demon Fruit 170 >> Melee 33 > Sword 28
local function scoreTool(t)
    if CFG.ForceWeapon and t.Name == CFG.ForceWeapon then return 1000 end
    if t:GetAttribute("ConsoleTool") then return -1 end      -- mobile button
    local wt = t:GetAttribute("WeaponType")
    if wt == "Demon Fruit" then return 120 end
    if wt == "Melee" then return 60 end
    if wt == "Sword" then return 50 end
    if wt ~= nil then return 20 end                          -- gun, etc.
    return 0
end

local function bestTool()
    local char = player.Character
    local bp = player:FindFirstChildOfClass("Backpack")
    local best, bestScore = nil, -math.huge
    for _, src in ipairs({ char, bp }) do
        if src then
            for _, t in ipairs(src:GetChildren()) do
                if t:IsA("Tool") then
                    local s = scoreTool(t)
                    if s > bestScore then best, bestScore = t, s end
                end
            end
        end
    end
    return best, bestScore
end

local function equipWeapon()
    local char = player.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return false end

    local want = bestTool()
    if not want then return false end

    local held = char:FindFirstChildOfClass("Tool")
    if held == want then return true end

    -- Put the wrong tool away before equipping, or EquipTool can no-op.
    if held then pcall(function() hum:UnequipTools() end) end
    pcall(function() hum:EquipTool(want) end)
    return true
end

-- =========================================================
-- FAST ATTACK
-- =========================================================
local fastOn, fastConn, ctrlRef = false, nil, nil

local function installFastAttack()
    if fastConn then pcall(function() fastConn:Disconnect() end) fastConn = nil end
    fastOn, ctrlRef = false, nil

    local env      = (getgenv and getgenv()) or {}
    local getreg_  = getreg or env.getreg
    local getupv   = (debug and debug.getupvalues) or env.getupvalues
    if not getreg_ or not getupv then
        say("fast attack unavailable (no getreg/getupvalues)")
        return false
    end

    pcall(function()
        local util = RS:FindFirstChild("Util")
        local shaker = util and util:FindFirstChild("CameraShaker")
        if shaker then
            local mod = require(shaker)
            if mod and mod.Stop then mod:Stop() end
        end
    end)

    local scripts = player:FindFirstChild("PlayerScripts")
    local combatScript = scripts and scripts:FindFirstChild("CombatFramework")
    if not combatScript then
        say("fast attack unavailable (CombatFramework missing)")
        return false
    end

    local found
    pcall(function()
        for _, v in pairs(getreg_()) do
            if typeof(v) == "function" then
                local okE, fenv = pcall(getfenv, v)
                if okE and fenv and rawget(fenv, "script") == combatScript then
                    local okU, ups = pcall(getupv, v)
                    if okU and ups then
                        for _, up in pairs(ups) do
                            if typeof(up) == "table" and rawget(up, "activeController") ~= nil then
                                found = up
                                return
                            end
                        end
                    end
                end
            end
        end
    end)

    if not found then
        say("fast attack unavailable (activeController not found)")
        return false
    end

    ctrlRef = found
    local NEG = -(math.huge ^ math.huge ^ math.huge)
    fastConn = track(RunService.RenderStepped:Connect(function()
        if not fastOn then return end
        pcall(function()
            local ac = ctrlRef.activeController
            if not ac then return end
            ac.timeToNextAttack   = NEG
            ac.attacking          = false
            ac.blocking           = false
            ac.increment          = CFG.ComboIncrement
            ac.hitboxMagnitude    = CFG.HitboxMagnitude
            ac.focusStart         = 0
            ac.currentAttackTrack = 0
        end)
    end))
    fastOn = true
    return true
end

-- =========================================================
-- MOVEMENT
-- =========================================================
-- Movement is lifted from chest_finder_v2, which locates and reaches its
-- target reliably. Two things make it work, and farm_pro had neither:
--   * collisions off + AutoRotate off, re-applied every PHYSICS step
--   * velocity zeroed every Heartbeat
-- Roblox re-asserts both continuously, so a one-shot write is always undone.
local TweenService = game:GetService("TweenService")

local savedCollide = {}
local stabConns = {}

-- Hoisted: the stabilizer's Heartbeat closure reads both of these, and it is
-- created before the movement code further down.
local activeTween = nil
local holdCF      = nil     -- CFrame re-asserted every frame while set

local function killVelocity(root)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function stabilize()
    local char, root, hum = parts()
    if not char or not root or not hum then return end
    hum.AutoRotate = false
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            if savedCollide[part] == nil then savedCollide[part] = part.CanCollide end
            part.CanCollide = false
        end
    end
    killVelocity(root)
end

-- The anti-gravity hold. A hovering character sinks between attacks because
-- gravity keeps applying and the position was only written once. Re-writing it
-- every Heartbeat pins it exactly, which is what stops NPCs reaching you during
-- a skill cooldown.
local function holdStep()
    if not CFG.HoldAltitude then return end
    if not holdCF then return end
    if activeTween then return end       -- never fight a tween in progress
    local _, root = parts()
    if not root then return end
    root.CFrame = holdCF
    killVelocity(root)
end

local function startStabilizer()
    if #stabConns > 0 then return end
    table.insert(stabConns, RunService.PreSimulation:Connect(stabilize))
    table.insert(stabConns, RunService.Heartbeat:Connect(function()
        local _, root = parts()
        if root then killVelocity(root) end
        pcall(holdStep)
    end))
end

local function stopStabilizer()
    for _, c in ipairs(stabConns) do pcall(function() c:Disconnect() end) end
    table.clear(stabConns)
    local char = parts()
    if char then
        for part, was in pairs(savedCollide) do
            if part and part.Parent then pcall(function() part.CanCollide = was end) end
        end
    end
    table.clear(savedCollide)
    local _, _, hum = parts()
    if hum then pcall(function() hum.AutoRotate = true end) end
end

local function setHold(cf) holdCF = cf end
local function clearHold() holdCF = nil end

local function cancelMove()
    if activeTween then pcall(function() activeTween:Cancel() end) end
    activeTween = nil
end

-- Tween to a target, exactly as the chest finder does. A tween is smooth and
-- the server follows it; a raw CFrame write teleports and makes the streaming
-- system drop the NPCs you were about to hit.
local MOVE_SPEED = 180
local function moveTo(position, speed)
    local _, root = parts()
    if not root then return false end
    local distance = (root.Position - position).Magnitude
    if distance < 4 then return true end

    clearHold()          -- a held CFrame would cancel the tween out
    cancelMove()
    local duration = math.max(0.06, distance / (speed or MOVE_SPEED))
    local tween = TweenService:Create(
        root,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        { CFrame = CFrame.new(position) }
    )
    activeTween = tween
    tween:Play()

    local deadline = os.clock() + duration + 1.5
    while os.clock() < deadline and P.running do
        local _, r = parts()
        if not r then return false end
        if (r.Position - position).Magnitude < 8 then return true end
        task.wait(0.05)
    end
    activeTween = nil
    return (function()
        local _, r = parts()
        return r and (r.Position - position).Magnitude < 25
    end)()
end

local function hoverAt(pos)
    local _, root = parts()
    if not root then return false end
    root.CFrame = CFrame.new(pos)
    killVelocity(root)
    return true
end

-- Re-assert the anchor every iteration. Roblox physics fights a floating
-- character continuously, so position must be re-pinned, not set once.
-- lookAt turns the CHARACTER toward the target. Never touch the camera:
-- writing CurrentCamera.CFrame locks the player's mouse and view.
local function pin(pos, lookAt)
    local _, root = parts()
    if not root then return end
    if pos then
        if lookAt and (lookAt - pos).Magnitude > 0.1 then
            root.CFrame = CFrame.new(pos, lookAt)
        else
            root.CFrame = CFrame.new(pos)
        end
    end
    killVelocity(root)
end


-- =========================================================
-- TARGETING
-- =========================================================
local function cleanName(model)
    return (model.Name:gsub("%s*%b[]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isBlacklisted(model)
    local until_ = blacklist[model]
    if not until_ then return false end
    if os.clock() > until_ then blacklist[model] = nil return false end
    return true
end

local function liveEnemies(names)
    local folder = workspace:FindFirstChild("Enemies")
    if not folder then return {} end
    local out = {}
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") and not isBlacklisted(m) then
            local hum  = m:FindFirstChildOfClass("Humanoid")
            local root = m:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 then
                local n = cleanName(m)
                if not names or names[n] then
                    table.insert(out, { model = m, hum = hum, root = root, name = n })
                end
            end
        end
    end
    return out
end

-- Seeds on the nearest enemy, then averages everything within ClusterRange.
local function cluster(list, from)
    if #list == 0 then return nil end
    local seed, best = nil, math.huge
    for _, e in ipairs(list) do
        local d = (e.root.Position - from).Magnitude
        if d < best then seed, best = e, d end
    end
    if not seed then return nil end

    local sum, n, hp, boss = Vector3.zero, 0, 0, false
    local members = {}
    for _, e in ipairs(list) do
        if (e.root.Position - seed.root.Position).Magnitude <= CFG.ClusterRange then
            sum += e.root.Position
            n += 1
            hp += e.hum.Health
            if e.hum.MaxHealth > 5000 then boss = true end
            table.insert(members, e)
        end
    end
    if n == 0 then return nil end
    return { pos = sum / n, count = n, hp = hp, boss = boss, seed = seed, members = members }
end

-- =========================================================
-- QUEST
-- =========================================================
local remotes = RS:FindFirstChild("Remotes")
local commF = remotes and remotes:FindFirstChild("CommF_")
local questFor, questAt = nil, 0

local function tryQuest(name)
    if not CFG.AutoQuest or not commF or not name then return end
    if questFor == name and os.clock() - questAt < CFG.QuestRetrySeconds then return end
    questFor, questAt = name, os.clock()
    pcall(function() commF:InvokeServer("StartQuest", name .. "Quest", 1) end)
end



-- =========================================================
-- ENEMY PULL
-- =========================================================
-- Held every Heartbeat, because the server's own NPC movement fights it. A
-- one-shot write is undone within a frame, exactly like character hovering.
local pullConn = nil
local pulled = {}

-- Stack enemies around a point. Used by both PULL (they are held under you)
-- and MAGNET (they are held in front of you, inside weapon range).
local function holdEnemies(centre, radius, range, filtered, cap)
    local folder = workspace:FindFirstChild("Enemies")
    if not folder then return 0 end
    local _, root = parts()
    if not root then return 0 end

    -- nearest first, so the cap keeps the ones actually worth hitting
    local list = {}
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") then
            local hum = m:FindFirstChildOfClass("Humanoid")
            local r = m:FindFirstChild("HumanoidRootPart")
            if hum and r and hum.Health > 0 then
                if (not filtered) or (not activeNames) or activeNames[cleanName(m)] then
                    local d = (r.Position - root.Position).Magnitude
                    if d <= range then
                        table.insert(list, { m = m, r = r, d = d })
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)

    table.clear(pulled)
    local n = 0
    for i, e in ipairs(list) do
        if i > cap then break end
        n += 1
        table.insert(pulled, e.m)
        -- ring them so they do not all fight for one spot; a tight ring keeps
        -- every one of them inside the same swing
        local a = (i / 8) * math.pi * 2
        local off = Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
        pcall(function()
            e.r.CFrame = CFrame.new(centre + off)
            e.r.AssemblyLinearVelocity = Vector3.zero
            e.r.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    return n
end

-- MAGNET: the answer to "make M1 reach further". The hitbox cannot be widened
-- on this executor, so the enemy is brought to the hitbox instead. They are
-- parked a few studs in FRONT of the character, which is where every weapon's
-- swing actually lands.
local function magnetStep()
    local _, root = parts()
    if not root then return end
    local centre = (root.CFrame * CFrame.new(0, -CFG.MagnetDrop, -CFG.MagnetDistance)).Position
    stats.pulled = holdEnemies(centre, 3, CFG.MagnetRange,
        not CFG.MagnetAllTypes, CFG.MagnetMax)
end

local function pullStep()
    local _, root = parts()
    if not root then return end
    local centre = root.Position - Vector3.new(0, CFG.PullDrop, 0)
    stats.pulled = holdEnemies(centre, CFG.PullRadius, CFG.PullRange, true, 60)
end

-- One connection drives both. Magnet wins when both are on, because holding a
-- model in two places at once just makes it vibrate.
local function startPuller()
    if pullConn then return end
    pullConn = RunService.Heartbeat:Connect(function()
        if CFG.Magnet then pcall(magnetStep)
        elseif CFG.PullEnemies then pcall(pullStep)
        end
    end)
end

local function stopPuller()
    if pullConn then pcall(function() pullConn:Disconnect() end) end
    pullConn = nil
    stats.pulled = 0
end

local function syncPuller()
    if CFG.Magnet or CFG.PullEnemies then startPuller() else stopPuller() end
end

-- =========================================================
-- QUEST (manual only)
-- =========================================================
-- Blind StartQuest calls reset an active quest's kill count to zero, which is
-- what destroyed real progress earlier. This instead walks to the quest giver
-- and triggers it the way a player does, and it only ever runs when you press
-- the button.
local function findQuestGiver(maxRange)
    local _, root = parts()
    if not root then return nil end

    -- WHY THIS LOOKS THE WAY IT DOES
    -- The chest finder works because it locks onto the interactable PART, not
    -- a guessed model position, so a chest on a second floor or underground is
    -- still reached exactly. Quest givers need the same treatment.
    --
    -- The earlier version ALSO required the NPC model to carry a Humanoid or
    -- to be named something containing "quest". Blox Fruits quest givers are
    -- often plain rigs with no Humanoid and an ordinary name -- "Villager" --
    -- so standing right next to one still reported "no quest giver found".
    -- Nothing is required now: every ClickDetector and ProximityPrompt is a
    -- candidate, and quest-looking ones simply score better.
    maxRange = maxRange or 400
    local cands = {}

    local function partOf(inst)
        local par = inst.Parent
        if par and par:IsA("BasePart") then return par end
        if par and par:IsA("Model") then
            return par.PrimaryPart
                or par:FindFirstChild("HumanoidRootPart")
                or par:FindFirstChild("Head")
                or par:FindFirstChildWhichIsA("BasePart", true)
        end
        if par then return par:FindFirstChildWhichIsA("BasePart", true) end
        return nil
    end

    -- Players see a "?" billboard reading QUEST above a giver. If that label
    -- exists anywhere under the model, this is certainly the right NPC.
    local function hasQuestMarker(model)
        if not model then return false end
        local ok, found = pcall(function()
            for _, d in ipairs(model:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton"))
                    and type(d.Text) == "string"
                    and string.find(string.lower(d.Text), "quest", 1, true) then
                    return true
                end
            end
            return false
        end)
        return ok and found or false
    end

    local function consider(inst)
        local part = partOf(inst)
        if not part then return end
        local d = (part.Position - root.Position).Magnitude
        if d > maxRange then return end

        local model = inst:FindFirstAncestorOfClass("Model")
        local nm = (model and model.Name) or part.Name
        local low = string.lower(nm)

        local txt = ""
        if inst:IsA("ProximityPrompt") then
            txt = string.lower(tostring(inst.ObjectText) .. " " .. tostring(inst.ActionText))
        end

        local named  = string.find(low, "quest", 1, true)
                    or string.find(low, "giver", 1, true)
        local prompt = string.find(txt, "quest", 1, true)
        -- the marker scan is the expensive one, so only close candidates pay it
        local marker = (d < 200) and hasQuestMarker(model) or false

        -- score = distance, minus a bonus per quest signal. A signalled giver
        -- 80 studs away beats an unmarked door 5 studs away.
        local score = d
        if named  then score -= 500 end
        if prompt then score -= 500 end
        if marker then score -= 800 end

        table.insert(cands, {
            model = model, part = part, interact = inst, dist = d,
            name = nm, score = score,
            signal = (marker and "marker") or (prompt and "prompt")
                     or (named and "name") or "-",
        })
    end

    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("ClickDetector") or o:IsA("ProximityPrompt") then
            pcall(consider, o)
        end
    end

    table.sort(cands, function(a, b) return a.score < b.score end)
    P.questCandidates = cands
    local best = cands[1]
    return best, best and best.dist or nil
end

-- What the scan can actually see, so a failure is never silent.
function P.questScan(range)
    findQuestGiver(range or 400)
    local out = {}
    for i, c in ipairs(P.questCandidates or {}) do
        if i > 6 then break end
        table.insert(out, string.format("%-20s %4.0f %s",
            string.sub(tostring(c.name), 1, 20), c.dist, c.signal))
    end
    if #out == 0 then return { "nothing interactable in range" } end
    return out
end

-- Detects an active quest so we never re-take one (re-taking zeroes its count).
function P.questActive()
    local pg = player:FindFirstChild("PlayerGui")
    if not pg then return false end
    local ok, found = pcall(function()
        for _, d in ipairs(pg:GetDescendants()) do
            if d:IsA("GuiObject") and d.Visible and d.Name == "Quest"
                and not d:FindFirstAncestor("BFPHUD") then
                -- the tracker frame carries the objective text when active
                for _, t in ipairs(d:GetDescendants()) do
                    if t:IsA("TextLabel") and t.Visible
                        and type(t.Text) == "string" and #t.Text > 3 then
                        return true
                    end
                end
            end
        end
        return false
    end)
    return ok and found or false
end

-- After the giver is clicked a dialog appears with one button per quest tier.
-- Click the one naming the enemy we are farming, else the first real option.
local function clickQuestDialog(wantName)
    local pg = player:FindFirstChild("PlayerGui")
    if not pg then return false end

    -- Blox Fruits builds the quest dialog out of ImageButtons whose caption
    -- lives in a child TextLabel, not out of TextButtons. Scanning only
    -- TextButton found nothing, which is why it opened the dialog and then
    -- stood there. GuiButton covers both, and the caption is read from the
    -- button's descendants.
    local function textOf(b)
        local acc = {}
        if type(b.Text) == "string" and #b.Text > 0 then table.insert(acc, b.Text) end
        for _, d in ipairs(b:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextBox"))
                and type(d.Text) == "string" and #d.Text > 0 then
                table.insert(acc, d.Text)
            end
        end
        return string.lower(table.concat(acc, " "))
    end

    local function click(b)
        local fired = false
        pcall(function()
            if getconnections then
                for _, conn in ipairs(getconnections(b.Activated)) do
                    conn:Fire() fired = true
                end
                if not fired then
                    for _, conn in ipairs(getconnections(b.MouseButton1Click)) do
                        conn:Fire() fired = true
                    end
                end
            end
        end)
        if not fired then
            pcall(function()
                local ap, as = b.AbsolutePosition, b.AbsoluteSize
                local x, y = ap.X + as.X / 2, ap.Y + as.Y / 2
                VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
                task.wait(0.06)
                VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
            end)
        end
    end

    local deadline = os.clock() + 4
    while os.clock() < deadline do
        local best, fallback, seen = nil, nil, {}
        for _, d in ipairs(pg:GetDescendants()) do
            -- Our own panel has buttons reading QUEST. Without this guard the
            -- dialog hunt clicks the farm's own UI instead of the game's.
            local mine = d:FindFirstAncestor("BFPHUD") ~= nil
            if not mine and d:IsA("GuiButton") and d.Visible and d.AbsoluteSize.X > 20 then
                local txt = textOf(d)
                if #txt > 2 then
                    table.insert(seen, string.sub(txt, 1, 40))
                    if wantName and string.find(txt, string.lower(wantName), 1, true) then
                        best = d
                    elseif string.find(txt, "quest", 1, true)
                        or string.find(txt, "accept", 1, true)
                        or string.find(txt, "kill", 1, true)
                        or string.find(txt, "defeat", 1, true) then
                        fallback = fallback or d
                    end
                end
            end
        end
        P.lastQuestOptions = seen
        local pick = best or fallback
        if pick then
            click(pick)
            return true, string.sub(textOf(pick), 1, 60)
        end
        task.wait(0.2)
    end
    return false
end

function P.takeQuest()
    if P.questActive() then
        P.lastQuestResult = "a quest is already active - not re-taking (would reset it)"
        say(P.lastQuestResult)
        return false
    end
    -- Close first: the giver you are standing next to should always win.
    -- Only widen if there is genuinely nothing interactable around you.
    local giver = findQuestGiver(300) or findQuestGiver(2000)
    if not giver then
        P.lastQuestResult = "no ClickDetector or ProximityPrompt found at all"
        say(P.lastQuestResult)
        return false
    end

    say(string.format("giver: %s  %.0f studs  [%s]",
        tostring(giver.name), giver.dist or 0, tostring(giver.signal)))

    -- Land at the interactable's own position, height included.
    moveTo(giver.part.Position + Vector3.new(0, 3, 0), MOVE_SPEED)
    task.wait(0.5)

    local fired = false
    local inst = giver.interact

    if inst:IsA("ClickDetector") then
        if fireclickdetector then
            pcall(function() fireclickdetector(inst, 0) end)
            fired = true
        end
    elseif inst:IsA("ProximityPrompt") then
        if fireproximityprompt then
            pcall(function() fireproximityprompt(inst) end)
            fired = true
        else
            pcall(function()
                inst:InputHoldBegin()
                task.wait((inst.HoldDuration or 0) + 0.1)
                inst:InputHoldEnd()
            end)
            fired = true
        end
    end

    if not fired then
        P.lastQuestResult = "giver has no ClickDetector/Prompt"
        say(P.lastQuestResult)
        return false
    end

    -- second half: the dialog is open, now pick the quest
    local wanted
    if activeNames then for n in pairs(activeNames) do wanted = n break end end
    local clicked, what = clickQuestDialog(wanted)
    P.lastQuestResult = clicked and ("accepted: " .. tostring(what))
                                or "dialog opened but no quest button found"
    say(P.lastQuestResult)

    -- go straight back to farming rather than standing at the giver
    anchor = nil
    setState("RESOLVE")
    progress()
    return clicked
end

-- =========================================================
-- ATTACK
-- =========================================================
-- Measured, not guessed: attacktest.lua tried nine methods against a live
-- enemy. Every mouse path (VirtualUser Button1, VirtualInputManager mouse
-- clicks, Tool:Activate) dealt ZERO. Only VirtualInputManager KEY events land,
-- and they land at hover height as well as point blank.
--
--   Light-Light  Z -> 170   (one-shot on a Monkey)
--   Combat       Z ->  33
--   Pipe         Z ->  28
--
-- Skills have cooldowns, so the keys are cycled: by the time Z comes round
-- again it has had three other casts' worth of time to recover.
local keyIndex, swingIndex = 0, 0

local function pressKey(key)
    VIM:SendKeyEvent(true, key, false, game)
    task.wait(CFG.AttackHold)
    VIM:SendKeyEvent(false, key, false, game)
end

-- M1 / left click. The attack test's mouse attempts passed repeatCount = 1;
-- the in-game form is 0. Both VIM and VirtualUser are fired each swing so
-- whichever the game accepts gets through.
local function pressM1()
    local cam = workspace.CurrentCamera
    local vs = cam.ViewportSize
    local x, y = vs.X * 0.5, vs.Y * 0.5

    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, true, game, 0) end)
    task.wait(CFG.AttackHold)
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, false, game, 0) end)

    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:Button1Down(Vector2.new(x, y), cam.CFrame)
        VirtualUser:Button1Up(Vector2.new(x, y), cam.CFrame)
    end)
end

-- EXPERIMENT. Every click pair measured zero, but a click pair is two events
-- a frame apart; some input paths only register a button that is actually HELD
-- across frames. This holds it down and never releases until the mode changes.
local m1Held = false
local function holdM1(down)
    local cam = workspace.CurrentCamera
    local vs = cam.ViewportSize
    local x, y = vs.X * 0.5, vs.Y * 0.5
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, down, game, 0) end)
    pcall(function()
        VirtualUser:CaptureController()
        if down then
            VirtualUser:Button1Down(Vector2.new(x, y), cam.CFrame)
        else
            VirtualUser:Button1Up(Vector2.new(x, y), cam.CFrame)
        end
    end)
    m1Held = down
end
P.releaseM1 = function() if m1Held then holdM1(false) end end

local function nextSkill()
    local keys = CFG.SkillKeys
    if not keys or #keys == 0 then return end
    keyIndex = (keyIndex % #keys) + 1
    pcall(pressKey, keys[keyIndex])
end

local function swing()
    stats.swings += 1
    swingIndex += 1
    local mode = CFG.AttackMode

    if mode ~= "M1HOLD" and m1Held then holdM1(false) end

    if mode == "SKILLS" then
        nextSkill()
    elseif mode == "M1HOLD" then
        holdM1(true)          -- re-assert; the game may drop a stale hold
    elseif mode == "BOTH" then
        pressM1()
        if swingIndex % math.max(1, CFG.SkillEvery) == 0 then nextSkill() end
    else -- "M1"
        pressM1()
    end
end

-- =========================================================
-- ESCALATION LADDER
-- =========================================================
local function escalate(currentCluster)
    escalation = math.min(escalation + 1, CFG.MaxEscalation)
    stats.escalations += 1
    lastProgressAt = os.clock()   -- give each rung a fresh window

    if escalation == 1 then
        say("stuck: re-anchoring")
        anchor = nil

    elseif escalation == 2 then
        say("stuck: re-equipping weapon")
        equipWeapon()
        anchor = nil

    elseif escalation == 3 then
        say("stuck: reinstalling fast attack")
        installFastAttack()
        equipWeapon()
        anchor = nil

    elseif escalation == 4 then
        say("stuck: blacklisting target, moving on")
        if currentCluster then
            for _, e in ipairs(currentCluster.members) do
                blacklist[e.model] = os.clock() + 60
            end
        end
        anchor = nil
        setState("RESOLVE")
    end
end

-- =========================================================
-- RESOLVE  (which enemies, and where)
-- =========================================================
local function resolveTargets()
    if targetNames then
        -- explicit set from the caller
        local loc
        for _, row in ipairs(LEVELS) do
            if targetNames[row[3]] then loc = row[4] break end
        end
        return targetNames, loc
    end

    if anyEnemyMode then return nil, nil end

    local lv = playerLevel()
    if not lv then
        say("level unknown - falling back to any enemy")
        return nil, nil
    end

    -- Collect every row matching the level, so an island with several valid
    -- enemy types is fully covered instead of just the first match.
    local names, loc = {}, nil
    for _, row in ipairs(LEVELS) do
        if lv >= row[1] and lv <= row[2] then
            names[row[3]] = true
            loc = loc or row[4]
        end
    end
    if not next(names) then
        -- above the table: use the highest row
        local top = LEVELS[#LEVELS]
        names[top[3]] = true
        loc = top[4]
    end
    return names, loc
end

-- =========================================================
-- MAIN LOOP
-- =========================================================

local function retreat()
    stats.retreats += 1
    say("retreating - low health")
    local _, root = parts()
    local safeSpot
    if root then
        local p = root.Position
        safeSpot = Vector3.new(p.X, p.Y + CFG.RetreatHeight, p.Z)
        hoverAt(safeSpot)
        setHold(CFrame.new(safeSpot))
    end
    local deadline = os.clock() + CFG.RegenWait
    while P.running and os.clock() < deadline do
        pin(safeSpot)
        if healthPct() > 0.9 then break end
        task.wait(0.2)
    end
    anchor = nil
    progress()
end

local function step()
    local _, root = parts()
    if not root then
        say("waiting for character")
        anchor = nil
        task.wait(0.4)
        return
    end

    if healthPct() < CFG.MinHealthPercent then
        retreat()
        return
    end

    -- ---------- RESOLVE ----------
    if state == "RESOLVE" or not activeNames and not anyEnemyMode then
        local names, loc = resolveTargets()
        activeNames = names
        travelGoal = loc
        local label = "any enemy"
        if names then
            local list = {}
            for n in pairs(names) do table.insert(list, n) end
            table.sort(list)
            label = table.concat(list, ", ")
        end
        say("targets: " .. label)
        setState("ENGAGE")
        progress()
        return
    end

    -- ---------- find work ----------
    local list = liveEnemies(activeNames)

    if #list == 0 and CFG.AnyEnemyFallback and activeNames then
        list = liveEnemies(nil)      -- nothing of the quest type loaded: take EXP
        if #list > 0 then say("quest enemies absent - hitting loaded enemies") end
    end

    if #list == 0 then
        -- ---------- TRAVEL ----------
        if travelGoal then
            if state ~= "TRAVEL" then
                setState("TRAVEL")
                stats.travels += 1
            end
            say("no targets loaded - moving to farm spot")
            moveTo(travelGoal + Vector3.new(0, CFG.HoverHeight, 0), MOVE_SPEED)
            task.wait(0.4)
            if os.clock() - stateEnteredAt > CFG.TravelTimeout then
                say("travel timeout - re-resolving")
                setState("RESOLVE")
            end
        else
            say("no targets and no travel goal")
            task.wait(0.6)
        end
        return
    end

    -- ---------- ENGAGE ----------
    if state ~= "ENGAGE" then setState("ENGAGE") end

    -- ONE target at a time, exactly like the chest finder picks one chest.
    -- Cluster anchoring looked clever and did not work: it hovered over a
    -- moving average, never actually reaching anything.
    local target, bestD = nil, math.huge
    for _, e in ipairs(list) do
        local d = (e.root.Position - root.Position).Magnitude
        if d < bestD then target, bestD = e, d end
    end
    if not target then task.wait(0.2) return end

    local hpStart = target.hum.Health
    say(string.format("%s  %.0f studs  hp %.0f%s",
        target.name, bestD, hpStart,
        escalation > 0 and ("  [esc " .. escalation .. "]") or ""))

    -- With MAGNET on the enemy comes to us, so travelling to it is wasted
    -- motion, and moving would drag the whole stack across the island.
    if CFG.Magnet then
        setHold(root.CFrame)
    else
        -- Go to it, slightly above so melee AI cannot path to us.
        local goal = target.root.Position + Vector3.new(0, CFG.HoverHeight, 0)
        moveTo(goal, MOVE_SPEED)
        local _, r0 = parts()
        if r0 then setHold(CFrame.new(r0.Position, target.root.Position)) end
    end

    -- Then hold on it and swing until it dies, it leaves, or we stall.
    local holdUntil = os.clock() + CFG.TargetTimeout
    local lastHP = hpStart
    while P.running and os.clock() < holdUntil do
        local m, hum = target.model, target.hum
        if not m or not m.Parent then break end
        if hum.Health <= 0 then
            if not countedDead[m] then
                countedDead[m] = os.clock()
                stats.kills += 1
            end
            progress()
            break
        end

        local _, r = parts()
        if not r then break end

        -- Re-seat on the target each swing; it moves, and so do we.
        -- setHold is what stops the slow sink between swings: without it the
        -- position is written once and gravity undoes it before the next one.
        if CFG.Magnet then
            if not holdCF then setHold(r.CFrame) end
        else
            local tp = target.root.Position + Vector3.new(0, CFG.HoverHeight, 0)
            if (r.Position - tp).Magnitude > 12 then
                local cf = CFrame.new(tp, target.root.Position)
                r.CFrame = cf
                setHold(cf)
                killVelocity(r)
            end
        end

        swing()
        task.wait(CFG.AttackGap)

        if hum.Health < lastHP - 0.5 then
            stats.damaging += 1
            progress()
        end
        lastHP = hum.Health
    end

    -- Forget old corpses so the table cannot grow without bound.
    if math.random() < 0.02 then
        local now = os.clock()
        for model, t in pairs(countedDead) do
            if now - t > 120 then countedDead[model] = nil end
        end
    end

    if os.clock() - lastProgressAt > CFG.StuckSeconds then
        blacklist[target.model] = os.clock() + 20
        escalate(nil)
    end

    if os.clock() - stateEnteredAt > CFG.EngageTimeout then
        say("engage timeout - re-resolving")
        setState("RESOLVE")
    end
end

local function mainLoop()
    while P.running do
        local ok, err = pcall(step)
        if not ok then
            say("recovered from error")
            log(err)
            task.wait(0.3)
        end
    end
end

-- Independent watchdog: catches a total freeze of the main loop.
local function watchdog()
    local lastSeen = os.clock()
    local lastSwings = stats.swings
    while P.running do
        task.wait(5)
        if stats.swings ~= lastSwings then
            lastSwings = stats.swings
            lastSeen = os.clock()
        elseif os.clock() - lastSeen > 20 and state == "ENGAGE" then
            say("watchdog: no swings in 20s - forcing re-resolve")
            anchor = nil
            escalation = 0
            setState("RESOLVE")
            lastSeen = os.clock()
        end
    end
end

-- =========================================================
-- FAST TRAVEL
-- =========================================================
-- Lifted from teliport.txt, which works: name a spawn point, then destroy the
-- character so the server rebuilds it there. The head is destroyed first
-- because the character does not reliably tear down otherwise.
local worldOrigin  = workspace:FindFirstChild("_WorldOrigin")
local PlayerSpawns = worldOrigin and worldOrigin:FindFirstChild("PlayerSpawns")

function P.spawnList()
    local team = (player.Team and player.Team.Name) or "Pirates"
    local folder = PlayerSpawns and (PlayerSpawns:FindFirstChild(team)
                                  or PlayerSpawns:FindFirstChild("Pirates"))
    local names = {}
    if folder then
        for _, sp in ipairs(folder:GetChildren()) do table.insert(names, sp.Name) end
    end
    table.sort(names)
    return names
end

function P.forceRespawn()
    if not commF then return false end
    local team = (player.Team and player.Team.Name) or "Pirates"
    pcall(function() commF:InvokeServer("SetTeam2", team) end)
    say("force respawn: " .. team)
    return true
end

function P.travelTo(name)
    if not commF or not name or name == "" then return false end
    local char = player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local head = char and char:FindFirstChild("Head")
    if not (char and hum and head) or hum.Health <= 0 then
        say("travel: no living character")
        return false
    end

    -- Stop driving the body during the respawn, or the tween writes to a
    -- destroyed root and the loop spins on errors.
    local wasRunning = P.running
    P.running = false
    clearHold()
    cancelMove()
    say("fast travel -> " .. name)
    P.lastTravel = name

    pcall(function() commF:InvokeServer("SetLastSpawnPoint", name) end)
    task.wait((player:GetNetworkPing() * 2) + (1 / 60))
    pcall(function() head:Destroy() end)
    task.wait()
    pcall(function() char:Destroy() end)

    player.CharacterAdded:Wait()
    task.wait(2.5)
    say("arrived: " .. name)

    if wasRunning then
        P.running = true
        equipWeapon()
        startStabilizer()
        anchor = nil
        setState("RESOLVE")
        progress()
        task.spawn(mainLoop)
        task.spawn(watchdog)
    end
    return true
end

-- =========================================================
-- UI
-- =========================================================
local gui
local function buildUI()
    local pg = player:WaitForChild("PlayerGui", 10)
    if not pg then return end
    local old = pg:FindFirstChild("BFPHUD")
    if old then old:Destroy() end

    gui = Instance.new("ScreenGui")
    gui.Name = "BFPHUD"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 45
    gui.Parent = pg

    -- ---------- shell ----------
    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(430, 524)
    panel.Position = UDim2.new(1, -442, 0, 12)
    panel.BackgroundColor3 = Color3.fromRGB(13, 16, 22)
    panel.BorderSizePixel = 0
    panel.Active = true
    panel.Draggable = true
    panel.Parent = gui
    local pc = Instance.new("UICorner") pc.CornerRadius = UDim.new(0, 8) pc.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -60, 0, 22)
    title.Position = UDim2.fromOffset(10, 5)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 12
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(235, 242, 250)
    title.Parent = panel

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(44, 18)
    closeBtn.Position = UDim2.new(1, -52, 0, 6)
    closeBtn.BackgroundColor3 = Color3.fromRGB(62, 30, 34)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 10
    closeBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
    closeBtn.Text = "CLOSE"
    closeBtn.Parent = panel
    local cc = Instance.new("UICorner") cc.CornerRadius = UDim.new(0, 4) cc.Parent = closeBtn
    closeBtn.Activated:Connect(function()
        P.stop()
        gui:Destroy()
    end)

    local statusLbl = Instance.new("TextLabel")
    statusLbl.Size = UDim2.new(1, -20, 0, 15)
    statusLbl.Position = UDim2.fromOffset(10, 26)
    statusLbl.BackgroundTransparency = 1
    statusLbl.Font = Enum.Font.Code
    statusLbl.TextSize = 10
    statusLbl.TextXAlignment = Enum.TextXAlignment.Left
    statusLbl.TextColor3 = Color3.fromRGB(150, 170, 190)
    statusLbl.TextTruncate = Enum.TextTruncate.AtEnd
    statusLbl.Parent = panel

    -- ---------- tabs ----------
    local TABS = { "FARM", "COMBAT", "MOVE", "QUEST", "TRAVEL", "INFO" }
    local pages, tabBtns = {}, {}
    local current = "FARM"

    local function showTab(name)
        current = name
        for n, page in pairs(pages) do
            page.Visible = (n == name)
        end
        for n, b in pairs(tabBtns) do
            b.BackgroundColor3 = (n == name)
                and Color3.fromRGB(44, 58, 82) or Color3.fromRGB(24, 29, 38)
        end
    end

    for i, name in ipairs(TABS) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(66, 22)
        b.Position = UDim2.fromOffset(8 + (i - 1) * 69, 45)
        b.BackgroundColor3 = Color3.fromRGB(24, 29, 38)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 10
        b.TextColor3 = Color3.fromRGB(215, 228, 240)
        b.Text = name
        b.Parent = panel
        local bc = Instance.new("UICorner") bc.CornerRadius = UDim.new(0, 4) bc.Parent = b
        b.Activated:Connect(function() showTab(name) end)
        tabBtns[name] = b

        local page = Instance.new("Frame")
        page.Size = UDim2.new(1, -16, 1, -78)
        page.Position = UDim2.fromOffset(8, 72)
        page.BackgroundTransparency = 1
        page.Visible = false
        page.Parent = panel
        local l = Instance.new("UIListLayout")
        l.SortOrder = Enum.SortOrder.LayoutOrder
        l.Padding = UDim.new(0, 4)
        l.Parent = page
        pages[name] = page
    end

    -- ---------- widget helpers ----------
    local order = 0
    local function nextOrder() order = order + 1 return order end

    local function row(parent, height)
        local f = Instance.new("Frame")
        f.Size = UDim2.new(1, 0, 0, height or 24)
        f.BackgroundTransparency = 1
        f.LayoutOrder = nextOrder()
        f.Parent = parent
        return f
    end

    local function label(parent, text, size, colour)
        local t = Instance.new("TextLabel")
        t.Size = UDim2.new(1, 0, 0, 16)
        t.BackgroundTransparency = 1
        t.Font = Enum.Font.GothamBold
        t.TextSize = size or 10
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.TextColor3 = colour or Color3.fromRGB(130, 148, 168)
        t.Text = text
        t.LayoutOrder = nextOrder()
        t.Parent = parent
        return t
    end

    -- a button that reports its own state through a refresh function
    local live = {}
    local function button(parent, x, w, text, colour, cb, refresh)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(w, 22)
        b.Position = UDim2.fromOffset(x, 0)
        b.BackgroundColor3 = colour
        b.Font = Enum.Font.GothamBold
        b.TextSize = 10
        b.TextColor3 = Color3.fromRGB(238, 244, 250)
        b.Text = text
        b.Parent = parent
        local bc = Instance.new("UICorner") bc.CornerRadius = UDim.new(0, 4) bc.Parent = b
        b.Activated:Connect(function() pcall(cb, b) end)
        if refresh then table.insert(live, function() pcall(refresh, b) end) end
        return b
    end

    -- numeric stepper:  label  [-] value [+]
    local function stepper(parent, name, get, set, step, minV, maxV)
        local f = row(parent, 24)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.fromOffset(150, 22)
        lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.Code
        lbl.TextSize = 11
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextColor3 = Color3.fromRGB(180, 198, 216)
        lbl.Parent = f
        local function redraw() lbl.Text = name .. ": " .. tostring(get()) end
        redraw()
        table.insert(live, redraw)

        button(f, 158, 28, "-", Color3.fromRGB(44, 34, 38), function()
            set(math.max(minV, get() - step)) redraw()
        end)
        button(f, 190, 28, "+", Color3.fromRGB(32, 48, 40), function()
            set(math.min(maxV, get() + step)) redraw()
        end)
        return f
    end

    local ON  = Color3.fromRGB(34, 74, 46)
    local OFF = Color3.fromRGB(46, 34, 38)
    local NEU = Color3.fromRGB(32, 42, 58)

    -- =====================================================
    -- FARM TAB
    -- =====================================================
    do
        local page = pages.FARM
        label(page, "RUN")
        local r1 = row(page)
        button(r1, 0, 110, "START", ON, function()
            if P.running then P.stop()
            else task.spawn(function() P.start(P.lastNames, P.lastOpts) end) end
        end, function(b)
            b.Text = P.running and "STOP" or "START"
            b.BackgroundColor3 = P.running and OFF or ON
        end)
        button(r1, 118, 120, "ANY ENEMY", NEU, function()
            task.spawn(function() P.start(nil, { anyEnemy = true }) end)
        end)
        button(r1, 246, 110, "BY LEVEL", NEU, function()
            task.spawn(function() P.start(nil, {}) end)
        end)

        label(page, "TARGET")
        local tgt = Instance.new("TextLabel")
        tgt.Size = UDim2.new(1, 0, 0, 32)
        tgt.BackgroundTransparency = 1
        tgt.Font = Enum.Font.Code
        tgt.TextSize = 11
        tgt.TextXAlignment = Enum.TextXAlignment.Left
        tgt.TextYAlignment = Enum.TextYAlignment.Top
        tgt.TextColor3 = Color3.fromRGB(180, 198, 216)
        tgt.TextWrapped = true
        tgt.LayoutOrder = nextOrder()
        tgt.Parent = page
        table.insert(live, function()
            local names = {}
            if activeNames then
                for n in pairs(activeNames) do table.insert(names, n) end
                table.sort(names)
            end
            tgt.Text = #names > 0 and table.concat(names, ", ") or "any enemy"
        end)

        -- pick a specific enemy from whatever is loaded right now
        label(page, "PICK A LOADED ENEMY")
        local pick = Instance.new("TextLabel")
        pick.Size = UDim2.new(1, 0, 0, 16)
        pick.BackgroundTransparency = 1
        pick.Font = Enum.Font.Code
        pick.TextSize = 11
        pick.TextXAlignment = Enum.TextXAlignment.Left
        pick.TextColor3 = Color3.fromRGB(210, 226, 240)
        pick.LayoutOrder = nextOrder()
        pick.Parent = page

        local loadedNames, pickIdx = {}, 1
        local function refreshLoaded()
            local seen, out = {}, {}
            local folder = workspace:FindFirstChild("Enemies")
            if folder then
                for _, m in ipairs(folder:GetChildren()) do
                    if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then
                        local n = cleanName(m)
                        if not seen[n] then seen[n] = true table.insert(out, n) end
                    end
                end
            end
            table.sort(out)
            loadedNames = out
            if pickIdx > #out then pickIdx = 1 end
            pick.Text = (#out > 0)
                and ("> " .. tostring(out[pickIdx]) .. "   (" .. #out .. " types loaded)")
                or "> nothing loaded"
        end
        refreshLoaded()
        table.insert(live, refreshLoaded)

        -- Multi-select. ADD keeps stacking names onto one target set, so a
        -- single run can cover several enemy types on the same island.
        local selected = {}
        local function selList()
            local out = {}
            for n in pairs(selected) do table.insert(out, n) end
            table.sort(out)
            return out
        end

        local r2 = row(page)
        button(r2, 0, 96, "< PREV", NEU, function()
            if #loadedNames > 0 then
                pickIdx = ((pickIdx - 2) % #loadedNames) + 1
                refreshLoaded()
            end
        end)
        button(r2, 100, 96, "NEXT >", NEU, function()
            if #loadedNames > 0 then
                pickIdx = (pickIdx % #loadedNames) + 1
                refreshLoaded()
            end
        end)
        button(r2, 200, 96, "ADD", Color3.fromRGB(40, 56, 74), function()
            local n = loadedNames[pickIdx]
            if n then selected[n] = true end
        end)
        button(r2, 302, 112, "ONLY THIS", Color3.fromRGB(44, 62, 40), function()
            local n = loadedNames[pickIdx]
            if n then
                table.clear(selected)
                selected[n] = true
                task.spawn(function() P.start({ n }, {}) end)
            end
        end)

        label(page, "SELECTED")
        local sel = Instance.new("TextLabel")
        sel.Size = UDim2.new(1, 0, 0, 30)
        sel.BackgroundTransparency = 1
        sel.Font = Enum.Font.Code
        sel.TextSize = 11
        sel.TextXAlignment = Enum.TextXAlignment.Left
        sel.TextYAlignment = Enum.TextYAlignment.Top
        sel.TextColor3 = Color3.fromRGB(210, 226, 240)
        sel.TextWrapped = true
        sel.LayoutOrder = nextOrder()
        sel.Parent = page
        table.insert(live, function()
            local l = selList()
            sel.Text = #l > 0 and table.concat(l, ", ") or "(none - ADD some, or type below)"
        end)

        local r3 = row(page)
        button(r3, 0, 200, "FARM SELECTED", Color3.fromRGB(44, 62, 40), function()
            local l = selList()
            if #l > 0 then task.spawn(function() P.start(l, {}) end) end
        end)
        button(r3, 208, 110, "CLEAR", Color3.fromRGB(46, 34, 38), function()
            table.clear(selected)
        end)

        -- Type any name, even one not currently streamed in.
        label(page, "OR TYPE NAMES  (comma separated)")
        local boxRow = row(page, 24)
        local tb = Instance.new("TextBox")
        tb.Size = UDim2.fromOffset(300, 22)
        tb.BackgroundColor3 = Color3.fromRGB(22, 27, 35)
        tb.BorderSizePixel = 0
        tb.ClearTextOnFocus = false
        tb.Font = Enum.Font.Code
        tb.TextSize = 11
        tb.TextXAlignment = Enum.TextXAlignment.Left
        tb.TextColor3 = Color3.fromRGB(225, 236, 246)
        tb.PlaceholderText = "Swan Pirate, Marine Commodore"
        tb.Text = ""
        tb.Parent = boxRow
        local tc = Instance.new("UICorner") tc.CornerRadius = UDim.new(0, 4) tc.Parent = tb

        button(boxRow, 308, 106, "FARM TYPED", Color3.fromRGB(44, 62, 40), function()
            local names = {}
            for word in string.gmatch(tb.Text, "[^,]+") do
                word = (word:gsub("^%s+", ""):gsub("%s+$", ""))
                if #word > 0 then table.insert(names, word) end
            end
            if #names > 0 then
                table.clear(selected)
                for _, n in ipairs(names) do selected[n] = true end
                task.spawn(function() P.start(names, {}) end)
            end
        end)
    end

    -- =====================================================
    -- COMBAT TAB
    -- =====================================================
    do
        local page = pages.COMBAT
        label(page, "ATTACK MODE")
        local r1 = row(page)
        local MODES = { "SKILLS", "M1", "BOTH", "M1HOLD" }
        for i, m in ipairs(MODES) do
            button(r1, (i - 1) * 104, 100, m, NEU, function()
                CFG.AttackMode = m
                if m ~= "M1HOLD" then pcall(P.releaseM1) end
            end, function(b)
                b.BackgroundColor3 = (CFG.AttackMode == m) and ON or NEU
            end)
        end
        label(page, "M1 click measured ZERO damage here - the input never reaches",
            10, Color3.fromRGB(196, 150, 110))
        label(page, "combat. M1HOLD is an untested variant. Use MAGNET for reach.",
            10, Color3.fromRGB(196, 150, 110))

        label(page, "WEAPON")
        local wpn = Instance.new("TextLabel")
        wpn.Size = UDim2.new(1, 0, 0, 16)
        wpn.BackgroundTransparency = 1
        wpn.Font = Enum.Font.Code
        wpn.TextSize = 11
        wpn.TextXAlignment = Enum.TextXAlignment.Left
        wpn.TextColor3 = Color3.fromRGB(210, 226, 240)
        wpn.LayoutOrder = nextOrder()
        wpn.Parent = page

        local tools, tIdx = {}, 1
        local function refreshTools()
            local out = {}
            local char = player.Character
            local bp = player:FindFirstChildOfClass("Backpack")
            for _, src in ipairs({ char, bp }) do
                if src then
                    for _, t in ipairs(src:GetChildren()) do
                        if t:IsA("Tool") and not t:GetAttribute("ConsoleTool") then
                            table.insert(out, t.Name)
                        end
                    end
                end
            end
            table.sort(out)
            tools = out
            if tIdx > #out then tIdx = 1 end
            local held = char and char:FindFirstChildOfClass("Tool")
            wpn.Text = "holding: " .. (held and held.Name or "NONE")
                .. "   |   pick: " .. tostring(out[tIdx] or "-")
        end
        refreshTools()
        table.insert(live, refreshTools)

        local r2 = row(page)
        button(r2, 0, 110, "< PREV", NEU, function()
            if #tools > 0 then tIdx = ((tIdx - 2) % #tools) + 1 refreshTools() end
        end)
        button(r2, 118, 110, "NEXT >", NEU, function()
            if #tools > 0 then tIdx = (tIdx % #tools) + 1 refreshTools() end
        end)
        button(r2, 236, 120, "USE THIS", Color3.fromRGB(44, 62, 40), function()
            local n = tools[tIdx]
            if n then
                CFG.ForceWeapon = n
                equipWeapon()
                refreshTools()
            end
        end)

        label(page, "SKILL KEYS  (only ones you have unlocked)")
        local r3 = row(page)
        local ALLK = {
            { "Z", Enum.KeyCode.Z }, { "X", Enum.KeyCode.X },
            { "C", Enum.KeyCode.C }, { "V", Enum.KeyCode.V },
            { "F", Enum.KeyCode.F },
        }
        local function hasKey(kc)
            for _, k in ipairs(CFG.SkillKeys) do if k == kc then return true end end
            return false
        end
        for i, pair in ipairs(ALLK) do
            button(r3, (i - 1) * 60, 54, pair[1], NEU, function()
                if hasKey(pair[2]) then
                    for idx, k in ipairs(CFG.SkillKeys) do
                        if k == pair[2] then table.remove(CFG.SkillKeys, idx) break end
                    end
                else
                    table.insert(CFG.SkillKeys, pair[2])
                end
            end, function(b)
                b.BackgroundColor3 = hasKey(pair[2]) and ON or OFF
            end)
        end

        stepper(page, "swing gap",
            function() return string.format("%.2f", CFG.AttackGap) end,
            function(v) CFG.AttackGap = v end, 0.01, 0.01, 1)
        stepper(page, "skill every N",
            function() return CFG.SkillEvery end,
            function(v) CFG.SkillEvery = v end, 1, 1, 12)
    end

    -- =====================================================
    -- MOVE TAB
    -- =====================================================
    do
        local page = pages.MOVE
        label(page, "ALTITUDE")
        local rg = row(page)
        button(rg, 0, 200, "ANTI-GRAVITY", NEU, function()
            CFG.HoldAltitude = not CFG.HoldAltitude
            if not CFG.HoldAltitude then clearHold() end
        end, function(b)
            b.Text = CFG.HoldAltitude and "ANTI-GRAVITY: ON" or "GRAVITY: ON (will sink)"
            b.BackgroundColor3 = CFG.HoldAltitude and ON or OFF
        end)
        button(rg, 208, 110, "HOLD HERE", Color3.fromRGB(40, 56, 74), function()
            local _, r = parts()
            if r then
                startStabilizer()   -- the hold runs from the stabilizer loop
                setHold(r.CFrame)
            end
        end)
        button(rg, 322, 92, "RELEASE", NEU, function() clearHold() end)

        label(page, "POSITION")
        stepper(page, "hover height",
            function() return CFG.HoverHeight end,
            function(v) CFG.HoverHeight = v end, 2, 2, 60)
        stepper(page, "boss hover",
            function() return CFG.BossHoverHeight end,
            function(v) CFG.BossHoverHeight = v end, 2, 2, 80)
        stepper(page, "secs per target",
            function() return CFG.TargetTimeout end,
            function(v) CFG.TargetTimeout = v end, 5, 5, 120)

        label(page, "MAGNET  (drags enemies into weapon range)")
        local rm = row(page)
        button(rm, 0, 200, "MAGNET", NEU, function()
            CFG.Magnet = not CFG.Magnet
            syncPuller()
            -- collisions off, or forty stacked NPCs push you off the island
            if CFG.Magnet then startStabilizer() end
        end, function(b)
            b.Text = CFG.Magnet and ("MAGNET ON  (" .. stats.pulled .. ")") or "MAGNET OFF"
            b.BackgroundColor3 = CFG.Magnet and ON or OFF
        end)
        button(rm, 208, 206, "ALL TYPES", NEU, function()
            CFG.MagnetAllTypes = not CFG.MagnetAllTypes
        end, function(b)
            b.Text = CFG.MagnetAllTypes and "PULLING: EVERY ENEMY" or "PULLING: SELECTED ONLY"
            b.BackgroundColor3 = CFG.MagnetAllTypes and ON or NEU
        end)
        stepper(page, "magnet range",
            function() return CFG.MagnetRange end,
            function(v) CFG.MagnetRange = v end, 250, 50, 10000)
        stepper(page, "magnet distance",
            function() return CFG.MagnetDistance end,
            function(v) CFG.MagnetDistance = v end, 1, 2, 40)
        stepper(page, "magnet max",
            function() return CFG.MagnetMax end,
            function(v) CFG.MagnetMax = v end, 5, 5, 120)

        label(page, "ENEMY PULL  (stacks them under you instead)")
        local r1 = row(page)
        button(r1, 0, 170, "PULL", NEU, function()
            CFG.PullEnemies = not CFG.PullEnemies
            syncPuller()
        end, function(b)
            b.Text = CFG.PullEnemies and ("PULL ON  (" .. stats.pulled .. ")") or "PULL OFF"
            b.BackgroundColor3 = CFG.PullEnemies and ON or OFF
        end)

        stepper(page, "pull range",
            function() return CFG.PullRange end,
            function(v) CFG.PullRange = v end, 10, 20, 500)
        stepper(page, "pull radius",
            function() return CFG.PullRadius end,
            function(v) CFG.PullRadius = v end, 1, 1, 40)
        stepper(page, "pull drop",
            function() return CFG.PullDrop end,
            function(v) CFG.PullDrop = v end, 1, 0, 40)

        label(page, "Pulling writes NPC positions from the client.",
            10, Color3.fromRGB(196, 150, 110))
    end

    -- =====================================================
    -- QUEST TAB
    -- =====================================================
    do
        local page = pages.QUEST
        label(page, "QUEST")
        local r1 = row(page)
        button(r1, 0, 170, "TAKE QUEST NOW", Color3.fromRGB(58, 48, 24), function()
            task.spawn(function() pcall(P.takeQuest) end)
        end)
        button(r1, 178, 130, "AUTO QUEST", NEU, function()
            CFG.AutoQuest = not CFG.AutoQuest
        end, function(b)
            b.Text = CFG.AutoQuest and "AUTO: ON" or "AUTO: OFF"
            b.BackgroundColor3 = CFG.AutoQuest and ON or OFF
        end)

        local scanTxt
        button(r1, 314, 100, "SCAN", Color3.fromRGB(40, 56, 74), function()
            local rows = P.questScan(400)
            if scanTxt then
                scanTxt.Text = "nearest interactables:\n" .. table.concat(rows, "\n")
            end
        end)

        label(page, "SCAN RESULT")
        scanTxt = Instance.new("TextLabel")
        scanTxt.Size = UDim2.new(1, 0, 0, 96)
        scanTxt.BackgroundTransparency = 1
        scanTxt.Font = Enum.Font.Code
        scanTxt.TextSize = 10
        scanTxt.TextXAlignment = Enum.TextXAlignment.Left
        scanTxt.TextYAlignment = Enum.TextYAlignment.Top
        scanTxt.TextColor3 = Color3.fromRGB(190, 208, 226)
        scanTxt.Text = "press SCAN while standing near a quest giver"
        scanTxt.LayoutOrder = nextOrder()
        scanTxt.Parent = page

        local qs = Instance.new("TextLabel")
        qs.Size = UDim2.new(1, 0, 0, 90)
        qs.BackgroundTransparency = 1
        qs.Font = Enum.Font.Code
        qs.TextSize = 10
        qs.TextXAlignment = Enum.TextXAlignment.Left
        qs.TextYAlignment = Enum.TextYAlignment.Top
        qs.TextColor3 = Color3.fromRGB(170, 190, 210)
        qs.TextWrapped = true
        qs.LayoutOrder = nextOrder()
        qs.Parent = page
        table.insert(live, function()
            local opts = P.lastQuestOptions
            qs.Text = "active quest: " .. (P.questActive() and "YES" or "no")
                .. "\nlast: " .. tostring(P.lastQuestResult or "-")
                .. "\ndialog buttons seen: "
                .. ((opts and #opts > 0) and table.concat(opts, " | ") or "-")
        end)
    end

    -- =====================================================
    -- TRAVEL TAB
    -- =====================================================
    do
        local page = pages.TRAVEL
        label(page, "FAST TRAVEL  (server spawn points)")
        local dst = Instance.new("TextLabel")
        dst.Size = UDim2.new(1, 0, 0, 18)
        dst.BackgroundTransparency = 1
        dst.Font = Enum.Font.Code
        dst.TextSize = 12
        dst.TextXAlignment = Enum.TextXAlignment.Left
        dst.TextColor3 = Color3.fromRGB(215, 230, 244)
        dst.LayoutOrder = nextOrder()
        dst.Parent = page

        local spawns, sIdx = {}, 1
        local function refreshSpawns()
            spawns = P.spawnList()
            if sIdx > #spawns then sIdx = 1 end
            dst.Text = (#spawns > 0)
                and ("> " .. tostring(spawns[sIdx]) .. "   (" .. sIdx .. "/" .. #spawns .. ")")
                or "> no spawn list (are you on a team?)"
        end
        refreshSpawns()

        local t1 = row(page)
        button(t1, 0, 96, "< PREV", NEU, function()
            if #spawns > 0 then sIdx = ((sIdx - 2) % #spawns) + 1 refreshSpawns() end
        end)
        button(t1, 100, 96, "NEXT >", NEU, function()
            if #spawns > 0 then sIdx = (sIdx % #spawns) + 1 refreshSpawns() end
        end)
        button(t1, 200, 96, "REFRESH", NEU, function() refreshSpawns() end)
        button(t1, 302, 112, "TRAVEL", Color3.fromRGB(58, 48, 24), function()
            local n = spawns[sIdx]
            if n then task.spawn(function() pcall(P.travelTo, n) end) end
        end)

        label(page, "OR TYPE A SPAWN NAME")
        local tr = row(page, 24)
        local tbox = Instance.new("TextBox")
        tbox.Size = UDim2.fromOffset(300, 22)
        tbox.BackgroundColor3 = Color3.fromRGB(22, 27, 35)
        tbox.BorderSizePixel = 0
        tbox.ClearTextOnFocus = false
        tbox.Font = Enum.Font.Code
        tbox.TextSize = 11
        tbox.TextXAlignment = Enum.TextXAlignment.Left
        tbox.TextColor3 = Color3.fromRGB(225, 236, 246)
        tbox.PlaceholderText = "Middle Town"
        tbox.Text = ""
        tbox.Parent = tr
        local tbc = Instance.new("UICorner") tbc.CornerRadius = UDim.new(0, 4) tbc.Parent = tbox
        button(tr, 308, 106, "GO", Color3.fromRGB(58, 48, 24), function()
            local n = (tbox.Text:gsub("^%s+", ""):gsub("%s+$", ""))
            if #n > 0 then task.spawn(function() pcall(P.travelTo, n) end) end
        end)

        local t2 = row(page)
        button(t2, 0, 200, "FORCE RESPAWN", Color3.fromRGB(46, 34, 38), function()
            task.spawn(function() pcall(P.forceRespawn) end)
        end)

        local tinfo = Instance.new("TextLabel")
        tinfo.Size = UDim2.new(1, 0, 0, 96)
        tinfo.BackgroundTransparency = 1
        tinfo.Font = Enum.Font.Code
        tinfo.TextSize = 10
        tinfo.TextXAlignment = Enum.TextXAlignment.Left
        tinfo.TextYAlignment = Enum.TextYAlignment.Top
        tinfo.TextColor3 = Color3.fromRGB(170, 190, 210)
        tinfo.TextWrapped = true
        tinfo.LayoutOrder = nextOrder()
        tinfo.Parent = page
        table.insert(live, function()
            tinfo.Text = "last travel: " .. tostring(P.lastTravel or "-")
                .. "\n\nTravel sets your spawn point then destroys the character,"
                .. " so the server rebuilds it at the destination. Farming pauses"
                .. " during the respawn and resumes on arrival."
        end)
    end

    -- =====================================================
    -- INFO TAB
    -- =====================================================
    do
        local page = pages.INFO
        local info = Instance.new("TextLabel")
        info.Size = UDim2.new(1, 0, 1, 0)
        info.BackgroundTransparency = 1
        info.Font = Enum.Font.Code
        info.TextSize = 11
        info.TextXAlignment = Enum.TextXAlignment.Left
        info.TextYAlignment = Enum.TextYAlignment.Top
        info.TextColor3 = Color3.fromRGB(180, 198, 216)
        info.LayoutOrder = nextOrder()
        info.Parent = page
        table.insert(live, function()
            local mins = math.max((os.clock() - stats.startedAt) / 60, 1 / 60)
            local char = player.Character
            local held = char and char:FindFirstChildOfClass("Tool")
            local _, _, hum = parts()
            info.Text = table.concat({
                "state        " .. state,
                "status       " .. statusLine,
                "",
                "kills        " .. stats.kills .. string.format("   (%.1f/min)", stats.kills / mins),
                "DAMAGE HITS  " .. stats.damaging,
                "swings       " .. stats.swings,
                "pulled       " .. stats.pulled,
                "",
                "weapon       " .. (held and held.Name or "NONE"),
                "mode         " .. tostring(CFG.AttackMode),
                "hover        " .. CFG.HoverHeight,
                "anti-grav    " .. (CFG.HoldAltitude and "ON" or "off")
                                .. (holdCF and "  [holding]" or ""),
                "magnet       " .. (CFG.Magnet and "ON" or "off")
                                .. "  range " .. CFG.MagnetRange,
                "level        " .. tostring(playerLevel() or "?"),
                "health       " .. (hum and math.floor(hum.Health) or "?"),
                "",
                "escalations  " .. stats.escalations,
                "travels      " .. stats.travels,
                "retreats     " .. stats.retreats,
                string.format("last progress %.1fs ago", os.clock() - lastProgressAt),
            }, "\n")
        end)
    end

    showTab("FARM")

    -- ---------- refresh loop ----------
    task.spawn(function()
        while gui and gui.Parent do
            title.Text = "BF FARM PRO   [" .. state .. "]"
            title.TextColor3 = P.running
                and Color3.fromRGB(126, 226, 152) or Color3.fromRGB(200, 210, 224)
            statusLbl.Text = statusLine
            for _, fn in ipairs(live) do fn() end
            task.wait(0.35)
        end
    end)
end

-- =========================================================
-- API
-- =========================================================
function P.start(names, opts)
    if P.running then P.stop() end
    opts = opts or {}
    P.lastNames, P.lastOpts = names, opts
    anyEnemyMode = opts.anyEnemy == true

    targetNames = nil
    if type(names) == "table" then
        targetNames = {}
        for _, n in ipairs(names) do targetNames[n] = true end
    elseif type(names) == "string" then
        targetNames = { [names] = true }
    end

    for k in pairs(stats) do stats[k] = 0 end
    stats.startedAt = os.clock()
    activeNames, anchor, lastClusterHP = nil, nil, nil
    escalation = 0
    blacklist = {}
    countedDead = {}
    lastProgressAt = os.clock()
    P.running = true
    setState("RESOLVE")

    installFastAttack()
    equipWeapon()
    startStabilizer()
    syncPuller()
    if not (gui and gui.Parent) then pcall(buildUI) end

    track(player.Idled:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end))

    track(player.CharacterAdded:Connect(function()
        task.wait(2)
        anchor = nil
        equipWeapon()
        installFastAttack()
        progress()
    end))

    task.spawn(mainLoop)
    task.spawn(watchdog)
    print("[BFP] running. _G.BFP.stop() to halt.")
end

function P.stop()
    P.running = false
    fastOn = false
    pcall(P.releaseM1)
    clearHold()
    cancelMove()
    stopStabilizer()
    stopPuller()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    -- HUD deliberately survives stop, so START can restart from the panel.
    -- The X button destroys it.
    say("stopped")
    print(string.format("[BFP] stopped. kills=%d swings=%d escalations=%d", stats.kills, stats.swings, stats.escalations))
end

function P.stats() return stats end
function P.state() return state, statusLine, escalation end

-- Show the panel immediately on load so no console command is required.
say("loaded - press BY LEVEL or ANY ENEMY to begin")
pcall(buildUI)
print("[BFP] loaded. Use the panel, or _G.BFP.start()")
