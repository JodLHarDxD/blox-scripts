--[[
    TELEPORT PROBE  v3
    ==================
    Goal: find out exactly what the game's own HOUSE button does, so the same
    mechanism can be pointed anywhere.

    WHAT v2 TAUGHT US
    Your executor reports:
        have    : getrawmetatable, setreadonly, getnamecallmethod, newcclosure,
                  getinfo, setclipboard
        missing : hookmetamethod, getconnections, getconstants, getupvalues

    Two consequences, and they shape this whole file:

      1. Without getconnections/getconstants the button's own code CANNOT be
         read. That door is closed. Do not waste time on it.
      2. v2 died silently at the raw-metatable hook - no error, no further
         lines, which is a killed thread rather than an exception. So the hook
         is no longer part of loading. It sits behind a button, it prints a
         marker BEFORE every step, and if it takes the thread down again the
         last marker on your clipboard names the exact step that did it.

    WHAT STILL WORKS, AND IS ENOUGH
    Plain Roblox events need no executor powers at all:

      CLICKS      connect to every button ourselves -> which one you pressed
      LIFECYCLE   CharacterRemoving / CharacterAdded -> whether the teleport
                  works by RESPAWNING you or by moving the body you have
      MOVEMENT    position jumps -> where it put you
      SPAWN MATCH the nearest entry in _WorldOrigin.PlayerSpawns to where you
                  landed -> the destination in the GAME'S OWN vocabulary

    That last pair is the answer either way:
      * character removed + added   -> respawn teleport. The spawn name we
        print is the exact string SetLastSpawnPoint wants.
      * body kept, position jumped  -> a plain CFrame write, which we can copy
        outright with no remote at all.

    WHAT TO DO
      execute -> press the HOUSE button -> paste what appears.
      Optional: press HOOK REMOTES afterwards if you want the remote name too.
]]

local Players = game:GetService("Players")
local player  = Players.LocalPlayer

-- =========================================================
-- OUTPUT  (first, and nothing before it)
-- =========================================================
local buf       = {}
local body, scroller, statusLbl, gui
local MAXLINES  = 500
local startedAt = os.clock()

local function flush()
    pcall(function()
        if body then body.Text = table.concat(buf, "\n") end
        if scroller then scroller.CanvasPosition = Vector2.new(0, 1e6) end
    end)
    -- rewritten after EVERY line: a thread that dies mid-way still leaves the
    -- full partial report on the clipboard, which is how v2 was diagnosed
    if setclipboard then pcall(setclipboard, table.concat(buf, "\n")) end
end

local function out(line)
    table.insert(buf, tostring(line))
    if #buf > MAXLINES then table.remove(buf, 1) end
    flush()
end

local function stamp(line)
    out(string.format("[%6.1f] %s", os.clock() - startedAt, tostring(line)))
end

local function status(s)
    pcall(function() if statusLbl then statusLbl.Text = tostring(s) end end)
end

local function guard(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then out("ERROR in " .. name .. ": " .. tostring(err)) end
    return ok
end

local H = {}

-- =========================================================
-- PANEL
-- =========================================================
do
    local pg = player:WaitForChild("PlayerGui", 10)
    local host = (gethui and gethui()) or pg
    local old = host:FindFirstChild("TeleportProbe")
    if old then pcall(function() old:Destroy() end) end

    gui = Instance.new("ScreenGui")
    gui.Name = "TeleportProbe"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999
    gui.Parent = host

    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(600, 460)
    panel.Position = UDim2.fromOffset(40, 50)
    panel.BackgroundColor3 = Color3.fromRGB(18, 18, 20)
    panel.BorderSizePixel = 0
    panel.Active = true
    panel.Draggable = true
    panel.Parent = gui
    local pc = Instance.new("UICorner") pc.CornerRadius = UDim.new(0, 14) pc.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 0, 22)
    title.Position = UDim2.fromOffset(14, 8)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(245, 245, 247)
    title.Text = "Teleport probe v3"
    title.Parent = panel

    statusLbl = Instance.new("TextLabel")
    statusLbl.Size = UDim2.new(1, -20, 0, 16)
    statusLbl.Position = UDim2.fromOffset(14, 29)
    statusLbl.BackgroundTransparency = 1
    statusLbl.Font = Enum.Font.Gotham
    statusLbl.TextSize = 12
    statusLbl.TextXAlignment = Enum.TextXAlignment.Left
    statusLbl.TextColor3 = Color3.fromRGB(142, 142, 147)
    statusLbl.Text = "starting"
    statusLbl.Parent = panel

    scroller = Instance.new("ScrollingFrame")
    scroller.Size = UDim2.new(1, -28, 1, -108)
    scroller.Position = UDim2.fromOffset(14, 50)
    scroller.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
    scroller.BorderSizePixel = 0
    scroller.ScrollBarThickness = 4
    scroller.ScrollBarImageColor3 = Color3.fromRGB(90, 90, 98)
    scroller.CanvasSize = UDim2.new()
    scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroller.Parent = panel
    local sc = Instance.new("UICorner") sc.CornerRadius = UDim.new(0, 10) sc.Parent = scroller

    body = Instance.new("TextBox")
    body.Size = UDim2.new(1, -12, 0, 0)
    body.Position = UDim2.fromOffset(6, 4)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.ClearTextOnFocus = false
    body.MultiLine = true
    body.TextEditable = false
    body.TextWrapped = true
    body.Font = Enum.Font.Code
    body.TextSize = 12
    body.TextColor3 = Color3.fromRGB(225, 236, 246)
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.Text = ""
    body.Parent = scroller

    local function mkButton(x, w, text, colour, key)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(w, 30)
        b.Position = UDim2.new(0, x, 1, -44)
        b.BackgroundColor3 = colour
        b.Font = Enum.Font.GothamMedium
        b.TextSize = 12
        b.TextColor3 = Color3.fromRGB(245, 245, 247)
        b.Text = text
        b.AutoButtonColor = false
        b.Parent = panel
        local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 8) c.Parent = b
        b.Activated:Connect(function()
            local fn = H[key]
            if not fn then
                status(key .. " never loaded - see the last line in the box")
                return
            end
            guard(key, fn, b)
        end)
        return b
    end

    mkButton(14,  104, "RECORDING",    Color3.fromRGB(48, 209, 88),  "toggle")
    mkButton(124, 128, "HOOK REMOTES", Color3.fromRGB(255, 159, 10), "hook")
    mkButton(258, 96,  "SPAWNS",       Color3.fromRGB(44, 44, 49),   "spawns")
    mkButton(360, 90,  "BUTTONS",      Color3.fromRGB(44, 44, 49),   "buttons")
    mkButton(456, 70,  "WHERE",        Color3.fromRGB(44, 44, 49),   "where")
    mkButton(532, 30,  "CLR",          Color3.fromRGB(44, 44, 49),   "clear")
    mkButton(568, 24,  "X",            Color3.fromRGB(255, 69, 58),  "close")
end

out("== TELEPORT PROBE v3 ==")
out("recording. press the game's HOUSE button now.")
out("")
status("recording")

-- =========================================================
-- CAPABILITIES
-- =========================================================
local CAP = {}
guard("capabilities", function()
    CAP.getrawmetatable   = getrawmetatable
    CAP.setreadonly       = setreadonly
    CAP.getnamecallmethod = getnamecallmethod
    CAP.newcclosure       = newcclosure
    CAP.hookmetamethod    = hookmetamethod
    CAP.getconnections    = getconnections
    CAP.setclipboard      = setclipboard
end)

-- =========================================================
-- SPAWN POINTS
-- =========================================================
-- The game's own name for every place it can put you. Matching where you land
-- against this list turns "I ended up at 1200, 30, -1310" into "Middle Town",
-- which is the string the teleport call itself would have used.
local function allSpawns()
    local out_ = {}
    local wo = workspace:FindFirstChild("_WorldOrigin")
    local ps = wo and wo:FindFirstChild("PlayerSpawns")
    if not ps then return out_ end
    for _, folder in ipairs(ps:GetChildren()) do
        for _, sp in ipairs(folder:GetChildren()) do
            local part = sp:IsA("BasePart") and sp
                or sp:FindFirstChildWhichIsA("BasePart", true)
            if part then
                table.insert(out_, { team = folder.Name, name = sp.Name, pos = part.Position })
            end
        end
    end
    return out_
end

local function nearestSpawn(pos)
    local best, bestD
    for _, s in ipairs(allSpawns()) do
        local d = (s.pos - pos).Magnitude
        if not bestD or d < bestD then best, bestD = s, d end
    end
    return best, bestD
end

-- =========================================================
-- CHANNEL: LIFECYCLE  (the decisive one)
-- =========================================================
-- Whether the body is replaced or kept is what separates the two possible
-- mechanisms, and both events are plain Roblox - no executor powers needed.
local recording = true
local lastRemovedAt = 0

guard("lifecycle watch", function()
    player.CharacterRemoving:Connect(function()
        if not recording then return end
        lastRemovedAt = os.clock()
        stamp("CHARACTER REMOVED   <- this teleport works by RESPAWNING you")
    end)
    player.CharacterAdded:Connect(function(char)
        if not recording then return end
        local gap = os.clock() - lastRemovedAt
        stamp(string.format("CHARACTER ADDED     (%.2fs after it was removed)", gap))
        task.spawn(function()
            local root = char:WaitForChild("HumanoidRootPart", 10)
            if not root then return end
            task.wait(0.6)
            local p = root.Position
            stamp(string.format("   landed at  %.1f, %.1f, %.1f", p.X, p.Y, p.Z))
            local s, d = nearestSpawn(p)
            if s then
                out(string.format("   nearest spawn point: \"%s\"  (team %s, %.0f studs away)",
                    s.name, s.team, d))
                out("   ^ that string is what SetLastSpawnPoint would be given")
            end
        end)
    end)
    out("lifecycle: watching (respawn vs CFrame is decided here)")
end)

-- =========================================================
-- CHANNEL: MOVEMENT
-- =========================================================
guard("movement watch", function()
    task.spawn(function()
        local last
        while gui and gui.Parent do
            local char = player.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                local p = root.Position
                if last and recording then
                    local d = (p - last).Magnitude
                    if d > 100 then
                        stamp(string.format("MOVED  %.0f studs  ->  %.1f, %.1f, %.1f",
                            d, p.X, p.Y, p.Z))
                        local s, sd = nearestSpawn(p)
                        if s then
                            out(string.format("   nearest spawn point: \"%s\" (%.0f studs)",
                                s.name, sd))
                        end
                        if os.clock() - lastRemovedAt > 3 then
                            out("   body was NOT replaced -> a plain CFrame write."
                                .. " We can copy this outright.")
                        end
                    end
                end
                last = p
            else
                last = nil
            end
            task.wait(0.12)
        end
    end)
    out("movement : watching for jumps over 100 studs")
end)

-- =========================================================
-- CHANNEL: CLICKS
-- =========================================================
-- Connecting to a button is vanilla Roblox, so this works even though the
-- handler itself cannot be read on this executor. It names the button, which
-- is what lets us find it again.
local lastClicked = nil
local watched = setmetatable({}, { __mode = "k" })

local function watchButton(b)
    if watched[b] then return end
    if gui and b:IsDescendantOf(gui) then return end
    watched[b] = true
    for _, signal in ipairs({ "Activated", "MouseButton1Click" }) do
        pcall(function()
            b[signal]:Connect(function()
                if not recording then return end
                lastClicked = b
                stamp("CLICK  " .. b:GetFullName())
                local txt = (type(b.Text) == "string" and #b.Text > 0) and b.Text or nil
                if txt then out("   text: " .. txt) end
                if b:IsA("ImageButton") and b.Image ~= "" then
                    out("   image: " .. b.Image)
                end
            end)
        end)
    end
end

guard("click watch", function()
    local pg = player:FindFirstChild("PlayerGui")
    if not pg then out("!! no PlayerGui") return end
    local n = 0
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("GuiButton") then watchButton(d) n += 1 end
    end
    pg.DescendantAdded:Connect(function(d)
        if d:IsA("GuiButton") then task.defer(watchButton, d) end
    end)
    out("clicks   : watching " .. n .. " buttons")
end)

-- =========================================================
-- HANDLERS
-- =========================================================
function H.toggle(b)
    recording = not recording
    b.Text = recording and "RECORDING" or "PAUSED"
    b.BackgroundColor3 = recording and Color3.fromRGB(48, 209, 88)
                                    or Color3.fromRGB(44, 44, 49)
    status(recording and "recording" or "paused")
end

-- The remote hook, isolated behind a button and narrated step by step.
-- v2 put this in the load path and the thread died at it with no error and no
-- further output. Now: everything else is already running before it is tried,
-- and a marker is printed BEFORE each step, so if the thread dies again the
-- last line on your clipboard names the exact step that killed it.
local hookInstalled = false
local seen = {}
local inHook = false

local TRAVELWORDS = { "travel", "teleport", "spawn", "home", "house", "island",
    "respawn", "warp", "fast", "port", "boat", "ship" }

local function looksTeleporty(s)
    local low = string.lower(tostring(s))
    for _, w in ipairs(TRAVELWORDS) do
        if string.find(low, w, 1, true) then return true end
    end
    return false
end

local function short(v)
    local t = typeof(v)
    if t == "string" then
        if #v > 70 then v = string.sub(v, 1, 70) .. "..." end
        return '"' .. v .. '"'
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "Instance" then
        return "<" .. v.ClassName .. " " .. v.Name .. ">"
    elseif t == "Vector3" then
        return string.format("Vector3(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
    elseif t == "CFrame" then
        local p = v.Position
        return string.format("CFrame(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
    elseif t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            table.insert(parts, tostring(k) .. " = "
                .. ((typeof(val) == "table") and "{...}" or short(val)))
            if #parts >= 8 then table.insert(parts, "...") break end
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return t
end

function H.hook(b)
    if hookInstalled then
        out("hook already installed")
        return
    end
    if not CAP.getnamecallmethod then
        out("cannot hook: no getnamecallmethod")
        return
    end

    local function noteCall(remote, method, ...)
        local ok, name = pcall(function() return remote:GetFullName() end)
        name = ok and name or tostring(remote)
        local parts = {}
        for i = 1, select("#", ...) do
            table.insert(parts, short((select(i, ...))))
        end
        local line = name .. ":" .. method .. "(" .. table.concat(parts, ", ") .. ")"
        if seen[line] then
            seen[line] += 1
            return
        end
        seen[line] = 1
        stamp(line .. (looksTeleporty(line) and "   <<<< TELEPORT?" or ""))
    end

    local original
    local function hooked(self, ...)
        if recording and not inHook then
            inHook = true
            local ok, method = pcall(CAP.getnamecallmethod)
            if ok and (method == "InvokeServer" or method == "FireServer") then
                pcall(noteCall, self, method, ...)
            end
            inHook = false
        end
        return original(self, ...)
    end

    out("")
    out("== INSTALLING REMOTE HOOK ==")
    out("if the output stops at one of these lines, THAT step killed it:")

    if CAP.hookmetamethod then
        out("  step 1  hookmetamethod")
        local fn = CAP.newcclosure and CAP.newcclosure(hooked) or hooked
        original = CAP.hookmetamethod(game, "__namecall", fn)
        out("  step 2  installed via hookmetamethod  OK")
        hookInstalled = true
    else
        out("  step 1  newcclosure")
        local fn = CAP.newcclosure and CAP.newcclosure(hooked) or hooked
        out("  step 2  getrawmetatable(game)")
        local mt = CAP.getrawmetatable(game)
        out("  step 3  read mt.__namecall")
        original = mt.__namecall
        out("  step 4  setreadonly(mt, false)")
        CAP.setreadonly(mt, false)
        out("  step 5  assign mt.__namecall   <- the usual killer")
        mt.__namecall = fn
        out("  step 6  setreadonly(mt, true)")
        CAP.setreadonly(mt, true)
        out("  step 7  installed via raw metatable  OK")
        hookInstalled = true
    end

    b.Text = "HOOKED"
    b.BackgroundColor3 = Color3.fromRGB(48, 209, 88)
    out("press the HOUSE button again - remotes will be listed now")
    out("")
end

function H.spawns()
    out("== SPAWN POINTS THE GAME KNOWS ==")
    local list = allSpawns()
    if #list == 0 then
        out("   _WorldOrigin.PlayerSpawns is not present or not streamed in")
        out("")
        return
    end
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local here = root and root.Position
    for _, s in ipairs(list) do
        if here then
            out(string.format("   %-8s %-24s %6.0f studs away", s.team, s.name,
                (s.pos - here).Magnitude))
        else
            out(string.format("   %-8s %s", s.team, s.name))
        end
    end
    out("")
end

function H.buttons()
    out("== BUTTONS NAMED LIKE TRAVEL ==")
    if not CAP.getconnections then
        out("   (handler code cannot be read on this executor - names only)")
    end
    local pg = player:FindFirstChild("PlayerGui")
    if not pg then out("   no PlayerGui") return end
    local hits = 0
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("GuiButton") and not (gui and d:IsDescendantOf(gui)) then
            local path = d:GetFullName()
            local txt = (type(d.Text) == "string") and d.Text or ""
            if looksTeleporty(path) or looksTeleporty(txt) then
                hits += 1
                out("   " .. path .. (txt ~= "" and ("   [" .. txt .. "]") or ""))
                if hits >= 25 then out("   ...") break end
            end
        end
    end
    if hits == 0 then
        out("   nothing matched by name - press the button while recording,")
        out("   the CLICK line names it exactly.")
    end
    out("")
end

function H.where()
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local p = root.Position
        out(string.format("position  %.1f, %.1f, %.1f", p.X, p.Y, p.Z))
        local s, d = nearestSpawn(p)
        if s then out(string.format("nearest   \"%s\" (%.0f studs)", s.name, d)) end
    else
        out("position  no character")
    end
    out("team      " .. ((player.Team and player.Team.Name) or "none"))
    out("place     " .. tostring(game.PlaceId))
    out("spawns    " .. #allSpawns() .. " known")
    out("")
end

function H.clear()
    table.clear(buf)
    table.clear(seen)
    flush()
    status("cleared - still recording")
end

function H.close()
    recording = false
    pcall(function() gui:Destroy() end)
end

guard("first look", H.where)
out("READY. press the HOUSE button in game.")
out("everything here is also on your clipboard.")
status("recording - press the house button")
