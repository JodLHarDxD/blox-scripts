--[[
    PROBE 2 - corrected instrument
    ==============================
    Fixes two bugs in probe.lua:
      * capability checks used rawget(getfenv(),..) which bypasses the __index
        chain, producing false FAILs for inherited globals. Now uses a plain
        global lookup inside pcall.
      * CombatFramework was searched in ReplicatedStorage; it lives in
        PlayerScripts.

    Also probes the three things your remote list revealed:
      GetBestQuestNPC, RequestStreamAroundAsync, and the real weapon set.

    READ-ONLY. Invokes nothing that mutates state.
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

line("PROBE 2")
line("time: " .. os.date("%H:%M:%S"))

-- ---------------------------------------------------------------
-- 1. EXECUTOR CAPABILITIES  (corrected lookup)
-- ---------------------------------------------------------------
hdr("EXECUTOR CAPABILITIES (corrected)")

-- Plain global read through the full __index chain, inside pcall.
local function globalFn(path)
    local ok, res = pcall(function()
        local cur = getfenv(0)
        for part in string.gmatch(path, "[^%.]+") do
            cur = cur[part]
            if cur == nil then return nil end
        end
        return cur
    end)
    if ok and type(res) == "function" then return res end
    -- second chance: getgenv
    local ok2, res2 = pcall(function()
        local g = getgenv and getgenv()
        if not g then return nil end
        local cur = g
        for part in string.gmatch(path, "[^%.]+") do
            cur = cur[part]
            if cur == nil then return nil end
        end
        return cur
    end)
    if ok2 and type(res2) == "function" then return res2 end
    return nil
end

local caps = {
    "getgc", "getreg", "getupvalues", "debug.getupvalues", "debug.getupvalue",
    "getrawmetatable", "setreadonly", "getnamecallmethod", "hookfunction",
    "hookmetamethod", "newcclosure", "getconnections", "fireclickdetector",
    "firetouchinterest", "queue_on_teleport", "setclipboard", "getsenv",
    "getloadedmodules", "getinstances", "sethiddenproperty", "gethiddenproperty",
}
for _, c in ipairs(caps) do
    mark(globalFn(c) ~= nil, c)
end
line("   executor: " .. tostring((globalFn("identifyexecutor") and identifyexecutor()) or "unknown"))

-- ---------------------------------------------------------------
-- 2. COMBAT FRAMEWORK  (correct location)
-- ---------------------------------------------------------------
hdr("COMBAT FRAMEWORK (PlayerScripts)")

local ps = player:FindFirstChild("PlayerScripts")
mark(ps ~= nil, "player.PlayerScripts")
if ps then
    local names = {}
    for _, ch in ipairs(ps:GetChildren()) do
        table.insert(names, ch.Name .. "(" .. ch.ClassName .. ")")
    end
    table.sort(names)
    line("   children: " .. table.concat(names, ", "))

    local cf = ps:FindFirstChild("CombatFramework")
    mark(cf ~= nil, "PlayerScripts.CombatFramework", cf and cf.ClassName)
    if cf then
        local subs = {}
        for _, ch in ipairs(cf:GetDescendants()) do
            table.insert(subs, ch.Name)
        end
        line("   descendants (" .. #subs .. "): " .. table.concat(subs, ", "):sub(1, 400))
    end
end

-- Can we actually reach activeController? This is the decisive test.
hdr("ACTIVE CONTROLLER REACHABILITY")
do
    local getreg_ = globalFn("getreg")
    local getupv  = globalFn("debug.getupvalues") or globalFn("getupvalues")
    local getgc_  = globalFn("getgc")

    line("   getreg=" .. tostring(getreg_ ~= nil)
        .. "  getupvalues=" .. tostring(getupv ~= nil)
        .. "  getgc=" .. tostring(getgc_ ~= nil))

    local cfScript = ps and ps:FindFirstChild("CombatFramework")
    local found, via = nil, nil

    -- Route A: registry walk + upvalues
    if getreg_ and getupv and cfScript then
        pcall(function()
            for _, v in pairs(getreg_()) do
                if typeof(v) == "function" then
                    local okE, fenv = pcall(getfenv, v)
                    if okE and fenv and rawget(fenv, "script") == cfScript then
                        local okU, ups = pcall(getupv, v)
                        if okU and ups then
                            for _, up in pairs(ups) do
                                if typeof(up) == "table" and rawget(up, "activeController") ~= nil then
                                    found, via = up, "getreg+getupvalues"
                                    return
                                end
                            end
                        end
                    end
                end
            end
        end)
    end

    -- Route B: garbage collector scan for the controller table directly
    if not found and getgc_ then
        pcall(function()
            for _, v in pairs(getgc_(true)) do
                if typeof(v) == "table" and rawget(v, "activeController") ~= nil then
                    found, via = v, "getgc"
                    return
                end
            end
        end)
    end

    -- Route C: require the module directly (works when it returns the table)
    if not found and cfScript then
        pcall(function()
            local mod = require(cfScript)
            if typeof(mod) == "table" and rawget(mod, "activeController") ~= nil then
                found, via = mod, "require"
            end
        end)
    end

    mark(found ~= nil, "activeController reachable", via)
    if found then
        local ac = rawget(found, "activeController")
        if typeof(ac) == "table" then
            local fields = {}
            for k, v in pairs(ac) do
                table.insert(fields, tostring(k) .. "=" .. typeof(v))
            end
            table.sort(fields)
            line("   activeController fields: " .. table.concat(fields, ", "):sub(1, 500))
        else
            line("   activeController is currently: " .. typeof(ac) .. " (equip a weapon and re-run)")
        end
    end
end

-- ---------------------------------------------------------------
-- 3. WEAPONS
-- ---------------------------------------------------------------
hdr("WEAPONS")
local char = player.Character
local bp = player:FindFirstChildOfClass("Backpack")
local equipped = char and char:FindFirstChildOfClass("Tool")
line("   equipped: " .. (equipped and equipped.Name or "none"))
if bp then
    for _, t in ipairs(bp:GetChildren()) do
        local kind = t:GetAttribute("ToolType") or t:GetAttribute("Type") or "?"
        line(string.format("   backpack: %-22s class=%s type=%s", t.Name, t.ClassName, tostring(kind)))
    end
end

-- ---------------------------------------------------------------
-- 4. QUEST HELPER REMOTE
-- ---------------------------------------------------------------
hdr("GetBestQuestNPC")
local remotes = RS:FindFirstChild("Remotes")
local gbq = remotes and remotes:FindFirstChild("GetBestQuestNPC")
mark(gbq ~= nil, "Remotes.GetBestQuestNPC", gbq and gbq.ClassName)
if gbq and gbq:IsA("RemoteFunction") then
    local ok, res = pcall(function() return gbq:InvokeServer() end)
    if ok then
        line("   returns: " .. typeof(res) .. "  value=" .. tostring(res))
        if typeof(res) == "table" then
            for k, v in pairs(res) do
                line("      " .. tostring(k) .. " = " .. tostring(v))
            end
        end
    else
        line("   invoke failed: " .. tostring(res))
    end
end

-- ---------------------------------------------------------------
-- 5. STREAMING CONTROL
-- ---------------------------------------------------------------
hdr("STREAMING")
line("   workspace.StreamingEnabled = " .. tostring(workspace.StreamingEnabled))
mark(typeof(player.RequestStreamAroundAsync) == "function",
    "player:RequestStreamAroundAsync (native)")
local rsa = remotes and remotes:FindFirstChild("RequestStreamAroundAsync")
mark(rsa ~= nil, "Remotes.RequestStreamAroundAsync", rsa and rsa.ClassName)

-- ---------------------------------------------------------------
-- 6. ENEMY SHAPE  (confirm naming + level attribute)
-- ---------------------------------------------------------------
hdr("ENEMY SHAPE")
local ef = workspace:FindFirstChild("Enemies")
if ef then
    local kids = ef:GetChildren()
    line("   loaded: " .. #kids)
    local shown = 0
    for _, m in ipairs(kids) do
        if m:IsA("Model") and shown < 4 then
            shown += 1
            local attrs = {}
            for k, v in pairs(m:GetAttributes()) do
                table.insert(attrs, tostring(k) .. "=" .. tostring(v))
            end
            table.sort(attrs)
            local hum = m:FindFirstChildOfClass("Humanoid")
            line(string.format("   %-18s hp=%s/%s attrs: %s",
                m.Name,
                hum and math.floor(hum.Health) or "?",
                hum and math.floor(hum.MaxHealth) or "?",
                table.concat(attrs, ", "):sub(1, 200)))
        end
    end
end

print(table.concat(out, "\n"))
if setclipboard then pcall(setclipboard, table.concat(out, "\n")) end
