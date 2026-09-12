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

    -- QUEST
    -- Re-taking a quest that is already running restarts its counter at zero.
    -- That is the only real danger, so every accept is gated on the in-game
    -- tracker reading EMPTY. With that gate the cycle is safe to leave on:
    --   accept -> kill the required count -> tracker clears -> accept again.
    AutoQuest          = false,
    QuestRetrySeconds  = 10,     -- gap between accept attempts
    QuestGiverName     = nil,    -- exact NPC name, e.g. "Adventurer"
    QuestName          = nil,    -- exact server quest name; nil = look it up
    QuestTier          = nil,    -- 1..3; nil = the tier matching the enemy
    QuestGiverClosest  = true,   -- no name set -> use the nearest "?" NPC
    QuestLock          = true,   -- repeat the quest that worked, not a new one
    QuestHopToGiver    = true,   -- stand at the giver before asking
    QuestReturnToFarm  = true,   -- fly back to the farm spot afterwards
    QuestKillsFallback = 10,     -- assumed count when the tracker is unreadable

    -- SECONDARY TARGETS
    -- Quest enemies respawn on a timer. Instead of hovering over empty ground
    -- the farm switches to a second set of names until the primaries are back.
    UseSecondary       = true,

    -- TELEPORT
    -- "auto"    : fly, and only respawn for a long haul to a real spawn point
    -- "fly"     : always fly there in steps (never destroys the character)
    -- "respawn" : always use the spawn point trick
    TeleportMode       = "auto",
    -- "instant" : one CFrame write, which is what the game's OWN house button
    --             was measured doing - 1590 studs, body never replaced
    -- "stepped" : cross in small steps; the fallback if instant is refused
    TeleportStyle      = "instant",
    TeleportSettle     = 2.0,    -- hold on arrival while the world streams in
    TeleportOverlay    = true,   -- the full-screen countdown card
    TeleportCountdown  = 3.0,    -- visible countdown before the hop
    TravelAltitude     = 350,    -- cruise height for the stepped fallback
    TravelStep         = 220,    -- studs per frame while crossing, stepped only
    FlyMaxDistance     = 6000,   -- further than this, auto tries respawn first


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
    MagnetRange        = 220,    -- how far out enemies are collected from
    -- WHERE THE PILE SITS, relative to you. Both are live sliders.
    --   Distance : how far IN FRONT. This is the gap that stops their melee
    --              from reaching you, so it is the one that matters most.
    --   Height   : POSITIVE lifts them above you, NEGATIVE drops them below.
    --              Below is what you want while hovering: you look down at
    --              them, they swing at air.
    --   OnGround : ignore Height and pin them to the ground you are hovering
    --              over, so they stand where they normally stand and you are
    --              simply out of reach above them.
    MagnetDistance     = 14,     -- studs in FRONT of you
    MagnetHeight       = -8,     -- + above you, - below you
    MagnetGround       = false,  -- pin to the ground instead of to your body
    MagnetMax          = 40,     -- cap the stack so the client does not choke
    MagnetAllTypes     = false,  -- true = drag every enemy, ignoring selection
    MagnetSpread       = 4,      -- how wide the held stack is
    -- Enemies held in FRONT and BELOW you only get hit if the swing points at
    -- them, and a standing character swings flat. This pitches the body at the
    -- stack, which is what puts the hitbox on the ground.
    FaceStack          = true,

    -- LEASH
    -- Every Blox Fruits NPC belongs to an area and stops being damageable once
    -- dragged outside it. A magnet strong enough to reach across the map pulls
    -- them past that limit, so they arrive and take no damage. This is the cap:
    -- an enemy is never moved further than LeashRadius from where it was found,
    -- and one that cannot be gathered without breaking its leash is left alone.
    LeashRadius        = 120,
    MagnetSeek         = false,  -- move YOU to the spot that reaches the most

    -- ONE TYPE AT A TIME
    -- Selecting Snow Bandit and Snowman should not mean dragging both species
    -- into one pile: they live in different parts of the island, each has its
    -- own leash, and a mixed pile is mostly enemies that cannot be hurt. The
    -- farm instead works one type through to exhaustion at that type's own
    -- centre, then moves to the next type's centre.
    RotateTypes        = true,
    TypeDwell          = 60,     -- seconds on one type before rotating
    TypeCentre         = true,   -- stand at the centre of the current type
    RecentreDistance   = 60,     -- re-centre once you drift this far

    -- Pitch applied while hovering and attacking. Attacking from directly above
    -- puts the enemy behind the swing arc; tilting nose-down points it at them.
    AttackTilt         = 0,      -- degrees, -89..89

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
    outOfLeash = 0, nearestHeld = 0,
}

local conns = {}
local function track(c) table.insert(conns, c) return c end

local state          = "BOOT"
local stateEnteredAt = 0
local statusLine     = "starting"
local escalation     = 0
local lastProgressAt = 0
local blacklist      = {}          -- model -> expiry clock
local countedDead    = {}          -- model -> clock, so a corpse counts once
local targetNames    = nil         -- set of names, or nil = any
local activeNames    = nil         -- resolved target set (hoisted: pullStep reads it)
local typeOrder      = {}          -- the selected names, in rotation order
local typeIdx        = 1
local typeSince      = 0
local focusSet       = nil         -- {name = true} for the type being worked now
local activeFilter   = nil         -- what the magnet may drag THIS cycle
local secondaryNames = nil         -- backup set, farmed while primaries respawn
local questTakenAt   = 0
local questBaseKills = 0
local questBlind     = false       -- accepted, but this island has no readable tracker
local lastQuestAt    = 0
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
    P.fastOK = false

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
    P.fastOK = true
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
local holdCF      = nil     -- absolute CFrame override (HOLD HERE)
local holdAnchor  = nil     -- GROUND position we are hovering over
local holdLook    = nil     -- what the character faces

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
-- The hold is stored as a GROUND anchor, not a finished CFrame, so hover
-- height and tilt are read fresh every frame. That is what makes the sliders
-- take effect while you are mid-fight instead of on the next target.
-- Yaw-only forward vector. Geometry built from the full LookVector feeds back
-- on itself: the stack sits where you are pointing, so pitching down to face it
-- moves it further down, and the body spirals. Stripping the pitch converges in
-- one frame and stays put.
local function yawLook(cf)
    local lv = cf.LookVector
    local flat = Vector3.new(lv.X, 0, lv.Z)
    if flat.Magnitude < 1e-3 then return Vector3.new(0, 0, -1) end
    return flat.Unit
end

-- A yaw-only snapshot of a pose. Capturing the CURRENT CFrame to hold it
-- captures the pitch that aiming already applied, and then the tilt is applied
-- to it again on the next frame. Do that once per target and the character
-- slowly rolls nose-over. Storing it flat makes every re-capture identical.
local function flatCF(cf)
    return CFrame.new(cf.Position, cf.Position + yawLook(cf))
end

-- Where the magnet parks the pile, measured from a position and a facing.
-- Taken apart into its own function because two callers need the SAME answer:
-- the magnet that moves the enemies there, and the hold that aims you at them.
-- If they disagree by even a little, you aim at empty ground.
local function stackPointFrom(pos, cf)
    local flat = pos + yawLook(cf) * CFG.MagnetDistance
    local y
    if CFG.MagnetGround then
        -- the ground we are hovering over: the anchor when there is one, else
        -- straight down by the hover height
        y = (holdAnchor and holdAnchor.Y) or (pos.Y - CFG.HoverHeight)
    else
        y = pos.Y + CFG.MagnetHeight
    end
    return Vector3.new(flat.X, y, flat.Z)
end

local function magnetCentre(root)
    return stackPointFrom(root.Position, root.CFrame)
end

-- The held pose. Tilt used to be applied on the anchored branch ONLY, so the
-- slider did nothing whenever the magnet was on (the magnet holds an absolute
-- CFrame). Both branches now end in the same aim-and-tilt code.
local function holdTarget()
    local cf
    if holdAnchor then
        local pos = holdAnchor + Vector3.new(0, CFG.HoverHeight, 0)
        if holdLook and (holdLook - pos).Magnitude > 0.1 then
            cf = CFrame.new(pos, holdLook)
        else
            cf = CFrame.new(pos)
        end
    else
        cf = holdCF
    end
    if not cf then return nil end

    -- A standing character swings flat, straight ahead. The magnet's pile is
    -- in front AND below, so a flat swing passes over it. Looking at the pile
    -- pitches the whole body nose-down and drops the hitbox onto the enemies.
    if CFG.Magnet and CFG.FaceStack then
        local centre = stackPointFrom(cf.Position, cf)
        if (centre - cf.Position).Magnitude > 0.5 then
            cf = CFrame.new(cf.Position, centre)
        end
    end

    if CFG.AttackTilt ~= 0 then
        cf = cf * CFrame.Angles(math.rad(CFG.AttackTilt), 0, 0)
    end
    return cf
end

local function holdStep()
    if not CFG.HoldAltitude then return end
    if activeTween then return end       -- never fight a tween in progress
    local cf = holdTarget()
    if not cf then return end
    local _, root = parts()
    if not root then return end
    root.CFrame = cf
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

local function setHold(cf) holdCF, holdAnchor, holdLook = cf, nil, nil end
-- ground point to hover over, and what to face. Height/tilt stay live.
local function setAnchor(groundPos, lookPos)
    holdAnchor, holdLook, holdCF = groundPos, lookPos, nil
end
local function clearHold() holdCF, holdAnchor, holdLook = nil, nil, nil end

local function cancelMove()
    if activeTween then pcall(function() activeTween:Cancel() end) end
    activeTween = nil
end

-- Tween to a target, exactly as the chest finder does. A tween is smooth and
-- the server follows it; a raw CFrame write teleports and makes the streaming
-- system drop the NPCs you were about to hit.
local MOVE_SPEED = 180
-- Movement used to abort the moment P.running went false, which meant every
-- manual button (take a quest, fly to a spot) walked half a stud and gave up
-- whenever the farm was not already running. STOP now cancels in-flight moves
-- through a short pulse instead, and manual moves work either way.
local moveEnabled = true
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
    while os.clock() < deadline and moveEnabled do
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

-- =========================================================
-- QUEST
-- =========================================================
local remotes = RS:FindFirstChild("Remotes")
local commF = remotes and remotes:FindFirstChild("CommF_")

-- =========================================================
-- ENEMY PULL
-- =========================================================
-- Held every Heartbeat, because the server's own NPC movement fights it. A
-- one-shot write is undone within a frame, exactly like character hovering.
local pullConn = nil
local pulled = {}

-- Where each enemy was first seen. An NPC dragged outside its own area stops
-- taking damage, so this is the point every displacement is measured from.
local homePos = setmetatable({}, { __mode = "k" })

local function homeOf(model, root)
    local h = homePos[model]
    if not h then
        h = root.Position
        homePos[model] = h
    end
    return h
end

-- Which names may be pulled right now. While rotating, only the type being
-- worked -- pulling the other selected species just stacks enemies that are
-- outside their own area and cannot be damaged.
local function pullFilter()
    if CFG.MagnetAllTypes then return nil end
    -- activeFilter is what the farm actually decided to fight this cycle, so
    -- when it falls back to the backup enemies the magnet follows it there.
    if activeFilter then return activeFilter end
    if CFG.RotateTypes and focusSet then return focusSet end
    return activeNames
end

-- Collect live enemies within range, remembering where each one belongs.
local function gather(range, names)
    local folder = workspace:FindFirstChild("Enemies")
    local _, root = parts()
    if not folder or not root then return {} end
    local list = {}
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") then
            local hum = m:FindFirstChildOfClass("Humanoid")
            local r = m:FindFirstChild("HumanoidRootPart")
            if hum and r and hum.Health > 0 then
                if (not names) or names[cleanName(m)] then
                    local d = (r.Position - root.Position).Magnitude
                    if d <= range then
                        table.insert(list, { m = m, r = r, d = d, home = homeOf(m, r) })
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    return list
end

-- Stack enemies around a point, refusing any move that would break a leash.
-- Used by both PULL (held under you) and MAGNET (held in front of you).
local function holdEnemies(centre, radius, range, names, cap)
    local list = gather(range, names)
    table.clear(pulled)
    local n, skipped = 0, 0
    for i, e in ipairs(list) do
        if n >= cap then break end
        -- concentric rings of 8: one ring of forty enemies is a single point
        local ring = math.floor(n / 8)
        local a    = (n % 8) / 8 * math.pi * 2
        local rad  = radius * (1 + ring * 0.55)
        local dest = centre + Vector3.new(math.cos(a) * rad, 0, math.sin(a) * rad)
        -- THE LEASH CHECK. Moving it here would take it out of its own area,
        -- where it arrives but takes no damage, so it is left where it is.
        if (dest - e.home).Magnitude > CFG.LeashRadius then
            skipped += 1
        else
            n += 1
            table.insert(pulled, e.m)
            pcall(function()
                e.r.CFrame = CFrame.new(dest)
                e.r.AssemblyLinearVelocity = Vector3.zero
                e.r.AssemblyAngularVelocity = Vector3.zero
            end)
        end
    end
    stats.outOfLeash = skipped

    -- The number that answers "are they close enough to hit me": the real
    -- distance from your body to the nearest enemy actually being held.
    local _, me = parts()
    if me then
        local nearest
        for _, m in ipairs(pulled) do
            local r = m:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (r.Position - me.Position).Magnitude
                if not nearest or d < nearest then nearest = d end
            end
        end
        stats.nearestHeld = nearest and math.floor(nearest) or 0
    end
    return n
end

-- Find the spot that can legally gather the most enemies: for each enemy,
-- count how many others share its neighbourhood, and take that centroid.
-- This is the "stand where I can pull them all" position.
local function packCentre()
    local list = gather(CFG.MagnetRange, pullFilter())
    if #list == 0 then return nil, 0 end
    local bestPos, bestN = nil, 0
    for _, a in ipairs(list) do
        local sum, n = Vector3.zero, 0
        for _, b in ipairs(list) do
            if (b.home - a.home).Magnitude <= CFG.LeashRadius * 0.8 then
                sum += b.home
                n += 1
            end
        end
        if n > bestN then bestPos, bestN = sum / n, n end
    end
    return bestPos, bestN
end
P.packCentre = packCentre

local function magnetStep()
    local _, root = parts()
    if not root then return end
    -- Built from the YAW only. The old version multiplied the full CFrame, so
    -- once the body pitched down the pile slid down with it and ended up on
    -- top of the player - which is exactly the "they hit me" complaint.
    local centre = magnetCentre(root)
    P.stackCentre = centre
    stats.pulled = holdEnemies(centre, CFG.MagnetSpread, CFG.MagnetRange,
        pullFilter(), CFG.MagnetMax)
end

local function pullStep()
    local _, root = parts()
    if not root then return end
    local centre = root.Position - Vector3.new(0, CFG.PullDrop, 0)
    stats.pulled = holdEnemies(centre, CFG.PullRadius, CFG.PullRange, pullFilter(), 60)
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
-- WHY THE OLD SCAN RETURNED ZIPLINES AND CAMPFIRES
-- Blox Fruits does not put a ClickDetector or a ProximityPrompt on a quest
-- giver. The "E Interact" ring is the game's own proximity UI, driven client
-- side, so scanning workspace for interactables found scenery and missed every
-- giver standing directly in front of the player.
--
-- What a quest giver does have is the "?" billboard reading QUEST above its
-- head. That is the signal the player reads, so it is the signal used here.
local function npcSources()
    local out = {}
    for _, n in ipairs({ "NPCs", "Npcs", "Characters", "Map" }) do
        local f = workspace:FindFirstChild(n)
        if f then table.insert(out, f) end
    end
    table.insert(out, workspace)
    return out
end

local function anchorPart(model)
    return model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("Head")
        or model:FindFirstChild("Torso")
        or model:FindFirstChildWhichIsA("BasePart")
end

-- true when a QUEST billboard hangs off this model
local function questMarker(model)
    local ok, hit = pcall(function()
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BillboardGui") then
                for _, t in ipairs(d:GetDescendants()) do
                    if (t:IsA("TextLabel") or t:IsA("TextButton"))
                        and type(t.Text) == "string"
                        and string.find(string.lower(t.Text), "quest", 1, true) then
                        return true
                    end
                end
            end
        end
        return false
    end)
    return ok and hit or false
end

-- QUEST GIVERS, from the Blox Fruits wiki NPC list (checked 2026-09-12).
--
-- Two tables, because they answer two different questions.
--
-- KNOWN_GIVERS is every name the wiki lists as a farm-quest giver, with no
-- island attached. Most of them are literally "<Island> Quest Giver", and the
-- ones that are not - Adventurer, Villager, Pirate Adventurer, Mole - are the
-- First Sea flavour names that no pattern match would ever catch. Being ON
-- this list is a strong signal on its own: whatever island you are standing
-- on, an NPC named from it is the quest giver, even when the enemy mapping
-- below is wrong. That makes the scan work everywhere without depending on
-- the mapping being perfect.
--
-- Deliberately NOT included: Bartilo (cafe), Trevor (fruit), King Neptune,
-- Military Detective (the Sea 2 key), Elite Hunter. They are quest NPCs but
-- not enemy-farm givers, and listing them would drag the farm to the wrong one.
local KNOWN_GIVERS = {}
for _, n in ipairs({
    -- First Sea
    "Bandit Quest Giver", "Adventurer", "Pirate Adventurer", "Desert Adventurer",
    "Villager", "Marine", "Marine Leader", "Colosseum Quest Giver",
    "Sky Adventurer", "Sky Quest Giver 2", "Mole", "Head Jailer", "Jail Keeper",
    "Freezeburg Quest Giver", "Submerged Quest Giver 1", "Submerged Quest Giver 2",
    -- Second Sea
    "Area 1 Quest Giver", "Area 2 Quest Giver", "Marine Quest Giver",
    "Graveyard Quest Giver", "Snow Quest Giver", "Ice Quest Giver",
    "Fire Quest Giver", "Forgotten Quest Giver", "Front Crew Quest Giver",
    "Rear Crew Quest Giver", "Frost Quest Giver",
    -- Third Sea
    "Pirate Port Quest Giver", "Hydra Town Quest Giver", "Dragon Crew Quest Giver",
    "Marine Tree Quest Giver", "Turtle Adventure Quest Giver",
    "Deep Forest Quest Giver", "Haunted Castle Quest Giver 1",
    "Haunted Castle Quest Giver 2", "Cake Quest Giver 1", "Cake Quest Giver 2",
    "Chocolate Quest Giver 1", "Chocolate Quest Giver 2", "Ice Cream Quest Giver",
    "Peanut Quest Giver", "Candy Cane Quest Giver", "Submerged Quest Giver 3",
    "Tiki Quest Giver 1", "Tiki Quest Giver 2", "Tiki Quest Giver 3",
}) do KNOWN_GIVERS[string.lower(n)] = n end
P.knownGivers = KNOWN_GIVERS

-- markerOnly = accept ONLY an NPC carrying the "?" QUEST billboard. That is
-- the closest-quest-giver mode: it needs no name and works on every island,
-- because the billboard is what the game itself shows the player.
local function findQuestGiver(maxRange, wantName, markerOnly)
    local _, root = parts()
    if not root then return nil end
    maxRange = maxRange or 300
    local want = wantName and string.lower(wantName) or nil

    local cands, seen = {}, {}
    for _, src in ipairs(npcSources()) do
        for _, m in ipairs(src:GetChildren()) do
            if m:IsA("Model") and not seen[m] then
                seen[m] = true
                local part = anchorPart(m)
                if part then
                    local d = (part.Position - root.Position).Magnitude
                    if d <= maxRange then
                        local low = string.lower(m.Name)
                        local named = string.find(low, "quest", 1, true)
                                   or string.find(low, "giver", 1, true)
                        -- on the wiki's list of quest givers: that is worth
                        -- more than any pattern match, and it works on every
                        -- island without the enemy mapping being right
                        local known = KNOWN_GIVERS[low] ~= nil
                        local marker = questMarker(m)
                        -- an exact name beats everything: quest givers are
                        -- ordinary NPCs with island-specific names, and the
                        -- name is the most reliable identifier there is
                        local exact = want and (low == want)
                        local score = d
                            - (exact and 50000 or 0)
                            - (known and 20000 or 0)
                            - (marker and 5000 or 0)
                            - (named and 1000 or 0)
                        local accept = exact or known or marker or named
                            or m:FindFirstChildOfClass("Humanoid")
                        if markerOnly then
                            accept = (exact or known or marker) and true or false
                        end
                        if accept then
                            table.insert(cands, {
                                model = m, part = part, dist = d, name = m.Name,
                                score = score,
                                signal = (exact and "EXACT NAME")
                                      or (known and "known giver")
                                      or (marker and "QUEST marker")
                                      or (named and "name") or "npc",
                                interact = m:FindFirstChildWhichIsA("ClickDetector", true)
                                        or m:FindFirstChildWhichIsA("ProximityPrompt", true),
                            })
                        end
                    end
                end
            end
        end
    end

    table.sort(cands, function(a, b) return a.score < b.score end)
    P.questCandidates = cands
    local best = cands[1]
    return best, best and best.dist or nil
end

-- What the scan can actually see, so a failure is never silent.
function P.questScan(range)
    findQuestGiver(range or 300)
    local out = {}
    for i, c in ipairs(P.questCandidates or {}) do
        if i > 8 then break end
        table.insert(out, string.format("%-22s %4.0f  %s",
            string.sub(tostring(c.name), 1, 22), c.dist, c.signal))
    end
    if #out == 0 then return { "no NPC models in range" } end
    return out
end

-- Ground truth dump for the nearest NPC, so the next fix is not a guess.
function P.questProbe()
    local _, root = parts()
    if not root then return { "no character" } end
    local best, bestD
    for _, src in ipairs(npcSources()) do
        for _, m in ipairs(src:GetChildren()) do
            if m:IsA("Model") and m ~= player.Character then
                local part = anchorPart(m)
                if part then
                    local d = (part.Position - root.Position).Magnitude
                    if not bestD or d < bestD then best, bestD = m, d end
                end
            end
        end
    end
    if not best then return { "no NPC found" } end

    local out = { ("NPC %s  %.0f studs  parent=%s"):format(
        best.Name, bestD, tostring(best.Parent and best.Parent.Name)) }
    local classes = {}
    for _, d in ipairs(best:GetDescendants()) do
        classes[d.ClassName] = (classes[d.ClassName] or 0) + 1
    end
    local rows = {}
    for c, n in pairs(classes) do table.insert(rows, c .. " x" .. n) end
    table.sort(rows)
    table.insert(out, table.concat(rows, ", "))
    for _, d in ipairs(best:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and type(d.Text) == "string"
            and #d.Text > 0 then
            table.insert(out, "text: " .. string.sub(d.Text, 1, 40))
        end
    end
    local attrs = best:GetAttributes()
    for k, v in pairs(attrs) do
        table.insert(out, "attr: " .. k .. " = " .. tostring(v))
    end
    if setclipboard then pcall(setclipboard, table.concat(out, "\n")) end
    P.lastProbe = out
    return out
end

-- ---------------------------------------------------------
-- READING THE TRACKER
-- ---------------------------------------------------------
-- The old check was "a GUI called Quest contains some text", which is equally
-- true of the quest BOARD standing in front of you. It therefore reported a
-- quest as active whenever the board was on screen, the accept was skipped as
-- a duplicate, and the farm never took anything. That is the whole bug.
--
-- The tracker has one thing nothing else has: a live have/need counter sitting
-- next to the word Defeat. That pair is what is read here.
local function shownOnScreen(g)
    local o = g
    while o and o:IsA("GuiObject") do
        if not o.Visible then return false end
        o = o.Parent
    end
    return true
end

local function blockText(frame)
    local acc = {}
    for _, d in ipairs(frame:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and type(d.Text) == "string" then
            table.insert(acc, d.Text)
        end
    end
    return string.lower(table.concat(acc, " "))
end

-- nil when no quest is running, else { have, need, enemy, text }
-- The scan walks every descendant of PlayerGui, and the panel asks three times
-- a second, so the answer is cached for half a second. Pass true to force it.
local questCache, questCacheAt = nil, 0
function P.readQuest(force)
    if not force and (os.clock() - questCacheAt) < 0.5 then return questCache end
    questCacheAt = os.clock()
    local pg = player:FindFirstChild("PlayerGui")
    if not pg then questCache = nil return nil end
    local found
    pcall(function()
        for _, d in ipairs(pg:GetDescendants()) do
            if d:IsA("TextLabel") and type(d.Text) == "string" and #d.Text > 0
                and not d:FindFirstAncestor("BFPHUD") and shownOnScreen(d) then
                local have, need = string.match(d.Text, "(%d+)%s*/%s*(%d+)")
                if have and need then
                    local parent = d.Parent
                    local blob = parent and blockText(parent) or string.lower(d.Text)
                    -- always beside the quest counter, never beside a mastery
                    -- or ammo counter
                    if string.find(blob, "defeat", 1, true)
                        or string.find(blob, "eliminate", 1, true)
                        or string.find(blob, "kill", 1, true) then
                        local enemy = string.match(blob, "defeat%s+%d+%s+([%a%s'%-]+)")
                        if enemy then enemy = (enemy:gsub("%s+$", "")) end
                        found = {
                            have  = tonumber(have) or 0,
                            need  = tonumber(need) or 0,
                            enemy = enemy,
                            text  = d.Text,
                        }
                        return
                    end
                end
            end
        end
    end)
    questCache = (found and found.need > 0) and found or nil
    return questCache
end

function P.questActive()
    return P.readQuest() ~= nil
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

-- Quest names the server accepts, by the enemy the quest asks for. These are
-- the names public Blox Fruits scripts have used for years; where one is wrong
-- the server simply refuses and nothing is lost. The QUEST tab has a box for
-- typing a name directly when a mapping here is stale.
-- Quest givers are ordinary NPCs with island-specific flavour names. Naming
-- one makes it unmissable; without a name the "?" billboard is the fallback.
-- Add to this as you confirm them, or type one into the QUEST tab.
-- GIVER_NAMES is the enemy -> giver mapping. The NAMES come from the wiki; the
-- pairing of name to enemy is read off each island, and a few of them are a
-- best reading rather than a certainty (marked). A wrong entry costs almost
-- nothing: no NPC by that name is near, the scan falls through to the nearest
-- "?" marker, and the moment an accept works the name that ACTUALLY worked is
-- learned into P.learnedGivers and overrides this table from then on.
local GIVER_NAMES = {
    -- First Sea
    ["Bandit"]                = "Bandit Quest Giver",
    ["Monkey"]                = "Adventurer",
    ["Gorilla"]               = "Adventurer",
    ["Pirate"]                = "Pirate Adventurer",
    ["Brute"]                 = "Pirate Adventurer",
    ["Desert Bandit"]         = "Desert Adventurer",
    ["Desert Officer"]        = "Desert Adventurer",
    ["Snow Bandit"]           = "Villager",
    ["Snowman"]               = "Villager",
    ["Chief Petty Officer"]   = "Marine",
    ["Sky Bandit"]            = "Sky Adventurer",
    ["Dark Master"]           = "Sky Adventurer",
    ["Prisoner"]              = "Jail Keeper",          -- Prison, two candidates
    ["Dangerous Prisoner"]    = "Jail Keeper",          -- the other is Head Jailer
    ["Toga Warrior"]          = "Colosseum Quest Giver",
    ["Gladiator"]             = "Colosseum Quest Giver",
    ["God's Guard"]           = "Sky Quest Giver 2",
    ["Shanda"]                = "Sky Quest Giver 2",
    ["Royal Squad"]           = "Mole",                 -- Upper Skylands
    ["Royal Soldier"]         = "Mole",
    ["Galley Pirate"]         = "Freezeburg Quest Giver",  -- uncertain pairing
    ["Galley Captain"]        = "Freezeburg Quest Giver",  -- uncertain pairing

    -- Second Sea
    ["Raider"]                = "Area 1 Quest Giver",
    ["Mercenary"]             = "Area 1 Quest Giver",
    ["Swan Pirate"]           = "Area 2 Quest Giver",
    ["Factory Staff"]         = "Area 2 Quest Giver",
    ["Marine Lieutenant"]     = "Marine Quest Giver",
    ["Marine Captain"]        = "Marine Quest Giver",
    ["Zombie"]                = "Graveyard Quest Giver",
    ["Vampire"]               = "Graveyard Quest Giver",
    ["Snow Trooper"]          = "Snow Quest Giver",
    ["Winter Warrior"]        = "Snow Quest Giver",
    ["Lab Subordinate"]       = "Ice Quest Giver",
    ["Horned Warrior"]        = "Ice Quest Giver",
    ["Magma Ninja"]           = "Fire Quest Giver",
    ["Lava Pirate"]           = "Fire Quest Giver",
    ["Sea Soldier"]           = "Forgotten Quest Giver",
    ["Water Fighter"]         = "Forgotten Quest Giver",
    ["Ship Deckhand"]         = "Front Crew Quest Giver",
    ["Ship Engineer"]         = "Front Crew Quest Giver",
    ["Ship Steward"]          = "Rear Crew Quest Giver",
    ["Ship Officer"]          = "Rear Crew Quest Giver",
    ["Arctic Warrior"]        = "Frost Quest Giver",
    ["Snow Lurker"]           = "Frost Quest Giver",

    -- Third Sea
    ["Reborn Skeleton"]       = "Haunted Castle Quest Giver 1",
    ["Living Zombie"]         = "Haunted Castle Quest Giver 1",
    ["Demonic Soul"]          = "Haunted Castle Quest Giver 2",
    ["Posessed Mummy"]        = "Haunted Castle Quest Giver 2",
    ["Peanut Scout"]          = "Peanut Quest Giver",
    ["Peanut President"]      = "Peanut Quest Giver",
    ["Ice Cream Chef"]        = "Ice Cream Quest Giver",
    ["Ice Cream Commander"]   = "Ice Cream Quest Giver",
    ["Cookie Crafter"]        = "Cake Quest Giver 1",
    ["Cake Guard"]            = "Cake Quest Giver 1",
    ["Baking Staff"]          = "Cake Quest Giver 2",
    ["Head Baker"]            = "Cake Quest Giver 2",
    ["Cocoa Warrior"]         = "Chocolate Quest Giver 1",
    ["Chocolate Bar Battler"] = "Chocolate Quest Giver 1",
    ["Sweet Thief"]           = "Chocolate Quest Giver 2",
    ["Candy Rebel"]           = "Chocolate Quest Giver 2",
    ["Candy Pirate"]          = "Candy Cane Quest Giver",
    ["Isle Outlaw"]           = "Tiki Quest Giver 1",
    ["Island Boy"]            = "Tiki Quest Giver 1",
    ["Isle Champion"]         = "Tiki Quest Giver 3",
    ["Forest Pirate"]         = "Marine Tree Quest Giver",
    ["Mythological Pirate"]   = "Marine Tree Quest Giver",
    ["Jungle Pirate"]         = "Deep Forest Quest Giver",
    ["Musketeer Pirate"]      = "Deep Forest Quest Giver",
    ["Fishman Raider"]        = "Hydra Town Quest Giver",   -- uncertain pairing
    ["Fishman Captain"]       = "Hydra Town Quest Giver",   -- uncertain pairing
}
P.giverNames = GIVER_NAMES

local QUESTS = {
    ["Bandit"]                = { "BanditQuest1", 1 },
    ["Monkey"]                = { "JungleQuest", 1 },
    ["Gorilla"]               = { "JungleQuest", 2 },
    ["Pirate"]                = { "BuggyQuest1", 1 },
    ["Brute"]                 = { "BuggyQuest1", 2 },
    ["Desert Bandit"]         = { "DesertQuest", 1 },
    ["Desert Officer"]        = { "DesertQuest", 2 },
    ["Snow Bandit"]           = { "SnowQuest", 1 },
    ["Snowman"]               = { "SnowQuest", 2 },
    ["Chief Petty Officer"]   = { "MarineQuest", 1 },
    ["Sky Bandit"]            = { "SkyQuest", 1 },
    ["Dark Master"]           = { "SkyQuest", 2 },
    ["Prisoner"]              = { "PrisonerQuest", 1 },
    ["Dangerous Prisoner"]    = { "PrisonerQuest", 2 },
    ["Toga Warrior"]          = { "ColosseumQuest", 1 },
    ["Gladiator"]             = { "ColosseumQuest", 2 },
    ["Military Soldier"]      = { "MagmaQuest", 1 },
    ["Military Spy"]          = { "MagmaQuest", 2 },
    ["Fishman Warrior"]       = { "FishmanQuest", 1 },
    ["Fishman Commando"]      = { "FishmanQuest", 2 },
    ["God's Guard"]           = { "SkyExp1Quest", 1 },
    ["Shanda"]                = { "SkyExp1Quest", 2 },
    ["Royal Squad"]           = { "SkyExp2Quest", 1 },
    ["Royal Soldier"]         = { "SkyExp2Quest", 2 },
    ["Galley Pirate"]         = { "FountainQuest", 1 },
    ["Galley Captain"]        = { "FountainQuest", 2 },
    ["Raider"]                = { "Area1Quest", 1 },
    ["Mercenary"]             = { "Area1Quest", 2 },
    ["Swan Pirate"]           = { "Area2Quest", 1 },
    ["Factory Staff"]         = { "Area2Quest", 2 },
    ["Marine Lieutenant"]     = { "MarineQuest2", 1 },
    ["Marine Captain"]        = { "MarineQuest2", 2 },
    ["Zombie"]                = { "ZombieQuest", 1 },
    ["Vampire"]               = { "ZombieQuest", 2 },
    ["Snow Trooper"]          = { "SnowMountainQuest", 1 },
    ["Winter Warrior"]        = { "SnowMountainQuest", 2 },
    ["Lab Subordinate"]       = { "IceSideQuest", 1 },
    ["Horned Warrior"]        = { "IceSideQuest", 2 },
    ["Magma Ninja"]           = { "MagmaSideQuest", 1 },
    ["Lava Pirate"]           = { "MagmaSideQuest", 2 },
    ["Ship Deckhand"]         = { "ShipQuest1", 1 },
    ["Ship Engineer"]         = { "ShipQuest1", 2 },
    ["Ship Steward"]          = { "ShipQuest2", 1 },
    ["Ship Officer"]          = { "ShipQuest2", 2 },
    ["Arctic Warrior"]        = { "FrostQuest", 1 },
    ["Snow Lurker"]           = { "FrostQuest", 2 },
    ["Sea Soldier"]           = { "ForgottenQuest", 1 },
    ["Water Fighter"]         = { "ForgottenQuest", 2 },
}
P.quests = QUESTS

-- Ask the server directly. This is the path that needs no NPC, no dialog and
-- no clicking, so it works even when the giver cannot be reached.
function P.startQuest(qname, tier)
    if not commF then
        P.lastQuestResult = "no CommF_ remote"
        return false
    end
    if P.questActive() then
        P.lastQuestResult = "a quest is already active - not re-taking"
        say(P.lastQuestResult)
        return false
    end
    tier = tier or 1
    local ok, res = pcall(function()
        return commF:InvokeServer("StartQuest", qname, tier)
    end)
    P.lastQuestResult = string.format("StartQuest %s t%d -> %s%s",
        tostring(qname), tier, ok and "" or "ERROR ", tostring(res))
    say(P.lastQuestResult)
    task.wait(0.4)
    return P.questActive()
end

-- Whatever we are farming, look up its quest and ask for it.
function P.startQuestForTarget()
    local names = {}
    if activeNames then for n in pairs(activeNames) do table.insert(names, n) end end
    if #names == 0 then
        -- resolveTargets is declared further down the file, so the level table
        -- is read directly rather than calling forward into an unset local
        local lv = playerLevel()
        if lv then
            for _, row in ipairs(LEVELS) do
                if lv >= row[1] and lv <= row[2] then table.insert(names, row[3]) end
            end
        end
    end
    for _, n in ipairs(names) do
        local q = QUESTS[n]
        if q then return P.startQuest(q[1], q[2]) end
    end
    P.lastQuestResult = "no quest name known for: " .. table.concat(names, ", ")
    say(P.lastQuestResult)
    return false
end

-- ---------------------------------------------------------
-- ACCEPTING, AND THE LOOP
-- ---------------------------------------------------------
-- Which quest belongs to what we are farming right now. The type being worked
-- wins, so a two-type rotation asks for the quest of the type in hand.
local function questForNames()
    local names = {}
    if P.focusName then table.insert(names, P.focusName) end
    if activeNames then
        for n in pairs(activeNames) do
            if n ~= P.focusName then table.insert(names, n) end
        end
    end
    if #names == 0 then
        local lv = playerLevel()
        if lv then
            for _, row in ipairs(LEVELS) do
                if lv >= row[1] and lv <= row[2] then table.insert(names, row[3]) end
            end
        end
    end
    for _, n in ipairs(names) do
        local q = QUESTS[n]
        if q then return q[1], q[2], n end
    end
    return nil, nil, names[1]
end
P.questForNames = questForNames

-- GIVER MEMORY, PER ENEMY.
-- Every island's quest giver is an ordinary NPC with its own name - Adventurer
-- in the Jungle, Villager in the Snow Village, and so on for every island.
-- Hard-coding that list means guessing, and a wrong guess sends the farm to
-- the wrong NPC. So the list is LEARNED instead: whenever an accept actually
-- works, the NPC that worked and the spot it was standing on are remembered
-- against the enemy being farmed, and every later accept goes straight there.
P.learnedGivers = {}     -- enemy name -> NPC name that worked
P.giverSpots    = {}     -- enemy name -> exact position that worked

local function currentEnemy()
    if P.questEnemy then return P.questEnemy end
    if P.focusName then return P.focusName end
    if activeNames then for n in pairs(activeNames) do return n end end
    return nil
end
P.currentEnemy = currentEnemy

function P.setGiverHere()
    local _, root = parts()
    if not root then return false end
    local e = currentEnemy()
    P.giverPos = root.Position
    if e then P.giverSpots[e] = root.Position end
    say("quest giver point saved" .. (e and (" for " .. e) or ""))
    return true
end

function P.clearGiver()
    local e = currentEnemy()
    P.giverPos = nil
    if e then
        P.giverSpots[e] = nil
        P.learnedGivers[e] = nil
    end
    say("quest giver point cleared")
end

-- What the panel shows for the enemy in hand.
function P.giverFor(enemy)
    enemy = enemy or currentEnemy()
    if not enemy then return nil, nil end
    return (CFG.QuestGiverName ~= "" and CFG.QuestGiverName)
        or P.learnedGivers[enemy] or GIVER_NAMES[enemy],
        P.giverSpots[enemy] or P.giverPos
end

-- ONE accept attempt.
--   * the remote is the path the dialog itself uses, so it is what is fired
--   * the NPC is used only for POSITION: some islands refuse the remote unless
--     you are standing at the giver
--   * if the remote leaves no tracker, the player's own path is tried: press E
--     at the giver, then click the dialog option naming our enemy
function P.acceptQuest(opts)
    opts = opts or {}
    if not commF then
        P.lastQuestResult = "no CommF_ remote"
        return false
    end
    if P.readQuest(true) and not opts.force then
        P.lastQuestResult = "already on a quest - not re-taking (that would reset it)"
        say(P.lastQuestResult)
        return false
    end

    local qname, tier, enemy = questForNames()
    -- Once a quest has been taken successfully, the loop repeats THAT one. You
    -- choose once; it does not drift onto a different quest because the type
    -- rotation moved on or a different enemy happened to be loaded.
    local locked = P.lockedQuest
    if locked and CFG.QuestLock ~= false then
        qname, tier, enemy = locked.name, locked.tier, locked.enemy
    end
    if CFG.QuestName and #tostring(CFG.QuestName) > 0 then qname = CFG.QuestName end
    if CFG.QuestTier then tier = CFG.QuestTier end
    tier = tier or 1
    if not qname then
        P.lastQuestResult = "no quest name known for " .. tostring(enemy or "this enemy")
        say(P.lastQuestResult)
        return false
    end

    local _, root = parts()
    local home = root and root.Position
    local atGiver = false

    if CFG.QuestHopToGiver then
        -- who to look for, best information first:
        --   1. the name you typed
        --   2. the name that WORKED here before
        --   3. the few names known up front
        --   4. nobody - just take the closest NPC wearing the "?" marker
        local want = CFG.QuestGiverName
        if (not want or want == "") and enemy then
            want = P.learnedGivers[enemy] or GIVER_NAMES[enemy]
        end

        local dest = (enemy and P.giverSpots[enemy]) or P.giverPos
        if not dest then
            local giver
            if want then
                giver = findQuestGiver(500, want) or findQuestGiver(3000, want)
            end
            -- closest-with-marker, which is what you want when nothing is set
            if not giver and CFG.QuestGiverClosest ~= false then
                giver = findQuestGiver(500, nil, true) or findQuestGiver(3000, nil, true)
                if giver then say("using the closest quest giver: " .. giver.name) end
            end
            giver = giver or findQuestGiver(3000, want)
            if giver then
                dest = giver.part.Position
                P.giverName = giver.name
            end
        end
        if dest then
            atGiver = true
            say("flying to the quest giver")
            clearHold()
            -- BESIDE it at its own height. The proximity check is a sphere
            -- around the NPC, and hovering overhead sits outside it.
            local stand = dest + Vector3.new(0, 3, 5)
            moveTo(stand, MOVE_SPEED)
            setHold(CFrame.new(stand, dest))
            task.wait(0.35)
        end
    end

    local ok, res = pcall(function()
        return commF:InvokeServer("StartQuest", qname, tier)
    end)
    task.wait(0.45)
    local q = P.readQuest(true)

    if not q and atGiver then
        say("remote refused - talking to the NPC")
        for _ = 1, 3 do
            pcall(function()
                VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                task.wait(0.07)
                VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
            end)
            task.wait(0.3)
        end
        pcall(clickQuestDialog, enemy)
        task.wait(0.5)
        q = P.readQuest(true)
    end

    questTakenAt   = os.clock()
    questBaseKills = stats.kills
    P.questEnemy   = enemy

    -- Learn from what worked. This is how the giver list builds itself instead
    -- of being guessed: the NPC and the spot are only remembered on success.
    if q and enemy then
        if P.giverName then P.learnedGivers[enemy] = P.giverName end
        local _, r = parts()
        if atGiver and r then P.giverSpots[enemy] = P.giverSpots[enemy] or r.Position end
        P.lockedQuest = { name = qname, tier = tier, enemy = enemy }
    end
    -- No tracker after a clean invoke means this island's tracker cannot be
    -- read, NOT that the accept failed. Re-asking would zero a running count,
    -- so from here the kills are counted locally instead.
    questBlind = (q == nil) and ok or false
    P.quest = q
    P.lastQuestResult = string.format("%s t%d -> %s", tostring(qname), tier,
        q and string.format("ACTIVE  %d/%d", q.have, q.need)
          or ("sent, tracker unreadable (" .. tostring(res) .. ")"))
    say(P.lastQuestResult)

    if atGiver and CFG.QuestReturnToFarm and home then
        clearHold()
        moveTo(home, MOVE_SPEED)
    end
    clearHold()
    if P.running then
        setState("ENGAGE")
        progress()
    end
    return q ~= nil or questBlind
end

-- Old name, same thing. The QUEST button still calls this.
function P.takeQuest() return P.acceptQuest() end

-- Clears the accept timer so the next pass takes a quest immediately. Called
-- when the loop is switched on and whenever a run starts.
function P.armQuest()
    lastQuestAt  = 0
    questBlind   = false
    P.questEnemy = nil
end

-- The loop: exactly one quest running at all times, and never two accepts for
-- one count. Called every pass of the main loop while AUTO QUEST is on.
function P.questCycle()
    local q = P.readQuest(true)
    P.quest = q

    if q then
        questBlind = false
        P.questProgress = q.have .. "/" .. q.need
        if q.have < q.need then return end                 -- still working it
        if os.clock() - questTakenAt < 2 then return end   -- accepted a moment ago
        say("quest complete - taking the next one")
    elseif questBlind then
        -- unreadable tracker: count our own kills against the assumed quota
        local done = stats.kills - questBaseKills
        P.questProgress = done .. "/" .. CFG.QuestKillsFallback .. " (counted here)"
        if done < CFG.QuestKillsFallback and os.clock() - questTakenAt < 900 then
            return
        end
    else
        P.questProgress = "none"
    end

    if os.clock() - lastQuestAt < CFG.QuestRetrySeconds then return end
    lastQuestAt = os.clock()
    -- A tracker still showing a FINISHED count would make the next accept
    -- refuse itself as a duplicate and the loop would stall there forever.
    -- Overriding is safe in exactly this case: the count is already done, so
    -- there is no progress left to reset.
    P.acceptQuest({ force = (q ~= nil and q.have >= q.need) })
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
        -- This rung used to assign to a variable nothing ever read, so the
        -- first rung of the ladder did nothing at all and the farm spent
        -- StuckSeconds achieving it. Dropping the hold is the real version:
        -- the next pass re-seats on the target from scratch.
        say("stuck: releasing the hold and re-seating")
        clearHold()
        cancelMove()

    elseif escalation == 2 then
        say("stuck: re-equipping weapon")
        equipWeapon()
        clearHold()

    elseif escalation == 3 then
        say("stuck: reinstalling fast attack")
        installFastAttack()
        equipWeapon()
        clearHold()

    elseif escalation == 4 then
        say("stuck: blacklisting target, moving on")
        if currentCluster then
            for _, e in ipairs(currentCluster.members) do
                blacklist[e.model] = os.clock() + 60
            end
        end
        clearHold()
        setState("RESOLVE")
    end
end

-- =========================================================
-- TYPE ROTATION
-- =========================================================
-- Picking Snow Bandit and Snowman does not mean fighting them as one pile.
-- They occupy different parts of the island and each has its own leash, so a
-- mixed gather is mostly enemies that cannot be damaged. One type is worked to
-- exhaustion at that type's own centre, then the next type's centre.
local function locFor(name)
    for _, row in ipairs(LEVELS) do
        if row[3] == name then return row[4] end
    end
    return nil
end

local function setFocus(i)
    typeSince = os.clock()
    local n = typeOrder[i]
    focusSet = n and { [n] = true } or nil
    P.focusName = n
    if n then
        travelGoal = locFor(n) or travelGoal
        say(string.format("type %d/%d: %s", i, #typeOrder, n))
    end
end

local function rotateType()
    typeSince = os.clock()
    if #typeOrder < 2 then return end
    typeIdx = (typeIdx % #typeOrder) + 1
    setFocus(typeIdx)
end
P.nextType = rotateType

local function buildTypeOrder(names)
    table.clear(typeOrder)
    if names then
        for n in pairs(names) do table.insert(typeOrder, n) end
        table.sort(typeOrder)
    end
    typeIdx = 1
    setFocus(1)
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
    progress()
end

local function step()
    local _, root = parts()
    if not root then
        say("waiting for character")
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
        buildTypeOrder(names)
        setState("ENGAGE")
        progress()
        return
    end

    -- ---------- QUEST CYCLE ----------
    -- accept -> fight -> the tracker clears itself -> accept the next one.
    -- Nothing here needs a button press, and nothing is re-taken mid-count.
    if CFG.AutoQuest and not anyEnemyMode then
        pcall(P.questCycle)
    end

    -- ---------- find work ----------
    -- While rotating, only the focused type counts as work.
    local wantNames = (CFG.RotateTypes and focusSet) or activeNames
    activeFilter = wantNames
    local list = liveEnemies(wantNames)

    -- A quest counts kills of ONE species, so while the quest loop is running
    -- that species outranks the rotation: killing anything else moves nothing.
    if CFG.AutoQuest and P.questEnemy then
        local qset = { [P.questEnemy] = true }
        local qlist = liveEnemies(qset)
        if #qlist > 0 then
            activeFilter, list = qset, qlist
        end
    end

    -- this type is finished here: move on to the next selected type
    if #list == 0 and CFG.RotateTypes and #typeOrder > 1 then
        rotateType()
        activeFilter = focusSet
        list = liveEnemies(focusSet)
    end

    -- Primaries are all dead and on a respawn timer. Instead of hovering over
    -- empty ground, work the BACKUP names until they come back.
    if #list == 0 and CFG.UseSecondary and secondaryNames and next(secondaryNames) then
        list = liveEnemies(secondaryNames)
        if #list > 0 then
            activeFilter = secondaryNames
            say("primary respawning - on backup targets")
        end
    end

    if #list == 0 and CFG.AnyEnemyFallback and activeNames then
        activeFilter = nil           -- nothing selected is loaded: take any EXP
        list = liveEnemies(nil)
        if #list > 0 then say("selected enemies absent - hitting what is loaded") end
    end

    if #list == 0 then
        -- ---------- TRAVEL ----------
        if travelGoal then
            if state ~= "TRAVEL" then
                setState("TRAVEL")
                stats.travels += 1
            end
            say("no targets loaded - flying to the farm spot")
            -- Stepped flight, not a tween: a tween across open water outruns
            -- the streaming system and drops you into unloaded space.
            P.flyTo(travelGoal)
            task.wait(0.3)
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

    -- Position on THIS type's patch of the island. homePos is where each one
    -- was first seen, so the centre is the species' real ground, not a point
    -- skewed by enemies a previous pull already moved.
    if CFG.RotateTypes and CFG.TypeCentre and #list > 1 then
        local sum = Vector3.zero
        for _, e in ipairs(list) do
            sum += (homePos[e.model] or e.root.Position)
        end
        local centre = sum / #list
        if (root.Position - centre).Magnitude > CFG.RecentreDistance then
            say("centring on " .. tostring(P.focusName or "targets"))
            moveTo(centre + Vector3.new(0, CFG.HoverHeight, 0), MOVE_SPEED)
            setAnchor(centre, nil)
            local _, r2 = parts()
            if r2 then root = r2 end
        end
    end

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
        setHold(flatCF(root.CFrame))
    else
        -- Go to it, slightly above so melee AI cannot path to us.
        local goal = target.root.Position + Vector3.new(0, CFG.HoverHeight, 0)
        moveTo(goal, MOVE_SPEED)
        setAnchor(target.root.Position, target.root.Position)
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
            if not holdCF then setHold(flatCF(r.CFrame)) end
        else
            -- follow it: the anchor is the ground point, so hover height and
            -- tilt stay live while the hold loop does the actual pinning
            setAnchor(target.root.Position, target.root.Position)
            local tp = target.root.Position + Vector3.new(0, CFG.HoverHeight, 0)
            if (r.Position - tp).Magnitude > 12 then
                r.CFrame = CFrame.new(tp, target.root.Position)
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

    -- time is up on this type even if it is not exhausted
    if CFG.RotateTypes and #typeOrder > 1
        and os.clock() - typeSince > CFG.TypeDwell then
        rotateType()
    end

    if os.clock() - stateEnteredAt > CFG.EngageTimeout then
        say("engage timeout - re-resolving")
        setState("RESOLVE")
    end
end

-- Generation token. Every restart (teleport, respawn, START) spawns a fresh
-- loop, and without this the old one kept running beside it - two loops
-- fighting over one character is what produced the random re-targeting.
local mainGen, dogGen = 0, 0

local function mainLoop()
    mainGen += 1
    local gen = mainGen
    while P.running and gen == mainGen do
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
    dogGen += 1
    local gen = dogGen
    local lastSeen = os.clock()
    local lastSwings = stats.swings
    while P.running and gen == dogGen do
        task.wait(5)
        if stats.swings ~= lastSwings then
            lastSwings = stats.swings
            lastSeen = os.clock()
        elseif os.clock() - lastSeen > 20 and state == "ENGAGE" then
            say("watchdog: no swings in 20s - forcing re-resolve")
            escalation = 0
            setState("RESOLVE")
            lastSeen = os.clock()
        end
    end
end

-- =========================================================
-- TELEPORT
-- =========================================================
-- THE SPAWN-POINT TRICK IS DEAD.
-- teliport.txt did this: SetLastSpawnPoint -> destroy the character -> the
-- server rebuilds the body at the new point. It worked for years. It does not
-- work now: the body is destroyed and you come back exactly where you were,
-- which is precisely the "teleport only deletes me" symptom.
--
-- So the primary engine here is not a respawn at all. It is what the working
-- script hubs do now: FLY there, in small CFrame steps, at altitude.
--   * one giant CFrame write is what trips the anti-cheat and outruns the
--     streaming system, so you arrive inside unloaded space and fall
--   * a chain of small writes reads as fast movement, which the game allows,
--     and it is the same mechanism that already puts this farm on every enemy
-- Rise to cruise height, cross in steps, descend, hold. Nothing is destroyed,
-- no respawn is involved, and there is no state where you end up dead.
--
-- The respawn path is kept as a SECOND engine with a ladder of four ways to
-- force the respawn, because when a server does honour it, it is the only way
-- to cross water the client cannot stream through.
local TeleportService = game:GetService("TeleportService")

local function spawnsFolder()
    local wo = workspace:FindFirstChild("_WorldOrigin")
    return wo and wo:FindFirstChild("PlayerSpawns") or nil
end

local function teamSpawnFolder()
    local ps = spawnsFolder()
    if not ps then return nil end
    local team = (player.Team and player.Team.Name) or "Pirates"
    return ps:FindFirstChild(team)
        or ps:FindFirstChild("Pirates")
        or ps:GetChildren()[1]
end

function P.spawnList()
    local folder = teamSpawnFolder()
    local names = {}
    if folder then
        for _, sp in ipairs(folder:GetChildren()) do table.insert(names, sp.Name) end
    end
    table.sort(names)
    return names
end

function P.spawnPos(name)
    local folder = teamSpawnFolder()
    local sp = folder and folder:FindFirstChild(name)
    if not sp then return nil end
    if sp:IsA("BasePart") then return sp.Position end
    local part = sp:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

function P.resolveSpawn(name)
    if not name or name == "" then return nil end
    local list = P.spawnList()
    for _, n in ipairs(list) do if n == name then return n end end
    local low = string.lower(name)
    for _, n in ipairs(list) do if string.lower(n) == low then return n end end
    for _, n in ipairs(list) do
        if string.find(string.lower(n), low, 1, true) then return n end
    end
    return nil
end

-- Every farm spot the level table knows about, built once.
function P.farmSpots()
    if P._spots then return P._spots end
    local out, seen = {}, {}
    for _, row in ipairs(LEVELS) do
        if not seen[row[3]] then
            seen[row[3]] = true
            table.insert(out, { name = row[3], pos = row[4], min = row[1], max = row[2] })
        end
    end
    P._spots = out
    return out
end

-- One list for the panel: server spawn points first (they can be reached both
-- ways), then the farm spots, which can only be flown to.
function P.destinations()
    local out = {}
    for _, n in ipairs(P.spawnList()) do
        table.insert(out, { name = n, pos = P.spawnPos(n), kind = "island", spawn = n })
    end
    for _, s in ipairs(P.farmSpots()) do
        table.insert(out, { name = s.name, pos = s.pos, kind = "farm",
                            label = "lv " .. s.min .. "-" .. s.max })
    end
    return out
end

function P.findDestination(name)
    if not name or name == "" then return nil end
    local low = string.lower(name)
    local all = P.destinations()
    for _, d in ipairs(all) do if d.name == name then return d end end
    for _, d in ipairs(all) do if string.lower(d.name) == low then return d end end
    for _, d in ipairs(all) do
        if string.find(string.lower(d.name), low, 1, true) then return d end
    end
    return nil
end

-- ---------------------------------------------------------
-- COUNTDOWN OVERLAY
-- ---------------------------------------------------------
-- The countdown is REAL, not decoration: nothing moves until it reaches zero,
-- so the hop can still be called off. That is how the game's own fast travel
-- behaves, and it is why a mis-click costs nothing.
local travelBusy   = false
local travelCancel = false

local function makeOverlay(destination)
    local host = (gethui and gethui()) or player:FindFirstChild("PlayerGui")
    if not host then return nil end
    local old = host:FindFirstChild("BFPTeleport")
    if old then pcall(function() old:Destroy() end) end

    local sg = Instance.new("ScreenGui")
    sg.Name = "BFPTeleport"
    sg.IgnoreGuiInset = true
    sg.ResetOnSpawn = false
    sg.DisplayOrder = 999
    sg.Parent = host

    local dim = Instance.new("TextButton")
    dim.Size = UDim2.fromScale(1, 1)
    dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    dim.BackgroundTransparency = 0.45
    dim.BorderSizePixel = 0
    dim.AutoButtonColor = false
    dim.Text = ""
    dim.Parent = sg

    local card = Instance.new("Frame")
    card.Size = UDim2.fromOffset(300, 188)
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.BackgroundColor3 = Color3.fromRGB(24, 24, 27)
    card.BorderSizePixel = 0
    card.Parent = sg
    local cc = Instance.new("UICorner") cc.CornerRadius = UDim.new(0, 20) cc.Parent = card
    local cs = Instance.new("UIStroke")
    cs.Color = Color3.fromRGB(70, 70, 78)
    cs.Transparency = 0.5
    cs.Parent = card

    local function text(y, h, size, font, colour)
        local t = Instance.new("TextLabel")
        t.Size = UDim2.new(1, -32, 0, h)
        t.Position = UDim2.fromOffset(16, y)
        t.BackgroundTransparency = 1
        t.Font = font
        t.TextSize = size
        t.TextColor3 = colour
        t.TextTruncate = Enum.TextTruncate.AtEnd
        t.Parent = card
        return t
    end

    local head = text(20, 16, 13, Enum.Font.GothamMedium, Color3.fromRGB(142, 142, 147))
    head.Text = "TELEPORTING TO"
    local dest = text(38, 24, 19, Enum.Font.GothamBold, Color3.fromRGB(245, 245, 247))
    dest.Text = destination
    local clock = text(68, 44, 40, Enum.Font.GothamBold, Color3.fromRGB(10, 132, 255))
    clock.Text = "3.0"
    local note = text(150, 16, 12, Enum.Font.Gotham, Color3.fromRGB(120, 120, 128))
    note.Text = "click anywhere to cancel"

    local barBG = Instance.new("Frame")
    barBG.Size = UDim2.new(1, -32, 0, 4)
    barBG.Position = UDim2.fromOffset(16, 128)
    barBG.BackgroundColor3 = Color3.fromRGB(58, 58, 62)
    barBG.BorderSizePixel = 0
    barBG.Parent = card
    local bbc = Instance.new("UICorner") bbc.CornerRadius = UDim.new(1, 0) bbc.Parent = barBG

    local bar = Instance.new("Frame")
    bar.Size = UDim2.fromScale(0, 1)
    bar.BackgroundColor3 = Color3.fromRGB(10, 132, 255)
    bar.BorderSizePixel = 0
    bar.Parent = barBG
    local bc = Instance.new("UICorner") bc.CornerRadius = UDim.new(1, 0) bc.Parent = bar

    dim.Activated:Connect(function() travelCancel = true end)

    return {
        tick = function(secondsLeft, total)
            clock.Text = string.format("%.1f", math.max(secondsLeft, 0))
            bar.Size = UDim2.fromScale(
                math.clamp(1 - (secondsLeft / math.max(total, 0.01)), 0, 1), 1)
        end,
        phase = function(big, small, progress)
            clock.Text = big
            clock.TextSize = (#big > 4) and 20 or 40
            note.Text = small or ""
            if progress then bar.Size = UDim2.fromScale(math.clamp(progress, 0, 1), 1) end
        end,
        kill = function() pcall(function() sg:Destroy() end) end,
    }
end

function P.cancelTravel() travelCancel = true end
function P.travelling() return travelBusy end

-- ---------------------------------------------------------
-- ENGINE 1: FLY
-- ---------------------------------------------------------
-- Small steps, every Heartbeat, velocity killed each one. The step size is the
-- whole trick: big enough to cross an ocean in a couple of seconds, small
-- enough that the server sees movement rather than a jump.
local function hopTo(pos, overlay, phaseName, totalDistance, doneSoFar)
    local step = math.max(CFG.TravelStep or 220, 20)
    local guard = 0
    while true do
        if travelCancel then return false end
        local _, r = parts()
        if not r then return false end
        local delta = pos - r.Position
        local d = delta.Magnitude
        if d < 8 then return true end
        r.CFrame = CFrame.new(r.Position + delta.Unit * math.min(step, d))
        killVelocity(r)
        if overlay and totalDistance and totalDistance > 0 then
            overlay.phase(phaseName, string.format("%.0f studs to go", d),
                ((doneSoFar or 0) + (totalDistance - d)) / totalDistance)
        end
        guard += 1
        if guard > 4000 then return false end
        RunService.Heartbeat:Wait()
    end
end

-- MEASURED, not assumed. The game's own house button was watched doing this:
--   CLICK  Main.HUDButtonBar.HomeButton
--   MOVED  1590 studs -> -1196.9, 10.1, 1873.7      5.7s after the press
--   body was NOT replaced
-- No respawn, no spawn point, and the 5.7s was the game's own countdown, not
-- travel time. The travel itself was one jump. So a direct CFrame write is not
-- something the game merely tolerates - it is the game's own mechanism, and it
-- is the default here.
--
-- The only real hazard is arriving before the world streams in and dropping
-- through ground that does not exist yet, which is what the settle hold is for.
local function instantTravel(target, overlay)
    local _, root = parts()
    if not root then return false, "no character" end
    local land = target + Vector3.new(0, CFG.HoverHeight, 0)

    clearHold()
    cancelMove()
    startStabilizer()
    if overlay then overlay.phase("GO", "arriving", 0.5) end

    root.CFrame = CFrame.new(land)
    killVelocity(root)
    setHold(CFrame.new(land))

    -- Re-assert every frame while the chunks load. One write is undone by
    -- physics within a frame, exactly like the hover hold.
    local settle = math.max(CFG.TeleportSettle or 2, 0.2)
    local deadline = os.clock() + settle
    while os.clock() < deadline do
        if travelCancel then break end
        local _, r = parts()
        if r then
            r.CFrame = CFrame.new(land)
            killVelocity(r)
        end
        if overlay then
            overlay.phase("...", "letting the island load",
                0.5 + 0.5 * (1 - (deadline - os.clock()) / settle))
        end
        RunService.Heartbeat:Wait()
    end

    setAnchor(target, nil)
    local _, r2 = parts()
    local off = r2 and (r2.Position - land).Magnitude or 9999
    -- A server that refuses the write snaps you back, and the distance says so.
    return off < 120, string.format("%.0f studs off", off)
end

local function steppedTravel(target, overlay)
    local _, root = parts()
    if not root then return false, "no character" end

    -- Cruise above everything between here and there. Mountains, island walls
    -- and the Sky islands all sit below this.
    local cruiseY = math.max(root.Position.Y, target.Y) + (CFG.TravelAltitude or 350)
    local start   = root.Position
    local up      = Vector3.new(start.X, cruiseY, start.Z)
    local over    = Vector3.new(target.X, cruiseY, target.Z)
    local land    = target + Vector3.new(0, CFG.HoverHeight, 0)
    local total   = (up - start).Magnitude + (over - up).Magnitude + (land - over).Magnitude

    clearHold()
    cancelMove()
    startStabilizer()          -- collisions off, velocity killed every frame

    if not hopTo(up, overlay, "UP", total, 0) then return false, "cancelled on the climb" end
    if not hopTo(over, overlay, "CROSS", total, (up - start).Magnitude) then
        return false, "cancelled mid-crossing"
    end
    if not hopTo(land, overlay, "DOWN", total,
        (up - start).Magnitude + (over - up).Magnitude) then
        return false, "cancelled on the descent"
    end

    setAnchor(target, nil)
    local _, r = parts()
    local off = r and (r.Position - land).Magnitude or 9999
    return off < 60, string.format("%.0f studs off the mark", off)
end

-- Instant first, stepped as the fallback. Nothing here needs the user to pick.
local function flyTravel(target, overlay)
    if (CFG.TeleportStyle or "instant") == "stepped" then
        return steppedTravel(target, overlay)
    end
    local ok, detail = instantTravel(target, overlay)
    if ok then return true, "instant, " .. tostring(detail) end
    if travelCancel then return false, "cancelled" end
    if overlay then overlay.phase("...", "snapped back - crossing in steps") end
    local ok2, d2 = steppedTravel(target, overlay)
    return ok2, "instant refused (" .. tostring(detail) .. ") then stepped, " .. tostring(d2)
end

-- ---------------------------------------------------------
-- ENGINE 2: RESPAWN
-- ---------------------------------------------------------
-- Kept because it is the only way through water the client will not stream.
-- Four ways to force the respawn, cheapest first, because which of them a
-- given server honours changes with every Blox Fruits update - and a single
-- hard-coded one silently doing nothing is exactly how this broke before.
local function waitForNewBody(oldChar, seconds)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        local c, r = parts()
        if c and r and c ~= oldChar then return true end
        task.wait(0.15)
    end
    return false
end

local function respawnTravel(spawnName, overlay)
    if not commF then return false, "no CommF_ remote" end

    local ok, res = pcall(function()
        return commF:InvokeServer("SetLastSpawnPoint", spawnName)
    end)
    local detail = ok and tostring(res) or ("ERROR " .. tostring(res))
    task.wait((player:GetNetworkPing() * 2) + 0.05)

    local oldChar = player.Character
    local hum = oldChar and oldChar:FindFirstChildOfClass("Humanoid")
    local rungs = {
        { "asking the humanoid to die", function()
            if hum then hum.Health = 0 end
        end },
        { "breaking the joints", function()
            if oldChar then oldChar:BreakJoints() end
        end },
        { "re-joining the team", function()
            local team = (player.Team and player.Team.Name) or "Pirates"
            commF:InvokeServer("SetTeam2", team)
        end },
        { "destroying the character", function()
            local head = oldChar and oldChar:FindFirstChild("Head")
            if head then head:Destroy() end
            task.wait()
            if oldChar then oldChar:Destroy() end
        end },
    }

    for i, rung in ipairs(rungs) do
        if travelCancel then return false, "cancelled" end
        if overlay then overlay.phase("...", rung[1], i / #rungs) end
        pcall(rung[2])
        if waitForNewBody(oldChar, 4) then
            task.wait(0.8)
            return true, detail .. " | respawned via " .. rung[1]
        end
    end
    return false, detail .. " | the server refused every respawn"
end

-- ---------------------------------------------------------
-- THE HOP
-- ---------------------------------------------------------
function P.travelTo(name, opts)
    opts = opts or {}
    if travelBusy then
        P.lastTravel = "already teleporting"
        return false
    end

    local dest = P.findDestination(name)
    if not dest or not dest.pos then
        P.lastTravel = (#P.spawnList() == 0)
            and "world has not streamed in yet - try again in a moment"
            or  ("no destination called " .. tostring(name))
        say(P.lastTravel)
        return false
    end

    local _, root = parts()
    if not root then
        P.lastTravel = "no living character"
        say(P.lastTravel)
        return false
    end

    travelBusy, travelCancel = true, false
    local before  = root.Position
    local overlay = (CFG.TeleportOverlay ~= false) and makeOverlay(dest.name) or nil

    -- Freeze the farm for the duration. A tween or a held CFrame fighting the
    -- teleport is what used to leave the loop spinning on errors.
    local wasRunning = P.running
    P.running = false
    cancelMove()
    clearHold()
    stopPuller()
    stats.travels += 1
    say("teleporting to " .. dest.name)

    local arrived, detail = false, ""
    local mode = opts.mode or CFG.TeleportMode or "auto"
    local distance = (dest.pos - before).Magnitude

    local ranOk = pcall(function()
        -- countdown, cancellable
        local total = math.max(CFG.TeleportCountdown or 3, 0)
        local left = total
        while left > 0 do
            if travelCancel then return end
            if overlay then overlay.tick(left, total) end
            task.wait(0.1)
            left -= 0.1
        end
        if travelCancel then return end

        -- AUTO: fly unless it is a long haul to a real spawn point, where the
        -- respawn is both instant and immune to anything in between. If the
        -- respawn is refused, the flight still runs - so auto never dead-ends.
        local useRespawn = (mode == "respawn")
            or (mode == "auto" and dest.spawn ~= nil
                and distance > (CFG.FlyMaxDistance or 6000))

        if useRespawn then
            arrived, detail = respawnTravel(dest.spawn, overlay)
            if arrived then
                local _, r = parts()
                local off = r and (r.Position - dest.pos).Magnitude or 9999
                if off > 800 then
                    -- server sent us somewhere else: fly the rest
                    if overlay then overlay.phase("...", "finishing on foot") end
                    arrived, detail = flyTravel(dest.pos, overlay)
                end
            elseif mode == "auto" then
                if overlay then overlay.phase("...", "respawn refused - flying instead") end
                arrived, detail = flyTravel(dest.pos, overlay)
            end
        else
            arrived, detail = flyTravel(dest.pos, overlay)
        end
    end)

    local _, nr = parts()
    local moved = nr and (nr.Position - before).Magnitude or 0
    if travelCancel then
        P.lastTravel = "cancelled"
    else
        P.lastTravel = string.format("%s -> %s  (%s, moved %.0f)", dest.name,
            arrived and "ARRIVED" or "FAILED", tostring(detail), moved)
    end
    if not ranOk then P.lastTravel = P.lastTravel .. "  [recovered from an error]" end
    say(P.lastTravel)

    if overlay then overlay.kill() end
    travelBusy, travelCancel = false, false

    if wasRunning then
        P.running = true
        equipWeapon()
        startStabilizer()
        syncPuller()
        setState("RESOLVE")
        progress()
        task.spawn(mainLoop)
        task.spawn(watchdog)
    end
    return arrived
end

-- Hop without the ceremony: no countdown, no overlay. Used by the farm-spot
-- rows and by the farm itself when its targets are not loaded here.
-- Anything beyond line of sight goes up and over, because a flat crossing at
-- ground level walks you into an island wall or the sea floor.
function P.flyTo(position)
    if not position then return false end
    local _, root = parts()
    if not root then return false end
    travelCancel = false        -- a cancelled teleport must not poison this
    clearHold()
    startStabilizer()
    local ok
    if (position - root.Position).Magnitude > 120 then
        ok = flyTravel(position, nil)      -- instant, with the stepped fallback
    else
        ok = hopTo(position + Vector3.new(0, CFG.HoverHeight, 0), nil, nil, nil, nil)
    end
    setAnchor(position, nil)
    say(ok and "arrived" or "could not reach that point")
    return ok
end

function P.forceRespawn()
    local oldChar = player.Character
    local hum = oldChar and oldChar:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum.Health = 0 end) end
    if not waitForNewBody(oldChar, 3) and commF then
        local team = (player.Team and player.Team.Name) or "Pirates"
        pcall(function() commF:InvokeServer("SetTeam2", team) end)
    end
    say("forced a respawn")
    return true
end

-- ---------------------------------------------------------
-- SEAS
-- ---------------------------------------------------------
-- The three seas are three separate Roblox places, so crossing them is a
-- server hop, not a teleport: this session ends and the farm restarts on the
-- other side. The game still enforces its own level and item requirements, so
-- a server you are not allowed into will simply send you back.
local SEAS = {
    { name = "First Sea",  id = 2753915549 },
    { name = "Second Sea", id = 4442272183 },
    { name = "Third Sea",  id = 7449423635 },
}
function P.seas() return SEAS end

function P.hopSea(placeId)
    if game.PlaceId == placeId then
        say("already in that sea")
        return false
    end
    say("leaving this server")
    local ok = pcall(function() TeleportService:Teleport(placeId, player) end)
    if not ok then say("the server refused the sea hop") end
    return ok
end

-- =========================================================
-- UI
-- =========================================================
-- One rule decided this rewrite: a control you have to think about is a broken
-- control. So there is exactly ONE primary button, every toggle looks like a
-- toggle and nothing else does, every number you might want to feel your way
-- to is a slider you drag, and the status line under the title always says in
-- plain words what the farm is doing right now.
--
-- Things deliberately NOT here: duplicate paths to the same action, warning
-- paragraphs in orange, and any control whose label needs a manual.
local gui
local function buildUI()
    local pg = player:WaitForChild("PlayerGui", 10)
    if not pg then return end
    local old = pg:FindFirstChild("BFPHUD")
    if old then old:Destroy() end

    local UIS = game:GetService("UserInputService")

    -- iOS system palette. One accent, one positive, one negative; everything
    -- else is a grey. Colour carries meaning here, it is not decoration.
    local C = {
        bg     = Color3.fromRGB(20, 20, 22),
        card   = Color3.fromRGB(30, 30, 34),
        card2  = Color3.fromRGB(44, 44, 49),
        line   = Color3.fromRGB(62, 62, 68),
        text   = Color3.fromRGB(245, 245, 247),
        dim    = Color3.fromRGB(142, 142, 147),
        faint  = Color3.fromRGB(99, 99, 105),
        accent = Color3.fromRGB(10, 132, 255),
        green  = Color3.fromRGB(48, 209, 88),
        red    = Color3.fromRGB(255, 69, 58),
        amber  = Color3.fromRGB(255, 159, 10),
    }

    local function mk(class, props)
        local o = Instance.new(class)
        local parent = props.Parent
        props.Parent = nil
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end

    local function corner(o, r)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, r)
        c.Parent = o
        return c
    end

    gui = mk("ScreenGui", {
        Name = "BFPHUD", ResetOnSpawn = false, IgnoreGuiInset = true,
        DisplayOrder = 45, Parent = pg,
    })

    -- ---------- shell ----------
    local panel = mk("Frame", {
        Size = UDim2.fromOffset(372, 548),
        Position = UDim2.new(1, -388, 0, 16),
        BackgroundColor3 = C.bg, BorderSizePixel = 0,
        Active = true, Draggable = true, Parent = gui,
    })
    corner(panel, 18)
    mk("UIStroke", { Color = C.line, Transparency = 0.55, Parent = panel })

    local title = mk("TextLabel", {
        Size = UDim2.fromOffset(160, 22), Position = UDim2.fromOffset(18, 14),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 17,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.text,
        Text = "Farm Pro", Parent = panel,
    })

    local dot = mk("Frame", {
        Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(252, 21),
        BackgroundColor3 = C.faint, BorderSizePixel = 0, Parent = panel,
    })
    corner(dot, 4)

    local stateLbl = mk("TextLabel", {
        Size = UDim2.fromOffset(60, 16), Position = UDim2.fromOffset(264, 17),
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.dim,
        Text = "idle", Parent = panel,
    })

    local hideBtn = mk("TextButton", {
        Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, -40, 0, 13),
        BackgroundColor3 = C.card, Font = Enum.Font.GothamBold, TextSize = 14,
        TextColor3 = C.dim, Text = "×", AutoButtonColor = false, Parent = panel,
    })
    corner(hideBtn, 13)

    -- Hidden, not destroyed. Closing a panel should never end the run, and a
    -- run with no way back to its controls is worse than no panel at all.
    local restore = mk("TextButton", {
        Size = UDim2.fromOffset(44, 44), Position = UDim2.new(1, -60, 0, 16),
        BackgroundColor3 = C.accent, Font = Enum.Font.GothamBold, TextSize = 16,
        TextColor3 = C.text, Text = "BF", Visible = false, Parent = gui,
    })
    corner(restore, 22)
    hideBtn.Activated:Connect(function()
        panel.Visible = false
        restore.Visible = true
    end)
    restore.Activated:Connect(function()
        panel.Visible = true
        restore.Visible = false
    end)

    -- ---------- primary action ----------
    local runBtn = mk("TextButton", {
        Size = UDim2.new(1, -36, 0, 44), Position = UDim2.fromOffset(18, 48),
        BackgroundColor3 = C.accent, Font = Enum.Font.GothamBold, TextSize = 15,
        TextColor3 = C.text, Text = "Start farming", AutoButtonColor = false,
        Parent = panel,
    })
    corner(runBtn, 13)

    local statusLbl = mk("TextLabel", {
        Size = UDim2.new(1, -36, 0, 14), Position = UDim2.fromOffset(18, 98),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.dim,
        TextTruncate = Enum.TextTruncate.AtEnd, Text = "", Parent = panel,
    })

    -- ---------- tabs ----------
    local TABS = { "Farm", "Quest", "Travel", "Setup", "Stats" }
    local pages, segs = {}, {}
    local current = "Farm"

    local segBG = mk("Frame", {
        Size = UDim2.new(1, -36, 0, 30), Position = UDim2.fromOffset(18, 118),
        BackgroundColor3 = C.card, BorderSizePixel = 0, Parent = panel,
    })
    corner(segBG, 9)

    local function showTab(name)
        current = name
        for n, page in pairs(pages) do page.Visible = (n == name) end
        for n, b in pairs(segs) do
            b.BackgroundColor3 = (n == name) and C.card2 or C.card
            b.TextColor3 = (n == name) and C.text or C.dim
        end
    end

    for i, name in ipairs(TABS) do
        local b = mk("TextButton", {
            Size = UDim2.new(1 / #TABS, -4, 1, -6),
            Position = UDim2.new((i - 1) / #TABS, 2, 0, 3),
            BackgroundColor3 = C.card, Font = Enum.Font.GothamMedium, TextSize = 11,
            TextColor3 = C.dim, Text = name, AutoButtonColor = false, Parent = segBG,
        })
        corner(b, 7)
        b.Activated:Connect(function() showTab(name) end)
        segs[name] = b

        local page = mk("ScrollingFrame", {
            Size = UDim2.new(1, -24, 1, -166), Position = UDim2.fromOffset(12, 158),
            BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
            ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(),
            Visible = false, Parent = panel,
        })
        local l = mk("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = page,
        })
        mk("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = page })
        l:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            page.CanvasSize = UDim2.new(0, 0, 0, l.AbsoluteContentSize.Y + 16)
        end)
        pages[name] = page
    end

    -- =====================================================
    -- WIDGETS
    -- =====================================================
    local live = {}
    local order = 0
    local function nextOrder() order += 1 return order end

    -- One shared drag handler for every slider. Per-slider connections leak
    -- and fight each other; one pointer to the slider being dragged does not.
    local dragTarget = nil
    UIS.InputChanged:Connect(function(i)
        if dragTarget and (i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch) then
            dragTarget(i.Position.X)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragTarget = nil
        end
    end)

    local function group(page, heading)
        if heading then
            mk("TextLabel", {
                Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
                Font = Enum.Font.GothamBold, TextSize = 10,
                TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.faint,
                Text = string.upper(heading), LayoutOrder = nextOrder(), Parent = page,
            })
        end
        local card = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = C.card, BorderSizePixel = 0,
            LayoutOrder = nextOrder(), Parent = page,
        })
        corner(card, 14)
        mk("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2), Parent = card,
        })
        mk("UIPadding", {
            PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
            PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = card,
        })
        return card
    end

    local function note(parent, text)
        return mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.faint,
            TextWrapped = true, Text = text, LayoutOrder = nextOrder(), Parent = parent,
        })
    end

    local function infoLine(parent, get)
        local t = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.dim,
            TextWrapped = true, Text = "", LayoutOrder = nextOrder(), Parent = parent,
        })
        table.insert(live, function() t.Text = get() end)
        return t
    end

    local function switch(parent, titleText, sub, get, set)
        local h = sub and 46 or 34
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = parent,
        })
        mk("TextLabel", {
            Size = UDim2.new(1, -60, 0, 18), Position = UDim2.fromOffset(0, sub and 5 or 8),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.text,
            Text = titleText, Parent = f,
        })
        if sub then
            mk("TextLabel", {
                Size = UDim2.new(1, -60, 0, 14), Position = UDim2.fromOffset(0, 24),
                BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.faint,
                Text = sub, Parent = f,
            })
        end
        local pill = mk("TextButton", {
            Size = UDim2.fromOffset(44, 25), Position = UDim2.new(1, -44, 0, (h - 25) / 2),
            BackgroundColor3 = C.line, Text = "", AutoButtonColor = false, Parent = f,
        })
        corner(pill, 13)
        local knob = mk("Frame", {
            Size = UDim2.fromOffset(21, 21), Position = UDim2.fromOffset(2, 2),
            BackgroundColor3 = C.text, BorderSizePixel = 0, Parent = pill,
        })
        corner(knob, 11)
        local function redraw()
            local on = get() and true or false
            pill.BackgroundColor3 = on and C.green or C.line
            knob.Position = UDim2.fromOffset(on and 21 or 2, 2)
        end
        pill.Activated:Connect(function() set(not get()) redraw() end)
        table.insert(live, redraw)
        redraw()
        return f
    end

    local function slider(parent, titleText, minV, maxV, stepV, get, set, unit)
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 50), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = parent,
        })
        mk("TextLabel", {
            Size = UDim2.new(1, -80, 0, 16), Position = UDim2.fromOffset(0, 6),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.text,
            Text = titleText, Parent = f,
        })
        local val = mk("TextLabel", {
            Size = UDim2.fromOffset(80, 16), Position = UDim2.new(1, -80, 0, 6),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.accent,
            Text = "", Parent = f,
        })
        local track = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 6), Position = UDim2.fromOffset(0, 32),
            BackgroundColor3 = C.card2, BorderSizePixel = 0, Parent = f,
        })
        corner(track, 3)
        local fill = mk("Frame", {
            Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.accent,
            BorderSizePixel = 0, Parent = track,
        })
        corner(fill, 3)
        local knob = mk("Frame", {
            Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = C.text,
            BorderSizePixel = 0, ZIndex = 2, Parent = track,
        })
        corner(knob, 8)

        local function redraw()
            local v = tonumber(get()) or minV
            local a = math.clamp((v - minV) / math.max(maxV - minV, 0.001), 0, 1)
            fill.Size = UDim2.fromScale(a, 1)
            knob.Position = UDim2.new(a, 0, 0.5, 0)
            val.Text = ((stepV < 1) and string.format("%.2f", v) or tostring(math.floor(v)))
                .. (unit or "")
        end
        local function apply(x)
            local a = math.clamp((x - track.AbsolutePosition.X)
                / math.max(track.AbsoluteSize.X, 1), 0, 1)
            local v = minV + a * (maxV - minV)
            v = math.floor(v / stepV + 0.5) * stepV
            v = math.clamp(v, minV, maxV)
            if stepV < 1 then v = tonumber(string.format("%.2f", v)) end
            set(v)
            redraw()
        end
        track.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                dragTarget = apply
                apply(i.Position.X)
            end
        end)
        table.insert(live, redraw)
        redraw()
        return f
    end

    local function button(parent, text, kind, cb, refresh)
        local fills = { primary = C.accent, good = C.green, bad = C.red, plain = C.card2 }
        local b = mk("TextButton", {
            Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = fills[kind] or C.card2,
            Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = C.text,
            Text = text, AutoButtonColor = false, LayoutOrder = nextOrder(), Parent = parent,
        })
        corner(b, 10)
        b.Activated:Connect(function() pcall(cb, b) end)
        if refresh then table.insert(live, function() pcall(refresh, b) end) end
        return b
    end

    -- two buttons on one line
    local function buttonPair(parent, aText, aKind, aCb, bText, bKind, bCb)
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = parent,
        })
        local fills = { primary = C.accent, good = C.green, bad = C.red, plain = C.card2 }
        local function half(text, kind, cb, x)
            local b = mk("TextButton", {
                Size = UDim2.new(0.5, -4, 1, 0), Position = UDim2.new(x, x == 0 and 0 or 4, 0, 0),
                BackgroundColor3 = fills[kind] or C.card2, Font = Enum.Font.GothamMedium,
                TextSize = 13, TextColor3 = C.text, Text = text,
                AutoButtonColor = false, Parent = f,
            })
            corner(b, 10)
            b.Activated:Connect(function() pcall(cb, b) end)
            return b
        end
        return half(aText, aKind, aCb, 0), half(bText, bKind, bCb, 0.5)
    end

    local function textbox(parent, placeholder, actionText, cb)
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = parent,
        })
        local tb = mk("TextBox", {
            Size = UDim2.new(1, -92, 1, 0), BackgroundColor3 = C.card2,
            BorderSizePixel = 0, ClearTextOnFocus = false, Font = Enum.Font.Gotham,
            TextSize = 12, TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left,
            PlaceholderText = placeholder, PlaceholderColor3 = C.faint, Text = "",
            Parent = f,
        })
        corner(tb, 10)
        mk("UIPadding", { PaddingLeft = UDim.new(0, 10), Parent = tb })
        local b = mk("TextButton", {
            Size = UDim2.fromOffset(86, 36), Position = UDim2.new(1, -86, 0, 0),
            BackgroundColor3 = C.card2, Font = Enum.Font.GothamMedium, TextSize = 12,
            TextColor3 = C.text, Text = actionText, AutoButtonColor = false, Parent = f,
        })
        corner(b, 10)
        local function fire()
            local v = (tb.Text:gsub("^%s+", ""):gsub("%s+$", ""))
            pcall(cb, v, tb)
        end
        b.Activated:Connect(fire)
        tb.FocusLost:Connect(function(enter) if enter then fire() end end)
        return tb
    end

    local function segmented(parent, items, get, set)
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = C.card2,
            BorderSizePixel = 0, LayoutOrder = nextOrder(), Parent = parent,
        })
        corner(f, 9)
        for i, it in ipairs(items) do
            local b = mk("TextButton", {
                Size = UDim2.new(1 / #items, -4, 1, -6),
                Position = UDim2.new((i - 1) / #items, 2, 0, 3),
                BackgroundColor3 = C.card2, Font = Enum.Font.GothamMedium, TextSize = 12,
                TextColor3 = C.dim, Text = it[1], AutoButtonColor = false, Parent = f,
            })
            corner(b, 7)
            b.Activated:Connect(function() set(it[2]) end)
            table.insert(live, function()
                local on = (get() == it[2])
                b.BackgroundColor3 = on and C.accent or C.card2
                b.TextColor3 = on and C.text or C.dim
            end)
        end
        return f
    end

    -- A scrolling list of tappable rows, rebuilt only when its contents change.
    local function listView(parent, height)
        local box = mk("Frame", {
            Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = C.card,
            BorderSizePixel = 0, LayoutOrder = nextOrder(), Parent = parent,
        })
        corner(box, 14)
        local sf = mk("ScrollingFrame", {
            Size = UDim2.new(1, -12, 1, -12), Position = UDim2.fromOffset(6, 6),
            BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
            ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(), Parent = box,
        })
        local l = mk("UIListLayout", { Padding = UDim.new(0, 2), Parent = sf })
        l:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            sf.CanvasSize = UDim2.new(0, 0, 0, l.AbsoluteContentSize.Y + 4)
        end)
        return sf
    end

    local function listRow(sf, text, tagText, tagColour, cb, i)
        local b = mk("TextButton", {
            Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.card2,
            BackgroundTransparency = 0.45, Font = Enum.Font.Gotham, TextSize = 12,
            TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left,
            Text = "  " .. text, AutoButtonColor = false, LayoutOrder = i, Parent = sf,
        })
        corner(b, 8)
        if tagText and tagText ~= "" then
            mk("TextLabel", {
                Size = UDim2.fromOffset(84, 30), Position = UDim2.new(1, -92, 0, 0),
                BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 10,
                TextXAlignment = Enum.TextXAlignment.Right,
                TextColor3 = tagColour or C.dim, Text = tagText, Parent = b,
            })
        end
        b.Activated:Connect(function() pcall(cb) end)
        return b
    end

    -- =====================================================
    -- FARM
    -- =====================================================
    -- selection[name] = "farm" | "backup" | nil
    local selection = {}
    local function selectionLists()
        local prim, back = {}, {}
        for n, kind in pairs(selection) do
            if kind == "farm" then table.insert(prim, n)
            elseif kind == "backup" then table.insert(back, n) end
        end
        table.sort(prim) table.sort(back)
        return prim, back
    end

    local function startFarm()
        local prim, back = selectionLists()
        P.setSecondary(back)
        task.spawn(function()
            if #prim > 0 then P.start(prim, {}) else P.start(nil, {}) end
        end)
    end

    do
        local page = pages.Farm

        local card = group(page, "targets")
        local list = listView(card, 154)
        note(card, "Tap once to farm it. Tap again to keep it as a backup for when "
            .. "the first lot are respawning. Tap a third time to drop it.")

        local signature = ""
        local function refreshList()
            local seen, out = {}, {}
            local folder = workspace:FindFirstChild("Enemies")
            if folder then
                for _, m in ipairs(folder:GetChildren()) do
                    if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then
                        local n = cleanName(m)
                        if not seen[n] then
                            seen[n] = true
                            table.insert(out, n)
                        end
                    end
                end
            end
            -- anything selected but not currently streamed in stays on the list
            for n in pairs(selection) do
                if not seen[n] then seen[n] = true table.insert(out, n) end
            end
            table.sort(out)

            local sig = table.concat(out, "|")
            for n, k in pairs(selection) do sig = sig .. "#" .. n .. k end
            if sig == signature then return end
            signature = sig

            for _, c in ipairs(list:GetChildren()) do
                if c:IsA("GuiObject") then c:Destroy() end
            end
            if #out == 0 then
                listRow(list, "nothing loaded here yet", "", C.faint, function() end, 1)
                return
            end
            for i, n in ipairs(out) do
                local kind = selection[n]
                local tag = (kind == "farm" and "FARM")
                    or (kind == "backup" and "BACKUP") or ""
                local col = (kind == "farm" and C.accent)
                    or (kind == "backup" and C.dim) or C.faint
                listRow(list, n, tag, col, function()
                    if selection[n] == nil then selection[n] = "farm"
                    elseif selection[n] == "farm" then selection[n] = "backup"
                    else selection[n] = nil end
                    refreshList()
                end, i)
            end
        end
        refreshList()
        table.insert(live, refreshList)

        buttonPair(page,
            "Farm by level", "plain", function()
                table.clear(selection)
                P.setSecondary(nil)
                task.spawn(function() P.start(nil, {}) end)
            end,
            "Farm anything", "plain", function()
                table.clear(selection)
                P.setSecondary(nil)
                task.spawn(function() P.start(nil, { anyEnemy = true }) end)
            end)

        textbox(page, "or type names: Swan Pirate, Raider", "Use", function(v)
            if #v == 0 then return end
            table.clear(selection)
            for word in string.gmatch(v, "[^,]+") do
                word = (word:gsub("^%s+", ""):gsub("%s+$", ""))
                if #word > 0 then selection[word] = "farm" end
            end
            startFarm()
        end)

        local rot = group(page, "rotation")
        switch(rot, "One type at a time",
            "Each species has its own patch of ground and its own leash",
            function() return CFG.RotateTypes end,
            function(v) CFG.RotateTypes = v end)
        switch(rot, "Stand in the middle of them", nil,
            function() return CFG.TypeCentre end,
            function(v) CFG.TypeCentre = v end)
        slider(rot, "Minutes per type", 0.5, 10, 0.5,
            function() return CFG.TypeDwell / 60 end,
            function(v) CFG.TypeDwell = math.floor(v * 60) end, " min")
        button(rot, "Switch type now", "plain", function() pcall(P.nextType) end)

        local mag = group(page, "magnet")
        switch(mag, "Pull enemies to me",
            "Drags them into weapon range instead of you chasing them",
            function() return CFG.Magnet end,
            function(v)
                CFG.Magnet = v
                syncPuller()
                if v then startStabilizer() end
            end)
        slider(mag, "Distance in front", 0, 100, 1,
            function() return CFG.MagnetDistance end,
            function(v) CFG.MagnetDistance = v end, " studs")
        slider(mag, "Height  (+ up  /  - down)", -80, 80, 1,
            function() return CFG.MagnetHeight end,
            function(v) CFG.MagnetHeight = v end, " studs")
        switch(mag, "Keep them on the ground",
            "Ignores height - they stand where they normally stand",
            function() return CFG.MagnetGround end,
            function(v) CFG.MagnetGround = v end)
        slider(mag, "How spread out", 1, 40, 1,
            function() return CFG.MagnetSpread end,
            function(v) CFG.MagnetSpread = v end, " studs")
        switch(mag, "Aim down at the pile",
            "A standing swing is flat and passes over them",
            function() return CFG.FaceStack end,
            function(v) CFG.FaceStack = v end)
        switch(mag, "Pull every enemy", "Off = only what you selected",
            function() return CFG.MagnetAllTypes end,
            function(v) CFG.MagnetAllTypes = v end)
        infoLine(mag, function()
            return string.format(
                "holding %d  ·  nearest one is %d studs from you  ·  %d left alone",
                stats.pulled or 0, stats.nearestHeld or 0, stats.outOfLeash or 0)
        end)
        note(mag, "If anything is still landing on you, raise Distance in front "
            .. "until the nearest-one number is past their reach. Their melee is "
            .. "shorter than yours.")
        button(mag, "Move me to the biggest group", "plain", function()
            task.spawn(function()
                local c, n = P.packCentre()
                if c then
                    clearHold()
                    moveTo(c + Vector3.new(0, CFG.HoverHeight, 0), MOVE_SPEED)
                    setAnchor(c, nil)
                    say(string.format("moved to the group (%d reachable)", n))
                else
                    say("no enemies to gather")
                end
            end)
        end)
    end

    -- =====================================================
    -- QUEST
    -- =====================================================
    do
        local page = pages.Quest

        local card = group(page, "quest loop")
        switch(card, "Run quests automatically",
            "Take it, kill the count, take the next one",
            function() return CFG.AutoQuest end,
            function(v)
                CFG.AutoQuest = v
                if v then
                    pcall(P.armQuest)
                    say("quest loop on")
                end
            end)
        infoLine(card, function()
            local q = P.readQuest and P.readQuest() or nil
            if q then
                return string.format("On a quest  ·  %d of %d  ·  %s",
                    q.have, q.need, q.enemy or "target")
            end
            return "No quest running right now"
        end)
        infoLine(card, function() return tostring(P.lastQuestResult or "") end)
        button(card, "Take a quest now", "primary", function()
            task.spawn(function() pcall(P.acceptQuest) end)
        end)

        local giver = group(page, "quest giver")
        infoLine(giver, function()
            local e = P.currentEnemy()
            local name, spot = P.giverFor(e)
            return string.format("For %s: %s%s", tostring(e or "-"),
                name and ("\"" .. name .. "\"") or "nearest ? marker",
                spot and "  ·  exact spot saved" or "")
        end)
        switch(giver, "Use the closest ? giver",
            "When no name is set, take the nearest NPC with the quest marker",
            function() return CFG.QuestGiverClosest end,
            function(v) CFG.QuestGiverClosest = v end)
        note(giver, "Every quest giver name from the wiki is built in, so the "
            .. "right NPC is recognised on any island - Adventurer in the Jungle, "
            .. "Villager in the Frozen Village, and the rest. Whichever one an "
            .. "accept actually works at is then remembered for that enemy and "
            .. "overrides the built-in list.")
        buttonPair(giver,
            "Save this spot", "plain", function() pcall(P.setGiverHere) end,
            "Forget spot", "plain", function() pcall(P.clearGiver) end)
        switch(giver, "Walk to the giver first", "Some islands refuse it from range",
            function() return CFG.QuestHopToGiver end,
            function(v) CFG.QuestHopToGiver = v end)
        switch(giver, "Return to the farm after", nil,
            function() return CFG.QuestReturnToFarm end,
            function(v) CFG.QuestReturnToFarm = v end)
        textbox(giver, "giver name, e.g. Adventurer", "Set", function(v)
            CFG.QuestGiverName = (#v > 0) and v or nil
            say("giver name: " .. tostring(CFG.QuestGiverName or "any"))
        end)

        local adv = group(page, "which quest")
        infoLine(adv, function()
            local lk = P.lockedQuest
            if lk and CFG.QuestLock ~= false then
                return string.format("LOCKED on %s tier %d  ·  for %s",
                    tostring(lk.name), lk.tier or 1, tostring(lk.enemy or "-"))
            end
            local qn, tier, enemy = P.questForNames()
            if CFG.QuestName then qn = CFG.QuestName end
            if CFG.QuestTier then tier = CFG.QuestTier end
            return string.format("%s  tier %s  ·  for %s",
                tostring(qn or "unknown"), tostring(tier or 1), tostring(enemy or "-"))
        end)
        switch(adv, "Keep repeating this quest",
            "Chosen once, then the loop stays on it",
            function() return CFG.QuestLock end,
            function(v) CFG.QuestLock = v end)
        button(adv, "Forget the locked quest", "plain", function()
            P.lockedQuest = nil
            say("quest unlocked - the next accept picks from your targets")
        end)
        segmented(adv, { { "Tier 1", 1 }, { "Tier 2", 2 }, { "Tier 3", 3 }, { "Auto", false } },
            function() return CFG.QuestTier or false end,
            function(v) CFG.QuestTier = v or nil end)
        textbox(adv, "override quest name, e.g. JungleQuest", "Set", function(v)
            CFG.QuestName = (#v > 0) and v or nil
            say("quest name: " .. tostring(CFG.QuestName or "auto"))
        end)
        note(adv, "A quest is never re-taken while its count is running: asking "
            .. "again would reset it to zero.")

        local dbg = group(page, "if it cannot find the giver")
        local scanTxt = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.dim,
            Text = "Scan lists the NPCs around you and what marked them.",
            LayoutOrder = nextOrder(), Parent = dbg,
        })
        buttonPair(dbg,
            "Scan for NPCs", "plain", function()
                scanTxt.Text = table.concat(P.questScan(400), "\n")
            end,
            "Probe nearest", "plain", function()
                scanTxt.Text = table.concat(P.questProbe(), "\n")
            end)
    end

    -- =====================================================
    -- TRAVEL
    -- =====================================================
    do
        local page = pages.Travel
        local chosen = nil
        local filter = ""

        local card = group(page, "teleport")
        infoLine(card, function()
            if not chosen then return "Pick somewhere below." end
            local _, root = parts()
            local d = P.findDestination(chosen)
            if root and d and d.pos then
                return string.format("%s  ·  %.0f studs away", chosen,
                    (d.pos - root.Position).Magnitude)
            end
            return chosen
        end)
        button(card, "Teleport", "primary", function()
            if not chosen then say("pick a destination first") return end
            task.spawn(function() pcall(P.travelTo, chosen) end)
        end, function(b)
            b.Text = P.travelling() and "Teleporting..."
                or (chosen and ("Teleport to " .. chosen) or "Teleport")
            b.BackgroundColor3 = P.travelling() and C.card2 or C.accent
        end)
        segmented(card, { { "Auto", "auto" }, { "Fly", "fly" }, { "Respawn", "respawn" } },
            function() return CFG.TeleportMode end,
            function(v) CFG.TeleportMode = v end)
        segmented(card, { { "Instant", "instant" }, { "Stepped", "stepped" } },
            function() return CFG.TeleportStyle end,
            function(v) CFG.TeleportStyle = v end)
        note(card, "Instant is one CFrame write - the same thing the game's own "
            .. "house button does. If a server snaps you back, it crosses in "
            .. "small steps instead, on its own. Respawn is the old spawn point "
            .. "trick, kept only because it still works on some servers.")
        slider(card, "Countdown", 0, 8, 0.5,
            function() return CFG.TeleportCountdown end,
            function(v) CFG.TeleportCountdown = v end, "s")
        infoLine(card, function() return tostring(P.lastTravel or "") end)

        local listCard = group(page, "where to")
        local sbox = textbox(listCard, "search islands and farm spots", "Clear",
            function(_, tb) tb.Text = "" filter = "" end)
        sbox:GetPropertyChangedSignal("Text"):Connect(function()
            filter = string.lower(sbox.Text)
        end)
        local list = listView(listCard, 190)

        local sig = ""
        local function refreshDest()
            local all = P.destinations()
            local out = {}
            for _, d in ipairs(all) do
                if filter == "" or string.find(string.lower(d.name), filter, 1, true) then
                    table.insert(out, d)
                end
            end
            local s = tostring(#all) .. "@" .. tostring(chosen) .. "@" .. filter
            for _, d in ipairs(out) do s = s .. d.name end
            if s == sig then return end
            sig = s
            for _, c in ipairs(list:GetChildren()) do
                if c:IsA("GuiObject") then c:Destroy() end
            end
            if #out == 0 then
                listRow(list, (#all == 0) and "world still loading" or "nothing matches",
                    "", C.faint, function() end, 1)
                return
            end
            for i, d in ipairs(out) do
                local tag = (chosen == d.name) and "SELECTED"
                    or (d.kind == "island" and "island" or (d.label or "farm"))
                local col = (chosen == d.name) and C.accent or C.faint
                listRow(list, d.name, tag, col, function()
                    chosen = d.name
                    refreshDest()
                end, i)
            end
        end
        refreshDest()
        table.insert(live, refreshDest)

        local fl = group(page, "flight")
        slider(fl, "Hold on arrival", 0.5, 6, 0.5,
            function() return CFG.TeleportSettle end,
            function(v) CFG.TeleportSettle = v end, "s")
        note(fl, "Arriving before the island has loaded drops you through ground "
            .. "that does not exist yet. This holds you in place until it does.")
        slider(fl, "Cruise height", 80, 900, 20,
            function() return CFG.TravelAltitude end,
            function(v) CFG.TravelAltitude = v end, " studs")
        slider(fl, "Step size", 60, 500, 20,
            function() return CFG.TravelStep end,
            function(v) CFG.TravelStep = v end, " studs")
        note(fl, "Smaller steps look more like ordinary movement and stream more "
            .. "safely. Bigger steps get there faster. 220 is the sane middle.")
        button(fl, "Force respawn", "plain", function()
            task.spawn(function() pcall(P.forceRespawn) end)
        end)

        local sea = group(page, "change sea")
        note(sea, "The three seas are three separate servers, so this leaves the "
            .. "one you are in and the farm restarts on the other side. The game "
            .. "still checks whether you are allowed in.")
        for _, s in ipairs(P.seas()) do
            button(sea, s.name, "plain", function()
                task.spawn(function() pcall(P.hopSea, s.id) end)
            end, function(b)
                b.TextColor3 = (game.PlaceId == s.id) and C.faint or C.text
                b.Text = (game.PlaceId == s.id) and (s.name .. "  (you are here)") or s.name
            end)
        end
    end

    -- =====================================================
    -- SETUP
    -- =====================================================
    do
        local page = pages.Setup

        local atk = group(page, "attack")
        segmented(atk, { { "Skills", "SKILLS" }, { "M1", "M1" },
                         { "Both", "BOTH" }, { "Hold", "M1HOLD" } },
            function() return CFG.AttackMode end,
            function(v)
                CFG.AttackMode = v
                if v ~= "M1HOLD" then pcall(P.releaseM1) end
            end)
        note(atk, "Skills are the only input measured to land on this executor. "
            .. "M1 is kept because it costs nothing to try on a new one.")

        local keyRow = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = atk,
        })
        local ALLK = {
            { "Z", Enum.KeyCode.Z }, { "X", Enum.KeyCode.X }, { "C", Enum.KeyCode.C },
            { "V", Enum.KeyCode.V }, { "F", Enum.KeyCode.F },
        }
        local function hasKey(kc)
            for _, k in ipairs(CFG.SkillKeys) do if k == kc then return true end end
            return false
        end
        for i, pair in ipairs(ALLK) do
            local b = mk("TextButton", {
                Size = UDim2.new(1 / #ALLK, -6, 1, 0),
                Position = UDim2.new((i - 1) / #ALLK, 3, 0, 0),
                BackgroundColor3 = C.card2, Font = Enum.Font.GothamBold, TextSize = 13,
                TextColor3 = C.text, Text = pair[1], AutoButtonColor = false, Parent = keyRow,
            })
            corner(b, 9)
            b.Activated:Connect(function()
                if hasKey(pair[2]) then
                    for idx, k in ipairs(CFG.SkillKeys) do
                        if k == pair[2] then table.remove(CFG.SkillKeys, idx) break end
                    end
                else
                    table.insert(CFG.SkillKeys, pair[2])
                end
            end)
            table.insert(live, function()
                local on = hasKey(pair[2])
                b.BackgroundColor3 = on and C.accent or C.card2
                b.TextColor3 = on and C.text or C.faint
            end)
        end
        note(atk, "Only the skill keys you have actually unlocked.")
        slider(atk, "Swing gap", 0.01, 0.6, 0.01,
            function() return CFG.AttackGap end,
            function(v) CFG.AttackGap = v end, "s")
        slider(atk, "Skill every N swings", 1, 12, 1,
            function() return CFG.SkillEvery end,
            function(v) CFG.SkillEvery = v end, "")
        slider(atk, "Hitbox reach", 20, 400, 10,
            function() return CFG.HitboxMagnitude end,
            function(v) CFG.HitboxMagnitude = v end, " studs")
        note(atk, "Hitbox reach is written straight into the combat controller, "
            .. "so a hit registers further out than the swing animation shows. "
            .. "The server still has the last word, so keep it sane.")

        local wep = group(page, "weapon")
        local tools, tIdx = {}, 1
        local wlbl = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1,
            Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.dim,
            TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
            Text = "", LayoutOrder = nextOrder(), Parent = wep,
        })
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
            wlbl.Text = "Holding " .. (held and held.Name or "nothing")
                .. "\nPick: " .. tostring(out[tIdx] or "-")
        end
        refreshTools()
        table.insert(live, refreshTools)
        buttonPair(wep,
            "Previous", "plain", function()
                if #tools > 0 then tIdx = ((tIdx - 2) % #tools) + 1 refreshTools() end
            end,
            "Next", "plain", function()
                if #tools > 0 then tIdx = (tIdx % #tools) + 1 refreshTools() end
            end)
        button(wep, "Use this weapon", "plain", function()
            local n = tools[tIdx]
            if n then
                CFG.ForceWeapon = n
                equipWeapon()
                refreshTools()
            end
        end)

        local pos = group(page, "position")
        switch(pos, "Anti-gravity hold", "Stops you sinking between swings",
            function() return CFG.HoldAltitude end,
            function(v)
                CFG.HoldAltitude = v
                if not v then clearHold() end
            end)
        slider(pos, "Hover height", 2, 60, 1,
            function() return CFG.HoverHeight end,
            function(v) CFG.HoverHeight = v end, " studs")
        slider(pos, "Extra tilt", -89, 89, 5,
            function() return CFG.AttackTilt end,
            function(v) CFG.AttackTilt = v end, "°")
        note(pos, "Aim down at the pile already pitches you at it. Extra tilt is "
            .. "on top of that, for weapons whose arc sits high or low.")
        buttonPair(pos,
            "Hold here", "plain", function()
                local _, r = parts()
                if r then
                    startStabilizer()
                    setHold(flatCF(r.CFrame))
                end
            end,
            "Release", "plain", function() clearHold() end)

        local reach = group(page, "reach and limits")
        slider(reach, "Magnet range", 20, 800, 20,
            function() return CFG.MagnetRange end,
            function(v) CFG.MagnetRange = v end, " studs")
        slider(reach, "Leash radius", 20, 600, 10,
            function() return CFG.LeashRadius end,
            function(v) CFG.LeashRadius = v end, " studs")
        note(reach, "An NPC dragged out of its own area still arrives, but takes "
            .. "no damage. Leash radius is the cap that prevents that.")
        slider(reach, "Most enemies held at once", 5, 120, 5,
            function() return CFG.MagnetMax end,
            function(v) CFG.MagnetMax = v end, "")
        slider(reach, "Seconds per target", 5, 120, 5,
            function() return CFG.TargetTimeout end,
            function(v) CFG.TargetTimeout = v end, "s")
        switch(reach, "Use backups while primaries respawn", nil,
            function() return CFG.UseSecondary end,
            function(v) CFG.UseSecondary = v end)
        switch(reach, "Hit anything if nothing selected is loaded", nil,
            function() return CFG.AnyEnemyFallback end,
            function(v) CFG.AnyEnemyFallback = v end)

        local sys = group(page, "system")
        switch(sys, "Print debug to console", nil,
            function() return CFG.Debug end,
            function(v) CFG.Debug = v end)
        button(sys, "Reinstall fast attack", "plain", function()
            installFastAttack()
            equipWeapon()
        end)
        button(sys, "Stop and close the panel", "bad", function()
            P.stop()
            gui:Destroy()
        end)
    end

    -- =====================================================
    -- STATS
    -- =====================================================
    do
        local page = pages.Stats
        local card = group(page, "this run")
        local big = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 54), BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold, TextSize = 34, TextColor3 = C.text,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "0",
            LayoutOrder = nextOrder(), Parent = card,
        })
        local sub = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1,
            Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.dim,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "kills",
            LayoutOrder = nextOrder(), Parent = card,
        })
        table.insert(live, function()
            local mins = math.max((os.clock() - stats.startedAt) / 60, 1 / 60)
            big.Text = tostring(stats.kills)
            sub.Text = string.format("kills  ·  %.1f per minute  ·  %d landed hits",
                stats.kills / mins, stats.damaging)
        end)

        local detail = group(page, "detail")
        local body = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.dim,
            Text = "", LayoutOrder = nextOrder(), Parent = detail,
        })
        table.insert(live, function()
            local char = player.Character
            local held = char and char:FindFirstChildOfClass("Tool")
            local _, _, hum = parts()
            local prim, back = selectionLists()
            body.Text = table.concat({
                "state        " .. state,
                "working      " .. tostring(P.focusName or "-")
                                .. "  (" .. typeIdx .. "/" .. math.max(#typeOrder, 1) .. ")",
                "farming      " .. (#prim > 0 and table.concat(prim, ", ") or "by level"),
                "backup       " .. (#back > 0 and table.concat(back, ", ") or "-"),
                "quest        " .. tostring(P.questProgress or "off")
                                .. (P.questEnemy and ("  " .. P.questEnemy) or ""),
                "",
                "weapon       " .. (held and held.Name or "none"),
                "attack       " .. tostring(CFG.AttackMode),
                "combat hook  " .. (P.fastOK and ("on, reach " .. CFG.HitboxMagnitude)
                                              or "NOT attached"),
                "swings       " .. stats.swings,
                "held         " .. stats.pulled .. "  skipped " .. (stats.outOfLeash or 0),
                "nearest held " .. (stats.nearestHeld or 0) .. " studs",
                "level        " .. tostring(playerLevel() or "?"),
                "health       " .. (hum and math.floor(hum.Health) or "?"),
                "",
                "escalations  " .. stats.escalations,
                "teleports    " .. stats.travels,
                "retreats     " .. stats.retreats,
                string.format("progress     %.0fs ago", os.clock() - lastProgressAt),
            }, "\n")
        end)
    end

    showTab("Farm")

    runBtn.Activated:Connect(function()
        if P.running then P.stop() else startFarm() end
    end)

    -- ---------- refresh ----------
    task.spawn(function()
        while gui and gui.Parent do
            runBtn.Text = P.running and "Stop" or "Start farming"
            runBtn.BackgroundColor3 = P.running and C.red or C.accent
            dot.BackgroundColor3 = P.running and C.green or C.faint
            stateLbl.Text = string.lower(state)
            statusLbl.Text = statusLine
            for _, fn in ipairs(live) do pcall(fn) end
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
    activeNames = nil
    pcall(P.armQuest)
    escalation = 0
    blacklist = {}
    countedDead = {}
    lastProgressAt = os.clock()
    P.running = true
    moveEnabled = true
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
    -- cancel anything in flight, then re-arm so the manual buttons still work
    moveEnabled = false
    task.delay(0.3, function() moveEnabled = true end)
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

-- Backup enemy set. Farmed only while the primaries are on their respawn
-- timer, then dropped the moment a primary is loaded again.
function P.setSecondary(names)
    if type(names) == "string" then names = { names } end
    if not names or #names == 0 then
        secondaryNames = nil
    else
        secondaryNames = {}
        for _, n in ipairs(names) do secondaryNames[n] = true end
    end
    return secondaryNames
end
function P.secondary() return secondaryNames end

function P.stats() return stats end
function P.state() return state, statusLine, escalation end

-- Show the panel immediately on load so no console command is required.
say("loaded - press BY LEVEL or ANY ENEMY to begin")
pcall(buildUI)
print("[BFP] loaded. Use the panel, or _G.BFP.start()")
