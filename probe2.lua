--[[
    PROBE 2  (incremental)
    ======================
    Prints EVERY line as it is produced and isolates each section in pcall,
    so a failure anywhere still leaves all prior output visible and names the
    section that died. The previous version buffered everything and printed
    once at the end - one error lost the whole report.

    READ-ONLY except for one GetBestQuestNPC invoke, which is a getter.
]]

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local player  = Players.LocalPlayer

local buf = {}
local function line(s)
    s = tostring(s)
    table.insert(buf, s)
    print(s)                     -- print immediately, never buffer-only
end

local function hdr(s)
    line("")
    line("== " .. s .. " ==")
end

local function mark(ok, label, detail)
    line(string.format("%s %s%s", ok and "[PASS]" or "[FAIL]", label,
        detail ~= nil and ("  -> " .. tostring(detail)) or ""))
end

-- Run one section; a failure reports itself and the probe continues.
local function section(name, fn)
    hdr(name)
    local ok, err = pcall(fn)
    if not ok then
        line("   !! SECTION ERROR: " .. tostring(err))
    end
end

line("PROBE 2  (incremental)")
line("time: " .. os.date("%H:%M:%S"))

-- ---------------------------------------------------------------
local function globalFn(path)
    local function walk(root)
        local cur = root
        for part in string.gmatch(path, "[^%.]+") do
            if type(cur) ~= "table" and type(cur) ~= "userdata" then return nil end
            cur = cur[part]
            if cur == nil then return nil end
        end
        return cur
    end

    -- normal global lookup, through the full __index chain
    local ok, res = pcall(function() return walk(_G) end)
    if ok and type(res) == "function" then return res end

    ok, res = pcall(function()
        local g = getgenv and getgenv() or nil
        return g and walk(g) or nil
    end)
    if ok and type(res) == "function" then return res end

    -- bare identifier resolution (covers globals not present as table keys)
    ok, res = pcall(function()
        local chunk = loadstring and loadstring("return " .. path)
        return chunk and chunk() or nil
    end)
    if ok and type(res) == "function" then return res end

    return nil
end

-- ---------------------------------------------------------------
section("EXECUTOR CAPABILITIES (corrected lookup)", function()
    local caps = {
        "getgc", "getreg", "getupvalues", "debug.getupvalues", "debug.getupvalue",
        "getsenv", "getrawmetatable", "setreadonly", "getnamecallmethod",
        "hookfunction", "hookmetamethod", "newcclosure", "getconnections",
        "fireclickdetector", "firetouchinterest", "queue_on_teleport",
        "setclipboard", "getloadedmodules", "getinstances",
        "sethiddenproperty", "gethiddenproperty", "getscripts",
    }
    for _, c in ipairs(caps) do
        mark(globalFn(c) ~= nil, c)
    end
    local ide = globalFn("identifyexecutor")
    if ide then
        local ok, name, ver = pcall(ide)
        line("   executor: " .. tostring(ok and name or "?") .. " " .. tostring(ver or ""))
    end
end)

-- ---------------------------------------------------------------
section("PLAYERSCRIPTS", function()
    local ps = player:FindFirstChild("PlayerScripts")
    mark(ps ~= nil, "player.PlayerScripts")
    if not ps then return end

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
            table.insert(subs, ch.Name .. "(" .. ch.ClassName .. ")")
        end
        line("   descendants (" .. #subs .. "): " .. string.sub(table.concat(subs, ", "), 1, 500))
    end
end)

-- ---------------------------------------------------------------
section("ACTIVE CONTROLLER - 4 ROUTES", function()
    local ps = player:FindFirstChild("PlayerScripts")
    local cfScript = ps and ps:FindFirstChild("CombatFramework")
    local getreg_ = globalFn("getreg")
    local getupv  = globalFn("debug.getupvalues") or globalFn("getupvalues")
    local getgc_  = globalFn("getgc")
    local getsenv_ = globalFn("getsenv")

    line(string.format("   getreg=%s getupvalues=%s getgc=%s getsenv=%s",
        tostring(getreg_ ~= nil), tostring(getupv ~= nil),
        tostring(getgc_ ~= nil), tostring(getsenv_ ~= nil)))

    local found, via

    -- Route A: registry walk + upvalues
    if getreg_ and getupv and cfScript then
        pcall(function()
            for _, v in pairs(getreg_()) do
                if typeof(v) == "function" then
                    local okE, fenv = pcall(getfenv, v)
                    if okE and type(fenv) == "table" and rawget(fenv, "script") == cfScript then
                        local okU, ups = pcall(getupv, v)
                        if okU and type(ups) == "table" then
                            for _, up in pairs(ups) do
                                if typeof(up) == "table" and rawget(up, "activeController") ~= nil then
                                    found, via = up, "A: getreg+getupvalues"
                                    return
                                end
                            end
                        end
                    end
                end
            end
        end)
    end
    line("   route A " .. (found and "HIT" or "miss"))

    -- Route B: garbage collector scan
    if not found and getgc_ then
        pcall(function()
            for _, v in pairs(getgc_(true)) do
                if typeof(v) == "table" and rawget(v, "activeController") ~= nil then
                    found, via = v, "B: getgc"
                    return
                end
            end
        end)
    end
    line("   route B " .. (found and "HIT" or "miss"))

    -- Route C: script environment of the CombatFramework LocalScript
    if not found and getsenv_ and cfScript then
        pcall(function()
            local env = getsenv_(cfScript)
            if type(env) == "table" then
                local keys = {}
                for k in pairs(env) do table.insert(keys, tostring(k)) end
                table.sort(keys)
                line("   getsenv keys: " .. string.sub(table.concat(keys, ", "), 1, 400))
                for _, v in pairs(env) do
                    if typeof(v) == "table" and rawget(v, "activeController") ~= nil then
                        found, via = v, "C: getsenv"
                        return
                    end
                end
                if rawget(env, "activeController") ~= nil then
                    found, via = env, "C: getsenv direct"
                end
            end
        end)
    end
    line("   route C " .. (found and "HIT" or "miss"))

    -- Route D: require the module (only works if it is a ModuleScript)
    if not found and cfScript then
        pcall(function()
            if cfScript:IsA("ModuleScript") then
                local mod = require(cfScript)
                if typeof(mod) == "table" and rawget(mod, "activeController") ~= nil then
                    found, via = mod, "D: require"
                end
            end
        end)
    end
    line("   route D " .. (found and "HIT" or "miss"))

    mark(found ~= nil, "activeController REACHABLE", via)
    if found then
        local ac = rawget(found, "activeController")
        if typeof(ac) == "table" then
            local fields = {}
            for k, v in pairs(ac) do
                table.insert(fields, tostring(k) .. "=" .. typeof(v))
            end
            table.sort(fields)
            line("   fields: " .. string.sub(table.concat(fields, ", "), 1, 600))
        else
            line("   activeController is " .. typeof(ac) .. " right now (equip a SWORD and re-run)")
        end
    end
end)

-- ---------------------------------------------------------------
section("WEAPONS", function()
    local char = player.Character
    local bp = player:FindFirstChildOfClass("Backpack")
    local eq = char and char:FindFirstChildOfClass("Tool")
    line("   equipped: " .. (eq and eq.Name or "none"))
    if bp then
        for _, t in ipairs(bp:GetChildren()) do
            local attrs = {}
            for k, v in pairs(t:GetAttributes()) do
                table.insert(attrs, tostring(k) .. "=" .. tostring(v))
            end
            line(string.format("   backpack: %-18s class=%s attrs={%s}",
                t.Name, t.ClassName, table.concat(attrs, ",")))
        end
    end
end)

-- ---------------------------------------------------------------
section("GetBestQuestNPC", function()
    local remotes = RS:FindFirstChild("Remotes")
    local gbq = remotes and remotes:FindFirstChild("GetBestQuestNPC")
    mark(gbq ~= nil, "Remotes.GetBestQuestNPC", gbq and gbq.ClassName)
    if not gbq then return end

    if gbq:IsA("RemoteFunction") then
        local ok, res = pcall(function() return gbq:InvokeServer() end)
        if not ok then
            line("   invoke failed: " .. tostring(res))
            return
        end
        line("   returns " .. typeof(res) .. ": " .. tostring(res))
        if typeof(res) == "table" then
            for k, v in pairs(res) do
                line("      " .. tostring(k) .. " = " .. tostring(v) .. "  (" .. typeof(v) .. ")")
            end
        end
    else
        line("   not a RemoteFunction, skipping invoke")
    end
end)

-- ---------------------------------------------------------------
section("STREAMING", function()
    line("   workspace.StreamingEnabled = " .. tostring(workspace.StreamingEnabled))
    local okM = pcall(function() return player.RequestStreamAroundAsync end)
    mark(okM, "player:RequestStreamAroundAsync exists")
    local remotes = RS:FindFirstChild("Remotes")
    local rsa = remotes and remotes:FindFirstChild("RequestStreamAroundAsync")
    mark(rsa ~= nil, "Remotes.RequestStreamAroundAsync", rsa and rsa.ClassName)
end)

-- ---------------------------------------------------------------
section("ENEMY SHAPE", function()
    local ef = workspace:FindFirstChild("Enemies")
    if not ef then line("   no Enemies folder") return end
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
            line(string.format("   %-16s hp=%s/%s  attrs{%s}",
                m.Name,
                hum and math.floor(hum.Health) or "?",
                hum and math.floor(hum.MaxHealth) or "?",
                string.sub(table.concat(attrs, ","), 1, 220)))
        end
    end
end)

line("")
line("== PROBE 2 COMPLETE ==")
if setclipboard then pcall(setclipboard, table.concat(buf, "\n")) end
