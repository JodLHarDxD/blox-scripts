--[[
    ATTACK TEST HARNESS
    ===================
    Stops the guessing. Finds the nearest enemy, then tries every plausible
    attack method one at a time, watching that enemy's Health after each.
    Whichever one drops its HP is the method the farm should use.

    HOW TO USE
      1. Equip the weapon you want to farm with.
      2. Stand near an enemy (within ~15 studs). Do NOT attack manually.
      3. Run this. It takes about 30 seconds.
      4. Read the panel / clipboard and send it back.

    It moves you next to the enemy but does not teleport you around, does not
    touch quests, and does not change your camera.
]]

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local player      = Players.LocalPlayer

-- =========================================================
-- OUTPUT
-- =========================================================
local buf, box = {}, nil
local function line(s)
    s = tostring(s)
    table.insert(buf, s)
    pcall(function() print(s) end)
    local all = table.concat(buf, "\n")
    if box then pcall(function() box.Text = all end) end
    if setclipboard then pcall(setclipboard, all) end
end

pcall(function()
    local pg = player:WaitForChild("PlayerGui", 10)
    local old = pg:FindFirstChild("AttackTest")
    if old then old:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "AttackTest"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999
    gui.Parent = pg
    local panel = Instance.new("Frame")
    panel.Size = UDim2.new(0.55, 0, 0.6, 0)
    panel.Position = UDim2.new(0.22, 0, 0.2, 0)
    panel.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
    panel.BorderSizePixel = 0
    panel.Active = true
    panel.Draggable = true
    panel.Parent = gui
    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(1, -70, 0, 24)
    t.Position = UDim2.fromOffset(8, 3)
    t.BackgroundTransparency = 1
    t.Font = Enum.Font.GothamBold
    t.TextSize = 13
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.TextColor3 = Color3.fromRGB(235, 242, 250)
    t.Text = "ATTACK TEST - copied to clipboard"
    t.Parent = panel
    local x = Instance.new("TextButton")
    x.Size = UDim2.fromOffset(58, 20)
    x.Position = UDim2.new(1, -66, 0, 4)
    x.BackgroundColor3 = Color3.fromRGB(60, 30, 34)
    x.Font = Enum.Font.GothamBold
    x.TextSize = 11
    x.TextColor3 = Color3.fromRGB(255, 200, 200)
    x.Text = "CLOSE"
    x.Parent = panel
    x.Activated:Connect(function() gui:Destroy() end)
    local sc = Instance.new("ScrollingFrame")
    sc.Size = UDim2.new(1, -12, 1, -32)
    sc.Position = UDim2.fromOffset(6, 28)
    sc.BackgroundColor3 = Color3.fromRGB(16, 19, 25)
    sc.BorderSizePixel = 0
    sc.CanvasSize = UDim2.new(0, 0, 0, 3000)
    sc.ScrollBarThickness = 8
    sc.Parent = panel
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
    box.Parent = sc
end)

line("ATTACK TEST  " .. os.date("%H:%M:%S"))

-- =========================================================
-- SETUP
-- =========================================================
local function parts()
    local c = player.Character
    if not c then return nil end
    return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end

local char, root, hum = parts()
if not root then line("!! no character") return end

-- what is equipped
local eq = char:FindFirstChildOfClass("Tool")
line("equipped: " .. (eq and eq.Name or "NONE"))
local bp = player:FindFirstChildOfClass("Backpack")
if bp then
    for _, t in ipairs(bp:GetChildren()) do
        line("  backpack: " .. t.Name .. "  WeaponType=" .. tostring(t:GetAttribute("WeaponType")))
    end
end

-- nearest enemy
local ef = workspace:FindFirstChild("Enemies")
if not ef then line("!! no Enemies folder") return end

local target, bestD = nil, math.huge
for _, m in ipairs(ef:GetChildren()) do
    if m:IsA("Model") then
        local h = m:FindFirstChildOfClass("Humanoid")
        local r = m:FindFirstChild("HumanoidRootPart")
        if h and r and h.Health > 0 then
            local d = (r.Position - root.Position).Magnitude
            if d < bestD then target, bestD = { m = m, h = h, r = r }, d end
        end
    end
end

if not target then line("!! no live enemy nearby - stand near one and re-run") return end
line(string.format("target: %s  hp=%.0f/%.0f  distance=%.0f",
    target.m.Name, target.h.Health, target.h.MaxHealth, bestD))
line("")

-- move next to it (small offset, stays in melee range)
local function reposition(heightOffset)
    local p = target.r.Position + Vector3.new(0, heightOffset, 0)
    root.CFrame = CFrame.new(p, target.r.Position)
    root.AssemblyLinearVelocity = Vector3.zero
end

-- =========================================================
-- TEST RUNNER
-- =========================================================
local results = {}

local function tryMethod(name, height, fn)
    if target.h.Health <= 0 then
        line("target already dead - stopping")
        return false
    end
    reposition(height)
    task.wait(0.3)

    local before = target.h.Health
    local ok, err = pcall(fn)
    -- swing for 2 seconds
    local deadline = os.clock() + 2
    while os.clock() < deadline do
        if not ok then break end
        pcall(fn)
        reposition(height)
        task.wait(0.12)
    end
    task.wait(0.3)
    local after = target.h.Health
    local dealt = before - after

    local verdict
    if not ok then
        verdict = "ERROR: " .. tostring(err)
    elseif dealt > 0 then
        verdict = string.format("*** DAMAGE %.0f ***", dealt)
    else
        verdict = "no damage"
    end
    line(string.format("[h=%2d] %-34s %s", height, name, verdict))
    table.insert(results, { name = name, height = height, dealt = dealt })
    return true
end

-- ---- method implementations ----
local VU = game:GetService("VirtualUser")
local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)
local cam = workspace.CurrentCamera

local function m_virtualUser()
    VU:CaptureController()
    VU:Button1Down(Vector2.new(0, 0), cam.CFrame)
    task.wait(0.05)
    VU:Button1Up(Vector2.new(0, 0), cam.CFrame)
end

local function m_virtualUserNoCapture()
    VU:Button1Down(Vector2.new(0, 0), cam.CFrame)
    task.wait(0.05)
    VU:Button1Up(Vector2.new(0, 0), cam.CFrame)
end

-- clicks at the enemy's actual position on screen
local function m_vimAtEnemy()
    if not VIM then error("VirtualInputManager unavailable") end
    local sp, onScreen = cam:WorldToViewportPoint(target.r.Position)
    if not onScreen then error("target off screen") end
    VIM:SendMouseButtonEvent(sp.X, sp.Y, 0, true, game, 1)
    task.wait(0.05)
    VIM:SendMouseButtonEvent(sp.X, sp.Y, 0, false, game, 1)
end

-- clicks at screen centre
local function m_vimCentre()
    if not VIM then error("VirtualInputManager unavailable") end
    local vs = cam.ViewportSize
    VIM:SendMouseButtonEvent(vs.X / 2, vs.Y / 2, 0, true, game, 1)
    task.wait(0.05)
    VIM:SendMouseButtonEvent(vs.X / 2, vs.Y / 2, 0, false, game, 1)
end

local function m_toolActivate()
    local t = char:FindFirstChildOfClass("Tool")
    if not t then error("no tool equipped") end
    t:Activate()
end

-- Z key, the usual first melee skill
local function m_keyZ()
    if not VIM then error("VirtualInputManager unavailable") end
    VIM:SendKeyEvent(true, Enum.KeyCode.Z, false, game)
    task.wait(0.05)
    VIM:SendKeyEvent(false, Enum.KeyCode.Z, false, game)
end

-- =========================================================
-- RUN
-- =========================================================
line("--- testing at melee height (h=4) ---")
tryMethod("VirtualUser + CaptureController", 4, m_virtualUser)
tryMethod("VirtualUser, no capture",          4, m_virtualUserNoCapture)
tryMethod("VIM click at enemy screen pos",    4, m_vimAtEnemy)
tryMethod("VIM click at screen centre",       4, m_vimCentre)
tryMethod("Tool:Activate()",                  4, m_toolActivate)
tryMethod("VIM key Z",                        4, m_keyZ)

line("")
line("--- testing at hover height (h=14) ---")
tryMethod("VirtualUser + CaptureController", 14, m_virtualUser)
tryMethod("VIM click at enemy screen pos",   14, m_vimAtEnemy)
tryMethod("VIM key Z",                       14, m_keyZ)

-- =========================================================
-- VERDICT
-- =========================================================
line("")
line("=== RESULT ===")
table.sort(results, function(a, b) return a.dealt > b.dealt end)
local best = results[1]
if best and best.dealt > 0 then
    line(string.format("WINNER: %s at height %d  (%.0f damage)", best.name, best.height, best.dealt))
    line("")
    for _, r in ipairs(results) do
        if r.dealt > 0 then
            line(string.format("  %-34s h=%2d  %.0f", r.name, r.height, r.dealt))
        end
    end
else
    line("NOTHING LANDED. Every method dealt zero damage.")
    line("Check: is the enemy still alive? are you in the same server?")
    line("Try attacking it manually right now - if that also fails, the enemy")
    line("may be out of range or protected.")
end
line("")
line("target final hp: " .. tostring(math.floor(target.h.Health)))
line("=== END ===")
