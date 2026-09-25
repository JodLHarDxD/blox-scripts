--[[
    BLOX FRUITS FARM PRO  --  GROUND
    ================================
    One thing, done plainly: loop a quest, walk to one species of enemy, stand
    at the distance you chose, and hit it until it dies.

    THE QUEST IS A LOOP, NOT A BUTTON
      take it -> kill the count the tracker asks for -> walk back to the giver
      -> take it again. Forever, on one giver and one quest, both of which you
      pick once. The only time it ever takes a DIFFERENT quest is if you
      change the target.

    WHAT IS GONE, AND WHY
      TELEPORT   it did not work, and every failure left the body hanging in
                 the air. Use the game's own travel.
      MAGNET     dragging an NPC is a client writing the CFrame of a model it
                 does not own. It was also why enemies arrived outside their
                 own area and stopped taking damage.
      HOVER      gravity cancelled every frame, collisions switched off.
      WALK SPEED the hold that wrote Humanoid.WalkSpeed every frame. Your
                 race, fruit and gear already make you fast; the farm now
                 never writes the property at all.
      WIDE HITBOX the old hook set the combat controller's hitbox to 150 studs.
                 That is the artificial range this build refuses to have: what
                 lands is what your weapon actually reaches, and DISTANCE below
                 is how you tune for it.
      BACKUPS, ROTATION, "HIT ANYTHING"
                 five flags that each quietly cancelled one of the others.
                 There is one target now. It is the one you picked.

    WHAT IS YOURS TO SET
      SPEED      swing rate and attack cooldown are sliders; walk speed is
                 the game's own and is never touched.
                 Nothing sets them behind your back and nothing is capped.
      WEAPON     the farm never changes your weapon unless you pick one. Pick
                 one and it stays picked, whatever the game tries to equip.
      DISTANCE   how far in front of you the enemy is held. A sword wants it
                 close; a fruit M1 wants a gap.
      GHOST      collisions DO go off again, but only when the character has
                 been blocked for a moment, and only until it is through.
                 On by default because you asked for it; one switch turns it
                 off (Attack -> Walk through it when stuck).

    EVERY MODE ON THE PANEL IS A SWITCH THAT READS On OR Off.

    CONTROL
        _G.BFP.start()          _G.BFP.stop()          _G.BFP.config
]]

if _G.BFP and _G.BFP.stop then pcall(_G.BFP.stop) end

local Players      = game:GetService("Players")
local RS           = game:GetService("ReplicatedStorage")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local PathService  = game:GetService("PathfindingService")
local VirtualUser  = game:GetService("VirtualUser")
local VIM          = game:GetService("VirtualInputManager")
local player       = Players.LocalPlayer

-- =========================================================
-- CONFIG
-- =========================================================
-- Every field here is independent. Nothing in this table turns anything else
-- in it off, because a setting that silently cancels another setting is the
-- reason a panel stops being trustworthy.
local CFG = {
    -- ---------- TARGET ----------
    -- Exactly one species. nil means "read it off my level".
    Target             = nil,
    MaxWalk            = 1200,   -- refuse to walk further than this unaided

    -- ---------- WEAPON ----------
    -- nil means HANDS OFF: whatever you are holding is used, and the farm
    -- never swaps it. Name one and it becomes a lock: if the game equips
    -- something else, this puts yours back, and nothing else is ever equipped.
    Weapon             = nil,

    -- ---------- AFTER A DEATH ----------
    -- A death drops the tool and turns both haki off. Enhancement (J) is
    -- re-asserted whenever the character is missing it. Observation (E) is
    -- checked after every death AND every KenEvery seconds, and E is pressed
    -- only when the dodge counter is gone. See keepHaki.
    AutoBuso           = true,
    AutoKen            = true,
    KenEvery           = 300,    -- seconds between Observation checks (5 min)

    -- ---------- ATTACK ----------
    -- Independent switches, not a mode. M1 alone is enough for most weapons.
    M1                 = true,
    SkillZ             = false,
    SkillX             = false,
    SkillC             = false,
    SkillV             = false,
    SkillEvery         = 4,      -- with M1 on, a skill every Nth swing

    -- ---------- SPEED, ALL YOURS ----------
    -- Nothing here is set for you and nothing is capped. The two swing-gap
    -- numbers are a RANGE: each gap is drawn between them, so the rhythm is
    -- not identical every single time. Put them on the same number for a flat
    -- fixed rate.
    SwingMin           = 0.12,
    SwingMax           = 0.30,
    -- The game's own attack cooldown. Off, your weapon's normal cooldown
    -- applies. On, the combat controller is told it is ready again every
    -- AttackSpeed seconds -- YOUR number, not negative infinity. The hitbox is
    -- never touched by this.
    FastAttack         = false,
    AttackSpeed        = 0.35,
    -- DASH. Blox Fruits binds it to Q, and a player leans on it constantly:
    -- into a target, out of a hit, and above all BETWEEN targets. Walking the
    -- gap is most of why the farm was slower than you are.
    -- OFF by default, because it was broken and you were right to keep it off.
    -- What was wrong is fixed below; turn it on when you want to test it.
    Dash               = false,
    -- Only dash when the gap is BIGGER than a dash covers. Set this too small
    -- and every dash overshoots the enemy and then has to walk back, which is
    -- half of what "it goes to the enemy and comes back" was.
    DashFrom           = 25,
    DashCooldown       = 0.9,    -- your number; the game has its own floor too
    DashKey            = "Q",
    -- WHY IT NEVER DASHED, AND WHAT THE DASH ACTUALLY FOLLOWS.
    -- With no WASD held the game dashes "forward", and forward is the CAMERA,
    -- not the body. The body is pinned at the target by FaceLock; the camera
    -- is yours and points wherever you last left it. The build before this
    -- refused to dash unless your camera happened to agree, and while the
    -- character runs around a camp your camera never turns with it, so the
    -- dash almost never fired. Lowering the distance changed nothing because
    -- distance was never the gate.
    --
    -- On: the camera's yaw is turned at the target for the press. Pitch and
    -- zoom are left alone and your mouse is free again the same frame, so the
    -- dash lands where the walk is going. Off: dash only when your camera
    -- already agrees -- view untouched, dashes rare.
    DashTurnsCamera    = true,

    -- ---------- DISTANCE ----------
    -- The only range in the script.
    --   sword / melee     : close, 5-8
    --   fruit M1 whose hitbox starts out from the body : 12-18
    StandOff           = 8,
    StandSlack         = 2,      -- drift allowed before it corrects
    -- KEEP THE M1 GOING WHILE IT COMES BACK.
    -- A swing or a skill throws the enemy away and it walks straight back at
    -- you. Its attack reach and your swing reach are about the same, so if
    -- the M1 only starts once it is inside reach, it is a race at the
    -- boundary -- and when the NPC wins it, its hit stuns you and it chains.
    -- From this many studs out the M1 is kept running while you close, so it
    -- walks into hits already in the air and is stunned before it can swing.
    -- At or below the swing reach this does nothing extra.
    SwingFrom          = 30,
    -- FACING. A melee M1 -- a sword, or a fighting style like Sanguine Art --
    -- swings where the BODY points, so the body is pinned at the target and
    -- re-pinned every pass. This is what makes hits land; without it the
    -- character drifts off-axis between swings and the arc misses.
    FaceLock           = true,
    -- AIMING THE CAMERA IS A SEPARATE, HEAVIER THING, AND IT IS NOW OFF.
    -- It takes the camera (Scriptable, so your mouse look is dead) and parks
    -- your cursor at the centre of the screen. That is only worth paying for
    -- fruit skills, which are cast down the cursor's ray. For melee it buys
    -- nothing and costs you the view and control of your own mouse.
    AimCamera          = false,
    CamBack            = 13,
    CamUp              = 5,

    -- ---------- QUEST LOOP ----------
    QuestLoop          = true,
    -- WHO HAS TO WALK.
    --   "auto"   : walk if the giver is NEAR, ask from range if it is far.
    --   "always" : walk to the giver every cycle, whatever it costs.
    --   "never"  : never walk. Ask from range and take what you get.
    -- The question is not whether the walk is possible, it is whether it is
    -- worth it, and that is a distance: the Demonic Soul giver stands right
    -- beside them and costs nothing, the Posessed Mummies are a long path
    -- underground from theirs. One radius separates those two cases without
    -- being told which island you are on.
    GiverMode          = "auto",
    GiverWalkRadius    = 250,    -- auto walks only when the giver is this close
    QuestReturnToFarm  = true,
    QuestGiverName     = nil,    -- exact NPC name; blank = use the table
    QuestName          = nil,    -- exact server quest id; blank = look it up
    QuestTier          = nil,    -- 1..3; blank = work it out and remember it
    QuestGiverRange    = 1200,
    QuestRetrySeconds  = 8,
    QuestStallSeconds  = 240,
    QuestKillsFallback = 10,

    -- ---------- SAFETY ----------
    MinHealthPercent   = 0.30,
    RegenWait          = 6,
    -- PAUSE AFTER A KILL. Zero, and deliberately so: a second of standing
    -- still per kill is a second nobody playing would ever spend, and over a
    -- respawn cycle it is the difference between clearing a camp and clearing
    -- half of it. The sliders are still there if you ever want it back.
    RestMin            = 0,
    RestMax            = 0,
    -- How long one uninterrupted sweep runs before the loop checks the quest
    -- again. It is not a limit on kills -- it chains targets the whole time.
    SweepSeconds       = 10,
    StuckSeconds       = 30,
    -- WHEN TO GIVE UP ON ONE ENEMY.
    -- This used to be a wall clock: 45 seconds on a target and it was parked
    -- regardless. With a slower weapon a perfectly healthy fight simply ran
    -- out of time and got abandoned half-killed. It is now measured from the
    -- last time its HEALTH DROPPED, so a fight that is being won never
    -- expires, however long it takes, and one that is not moving at all is
    -- parked quickly.
    GiveUpSeconds      = 12,

    -- ---------- GATHER ----------
    -- THE MAGNET, DONE BY THE ENEMIES' OWN LEGS.
    -- When nobody is in reach, instead of walking to the nearest one and
    -- killing it alone, tag a few with one M1 each on the way through. Each
    -- one tagged chases you, so they arrive in a pile and every swing lands
    -- on several. The server's own AI does the moving, so there is nothing
    -- for it to measure -- unlike a magnet (client writing NPC positions) or
    -- fast travel (your character moving faster than it can).
    Gather             = true,
    GatherCount        = 3,      -- tag up to this many per pile
    GatherRadius       = 60,     -- only ones within this many studs
    GatherCooldown     = 6,      -- seconds between gathers
    JumpWhenStuck      = true,
    -- STUCK IS A CRISIS, AND A CRISIS GETS BIG ACTIONS.
    -- Target above: stand still, ground jump, stack every air jump straight
    -- up, dash forward off the top. Target on our level: two dashes to the
    -- open side, then forward. Each burst is checked for real progress and
    -- the next is the other kind or the other side. Four bursts hand over to
    -- pathfinding. Off: pathfinding only.
    Panic              = true,
    -- AIR JUMPS PER CLIMB, stacked straight up with no movement held (they go
    -- where you are moving; moving forward wastes them into the wall).
    ClimbJumps         = 6,
    -- If the Space key is ignored in the air (no upward kick within a tenth
    -- of a second), ask the engine for the jump directly. Off: Space only.
    ForceAirJump       = true,
    -- GHOST: WHEN ROUND HAS FAILED, THROUGH.
    -- Asked to move and gaining no ground for GhostAfter seconds, whatever
    -- is walking the character (fight, walk to the camp, walk to the giver,
    -- gather), and its collisions go off until it is out the other side of
    -- the trunk or wall. If where it is going is higher, it is also lifted.
    -- In a fight with Panic on, one legal burst is tried first.
    -- READ THE GROUND FIRST. On reaching a camp its ground is read once --
    -- heights, walls, trunks, low logs -- and every approach is planned on
    -- that map: round what cannot be jumped, over what can, jump pressed
    -- before the edge. Re-planned from memory as enemies move. Off: straight
    -- runs with the stuck recovery, as before.
    TerrainMap         = true,
    Ghost              = true,
    GhostAfter         = 1.5,    -- seconds blocked before going through
    GhostLiftMax       = 30,     -- highest lift, in studs
    Debug              = false,
}

local P = { running = false, config = CFG }
_G.BFP = P

-- =========================================================
-- LEVEL -> ENEMY -> WHERE IT LIVES
-- =========================================================
-- Rebuilt 2026-09-14 from the published level tables, cross-read against the
-- wiki. The rows that were here before had Third Sea enemies filed at Second
-- Sea levels, so "by my level" resolved to a species that does not live where
-- it then sent you.
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

    -- SECOND SEA
    {700,724,"Raider",Vector3.new(68.9,93.6,2429.7)},
    {725,774,"Mercenary",Vector3.new(-864.9,122.5,1453.2)},
    {775,799,"Swan Pirate",Vector3.new(1065.4,137.6,1324.4)},
    {800,874,"Factory Staff",Vector3.new(533.2,128.5,355.6)},
    {875,899,"Marine Lieutenant",Vector3.new(-2489.3,84.6,-3151.9)},
    {900,949,"Marine Captain",Vector3.new(-2335.2,79.8,-3245.9)},
    {950,974,"Zombie",Vector3.new(-5536.5,101.1,-835.6)},
    {975,999,"Vampire",Vector3.new(-5806.1,16.7,-1164.4)},
    {1000,1049,"Snow Trooper",Vector3.new(535.2,432.7,-5484.9)},
    {1050,1099,"Winter Warrior",Vector3.new(1234.5,457.0,-5174.1)},
    {1100,1124,"Lab Subordinate",Vector3.new(-5720.6,63.3,-4784.6)},
    {1125,1174,"Horned Warrior",Vector3.new(-6292.8,91.2,-5502.7)},
    {1175,1199,"Magma Ninja",Vector3.new(-5461.8,130.4,-5836.5)},
    {1200,1249,"Lava Pirate",Vector3.new(-5251.2,55.2,-4774.4)},
    {1250,1274,"Ship Deckhand",Vector3.new(921.1,126.0,33088.3)},
    {1275,1299,"Ship Engineer",Vector3.new(886.3,40.5,32800.8)},
    {1300,1324,"Ship Steward",Vector3.new(943.9,129.6,33444.4)},
    {1325,1349,"Ship Officer",Vector3.new(955.4,181.1,33331.9)},
    {1350,1374,"Arctic Warrior",Vector3.new(5935.5,77.3,-6472.8)},
    {1375,1424,"Snow Lurker",Vector3.new(5628.5,57.6,-6618.4)},
    {1425,1449,"Sea Soldier",Vector3.new(-3185.0,58.8,-9663.6)},
    {1450,1499,"Water Fighter",Vector3.new(-3262.9,298.7,-10552.5)},

    -- THIRD SEA
    {1500,1524,"Pirate Millionaire",Vector3.new(81.2,43.8,5724.7)},
    {1525,1574,"Pistol Billionaire",Vector3.new(81.2,43.8,5724.7)},
    {1575,1599,"Dragon Crew Warrior",Vector3.new(6242.0,51.5,-1244.0)},
    {1600,1624,"Dragon Crew Archer",Vector3.new(6488.9,383.4,-110.7)},
    {1625,1649,"Female Islander",Vector3.new(5825.2,682.9,704.6)},
    {1650,1699,"Giant Islander",Vector3.new(4530.4,656.8,-131.6)},
    {1700,1724,"Marine Commodore",Vector3.new(2490.1,190.4,-7160.1)},
    {1725,1774,"Marine Rear Admiral",Vector3.new(3951.4,229.1,-6912.8)},
    {1775,1799,"Fishman Raider",Vector3.new(-10322.4,390.9,-8580.1)},
    {1800,1824,"Fishman Captain",Vector3.new(-11194.5,442.0,-8608.8)},
    {1825,1849,"Forest Pirate",Vector3.new(-13225.8,428.2,-7753.1)},
    {1850,1899,"Mythological Pirate",Vector3.new(-13869.2,565.0,-7084.4)},
    {1900,1924,"Jungle Pirate",Vector3.new(-11982.2,376.3,-10451.4)},
    {1925,1974,"Musketeer Pirate",Vector3.new(-13282.3,496.2,-9565.2)},
    {1975,1999,"Reborn Skeleton",Vector3.new(-8817.9,191.2,6298.7)},
    {2000,2024,"Living Zombie",Vector3.new(-10125.2,184.0,6242.0)},
    {2025,2049,"Demonic Soul",Vector3.new(-9712.0,204.7,6193.3)},
    {2050,2074,"Posessed Mummy",Vector3.new(-9545.8,69.6,6339.6)},
    {2075,2099,"Peanut Scout",Vector3.new(-2126.4,90.6,-10302.0)},
    {2100,2124,"Peanut President",Vector3.new(-2118.8,70.3,-10509.3)},
    {2125,2149,"Ice Cream Chef",Vector3.new(-685.3,96.3,-10957.6)},
    {2150,2199,"Ice Cream Commander",Vector3.new(-635.7,143.0,-11335.2)},
    {2200,2224,"Cookie Crafter",Vector3.new(-2321.7,36.7,-12216.7)},
    {2225,2249,"Cake Guard",Vector3.new(-1418.1,36.7,-12255.7)},
    {2250,2274,"Baking Staff",Vector3.new(-1980.4,36.7,-12983.8)},
    {2275,2299,"Head Baker",Vector3.new(-2251.6,52.3,-13033.4)},
    {2300,2324,"Cocoa Warrior",Vector3.new(168.0,26.2,-12238.9)},
    {2325,2349,"Chocolate Bar Battler",Vector3.new(701.3,25.6,-12708.2)},
    {2350,2374,"Sweet Thief",Vector3.new(-140.3,25.6,-12652.3)},
    {2375,2399,"Candy Rebel",Vector3.new(47.9,25.6,-13029.2)},
    {2400,2424,"Candy Pirate",Vector3.new(-1437.6,17.1,-14385.7)},
    {2425,2449,"Snow Demon",Vector3.new(-916.2,17.1,-14638.8)},
    {2450,2474,"Isle Outlaw",Vector3.new(-16162.8,11.7,-96.5)},
    {2475,2499,"Island Boy",Vector3.new(-16357.3,20.6,1005.6)},
    {2500,2524,"Sun-kissed Warrior",Vector3.new(-16357.3,20.6,1005.6)},
    {2525,2549,"Isle Champion",Vector3.new(-16848.9,21.7,1041.4)},
    {2550,2574,"Serpent Hunter",Vector3.new(-16621.4,121.4,1290.7)},
    {2575,2600,"Skull Slayer",Vector3.new(-16811.6,84.6,1542.2)},
}
P.levels = LEVELS

-- =========================================================
-- QUEST TABLES
-- =========================================================
-- The server's own quest ids, not the titles the dialog shows.
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
    -- MEASURED: MarineQuest tier 1 handed back "Defeat 5 Trainees", so the
    -- Trainee is tier 1 and the Officer is tier 2.
    ["Trainee"]               = { "MarineQuest", 1 },
    ["Chief Petty Officer"]   = { "MarineQuest", 2 },
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
    ["Marine Lieutenant"]     = { "MarineQuest3", 1 },
    ["Marine Captain"]        = { "MarineQuest3", 2 },
    ["Zombie"]                = { "ZombieQuest", 1 },
    ["Vampire"]               = { "ZombieQuest", 2 },
    ["Snow Trooper"]          = { "SnowMountainQuest", 1 },
    ["Winter Warrior"]        = { "SnowMountainQuest", 2 },
    ["Lab Subordinate"]       = { "IceSideQuest", 1 },
    ["Horned Warrior"]        = { "IceSideQuest", 2 },
    ["Magma Ninja"]           = { "FireSideQuest", 1 },
    ["Lava Pirate"]           = { "FireSideQuest", 2 },
    ["Ship Deckhand"]         = { "ShipQuest1", 1 },
    ["Ship Engineer"]         = { "ShipQuest1", 2 },
    ["Ship Steward"]          = { "ShipQuest2", 1 },
    ["Ship Officer"]          = { "ShipQuest2", 2 },
    ["Arctic Warrior"]        = { "FrostQuest", 1 },
    ["Snow Lurker"]           = { "FrostQuest", 2 },
    ["Sea Soldier"]           = { "ForgottenQuest", 1 },
    ["Water Fighter"]         = { "ForgottenQuest", 2 },

    -- THIRD SEA
    ["Pirate Millionaire"]    = { "PiratePortQuest", 1 },
    ["Pistol Billionaire"]    = { "PiratePortQuest", 2 },
    ["Dragon Crew Warrior"]   = { "AmazonQuest", 1 },
    ["Dragon Crew Archer"]    = { "AmazonQuest", 2 },
    ["Female Islander"]       = { "AmazonQuest2", 1 },
    ["Giant Islander"]        = { "AmazonQuest2", 2 },
    ["Marine Commodore"]      = { "MarineTreeIsland", 1 },
    ["Marine Rear Admiral"]   = { "MarineTreeIsland", 2 },
    ["Fishman Raider"]        = { "DeepForestIsland3", 1 },
    ["Fishman Captain"]       = { "DeepForestIsland3", 2 },
    ["Forest Pirate"]         = { "DeepForestIsland", 1 },
    ["Mythological Pirate"]   = { "DeepForestIsland", 2 },
    ["Jungle Pirate"]         = { "DeepForestIsland2", 1 },
    ["Musketeer Pirate"]      = { "DeepForestIsland2", 2 },
    -- HAUNTED CASTLE. Giver 1 is in the grey hut in the middle of the grounds,
    -- giver 2 stands at the castle's front door among the Demonic Souls.
    ["Reborn Skeleton"]       = { "HauntedQuest1", 1 },
    ["Living Zombie"]         = { "HauntedQuest1", 2 },
    ["Demonic Soul"]          = { "HauntedQuest2", 1 },
    ["Posessed Mummy"]        = { "HauntedQuest2", 2 },
    ["Peanut Scout"]          = { "NutsIslandQuest", 1 },
    ["Peanut President"]      = { "NutsIslandQuest", 2 },
    ["Ice Cream Chef"]        = { "IceCreamIslandQuest", 1 },
    ["Ice Cream Commander"]   = { "IceCreamIslandQuest", 2 },
    ["Cookie Crafter"]        = { "CakeQuest1", 1 },
    ["Cake Guard"]            = { "CakeQuest1", 2 },
    ["Baking Staff"]          = { "CakeQuest2", 1 },
    ["Head Baker"]            = { "CakeQuest2", 2 },
    ["Cocoa Warrior"]         = { "ChocQuest1", 1 },
    ["Chocolate Bar Battler"] = { "ChocQuest1", 2 },
    ["Sweet Thief"]           = { "ChocQuest2", 1 },
    ["Candy Rebel"]           = { "ChocQuest2", 2 },
    ["Candy Pirate"]          = { "CandyQuest1", 1 },
    ["Snow Demon"]            = { "CandyQuest1", 2 },
    ["Isle Outlaw"]           = { "TikiQuest1", 1 },
    ["Island Boy"]            = { "TikiQuest1", 2 },
    ["Sun-kissed Warrior"]    = { "TikiQuest2", 1 },
    ["Isle Champion"]         = { "TikiQuest2", 2 },
    ["Serpent Hunter"]        = { "TikiQuest3", 1 },
    ["Skull Slayer"]          = { "TikiQuest3", 2 },
}
P.quests = QUESTS

-- The giver's NAME is a hint. The giver's POSITION is the thing that works:
-- the server refuses StartQuest unless you are standing near it, and a
-- coordinate cannot be misspelled or fail to stream in.
local GIVER_POS = {
    ["Raider"]                = Vector3.new(-427.7, 73.0, 1835.9),
    ["Mercenary"]             = Vector3.new(-427.7, 73.0, 1835.9),
    ["Swan Pirate"]           = Vector3.new(635.6, 73.1, 917.8),
    ["Factory Staff"]         = Vector3.new(635.6, 73.1, 917.8),
    ["Marine Lieutenant"]     = Vector3.new(-2441.0, 73.0, -3217.7),
    ["Marine Captain"]        = Vector3.new(-2441.0, 73.0, -3217.7),
    ["Zombie"]                = Vector3.new(-5494.3, 48.5, -794.6),
    ["Vampire"]               = Vector3.new(-5494.3, 48.5, -794.6),
    ["Snow Trooper"]          = Vector3.new(607.1, 401.5, -5370.6),
    ["Winter Warrior"]        = Vector3.new(607.1, 401.5, -5370.6),
    ["Lab Subordinate"]       = Vector3.new(-6061.8, 15.9, -4902.0),
    ["Horned Warrior"]        = Vector3.new(-6061.8, 15.9, -4902.0),
    ["Magma Ninja"]           = Vector3.new(-5429.1, 16.0, -5298.0),
    ["Lava Pirate"]           = Vector3.new(-5429.1, 16.0, -5298.0),
    ["Ship Deckhand"]         = Vector3.new(1040.3, 125.1, 32911.0),
    ["Ship Engineer"]         = Vector3.new(1040.3, 125.1, 32911.0),
    ["Ship Steward"]          = Vector3.new(971.4, 125.1, 33245.5),
    ["Ship Officer"]          = Vector3.new(971.4, 125.1, 33245.5),
    ["Arctic Warrior"]        = Vector3.new(5668.1, 28.2, -6484.6),
    ["Snow Lurker"]           = Vector3.new(5668.1, 28.2, -6484.6),
    ["Sea Soldier"]           = Vector3.new(-3054.6, 236.9, -10147.8),
    ["Water Fighter"]         = Vector3.new(-3054.6, 236.9, -10147.8),

    ["Pirate Millionaire"]    = Vector3.new(-290.1, 42.9, 5581.6),
    ["Pistol Billionaire"]    = Vector3.new(-290.1, 42.9, 5581.6),
    ["Dragon Crew Warrior"]   = Vector3.new(5832.8, 51.7, -1101.5),
    ["Dragon Crew Archer"]    = Vector3.new(5832.8, 51.7, -1101.5),
    ["Female Islander"]       = Vector3.new(5448.9, 601.5, 751.1),
    ["Giant Islander"]        = Vector3.new(5448.9, 601.5, 751.1),
    ["Marine Commodore"]      = Vector3.new(2180.5, 27.8, -6741.6),
    ["Marine Rear Admiral"]   = Vector3.new(2180.5, 27.8, -6741.6),
    ["Fishman Raider"]        = Vector3.new(-10581.7, 330.9, -8761.2),
    ["Fishman Captain"]       = Vector3.new(-10581.7, 330.9, -8761.2),
    ["Forest Pirate"]         = Vector3.new(-13234.0, 331.5, -7625.4),
    ["Mythological Pirate"]   = Vector3.new(-13234.0, 331.5, -7625.4),
    ["Jungle Pirate"]         = Vector3.new(-12680.4, 390.0, -9902.0),
    ["Musketeer Pirate"]      = Vector3.new(-12680.4, 390.0, -9902.0),
    ["Reborn Skeleton"]       = Vector3.new(-9480.8, 142.1, 5566.1),
    ["Living Zombie"]         = Vector3.new(-9480.8, 142.1, 5566.1),
    ["Demonic Soul"]          = Vector3.new(-9517.0, 178.0, 6078.5),
    ["Posessed Mummy"]        = Vector3.new(-9517.0, 178.0, 6078.5),
    ["Peanut Scout"]          = Vector3.new(-2104.4, 38.1, -10194.1),
    ["Peanut President"]      = Vector3.new(-2104.4, 38.1, -10194.1),
    ["Ice Cream Chef"]        = Vector3.new(-820.2, 65.8, -10966.2),
    ["Ice Cream Commander"]   = Vector3.new(-820.2, 65.8, -10966.2),
    ["Cookie Crafter"]        = Vector3.new(-2022.3, 36.9, -12030.9),
    ["Cake Guard"]            = Vector3.new(-2022.3, 36.9, -12030.9),
    ["Baking Staff"]          = Vector3.new(-1928.3, 37.7, -12840.6),
    ["Head Baker"]            = Vector3.new(-1928.3, 37.7, -12840.6),
    ["Cocoa Warrior"]         = Vector3.new(231.8, 23.9, -12200.3),
    ["Chocolate Bar Battler"] = Vector3.new(231.8, 23.9, -12200.3),
    ["Sweet Thief"]           = Vector3.new(151.2, 23.9, -12774.6),
    ["Candy Rebel"]           = Vector3.new(151.2, 23.9, -12774.6),
    ["Candy Pirate"]          = Vector3.new(-1149.3, 13.6, -14445.6),
    ["Snow Demon"]            = Vector3.new(-1149.3, 13.6, -14445.6),
    ["Isle Outlaw"]           = Vector3.new(-16549.9, 55.7, -179.9),
    ["Island Boy"]            = Vector3.new(-16549.9, 55.7, -179.9),
    ["Sun-kissed Warrior"]    = Vector3.new(-16541.0, 54.8, 1051.5),
    ["Isle Champion"]         = Vector3.new(-16541.0, 54.8, 1051.5),
    ["Serpent Hunter"]        = Vector3.new(-16665.2, 104.6, 1579.7),
    ["Skull Slayer"]          = Vector3.new(-16665.2, 104.6, 1579.7),
}
P.giverPositions = GIVER_POS

local GIVER_NAMES = {
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
    ["Prisoner"]              = "Jail Keeper",
    ["Dangerous Prisoner"]    = "Jail Keeper",
    ["Toga Warrior"]          = "Colosseum Quest Giver",
    ["Gladiator"]             = "Colosseum Quest Giver",
    ["God's Guard"]           = "Sky Quest Giver 2",
    ["Shanda"]                = "Sky Quest Giver 2",
    ["Royal Squad"]           = "Mole",
    ["Royal Soldier"]         = "Mole",
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
    ["Pirate Millionaire"]    = "Port Town Quest Giver",
    ["Pistol Billionaire"]    = "Port Town Quest Giver",
    ["Dragon Crew Warrior"]   = "Hydra Town Quest Giver",
    ["Dragon Crew Archer"]    = "Hydra Town Quest Giver",
    ["Female Islander"]       = "Hydra Island Quest Giver",
    ["Giant Islander"]        = "Hydra Island Quest Giver",
    ["Marine Commodore"]      = "Marine Tree Quest Giver",
    ["Marine Rear Admiral"]   = "Marine Tree Quest Giver",
    ["Fishman Raider"]        = "Deep Forest Quest Giver 3",
    ["Fishman Captain"]       = "Deep Forest Quest Giver 3",
    ["Forest Pirate"]         = "Deep Forest Quest Giver",
    ["Mythological Pirate"]   = "Deep Forest Quest Giver",
    ["Jungle Pirate"]         = "Deep Forest Quest Giver 2",
    ["Musketeer Pirate"]      = "Deep Forest Quest Giver 2",
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
    ["Snow Demon"]            = "Candy Cane Quest Giver",
    ["Isle Outlaw"]           = "Tiki Quest Giver 1",
    ["Island Boy"]            = "Tiki Quest Giver 1",
    ["Sun-kissed Warrior"]    = "Tiki Quest Giver 2",
    ["Isle Champion"]         = "Tiki Quest Giver 2",
    ["Serpent Hunter"]        = "Tiki Quest Giver 3",
    ["Skull Slayer"]          = "Tiki Quest Giver 3",
}
P.giverNames = GIVER_NAMES

-- Every name the wiki lists as a farm-quest giver, island not attached. Being
-- on this list is a strong signal on its own, so the nearby scan works even
-- where the enemy mapping above is wrong.
local KNOWN_GIVERS = {}
for _, n in ipairs({
    "Bandit Quest Giver", "Adventurer", "Pirate Adventurer", "Desert Adventurer",
    "Villager", "Marine", "Marine Leader", "Colosseum Quest Giver",
    "Sky Adventurer", "Sky Quest Giver 2", "Mole", "Head Jailer", "Jail Keeper",
    "Freezeburg Quest Giver", "Submerged Quest Giver 1", "Submerged Quest Giver 2",
    "Area 1 Quest Giver", "Area 2 Quest Giver", "Marine Quest Giver",
    "Graveyard Quest Giver", "Snow Quest Giver", "Ice Quest Giver",
    "Fire Quest Giver", "Forgotten Quest Giver", "Front Crew Quest Giver",
    "Rear Crew Quest Giver", "Frost Quest Giver",
    "Port Town Quest Giver", "Pirate Port Quest Giver", "Hydra Town Quest Giver",
    "Hydra Island Quest Giver", "Dragon Crew Quest Giver",
    "Marine Tree Quest Giver", "Turtle Adventure Quest Giver",
    "Deep Forest Quest Giver", "Deep Forest Quest Giver 2",
    "Deep Forest Quest Giver 3", "Haunted Castle Quest Giver 1",
    "Haunted Castle Quest Giver 2", "Cake Quest Giver 1", "Cake Quest Giver 2",
    "Chocolate Quest Giver 1", "Chocolate Quest Giver 2", "Ice Cream Quest Giver",
    "Peanut Quest Giver", "Candy Cane Quest Giver", "Submerged Quest Giver 3",
    "Tiki Quest Giver 1", "Tiki Quest Giver 2", "Tiki Quest Giver 3",
}) do KNOWN_GIVERS[string.lower(n)] = n end
P.knownGivers = KNOWN_GIVERS

-- =========================================================
-- STATE
-- =========================================================
local stats = {
    kills = 0, swings = 0, damaging = 0, quests = 0,
    escalations = 0, retreats = 0, walks = 0, dashes = 0, startedAt = 0,
    switches = 0, hops = 0, airJumps = 0, forcedJumps = 0,
    panics = 0, panicDashes = 0, detours = 0, hakiPresses = 0,
    gathers = 0, tagged = 0, ghosts = 0, lifts = 0, ghostFalls = 0,
    navMaps = 0, navPlans = 0, navJumps = 0, navLearned = 0,
}

local state          = "IDLE"
local statusLine     = "idle"
local stateEnteredAt = 0
local lastProgressAt = 0
local escalation     = 0
local blacklist      = {}
local countedDead    = {}
local conns          = {}
local moveEnabled    = true

local activeName     = nil     -- the ONE species being farmed
local farmSpot       = nil     -- where that species lives
-- The one currently being hit. It only outranks "nearest" while it is inside
-- swing range: a target you are landing hits on is not dropped for one that
-- happens to be a stud closer. Once it is out of reach it competes on
-- distance like everything else.
local engagedModel   = nil
-- While the clock is under this, the approach paths round obstacles instead
-- of walking straight. Set by the sweep when it finds itself stuck.
local pathUntil      = 0
local lastJumpAt     = 0       -- any jump, for spacing and for holding the dash

P.learnedGivers = {}
P.learnedQuests = {}
P.giverSpots    = {}
P.lockedQuest   = nil

-- THE ABORT EPOCH.
-- STOP used to be advisory. acceptQuest walks to the giver, accepts, and walks
-- back, and none of that checked P.running -- so pressing Stop mid-quest let
-- the whole thing run to completion and fire StartQuest anyway. moveEnabled
-- made it worse: stop set it false and put it back true 0.3s later so the
-- manual buttons would still work, which meant an in-flight walk simply
-- resumed. Every long operation now captures this number on entry and gives up
-- the moment it changes. Stop bumps it, so stop means stop.
local epoch = 0
local function stale(e) return e ~= epoch end

local function track(c) table.insert(conns, c) return c end
local function log(m) if CFG.Debug then print("[BFP] " .. tostring(m)) end end
local function say(s) statusLine = tostring(s) end

local function setState(s)
    if state ~= s then
        state = s
        stateEnteredAt = os.clock()
        log("state -> " .. s)
    end
end

local function progress()
    lastProgressAt = os.clock()
    escalation = 0
end

local function jitter(lo, hi)
    if hi <= lo then return lo end
    return lo + math.random() * (hi - lo)
end

-- =========================================================
-- CHARACTER
-- =========================================================
local function parts()
    local char = player.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return char, nil, nil end
    return char, root, hum
end

local function healthPct()
    local _, _, hum = parts()
    if not hum or hum.MaxHealth <= 0 then return 1 end
    return hum.Health / hum.MaxHealth
end

local function playerLevel()
    local ls = player:FindFirstChild("leaderstats")
    local lv = ls and ls:FindFirstChild("Level")
    if lv and tonumber(lv.Value) then return tonumber(lv.Value) end
    local d = player:FindFirstChild("Data")
    local l2 = d and d:FindFirstChild("Level")
    return l2 and tonumber(l2.Value) or nil
end

-- =========================================================
-- WEAPON
-- =========================================================
-- The farm does NOT choose your weapon. The automatic choice never did
-- anything useful except swap the sword you wanted out for a fruit you did
-- not, usually mid-fight. No name set means hands off entirely.
local function toolNames()
    local out, seen = {}, {}
    local bp = player:FindFirstChild("Backpack")
    for _, src in ipairs({ bp, player.Character }) do
        if src then
            for _, t in ipairs(src:GetChildren()) do
                if t:IsA("Tool") and not seen[t.Name] then
                    seen[t.Name] = true
                    table.insert(out, t.Name)
                end
            end
        end
    end
    table.sort(out)
    return out
end
P.tools = toolNames

local function heldTool()
    local char = player.Character
    return char and char:FindFirstChildOfClass("Tool")
end
P.heldTool = function()
    local t = heldTool()
    return t and t.Name or nil
end

-- Put the locked weapon back if it is not in hand.
local lastHeld = nil      -- what was in hand last, so a respawn can get it back
local function keepWeapon()
    local want = CFG.Weapon
    if not want or want == "" then
        local t = heldTool()
        if t then lastHeld = t.Name; P.lastHeld = lastHeld end
        return t and t.Name or nil
    end
    local t = heldTool()
    if t and t.Name == want then return want end

    local char = player.Character
    local bp   = player:FindFirstChild("Backpack")
    local tool = (bp and bp:FindFirstChild(want)) or (char and char:FindFirstChild(want))
    if tool and tool:IsA("Tool") then
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then pcall(function() hum:EquipTool(tool) end) end
        return want
    end
    return t and t.Name or nil
end

-- =========================================================
-- ATTACK SPEED
-- =========================================================
-- The game's own attack cooldown lives on the combat controller. This reaches
-- into it and clears the "next attack at" stamp, which is what lets a swing
-- land sooner than the weapon's animation would allow.
--
-- TWO DELIBERATE DIFFERENCES from the version this replaces:
--   * it clears the stamp once every AttackSpeed seconds -- YOUR number --
--     instead of pinning it at negative infinity forever. You set the rate.
--   * it does not touch hitboxMagnitude. The old one set it to 150 studs,
--     which is the artificial range this build refuses to have. What lands is
--     what your weapon reaches; use DISTANCE to tune for that.
-- If the executor has no getreg/getupvalues this cannot install, and the panel
-- says so rather than pretending it is on.
local fastConn, ctrlRef = nil, nil
local lastCleared = 0
P.fastOK = false

local function installFastAttack()
    if fastConn then pcall(function() fastConn:Disconnect() end) fastConn = nil end
    ctrlRef, P.fastOK = nil, false

    local env     = (getgenv and getgenv()) or {}
    local getreg_ = getreg or env.getreg
    local getupv  = (debug and debug.getupvalues) or env.getupvalues
    if not getreg_ or not getupv then
        P.fastNote = "not available: this executor has no getreg/getupvalues"
        return false
    end

    local scripts = player:FindFirstChild("PlayerScripts")
    local combatScript = scripts and scripts:FindFirstChild("CombatFramework")
    if not combatScript then
        P.fastNote = "not available: CombatFramework missing"
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
        P.fastNote = "not available: activeController not found"
        return false
    end

    ctrlRef  = found
    P.fastOK = true
    P.fastNote = "installed"
    fastConn = track(RunService.RenderStepped:Connect(function()
        if not CFG.FastAttack then return end
        local gap = math.max(CFG.AttackSpeed or 0.35, 0.05)
        if os.clock() - lastCleared < gap then return end
        lastCleared = os.clock()
        pcall(function()
            local ac = ctrlRef.activeController
            if not ac then return end
            ac.timeToNextAttack   = 0
            ac.attacking          = false
            ac.blocking           = false
            ac.focusStart         = 0
            ac.currentAttackTrack = 0
            -- hitboxMagnitude is deliberately NOT touched.
        end)
    end))
    return true
end
P.installFastAttack = installFastAttack

-- =========================================================
-- ATTACK
-- =========================================================
local swingIndex = 0

local function pressM1()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vs = cam.ViewportSize
    local x, y = vs.X * 0.5, vs.Y * 0.5

    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, true, game, 0) end)
    task.wait(0.04)
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, false, game, 0) end)

    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:Button1Down(Vector2.new(x, y), cam.CFrame)
        VirtualUser:Button1Up(Vector2.new(x, y), cam.CFrame)
    end)
end

local function pressKey(code)
    pcall(function()
        VIM:SendKeyEvent(true, code, false, game)
        task.wait(0.04)
        VIM:SendKeyEvent(false, code, false, game)
    end)
end

-- JUMP THE WAY A PLAYER DOES: the Space key, not only Humanoid.Jump.
-- Humanoid.Jump is a ground jump and nothing else. The extra jumps you have
-- in the air are the game's own script listening for the JUMP KEY while you
-- are airborne, and a property write never reaches it -- which is why the
-- hop was "sometimes" a jump and never a climb. Space now goes through the
-- input pipeline, and Humanoid.Jump is set as well so the ground jump is
-- certain even if a key event were ever swallowed.
local function jump()
    local _, _, h = parts()
    if h then pcall(function() h.Jump = true end) end
    task.spawn(pressKey, Enum.KeyCode.Space)
end

-- One ray from the character. yOff is height relative to the root (the root
-- sits about three studs above the feet, so -1.5 is the knee and +12 is well
-- over two of you). Only collidable geometry counts; the character and every
-- enemy are excluded, so the target itself is never "an obstacle".
local function rayHit(r, dir, len, yOff)
    local excl = {}
    local char = player.Character
    if char then table.insert(excl, char) end
    local enemies = workspace:FindFirstChild("Enemies")
    if enemies then table.insert(excl, enemies) end
    local ok, hit = pcall(function()
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = excl
        params.RespectCanCollide = true
        local origin = r.Position + Vector3.new(0, yOff, 0)
        return workspace:Raycast(origin, dir * len, params)
    end)
    return ok and hit ~= nil
end

-- Something at knee height a few studs along the direction of travel.
local function ledgeAhead(r, h)
    local md = h.MoveDirection
    if md.Magnitude < 0.1 then return false end
    if h.FloorMaterial == Enum.Material.Air then return false end   -- airborne already
    return rayHit(r, md.Unit, 4.5, -1.5)
end

-- WHICH SIDE IS OPEN. One ray each way at chest height. If only one side is
-- clear, that side; if both or neither, the side that worked last time, so
-- a trunk is gone round in one direction rather than back and forth.
local lastSide = 1
local function openSide(r, dir)
    local right = Vector3.new(-dir.Z, 0, dir.X)
    local rOpen = not rayHit(r, right, 10, 2)
    local lOpen = not rayHit(r, -right, 10, 2)
    if rOpen and not lOpen then return 1 end
    if lOpen and not rOpen then return -1 end
    return lastSide
end

-- THE AIR JUMP, VERIFIED. Space first: that is the game's own air jump, the
-- key you would press. If the character shows no upward kick within a tenth
-- of a second the key did not reach it, and -- if allowed -- the engine is
-- asked for the jump directly. Both are counted, so the stats page shows
-- which one is actually doing the work.
local function airJump(r, h)
    local before = r.AssemblyLinearVelocity.Y
    pressKey(Enum.KeyCode.Space)
    task.wait(0.10)
    local after = r.AssemblyLinearVelocity.Y
    if after > before + 8 then
        stats.airJumps += 1
        return true
    end
    if not CFG.ForceAirJump then return false end
    local ok = pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end)
    if ok then stats.forcedJumps += 1 end
    return ok
end

-- =========================================================
-- GHOST: THROUGH, WHEN ROUND HAS FAILED
-- =========================================================
-- Five builds tried to get round a trunk the legal way -- hops, stacked air
-- jumps, sideways dashes, pathfinding -- and every one of them lived inside
-- the fight. The walk to the camp, the walk to the quest giver and the gather
-- pass had nothing but Humanoid.Jump, so a trunk on any of those walks was
-- "pushes forward and stays there", with none of the recovery ever running.
--
-- So this watches the CHARACTER, not any one routine. Whoever is walking it:
-- if it is being asked to move (MoveDirection) and has gained under three
-- studs that way for GhostAfter seconds, it is blocked, and blocked turns its
-- collisions off. It walks straight through the trunk or the wall. The
-- Humanoid stands on the floor by a ray, not by collision, so the ground still
-- holds it. If where it is going is higher -- a ledge, higher ground -- it is
-- also lifted: one upward kick, sized by gravity to clear the height, while it
-- keeps going forward.
--
-- Collisions come back only once the body is clear of every solid part.
-- Turning them on while inside a trunk would have the engine throw the
-- character out of it, which is worse than the trunk.
--
-- The cost, said plainly: the server sees your position pass through a solid.
-- It only happens after being blocked, and only until you are through.
local ghosting    = false
local ghostSince  = 0
local ghostWhy    = ""
local ghostGen    = 0
local ghostOrig   = {}      -- part -> CanCollide before the ghost, to restore
local ghostConn   = nil
local ghostLifts  = 0
local lastLiftAt  = 0
local lastClearAt = 0
local ghostFrom   = nil     -- where the character stood when it went ghost
local ghostQuietUntil = 0   -- after a fall-through, leave it to the legal ladder
local blockAt, blockPos = nil, nil
-- Where the walk is really going. The fight flattens its MoveTo to your own
-- height, so Humanoid.WalkToPoint alone would never say "up"; whoever is
-- chasing something writes it here, and it goes stale in half a second.
local chaseGoal, chaseGoalAt = nil, 0
local function setChase(pos) chaseGoal, chaseGoalAt = pos, os.clock() end

local function charParts(char)
    local out = {}
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then table.insert(out, d) end
    end
    return out
end

local function ghostOff()
    if ghostConn then pcall(function() ghostConn:Disconnect() end) ghostConn = nil end
    if not ghosting then return end
    ghosting = false
    for part, was in pairs(ghostOrig) do
        if part.Parent then pcall(function() part.CanCollide = was end) end
    end
    table.clear(ghostOrig)
end
P.ghostOff = ghostOff
P.ghosting = function() return ghosting, ghostWhy end

-- Is the body inside anything solid? The root, the torso and the head are
-- asked against real geometry (not bounding boxes, which for a tree mesh
-- take in the whole canopy). Legs are left out: they touch the floor.
-- Every player and every enemy is excluded; only the world counts.
local function bodyClear(char)
    local excl = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then table.insert(excl, pl.Character) end
    end
    local enemies = workspace:FindFirstChild("Enemies")
    if enemies then table.insert(excl, enemies) end
    local op = OverlapParams.new()
    op.FilterType = Enum.RaycastFilterType.Exclude
    op.FilterDescendantsInstances = excl
    op.RespectCanCollide = true
    for _, n in ipairs({ "HumanoidRootPart", "UpperTorso", "Torso", "Head" }) do
        local p = char:FindFirstChild(n)
        if p and p:IsA("BasePart") then
            local ok, hits = pcall(function() return workspace:GetPartsInPart(p, op) end)
            if ok and hits and #hits > 0 then return false end
        end
    end
    return true
end

local function ghostOn(why)
    if not CFG.Ghost then return end
    local char = player.Character
    if not char then return end
    ghostGen += 1
    ghostSince, ghostWhy, ghostLifts = os.clock(), why or "blocked", 0
    say("ghost - " .. ghostWhy)
    if ghosting then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    ghostFrom = root and root.Position or nil
    ghosting = true
    stats.ghosts += 1
    local list, listAt = charParts(char), os.clock()
    -- Stepped runs before physics, every frame. The Humanoid puts collision
    -- back on some of its own parts each step, so one write is not enough.
    ghostConn = RunService.Stepped:Connect(function()
        if player.Character ~= char then ghostOff() return end
        if os.clock() - listAt > 0.5 then list, listAt = charParts(char), os.clock() end
        for _, p in ipairs(list) do
            if ghostOrig[p] == nil then ghostOrig[p] = p.CanCollide end
            p.CanCollide = false
        end
    end)
end

-- Runs every Heartbeat while the farm runs.
local function ghostWatch()
    local char, r, h = parts()
    if not char or not r or not h then blockAt = nil return end
    local now = os.clock()

    if ghosting then
        local g = (chaseGoal and now - chaseGoalAt < 0.5) and chaseGoal
            or (h.WalkToPoint + Vector3.new(0, 3, 0))       -- a path point is at the feet

        -- FELL THROUGH. The Humanoid finds the floor with a ray from the
        -- root, and a ray that starts inside something thick (a cliff, a
        -- hill) may find no floor at all. Well below where the ghost began
        -- AND below where it is going is not a walk down, it is a fall.
        -- Back to where it started, solid again, and the ghost stays quiet
        -- for ten seconds so the bursts and the pathing get their turn.
        if ghostFrom and r.Position.Y < ghostFrom.Y - 10 and r.Position.Y < g.Y - 4 then
            local back = ghostFrom + Vector3.new(0, 2, 0)
            ghostOff()
            pcall(function()
                r.AssemblyLinearVelocity = Vector3.zero
                r.CFrame = CFrame.new(back) * (r.CFrame - r.CFrame.Position)
            end)
            ghostQuietUntil, blockAt = now + 10, nil
            stats.ghostFalls += 1
            say("ghost fell through - back, trying the long way")
            return
        end

        -- LIFT: where it is going is above it.
        if CFG.Ghost and P.running and h.MoveDirection.Magnitude > 0.1
            and ghostLifts < 3 and now - lastLiftAt > 1.2 then
            local rise = g.Y - r.Position.Y
            if rise > 4 then
                lastLiftAt = now
                ghostLifts += 1
                stats.lifts += 1
                local height = math.clamp(rise + 5, 6, CFG.GhostLiftMax or 30)
                local vy = math.sqrt(2 * workspace.Gravity * height)
                pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end)
                local v = r.AssemblyLinearVelocity
                r.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
                ghostSince = now              -- the ghost lasts the flight
                say(string.format("ghost - lifting %.0f studs", height))
            end
        end
        -- OFF: only once through, and never inside something.
        if now - ghostSince > 1.5 and now - lastClearAt > 0.2 then
            lastClearAt = now
            if bodyClear(char) then
                ghostOff()
                blockAt = nil
                say("through")
            end
        end
        return
    end

    if not P.running or not CFG.Ghost or not moveEnabled or now < ghostQuietUntil then
        blockAt = nil
        return
    end
    local md = h.MoveDirection
    local dir = Vector3.new(md.X, 0, md.Z)
    -- Not being asked to move, stunned, or held by the game: not blocked.
    if dir.Magnitude < 0.1 or h.WalkSpeed < 2 or r.Anchored then blockAt = nil return end
    dir = dir.Unit
    if not blockAt then blockAt, blockPos = now, r.Position return end
    local moved = r.Position - blockPos
    if Vector3.new(moved.X, 0, moved.Z):Dot(dir) >= 3 then
        blockAt, blockPos = now, r.Position       -- gaining ground; start over
    elseif now - blockAt >= (CFG.GhostAfter or 1.5) then
        blockAt = nil
        ghostOn("blocked, going through")
    end
end

-- On stop the watcher goes, but a body left inside a trunk must not get its
-- collisions back there. Wait until it is clear (or five seconds), then off --
-- unless a new run has taken the ghost over in the meantime.
local function ghostRelease()
    if not ghosting then ghostOff() return end
    local gen = ghostGen
    task.spawn(function()
        local t0 = os.clock()
        while ghosting and os.clock() - t0 < 5 do
            local c = player.Character
            if not c or bodyClear(c) then break end
            task.wait(0.2)
        end
        if ghostGen == gen then ghostOff() end
    end)
end

-- =========================================================
-- WALK ON WATER
-- =========================================================
-- The sea in Blox Fruits is one slab, workspace.Map["WaterBase-Plane"], and it
-- is the FLOOR you stand on in the sea: it sits under the surface, so standing
-- on it means standing in water, which is what hurts a fruit user, and it is
-- why getting out means climbing an island edge from below. Make the slab
-- taller (Size.Y 80 -> 112) and its top comes up to the surface: you run ON
-- the water. No damage, and no edge to climb, because you never went down.
-- The public hubs all do exactly this, and one re-applies it every tenth of a
-- second, so the game evidently puts it back; it is kept here the same way.
-- It is your client's copy of the slab. Nobody else's sea changes.
-- ALWAYS ON, no switch: you never want water damage, so water is land.
local WATER_Y = 112          -- raised: the top is at the surface (the game's is 80)
P.waterNote = "not looked yet"
P.waterSets = 0

local function keepWater()
    local map = workspace:FindFirstChild("Map")
    local wp = map and map:FindFirstChild("WaterBase-Plane")
    if not (wp and wp:IsA("BasePart")) then
        P.waterNote = "no WaterBase-Plane in workspace.Map here"
        return
    end
    if math.abs(wp.Size.Y - WATER_Y) > 0.5 then
        wp.Size = Vector3.new(wp.Size.X, WATER_Y, wp.Size.Z)
        P.waterSets += 1
    end
    P.waterNote = "solid - standing on the surface"
end

-- =========================================================
-- READ THE GROUND FIRST: A MAP OF THE CAMP, AND A ROUTE ON IT
-- =========================================================
-- Why the approach stuck and stuttered: it ran in a straight line and only
-- found out about a trunk, a ledge or a log by hitting it. Everything after
-- that -- the hop, the bursts, the ghost -- was recovery, and recovery is slow
-- by nature: it has to fail first.
--
-- A camp does not move. So it is read ONCE, on arrival: a grid of cells three
-- studs apart over the ground round the enemies. Per cell, how high the floor
-- is (one ray down). Per step between neighbouring cells, whether a body fits
-- through at the waist (one ray across) and whether something low sits in the
-- way at the knee (one more). A few tens of thousands of rays, spread over
-- about a second of frames so the game never hitches -- and then nothing is
-- scanned again.
--
-- Every step is then one of three things for THIS character:
--   walk : level enough to just walk (up to NAV_STEP studs)
--   jump : up to what your own ground jump clears (read from your jump power
--          and the game's gravity, with a margin), or a log at the knee
--   wall : anything taller, or a trunk / wall at the waist
-- The approach is planned on the map (A*): round walls, over what jumps, and
-- a little away from walls so shoulders do not catch corners. Straight runs
-- are merged into one line, so it does not zig-zag cell to cell. The route is
-- re-planned from memory whenever the enemy moves: milliseconds, no rays.
--
-- Pure Lua from here to NAV GLUE: no Roblox calls, so it can be tested
-- offline against a made-up landscape.
local Nav = {}
local NAV_STEP = 1.2
local NAV_SQ2  = math.sqrt(2)
-- The 8 neighbours: di, dj, which of the 4 stored directions, stored on the
-- neighbour (true) or on this cell (false).
local NAV_DIRS = {
    {  1,  0, 1, false }, { -1,  0, 1, true },
    {  0,  1, 2, false }, {  0, -1, 2, true },
    {  1,  1, 3, false }, { -1, -1, 3, true },
    { -1,  1, 4, false }, {  1, -1, 4, true },
}
local NAV_FWD = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { -1, 1 } }
local NAV_DIR_OF = { [-1] = {}, [0] = {}, [1] = {} }
for k, e in ipairs(NAV_DIRS) do NAV_DIR_OF[e[1]][e[2]] = k end

function Nav.new(cx, cz, radius, cell)
    local n = math.floor(2 * radius / cell) + 1
    return {
        n = n, C = cell, cx = cx, cz = cz,
        x0 = cx - (n - 1) * cell / 2, z0 = cz - (n - 1) * cell / 2,
        H = {}, body = { {}, {}, {}, {} }, knee = { {}, {}, {}, {} },
        near = {}, learned = 0, ready = false, done = 0, total = 2 * n * n,
    }
end

local function navIdx(m, i, j) return j * m.n + i + 1 end

function Nav.cellOf(m, x, z)
    local i = math.floor((x - m.x0) / m.C + 0.5)
    local j = math.floor((z - m.z0) / m.C + 0.5)
    if i < 0 or j < 0 or i >= m.n or j >= m.n then return nil end
    return i, j
end

function Nav.center(m, i, j) return m.x0 + i * m.C, m.z0 + j * m.C end

-- The edge from (i,j) along NAV_DIRS[k]: stored direction, the slot it is
-- stored in, and the two cell indices. nil if the neighbour is off the map.
local function navSlot(m, i, j, k)
    local e = NAV_DIRS[k]
    local bi, bj = i + e[1], j + e[2]
    if bi < 0 or bj < 0 or bi >= m.n or bj >= m.n then return nil end
    local a, b = navIdx(m, i, j), navIdx(m, bi, bj)
    return e[3], (e[4] and b or a), a, b
end

-- 0 walk, 1 jump, 2 wall.
function Nav.edge(m, i, j, k, jumpMax)
    local d, slot, a, b = navSlot(m, i, j, k)
    if not d then return 2 end
    local hA, hB = m.H[a], m.H[b]
    if not hA or not hB then return 2 end
    if m.body[d][slot] then return 2 end
    local rise = hB - hA
    if rise > jumpMax then return 2 end
    if rise > NAV_STEP or m.knee[d][slot] then return 1 end
    return 0
end

-- Learned: this step is shut, whatever the survey said.
function Nav.block(m, i, j, k)
    local d, slot = navSlot(m, i, j, k)
    if d and not m.body[d][slot] then
        m.body[d][slot] = true
        m.learned += 1
    end
end

-- rayDown(x, yTop, z, len) -> floor height or nil
-- rayFlat(x1, y, z1, x2, z2) -> true if something solid is in the way
-- pause() is called every `budget` rays; returning false abandons the read.
function Nav.survey(m, yTop, rayDown, rayFlat, budget, pause)
    local n, used = m.n, 0
    local function tick()
        used += 1
        if used < budget then return true end
        used = 0
        return pause()
    end
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            local x, z = Nav.center(m, i, j)
            m.H[navIdx(m, i, j)] = rayDown(x, yTop, z, 400)
            m.done += 1
            if not tick() then return false end
        end
    end
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            local a = navIdx(m, i, j)
            local hA = m.H[a]
            local x1, z1 = Nav.center(m, i, j)
            for d = 1, 4 do
                local bi, bj = i + NAV_FWD[d][1], j + NAV_FWD[d][2]
                if hA and bi >= 0 and bj >= 0 and bi < n and bj < n then
                    local hB = m.H[navIdx(m, bi, bj)]
                    if hB then
                        local x2, z2 = Nav.center(m, bi, bj)
                        local top = math.max(hA, hB)
                        if rayFlat(x1, top + 2.5, z1, x2, z2) then m.body[d][a] = true end
                        if not tick() then return false end
                        if math.abs(hB - hA) <= NAV_STEP then
                            if rayFlat(x1, top + 1.0, z1, x2, z2) then m.knee[d][a] = true end
                            if not tick() then return false end
                        end
                    end
                end
            end
            m.done += 1
        end
    end
    -- How many of the four straight sides are hard walls: the route pays a
    -- little to pass close to one, so it keeps a shoulder's width off it.
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            local c = 0
            for k = 1, 4 do
                if Nav.edge(m, i, j, k, math.huge) == 2 then c += 1 end
            end
            m.near[navIdx(m, i, j)] = c
        end
    end
    m.ready = true
    return true
end

local function navPush(hf, hv, f, v)
    local k = #hf + 1
    hf[k], hv[k] = f, v
    while k > 1 do
        local p = k // 2
        if hf[p] <= hf[k] then break end
        hf[p], hf[k] = hf[k], hf[p]
        hv[p], hv[k] = hv[k], hv[p]
        k = p
    end
end

local function navPop(hf, hv)
    local n = #hf
    local top = hv[1]
    hf[1], hv[1] = hf[n], hv[n]
    hf[n], hv[n] = nil, nil
    n -= 1
    local k = 1
    while true do
        local l, r, s = 2 * k, 2 * k + 1, k
        if l <= n and hf[l] < hf[s] then s = l end
        if r <= n and hf[r] < hf[s] then s = r end
        if s == k then break end
        hf[s], hf[k] = hf[k], hf[s]
        hv[s], hv[k] = hv[k], hv[s]
        k = s
    end
    return top
end

-- A diagonal may not cut a corner: both straight steps beside it must be
-- open (a jump is open; only a wall shuts it).
local function navCornerOK(m, i, j, k, jumpMax)
    if k <= 4 then return true end
    local e = NAV_DIRS[k]
    return Nav.edge(m, i, j, NAV_DIR_OF[e[1]][0], jumpMax) < 2
        and Nav.edge(m, i, j, NAV_DIR_OF[0][e[2]], jumpMax) < 2
end

-- Route from (sx,sz) to (gx,gz). Returns nodes {x,z,y,i,j,jump} from the
-- start cell to the goal -- or, when the goal cannot be reached, to the
-- reachable cell nearest it -- and whether the goal itself was reached.
-- node.jump = the step INTO this node needs a jump.
function Nav.plan(m, sx, sz, gx, gz, jumpMax, maxExpand)
    local si, sj = Nav.cellOf(m, sx, sz)
    local gi, gj = Nav.cellOf(m, gx, gz)
    if not si or not gi then return nil, false end
    local n, C = m.n, m.C
    local start, goal = navIdx(m, si, sj), navIdx(m, gi, gj)
    local function hcost(i, j)
        local dx, dz = math.abs(i - gi), math.abs(j - gj)
        return C * (math.max(dx, dz) + (NAV_SQ2 - 1) * math.min(dx, dz))
    end
    local g, came, jumpIn, closed = { [start] = 0 }, {}, {}, {}
    local hf, hv = {}, {}
    navPush(hf, hv, hcost(si, sj), start)
    local best, bestH = start, hcost(si, sj)
    local expanded, cap = 0, maxExpand or 3000
    while #hv > 0 do
        local a = navPop(hf, hv)
        if a == goal then best = goal break end
        if not closed[a] then
            closed[a] = true
            expanded += 1
            if expanded > cap then break end
            local i, j = (a - 1) % n, (a - 1) // n
            local hh = hcost(i, j)
            if hh < bestH then best, bestH = a, hh end
            for k = 1, 8 do
                local e = NAV_DIRS[k]
                local bi, bj = i + e[1], j + e[2]
                if bi >= 0 and bj >= 0 and bi < n and bj < n then
                    local b = navIdx(m, bi, bj)
                    if not closed[b] then
                        local cls = Nav.edge(m, i, j, k, jumpMax)
                        if cls < 2 and navCornerOK(m, i, j, k, jumpMax) then
                            local stepLen = (k <= 4) and C or C * NAV_SQ2
                            local cost = stepLen * (1 + 0.35 * (m.near[b] or 0))
                                + (cls == 1 and 1.5 * C or 0)
                            local ng = g[a] + cost
                            if g[b] == nil or ng < g[b] then
                                g[b], came[b], jumpIn[b] = ng, a, (cls == 1)
                                navPush(hf, hv, ng + hcost(bi, bj), b)
                            end
                        end
                    end
                end
            end
        end
    end
    local cells, a = {}, best
    while a do
        table.insert(cells, 1, a)
        a = came[a]
    end
    local nodes = {}
    for _, c in ipairs(cells) do
        local i, j = (c - 1) % n, (c - 1) // n
        local x, z = Nav.center(m, i, j)
        table.insert(nodes, { x = x, z = z, y = m.H[c] or 0, i = i, j = j,
            jump = jumpIn[c] or false })
    end
    return nodes, best == goal
end

-- Is the straight line from A to B a plain walk the whole way: no jump, no
-- wall, no corner cut, and not brushing a wall? Checked cell to cell along
-- the line.
local function navLineClear(m, ax, az, bx, bz, jumpMax)
    local dx, dz = bx - ax, bz - az
    local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dz * dz) / (m.C * 0.5)))
    local pi, pj = Nav.cellOf(m, ax, az)
    if not pi then return false end
    for s = 1, steps do
        local t = s / steps
        local ci, cj = Nav.cellOf(m, ax + dx * t, az + dz * t)
        if not ci then return false end
        if ci ~= pi or cj ~= pj then
            local di, dj = ci - pi, cj - pj
            if math.abs(di) > 1 or math.abs(dj) > 1 then return false end
            local k = NAV_DIR_OF[di][dj]
            if Nav.edge(m, pi, pj, k, jumpMax) ~= 0 then return false end
            if k > 4 and (Nav.edge(m, pi, pj, NAV_DIR_OF[di][0], jumpMax) ~= 0
                or Nav.edge(m, pi, pj, NAV_DIR_OF[0][dj], jumpMax) ~= 0) then
                return false
            end
            if s < steps and (m.near[navIdx(m, ci, cj)] or 0) > 0 then return false end
            pi, pj = ci, cj
        end
    end
    return true
end

-- Merge the cell-by-cell route into straight runs. A jump step is never
-- merged across: both its ends stay, so the jump happens where it must.
function Nav.smooth(m, nodes, jumpMax)
    if #nodes <= 2 then return nodes end
    local out, a = { nodes[1] }, 1
    while a < #nodes do
        local far = a + 1
        if not nodes[a + 1].jump then
            for c = a + 2, #nodes do
                if nodes[c].jump then break end
                if navLineClear(m, nodes[a].x, nodes[a].z, nodes[c].x, nodes[c].z, jumpMax) then
                    far = c
                else
                    break
                end
            end
        end
        table.insert(out, nodes[far])
        a = far
    end
    return out
end

-- How long a jump with take-off speed v0 takes to rise `rise` studs; nil if
-- it never gets that high.
function Nav.riseTime(v0, grav, rise)
    local disc = v0 * v0 - 2 * grav * rise
    if disc < 0 then return nil end
    return (v0 - math.sqrt(disc)) / grav
end

-- The 8-neighbour direction closest to (dx, dz).
function Nav.dirToward(dx, dz)
    local a = math.atan2(dz, dx)
    local oct = math.floor(a / (math.pi / 4) + 0.5) % 8
    local map = { [0] = { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 },
                  { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }
    local v = map[oct]
    return NAV_DIR_OF[v[1]][v[2]]
end
-- ============ NAV GLUE ============
-- The Roblox side. The map is read once per camp, in the background; the
-- route is followed every frame. The fight only says WHERE it wants to be
-- (navWant); the follower decides how to get there.
local NAV_RADIUS, NAV_CELL = 90, 3
local navMap, navBuilding = nil, nil
local navGoal, navGoalAt = nil, 0
local navPath, navPathGoal, navPathAt, navReached, navI = nil, nil, 0, false, 2

local function navRays()
    local excl = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then table.insert(excl, pl.Character) end
    end
    local enemies = workspace:FindFirstChild("Enemies")
    if enemies then table.insert(excl, enemies) end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = excl
    rp.RespectCanCollide = true
    local function down(x, yTop, z, len)
        local hit = workspace:Raycast(Vector3.new(x, yTop, z), Vector3.new(0, -len, 0), rp)
        return hit and hit.Position.Y or nil
    end
    local function flat(x1, y, z1, x2, z2)
        return workspace:Raycast(Vector3.new(x1, y, z1), Vector3.new(x2 - x1, 0, z2 - z1), rp) ~= nil
    end
    return down, flat
end

-- Read the camp, if this one has not been read. The centre is the middle of
-- the enemies near you (that is where the running happens), else you.
local function navEnsure(list, mePos)
    if not CFG.TerrainMap or navBuilding then return end
    local sx, sz, c = 0, 0, 0
    for _, e in ipairs(list) do
        local p = e.root.Position
        if (p - mePos).Magnitude < 150 then sx += p.X sz += p.Z c += 1 end
    end
    local cx, cz = mePos.X, mePos.Z
    if c > 0 then cx, cz = sx / c, sz / c end
    if navMap then
        local off = math.sqrt((navMap.cx - cx) ^ 2 + (navMap.cz - cz) ^ 2)
        local meIn = Nav.cellOf(navMap, mePos.X, mePos.Z) ~= nil
        if off < NAV_RADIUS * 0.5 and meIn then return end
    end
    local m = Nav.new(cx, cz, NAV_RADIUS, NAV_CELL)
    navBuilding = m
    local down, flat = navRays()
    -- UNDER A ROOF? Read from 30 studs up, the floor is the roof of a cave or
    -- a building. Checked on a ring round you so one tree's canopy does not
    -- count: only when most of the ring is covered is the whole read taken
    -- from just over head height instead.
    local top, covered = mePos.Y + 30, 0
    for k = 0, 7 do
        local a = k * math.pi / 4
        local fy = down(mePos.X + 20 * math.cos(a), top, mePos.Z + 20 * math.sin(a), 400)
        if fy and fy > mePos.Y + 1 then covered += 1 end
    end
    if covered >= 6 then top = mePos.Y + 4 end
    m.top = top
    local myEpoch = epoch
    task.spawn(function()
        local ok = pcall(Nav.survey, m, top, down, flat, 400, function()
            task.wait()
            return (not stale(myEpoch)) and CFG.TerrainMap and navBuilding == m
        end)
        if navBuilding == m then navBuilding = nil end
        if ok and m.ready then
            navMap, navPath = m, nil
            stats.navMaps += 1
        end
    end)
end

local function navHalt() navGoal, navPath = nil, nil end

local function navUsable(goal)
    if not CFG.TerrainMap then return false end
    local m = navMap
    if not (m and m.ready) then return false end
    local _, r = parts()
    if not r then return false end
    return Nav.cellOf(m, r.Position.X, r.Position.Z) ~= nil
        and Nav.cellOf(m, goal.X, goal.Z) ~= nil
end

local function navWant(goal) navGoal, navGoalAt = goal, os.clock() end

-- Following a planned route to a goal it can actually reach?
local function navFollowing()
    return navGoal ~= nil and navPath ~= nil and navReached
        and os.clock() - navGoalAt < 0.5
end

-- Your own ground jump: take-off speed, and the highest step it clears
-- (85% of the peak, so a step is never taken at the very top of the arc).
local function navJump(h)
    local grav = workspace.Gravity
    local v0
    if h.UseJumpPower then v0 = h.JumpPower else v0 = math.sqrt(2 * grav * math.max(h.JumpHeight, 0)) end
    if v0 < 20 then v0 = 50 end        -- jumping handed to the game's own script: assume the default
    return v0, grav, 0.85 * v0 * v0 / (2 * grav)
end

-- The step just ahead is shut: mark it, and plan again round it.
local function navLearnAhead()
    local m, path = navMap, navPath
    local _, r = parts()
    if not (m and path and r) then return end
    local nd = path[math.min(navI, #path)]
    local ci, cj = Nav.cellOf(m, r.Position.X, r.Position.Z)
    if not ci then return end
    Nav.block(m, ci, cj, Nav.dirToward(nd.x - r.Position.X, nd.z - r.Position.Z))
    navPath = nil
    stats.navLearned += 1
end

-- Every frame: steer along the route and jump before each edge.
local function navTick()
    if not navGoal then return end
    local now = os.clock()
    if now - navGoalAt > 0.5 or not P.running or not CFG.TerrainMap then
        navHalt()
        return
    end
    local m = navMap
    local _, r, h = parts()
    if not (m and m.ready and r and h) then return end
    local me, goal = r.Position, navGoal
    local v0, grav, jumpMax = navJump(h)

    -- Plan again: no route, the goal moved, or wandered off it. Never more
    -- often than five times a second; a plan is a few milliseconds.
    local replan = navPath == nil
        or (navPathGoal and ((goal.X - navPathGoal.X) ^ 2 + (goal.Z - navPathGoal.Z) ^ 2) > 9)
        or now - navPathAt > 1.5
    if navPath and not replan then
        local nd = navPath[math.min(navI, #navPath)]
        if (nd.x - me.X) ^ 2 + (nd.z - me.Z) ^ 2 > (NAV_CELL * 6) ^ 2 then replan = true end
    end
    if replan and (navPath == nil or now - navPathAt > 0.2) then
        local nodes, reached = Nav.plan(m, me.X, me.Z, goal.X, goal.Z, jumpMax, 3000)
        navPath = nodes and Nav.smooth(m, nodes, jumpMax) or nil
        navPathGoal, navPathAt, navReached, navI = goal, now, reached, 2
        stats.navPlans += 1
    end
    local path = navPath
    if not path or #path < 2 then
        h:MoveTo(goal)
        return
    end

    -- Past a point: next one. "Past" is either close to it, or already on
    -- the far side of it along the route. A jump point is only passed by
    -- actually getting up there.
    while navI < #path do
        local a, b = path[navI], path[navI + 1]
        local ax, az = me.X - a.x, me.Z - a.z
        local near = ax * ax + az * az < 2.5 * 2.5
        local beyond = ax * (b.x - a.x) + az * (b.z - a.z) > 0
        local up = me.Y > a.y + 2.2             -- standing on its level
        if (near or beyond) and (not a.jump or up) then
            navI += 1
        else
            break
        end
    end
    local nd = path[navI]

    -- STEER: aim ahead along the route, further the faster you are, but
    -- never past a jump point (the run-up must line up with the jump).
    local tx, tz, ty = nd.x, nd.z, nd.y
    if navI == #path then
        -- The last point: the goal itself. If the map has NO way in, it still
        -- pushes straight at it from the nearest point, so the stuck ladder
        -- (bursts, ghost) gets its turn instead of standing there politely.
        local dx, dz = me.X - nd.x, me.Z - nd.z
        if navReached or dx * dx + dz * dz < 4 * 4 then
            tx, tz, ty = goal.X, goal.Z, goal.Y - 3
        end
    else
        local look = math.clamp(h.WalkSpeed * 0.25, 5, 14)
        local dx, dz = nd.x - me.X, nd.z - me.Z
        local dn = math.sqrt(dx * dx + dz * dz)
        local nx = path[navI + 1]
        if dn < look and not nd.jump and not nx.jump then
            local sx, sz = nx.x - nd.x, nx.z - nd.z
            local sl = math.sqrt(sx * sx + sz * sz)
            if sl > 0.01 then
                local t = math.min(1, (look - dn) / sl)
                tx, tz, ty = nd.x + sx * t, nd.z + sz * t, nd.y + (nx.y - nd.y) * t
            end
        end
    end
    h:MoveTo(Vector3.new(tx, ty + 3, tz))

    -- JUMP BEFORE THE EDGE: as far ahead of it as you travel while the jump
    -- rises to the step's height, plus a stud. Ground jumps only.
    for k = navI, math.min(#path, navI + 1) do
        local jn = path[k]
        if jn.jump and k > 1 then
            local pv = path[k - 1]
            local ex, ez = (pv.x + jn.x) / 2, (pv.z + jn.z) / 2
            local rise = math.max(0.8, jn.y - pv.y) + 0.6
            local t = Nav.riseTime(v0, grav, rise) or 0.3
            local lead = h.WalkSpeed * t + 1.0
            local dx, dz = ex - me.X, ez - me.Z
            if dx * dx + dz * dz <= lead * lead
                and h.FloorMaterial ~= Enum.Material.Air
                and now - lastJumpAt > 0.35 then
                jump()
                lastJumpAt = now
                stats.navJumps += 1
            end
            break
        end
    end
end

-- (the climb and the sideways burst live after tryDash: they dash.)

-- =========================================================
-- HAKI, AND WHAT A DEATH TAKES WITH IT
-- =========================================================
-- Dying drops the tool, turns Enhancement (J) off and turns Observation (E)
-- off. In the Third Sea the swing does not land without Enhancement, so a
-- respawn without it walks back to the camp and dies again.
--
-- Enhancement can be CHECKED: the character carries a child named HasBuso
-- while it is on. So it is re-asserted whenever it is missing, capped at
-- three presses per life so a wrong marker name can never become a toggle
-- war.
-- OBSERVATION CAN BE READ AFTER ALL. While it is on, the game shows its dodge
-- counter, and that counter is an ImageLabel directly under
-- PlayerGui.ScreenGui -- the same check the public hubs use for their own
-- auto-Ken. Present = on, gone = off. E is a toggle, so it is pressed ONLY
-- when the counter is gone: a press can never turn an on Observation off.
-- It is looked at after every death and every KenEvery seconds (5 minutes).
--
-- The marker is trusted once it has been seen. Until then, a press that does
-- not make it appear is a miss; two misses in a row (two presses, so E is
-- left where it started) and the timed check stops pressing and says so on
-- the panel. A new life still gets its one press either way: a death always
-- turns Observation off, so that press is safe with or without a marker.
P.busoOK   = false
P.kenDone  = false
local kenChar     = nil    -- the life E has been checked for
local seenChar    = nil
local seenCharAt  = 0
local busoTries   = 0
local lastBusoAt  = 0
local kenNextAt   = 0      -- next timed look
local kenVerifyAt = nil    -- a press is waiting to be checked at this time
local kenSeen     = false  -- the marker has been seen: it is real
local kenMisses   = 0
local kenBlind    = false  -- marker never seen and two presses missed
P.kenNote = "not checked yet"

local function hasBuso()
    local char = player.Character
    return char ~= nil and char:FindFirstChild("HasBuso") ~= nil
end
P.hasBuso = hasBuso

-- true = on, false = off, nil = cannot tell (no ScreenGui to look in).
local function kenOn()
    local pg = player:FindFirstChildOfClass("PlayerGui")
    local sg = pg and pg:FindFirstChild("ScreenGui")
    if not sg then return nil end
    return sg:FindFirstChild("ImageLabel") ~= nil
end
P.kenOn = kenOn
P.kenNextIn = function() return math.max(0, kenNextAt - os.clock()) end

local function keepHaki()
    local char, root, hum = parts()
    if not char or not root or not hum then return end
    if char ~= seenChar then
        seenChar, seenCharAt = char, os.clock()
        busoTries = 0
    end
    if os.clock() - seenCharAt < 1.5 then return end   -- let the spawn settle

    if CFG.AutoBuso then
        if hasBuso() then
            P.busoOK = true
        else
            P.busoOK = false
            if busoTries < 3 and os.clock() - lastBusoAt > 2.5 then
                lastBusoAt = os.clock()
                busoTries += 1
                stats.hakiPresses += 1
                pressKey(Enum.KeyCode.J)
                say("enhancement off - pressing J")
            end
        end
    end

    if not CFG.AutoKen then return end
    local now = os.clock()
    local on  = kenOn()
    if on then kenSeen, kenBlind, kenMisses = true, false, 0 end

    -- The last press: did the counter come up?
    if kenVerifyAt and now >= kenVerifyAt then
        kenVerifyAt = nil
        if on then
            P.kenNote = "ON - E worked, dodge counter showing"
        elseif on == false then
            -- Out of dodges puts Observation on a cooldown and E does nothing
            -- until it ends; or the marker is wrong. Look again soon.
            kenMisses += 1
            kenNextAt = now + 20
            if not kenSeen and kenMisses >= 2 then
                kenBlind = true
                P.kenNote = "E pressed twice, dodge counter never appeared - "
                    .. "timed check paused (a death still gets its one press)"
            else
                P.kenNote = "E pressed, counter not up yet - trying again in 20s"
            end
        end
    end
    if kenVerifyAt then return end

    local newLife = (kenChar ~= char)
    if not newLife and now < kenNextAt then return end

    -- A new life waits until the character has proved it takes input (the
    -- Enhancement press landed). A timed look on a settled life does not.
    if newLife then
        local ready
        if CFG.AutoBuso then
            ready = hasBuso()
        else
            ready = (now - seenCharAt) > 3
        end
        if not ready then return end
    end
    kenChar   = char
    kenNextAt = now + math.max(30, CFG.KenEvery or 300)
    P.kenDone = true

    if on then
        P.kenNote = "ON - checked, left alone"
        return
    end
    if on == false and kenBlind and not newLife then
        P.kenNote = "counter not showing, but the marker is unproven - not pressing"
        return
    end
    if on == nil and not newLife then
        P.kenNote = "cannot see PlayerGui.ScreenGui - timed check skipped"
        return
    end
    stats.hakiPresses += 1
    pressKey(Enum.KeyCode.E)
    say("observation off - pressing E")
    P.kenNote = "OFF - pressed E, checking"
    if on ~= nil then kenVerifyAt = now + 2.5 end
end

local SKILL_KEYS = {
    { "SkillZ", Enum.KeyCode.Z },
    { "SkillX", Enum.KeyCode.X },
    { "SkillC", Enum.KeyCode.C },
    { "SkillV", Enum.KeyCode.V },
}
local skillIndex = 0
local function activeSkills()
    local out = {}
    for _, row in ipairs(SKILL_KEYS) do
        if CFG[row[1]] then table.insert(out, row[2]) end
    end
    return out
end
P.activeSkillCount = function() return #activeSkills() end

local function swing()
    stats.swings += 1
    swingIndex += 1
    if CFG.M1 then pressM1() end
    local keys = activeSkills()
    if #keys > 0 then
        local every = math.max(1, math.floor(CFG.SkillEvery or 4))
        -- With M1 off every swing IS a skill: there is nothing to space out.
        if (not CFG.M1) or (swingIndex % every == 0) then
            skillIndex = (skillIndex % #keys) + 1
            pressKey(keys[skillIndex])
        end
    end
end

local function swingGap() return jitter(CFG.SwingMin or 0.12, CFG.SwingMax or 0.30) end

-- WAIT OUT THE SWING GAP, BUT WATCH WHILE WAITING.
-- task.wait(swingGap()) sleeps blind for up to a third of a second and only
-- then looks at the target, so the killing blow was followed by the character
-- standing over a corpse for the rest of the gap before it noticed. From
-- outside that is indistinguishable from the script stopping to think, and it
-- is what "it scans to see whether it is killed" actually was.
-- Same total gap between swings, but death is seen within a frame of it
-- happening.
-- It also breaks the moment the target is thrown out of reach. The fourth hit
-- of a combo knocks these things a long way, and waiting out the rest of the
-- gap over an empty patch of ground is time the walk after it could have had.
-- No extra swing comes of this: swings only fire from the in-reach branch.
local function swingWait(hum, targetRoot, reach)
    local deadline = os.clock() + swingGap()
    repeat
        task.wait()
        if not hum or hum.Parent == nil or hum.Health <= 0 then return end
        if targetRoot and reach then
            local _, r = parts()
            if r and (targetRoot.Position - r.Position).Magnitude > reach + 4 then
                return
            end
        end
    until os.clock() >= deadline
end
local function restGap()  return jitter(CFG.RestMin or 0, CFG.RestMax or 0) end

-- THE DASH.
-- Fired at the gap, not at the enemy: only when the next target is further
-- away than DashFrom, so it closes distance instead of overshooting something
-- already in reach. The body is already pointing at the target by then --
-- AutoRotate turns it toward whatever MoveTo is walking at -- so the dash goes
-- the right way without any extra aiming.
local DASH_KEYS = {
    Q = Enum.KeyCode.Q, E = Enum.KeyCode.E, F = Enum.KeyCode.F,
    R = Enum.KeyCode.R, LeftShift = Enum.KeyCode.LeftShift,
}
local lastDashAt = 0
-- WHY THE DASH WAS BROKEN.
-- The key itself was never the problem. Blox Fruits dashes along the direction
-- you are MOVING, and falls back to the way the body is pointing when you are
-- standing still. This script never presses WASD -- it moves with
-- Humanoid:MoveTo -- and it no longer owns the camera either. So at the moment
-- the key was pressed, the direction was simply whatever the character
-- happened to be doing, and nothing checked it.
--
-- Three things went wrong from that:
--   * it was fired the instant a new target was chosen, BEFORE the character
--     had turned or taken a step. The body was still pointing at the enemy
--     that had just died, so the dash threw you at the corpse and the walk
--     then had to bring you back. That is the "goes to it and comes back".
--   * with no direction check at all, any dash fired mid-turn went sideways.
--   * DashFrom was 16 studs, which is far less than a dash covers, so even a
--     correctly aimed one overshot and had to walk back.
--
-- So now it refuses unless the character is genuinely already moving TOWARD
-- the target. If it cannot confirm that, it does not dash. A dash that does
-- not happen costs a moment; a dash in the wrong direction costs the walk
-- back, and that is the trade that was being got wrong.
-- Turn only the camera's YAW at a point. Pitch and zoom are kept. The default
-- camera reads its own look vector back at the start of every frame and
-- applies your mouse on top, so one write sticks and your mouse takes over
-- again immediately. Camera state is client-only; the server never sees it.
local function turnCameraAt(targetPos)
    local cam = workspace.CurrentCamera
    if not cam then return false end
    local here = cam.CFrame.Position
    local flat = targetPos - here
    flat = Vector3.new(flat.X, 0, flat.Z)
    if flat.Magnitude < 0.5 then return false end
    local f    = flat.Unit
    local sinP = math.clamp(cam.CFrame.LookVector.Y, -0.99, 0.99)
    local cosP = math.sqrt(1 - sinP * sinP)
    local look = Vector3.new(f.X * cosP, sinP, f.Z * cosP)
    return pcall(function()
        cam.CFrame = CFrame.lookAt(here, here + look)
    end)
end

-- THE DASH GOES WHERE THE CAMERA LOOKS.
-- With no WASD held, the game dashes "forward", and forward is the camera.
-- The build before this guessed at that and, unable to aim the camera without
-- taking your view, refused to dash unless your camera already agreed -- and
-- because the character turns around a camp while your camera does not, it
-- almost never did. Now the camera's yaw is turned at the target for the
-- press (pitch, zoom and your mouse untouched), so body, walk and camera all
-- agree at the instant of the key.
local function tryDash(distance, toward)
    if not CFG.Dash then return false end
    if distance and distance < (CFG.DashFrom or 25) then return false end
    if os.clock() - lastDashAt < (CFG.DashCooldown or 0.9) then return false end

    local _, r = parts()
    if not r then return false end
    local want = toward and Vector3.new(toward.X, 0, toward.Z) or nil
    if not want or want.Magnitude < 0.1 then return false end

    if CFG.DashTurnsCamera then
        if not turnCameraAt(r.Position + toward) then return false end
    else
        local cam = workspace.CurrentCamera
        if not cam then return false end
        local look = cam.CFrame.LookVector
        look = Vector3.new(look.X, 0, look.Z)
        if look.Magnitude < 0.1 then return false end
        if look.Unit:Dot(want.Unit) < 0.7 then return false end   -- ~45 deg
    end

    lastDashAt = os.clock()
    -- Spawned, not called. pressKey holds the key down for a frame before
    -- releasing it, and doing that inline stalls the loop for that long.
    task.spawn(pressKey, DASH_KEYS[CFG.DashKey or "Q"] or Enum.KeyCode.Q)
    stats.dashes += 1
    return true
end

-- A dash in a chosen direction, no questions asked: camera turned that way,
-- key pressed. Used by the panic bursts, which are exactly the moment you
-- would not stop to check a cooldown.
local function dashDir(r, dir)
    turnCameraAt(r.Position + dir * 20)
    task.wait()                                  -- let the camera write land
    pressKey(DASH_KEYS[CFG.DashKey or "Q"] or Enum.KeyCode.Q)
    lastDashAt = os.clock()
    stats.dashes += 1
    stats.panicDashes += 1
end

local function panicGuard(myEpoch)
    return stale(myEpoch) or not P.running or not moveEnabled
end

-- CLIMB BURST: stand still, jump, stack every air jump STRAIGHT UP, then go
-- forward off the top.
-- The air jump goes where you are moving. The build before this held
-- forward the whole time, so every air jump was spent into the face of the
-- ledge and the character never got high. Movement is cancelled first, the
-- jumps stack vertically, and only then -- at the top -- the camera turns to
-- the target and it dashes and walks forward. Returns true on real forward
-- progress.
local function climbBurst(targetRoot)
    navHalt()
    local _, r, h = parts()
    if not r or not h or not targetRoot then return false end
    local start = r.Position
    local flat  = targetRoot.Position - start
    flat = Vector3.new(flat.X, 0, flat.Z)
    if flat.Magnitude < 0.5 then return false end
    local dir = flat.Unit
    local n   = math.max(1, math.floor(CFG.ClimbJumps or 6))
    local myEpoch = epoch

    h:MoveTo(r.Position)                         -- STOP. No forward input.
    task.wait(0.12)
    jump()
    stats.hops += 1
    lastJumpAt = os.clock()
    task.wait(0.35)

    for _ = 1, n do
        if panicGuard(myEpoch) then return false end
        local _, r2, h2 = parts()
        if not r2 or not h2 then return false end
        h2:MoveTo(r2.Position)                   -- still: the jump goes UP
        airJump(r2, h2)
        lastJumpAt = os.clock()
        task.wait(0.3)
    end

    -- At the top: forward. Camera at the target, dash, and walk.
    local _, r3, h3 = parts()
    if not r3 or not h3 then return false end
    local goal = targetRoot.Position
    h3:MoveTo(Vector3.new(goal.X, r3.Position.Y, goal.Z))
    dashDir(r3, dir)
    task.wait(0.7)
    local _, r4 = parts()
    if not r4 then return false end
    return (r4.Position - start):Dot(dir) > 4
end

-- SIDEWAYS BURST: two dashes to one side, then forward again. Twenty studs
-- a dash, which is what gets round a trunk; an eight-stud sidestep was not.
-- Movement is cancelled first so the dash follows the camera and not a
-- MoveTo. Returns true if it got forward, or at least somewhere new.
local function lateralBurst(targetRoot, side)
    navHalt()
    local _, r, h = parts()
    if not r or not h or not targetRoot then return false end
    local start = r.Position
    local flat  = targetRoot.Position - start
    flat = Vector3.new(flat.X, 0, flat.Z)
    if flat.Magnitude < 0.5 then return false end
    local dir = flat.Unit
    local lat = Vector3.new(-dir.Z * side, 0, dir.X * side)
    local myEpoch = epoch

    h:MoveTo(r.Position)                         -- STOP, so the dash is the camera's
    task.wait(0.12)
    for _ = 1, 2 do
        if panicGuard(myEpoch) then return false end
        local _, r2, h2 = parts()
        if not r2 or not h2 then return false end
        h2:MoveTo(r2.Position)
        dashDir(r2, lat)
        task.wait(0.55)
    end

    local _, r3, h3 = parts()
    if not r3 or not h3 then return false end
    local goal = targetRoot.Position
    h3:MoveTo(Vector3.new(goal.X, r3.Position.Y, goal.Z))
    task.wait(0.6)
    local _, r4 = parts()
    if not r4 then return false end
    local moved = r4.Position - start
    local flatMoved = Vector3.new(moved.X, 0, moved.Z).Magnitude
    local ok = moved:Dot(dir) > 4 or flatMoved > 12
    if ok then lastSide = side end
    return ok
end
P.tryDash = tryDash

-- =========================================================
-- WALKING
-- =========================================================
-- PathfindingService for the route, Humanoid:MoveTo for the steps. The
-- humanoid walks at its own WalkSpeed, physics does the collisions, and the
-- route goes around the wall instead of through it.
local function cancelWalk()
    local _, r, h = parts()
    if r and h then h:MoveTo(r.Position) end
end

-- Turn to face something without moving. Yaw only, which is what a mouse turn
-- produces; the position is untouched.
-- 0.94 is about twenty degrees of slop, which was fine for walking up to a
-- quest giver and useless for landing a swing: the body sat up to twenty
-- degrees off and the arc went past the enemy. Tight now, so the aim is
-- re-asserted on essentially every pass.
local function faceTarget(root, targetPos, tight)
    local flat = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
    if (flat - root.Position).Magnitude < 0.5 then return end
    local want = CFrame.new(root.Position, flat)
    local slop = tight and 0.9995 or 0.94
    if root.CFrame.LookVector:Dot(want.LookVector) > slop then return end
    root.CFrame = want
end

-- THE CAMERA, BORROWED AND GIVEN BACK.
-- Scriptable is a real hijack: while it is set the player's own mouse look is
-- dead. It is only taken while something is being fought, and every exit path
-- hands it back.
local camHeld = false
local function releaseCamera()
    if not camHeld then return end
    camHeld = false
    local cam = workspace.CurrentCamera
    if not cam then return end
    pcall(function()
        local _, _, hum = parts()
        if hum then cam.CameraSubject = hum end
        cam.CameraType = Enum.CameraType.Custom
    end)
end
P.releaseCamera = releaseCamera

local lastCamAt = 0
local function aimCameraAt(root, targetPos)
    if not CFG.AimCamera then return end
    local cam = workspace.CurrentCamera
    if not cam or not root then return end
    if os.clock() - lastCamAt < 0.06 then return end
    lastCamAt = os.clock()

    local eye  = root.Position + Vector3.new(0, 2, 0)
    local flat = targetPos - eye
    flat = Vector3.new(flat.X, 0, flat.Z)
    if flat.Magnitude < 0.5 then return end
    local back = eye - flat.Unit * (CFG.CamBack or 13)
        + Vector3.new(0, CFG.CamUp or 5, 0)

    pcall(function()
        if not camHeld then
            cam.CameraType = Enum.CameraType.Scriptable
            camHeld = true
        end
        cam.CFrame = CFrame.new(back, targetPos)
        -- The centre of the screen is now the enemy, so that is where the
        -- cursor belongs: the skill ray and the camera agree.
        local vs = cam.ViewportSize
        VIM:SendMouseMoveEvent(vs.X * 0.5, vs.Y * 0.5, game)
    end)
end

-- Walk a real route. arrive = how close counts as there, budget = seconds.
local function walkTo(goal, opts)
    navHalt()
    opts = opts or {}
    local _, root, hum = parts()
    if not root or not hum then return false end
    local arrive = opts.arrive or 6
    local budget = opts.budget or 30
    if (root.Position - goal).Magnitude <= arrive then return true end
    stats.walks += 1

    local path = PathService:CreatePath({
        AgentRadius     = 3,
        AgentHeight     = 6,
        AgentCanJump    = true,
        AgentMaxSlope   = 60,
        WaypointSpacing = 8,
    })

    local myEpoch = epoch
    local deadline, retries = os.clock() + budget, 0
    while os.clock() < deadline and moveEnabled and not stale(myEpoch) do
        local _, r, h = parts()
        if not r or not h then return false end
        if (r.Position - goal).Magnitude <= arrive then return true end
        local ok = pcall(function() path:ComputeAsync(r.Position, goal) end)
        local points = (ok and path.Status == Enum.PathStatus.Success)
            and path:GetWaypoints() or nil

        if not points or #points < 2 then
            -- No route: the goal may be mid-air, inside geometry, or across
            -- water. Push at it in a straight walk, which still collides.
            local before = r.Position
            h:MoveTo(goal)
            task.wait(1.0)
            local _, r2 = parts()
            if not r2 then return false end
            if (r2.Position - before).Magnitude < 1.5 then
                if CFG.JumpWhenStuck then h.Jump = true end
                retries += 1
                if retries > 5 then return false end
            end
        else
            for i = 2, #points do
                if not moveEnabled or stale(myEpoch) then return false end
                local wp = points[i]
                local _, r3, h3 = parts()
                if not r3 or not h3 then return false end

                if wp.Action == Enum.PathWaypointAction.Jump then h3.Jump = true end
                h3:MoveTo(wp.Position)

                -- MoveToFinished waits its full eight seconds on a waypoint
                -- that cannot be reached, so it is raced against a short clock.
                --
                -- NEVER ARRIVE, NEVER STOP. A Humanoid halts the instant it
                -- reaches its MoveTo point. With waypoints eight studs apart
                -- and a look every tenth of a second, a fast character (Mink,
                -- Kitsune, a speed helmet) got to each one well inside that
                -- tenth and stood there until the next look: run, stop, run,
                -- stop, the whole way to the camp or the giver. Now it looks
                -- every frame and hands over the next waypoint while this one
                -- is still a tenth of a second of travel away, so the body is
                -- never told it has arrived. The speed is the game's; this
                -- only stops throwing it away.
                local reached, stamp = false, r3.Position
                local wpDeadline = os.clock() + 3
                local lastWp = (i == #points)
                while os.clock() < wpDeadline do
                    if stale(myEpoch) then return false end
                    local _, r4, h4 = parts()
                    if not r4 or not h4 then return false end
                    if (r4.Position - goal).Magnitude <= arrive then return true end
                    local off  = wp.Position - r4.Position
                    local lead = lastWp and 4 or math.clamp(h4.WalkSpeed * 0.1, 4, 8)
                    if Vector3.new(off.X, 0, off.Z).Magnitude < lead and math.abs(off.Y) < 6 then
                        reached = true
                        break
                    end
                    task.wait()
                end

                if not reached then
                    local _, r5, h5 = parts()
                    if r5 and (r5.Position - stamp).Magnitude < 1.5 then
                        if CFG.JumpWhenStuck and h5 then h5.Jump = true end
                        retries += 1
                        if retries > 5 then return false end
                        break
                    end
                end
                if os.clock() > deadline then break end
            end
        end
    end

    local _, rf = parts()
    return rf ~= nil and (rf.Position - goal).Magnitude <= arrive + 8
end
P.walkTo = walkTo

-- STATION: hold the enemy at the distance you chose, in front of you.
-- Closing in is half of it. Backing OFF is the other half, and it is the half
-- that matters for a fruit M1 whose hitbox starts a few studs out: an enemy
-- standing inside that gap takes nothing. Both corrections move along the same
-- line, so the enemy stays in front instead of being orbited.
-- Returns the current flat distance.
-- climb: the target is above or below by more than a swing reaches, so keep
-- pushing at it however close it is on the flat. The ray and the jump take
-- it from there.
local function station(targetRoot, climb)
    local _, r, h = parts()
    if not r or not h or not targetRoot then return math.huge end

    local me, them = r.Position, targetRoot.Position
    local flat = Vector3.new(them.X - me.X, 0, them.Z - me.Z)
    local d = flat.Magnitude
    if d < 0.05 then return d end
    local dir = flat.Unit

    local want  = math.max(CFG.StandOff or 8, 1)
    local slack = math.max(CFG.StandSlack or 2, 0.5)
    local spot  = them - dir * want

    if d > want + slack or climb then
        -- walkTo BLOCKS. It runs ComputeAsync and then sits on waypoints, and
        -- while it does that nothing swings -- which is the "it just stands
        -- there in the middle of a fight" you can see from outside. So it is
        -- only used when the target is genuinely far; anything nearer gets a
        -- plain MoveTo, which returns immediately and lets the loop keep
        -- hitting. An approach that cannot close is caught by GiveUpSeconds
        -- rather than by blocking here for twelve seconds.
        if os.clock() < pathUntil then
            -- A detour is in force. The old detour pathed once and then
            -- handed straight back to this MoveTo, which walked straight
            -- back into the same trunk. Now the approach keeps pathing for
            -- as long as the detour lasts, in short chunks so the loop still
            -- sees a kill, a nearer enemy or a stop between them.
            walkTo(them, { arrive = want + slack, budget = 1.5 })
        elseif navUsable(climb and them or spot) then
            -- The camp has been read: say where to be, and the follower
            -- runs the route every frame.
            navWant(climb and them or spot)
        elseif d > 120 then
            walkTo(spot, { arrive = want + slack, budget = 4 })
        else
            navHalt()
            local goal = climb and them or spot
            h:MoveTo(Vector3.new(goal.X, me.Y, goal.Z))
        end
        -- No body turn here. While running, the game already turns you to
        -- face where you are going, which is the enemy; writing the root
        -- CFrame on top of that only fights it mid-stride. The lock takes
        -- over once in range, where the swing needs it.
    elseif d < want - slack then
        navHalt()
        h:MoveTo(Vector3.new(spot.X, me.Y, spot.Z))
        if CFG.FaceLock then faceTarget(r, them, true) end
    else
        navHalt()
        h:MoveTo(me)                 -- stop; we are where we want to be
        faceTarget(r, them, CFG.FaceLock)
    end
    return d
end

-- =========================================================
-- TARGETING
-- =========================================================
-- Three gsubs per enemy, and the enemy list is re-read after every kill. The
-- name of a model does not change, so it is worked out once and kept.
local nameCache = {}
local function cleanName(model)
    local hit = nameCache[model]
    if hit then return hit end
    local n = (model.Name:gsub("%s*%b[]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
    nameCache[model] = n
    return n
end

local function isBlacklisted(model)
    local until_ = blacklist[model]
    if not until_ then return false end
    if os.clock() > until_ then blacklist[model] = nil return false end
    return true
end

-- ONE name, always. There is no "anything loaded" path in this build, so
-- nothing can quietly widen what gets hit.
local function liveEnemies(name)
    local folder = workspace:FindFirstChild("Enemies")
    if not folder then return {} end
    local out = {}
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") and not isBlacklisted(m) then
            local hum  = m:FindFirstChildOfClass("Humanoid")
            local root = m:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 then
                local n = cleanName(m)
                if (not name) or n == name then
                    table.insert(out, { model = m, hum = hum, root = root, name = n })
                end
            end
        end
    end
    return out
end
P.liveEnemies = liveEnemies

-- WHICH ONE NEXT.
-- WHOEVER IS NEAREST. That is the whole rule, and it is the human one.
--
-- The version before this preferred an enemy it had NOT yet worked over one
-- it had, on the theory that nearest-first would ping-pong between respawns
-- and never clear a camp. That theory was wrong for a quest farm -- a kill is
-- a kill, the quest does not care which eight -- and it produced exactly the
-- thing you watched: the one standing beside you had been "worked" (it was
-- picked once and then a swing threw it away), so the walk went straight past
-- it to a fresh one on the far side of the camp.
--
-- Now: the one standing next to you is the one you hit. A respawn that pops
-- up beside you beats the untouched one thirty studs off. The only thing that
-- beats "nearest" is "already in reach and being hit" -- see engagedModel.
local function swingReach()
    return math.max(CFG.StandOff or 8, 1) + math.max(CFG.StandSlack or 2, 0.5) * 2
end

-- How much nearer another enemy has to be before the walk turns to it.
-- Without a margin two enemies at nearly the same distance would trade the
-- target back and forth every quarter second.
local SWITCH_MARGIN = 6

local function pickNext(list, pos)
    local best, bestD = nil, math.huge
    local reach = swingReach()
    for _, e in ipairs(list) do
        local d = (e.root.Position - pos).Magnitude
        if e.model == engagedModel and d <= reach then return e, d end
        if d < bestD then best, bestD = e, d end
    end
    return best, bestD
end

function P.nearbyNames()
    local folder = workspace:FindFirstChild("Enemies")
    local counts = {}
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") then
                local hum = m:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local n = cleanName(m)
                    counts[n] = (counts[n] or 0) + 1
                end
            end
        end
    end
    return counts
end

local function levelRow()
    local lv = playerLevel()
    if not lv then return nil end
    for _, row in ipairs(LEVELS) do
        if lv >= row[1] and lv <= row[2] then return row end
    end
    return LEVELS[#LEVELS]
end
P.levelRow = levelRow

local function resolveTarget()
    if CFG.Target and #tostring(CFG.Target) > 0 then
        local name = CFG.Target
        local spot
        for _, row in ipairs(LEVELS) do
            if row[3] == name then spot = row[4] break end
        end
        return name, spot
    end
    local row = levelRow()
    if not row then return nil, nil end
    return row[3], row[4]
end

-- =========================================================
-- QUEST
-- =========================================================
local remotes = RS:FindFirstChild("Remotes")
local commF   = remotes and remotes:FindFirstChild("CommF_")

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

-- Blox Fruits puts no ClickDetector and no ProximityPrompt on a quest giver.
-- The "E Interact" ring is the game's own client-side UI. What a giver DOES
-- have is the "?" billboard reading QUEST above its head, so that is the
-- signal used here.
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
                        local low   = string.lower(m.Name)
                        local named = string.find(low, "quest", 1, true)
                                   or string.find(low, "giver", 1, true)
                        local known  = KNOWN_GIVERS[low] ~= nil
                        local marker = questMarker(m)
                        local exact  = want and (low == want)
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
                                signal = (exact and "exact name")
                                      or (known and "known giver")
                                      or (marker and "QUEST marker")
                                      or (named and "name") or "npc",
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
P.findQuestGiver = findQuestGiver

function P.questScan(range)
    findQuestGiver(range or 400)
    local out = {}
    for i, c in ipairs(P.questCandidates or {}) do
        if i > 8 then break end
        table.insert(out, string.format("%s  %.0f studs  (%s)",
            tostring(c.name), c.dist, c.signal))
    end
    if #out == 0 then return { "no NPC models in range" } end
    return out
end

-- ---------------------------------------------------------
-- READING THE TRACKER
-- ---------------------------------------------------------
-- "A GUI called Quest contains some text" is equally true of the quest BOARD
-- standing in front of you, which is why the old check reported a quest as
-- active whenever the board was on screen. The tracker has one thing nothing
-- else has: a live have/need counter beside the word Defeat.
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

local questCache, questCacheAt = nil, 0
-- The exact label the counter lives in, once we have found it once.
local questLabel = nil
P.questScans = 0        -- how many full tree walks this run has cost

-- Read one label. This is the whole job once you know WHICH label.
local function parseCounter(d)
    if not d or not d.Parent then return nil end
    local txt = d.Text
    if type(txt) ~= "string" or #txt == 0 then return nil end
    local have, need = string.match(txt, "(%d+)%s*/%s*(%d+)")
    if not (have and need) then return nil end
    if not shownOnScreen(d) then return nil end
    local blob = d.Parent and blockText(d.Parent) or string.lower(txt)
    if not (string.find(blob, "defeat", 1, true)
        or string.find(blob, "eliminate", 1, true)
        or string.find(blob, "kill", 1, true)) then return nil end
    local enemy = string.match(blob, "defeat%s+%d+%s+([%a%s\'%-]+)")
    if enemy then enemy = (enemy:gsub("%s+$", "")) end
    return {
        have = tonumber(have) or 0, need = tonumber(need) or 0,
        enemy = enemy, text = txt,
    }
end

-- WHY THIS USED TO STALL THE FARM.
-- The counter lives in one TextLabel, and that label does not move. The old
-- version walked EVERY descendant of PlayerGui to find it again on every
-- single call -- and Blox Fruits' PlayerGui is thousands of instances, each
-- TextLabel of which then cost an ancestor walk and a subtree walk on top.
-- Called once every few seconds that is invisible. Called after every kill it
-- is the pause you can watch from outside.
--
-- So the label is remembered. The fast path re-reads the one we hold, which is
-- a text compare and a pattern match. The tree is only walked again when that
-- label has actually gone -- a respawn, a UI reset, a new quest panel.
function P.readQuest(force)
    if not force and (os.clock() - questCacheAt) < 0.5 then return questCache end
    questCacheAt = os.clock()

    local fast
    pcall(function() fast = parseCounter(questLabel) end)
    if fast then
        questCache = (fast.need > 0) and fast or nil
        return questCache
    end
    questLabel = nil

    local pg = player:FindFirstChild("PlayerGui")
    if not pg then questCache = nil return nil end
    local found
    P.questScans += 1
    pcall(function()
        for _, d in ipairs(pg:GetDescendants()) do
            if d:IsA("TextLabel") and not d:FindFirstAncestor("BFPHUD") then
                local parsed = parseCounter(d)
                if parsed then
                    questLabel = d
                    found = parsed
                    return
                end
            end
        end
    end)
    questCache = (found and found.need > 0) and found or nil
    return questCache
end

function P.questActive() return P.readQuest() ~= nil end

-- After the giver is triggered a dialog appears with one button per tier.
-- Blox Fruits builds it out of ImageButtons whose caption lives in a child
-- TextLabel, not out of TextButtons, so GuiButton is what has to be scanned.
local function clickQuestDialog(wantName)
    local pg = player:FindFirstChild("PlayerGui")
    if not pg then return false end

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
        task.wait(0.25)
    end
    return false
end

-- Where the giver for this species stands: picked by hand > the table > scan.
function P.giverFor(enemy)
    enemy = enemy or activeName or CFG.Target
    if not enemy then return nil, nil end
    local name = (CFG.QuestGiverName and #CFG.QuestGiverName > 0 and CFG.QuestGiverName)
        or P.learnedGivers[enemy] or GIVER_NAMES[enemy]
    local pos = P.giverSpots[enemy] or GIVER_POS[enemy]
    return name, pos
end

function P.setGiver(pos, name)
    local e = activeName or CFG.Target
    if not e then say("pick a target first") return false end
    P.giverSpots[e] = pos
    if name then P.learnedGivers[e] = name end
    say("giver set for " .. e .. (name and (": " .. name) or ""))
    return true
end

function P.setGiverHere()
    local _, root = parts()
    if not root then return false end
    return P.setGiver(root.Position, nil)
end

function P.clearGiver()
    local e = activeName or CFG.Target
    if e then
        P.giverSpots[e] = nil
        P.learnedGivers[e] = nil
    end
    say("giver reset to the table")
end

local questTakenAt, questBaseKills, questLastHave, questMovedAt = 0, 0, 0, 0
local questBlind, lastQuestAt = false, 0

local function questForTarget()
    local enemy = activeName or CFG.Target
    if not enemy then return nil, nil, nil end
    if CFG.QuestName and #tostring(CFG.QuestName) > 0 then
        return CFG.QuestName, CFG.QuestTier or 1, enemy
    end
    local learned = P.learnedQuests[enemy]
    if learned then return learned.name, learned.tier, enemy end
    local q = QUESTS[enemy]
    if q then return q[1], q[2], enemy end
    return nil, nil, enemy
end
P.questForTarget = questForTarget

-- ONE accept attempt. The remote is the path the dialog itself uses; the
-- giver's POSITION is what the server checks, so that is what we walk to.
function P.acceptQuest(opts)
    opts = opts or {}
    if not commF then
        P.lastQuestResult = "no CommF_ remote"
        say(P.lastQuestResult)
        return false
    end
    if P.readQuest(true) and not opts.force then
        P.lastQuestResult = "already on a quest - not re-taking (that resets it)"
        say(P.lastQuestResult)
        return false
    end

    local qname, tier, enemy = questForTarget()
    local locked = P.lockedQuest
    if locked and not (CFG.QuestName and #tostring(CFG.QuestName) > 0) then
        qname, tier, enemy = locked.name, locked.tier, locked.enemy
    end
    if CFG.QuestTier then tier = CFG.QuestTier end
    tier = tier or 1
    if not qname then
        P.lastQuestResult = "no quest id known for " .. tostring(enemy or "this enemy")
        say(P.lastQuestResult)
        return false
    end

    local myEpoch = epoch
    local _, root = parts()
    local home = root and root.Position
    local atGiver = false

    -- THE WALK IS NOT ALWAYS NECESSARY, AND IT IS THE EXPENSIVE PART.
    -- Roughly 230 studs each way at Haunted Castle, for eight kills. Whether
    -- the server actually checks your distance turns out to vary, so this
    -- measures it once per species instead of assuming either way.
    local mode = CFG.GiverMode or "auto"

    local function goToGiver()
        local wantName, dest = P.giverFor(enemy)
        if not dest then
            -- Bounded on purpose: an unbounded search finds an NPC with the
            -- right name on a DIFFERENT island and walks you off the map.
            local far = CFG.QuestGiverRange or 1200
            local giver
            if wantName then
                giver = findQuestGiver(500, wantName) or findQuestGiver(far, wantName)
            end
            giver = giver or findQuestGiver(500, nil, true) or findQuestGiver(far, nil, true)
            if giver then
                dest = giver.part.Position
                P.giverName = giver.name
            end
        end
        if not dest then return true end          -- nowhere to walk; ask anyway
        atGiver = true
        setState("TO GIVER")
        say("walking to the quest giver")
        walkTo(dest, { arrive = 8, budget = 60 })
        if stale(myEpoch) then return false end
        local _, r = parts()
        if r then faceTarget(r, dest) end
        task.wait(jitter(0.4, 1.0))
        return true
    end

    -- How far the giver actually is, right now. An unknown distance means the
    -- giver still has to be found by scanning, and that is worth walking for.
    local _, gpos = P.giverFor(enemy)
    local giverDist = (gpos and root) and (gpos - root.Position).Magnitude or nil
    local mustWalk = (mode == "always")
        or (mode == "auto" and (giverDist == nil
            or giverDist <= (CFG.GiverWalkRadius or 250)))

    if mustWalk and not goToGiver() then
        P.lastQuestResult = "stopped on the way to the giver"
        say(P.lastQuestResult)
        return false
    end

    -- Last gate before the remote. Everything above this point is movement and
    -- can be abandoned freely; below it a quest actually gets taken, and taking
    -- one after STOP is exactly the surprise this guards against.
    if stale(myEpoch) then
        P.lastQuestResult = "stopped before asking - no quest taken"
        say(P.lastQuestResult)
        return false
    end

    -- ASK, THEN CHECK WHAT ARRIVED.
    -- A quest id and tier can simply be wrong, and the tracker is the only
    -- thing that knows: it names the enemy the quest actually wants.
    local mine = enemy and string.lower(tostring(enemy)) or nil
    local function wanted(trackerEnemy)
        if not trackerEnemy or not mine then return true end
        local a = string.lower(tostring(trackerEnemy))
        return string.find(a, mine, 1, true) ~= nil
            or string.find(mine, a, 1, true) ~= nil
    end

    local tiers
    if CFG.QuestTier then
        tiers = { CFG.QuestTier }
    elseif locked then
        tiers = { tier }
    else
        tiers = { tier }
        for _, t in ipairs({ 1, 2, 3 }) do
            if t ~= tier then table.insert(tiers, t) end
        end
    end

    local q, ok, res
    local function attempt()
        local gotQ, gotOk, gotRes
        for i, t in ipairs(tiers) do
            if stale(myEpoch) then break end
            gotOk, gotRes = pcall(function()
                return commF:InvokeServer("StartQuest", qname, t)
            end)
            task.wait(0.45)
            gotQ = P.readQuest(true)

            if not gotQ and atGiver and i == 1 then
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
                gotQ = P.readQuest(true)
            end

            tier = t
            if not gotQ then break end
            if wanted(gotQ.enemy) then break end
            if i == #tiers then
                say(string.format("no tier of %s asks for %s",
                    tostring(qname), tostring(enemy)))
                break
            end
            say(string.format("tier %d wants %s - trying tier %d", t,
                tostring(gotQ.enemy), tiers[i + 1]))
        end
        return gotQ, gotOk, gotRes
    end

    q, ok, res = attempt()

    -- Asked from range and got nothing back: walk up and ask once more, so a
    -- server that DOES check distance still works instead of stalling the
    -- loop. Auto only -- "never" means never, because it is your switch.
    if not q and mode == "auto" and not atGiver and not stale(myEpoch) then
        say("nothing from here - walking up and asking again")
        -- atGiver is only set once a destination was actually found and
        -- walked to. Without that guard this re-asks from the same spot, and a
        -- second StartQuest on a quest that DID start resets its count.
        local moved = goToGiver() and atGiver
        if moved then q, ok, res = attempt() end
    end

    local matched = (q ~= nil) and wanted(q.enemy)
    P.questMatched = matched
    questTakenAt   = os.clock()
    questBaseKills = stats.kills
    questLastHave  = q and q.have or 0
    questMovedAt   = os.clock()

    -- Only a quest that MATCHES gets locked. From then on the loop repeats
    -- exactly this one: same id, same tier, same giver, for as long as the
    -- target does not change.
    if q and enemy and matched then
        stats.quests += 1
        if P.giverName then P.learnedGivers[enemy] = P.giverName end
        local _, r = parts()
        if atGiver and r then P.giverSpots[enemy] = P.giverSpots[enemy] or r.Position end
        P.lockedQuest = { name = qname, tier = tier, enemy = enemy }
        P.learnedQuests[enemy] = { name = qname, tier = tier }
    end
    -- No tracker after a clean invoke means this island's tracker cannot be
    -- read, NOT that the accept failed. Re-asking would zero a running count,
    -- so from here the kills are counted locally instead.
    questBlind = (q == nil) and ok or false
    P.quest = q
    P.lastQuestResult = string.format("%s t%d -> %s", tostring(qname), tier,
        q and string.format("%s  %d/%d%s", matched and "ACTIVE" or "WRONG ENEMY",
                q.have, q.need,
                matched and "" or (", it wants " .. tostring(q.enemy)))
          or ("sent, tracker unreadable (" .. tostring(res) .. ")"))
    say(P.lastQuestResult)

    if atGiver and CFG.QuestReturnToFarm and home and not stale(myEpoch) then
        setState("TO FARM")
        say("walking back to the farm")
        walkTo(home, { arrive = 12, budget = 60 })
    end
    if P.running then
        setState("FIGHT")
        progress()
    end
    return q ~= nil or questBlind
end

function P.takeQuest() return P.acceptQuest({ force = true }) end

function P.armQuest()
    lastQuestAt   = 0
    questBlind    = false
    P.lockedQuest = nil
end

-- THE LOOP.
-- accept -> the tracker counts your kills -> it reads full -> walk back to the
-- giver -> accept the same one again. Exactly one quest running at any moment,
-- and never two accepts against one count, because a second accept is what
-- resets a running count to zero.
function P.questCycle()
    local q = P.readQuest(true)
    P.quest = q

    if q then
        questBlind = false
        P.questProgress = q.have .. "/" .. q.need
        if q.have ~= questLastHave then
            questLastHave, questMovedAt = q.have, os.clock()
        end
        if q.have < q.need then
            -- A count that never moves is a count for an enemy we are not
            -- fighting. That is the one failure the never-re-take rule can
            -- produce, so it gets a way out.
            if os.clock() - questMovedAt > (CFG.QuestStallSeconds or 240) then
                say("quest has not moved in a while - taking a fresh one")
            else
                return
            end
        elseif os.clock() - questTakenAt < 2 then
            return
        else
            say("quest done - going back for the next one")
        end
    elseif questBlind then
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
    -- refuse itself as a duplicate. Overriding is safe in exactly this case:
    -- the count is already done, so there is no progress left to reset.
    P.acceptQuest({ force = (q ~= nil) })
end

-- =========================================================
-- ESCALATION
-- =========================================================
-- Four rungs, none of which reaches for an exploit. On foot, "stuck" nearly
-- always means the thing is behind something.
local function escalate(target)
    navHalt()
    escalation = math.min(escalation + 1, 4)
    stats.escalations += 1
    lastProgressAt = os.clock()

    if escalation == 1 then
        say("stuck: re-seating on the target")
        cancelWalk()
    elseif escalation == 2 then
        say("stuck: backing off and re-pathing")
        local _, r, h = parts()
        if r and h then
            h:MoveTo(r.Position - r.CFrame.LookVector * 14)
            task.wait(0.9)
        end
    elseif escalation == 3 then
        say("stuck: putting the weapon back")
        keepWeapon()
        local _, _, h = parts()
        if h and CFG.JumpWhenStuck then h.Jump = true end
    elseif escalation == 4 then
        say("stuck: leaving this one alone")
        if target then blacklist[target.model] = os.clock() + 60 end
        setState("RESOLVE")
    end
end

-- =========================================================
-- MAIN LOOP
-- =========================================================
local function retreat()
    navHalt()
    stats.retreats += 1
    say("retreating - low health")
    setState("RETREAT")
    releaseCamera()
    local deadline = os.clock() + math.max(CFG.RegenWait, 4)
    while P.running and os.clock() < deadline do
        local _, r, h = parts()
        if not r or not h then break end
        if healthPct() > 0.9 then break end
        local away = r.Position
        local near = liveEnemies(nil)
        if #near > 0 then
            local sum = Vector3.zero
            for _, e in ipairs(near) do sum += e.root.Position end
            local threat = sum / #near
            local dir = r.Position - threat
            dir = Vector3.new(dir.X, 0, dir.Z)
            if dir.Magnitude > 0.1 then away = r.Position + dir.Unit * 70 end
        end
        h:MoveTo(away)
        task.wait(0.5)
    end
    progress()
end

-- =========================================================
-- GATHER: A PILE, WITHOUT A MAGNET
-- =========================================================
-- Worth it only when nobody is already in reach (there is a walk coming
-- either way) and at least two are close enough to tag. One next to you is
-- just fought; that is a pile of one and it is already here.
local lastGatherAt = 0
local function gatherWorth(list, pos)
    if not CFG.Gather then return false end
    if os.clock() - lastGatherAt < (CFG.GatherCooldown or 6) then return false end
    local reach  = swingReach()
    local radius = CFG.GatherRadius or 60
    local inRange = 0
    for _, e in ipairs(list) do
        local d = (e.root.Position - pos).Magnitude
        if d <= reach * 1.5 then return false end
        if d <= radius then inRange += 1 end
    end
    return inRange >= 2
end

-- Walk a nearest-neighbour route through up to GatherCount of them, one M1
-- each once in reach, and move on without waiting for the kill. Three
-- seconds per enemy at most; one that cannot be reached is skipped. Returns
-- with the character beside the last one tagged, and the rest walking in.
local function gatherPass(list)
    local _, r = parts()
    if not r or not gatherWorth(list, r.Position) then return end
    lastGatherAt = os.clock()

    local radius = CFG.GatherRadius or 60
    local pool = {}
    for _, e in ipairs(list) do
        if (e.root.Position - r.Position).Magnitude <= radius then
            table.insert(pool, e)
        end
    end
    local want  = math.max(2, math.floor(CFG.GatherCount or 3))
    local route, from = {}, r.Position
    while #route < want and #pool > 0 do
        local bi, bd = 1, math.huge
        for i, e in ipairs(pool) do
            local d = (e.root.Position - from).Magnitude
            if d < bd then bi, bd = i, d end
        end
        local e = table.remove(pool, bi)
        table.insert(route, e)
        from = e.root.Position
    end

    stats.gathers += 1
    setState("GATHER")
    say(string.format("gathering %d", #route))
    local reach   = swingReach()
    local myEpoch = epoch
    for _, e in ipairs(route) do
        local deadline = os.clock() + 3
        while os.clock() < deadline do
            if stale(myEpoch) or not P.running or not moveEnabled then return end
            if healthPct() < CFG.MinHealthPercent then return end
            if not e.model.Parent or e.hum.Health <= 0 then break end
            setChase(e.root.Position)
            local d = station(e.root)
            if d <= reach then
                if CFG.M1 then pressM1() end
                stats.swings += 1
                stats.tagged += 1
                progress()                    -- a tag is progress, not a stall
                task.wait(0.12)
                break
            end
            task.wait(0.06)
        end
    end
end

local function step()
    local _, root = parts()
    if not root then
        say("waiting for character")
        task.wait(0.5)
        return
    end

    if healthPct() < CFG.MinHealthPercent then
        retreat()
        return
    end

    -- ---------- RESOLVE ----------
    if state == "RESOLVE" or not activeName then
        local name, spot = resolveTarget()
        if not name then
            say("level unknown - pick a target on the panel")
            task.wait(1.5)
            return
        end
        activeName, farmSpot = name, spot
        engagedModel = nil
        pathUntil = 0
        say("target: " .. name)
        setState("FIGHT")
        progress()
        return
    end

    keepWeapon()
    pcall(keepHaki)

    -- ---------- THE QUEST LOOP ----------
    if CFG.QuestLoop then pcall(P.questCycle) end

    -- ---------- FIND ONE ----------
    local list = liveEnemies(activeName)

    if #list == 0 then
        releaseCamera()
        -- Nothing of the chosen species is loaded. Either walk to where it
        -- lives, or -- if we are already standing there -- wait for the
        -- respawn. It never goes looking for something else to hit.
        if farmSpot then
            local far = (farmSpot - root.Position).Magnitude
            if far < 140 then
                say(string.format("waiting for %s to respawn", activeName))
                setState("WAIT")
                -- WATCH, DO NOT SLEEP. This was one blind 1.5-3.5s sleep, so
                -- an enemy that respawned a moment in was left standing
                -- there for up to three seconds while you did nothing -- the
                -- "stops and thinks" between enemies. It looks every tenth
                -- of a second now and goes the moment one is back.
                local myEpoch = epoch
                local untilT  = os.clock() + jitter(1.5, 3.5)
                while os.clock() < untilT and P.running and not stale(myEpoch) do
                    task.wait(0.1)
                    if #liveEnemies(activeName) > 0 then break end
                end
                return
            end
            if far > (CFG.MaxWalk or 1200) then
                say(string.format("%s lives %.0f studs away - travel there yourself",
                    activeName, far))
                setState("WAIT")
                task.wait(3)
                return
            end
            setState("WALK")
            say(string.format("walking to %s  (%.0f studs)", activeName, far))
            -- Straight into the fight on arrival: no pause after the walk.
            walkTo(farmSpot, { arrive = 20, budget = 90 })
        else
            say("no idea where " .. tostring(activeName) .. " lives - walk there yourself")
            task.wait(3)
        end
        return
    end

    -- ---------- FIGHT: ONE SWEEP, NOT ONE TARGET ----------
    -- The old shape was: pick one, kill it, LEAVE the loop, rest a second, go
    -- back through resolve, re-scan, pick again. Three of those four steps are
    -- dead time, and they cost more than the fight does. This stays inside and
    -- chains: the instant one dies the next is chosen and dashed at, with no
    -- pause and no round trip through the state machine.
    setState("FIGHT")

    -- Read this camp's ground, once, in the background.
    if CFG.TerrainMap then pcall(navEnsure, list, root.Position) end

    -- Nobody in reach and a few close by: tag them first so they come to
    -- us together. Guarded, so a failure here can never stop the fight.
    if CFG.Gather then
        pcall(gatherPass, list)
        list = liveEnemies(activeName)
        if #list == 0 then return end
        setState("FIGHT")
    end

    local want     = math.max(CFG.StandOff or 8, 1)
    local slack    = math.max(CFG.StandSlack or 2, 0.5)
    local sweepEnd = os.clock() + (CFG.SweepSeconds or 10)

    local target, bestD = pickNext(list, root.Position)
    if not target then task.wait(0.3) return end
    if engagedModel ~= target.model then pathUntil = 0 end
    engagedModel = target.model
    local lastHitAt   = os.clock()     -- last time this one's health moved
    local targetSince = os.clock()     -- and when we picked it at all
    local lastHP      = target.hum.Health
    local lastLookAt  = 0              -- last time we looked for someone nearer
    local stuckSince  = nil            -- pushing against something since
    local panicked    = false          -- a burst already tried this episode
    local targetPanics = 0             -- bursts spent on this one target
    local lateralSide = nil            -- which way the sideways burst goes
    local windowAt    = nil            -- net-movement window: when it opened
    local windowPos   = nil            --   and where the character was then
    local creeping    = false          -- last window closed with no ground gained
    local targetDetours = 0            -- detours spent on this one target
    local unreachable = false          -- three detours: give it up
    local targetGhosts = 0             -- times it has gone through for this one
    local targetLearn = 0              -- map corrections spent on this one
    say(string.format("%s  %.0f studs  hp %.0f%s", target.name, bestD, lastHP,
        escalation > 0 and ("  [esc " .. escalation .. "]") or ""))

    while P.running and os.clock() < sweepEnd do
        local m    = target.model
        local hum  = target.hum
        local gone = (not m) or (not m.Parent) or (not hum) or (hum.Parent == nil)
        local dead = (not gone) and hum.Health <= 0

        if dead and not countedDead[m] then
            countedDead[m] = os.clock()
            stats.kills += 1
            progress()
            -- DO NOT READ THE GUI HERE. We already know what the quest wants
            -- -- need was captured when it was accepted -- and we are counting
            -- kills ourselves. So count, and only go and LOOK once the local
            -- count says it should be done. Seven kills out of eight now cost
            -- nothing at all, and the eighth pays for one confirmation.
            -- The look is still the authority: if the tracker disagrees (a kill
            -- that was not credited, someone else got the tag) the sweep simply
            -- carries on and asks again a kill later.
            if CFG.QuestLoop and P.quest and (P.quest.need or 0) > 0
                and (stats.kills - questBaseKills) >= P.quest.need then
                local qq = P.readQuest(true)
                if (not qq) or qq.have >= qq.need then
                    say("count is full - ending the sweep")
                    break
                end
            end
        end
        -- Nothing landing for GiveUpSeconds means it is behind something or
        -- out of reach. A fight that IS landing never expires, however slow
        -- the weapon: the clock is reset by damage, not by the wall.
        -- Only counts time spent IN RANGE. A melee swing throws these things
        -- a long way, and the walk back out to one is not the enemy being
        -- unreachable, it is the knockback doing its job -- but the clock used
        -- to run right through it and blacklist a perfectly good target.
        -- A separate, much longer ceiling stops a genuinely unreachable one
        -- being chased forever.
        local giveUp = CFG.GiveUpSeconds or 12
        local expired = (not gone) and (not dead)
            and (unreachable
                 or (os.clock() - lastHitAt) > giveUp
                 or (os.clock() - targetSince) > giveUp * 5)
        if expired then
            blacklist[m] = os.clock() + 30
            say(unreachable and "cannot get to this one - leaving it"
                or "nothing landing on this one - leaving it")
        end

        if gone or dead or expired then
            -- Only pause here if you have actually asked for a pause.
            if (CFG.RestMax or 0) > 0 then task.wait(restGap()) end
            local _, rNow = parts()
            if not rNow then break end
            list = liveEnemies(activeName)
            local nxt, nd = pickNext(list, rNow.Position)
            if not nxt then break end          -- camp is clear; step() decides
            if gatherWorth(list, rNow.Position) then break end   -- step() gathers the next pile
            target  = nxt
            engagedModel = target.model
            lastHitAt   = os.clock()
            targetSince = os.clock()
            lastHP      = target.hum.Health
            lastLookAt  = os.clock()
            stuckSince, panicked, targetPanics, lateralSide = nil, false, 0, nil
            windowAt, windowPos, creeping = nil, nil, false
            targetDetours, unreachable, pathUntil, targetGhosts = 0, false, 0, 0
            targetLearn = 0
            -- NO DASH HERE. This is the instant the new target was chosen and
            -- the character has not turned or moved yet, so a dash fired now
            -- goes wherever the body was last pointing -- at the one that just
            -- died. The closing branch below dashes once real movement toward
            -- the new target exists.
            say(string.format("%s  %.0f studs  hp %.0f", target.name, nd, lastHP))
            task.wait()                        -- one frame, so this cannot spin
            continue
        end

        local _, r, h = parts()
        if not r or not h then break end

        -- Above or below by more than a swing reaches counts as OUT of reach
        -- however close it is on the flat. The distance was flat-only, so an
        -- enemy on a ledge six studs up read as "in reach" and the character
        -- stood at the foot of the ledge swinging into its face until the
        -- give-up clock parked it. station() keeps pushing at it instead,
        -- the ray sees the ledge, and the jump takes it up.
        local dy    = math.abs(target.root.Position.Y - r.Position.Y)
        local climb = dy > 6
        setChase(target.root.Position)     -- tells the ghost how high "there" is
        local d = station(target.root, climb)
        aimCameraAt(r, target.root.Position)

        -- reach is where a swing connects. swingFrom is further out: while
        -- the target is walking back from a throw the M1 is kept going from
        -- there, so it arrives into hits already in the air. Its hitstun lands
        -- before its attack does, which is the whole point.
        local reach     = want + slack * 2
        local swingFrom = math.max(reach, CFG.SwingFrom or 0)
        local inReach   = d <= reach and not climb
        local closing   = (not inReach) and d <= swingFrom

        if inReach then
            swing()
            -- Breaks the moment it dies, or the moment it is thrown past the
            -- swing window, so the chase starts on the same frame it happens.
            swingWait(hum, target.root, swingFrom)
        else
            -- ---- SOMEBODY NEARER? Hit them instead. ----
            -- While walking to one, the list is re-read four times a second
            -- (cheap: names are cached, it is one pass over the folder) and
            -- if another is closer by a clear margin the walk turns to it. A
            -- respawn that popped up beside you beats the one thirty studs
            -- off; one that a swing threw across the camp is left to walk
            -- back on its own while you hit whoever is standing next to you.
            if os.clock() - lastLookAt > 0.25 then
                lastLookAt = os.clock()
                list = liveEnemies(activeName)
                local nxt, nd = pickNext(list, r.Position)
                if nxt and nxt.model ~= target.model then
                    local cur = (target.root.Position - r.Position).Magnitude
                    if nd + SWITCH_MARGIN < cur then
                        target = nxt
                        engagedModel = target.model
                        lastHitAt   = os.clock()
                        targetSince = os.clock()
                        lastHP      = target.hum.Health
                        stuckSince, panicked, targetPanics, lateralSide = nil, false, 0, nil
                        windowAt, windowPos, creeping = nil, nil, false
                        targetDetours, unreachable, pathUntil, targetGhosts = 0, false, 0, 0
                        targetLearn = 0
                        stats.switches += 1
                        say(string.format("%s is nearer  %.0f studs", target.name, nd))
                        task.wait()
                        continue
                    end
                end
            end

            local now   = os.clock()
            local flatT = target.root.Position - r.Position
            flatT = Vector3.new(flatT.X, 0, flatT.Z)
            local dirT  = (flatT.Magnitude > 0.5) and flatT.Unit or nil

            -- ---- SOMETHING LOW AHEAD, target on our level: one hop, now. ----
            -- A knee-height ray a few studs along the direction of travel.
            -- If the target is UP THERE this is not a hop, it is the climb,
            -- and the panic below runs at once without waiting for a clock.
            local ledge = CFG.JumpWhenStuck and now - lastJumpAt > 0.9 and ledgeAhead(r, h)
            if ledge and not climb then
                jump()
                lastJumpAt = now
                stats.hops += 1
            end

            -- ---- STUCK: PANIC. ----
            -- Two signals, because a big trunk does not look like a wall.
            --  fast: pushing and going nowhere (ground speed near zero).
            --  slow: pushing, and the last 1.2s gained under 2.5 studs of
            --        ground. That is the jitter against a trunk, the slide
            --        along its face, the orbit round it -- all of which show
            --        SPEED but no progress, so the fast signal never saw them.
            -- Stuck is a crisis and a crisis gets BIG actions, not small
            -- ones. Target above: stand still, jump, stack every air jump
            -- straight up, dash forward off the top. Target on our level:
            -- two dashes to the open side, then forward. Each burst is
            -- checked for real progress; the next is the other kind, or the
            -- other side. Four bursts and it hands over to pathfinding for
            -- eight seconds (station); three of those and the enemy is
            -- given up. Nothing here calculates what the obstacle IS beyond
            -- "is the target above me" -- it just does everything, big.
            local pushing = h.MoveDirection.Magnitude > 0.1
            local vel     = r.AssemblyLinearVelocity
            local ground  = Vector3.new(vel.X, 0, vel.Z).Magnitude
            if not pushing then
                windowAt, windowPos, creeping = nil, nil, false
            else
                if not windowAt then windowAt, windowPos = now, r.Position end
                if now - windowAt >= 1.2 then
                    local moved = r.Position - windowPos
                    creeping = Vector3.new(moved.X, 0, moved.Z).Magnitude < 2.5
                    windowAt, windowPos = now, r.Position
                end
            end
            local stuck = pushing and (ground < 1.5 or creeping)
            local ledgeUp = ledge and climb
            -- Going through already: give it the time to get out the far side
            -- instead of calling that "stuck" and firing a burst mid-trunk.
            if ghosting and now - ghostSince < 2.5 then stuck, ledgeUp = false, false end
            if stuck or ledgeUp then
                stuckSince = stuckSince or now
                local held = now - stuckSince
                if (held > 0.3 or ledgeUp) and not panicked then
                    panicked = true
                    -- THE MAP WAS WRONG HERE. Following a route the map said
                    -- was open and stuck anyway: mark that step shut and
                    -- re-plan round it, before any burst. Twice per target;
                    -- the map keeps the lesson for the next one.
                    if navFollowing() and targetLearn < 2 then
                        targetLearn += 1
                        navLearnAhead()
                        say("map was wrong here - routing round")
                        stuckSince, panicked = nil, false
                        windowAt, windowPos, creeping = nil, nil, false
                        task.wait()
                        continue
                    end
                    -- THROUGH IT. With Panic on, one legal burst gets its try
                    -- first; the moment one has failed, it goes through. With
                    -- Panic off it goes through straight away. Twice per
                    -- target, then the bursts and the pathing below as before.
                    local goThrough = CFG.Ghost and dirT and targetGhosts < 2
                        and now >= ghostQuietUntil
                        and ((not CFG.Panic) or targetPanics >= 1)
                    if goThrough then
                        targetGhosts += 1
                        ghostOn(climb and "going up and through" or "going through")
                        stuckSince, panicked = nil, false
                        windowAt, windowPos, creeping = nil, nil, false
                        task.wait()
                        continue
                    elseif CFG.Panic and dirT and targetPanics < 4 then
                        targetPanics += 1
                        stats.panics += 1
                        -- Above: climb first, then sideways. Level: sideways
                        -- first, then climb. Then the other side, then climb
                        -- again. Everything gets tried, biggest-likely first.
                        local useClimb = ((targetPanics % 2 == 1) == climb)
                        local ok
                        if useClimb then
                            say("stuck - climbing, all the jumps")
                            ok = climbBurst(target.root)
                        else
                            if lateralSide == nil then lateralSide = openSide(r, dirT) end
                            say("stuck - dashing " .. (lateralSide > 0 and "right" or "left"))
                            ok = lateralBurst(target.root, lateralSide)
                            if not ok then lateralSide = -lateralSide end
                        end
                        if ok then targetPanics = 0 end
                        stuckSince, panicked = nil, false
                        windowAt, windowPos, creeping = nil, nil, false
                        task.wait()
                        continue
                    end
                elseif panicked and held > 1.2 then
                    stuckSince, panicked = nil, false
                    windowAt, windowPos, creeping = nil, nil, false
                    targetPanics = 0                   -- the cycle can start over from wherever the path leaves us
                    targetDetours += 1
                    stats.detours += 1
                    if targetDetours >= 3 then
                        unreachable = true     -- the top of the loop parks it
                    else
                        say("blocked - pathing round it")
                        pathUntil = now + 8
                    end
                    task.wait()
                    continue
                end
            else
                stuckSince, panicked = nil, false
            end

            -- ---- DASH, then the closing M1 -- never both on one pass. ----
            -- No dash while the target is above or below (a dash at a ledge
            -- face is the wrong tool; the climb is the tool), none while
            -- stuck, and none just after a jump -- in the air it goes
            -- anywhere. The panic bursts dash on their own terms.
            -- A swing started on top of the dash cuts the dash short.
            local noDash = climb or (stuckSince ~= nil) or (now - lastJumpAt < 1.2)
                or (navFollowing() and navPath ~= nil and #navPath > 2)
            local dashed = (not noDash)
                and tryDash(d, target.root.Position - r.Position) or false

            -- ---- CLOSING: keep the M1 running. ----
            -- M1 only. Skills stay on their in-reach cadence; burning one at
            -- an enemy twenty studs out is what "wasting the special" is.
            if closing and CFG.M1 and not dashed then
                stats.swings += 1
                pressM1()
            end
            progress()                -- walking is not stalling
            lastHitAt = os.clock()    -- nor is chasing one that was knocked away
            if closing then
                -- The swing gap is the pace now, same as in reach. It still
                -- breaks the instant the target dies or is thrown out past
                -- the window.
                swingWait(hum, target.root, swingFrom)
            else
                task.wait(0.06)
            end
        end

        if hum.Health < lastHP - 0.5 then
            stats.damaging += 1
            lastHitAt = os.clock()     -- it is working; do not time this out
            progress()
        end
        lastHP = hum.Health
    end
    -- The sweep ended with this one still alive (count filled, or the clock
    -- ran out). Leave it flagged: if it is still in reach when the next pass
    -- starts it is picked straight back up rather than swapped for one a
    -- stud closer. If it has been thrown out of reach, nearest wins.
    if target and target.hum and target.hum.Health > 0 then
        engagedModel = target.model
    else
        engagedModel = nil
    end

    if math.random() < 0.02 then
        local now = os.clock()
        for model, t in pairs(countedDead) do
            if now - t > 120 then countedDead[model] = nil end
        end
        -- Anything that has left the world can go; keeping destroyed models as
        -- keys forever is a leak, and they can never match a respawn anyway.
        for model in pairs(nameCache) do
            if not model.Parent then nameCache[model] = nil end
        end
    end

    if os.clock() - lastProgressAt > CFG.StuckSeconds then
        escalate(target)
    end
end

local mainGen, dogGen = 0, 0

local function mainLoop()
    mainGen += 1
    local gen = mainGen
    while P.running and gen == mainGen do
        local ok, err = pcall(step)
        if not ok then
            log("step error: " .. tostring(err))
            say("recovered from an error")
            task.wait(0.6)
        end
        task.wait(0.05)
    end
end

local function watchdog()
    dogGen += 1
    local gen = dogGen
    local lastSeen, lastSwings = os.clock(), stats.swings
    while P.running and gen == dogGen do
        task.wait(5)
        if stats.swings ~= lastSwings then
            lastSwings = stats.swings
            lastSeen = os.clock()
        elseif os.clock() - lastSeen > 90 and state == "FIGHT" then
            say("watchdog: nothing hit in a while - re-resolving")
            escalation = 0
            setState("RESOLVE")
            lastSeen = os.clock()
        end
    end
end

-- =========================================================
-- UI
-- =========================================================
-- EVERY MODE ON THIS PANEL IS A SWITCH THAT READS On OR Off.
-- The old panel had rows you tapped and then had to guess about: did that do
-- anything, is it on now? A switch answers both without being pressed. The
-- only momentary controls left are the ones that genuinely happen once, and
-- each writes what it did into a line that stays on screen.
--
-- Nothing here turns anything else off. Target, weapon, distance, which keys
-- get pressed, how fast: separate decisions, none of which cancels another.
local gui
local function buildUI()
    local pg = player:WaitForChild("PlayerGui", 10)
    if not pg then return end
    local old = pg:FindFirstChild("BFPHUD")
    if old then old:Destroy() end

    local UIS = game:GetService("UserInputService")

    local C = {
        base    = Color3.fromRGB(18, 17, 16),
        raised  = Color3.fromRGB(31, 29, 27),
        pressed = Color3.fromRGB(42, 39, 36),
        hair    = Color3.fromRGB(53, 50, 46),
        text    = Color3.fromRGB(242, 239, 234),
        second  = Color3.fromRGB(154, 149, 141),
        third   = Color3.fromRGB(107, 102, 95),
        ivory   = Color3.fromRGB(232, 224, 212),
        live    = Color3.fromRGB(63, 208, 126),
        warn    = Color3.fromRGB(240, 166, 60),
        stop    = Color3.fromRGB(232, 92, 78),
    }
    local F = { tiny = 11, small = 13, body = 14, label = 15, subject = 21 }

    local function mk(class, props)
        local o = Instance.new(class)
        local parent = props.Parent
        props.Parent = nil
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end
    local function corner(o, r)
        mk("UICorner", { CornerRadius = UDim.new(0, r), Parent = o })
        return o
    end
    local EASE  = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    local QUICK = TweenInfo.new(0.11, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    local function tween(o, props, info)
        TweenService:Create(o, info or EASE, props):Play()
    end

    gui = mk("ScreenGui", {
        Name = "BFPHUD", ResetOnSpawn = false, IgnoreGuiInset = true,
        DisplayOrder = 45, Parent = pg,
    })

    local panel = mk("Frame", {
        Size = UDim2.fromOffset(342, 492),
        Position = UDim2.new(1, -360, 0, 18),
        BackgroundColor3 = C.base, BorderSizePixel = 0,
        Active = true, Draggable = true, Parent = gui,
    })
    corner(panel, 20)
    mk("UIStroke", { Color = C.hair, Transparency = 0.45, Parent = panel })
    mk("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.94),
            NumberSequenceKeypoint.new(0.35, 1),
            NumberSequenceKeypoint.new(1, 1),
        }),
        Color = ColorSequence.new(Color3.fromRGB(255, 245, 230)),
        Parent = panel,
    })

    local backBtn = mk("TextButton", {
        Size = UDim2.fromOffset(54, 30), Position = UDim2.fromOffset(14, 14),
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = C.second, Text = "Back", Visible = false,
        AutoButtonColor = false, Parent = panel,
    })
    local heading = mk("TextLabel", {
        Size = UDim2.new(1, -104, 0, 22), Position = UDim2.fromOffset(20, 18),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
        TextSize = F.label, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = C.text, Text = "Farm Pro", Parent = panel,
    })
    local dot = mk("Frame", {
        Size = UDim2.fromOffset(7, 7), Position = UDim2.new(1, -62, 0, 26),
        BackgroundColor3 = C.third, BorderSizePixel = 0, Parent = panel,
    })
    corner(dot, 4)
    local foldBtn = mk("TextButton", {
        Size = UDim2.fromOffset(42, 30), Position = UDim2.new(1, -52, 0, 14),
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextColor3 = C.second, Text = "Hide", AutoButtonColor = false, Parent = panel,
    })

    local bodyFrame = mk("Frame", {
        Size = UDim2.new(1, 0, 1, -52), Position = UDim2.fromOffset(0, 52),
        BackgroundTransparency = 1, ClipsDescendants = true, Parent = panel,
    })

    local folded = false
    foldBtn.Activated:Connect(function()
        folded = not folded
        bodyFrame.Visible = not folded
        foldBtn.Text = folded and "Show" or "Hide"
        tween(panel, { Size = UDim2.fromOffset(342, folded and 52 or 492) })
    end)

    local live = {}
    local buildingView = nil
    local function addLive(fn) table.insert(live, { v = buildingView, f = fn }) end

    local views = {}
    local currentView = "home"

    local function makeView(name)
        local v = mk("ScrollingFrame", {
            Name = name,
            Size = UDim2.fromScale(1, 1), Position = UDim2.fromScale(1, 0),
            BackgroundTransparency = 1, BorderSizePixel = 0,
            ScrollBarThickness = 2, ScrollBarImageColor3 = C.hair,
            CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false, Parent = bodyFrame,
        })
        mk("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            HorizontalAlignment = Enum.HorizontalAlignment.Center, Parent = v,
        })
        mk("UIPadding", { PaddingBottom = UDim.new(0, 16), Parent = v })
        views[name] = v
        buildingView = v
        return v
    end

    local TITLES = {
        home = "Farm Pro", target = "Target", weapon = "Weapon",
        attack = "Attack", speed = "Speed", quest = "Quest loop", stats = "Stats",
    }

    local function show(name, back)
        if name == currentView then return end
        local from, to = views[currentView], views[name]
        if not to then return end
        to.Position = UDim2.fromScale(back and -1 or 1, 0)
        to.Visible = true
        tween(to, { Position = UDim2.fromScale(0, 0) })
        if from then
            tween(from, { Position = UDim2.fromScale(back and 1 or -1, 0) })
            task.delay(0.24, function()
                if currentView ~= from.Name then from.Visible = false end
            end)
        end
        currentView = name
        heading.Text = TITLES[name] or name
        heading.Position = UDim2.fromOffset(name == "home" and 20 or 76, 18)
        backBtn.Visible = (name ~= "home")
    end
    backBtn.Activated:Connect(function() show("home", true) end)

    -- =====================================================
    -- PIECES
    -- =====================================================
    local order = 0
    local function nextOrder() order += 1 return order end

    local function gap(view, h)
        mk("Frame", {
            Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = view,
        })
    end

    local function heading2(view, text)
        local t = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium, TextSize = F.tiny,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.third,
            Text = string.upper(text), LayoutOrder = nextOrder(), Parent = view,
        })
        mk("UIPadding", { PaddingLeft = UDim.new(0, 20), Parent = t })
        return t
    end

    local function hairline(view)
        local holder = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 1), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = view,
        })
        mk("Frame", {
            Size = UDim2.new(1, -20, 0, 1), Position = UDim2.fromOffset(20, 0),
            BackgroundColor3 = C.hair, BackgroundTransparency = 0.5,
            BorderSizePixel = 0, Parent = holder,
        })
        return holder
    end

    local function pressable(btn)
        local base = btn.BackgroundColor3
        btn.MouseButton1Down:Connect(function()
            tween(btn, { BackgroundColor3 = C.pressed }, QUICK)
        end)
        local function release() tween(btn, { BackgroundColor3 = base }, QUICK) end
        btn.MouseButton1Up:Connect(release)
        btn.MouseLeave:Connect(release)
        return btn
    end

    local function caption(view, text)
        local t = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = F.small,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.third,
            TextWrapped = true, Text = text, LayoutOrder = nextOrder(), Parent = view,
        })
        mk("UIPadding", {
            PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 20), Parent = t,
        })
        gap(view, 6)
        return t
    end

    -- A line that reports what the last action actually did, and keeps
    -- reporting it. This is what a momentary button owes you.
    local function readout(view, fn)
        local t = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = F.small,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.second,
            TextWrapped = true, Text = "", LayoutOrder = nextOrder(), Parent = view,
        })
        mk("UIPadding", {
            PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 20), Parent = t,
        })
        gap(view, 8)
        addLive(function()
            local ok, v = pcall(fn)
            t.Text = ok and tostring(v or "") or ""
        end)
        return t
    end

    local function navRow(view, label, valueFn, target)
        local b = mk("TextButton", {
            Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = C.base,
            BorderSizePixel = 0, Text = "", AutoButtonColor = false,
            LayoutOrder = nextOrder(), Parent = view,
        })
        mk("TextLabel", {
            Size = UDim2.new(0, 116, 1, 0), Position = UDim2.fromOffset(20, 0),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
            TextSize = F.label, TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = C.text, Text = label, Parent = b,
        })
        local val = mk("TextLabel", {
            Size = UDim2.new(1, -176, 1, 0), Position = UDim2.fromOffset(136, 0),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham,
            TextSize = F.body, TextXAlignment = Enum.TextXAlignment.Right,
            TextColor3 = C.second, TextTruncate = Enum.TextTruncate.AtEnd,
            Text = "", Parent = b,
        })
        mk("TextLabel", {
            Size = UDim2.fromOffset(20, 48), Position = UDim2.new(1, -28, 0, 0),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham,
            TextSize = 14, TextColor3 = C.third, Text = ">", Parent = b,
        })
        pressable(b)
        b.Activated:Connect(function() show(target) end)
        if valueFn then
            addLive(function()
                local ok, v = pcall(valueFn)
                val.Text = ok and tostring(v) or ""
            end)
        end
        return b
    end

    -- THE SWITCH.
    -- Pill, knob, AND the word. The word is the point: a pill on its own still
    -- asks you to remember which side means on.
    local function switchRow(view, label, sub, get, set)
        local h = sub and 60 or 48
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = view,
        })
        mk("TextLabel", {
            Size = UDim2.new(1, -132, 0, 20),
            Position = UDim2.fromOffset(20, sub and 9 or 14),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
            TextSize = F.label, TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = C.text, Text = label, Parent = f,
        })
        if sub then
            mk("TextLabel", {
                Size = UDim2.new(1, -132, 0, 16), Position = UDim2.fromOffset(20, 30),
                BackgroundTransparency = 1, Font = Enum.Font.Gotham,
                TextSize = F.small, TextXAlignment = Enum.TextXAlignment.Left,
                TextColor3 = C.third, Text = sub, Parent = f,
            })
        end
        local word = mk("TextLabel", {
            Size = UDim2.fromOffset(30, 20),
            Position = UDim2.new(1, -106, 0, (h - 20) / 2),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
            TextSize = F.small, TextXAlignment = Enum.TextXAlignment.Right,
            TextColor3 = C.third, Text = "Off", Parent = f,
        })
        local pill = mk("TextButton", {
            Size = UDim2.fromOffset(46, 27),
            Position = UDim2.new(1, -66, 0, (h - 27) / 2),
            BackgroundColor3 = C.hair, Text = "", AutoButtonColor = false, Parent = f,
        })
        corner(pill, 13)
        local knob = mk("Frame", {
            Size = UDim2.fromOffset(23, 23), Position = UDim2.fromOffset(2, 2),
            BackgroundColor3 = C.text, BorderSizePixel = 0, Parent = pill,
        })
        corner(knob, 11)
        local function redraw()
            local on = get() and true or false
            tween(pill, { BackgroundColor3 = on and C.live or C.hair }, QUICK)
            tween(knob, { Position = UDim2.fromOffset(on and 21 or 2, 2) }, QUICK)
            word.Text = on and "On" or "Off"
            word.TextColor3 = on and C.live or C.third
        end
        pill.Activated:Connect(function() set(not get()) redraw() end)
        addLive(redraw)
        redraw()
        return f
    end

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

    local function sliderRow(view, label, minV, maxV, stepV, get, set, unit)
        local f = mk("TextButton", {
            Size = UDim2.new(1, 0, 0, 62), BackgroundTransparency = 1,
            Text = "", AutoButtonColor = false,
            LayoutOrder = nextOrder(), Parent = view,
        })
        mk("TextLabel", {
            Size = UDim2.new(1, -130, 0, 20), Position = UDim2.fromOffset(20, 10),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
            TextSize = F.label, TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = C.text, Text = label, Parent = f,
        })
        local val = mk("TextLabel", {
            Size = UDim2.fromOffset(110, 20), Position = UDim2.new(1, -130, 0, 10),
            BackgroundTransparency = 1, Font = Enum.Font.Code,
            TextSize = F.body, TextXAlignment = Enum.TextXAlignment.Right,
            TextColor3 = C.second, Text = "", Parent = f,
        })
        local track = mk("Frame", {
            Size = UDim2.new(1, -40, 0, 4), Position = UDim2.fromOffset(20, 42),
            BackgroundColor3 = C.hair, BorderSizePixel = 0, Parent = f,
        })
        corner(track, 2)
        local fill = mk("Frame", {
            Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.ivory,
            BorderSizePixel = 0, Parent = track,
        })
        corner(fill, 2)
        local knob = mk("Frame", {
            Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = C.ivory,
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
            local v = math.clamp(math.floor((minV + a * (maxV - minV)) / stepV + 0.5) * stepV,
                minV, maxV)
            if stepV < 1 then v = tonumber(string.format("%.2f", v)) end
            set(v)
            redraw()
        end
        f.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                dragTarget = apply
                tween(knob, { Size = UDim2.fromOffset(20, 20) }, QUICK)
                apply(i.Position.X)
            end
        end)
        f.InputEnded:Connect(function()
            tween(knob, { Size = UDim2.fromOffset(16, 16) }, QUICK)
        end)
        addLive(redraw)
        redraw()
        return f
    end

    local function actionRow(view, label, tone, cb)
        local b = mk("TextButton", {
            Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = C.base,
            BorderSizePixel = 0, Font = Enum.Font.GothamMedium, TextSize = F.label,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = (tone == "danger") and C.stop or C.ivory, Text = label,
            AutoButtonColor = false, LayoutOrder = nextOrder(), Parent = view,
        })
        mk("UIPadding", { PaddingLeft = UDim.new(0, 20), Parent = b })
        pressable(b)
        b.Activated:Connect(function() task.spawn(function() pcall(cb, b) end) end)
        return b
    end

    local function textRow(view, placeholder, cb)
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1,
            LayoutOrder = nextOrder(), Parent = view,
        })
        local tb = mk("TextBox", {
            Size = UDim2.new(1, -40, 0, 36), Position = UDim2.fromOffset(20, 8),
            BackgroundColor3 = C.raised, BorderSizePixel = 0,
            ClearTextOnFocus = false, Font = Enum.Font.Gotham, TextSize = F.body,
            TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left,
            PlaceholderText = placeholder, PlaceholderColor3 = C.third,
            Text = "", Parent = f,
        })
        corner(tb, 10)
        mk("UIPadding", { PaddingLeft = UDim.new(0, 12), Parent = tb })
        tb.FocusLost:Connect(function(enter)
            if enter then
                pcall(cb, (tb.Text:gsub("^%s+", ""):gsub("%s+$", "")), tb)
            end
        end)
        return tb
    end

    -- A LIST YOU PICK ONE THING FROM.
    -- Radio, not a cycle. Tapping a row selects it; the selected row is filled
    -- ivory and carries a tick. There is no second tap that means something
    -- else, because that is the state you cannot see.
    local function chooser(view, height)
        local box = mk("ScrollingFrame", {
            Size = UDim2.new(1, 0, 0, height), BackgroundTransparency = 1,
            BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = C.hair,
            CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
            LayoutOrder = nextOrder(), Parent = view,
        })
        mk("UIListLayout", { Padding = UDim.new(0, 3), Parent = box })
        mk("UIPadding", {
            PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 20), Parent = box,
        })
        gap(view, 10)
        return box
    end

    local function chooserRow(box, i, label, tag, chosen, cb)
        local b = mk("TextButton", {
            Size = UDim2.new(1, 0, 0, 38),
            BackgroundColor3 = chosen and C.ivory or C.raised,
            BackgroundTransparency = chosen and 0 or 0.35, BorderSizePixel = 0,
            Font = chosen and Enum.Font.GothamBold or Enum.Font.Gotham,
            TextSize = F.body, TextColor3 = chosen and C.base or C.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = (chosen and "  > " or "      ") .. label,
            AutoButtonColor = false, LayoutOrder = i, Parent = box,
        })
        corner(b, 9)
        if tag and tag ~= "" then
            mk("TextLabel", {
                Size = UDim2.fromOffset(104, 38), Position = UDim2.new(1, -114, 0, 0),
                TextTruncate = Enum.TextTruncate.AtEnd,
                BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
                TextSize = F.small, TextXAlignment = Enum.TextXAlignment.Right,
                TextColor3 = chosen and C.base or C.third, Text = tag, Parent = b,
            })
        end
        if not chosen then pressable(b) end
        b.Activated:Connect(function() pcall(cb) end)
        return b
    end

    -- =====================================================
    -- HOME
    -- =====================================================
    do
        local v = makeView("home")
        v.Visible = true
        v.Position = UDim2.fromScale(0, 0)
        gap(v, 4)

        local subject = mk("TextLabel", {
            Size = UDim2.new(1, -40, 0, 26), BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold, TextSize = F.subject,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.text,
            TextTruncate = Enum.TextTruncate.AtEnd, Text = "Idle",
            LayoutOrder = nextOrder(), Parent = v,
        })
        mk("UIPadding", { PaddingLeft = UDim.new(0, 20), Parent = subject })

        local detail = mk("TextLabel", {
            Size = UDim2.new(1, -40, 0, 18), BackgroundTransparency = 1,
            Font = Enum.Font.Gotham, TextSize = F.small,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.second,
            TextTruncate = Enum.TextTruncate.AtEnd, Text = "",
            LayoutOrder = nextOrder(), Parent = v,
        })
        mk("UIPadding", { PaddingLeft = UDim.new(0, 20), Parent = detail })

        addLive(function()
            if P.running then
                subject.Text = tostring(activeName or "Farming")
                local mins = math.max((os.clock() - stats.startedAt) / 60, 1 / 60)
                detail.Text = string.format("%s  ·  %d kills  ·  %.0f/min  ·  %s",
                    state, stats.kills, stats.kills / mins, statusLine)
            else
                subject.Text = "Idle"
                detail.Text = statusLine
            end
        end)

        gap(v, 14)

        local hero = mk("TextButton", {
            Size = UDim2.new(1, -40, 0, 52), BackgroundColor3 = C.ivory,
            BorderSizePixel = 0, Font = Enum.Font.GothamBold, TextSize = 16,
            TextColor3 = C.base, Text = "Start", AutoButtonColor = false,
            LayoutOrder = nextOrder(), Parent = v,
        })
        corner(hero, 14)
        hero.Activated:Connect(function()
            if P.running then P.stop() else P.start() end
        end)
        hero.MouseButton1Down:Connect(function()
            tween(hero, { Size = UDim2.new(1, -46, 0, 50) }, QUICK)
        end)
        local function heroUp() tween(hero, { Size = UDim2.new(1, -40, 0, 52) }, QUICK) end
        hero.MouseButton1Up:Connect(heroUp)
        hero.MouseLeave:Connect(heroUp)
        addLive(function()
            hero.Text = P.running and "Stop" or "Start"
            hero.BackgroundColor3 = P.running and C.stop or C.ivory
            hero.TextColor3 = P.running and C.text or C.base
        end)

        gap(v, 16)

        -- The loop switch lives on the front page, because it is the thing you
        -- came here to leave running.
        switchRow(v, "Quest loop",
            "Take it, kill the count, walk back, take it again",
            function() return CFG.QuestLoop end,
            function(x)
                CFG.QuestLoop = x
                if x then P.armQuest() end
                say(x and "quest loop on" or "quest loop off")
            end)

        gap(v, 8)

        navRow(v, "Target", function()
            return CFG.Target or ((activeName and (activeName .. "  by level")) or "by level")
        end, "target")
        hairline(v)
        navRow(v, "Weapon", function()
            if CFG.Weapon and #CFG.Weapon > 0 then return CFG.Weapon .. "  locked" end
            return (P.heldTool() or "none") .. "  free"
        end, "weapon")
        hairline(v)
        navRow(v, "Attack", function()
            local bits = {}
            if CFG.M1 then table.insert(bits, "M1") end
            local n = P.activeSkillCount()
            if n > 0 then table.insert(bits, n .. " skill" .. (n > 1 and "s" or "")) end
            if #bits == 0 then return "nothing on" end
            return table.concat(bits, " + ") .. "  ·  " .. math.floor(CFG.StandOff) .. " studs"
        end, "attack")
        hairline(v)
        navRow(v, "Speed", function()
            local bits = { string.format("%.2f-%.2fs", CFG.SwingMin, CFG.SwingMax) }
            if CFG.FastAttack then table.insert(bits, "fast") end
            return table.concat(bits, "  ·  ")
        end, "speed")
        hairline(v)
        navRow(v, "Quest", function()
            if not CFG.QuestLoop then return "Off" end
            local q = P.readQuest()
            if q then return q.have .. " / " .. q.need end
            return tostring(P.questProgress or "waiting")
        end, "quest")
        hairline(v)
        navRow(v, "Stats", function() return stats.kills .. " killed" end, "stats")

        gap(v, 10)
    end

    -- =====================================================
    -- TARGET
    -- =====================================================
    do
        local v = makeView("target")
        gap(v, 6)
        heading2(v, "one species, and only that one")
        caption(v, "Whatever is ticked here is the only thing the farm will "
            .. "ever walk to or hit. There is no backup list and no \"anything "
            .. "loaded\" fallback in this build: if none are alive it stands "
            .. "and waits for the respawn.")

        local box = chooser(v, 176)
        local signature = nil
        local function refresh()
            local counts = P.nearbyNames()
            local names = {}
            for n in pairs(counts) do table.insert(names, n) end
            local row = levelRow()
            if row and not counts[row[3]] then table.insert(names, row[3]) end
            if CFG.Target and not counts[CFG.Target] then
                local dup = false
                for _, n in ipairs(names) do if n == CFG.Target then dup = true end end
                if not dup then table.insert(names, CFG.Target) end
            end
            table.sort(names)

            local sig = tostring(CFG.Target) .. "|"
            for _, n in ipairs(names) do sig = sig .. n .. (counts[n] or 0) .. "," end
            if sig == signature then return end
            signature = sig

            for _, c in ipairs(box:GetChildren()) do
                if c:IsA("GuiObject") then c:Destroy() end
            end

            chooserRow(box, 1, "By my level", row and row[3] or "unknown",
                CFG.Target == nil, function()
                    CFG.Target = nil
                    activeName = nil
                    P.lockedQuest = nil
                    setState("RESOLVE")
                    say("target: by level")
                end)

            for i, n in ipairs(names) do
                local c = counts[n]
                chooserRow(box, i + 1, n, c and (c .. " alive") or "not loaded",
                    CFG.Target == n, function()
                        CFG.Target = n
                        activeName = nil
                        P.lockedQuest = nil
                        setState("RESOLVE")
                        say("target: " .. n)
                    end)
            end
        end
        refresh()
        addLive(refresh)

        heading2(v, "or type the name")
        textRow(v, "Demonic Soul", function(val)
            if #val == 0 then return end
            CFG.Target = val
            activeName = nil
            P.lockedQuest = nil
            setState("RESOLVE")
            say("target: " .. val)
            signature = nil
        end)

        sliderRow(v, "Walk this far to reach it", 200, 3000, 100,
            function() return CFG.MaxWalk end,
            function(x) CFG.MaxWalk = x end, " studs")
        caption(v, "Further than this and it stops and tells you, rather than "
            .. "setting off across the map on its own.")
    end

    -- =====================================================
    -- WEAPON
    -- =====================================================
    do
        local v = makeView("weapon")
        gap(v, 6)
        heading2(v, "what it swings")
        caption(v, "Nothing here is automatic. With nothing picked the farm "
            .. "never touches your hands. Pick one and it is a LOCK: if the "
            .. "game equips something else, yours goes straight back, and it "
            .. "will not change on its own for any reason.")

        local box = chooser(v, 200)
        local signature = nil
        local function refresh()
            local names = toolNames()
            local held = P.heldTool()
            local sig = tostring(CFG.Weapon) .. "|" .. tostring(held) .. "|"
                .. table.concat(names, ",")
            if sig == signature then return end
            signature = sig

            for _, c in ipairs(box:GetChildren()) do
                if c:IsA("GuiObject") then c:Destroy() end
            end

            chooserRow(box, 1, "Whatever I am holding", held or "empty hands",
                (CFG.Weapon == nil or CFG.Weapon == ""), function()
                    CFG.Weapon = nil
                    say("weapon: free")
                end)

            for i, n in ipairs(names) do
                chooserRow(box, i + 1, n, (held == n) and "in hand" or "",
                    CFG.Weapon == n, function()
                        CFG.Weapon = n
                        keepWeapon()
                        say("weapon locked: " .. n)
                    end)
            end
        end
        refresh()
        addLive(refresh)

        readout(v, function()
            if CFG.Weapon and #CFG.Weapon > 0 then
                local held = P.heldTool()
                if held == CFG.Weapon then
                    return "LOCKED to " .. CFG.Weapon .. ", and it is in hand."
                end
                return "LOCKED to " .. CFG.Weapon .. " - not in hand, putting it back."
            end
            return "Free. Holding " .. tostring(P.heldTool() or "nothing")
                .. ". Nothing will change it."
        end)

        gap(v, 8)
        heading2(v, "after a death")
        switchRow(v, "Enhancement (J) - keep it on",
            "Checked every pass; J is pressed when the character lacks it",
            function() return CFG.AutoBuso end,
            function(x) CFG.AutoBuso = x end)
        switchRow(v, "Observation (E) - keep it on",
            "Checked after a death and on a timer; E only when it is off",
            function() return CFG.AutoKen end,
            function(x) CFG.AutoKen = x end)
        sliderRow(v, "Check Observation every", 1, 15, 1,
            function() return (CFG.KenEvery or 300) / 60 end,
            function(x)
                CFG.KenEvery = x * 60
                kenNextAt = math.min(kenNextAt, os.clock() + CFG.KenEvery)
            end, " min")
        readout(v, function()
            local lines = {}
            table.insert(lines, "Held now: " .. tostring(P.heldTool() or "nothing")
                .. ".  Remembered for a respawn: " .. tostring(P.lastHeld or "nothing yet") .. ".")
            if CFG.AutoBuso then
                table.insert(lines, hasBuso()
                    and "Enhancement: ON (the character carries HasBuso)."
                    or  "Enhancement: OFF - pressing J, up to 3 tries per life.")
            else
                table.insert(lines, "Enhancement: not managed.")
            end
            if CFG.AutoKen then
                local on = kenOn()
                table.insert(lines, "Observation now: "
                    .. (on == true and "ON (dodge counter showing)"
                        or on == false and "OFF (no dodge counter)"
                        or "cannot tell (no PlayerGui.ScreenGui)")
                    .. string.format(".  Next look in %d:%02d.",
                        math.floor(P.kenNextIn() / 60), math.floor(P.kenNextIn() % 60)))
                table.insert(lines, "Last: " .. tostring(P.kenNote))
            else
                table.insert(lines, "Observation: not managed.")
            end
            return table.concat(lines, "\n")
        end)
        caption(v, "E is a toggle, so it is pressed only when the dodge "
            .. "counter is gone - it can never turn an Observation that is on "
            .. "off. It is looked at on the timer above and after every death. "
            .. "If 'Observation now' says OFF while you can see your dodges, "
            .. "the marker is wrong: after two presses that do not bring it "
            .. "up (so E ends where it started) the timer stops pressing and "
            .. "says so under Last. If the Enhancement line says OFF while "
            .. "you can see it is on, that marker is wrong - tell me.")
    end

    -- =====================================================
    -- ATTACK
    -- =====================================================
    do
        local v = makeView("attack")
        gap(v, 6)
        heading2(v, "distance")
        sliderRow(v, "Keep the enemy at", 2, 40, 1,
            function() return CFG.StandOff end,
            function(x) CFG.StandOff = x end, " studs")
        caption(v, "Who it hits: whoever is nearest, always. While walking to "
            .. "one it keeps looking, and if another is clearly nearer it "
            .. "turns to that one - a respawn beside you beats the untouched "
            .. "one across the camp. The only thing that beats nearest is the "
            .. "one already inside this distance and being hit. A low step "
            .. "ahead gets a hop before it is hit. STUCK IS A CRISIS and it "
            .. "gets big actions: enemy above you - stand still, jump, stack "
            .. "every air jump straight up, dash forward off the top. Enemy "
            .. "on your level - two dashes to the open side, then forward. "
            .. "Each burst is checked for real progress; the next is the "
            .. "other kind or the other side. Four bursts and it hands over "
            .. "to pathfinding for eight seconds; three of those and the "
            .. "enemy is left alone. An enemy up on a ledge counts as out of "
            .. "reach, so it climbs to it instead of swinging into the wall.")

        switchRow(v, "Read the ground first",
            "Map the camp once; route round walls, jump before edges",
            function() return CFG.TerrainMap end,
            function(x)
                CFG.TerrainMap = x
                if not x then navHalt() end
            end)
        readout(v, function()
            local line
            if navBuilding then
                line = string.format("Reading the ground: %d%%",
                    math.floor(100 * navBuilding.done / math.max(navBuilding.total, 1)))
            elseif navMap then
                line = string.format("Map ready: %dx%d cells, %d studs each. "
                    .. "%d steps learned shut.", navMap.n, navMap.n, navMap.C, navMap.learned)
            else
                line = "No map yet - it is read when a camp is reached."
            end
            local route = "no route"
            if navPath and navGoal then
                local j = 0
                for _, nd in ipairs(navPath) do if nd.jump then j += 1 end end
                route = string.format("route %d points, %d jumps%s", #navPath, j,
                    navReached and "" or ", no way all the way in")
            end
            return line .. "\n" .. route .. string.format(".  Plans %d, jumps %d, learned %d.",
                stats.navPlans, stats.navJumps, stats.navLearned)
        end)
        caption(v, "A camp does not move, so its ground is read once when you "
            .. "get there - floor heights, walls, trunks, logs at the knee - "
            .. "over about a second, and never scanned again. Every run to an "
            .. "enemy is then planned on that map: round what is too tall, "
            .. "over what your own jump clears, a little off walls so your "
            .. "shoulders do not catch. It is steered every frame and the jump "
            .. "is pressed BEFORE the edge, as far ahead as your speed carries "
            .. "you while the jump rises. If you still get stuck where the map "
            .. "said it was open, that step is marked shut and it routes round; "
            .. "only then do the bursts and the walk-through get a turn.")

        switchRow(v, "Walk through it when stuck",
            "Collisions off until clear; lifted onto higher ground",
            function() return CFG.Ghost end,
            function(x)
                CFG.Ghost = x
                if not x then pcall(ghostRelease) end
            end)
        sliderRow(v, "Blocked for", 0.5, 5, 0.5,
            function() return CFG.GhostAfter end,
            function(x) CFG.GhostAfter = x end, " s")
        readout(v, function()
            local on, why = P.ghosting()
            return (on and ("Going through now - " .. tostring(why)) or "Solid.")
                .. "  Gone through " .. stats.ghosts .. " times, lifted "
                .. stats.lifts .. "."
        end)
        caption(v, "The farm walks, the quest walk, the gather and the fight "
            .. "are all watched the same way: asked to move and gaining no "
            .. "ground for this long, and the character's collisions go off. "
            .. "It walks straight through the trunk or the wall, still "
            .. "standing on the floor. If where it is going is higher - a "
            .. "ledge, higher land - it is kicked up to that height as well. "
            .. "Collisions come back only once it is clear of everything "
            .. "solid. In a fight with Panic on, one burst is tried first; "
            .. "with Panic off it goes through at once. The server does see "
            .. "you pass through a solid - only when stuck, only until clear.")

        readout(v, function()
            return "Water: " .. tostring(P.waterNote) .. ".  Put back up "
                .. tostring(P.waterSets) .. " times (the game resets it)."
        end)
        caption(v, "Water is land, always - no switch. The sea floor in this "
            .. "game sits under the surface, so standing on it is standing IN "
            .. "water: that is the damage, and it is why getting out meant "
            .. "climbing an island edge from below. It is raised to the "
            .. "surface on your screen from the moment the script loads, so a "
            .. "lunge off the shore leaves you standing on the water and you "
            .. "just run back. Your client only; rejoining resets it.")

        switchRow(v, "Panic when stuck",
            "Big bursts: stacked air jumps, sideways dashes",
            function() return CFG.Panic end,
            function(x) CFG.Panic = x end)
        sliderRow(v, "Air jumps per climb", 2, 12, 1,
            function() return CFG.ClimbJumps end,
            function(x) CFG.ClimbJumps = x end, "")
        switchRow(v, "Force the air jump if Space is ignored",
            "The engine jump, only when the key showed no kick",
            function() return CFG.ForceAirJump end,
            function(x) CFG.ForceAirJump = x end)
        caption(v, "The air jump goes where you are moving, so the climb "
            .. "cancels all movement first and stacks the jumps straight up; "
            .. "only at the top does it turn to the enemy and dash forward. "
            .. "Each air jump is checked: Space is pressed, and if the "
            .. "character got no upward kick the engine is asked directly. "
            .. "The stats page shows which of the two is doing the work.")

        sliderRow(v, "Keep swinging from", 0, 60, 1,
            function() return CFG.SwingFrom end,
            function(x) CFG.SwingFrom = x end, " studs")
        caption(v, "After a throw the enemy walks straight back at you, and "
            .. "its reach is about the same as yours. If the M1 only starts "
            .. "once it is in reach, it is a race at the boundary, and when "
            .. "the NPC wins it you are stunned and it chains. From this far "
            .. "out the M1 is kept going while you close, so it walks into "
            .. "hits already in the air. Set it at or below the distance above "
            .. "to swing only in reach.")
        switchRow(v, "Gather a pile before fighting",
            "Tag a few with one M1 each; they walk to you together",
            function() return CFG.Gather end,
            function(x) CFG.Gather = x end)
        sliderRow(v, "Tag up to", 2, 5, 1,
            function() return CFG.GatherCount end,
            function(x) CFG.GatherCount = x end, " enemies")
        sliderRow(v, "Gather from within", 30, 120, 5,
            function() return CFG.GatherRadius end,
            function(x) CFG.GatherRadius = x end, " studs")
        caption(v, "The magnet, done by their own legs. When nobody is in "
            .. "reach it walks through the nearest few, hits each once, and "
            .. "moves on without waiting for the kill. Each one hit chases "
            .. "you, so they arrive in a pile and every swing lands on "
            .. "several. The game's own AI moves them, so there is nothing "
            .. "unusual for the server to see. More enemies at once also "
            .. "means more damage taken; an area skill every few swings makes "
            .. "a pile pay off most.")
        sliderRow(v, "Allowed drift", 0.5, 8, 0.5,
            function() return CFG.StandSlack end,
            function(x) CFG.StandSlack = x end, " studs")
        caption(v, "This is the only range in the script. Nothing widens a "
            .. "hitbox anywhere, so what lands is whatever your weapon really "
            .. "reaches. A sword wants 5-8. A fruit M1 whose hitbox starts out "
            .. "from the body wants 12-18 - too close and the swing passes "
            .. "over the enemy. It closes in AND backs off to hold the number, "
            .. "so the enemy stays in front of you either way.")

        switchRow(v, "Lock the body on the target",
            "A melee swing goes where the body points",
            function() return CFG.FaceLock end,
            function(x) CFG.FaceLock = x end)
        switchRow(v, "Take the camera and aim it",
            "Off: your view and your cursor stay yours",
            function() return CFG.AimCamera end,
            function(x)
                CFG.AimCamera = x
                if not x then releaseCamera() end
            end)
        caption(v, "Two different things. Locking the BODY costs you nothing "
            .. "and is what makes a sword or a fighting style land. Taking the "
            .. "CAMERA is only worth it for fruit skills, which fire down the "
            .. "cursor ray - and it makes your mouse look dead and parks your "
            .. "cursor at the middle of the screen, which is your cursor "
            .. "fighting the script for the aim.")

        sliderRow(v, "Give up if nothing lands for", 3, 60, 1,
            function() return CFG.GiveUpSeconds end,
            function(x) CFG.GiveUpSeconds = x end, "s")
        caption(v, "Measured from the last time the enemy's health actually "
            .. "moved, not from when the fight started - so a slow kill is "
            .. "never abandoned half-finished, and something you cannot reach "
            .. "is dropped quickly.")

        gap(v, 8)
        heading2(v, "what gets pressed")
        switchRow(v, "M1", "Left click, every swing",
            function() return CFG.M1 end,
            function(x) CFG.M1 = x end)
        switchRow(v, "Z", nil, function() return CFG.SkillZ end,
            function(x) CFG.SkillZ = x end)
        switchRow(v, "X", nil, function() return CFG.SkillX end,
            function(x) CFG.SkillX = x end)
        switchRow(v, "C", nil, function() return CFG.SkillC end,
            function(x) CFG.SkillC = x end)
        switchRow(v, "V", nil, function() return CFG.SkillV end,
            function(x) CFG.SkillV = x end)
        sliderRow(v, "A skill every", 1, 10, 1,
            function() return CFG.SkillEvery end,
            function(x) CFG.SkillEvery = x end, " swings")

        readout(v, function()
            local bits = {}
            if CFG.M1 then table.insert(bits, "M1") end
            local keys = {}
            for _, row in ipairs(SKILL_KEYS) do
                if CFG[row[1]] then table.insert(keys, row[2].Name) end
            end
            if #bits == 0 and #keys == 0 then
                return "Nothing is switched on - no key will be pressed."
            end
            if #keys == 0 then return "Pressing M1 only." end
            if not CFG.M1 then
                return "Pressing " .. table.concat(keys, ", ") .. " in turn, one per swing."
            end
            return "M1 every swing, plus " .. table.concat(keys, ", ")
                .. " in turn every " .. math.floor(CFG.SkillEvery) .. "."
        end)
    end

    -- =====================================================
    -- SPEED
    -- =====================================================
    do
        local v = makeView("speed")
        gap(v, 6)
        heading2(v, "how often it swings")
        sliderRow(v, "Gap, fastest", 0.02, 1, 0.02,
            function() return CFG.SwingMin end,
            function(x)
                CFG.SwingMin = x
                if CFG.SwingMax < x then CFG.SwingMax = x end
            end, "s")
        sliderRow(v, "Gap, slowest", 0.02, 1.5, 0.02,
            function() return CFG.SwingMax end,
            function(x)
                CFG.SwingMax = x
                if CFG.SwingMin > x then CFG.SwingMin = x end
            end, "s")
        sliderRow(v, "Rest after a kill", 0, 6, 0.2,
            function() return CFG.RestMax end,
            function(x)
                CFG.RestMax = x
                if CFG.RestMin > x then CFG.RestMin = x end
            end, "s")
        caption(v, "Each gap is drawn between the two numbers. Put them on the "
            .. "same value for a flat fixed rate - nothing here is capped and "
            .. "nothing is chosen for you. Rest is 0 by default: the farm goes "
            .. "straight from one kill to the next.")

        gap(v, 8)
        heading2(v, "closing the gap")
        switchRow(v, "Dash to close a long gap",
            "Body, walk and camera all aimed at it for the press",
            function() return CFG.Dash end,
            function(x) CFG.Dash = x end)
        sliderRow(v, "Only dash past", 10, 150, 5,
            function() return CFG.DashFrom end,
            function(x) CFG.DashFrom = x end, " studs")
        sliderRow(v, "Dash no more often than", 0.2, 4, 0.1,
            function() return CFG.DashCooldown end,
            function(x) CFG.DashCooldown = x end, "s")
        switchRow(v, "Turn my camera at it for the dash",
            "Off: dash only when your camera already faces it (rare)",
            function() return CFG.DashTurnsCamera end,
            function(x) CFG.DashTurnsCamera = x end)
        sliderRow(v, "Sweep length", 4, 40, 1,
            function() return CFG.SweepSeconds end,
            function(x) CFG.SweepSeconds = x end, "s")
        textRow(v, "dash key: Q, E, F, R, LeftShift", function(val)
            val = (val:gsub("^%l", string.upper))
            if DASH_KEYS[val] then
                CFG.DashKey = val
                say("dash key: " .. val)
            else
                say("unknown key: " .. tostring(val))
            end
        end)
        readout(v, function()
            if not CFG.Dash then
                return "Dash off. It walks every gap."
            end
            return string.format("Dash on %s, past %d studs, at most every "
                .. "%.1fs. %d fired so far. The dash goes where the camera "
                .. "looks, so %s. If it overshoots and walks back, raise the "
                .. "distance.",
                tostring(CFG.DashKey or "Q"), math.floor(CFG.DashFrom),
                CFG.DashCooldown, stats.dashes or 0,
                CFG.DashTurnsCamera
                    and "the camera's yaw is turned at the target for the press"
                    or  "it only fires when your camera already agrees")
        end)

        gap(v, 8)
        heading2(v, "the game's own cooldown")
        switchRow(v, "Fast attack",
            "Clear the combat controller's cooldown on your clock",
            function() return CFG.FastAttack end,
            function(x)
                CFG.FastAttack = x
                if x and not P.fastOK then installFastAttack() end
                say(x and ("fast attack " .. tostring(P.fastNote or ""))
                    or "fast attack off")
            end)
        sliderRow(v, "Ready again every", 0.05, 2, 0.05,
            function() return CFG.AttackSpeed end,
            function(x) CFG.AttackSpeed = x end, "s")
        readout(v, function()
            if not CFG.FastAttack then
                return "Off. Your weapon's own cooldown applies."
            end
            if not P.fastOK then
                return "ON, but the hook could not install - " .. tostring(P.fastNote)
            end
            return string.format("ON. Telling the controller it is ready every %.2fs. "
                .. "The hitbox is not touched - range is still whatever your "
                .. "weapon reaches.", CFG.AttackSpeed)
        end)

        gap(v, 4)
        heading2(v, "how fast it walks")
        readout(v, function()
            local _, _, hum = parts()
            return "The game's own: " .. (hum and string.format("%.0f", hum.WalkSpeed) or "?")
                .. " right now. Race, fruit and gear set it; the farm never "
                .. "writes it."
        end)
    end

    -- =====================================================
    -- QUEST LOOP
    -- =====================================================
    do
        local v = makeView("quest")
        gap(v, 6)

        switchRow(v, "Quest loop",
            "Accept, kill the count, walk back, accept again",
            function() return CFG.QuestLoop end,
            function(x)
                CFG.QuestLoop = x
                if x then P.armQuest() end
                say(x and "quest loop on" or "quest loop off")
            end)
        switchRow(v, "Walk back afterwards", nil,
            function() return CFG.QuestReturnToFarm end,
            function(x) CFG.QuestReturnToFarm = x end)

        gap(v, 8)
        heading2(v, "does it have to walk to the giver")
        local modeBox = chooser(v, 128)
        local modeSig = nil
        local MODES = {
            { "auto",   "Walk only if it is near", "by distance" },
            { "always", "Always walk to it",       "safe, and the slow one" },
            { "never",  "Never walk, ask anyway",  "fastest if it works" },
        }
        local function modeRefresh()
            local e = activeName or CFG.Target
            local _, gp = P.giverFor(e)
            local _, rr = parts()
            local gd = (gp and rr) and math.floor((gp - rr.Position).Magnitude) or nil
            local sig = tostring(CFG.GiverMode) .. "|" .. tostring(e) .. "|"
                .. tostring(gd and math.floor(gd / 25))
            if sig == modeSig then return end
            modeSig = sig
            for _, c in ipairs(modeBox:GetChildren()) do
                if c:IsA("GuiObject") then c:Destroy() end
            end
            for i, m in ipairs(MODES) do
                local tag = m[3]
                if m[1] == "auto" and gd then
                    tag = (gd <= (CFG.GiverWalkRadius or 250))
                        and ("giver " .. gd .. " away: walks")
                        or  ("giver " .. gd .. " away: asks")
                end
                chooserRow(modeBox, i, m[2], tag, CFG.GiverMode == m[1], function()
                    CFG.GiverMode = m[1]
                    say("giver: " .. m[2])
                    modeSig = nil
                end)
            end
        end
        modeRefresh()
        addLive(modeRefresh)
        sliderRow(v, "Near means within", 30, 800, 10,
            function() return CFG.GiverWalkRadius end,
            function(x) CFG.GiverWalkRadius = x end, " studs")
        caption(v, "The walk is the expensive part of the cycle, and whether "
            .. "it is worth paying is a distance. The Demonic Soul giver "
            .. "stands right beside them, so walking costs nothing and auto "
            .. "walks it. The Posessed Mummies are a long path underground "
            .. "from theirs, so auto asks from range instead. If asking from "
            .. "range comes back empty it walks up and asks again, so a server "
            .. "that does check distance still works.")

        readout(v, function()
            local e = activeName or CFG.Target
            if not e then return "No target picked yet." end
            local qname, tier = questForTarget()
            local gname, gpos = P.giverFor(e)
            local lines = {}
            local lk = P.lockedQuest
            table.insert(lines, e .. "  ->  " .. tostring(qname or "no quest id")
                .. (tier and ("  tier " .. tier) or "")
                .. (lk and "   [locked]" or ""))
            table.insert(lines, "giver: " .. tostring(gname or "name unknown"))
            if gpos then
                local _, r = parts()
                local d = r and (gpos - r.Position).Magnitude or nil
                table.insert(lines, string.format("spot: %.0f, %.0f, %.0f%s",
                    gpos.X, gpos.Y, gpos.Z,
                    d and string.format("   %.0f studs away", d) or ""))
            else
                table.insert(lines, "spot: unknown - it will scan for the \"?\" marker")
            end
            local q = P.readQuest()
            table.insert(lines, "now: " .. (q and (q.have .. "/" .. q.need .. "  "
                .. tostring(q.enemy or "")) or tostring(P.questProgress or "none")))
            if P.lastQuestResult then table.insert(lines, "last: " .. P.lastQuestResult) end
            return table.concat(lines, "\n")
        end)

        gap(v, 4)
        heading2(v, "which giver")
        caption(v, "The table already knows where each island's giver stands. "
            .. "Pick a different one here and the loop uses that one from then "
            .. "on, every single cycle.")

        local box = chooser(v, 150)
        local signature = nil
        local function refresh()
            local e = activeName or CFG.Target
            local tablePos = e and GIVER_POS[e] or nil
            local savedPos = e and P.giverSpots[e] or nil
            findQuestGiver(400, nil, true)
            local cands = P.questCandidates or {}

            local sig = tostring(e) .. "|" .. tostring(savedPos) .. "|"
            for i, c in ipairs(cands) do
                if i > 4 then break end
                sig = sig .. c.name .. math.floor(c.dist) .. ","
            end
            if sig == signature then return end
            signature = sig

            for _, c in ipairs(box:GetChildren()) do
                if c:IsA("GuiObject") then c:Destroy() end
            end

            local usingTable = (savedPos == nil)
            chooserRow(box, 1, "From the table",
                tablePos and (e and GIVER_NAMES[e] or "known") or "none known",
                usingTable, function()
                    P.clearGiver()
                    signature = nil
                end)
            chooserRow(box, 2, "Right where I am standing",
                savedPos and "saved" or "", false, function()
                    P.setGiverHere()
                    signature = nil
                end)

            local shown = 0
            for _, c in ipairs(cands) do
                if shown >= 4 then break end
                shown += 1
                local pos = c.part.Position
                local chosen = savedPos ~= nil and (savedPos - pos).Magnitude < 6
                chooserRow(box, 2 + shown, c.name,
                    string.format("%.0f studs", c.dist), chosen, function()
                        P.setGiver(pos, c.name)
                        signature = nil
                    end)
            end
        end
        refresh()
        addLive(refresh)

        actionRow(v, "Take one right now", nil, function()
            task.spawn(function() pcall(P.takeQuest) end)
        end)
        hairline(v)
        actionRow(v, "Unlock the quest and work it out again", nil, function()
            P.lockedQuest = nil
            local e = activeName or CFG.Target
            if e then P.learnedQuests[e] = nil end
            say("quest unlocked - the next accept works it out")
        end)

        gap(v, 8)
        heading2(v, "override the lookup")
        textRow(v, "giver name, exactly", function(val)
            CFG.QuestGiverName = (#val > 0) and val or nil
            say("giver name: " .. tostring(CFG.QuestGiverName or "from the table"))
        end)
        textRow(v, "quest id, e.g. HauntedQuest2", function(val)
            CFG.QuestName = (#val > 0) and val or nil
            P.lockedQuest = nil
            say("quest id: " .. tostring(CFG.QuestName or "from the table"))
        end)
        sliderRow(v, "Tier   0 = work it out", 0, 3, 1,
            function() return CFG.QuestTier or 0 end,
            function(x) CFG.QuestTier = (x > 0) and x or nil end)
        caption(v, "Leave the tier at 0 and the first accept tries each one, "
            .. "reads the tracker back, and keeps whichever actually asks for "
            .. "your species. That answer is then locked and every later cycle "
            .. "repeats exactly it.")
    end

    -- =====================================================
    -- STATS
    -- =====================================================
    do
        local v = makeView("stats")
        gap(v, 8)
        readout(v, function()
            local mins = math.max((os.clock() - stats.startedAt) / 60, 1 / 60)
            local q = P.readQuest()
            local _, _, hum = parts()
            return table.concat({
                string.format("state       %s   %.0fs", state, os.clock() - stateEnteredAt),
                "target      " .. tostring(activeName or "-"),
                "weapon      " .. tostring(P.heldTool() or "-")
                    .. ((CFG.Weapon and #CFG.Weapon > 0) and "  locked" or "  free"),
                "distance    " .. math.floor(CFG.StandOff) .. " studs"
                    .. "   swinging from " .. math.floor(CFG.SwingFrom or 0),
                "walkspeed   " .. (hum and string.format("%.0f", hum.WalkSpeed) or "?")
                    .. "  (the game's own - never written)",
                "fast attack " .. (CFG.FastAttack
                    and (P.fastOK and "on" or ("on, " .. tostring(P.fastNote))) or "off"),
                "",
                "kills       " .. stats.kills .. string.format("   %.1f/min", stats.kills / mins),
                "swings      " .. stats.swings,
                "damaging    " .. stats.damaging,
                "quests      " .. stats.quests,
                "walks       " .. stats.walks,
                "dashes      " .. stats.dashes,
                "haki        " .. stats.hakiPresses .. "   (J/E presses)"
                    .. (hasBuso() and "   enhancement ON" or "   enhancement OFF"),
                "switches    " .. stats.switches .. "   (turned to a nearer one mid-walk)",
                "gathers     " .. stats.gathers .. "   (piles started)   tagged " .. stats.tagged,
                "hops        " .. stats.hops .. "   (ground jumps)",
                "air jumps   " .. stats.airJumps .. "   (Space worked in the air)",
                "forced      " .. stats.forcedJumps .. "   (Space ignored; engine jumped)",
                "panics      " .. stats.panics .. "   (stuck bursts: climb or sideways)",
                "panic dash  " .. stats.panicDashes .. "   (dashes spent inside bursts)",
                "detours     " .. stats.detours .. "   (hop did nothing, pathed round for 8s)",
                "map         " .. stats.navMaps .. " read   plans " .. stats.navPlans
                    .. "   jumps " .. stats.navJumps .. "   learned " .. stats.navLearned,
                "ghosts      " .. stats.ghosts .. "   (blocked; walked through)   lifts " .. stats.lifts
                    .. "   fell " .. stats.ghostFalls,
                "gui scans   " .. tostring(P.questScans or 0)
                    .. "   (full PlayerGui walks - should stay tiny)",
                "retreats    " .. stats.retreats,
                "escalations " .. stats.escalations,
                "",
                "quest       " .. (q and (q.have .. "/" .. q.need .. "  "
                    .. tostring(q.enemy or "")) or tostring(P.questProgress or "none")),
                "status      " .. statusLine,
            }, "\n")
        end)
        actionRow(v, "Reset the counters", nil, function()
            for k in pairs(stats) do stats[k] = 0 end
            stats.startedAt = os.clock()
            say("counters reset")
        end)
        hairline(v)
        switchRow(v, "Print debug to the console", nil,
            function() return CFG.Debug end,
            function(x) CFG.Debug = x end)
        gap(v, 8)
        actionRow(v, "Stop and close the panel", "danger", function()
            P.stop()
            if gui then gui:Destroy() end
        end)
    end

    show("home")

    task.spawn(function()
        while gui and gui.Parent do
            dot.BackgroundColor3 = P.running and C.live or C.third
            for _, e in ipairs(live) do
                if not e.v or e.v.Visible then pcall(e.f) end
            end
            task.wait(0.3)
        end
    end)
end

-- =========================================================
-- API
-- =========================================================
function P.start(name)
    if P.running then P.stop() end
    if type(name) == "string" and #name > 0 then CFG.Target = name end

    for k in pairs(stats) do stats[k] = 0 end
    stats.startedAt = os.clock()
    activeName  = nil
    farmSpot    = nil
    blacklist   = {}
    countedDead = {}
    escalation  = 0
    pathUntil   = 0
    lastProgressAt = os.clock()
    P.running   = true
    moveEnabled = true
    pcall(P.armQuest)
    setState("RESOLVE")

    keepWeapon()
    -- If Enhancement is off at start, this is a fresh life and both go back
    -- on -- see keepHaki. Otherwise the life is treated as settled, and
    -- Observation gets its timed look straight away: the dodge counter is
    -- read, and E is pressed only if it is not showing.
    seenChar, seenCharAt = player.Character, os.clock() - 10
    busoTries = 0
    P.kenDone = false
    kenNextAt, kenVerifyAt, kenMisses, kenBlind = 0, nil, 0, false
    if CFG.AutoBuso and not hasBuso() then
        kenChar = nil
    else
        kenChar = player.Character
    end
    -- Installed either way so the switch works instantly, but it does nothing
    -- at all until CFG.FastAttack is on.
    pcall(installFastAttack)
    if not (gui and gui.Parent) then pcall(buildUI) end

    -- The ghost watcher: every frame, whatever is walking the character.
    blockAt = nil
    track(RunService.Heartbeat:Connect(function() pcall(ghostWatch) end))
    -- The route follower: steer and jump, every frame. It owns the legs
    -- while it runs, so if it ever throws, the character would just stand
    -- there. Three errors and the map switches itself off (the panel shows
    -- Off) and the plain straight run takes over again.
    navHalt()
    local navErrors = 0
    track(RunService.Heartbeat:Connect(function()
        local ok, err = pcall(navTick)
        if not ok then
            navErrors += 1
            log("nav error: " .. tostring(err))
            if navErrors >= 3 then
                CFG.TerrainMap = false
                navHalt()
                say("ground map switched itself off after errors")
            end
        end
    end))

    track(player.Idled:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end))

    track(player.CharacterAdded:Connect(function()
        task.wait(2)
        -- The tool. A lock puts its own back through keepWeapon. Free hands
        -- put back whatever was in hand before the death, once the Backpack
        -- has filled (it lags the spawn by a moment).
        if not (CFG.Weapon and #CFG.Weapon > 0) and lastHeld then
            for _ = 1, 12 do
                local char = player.Character
                local bp   = player:FindFirstChild("Backpack")
                local tool = bp and bp:FindFirstChild(lastHeld)
                local hum  = char and char:FindFirstChildOfClass("Humanoid")
                if tool and tool:IsA("Tool") and hum then
                    pcall(function() hum:EquipTool(tool) end)
                    say("back in hand: " .. lastHeld)
                    break
                end
                task.wait(0.5)
            end
        end
        keepWeapon()
        pcall(installFastAttack)
        progress()
        -- Haki comes back through keepHaki on the next step: it sees the new
        -- character, waits for the spawn to settle, then J, then E.
    end))

    task.spawn(mainLoop)
    task.spawn(watchdog)
    print("[BFP] running. _G.BFP.stop() to halt.")
end

function P.stop()
    P.running = false
    epoch += 1                 -- everything in flight gives up on this line
    moveEnabled = false
    task.delay(0.3, function() moveEnabled = true end)
    pcall(releaseCamera)
    pcall(cancelWalk)
    if fastConn then pcall(function() fastConn:Disconnect() end) fastConn = nil end
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    pcall(ghostRelease)
    navHalt()
    setState("IDLE")
    say("stopped")
    print(string.format("[BFP] stopped. kills=%d swings=%d quests=%d",
        stats.kills, stats.swings, stats.quests))
end

function P.stats() return stats end
function P.state() return state, statusLine, escalation end

say("loaded - pick a target, then press Start")
pcall(buildUI)
-- Water is land from load, farm running or not, panel open or closed: the
-- game puts the slab back, so it is looked at four times a second. Hands
-- over only when a newer copy of this script takes over _G.BFP.
task.spawn(function()
    while _G.BFP == P do
        pcall(keepWater)
        task.wait(0.25)
    end
end)
print("[BFP] loaded. Use the panel, or _G.BFP.start(\"Demonic Soul\")")
