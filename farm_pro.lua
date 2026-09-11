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
    AttackMode         = "M1",
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
    escalations = 0, travels = 0, damaging = 0, startedAt = 0,
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

local function startStabilizer()
    if #stabConns > 0 then return end
    table.insert(stabConns, RunService.PreSimulation:Connect(stabilize))
    table.insert(stabConns, RunService.Heartbeat:Connect(function()
        local _, root = parts()
        if root then killVelocity(root) end
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

local activeTween = nil
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
-- QUEST (manual only)
-- =========================================================
-- Blind StartQuest calls reset an active quest's kill count to zero, which is
-- what destroyed real progress earlier. This instead walks to the quest giver
-- and triggers it the way a player does, and it only ever runs when you press
-- the button.
local function findQuestGiver(maxRange)
    local _, root = parts()
    if not root then return nil end
    local best, bestD = nil, maxRange or 1500

    local function consider(model)
        if not model:IsA("Model") then return end
        local n = string.lower(model.Name)
        if not (string.find(n, "quest", 1, true) or string.find(n, "giver", 1, true)) then return end
        local r = model:FindFirstChild("HumanoidRootPart")
            or model.PrimaryPart
            or model:FindFirstChildWhichIsA("BasePart", true)
        if not r then return end
        local d = (r.Position - root.Position).Magnitude
        if d < bestD then best, bestD = { model = model, part = r }, d end
    end

    for _, o in ipairs(workspace:GetDescendants()) do
        consider(o)
    end
    return best, bestD
end

function P.takeQuest()
    local giver, dist = findQuestGiver(1500)
    if not giver then
        say("no quest giver found nearby")
        return false
    end

    say(string.format("quest giver %s at %.0f studs", giver.model.Name, dist or 0))
    moveTo(giver.part.Position + Vector3.new(0, 4, 0), MOVE_SPEED)
    task.wait(0.4)

    local fired = false

    -- ClickDetector is how most Blox Fruits quest givers are driven.
    local cd = giver.model:FindFirstChildWhichIsA("ClickDetector", true)
    if cd and fireclickdetector then
        pcall(function() fireclickdetector(cd, 0) end)
        fired = true
    end

    -- Some use a ProximityPrompt instead.
    local pp = giver.model:FindFirstChildWhichIsA("ProximityPrompt", true)
    if pp then
        if fireproximityprompt then
            pcall(function() fireproximityprompt(pp) end)
            fired = true
        else
            pcall(function()
                pp:InputHoldBegin()
                task.wait(pp.HoldDuration + 0.1)
                pp:InputHoldEnd()
            end)
            fired = true
        end
    end

    say(fired and ("quest giver triggered: " .. giver.model.Name)
               or "quest giver found but no ClickDetector/Prompt to fire")
    return fired
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
local VIM = game:GetService("VirtualInputManager")
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

    if mode == "SKILLS" then
        nextSkill()
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
local activeNames = nil

local function retreat()
    stats.retreats += 1
    say("retreating - low health")
    local _, root = parts()
    local safeSpot
    if root then
        local p = root.Position
        safeSpot = Vector3.new(p.X, p.Y + CFG.RetreatHeight, p.Z)
        hoverAt(safeSpot)
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

    -- Go to it, slightly above so melee AI cannot path to us.
    local goal = target.root.Position + Vector3.new(0, CFG.HoverHeight, 0)
    moveTo(goal, MOVE_SPEED)

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
        local tp = target.root.Position + Vector3.new(0, CFG.HoverHeight, 0)
        if (r.Position - tp).Magnitude > 12 then
            r.CFrame = CFrame.new(tp, target.root.Position)
            killVelocity(r)
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

    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(372, 194)
    panel.Position = UDim2.new(1, -352, 0, 12)
    panel.BackgroundColor3 = Color3.fromRGB(13, 16, 22)
    panel.BackgroundTransparency = 0.08
    panel.BorderSizePixel = 0
    panel.Active = true
    panel.Draggable = true
    panel.Parent = gui
    local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 8) c.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -16, 0, 20)
    title.Position = UDim2.fromOffset(10, 6)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 12
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    -- ---------- CONTROLS ----------
    local function mkButton(text, x, w, colour, cb)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(w, 22)
        b.Position = UDim2.fromOffset(x, 26)
        b.BackgroundColor3 = colour
        b.Font = Enum.Font.GothamBold
        b.TextSize = 11
        b.TextColor3 = Color3.fromRGB(238, 244, 250)
        b.Text = text
        b.Parent = panel
        local bc = Instance.new("UICorner") bc.CornerRadius = UDim.new(0, 5) bc.Parent = b
        b.Activated:Connect(function() pcall(cb, b) end)
        return b
    end

    local startBtn
    startBtn = mkButton("START", 10, 74, Color3.fromRGB(28, 66, 40), function()
        if P.running then
            P.stop()
        else
            -- restart in the same mode without tearing down the HUD
            task.spawn(function() P.start(P.lastNames, P.lastOpts) end)
        end
    end)

    mkButton("ANY ENEMY", 90, 90, Color3.fromRGB(30, 46, 72), function()
        task.spawn(function() P.start(nil, { anyEnemy = true }) end)
    end)

    mkButton("BY LEVEL", 186, 84, Color3.fromRGB(30, 46, 72), function()
        task.spawn(function() P.start(nil, {}) end)
    end)

    mkButton("QUEST", 278, 52, Color3.fromRGB(58, 48, 24), function()
        task.spawn(function() pcall(P.takeQuest) end)
    end)

    mkButton("X", 336, 26, Color3.fromRGB(62, 30, 34), function()
        P.stop()
        if gui then gui:Destroy() end
    end)

    local body = Instance.new("TextLabel")
    body.Size = UDim2.new(1, -16, 1, -54)
    body.Position = UDim2.fromOffset(10, 52)
    body.BackgroundTransparency = 1
    body.Font = Enum.Font.Code
    body.TextSize = 11
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.TextColor3 = Color3.fromRGB(172, 192, 212)
    body.Parent = panel

    task.spawn(function()
        while gui and gui.Parent do
            startBtn.Text = P.running and "STOP" or "START"
            startBtn.BackgroundColor3 = P.running
                and Color3.fromRGB(72, 38, 30) or Color3.fromRGB(28, 66, 40)
            task.wait(0.3)
        end
    end)

    task.spawn(function()
        while gui and gui.Parent do
            local mins = math.max((os.clock() - stats.startedAt) / 60, 1 / 60)
            title.Text = "BF FARM PRO   [" .. state .. "]" .. (fastOn and "   fast ON" or "   fast OFF")
            title.TextColor3 = fastOn and Color3.fromRGB(126, 226, 152) or Color3.fromRGB(245, 200, 110)
            local char = player.Character
            local held = char and char:FindFirstChildOfClass("Tool")
            body.Text = string.format(
                "%s\nweapon: %s\nkills %d  (%.1f/min)   swings %d\nreanchor %d  esc %d  travel %d  retreat %d\nlast progress %.1fs ago",
                statusLine,
                held and held.Name or "NONE",
                stats.kills, stats.kills / mins, stats.swings,
                stats.damaging,
                stats.reanchors, stats.escalations, stats.travels, stats.retreats,
                os.clock() - lastProgressAt)
            task.wait(0.25)
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
    cancelMove()
    stopStabilizer()
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
