--[[
    SOLO FARM V2 — LIVE CLIENT PROBE
    ================================
    READ-ONLY. Changes nothing. Invokes no remotes. Destroys nothing.
    Verifies every assumption solo_farm_v2.lua makes about Blox Fruits
    and about your executor, then prints a report.

    Run this in Blox Fruits, character spawned, before touching the farm.
]]

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local player  = Players.LocalPlayer

local out = {}
local function line(s) table.insert(out, s) end
local function hdr(s) line("") line("== " .. s .. " ==") end
local function mark(ok, label, detail)
    line(string.format("%s %s%s", ok and "[PASS]" or "[FAIL]", label,
        detail and ("  -> " .. tostring(detail)) or ""))
end
local function try(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

line("SOLO FARM V2 PROBE")
line("time: " .. os.date("%H:%M:%S"))

-- ---------------------------------------------------------------
hdr("REMOTES")
local remotes = RS:FindFirstChild("Remotes")
mark(remotes ~= nil, "ReplicatedStorage.Remotes")
local commF = remotes and remotes:FindFirstChild("CommF_")
mark(commF ~= nil, "Remotes.CommF_", commF and commF.ClassName)
if remotes then
    local names = {}
    for _, r in ipairs(remotes:GetChildren()) do table.insert(names, r.Name) end
    table.sort(names)
    line("   all remotes: " .. table.concat(names, ", "))
end

-- ---------------------------------------------------------------
hdr("PLAYER DATA")
local data = player:FindFirstChild("Data")
mark(data ~= nil, "player.Data")
local lvl = data and data:FindFirstChild("Level")
mark(lvl ~= nil, "player.Data.Level", lvl and (lvl.ClassName .. " = " .. tostring(lvl.Value)))
line("   team: " .. tostring(player.Team and player.Team.Name or "nil"))

-- ---------------------------------------------------------------
hdr("SPAWNS  (travel path)")
local worldOrigin = workspace:FindFirstChild("_WorldOrigin")
mark(worldOrigin ~= nil, "workspace._WorldOrigin")
local spawnFolder = worldOrigin and worldOrigin:FindFirstChild("PlayerSpawns")
mark(spawnFolder ~= nil, "_WorldOrigin.PlayerSpawns")
if spawnFolder then
    for _, sub in ipairs(spawnFolder:GetChildren()) do
        line(string.format("   %s: %d entries", sub.Name, #sub:GetChildren()))
    end
end

-- ---------------------------------------------------------------
hdr("ENEMIES  (detection path)")
local enemyFolder = workspace:FindFirstChild("Enemies")
mark(enemyFolder ~= nil, "workspace.Enemies")
if enemyFolder then
    local kids = enemyFolder:GetChildren()
    line("   count: " .. #kids)
    local shown, bracketed, hasLevelAttr = 0, 0, 0
    for _, m in ipairs(kids) do
        if m:IsA("Model") then
            if m.Name:match("%[Lv%.%s*%d+%]") then bracketed += 1 end
            if m:GetAttribute("Level") ~= nil then hasLevelAttr += 1 end
            if shown < 6 then
                shown += 1
                local hum = m:FindFirstChildOfClass("Humanoid")
                local root = m:FindFirstChild("HumanoidRootPart")
                line(string.format("   sample: %-34s hum=%s root=%s",
                    m.Name, tostring(hum ~= nil), tostring(root ~= nil)))
            end
        end
    end
    line(string.format("   names matching '[Lv. N]' : %d / %d", bracketed, #kids))
    line(string.format("   models with Level attribute: %d / %d  <-- script reads this", hasLevelAttr, #kids))
end

-- ---------------------------------------------------------------
hdr("COMBAT  (the fatal one)")
local char = player.Character
local backpack = player:FindFirstChildOfClass("Backpack")
local toolC = char and char:FindFirstChildOfClass("Tool")
local toolB = backpack and backpack:FindFirstChildOfClass("Tool")
mark((toolC or toolB) ~= nil, "a Tool is available",
    toolC and (toolC.Name .. " (equipped)") or (toolB and (toolB.Name .. " (backpack)")))
if backpack then
    local names = {}
    for _, t in ipairs(backpack:GetChildren()) do table.insert(names, t.Name) end
    line("   backpack: " .. (#names > 0 and table.concat(names, ", ") or "empty"))
end
mark(try(function() return game:GetService("VirtualUser") end) ~= nil, "VirtualUser service reachable")

local cf = try(function() return RS:FindFirstChild("CombatFramework", true) end)
mark(cf ~= nil, "CombatFramework module found", cf and cf:GetFullName())

-- ---------------------------------------------------------------
hdr("CHESTS")
local chestCount, chestClick, chestTouch = 0, 0, 0
for _, o in ipairs(workspace:GetChildren()) do
    if o.Name:lower():find("chest", 1, true) then
        chestCount += 1
        if chestCount <= 3 then
            local part = o:IsA("BasePart") and o or o:FindFirstChildWhichIsA("BasePart", true)
            local cd = o:FindFirstChildOfClass("ClickDetector", true)
            local ti = part and part:FindFirstChild("TouchInterest")
            if cd then chestClick += 1 end
            if ti then chestTouch += 1 end
            line(string.format("   %-28s ClickDetector=%s TouchInterest=%s",
                o.Name, tostring(cd ~= nil), tostring(ti ~= nil)))
        end
    end
end
line("   top-level chest-named objects: " .. chestCount)

-- ---------------------------------------------------------------
hdr("EXECUTOR CAPABILITIES  (Solara)")
local caps = {
    "fireclickdetector", "firetouchinterest", "queue_on_teleport",
    "queueonteleport", "getgc", "getrawmetatable", "hookfunction",
    "getconnections", "setclipboard", "identifyexecutor", "getupvalues",
    "debug.getupvalues", "require",
}
for _, name in ipairs(caps) do
    local fn
    if name:find("%.") then
        local a, b = name:match("(.+)%.(.+)")
        fn = rawget(getfenv(), a) and rawget(getfenv(), a)[b]
    else
        fn = rawget(getfenv(), name) or (getgenv and getgenv()[name])
    end
    mark(type(fn) == "function", name)
end
local ident = try(function() return identifyexecutor() end)
line("   executor: " .. tostring(ident or "unknown"))

-- ---------------------------------------------------------------
hdr("VERDICT")
local combatOK = (toolC or toolB) ~= nil
local travelOK = spawnFolder ~= nil and commF ~= nil
local detectOK = enemyFolder ~= nil
line("detection : " .. (detectOK and "ready" or "BROKEN"))
line("travel    : " .. (travelOK and "remote+spawns present (name still unverified)" or "BROKEN"))
line("combat    : " .. (combatOK and "tool present - but Tool:Activate() still unproven" or "NO TOOL"))

print(table.concat(out, "\n"))
if setclipboard then
    pcall(setclipboard, table.concat(out, "\n"))
    print("\n[probe] full report copied to clipboard")
end
