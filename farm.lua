--[[
    BLOX FRUITS FARM MODULE (standalone)
    ====================================
    Run alongside tracker.lua so kill rate is measurable, not asserted.

    HOW IT WORKS
      1. FAST ATTACK - walks the Lua registry to find the CombatFramework's
         activeController, then every RenderStepped clears the attack cooldown,
         the mid-attack lock, and the current animation track. Removing the
         cooldown is what makes it fast; the animation vanishing is a side
         effect of zeroing currentAttackTrack.
      2. HOVER - writes HumanoidRootPart.CFrame directly (no tween) and
         re-injects upward Velocity every iteration so gravity never lands you.
         Melee NPC AI cannot path upward, so you take no hits.
      3. CLUSTER - hovers over the CENTROID of all live target enemies rather
         than chasing them one at a time. With a wide hitbox one swing covers
         the whole group.
      4. QUEST - accepts the matching quest through CommF_ so kills count.

    CONTROL
        _G.BFFarm.start("Bandit")   -- farm a specific enemy name
        _G.BFFarm.start()           -- farm whatever is nearest
        _G.BFFarm.stop()
        _G.BFFarm.config            -- live-tunable table
]]

if _G.BFFarm and _G.BFFarm.stop then pcall(_G.BFFarm.stop) end

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local player     = Players.LocalPlayer

local CFG = {
    -- Positioning
    HoverHeight       = 12,    -- studs above the cluster centroid
    BossHoverHeight   = 28,
    ReanchorDistance  = 35,    -- re-position only when centroid drifts this far
    ClusterRange      = 300,   -- enemies within this radius join the cluster

    -- Combat
    HitboxMagnitude   = 150,
    ComboIncrement    = 4,
    AttackHold        = 0.06,  -- Button1Down -> Button1Up
    AttackGap         = 0.06,
    KillCheckInterval = 0.15,

    -- Safety
    MinHealthPercent  = 0.35,  -- retreat below this
    RetreatHeight     = 180,
    RegenWait         = 4,

    -- Quest
    AutoQuest         = true,

    Debug             = false,
}

local F = { running = false, config = CFG }
_G.BFFarm = F

local stats = {
    kills = 0, swings = 0, reanchors = 0,
    retreats = 0, questCalls = 0, startedAt = 0,
}

local conns = {}
local function track(c) table.insert(conns, c) return c end

local function log(msg)
    if CFG.Debug then print("[BFFarm] " .. tostring(msg)) end
end

local status = "idle"
local function setStatus(s)
    status = tostring(s)
    log(s)
end

-- =========================================================
-- CHARACTER HELPERS
-- =========================================================
local function parts()
    local char = player.Character
    if not char or not char:IsDescendantOf(workspace) then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if root and hum and hum.Health > 0 then return char, root, hum end
    return nil
end

local function healthPercent()
    local _, _, hum = parts()
    if not hum or hum.MaxHealth <= 0 then return 1 end
    return hum.Health / hum.MaxHealth
end

-- =========================================================
-- 1. FAST ATTACK  (CombatFramework controller patch)
-- =========================================================
local fastAttackOn, fastAttackConn, controllerRef = false, nil, nil

local function installFastAttack()
    local env = (getgenv and getgenv()) or {}
    local getreg_  = getreg  or env.getreg
    local getupv   = (debug and debug.getupvalues) or getupvalues or env.getupvalues
    local getfenv_ = getfenv

    if not getreg_ or not getupv then
        setStatus("fast attack UNAVAILABLE - executor lacks getreg/getupvalues")
        return false
    end

    -- Quieten the camera shake so rapid swings do not whip the view around.
    pcall(function()
        local shaker = RS:FindFirstChild("Util")
        shaker = shaker and shaker:FindFirstChild("CameraShaker")
        if shaker then
            local mod = require(shaker)
            if mod and mod.Stop then mod:Stop() end
        end
    end)

    local combatScript
    pcall(function()
        combatScript = player:FindFirstChild("PlayerScripts")
        combatScript = combatScript and combatScript:FindFirstChild("CombatFramework")
    end)
    if not combatScript then
        setStatus("fast attack UNAVAILABLE - CombatFramework script not found")
        return false
    end

    -- Find the controller table held as an upvalue of a CombatFramework function.
    local found
    pcall(function()
        for _, value in pairs(getreg_()) do
            if typeof(value) == "function" then
                local okEnv, fenv = pcall(getfenv_, value)
                if okEnv and fenv and rawget(fenv, "script") == combatScript then
                    local okUp, upvals = pcall(getupv, value)
                    if okUp and upvals then
                        for _, up in pairs(upvals) do
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
        setStatus("fast attack UNAVAILABLE - activeController not located")
        return false
    end

    controllerRef = found
    local NEG = -(math.huge ^ math.huge ^ math.huge)

    fastAttackConn = track(RunService.RenderStepped:Connect(function()
        if not fastAttackOn then return end
        pcall(function()
            local ac = controllerRef.activeController
            if not ac then return end
            ac.timeToNextAttack   = NEG            -- cooldown always satisfied
            ac.attacking          = false          -- clear mid-attack lock
            ac.blocking           = false
            ac.increment          = CFG.ComboIncrement
            ac.hitboxMagnitude    = CFG.HitboxMagnitude
            ac.focusStart         = 0
            ac.currentAttackTrack = 0              -- <- kills the swing animation
        end)
    end))

    fastAttackOn = true
    setStatus("fast attack INSTALLED")
    return true
end

-- =========================================================
-- 2. MOVEMENT  (direct CFrame + velocity injection)
-- =========================================================
local function hoverAt(position)
    local _, root = parts()
    if not root then return false end
    root.CFrame = CFrame.new(position)
    root.Velocity = Vector3.new(0, 50, 0)
    return true
end

-- Must be re-applied every iteration: physics consumes velocity each frame.
local function float()
    local _, root = parts()
    if root then root.Velocity = Vector3.new(0, 50, 0) end
end

local function faceDown(targetPos)
    local cam = workspace.CurrentCamera
    local _, root = parts()
    if cam and root and targetPos then
        pcall(function()
            cam.CFrame = CFrame.new(root.Position, targetPos)
        end)
    end
end

-- =========================================================
-- 3. TARGETING  (cluster centroid, not nearest-chase)
-- =========================================================
local function enemyName(model)
    -- Blox Fruits names enemies "Bandit [Lv. 5]" - strip the bracketed level.
    return (model.Name:gsub("%s*%b[]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function liveEnemies(filterName)
    local folder = workspace:FindFirstChild("Enemies")
    if not folder then return {} end
    local out = {}
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") then
            local hum  = m:FindFirstChildOfClass("Humanoid")
            local root = m:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 then
                if not filterName or enemyName(m) == filterName then
                    table.insert(out, { model = m, hum = hum, root = root, name = enemyName(m) })
                end
            end
        end
    end
    return out
end

-- Centroid of the densest group: seed on the nearest enemy, then average
-- everything within ClusterRange of it.
local function clusterCentroid(list, fromPos)
    if #list == 0 then return nil, 0, nil end

    local seed, bestD = nil, math.huge
    for _, e in ipairs(list) do
        local d = (e.root.Position - fromPos).Magnitude
        if d < bestD then seed, bestD = e, d end
    end
    if not seed then return nil, 0, nil end

    local sum, n = Vector3.zero, 0
    for _, e in ipairs(list) do
        if (e.root.Position - seed.root.Position).Magnitude <= CFG.ClusterRange then
            sum += e.root.Position
            n += 1
        end
    end
    if n == 0 then return seed.root.Position, 1, seed end
    return sum / n, n, seed
end

-- =========================================================
-- 4. QUEST
-- =========================================================
local remotes = RS:FindFirstChild("Remotes")
local commF = remotes and remotes:FindFirstChild("CommF_")
local lastQuestFor, lastQuestAt = nil, 0

local function tryQuest(targetName)
    if not CFG.AutoQuest or not commF or not targetName then return end
    if lastQuestFor == targetName and os.clock() - lastQuestAt < 60 then return end
    lastQuestFor, lastQuestAt = targetName, os.clock()
    stats.questCalls += 1
    -- Quest name/index are game data; failure is non-fatal, kills still count
    -- toward any quest already active.
    pcall(function()
        commF:InvokeServer("StartQuest", targetName .. "Quest", 1)
    end)
end

-- =========================================================
-- 5. ATTACK
-- =========================================================
local function swing()
    stats.swings += 1
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:Button1Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
    task.wait(CFG.AttackHold)
    pcall(function()
        VirtualUser:Button1Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end

-- =========================================================
-- 6. MAIN LOOP
-- =========================================================
local targetFilter = nil
local anchor = nil

local function retreat()
    stats.retreats += 1
    setStatus("retreating - low health")
    local _, root = parts()
    if root then
        local p = root.Position
        hoverAt(Vector3.new(p.X, p.Y + CFG.RetreatHeight, p.Z))
    end
    local deadline = os.clock() + CFG.RegenWait
    while F.running and os.clock() < deadline do
        float()
        if healthPercent() > 0.9 then break end
        task.wait(0.2)
    end
end

local function loop()
    while F.running do
        local ok, err = pcall(function()
            local _, root = parts()
            if not root then
                setStatus("waiting for character")
                anchor = nil
                task.wait(0.5)
                return
            end

            if healthPercent() < CFG.MinHealthPercent then
                retreat()
                return
            end

            local list = liveEnemies(targetFilter)
            if #list == 0 then
                setStatus(targetFilter and ("no live " .. targetFilter .. " loaded") or "no enemies loaded")
                anchor = nil
                task.wait(0.5)
                return
            end

            local centroid, count, seed = clusterCentroid(list, root.Position)
            if not centroid then task.wait(0.3) return end

            local name = seed and seed.name or "?"
            tryQuest(name)

            local height = (count == 1 and seed and seed.hum.MaxHealth > 5000)
                and CFG.BossHoverHeight or CFG.HoverHeight
            local desired = centroid + Vector3.new(0, height, 0)

            -- Re-anchor only on meaningful drift, so aggro can pull the group in.
            if not anchor or (anchor - desired).Magnitude > CFG.ReanchorDistance then
                anchor = desired
                stats.reanchors += 1
                hoverAt(anchor)
            end

            faceDown(centroid)
            setStatus(string.format("farming %s  x%d  (hover %d)", name, count, height))

            local before = count
            swing()
            float()
            task.wait(CFG.AttackGap)

            -- Count verified kills: enemies that were live and are now not.
            local after = #liveEnemies(targetFilter)
            if after < before then
                stats.kills += (before - after)
            end
        end)

        if not ok then
            setStatus("recovered from error")
            log(err)
            task.wait(0.4)
        end
    end
end

-- =========================================================
-- 7. UI
-- =========================================================
local gui
local function buildUI()
    local pg = player:WaitForChild("PlayerGui", 10)
    if not pg then return end
    local old = pg:FindFirstChild("BFFarmHUD")
    if old then old:Destroy() end

    gui = Instance.new("ScreenGui")
    gui.Name = "BFFarmHUD"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 40
    gui.Parent = pg

    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(300, 92)
    panel.Position = UDim2.new(1, -312, 0, 12)
    panel.BackgroundColor3 = Color3.fromRGB(14, 17, 23)
    panel.BackgroundTransparency = 0.1
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
    title.TextColor3 = Color3.fromRGB(235, 242, 250)
    title.Text = "BF FARM"
    title.Parent = panel

    local body = Instance.new("TextLabel")
    body.Size = UDim2.new(1, -16, 1, -30)
    body.Position = UDim2.fromOffset(10, 26)
    body.BackgroundTransparency = 1
    body.Font = Enum.Font.Code
    body.TextSize = 11
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.TextColor3 = Color3.fromRGB(170, 190, 210)
    body.Text = ""
    body.Parent = panel

    task.spawn(function()
        while gui and gui.Parent do
            local mins = math.max((os.clock() - stats.startedAt) / 60, 1 / 60)
            title.Text = "BF FARM" .. (fastAttackOn and "  -  fast attack ON" or "  -  NO fast attack")
            title.TextColor3 = fastAttackOn and Color3.fromRGB(126, 226, 152) or Color3.fromRGB(245, 200, 110)
            body.Text = string.format(
                "%s\nkills %d  (%.1f/min)   swings %d\nreanchors %d   retreats %d   quests %d",
                status, stats.kills, stats.kills / mins, stats.swings,
                stats.reanchors, stats.retreats, stats.questCalls)
            task.wait(0.3)
        end
    end)
end

-- =========================================================
-- API
-- =========================================================
function F.start(enemyNameFilter)
    if F.running then F.stop() end
    targetFilter = enemyNameFilter
    stats.kills, stats.swings, stats.reanchors = 0, 0, 0
    stats.retreats, stats.questCalls = 0, 0
    stats.startedAt = os.clock()
    anchor = nil
    F.running = true

    installFastAttack()
    pcall(buildUI)

    -- Anti-AFK: Roblox idle-kicks at 20 minutes.
    track(player.Idled:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end))

    task.spawn(loop)
    setStatus("started" .. (enemyNameFilter and (" - target " .. enemyNameFilter) or " - nearest"))
    print("[BFFarm] running. _G.BFFarm.stop() to halt.")
end

function F.stop()
    F.running = false
    fastAttackOn = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if gui then pcall(function() gui:Destroy() end) end
    gui = nil
    setStatus("stopped")
    print(string.format("[BFFarm] stopped. kills=%d swings=%d", stats.kills, stats.swings))
end

function F.stats() return stats end

print("[BFFarm] loaded. Start with:  _G.BFFarm.start()   or   _G.BFFarm.start(\"Bandit\")")
