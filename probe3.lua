--[[
    PROBE 3 - self-displaying
    =========================
    Solara has no console, so this does not rely on print():
      * renders every line into an on-screen, selectable TextBox
      * rewrites the clipboard after EVERY line, so a crash still leaves
        the full partial report on the clipboard
      * each section is isolated; a failure names itself and the probe continues

    The UI is built FIRST, before anything that can fail.
]]

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local player  = Players.LocalPlayer

-- =========================================================
-- OUTPUT SURFACE (built first, deliberately)
-- =========================================================
local buf = {}
local box

do
    local ok = pcall(function()
        local pg = player:WaitForChild("PlayerGui", 10)
        local old = pg:FindFirstChild("Probe3")
        if old then old:Destroy() end

        local gui = Instance.new("ScreenGui")
        gui.Name = "Probe3"
        gui.ResetOnSpawn = false
        gui.IgnoreGuiInset = true
        gui.DisplayOrder = 999
        gui.Parent = pg

        local panel = Instance.new("Frame")
        panel.Size = UDim2.new(0.7, 0, 0.8, 0)
        panel.Position = UDim2.new(0.15, 0, 0.1, 0)
        panel.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
        panel.BorderSizePixel = 0
        panel.Active = true
        panel.Draggable = true
        panel.Parent = gui

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -90, 0, 26)
        title.Position = UDim2.fromOffset(8, 2)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 13
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.TextColor3 = Color3.fromRGB(235, 242, 250)
        title.Text = "PROBE 3 - select text and Ctrl+C, or it is on your clipboard"
        title.Parent = panel

        local close = Instance.new("TextButton")
        close.Size = UDim2.fromOffset(70, 20)
        close.Position = UDim2.new(1, -78, 0, 4)
        close.BackgroundColor3 = Color3.fromRGB(60, 30, 34)
        close.Font = Enum.Font.GothamBold
        close.TextSize = 11
        close.TextColor3 = Color3.fromRGB(255, 200, 200)
        close.Text = "CLOSE"
        close.Parent = panel
        close.Activated:Connect(function() gui:Destroy() end)

        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1, -12, 1, -34)
        scroll.Position = UDim2.fromOffset(6, 30)
        scroll.BackgroundColor3 = Color3.fromRGB(16, 19, 25)
        scroll.BorderSizePixel = 0
        scroll.CanvasSize = UDim2.new(0, 0, 0, 4000)
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
    if not ok then box = nil end
end

local function line(s)
    s = tostring(s)
    table.insert(buf, s)
    local all = table.concat(buf, "\n")
    pcall(function() print(s) end)
    if box then pcall(function() box.Text = all end) end
    -- rewrite the clipboard every line so a crash still leaves a full report
    if setclipboard then pcall(setclipboard, all) end
end

local function hdr(s) line("") line("== " .. s .. " ==") end

local function mark(ok, label, detail)
    line((ok and "[PASS] " or "[FAIL] ") .. label ..
        (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
end

local function section(name, fn)
    hdr(name)
    local ok, err = pcall(fn)
    if not ok then line("   !! SECTION ERROR: " .. tostring(err)) end
end

line("PROBE 3")
line("time: " .. os.date("%H:%M:%S"))

-- =========================================================
local function globalFn(path)
    local function walk(root)
        local cur = root
        for part in string.gmatch(path, "[^%.]+") do
            local t = type(cur)
            if t ~= "table" and t ~= "userdata" then return nil end
            cur = cur[part]
            if cur == nil then return nil end
        end
        return cur
    end
    local ok, res = pcall(walk, _G)
    if ok and type(res) == "function" then return res end
    ok, res = pcall(function()
        local g = getgenv and getgenv()
        if not g then return nil end
        return walk(g)
    end)
    if ok and type(res) == "function" then return res end
    return nil
end

-- =========================================================
section("EXECUTOR CAPABILITIES", function()
    local caps = {
        "getgc", "getreg", "getupvalues", "debug.getupvalues",
        "getsenv", "getrawmetatable", "setreadonly", "getnamecallmethod",
        "hookfunction", "hookmetamethod", "newcclosure", "getconnections",
        "fireclickdetector", "firetouchinterest", "queue_on_teleport",
        "setclipboard", "getloadedmodules", "sethiddenproperty",
    }
    for _, c in ipairs(caps) do mark(globalFn(c) ~= nil, c) end
end)

-- =========================================================
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
    mark(cf ~= nil, "CombatFramework", cf and cf.ClassName)
    if cf then
        local subs = {}
        for _, ch in ipairs(cf:GetDescendants()) do
            table.insert(subs, ch.Name .. "(" .. ch.ClassName .. ")")
        end
        line("   descendants: " .. string.sub(table.concat(subs, ", "), 1, 400))
    end
end)

-- =========================================================
section("ACTIVE CONTROLLER", function()
    local ps = player:FindFirstChild("PlayerScripts")
    local cfScript = ps and ps:FindFirstChild("CombatFramework")
    local getreg_  = globalFn("getreg")
    local getupv   = globalFn("debug.getupvalues") or globalFn("getupvalues")
    local getgc_   = globalFn("getgc")
    local getsenv_ = globalFn("getsenv")

    line("   getreg=" .. tostring(getreg_ ~= nil) ..
         " getupvalues=" .. tostring(getupv ~= nil) ..
         " getgc=" .. tostring(getgc_ ~= nil) ..
         " getsenv=" .. tostring(getsenv_ ~= nil))

    local found, via

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
    line("   route A (registry): " .. (found and "HIT" or "miss"))

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
    line("   route B (getgc): " .. (found and "HIT" or "miss"))

    if not found and getsenv_ and cfScript then
        pcall(function()
            local env = getsenv_(cfScript)
            if type(env) == "table" then
                for _, v in pairs(env) do
                    if typeof(v) == "table" and rawget(v, "activeController") ~= nil then
                        found, via = v, "getsenv"
                        return
                    end
                end
            end
        end)
    end
    line("   route C (getsenv): " .. (found and "HIT" or "miss"))

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
            line("   activeController currently " .. typeof(ac) .. " - equip a SWORD and re-run")
        end
    end
end)

-- =========================================================
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
            line("   backpack: " .. t.Name .. "  class=" .. t.ClassName ..
                 "  attrs{" .. table.concat(attrs, ",") .. "}")
        end
    end
end)

-- =========================================================
section("GetBestQuestNPC", function()
    local remotes = RS:FindFirstChild("Remotes")
    local gbq = remotes and remotes:FindFirstChild("GetBestQuestNPC")
    mark(gbq ~= nil, "Remotes.GetBestQuestNPC", gbq and gbq.ClassName)
    if not gbq or not gbq:IsA("RemoteFunction") then return end
    local ok, res = pcall(function() return gbq:InvokeServer() end)
    if not ok then line("   invoke failed: " .. tostring(res)) return end
    line("   returns " .. typeof(res) .. ": " .. tostring(res))
    if typeof(res) == "table" then
        for k, v in pairs(res) do
            line("      " .. tostring(k) .. " = " .. tostring(v) .. " (" .. typeof(v) .. ")")
        end
    end
end)

-- =========================================================
section("STREAMING", function()
    line("   StreamingEnabled = " .. tostring(workspace.StreamingEnabled))
    local remotes = RS:FindFirstChild("Remotes")
    local rsa = remotes and remotes:FindFirstChild("RequestStreamAroundAsync")
    mark(rsa ~= nil, "Remotes.RequestStreamAroundAsync", rsa and rsa.ClassName)
end)

-- =========================================================
section("ENEMY SHAPE", function()
    local ef = workspace:FindFirstChild("Enemies")
    if not ef then line("   no Enemies folder") return end
    local kids = ef:GetChildren()
    line("   loaded: " .. #kids)
    local shown = 0
    for _, m in ipairs(kids) do
        if m:IsA("Model") and shown < 3 then
            shown = shown + 1
            local attrs = {}
            for k, v in pairs(m:GetAttributes()) do
                table.insert(attrs, tostring(k) .. "=" .. tostring(v))
            end
            table.sort(attrs)
            local hum = m:FindFirstChildOfClass("Humanoid")
            line("   " .. m.Name ..
                 "  hp=" .. tostring(hum and math.floor(hum.Health) or "?") ..
                 "/" .. tostring(hum and math.floor(hum.MaxHealth) or "?") ..
                 "  attrs{" .. string.sub(table.concat(attrs, ","), 1, 200) .. "}")
        end
    end
end)

line("")
line("== PROBE 3 COMPLETE ==")
