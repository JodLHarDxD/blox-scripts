--[[
    COMBAT SNIFFER
    ==============
    Update 30 removed CombatFramework from PlayerScripts, so the usual
    fast-attack route is dead. Solara also lacks getupvalues/getgc/getsenv.

    But it HAS getrawmetatable + setreadonly + getnamecallmethod + newcclosure,
    which is all a __namecall hook needs. So instead of reading the game's
    combat internals, we watch what it SENDS when you attack, and later replay
    exactly that.

    HOW TO USE
      1. Run this.
      2. Equip your melee weapon (Combat / a sword) - NOT the fruit.
      3. Walk up to an enemy and attack normally, 3-4 times, by hand.
      4. Read the panel. Press CAPTURE to copy everything.
      5. Send it back.

    Everything is logged with arguments so the attack call can be reproduced.
    Output renders on screen and to the clipboard - no console required.

    _G.SNIFF.stop()   removes the hook and the UI
]]

if _G.SNIFF and _G.SNIFF.stop then pcall(_G.SNIFF.stop) end

local Players = game:GetService("Players")
local player  = Players.LocalPlayer

local S = { running = true }
_G.SNIFF = S

-- =========================================================
-- OUTPUT (built first - no console on Solara)
-- =========================================================
local buf, box, counterLabel = {}, nil, nil
local MAXBUF = 400

local function flush()
    local all = table.concat(buf, "\n")
    if box then pcall(function() box.Text = all end) end
    if setclipboard then pcall(setclipboard, all) end
end

local function line(s)
    table.insert(buf, tostring(s))
    if #buf > MAXBUF then table.remove(buf, 1) end
    pcall(function() print(s) end)
    flush()
end

pcall(function()
    local pg = player:WaitForChild("PlayerGui", 10)
    local old = pg:FindFirstChild("CombatSniffer")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "CombatSniffer"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999
    gui.Parent = pg

    local panel = Instance.new("Frame")
    panel.Size = UDim2.new(0.62, 0, 0.66, 0)
    panel.Position = UDim2.new(0.19, 0, 0.17, 0)
    panel.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
    panel.BorderSizePixel = 0
    panel.Active = true
    panel.Draggable = true
    panel.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -160, 0, 24)
    title.Position = UDim2.fromOffset(8, 3)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(235, 242, 250)
    title.Text = "COMBAT SNIFFER - equip melee, then attack by hand"
    title.Parent = panel

    counterLabel = Instance.new("TextLabel")
    counterLabel.Size = UDim2.new(0, 150, 0, 16)
    counterLabel.Position = UDim2.fromOffset(8, 24)
    counterLabel.BackgroundTransparency = 1
    counterLabel.Font = Enum.Font.Code
    counterLabel.TextSize = 11
    counterLabel.TextXAlignment = Enum.TextXAlignment.Left
    counterLabel.TextColor3 = Color3.fromRGB(150, 170, 190)
    counterLabel.Text = "calls 0"
    counterLabel.Parent = panel

    local cap = Instance.new("TextButton")
    cap.Size = UDim2.fromOffset(72, 20)
    cap.Position = UDim2.new(1, -156, 0, 3)
    cap.BackgroundColor3 = Color3.fromRGB(30, 58, 40)
    cap.Font = Enum.Font.GothamBold
    cap.TextSize = 11
    cap.TextColor3 = Color3.fromRGB(190, 240, 200)
    cap.Text = "CAPTURE"
    cap.Parent = panel
    cap.Activated:Connect(function()
        flush()
        line("-- captured to clipboard --")
    end)

    local clr = Instance.new("TextButton")
    clr.Size = UDim2.fromOffset(62, 20)
    clr.Position = UDim2.new(1, -80, 0, 3)
    clr.BackgroundColor3 = Color3.fromRGB(58, 30, 34)
    clr.Font = Enum.Font.GothamBold
    clr.TextSize = 11
    clr.TextColor3 = Color3.fromRGB(255, 200, 200)
    clr.Text = "CLEAR"
    clr.Parent = panel
    clr.Activated:Connect(function()
        table.clear(buf)
        flush()
    end)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -12, 1, -46)
    scroll.Position = UDim2.fromOffset(6, 42)
    scroll.BackgroundColor3 = Color3.fromRGB(16, 19, 25)
    scroll.BorderSizePixel = 0
    scroll.CanvasSize = UDim2.new(0, 0, 0, 6000)
    scroll.ScrollBarThickness = 8
    scroll.Parent = panel

    box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -8, 1, 0)
    box.Position = UDim2.fromOffset(4, 0)
    box.BackgroundTransparency = 1
    box.ClearTextOnFocus = false
    box.MultiLine = true
    box.TextEditable = false
    box.Font = Enum.Font.Code
    box.TextSize = 12
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.TextYAlignment = Enum.TextYAlignment.Top
    box.TextColor3 = Color3.fromRGB(200, 215, 230)
    box.TextWrapped = true
    box.Text = ""
    box.Parent = scroll
end)

-- =========================================================
-- VALUE RENDERING
-- =========================================================
local function repr(v, depth)
    depth = depth or 0
    local t = typeof(v)
    if t == "string" then
        if #v > 60 then v = string.sub(v, 1, 57) .. "..." end
        return '"' .. v .. '"'
    elseif t == "Instance" then
        return v.ClassName .. "(" .. v.Name .. ")"
    elseif t == "Vector3" then
        return string.format("V3(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z)
    elseif t == "CFrame" then
        local p = v.Position
        return string.format("CF(%.0f,%.0f,%.0f)", p.X, p.Y, p.Z)
    elseif t == "table" then
        if depth >= 3 then return "{...}" end
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 10 then
                table.insert(parts, "...")
                break
            end
            table.insert(parts, "[" .. tostring(k) .. "]=" .. repr(val, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function reprArgs(args, n)
    local parts = {}
    for i = 1, n do
        table.insert(parts, repr(args[i]))
    end
    return table.concat(parts, ", ")
end

-- =========================================================
-- NAMECALL HOOK
-- =========================================================
local calls = 0
local seen = {}          -- signature -> count, so spam collapses
local restore = nil

-- Remotes that fire constantly and drown the signal.
local NOISE = {
    ClientLoDPosition = true, ReportActivity = true, Location = true,
    SetLocalMovers = true, ClientLoD = true, RobloxAnalytics = true,
    InitAnalytics = true, OnAnalyticsUpdate = true, Clock = true,
    DangerDistance = true, SyncAnimations = true, MinValue = true,
    CharacterTransparency = true, Stats = true, ReplicateStats = true,
}

local ok, err = pcall(function()
    local mt = getrawmetatable(game)
    local oldNamecall = mt.__namecall

    local hook = function(self, ...)
        if S.running and typeof(self) == "Instance" then
            local cls = self.ClassName
            if cls == "RemoteEvent" or cls == "RemoteFunction"
                or cls == "UnreliableRemoteEvent" then
                local method = ""
                pcall(function() method = getnamecallmethod() end)
                if method == "FireServer" or method == "InvokeServer" then
                    if not NOISE[self.Name] then
                        local args = table.pack(...)
                        local first = args.n > 0 and tostring(args[1]) or ""
                        local sig = self.Name .. "|" .. first
                        seen[sig] = (seen[sig] or 0) + 1
                        calls = calls + 1
                        if counterLabel then
                            pcall(function()
                                counterLabel.Text = "calls " .. calls
                            end)
                        end
                        -- log the first 3 of any signature, then every 25th
                        local c = seen[sig]
                        if c <= 3 or c % 25 == 0 then
                            pcall(function()
                                line(string.format("%s:%s(%s)%s",
                                    self.Name, method, reprArgs(args, args.n),
                                    c > 3 and ("   x" .. c) or ""))
                            end)
                        end
                    end
                end
            end
        end
        return oldNamecall(self, ...)
    end

    local final = hook
    if newcclosure then
        local okc, wrapped = pcall(newcclosure, hook)
        if okc and wrapped then final = wrapped end
    end

    setreadonly(mt, false)
    mt.__namecall = final
    pcall(setreadonly, mt, true)

    restore = function()
        pcall(function()
            setreadonly(mt, false)
            mt.__namecall = oldNamecall
            pcall(setreadonly, mt, true)
        end)
    end
end)

line("COMBAT SNIFFER " .. os.date("%H:%M:%S"))
line(ok and "hook INSTALLED" or ("hook FAILED: " .. tostring(err)))
line("")

-- Report what is equipped, since attacking with a fruit logs fruit moves.
pcall(function()
    local char = player.Character
    local eq = char and char:FindFirstChildOfClass("Tool")
    line("equipped: " .. (eq and eq.Name or "NONE"))
    local bp = player:FindFirstChildOfClass("Backpack")
    if bp then
        local names = {}
        for _, t in ipairs(bp:GetChildren()) do
            local wt = t:GetAttribute("WeaponType")
            table.insert(names, t.Name .. (wt and ("[" .. tostring(wt) .. "]") or ""))
        end
        line("backpack: " .. table.concat(names, ", "))
    end
    line("")
    line(">> Equip your MELEE weapon, then attack an enemy by hand 3-4 times.")
    line("")
end)

-- =========================================================
-- HELPERS
-- =========================================================
function S.summary()
    line("")
    line("=== SIGNATURE SUMMARY ===")
    local rows = {}
    for sig, n in pairs(seen) do
        table.insert(rows, { sig = sig, n = n })
    end
    table.sort(rows, function(a, b) return a.n > b.n end)
    for _, r in ipairs(rows) do
        line(string.format("  %-52s x%d", r.sig, r.n))
    end
    flush()
end

function S.stop()
    S.running = false
    if restore then pcall(restore) end
    pcall(function()
        local pg = player:FindFirstChild("PlayerGui")
        local g = pg and pg:FindFirstChild("CombatSniffer")
        if g then g:Destroy() end
    end)
    print("[SNIFF] stopped, hook restored")
end
