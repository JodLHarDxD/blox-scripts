--[[
    BLOX FRUITS LIVE TRACKER
    ========================
    Passive observability layer. Run this FIRST, then run your farm/chest script
    alongside it. It observes and reports; it never changes game behaviour.

    WHAT IT SHOWS
      * Every CommF_ remote call: command, arguments, RETURN VALUE, duration.
        This is what reveals why SetLastSpawnPoint gets rejected.
      * Every death / respawn, with distance moved -> detects the respawn loop.
      * Streaming window: how many chests / enemies are actually loaded client-side.
      * Running counters and a scrolling colour-coded event feed.

    MANUAL PROBE (safe, does not destroy your character):
        _G.BFT.testSpawn("Middle Town")   -- prints the raw server return value
        _G.BFT.spawns()                   -- lists every spawn name it can see
        _G.BFT.dump()                     -- prints + copies the whole log
        _G.BFT.stop()                     -- removes hooks and UI
]]

if _G.BFT and _G.BFT.stop then pcall(_G.BFT.stop) end

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player     = Players.LocalPlayer

local CFG = {
    MaxLogLines   = 600,
    FeedLines     = 18,
    StreamPollSec = 2.0,
}

local BFT = { running = true }
_G.BFT = BFT

-- =========================================================
-- LOG BUFFER
-- =========================================================
local logBuf, logSeq = {}, 0
local feedDirty = true

local COLORS = {
    info   = Color3.fromRGB(198, 212, 228),
    good   = Color3.fromRGB(126, 226, 152),
    warn   = Color3.fromRGB(245, 200, 110),
    bad    = Color3.fromRGB(255, 130, 130),
    remote = Color3.fromRGB(140, 195, 255),
    event  = Color3.fromRGB(206, 160, 255),
}

local function push(kind, text)
    logSeq += 1
    local entry = {
        seq   = logSeq,
        t     = os.clock(),
        kind  = kind,
        text  = tostring(text),
        stamp = os.date("%H:%M:%S"),
    }
    table.insert(logBuf, entry)
    if #logBuf > CFG.MaxLogLines then table.remove(logBuf, 1) end
    feedDirty = true
    print(string.format("[BFT %s] %s", entry.stamp, entry.text))
    return entry
end

-- Render any Lua value compactly for one log line.
local function repr(v, depth)
    depth = depth or 0
    local t = typeof(v)
    if t == "string" then
        if #v > 48 then v = v:sub(1, 45) .. "..." end
        return '"' .. v .. '"'
    elseif t == "Instance" then
        return v.ClassName .. "(" .. v.Name .. ")"
    elseif t == "Vector3" then
        return string.format("V3(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z)
    elseif t == "table" then
        if depth >= 2 then return "{...}" end
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n += 1
            if n > 6 then
                table.insert(parts, "...")
                break
            end
            table.insert(parts, tostring(k) .. "=" .. repr(val, depth + 1))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(v)
end

local function reprList(list, count)
    local parts = {}
    for i = 1, count do
        table.insert(parts, repr(list[i]))
    end
    return table.concat(parts, ", ")
end

-- =========================================================
-- COUNTERS
-- =========================================================
local counters = {
    remoteCalls = 0,
    deaths      = 0,
    respawns    = 0,
    spawnSet    = 0,
    spawnRejected = 0,
    chestsSeen  = 0,
    enemiesSeen = 0,
}

-- =========================================================
-- REMOTE OBSERVATION
-- =========================================================
local remotes = RS:FindFirstChild("Remotes")
local commF = remotes and remotes:FindFirstChild("CommF_")
push("info", commF and "CommF_ located" or "CommF_ NOT FOUND - remote logging disabled")

-- Records what the script last asked for, so respawn reporting can score arrival.
local lastSpawnRequest = nil

local function noteRemote(args, argc, results, resn, elapsed)
    local cmd = tostring(args[1])
    counters.remoteCalls += 1

    local retText = resn > 0 and reprList(results, resn) or "<nil>"
    local argText = ""
    if argc > 1 then
        local tail = {}
        for i = 2, argc do
            table.insert(tail, args[i])
        end
        argText = reprList(tail, argc - 1)
    end

    if cmd == "SetLastSpawnPoint" or cmd == "SetSpawnPoint" then
        counters.spawnSet += 1
        lastSpawnRequest = { name = args[2], at = os.clock(), ret = results[1] }
        -- A falsey or empty return is the rejection signal we are hunting.
        if resn == 0 or results[1] == false or results[1] == nil then
            counters.spawnRejected += 1
            push("bad", string.format(
                "SPAWN REJECTED? %s(%s) -> %s   [%.0fms]  <-- server returned nothing/false",
                cmd, argText, retText, elapsed * 1000))
            return
        end
        push("good", string.format("%s(%s) -> %s   [%.0fms]", cmd, argText, retText, elapsed * 1000))
        return
    end

    push("remote", string.format("%s(%s) -> %s   [%.0fms]", cmd, argText, retText, elapsed * 1000))
end

-- Feature-detect a metatable hook. Optional: the manual probe works without it.
local hookInstalled, restoreHook = false, nil
do
    local env = (getgenv and getgenv()) or {}
    local okHook, hookErr = pcall(function()
        if not commF then error("no CommF_") end
        local grm = getrawmetatable or env.getrawmetatable
        local sro = setreadonly or env.setreadonly
        local getMethod = getnamecallmethod or env.getnamecallmethod
        if not grm or not sro then error("no metatable access") end
        if not getMethod then error("no getnamecallmethod") end

        local mt = grm(game)
        local oldNamecall = mt.__namecall

        local hook = function(self, ...)
            if BFT.running and self == commF then
                local method = ""
                pcall(function() method = getMethod() end)
                if method == "InvokeServer" then
                    local args = table.pack(...)
                    local started = os.clock()
                    local res = table.pack(oldNamecall(self, ...))
                    local elapsed = os.clock() - started
                    pcall(noteRemote, args, args.n, res, res.n, elapsed)
                    return table.unpack(res, 1, res.n)
                end
            end
            return oldNamecall(self, ...)
        end

        -- newcclosure keeps yielding intact on most executors; fall back if absent.
        local ncc = newcclosure or env.newcclosure
        local final = hook
        if ncc then
            local okc, wrapped = pcall(ncc, hook)
            if okc and wrapped then final = wrapped end
        end

        sro(mt, false)
        mt.__namecall = final
        pcall(sro, mt, true)

        restoreHook = function()
            pcall(function()
                sro(mt, false)
                mt.__namecall = oldNamecall
                pcall(sro, mt, true)
            end)
        end
        hookInstalled = true
    end)

    if hookInstalled then
        push("good", "Remote hook INSTALLED - every CommF_ call logged with its return value")
    else
        push("warn", "Remote hook unavailable (" .. tostring(hookErr) .. ") - observation mode only. _G.BFT.testSpawn() still works.")
    end
end

-- =========================================================
-- MANUAL SAFE PROBE
-- =========================================================
local worldOrigin = workspace:FindFirstChild("_WorldOrigin")
local spawnFolder = worldOrigin and worldOrigin:FindFirstChild("PlayerSpawns")

function BFT.spawns()
    if not spawnFolder then
        push("bad", "PlayerSpawns not found")
        return
    end
    for _, sub in ipairs(spawnFolder:GetChildren()) do
        local names = {}
        for _, s in ipairs(sub:GetChildren()) do
            table.insert(names, s.Name)
        end
        table.sort(names)
        push("info", string.format("SPAWNS[%s] (%d): %s", sub.Name, #names, table.concat(names, ", ")))
    end
end

-- Calls SetLastSpawnPoint and prints the raw return. Does NOT destroy anything,
-- so a rejected spawn costs nothing. This is the fix-#1 diagnostic.
function BFT.testSpawn(name)
    if not commF then
        push("bad", "no CommF_")
        return
    end
    if type(name) ~= "string" then
        push("bad", 'usage: _G.BFT.testSpawn("Middle Town")')
        return
    end
    local started = os.clock()
    local res = table.pack(pcall(function()
        return commF:InvokeServer("SetLastSpawnPoint", name)
    end))
    local elapsed = os.clock() - started

    if not res[1] then
        push("bad", string.format("testSpawn(%q) THREW: %s", name, tostring(res[2])))
        return
    end

    local retn = res.n - 1
    local retText = "<nil>"
    if retn > 0 then
        local tail = {}
        for i = 2, res.n do
            table.insert(tail, res[i])
        end
        retText = reprList(tail, retn)
    end

    push((retn > 0 and res[2]) and "good" or "warn", string.format(
        "testSpawn(%q) -> %s   [%.0fms]  (character untouched)", name, retText, elapsed * 1000))
    return res[2]
end

-- =========================================================
-- CHARACTER / RESPAWN MONITOR
-- =========================================================
local conns = {}
local lastDeathPos, lastCharAt = nil, os.clock()

local function watchCharacter(char)
    counters.respawns += 1
    local root = char:WaitForChild("HumanoidRootPart", 10)
    local hum  = char:FindFirstChildOfClass("Humanoid")
    local gap  = os.clock() - lastCharAt
    lastCharAt = os.clock()

    if hum then
        table.insert(conns, hum.Died:Connect(function()
            counters.deaths += 1
            if root and root.Parent then
                lastDeathPos = root.Position
            end
            push("warn", string.format("DIED #%d at %s", counters.deaths, repr(lastDeathPos)))
        end))
    end

    task.wait(1.2) -- let the server settle the spawn position
    if not root or not root.Parent then return end
    local pos = root.Position

    local moved = lastDeathPos and (pos - lastDeathPos).Magnitude or 0
    local verdict = ""
    if lastSpawnRequest and os.clock() - lastSpawnRequest.at < 20 then
        verdict = string.format(" | requested %q", tostring(lastSpawnRequest.name))
        if lastDeathPos and moved < 500 then
            verdict = verdict .. "  <-- DID NOT MOVE: respawn loop"
        end
    end

    local kind = (lastDeathPos and moved < 500) and "bad" or "event"
    push(kind, string.format(
        "RESPAWN #%d  moved %.0f studs  (gap %.1fs)  pos %s%s",
        counters.respawns, moved, gap, repr(pos), verdict))
end

table.insert(conns, player.CharacterAdded:Connect(function(c)
    task.spawn(function() pcall(watchCharacter, c) end)
end))
if player.Character then
    task.spawn(function() pcall(watchCharacter, player.Character) end)
end

-- =========================================================
-- STREAMING WINDOW MONITOR
-- =========================================================
local function countLoaded()
    local chests, enemies = 0, 0
    local enemyFolder = workspace:FindFirstChild("Enemies")
    if enemyFolder then
        for _, m in ipairs(enemyFolder:GetChildren()) do
            if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then
                enemies += 1
            end
        end
    end
    for _, o in ipairs(workspace:GetDescendants()) do
        if string.find(string.lower(o.Name), "chest", 1, true) then
            chests += 1
        end
    end
    return chests, enemies
end

task.spawn(function()
    local lastC, lastE = -1, -1
    while BFT.running do
        local ok, c, e = pcall(countLoaded)
        if ok then
            counters.chestsSeen, counters.enemiesSeen = c, e
            if c ~= lastC or e ~= lastE then
                push("info", string.format("STREAM  chests loaded: %d   enemies loaded: %d", c, e))
                lastC, lastE = c, e
            end
        end
        task.wait(CFG.StreamPollSec)
    end
end)

-- =========================================================
-- UI
-- =========================================================
local gui, feedLabels = nil, {}

local function buildUI()
    local pg = player:WaitForChild("PlayerGui", 10)
    if not pg then return end
    local old = pg:FindFirstChild("BFTracker")
    if old then old:Destroy() end

    gui = Instance.new("ScreenGui")
    gui.Name = "BFTracker"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 50
    gui.Parent = pg

    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(560, 330)
    panel.Position = UDim2.new(0, 12, 1, -342)
    panel.BackgroundColor3 = Color3.fromRGB(14, 17, 23)
    panel.BackgroundTransparency = 0.08
    panel.BorderSizePixel = 0
    panel.Active = true
    panel.Draggable = true
    panel.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -90, 0, 26)
    title.Position = UDim2.fromOffset(10, 4)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(235, 242, 250)
    title.Text = "BF TRACKER" .. (hookInstalled and "  -  remote hook ON" or "  -  observe only")
    title.Parent = panel

    local stat = Instance.new("TextLabel")
    stat.Size = UDim2.new(1, -20, 0, 16)
    stat.Position = UDim2.fromOffset(10, 28)
    stat.BackgroundTransparency = 1
    stat.Font = Enum.Font.Code
    stat.TextSize = 11
    stat.TextXAlignment = Enum.TextXAlignment.Left
    stat.TextColor3 = Color3.fromRGB(150, 168, 188)
    stat.Text = ""
    stat.Parent = panel

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(74, 20)
    btn.Position = UDim2.new(1, -82, 0, 6)
    btn.BackgroundColor3 = Color3.fromRGB(40, 48, 60)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.TextColor3 = Color3.fromRGB(220, 230, 240)
    btn.Text = "DUMP LOG"
    btn.Parent = panel

    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(0, 5)
    bc.Parent = btn
    btn.Activated:Connect(function() BFT.dump() end)

    local feed = Instance.new("Frame")
    feed.Size = UDim2.new(1, -20, 1, -56)
    feed.Position = UDim2.fromOffset(10, 50)
    feed.BackgroundTransparency = 1
    feed.Parent = panel

    local list = Instance.new("UIListLayout")
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 1)
    list.Parent = feed

    for i = 1, CFG.FeedLines do
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, 14)
        l.LayoutOrder = i
        l.BackgroundTransparency = 1
        l.Font = Enum.Font.Code
        l.TextSize = 11
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextTruncate = Enum.TextTruncate.AtEnd
        l.TextColor3 = COLORS.info
        l.Text = ""
        l.Parent = feed
        feedLabels[i] = l
    end

    task.spawn(function()
        while BFT.running do
            if feedDirty then
                feedDirty = false
                local start = math.max(1, #logBuf - CFG.FeedLines + 1)
                for i = 1, CFG.FeedLines do
                    local e = logBuf[start + i - 1]
                    local l = feedLabels[i]
                    if e then
                        l.Text = e.stamp .. "  " .. e.text
                        l.TextColor3 = COLORS[e.kind] or COLORS.info
                    else
                        l.Text = ""
                    end
                end
            end
            stat.Text = string.format(
                "remote %d (rejected %d) | deaths %d | respawns %d | chests %d | enemies %d",
                counters.remoteCalls, counters.spawnRejected,
                counters.deaths, counters.respawns,
                counters.chestsSeen, counters.enemiesSeen)
            task.wait(0.25)
        end
    end)
end
pcall(buildUI)

-- =========================================================
-- EXPORT / STOP
-- =========================================================
function BFT.dump()
    local lines = {
        "===== BF TRACKER LOG =====",
        string.format("hook=%s  remoteCalls=%d  spawnRejected=%d  deaths=%d  respawns=%d",
            tostring(hookInstalled), counters.remoteCalls, counters.spawnRejected,
            counters.deaths, counters.respawns),
        "",
    }
    for _, e in ipairs(logBuf) do
        table.insert(lines, string.format("%s [%s] %s", e.stamp, e.kind, e.text))
    end
    local text = table.concat(lines, "\n")
    print(text)
    local sc = setclipboard or (getgenv and getgenv().setclipboard)
    if sc then
        pcall(sc, text)
        print("[BFT] log copied to clipboard (" .. #logBuf .. " lines)")
    end
    return text
end

function BFT.stop()
    BFT.running = false
    if restoreHook then pcall(restoreHook) end
    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end
    if gui then
        pcall(function() gui:Destroy() end)
    end
    print("[BFT] tracker stopped, hooks restored")
end

push("good", "Tracker ready. Run your farm/chest script now.")
push("info", 'Probe:  _G.BFT.testSpawn("Middle Town")   |   _G.BFT.spawns()   |   _G.BFT.dump()')
