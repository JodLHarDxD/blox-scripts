--[[
    SOLO FARM V2
    ============
    A self-contained Luau farming controller for Blox Fruits.

    What changed from solo_farm.lua:
      * No remote UI library or loadstring dependency.
      * One cooperative scheduler owns movement and actions.
      * Farming modes no longer fight over the same character/tween.
      * Enemy and chest detection do not depend on PrimaryPart.
      * Counters only increase after an observable result.
      * Farm duration is actually enforced.
      * UI shows the current action, mode rotation, errors, and statistics.

    Blox Fruits data is embedded below:
      * First, Second, and Third Sea progression islands.
      * Regular enemies, quest levels, quest givers, and quest remote IDs.
      * Current and legacy boss names/locations.
      * Aliases for Update 30 name changes.
      * First Sea -> Second Sea progression route with a level-700 gate.

    Combat still uses a conservative generic Tool:Activate() hook. The
    target game can change its combat internals, so the attack adapter remains
    isolated in performAttack().
]]

-- =========================================================
-- CONFIGURATION
-- =========================================================
local CFG = {
    -- Movement
    MoveSpeed = 180,
    MaxDirectMoveDistance = 800,
    LocalIslandRadius = 800,
    AlreadyAtSpawnRadius = 500,
    TeleportArrivalRadius = 1000,
    MaxTeleportHopDistance = 6000,
    TeleportRetries = 2,
    TeleportRetryDelay = 0.8,
    AttackDistance = 24,
    TravelDistance = 650,
    CharacterTimeout = 15,
    TravelCooldown = 30,
    ExploreWait = 2.5,

    -- Detection
    EnemyScanRange = 450,
    BossScanRange = 1200,
    EnemyScanInterval = 0.35,
    ChestScanInterval = 1.00,
    SchedulerInterval = 0.12,
    ContextRefreshInterval = 1.00,

    -- Combat
    AttackInterval = 0.18,
    EnableQuestHelper = true,
    UseBloxFruitsQuestRemote = true,
    FarmDurationMinutes = 60,

    -- Update 30 Magnet Night Event
    -- The reference schedule is XX:00 for 10 minutes. Keep the clock in UTC
    -- by default; UTC+05:30 therefore appears as XX:30 in India.
    MagnetEventStartMinute = 0,
    MagnetEventDurationMinutes = 10,
    MagnetEventTimeBase = "UTC",
    MagnetEventLocalOffsetMinutes = 330,
    MagnetEventLocalLabel = "IST",
    MagnetScanRange = 900,
    MagnetZoneLoadWait = 1.25,
    MagnetZoneScanRange = 1800,
    MagnetEventRouteSea = 3,
    MagnetEventPreemptsFarm = true,
    MagnetServerHopAfterClear = true,
    -- Inject a runtime-specific server-hop function if one is available.
    -- The default stays nil because Roblox client code does not expose a
    -- supported public-server enumeration API.
    ServerHopAdapter = nil,

    -- Account progression route
    ProgressionGoalLevel = 700,
    PauseAtFirstSeaGate = true,

    -- General
    Debug = false,
    LoadUI = true,
}

-- =========================================================
-- BLOX FRUITS PROGRESSION DATABASE
-- =========================================================
-- The regular quest rows follow the current three-sea quest table. Aliases
-- cover common internal names and names changed by Update 30.
local function BFQuest(enemy, level, giver, questName, questIndex, count)
    return {
        enemy = enemy,
        level = level,
        giver = giver,
        questName = questName,
        questIndex = questIndex,
        count = count or 1,
    }
end

local function BFIsland(sea, name, aliases, minLevel, maxLevel, quests)
    return {
        sea = sea,
        name = name,
        aliases = aliases or {},
        minLevel = minLevel,
        maxLevel = maxLevel,
        quests = quests or {},
    }
end

local function BFBoss(sea, name, aliases, island, level, kind)
    return {
        sea = sea,
        name = name,
        aliases = aliases or {},
        island = island,
        level = level,
        kind = kind or "Boss",
    }
end

local BF_ISLANDS = {
    -- First Sea
    BFIsland(1, "Marine Starter", {"MarineStarter", "Marine Starter Island"}, 0, 10, {
        BFQuest("Trainee", 0, "Marine Leader", "MarineQuest", 1, 5),
    }),
    BFIsland(1, "Pirate Starter", {"PirateStarter", "Pirate Starter Island"}, 0, 10, {
        BFQuest("Bandit", 0, "Bandit Quest Giver", "BanditQuest1", 1, 5),
    }),
    BFIsland(1, "Jungle", {"Jungle"}, 10, 30, {
        BFQuest("Monkey", 10, "Adventurer", "JungleQuest", 1, 6),
        BFQuest("Gorilla", 15, "Adventurer", "JungleQuest", 2, 8),
    }),
    BFIsland(1, "Pirate Village", {"PirateVillage", "Buggy"}, 30, 60, {
        BFQuest("Pirate", 30, "Pirate Adventurer", "BuggyQuest1", 1, 8),
        BFQuest("Brute", 40, "Pirate Adventurer", "BuggyQuest1", 2, 8),
    }),
    BFIsland(1, "Desert", {"Desert"}, 60, 90, {
        BFQuest("Desert Bandit", 60, "Desert Adventurer", "DesertQuest", 1, 8),
        BFQuest("Desert Officer", 75, "Desert Adventurer", "DesertQuest", 2, 8),
    }),
    BFIsland(1, "Frozen Village", {"FrozenVillage", "Ice"}, 90, 120, {
        BFQuest("Snow Bandit", 90, "Villager", "SnowQuest", 1, 7),
        BFQuest("Snowman", 100, "Villager", "SnowQuest", 2, 8),
    }),
    BFIsland(1, "Marine Fortress", {"MarineFortress", "MarineBase"}, 120, 150, {
        BFQuest("Chief Petty Officer", 120, "Marine", "MarineQuest2", 1, 7),
    }),
    BFIsland(1, "Skylands", {"Skylands", "SkyIsland", "Sky"}, 150, 250, {
        BFQuest("Sky Bandit", 150, "Sky Adventurer", "SkyQuest", 1, 7),
        BFQuest("Dark Master", 175, "Sky Adventurer", "SkyQuest", 2, 8),
    }),
    BFIsland(1, "Prison", {"Prison"}, 190, 250, {
        BFQuest("Prisoner", 190, "Jail Keeper", "PrisonerQuest", 1, 8),
        BFQuest("Dangerous Prisoner", 210, "Jail Keeper", "PrisonerQuest", 2, 8),
        BFQuest("Ruthless Prisoner", 220, "Head Jailer", "PrisonerQuest", 2, 8),
    }),
    BFIsland(1, "Colosseum", {"Colosseum"}, 250, 300, {
        BFQuest("Toga Warrior", 250, "Colosseum Quest Giver", "ColosseumQuest", 1, 8),
        BFQuest("Gladiator", 275, "Colosseum Quest Giver", "ColosseumQuest", 2, 4),
    }),
    BFIsland(1, "Magma Village", {"MagmaVillage", "Magma"}, 300, 375, {
        BFQuest("Military Soldier", 300, "The Mayor", "MagmaQuest", 1, 7),
        BFQuest("Military Spy", 325, "The Mayor", "MagmaQuest", 2, 8),
    }),
    BFIsland(1, "Underwater City", {"UnderwaterCity", "FishmanIsland"}, 375, 450, {
        BFQuest("Fishman Warrior", 375, "King Neptune", "FishmanQuest", 1, 8),
        BFQuest("Fishman Commando", 400, "King Neptune", "FishmanQuest", 2, 8),
    }),
    BFIsland(1, "Upper Skylands", {"UpperSkylands", "UpperSky", "SkyExp"}, 450, 625, {
        BFQuest("God's Guard", 450, "Mole", "SkyExp1Quest", 1, 8),
        BFQuest("Shanda", 475, "Mole", "SkyExp1Quest", 2, 8),
        BFQuest("Royal Squad", 525, "Sky Quest Giver 2", "SkyExp1Quest", 1, 8),
        BFQuest("Royal Soldier", 550, "Sky Quest Giver 2", "SkyExp1Quest", 2, 8),
    }),
    BFIsland(1, "Fountain City", {"FountainCity", "Fountain"}, 625, 700, {
        BFQuest("Galley Pirate", 625, "Freezeburg Quest Giver", "FountainQuest", 1, 8),
        BFQuest("Galley Captain", 650, "Freezeburg Quest Giver", "FountainQuest", 2, 9),
    }),
    BFIsland(1, "Middle Town", {"MiddleTown", "Middle Island"}, 1, 700, {}),
    BFIsland(1, "Jean-Luc Island", {"JeanLucIsland", "Jean-Luc Island"}, 1, 700, {}),

    -- Second Sea
    BFIsland(2, "Kingdom of Rose", {"KingdomOfRose", "Rose"}, 700, 924, {
        BFQuest("Raider", 700, "Area 1 Quest Giver", "Area1Quest", 1, 8),
        BFQuest("Mercenary", 725, "Area 1 Quest Giver", "Area1Quest", 2, 8),
        BFQuest("Swan Pirate", 775, "Area 2 Quest Giver", "Area2Quest", 1, 8),
        BFQuest("Factory Staff", 800, "Area 2 Quest Giver", "Area2Quest", 2, 8),
    }),
    BFIsland(2, "Green Zone", {"GreenZone", "Docks 3"}, 875, 950, {
        BFQuest("Marine Lieutenant", 875, "Marine Quest Giver", "MarineQuest3", 1, 8),
        BFQuest("Marine Captain", 900, "Marine Quest Giver", "MarineQuest3", 2, 9),
    }),
    BFIsland(2, "Graveyard", {"Graveyard", "GraveyardIsland"}, 950, 1000, {
        BFQuest("Zombie", 950, "Graveyard Quest Giver", "ZombieQuest", 1, 8),
        BFQuest("Vampire", 975, "Graveyard Quest Giver", "ZombieQuest", 2, 8),
    }),
    BFIsland(2, "Snow Mountain", {"SnowMountain"}, 1000, 1100, {
        BFQuest("Snow Trooper", 1000, "Snow Quest Giver", "SnowMountainQuest", 1, 8),
        BFQuest("Winter Warrior", 1050, "Snow Quest Giver", "SnowMountainQuest", 2, 9),
    }),
    BFIsland(2, "Hot and Cold", {"HotAndCold", "IceSide", "FireSide"}, 1100, 1250, {
        BFQuest("Lab Subordinate", 1100, "Ice Quest Giver", "IceSideQuest", 1, 8),
        BFQuest("Horned Warrior", 1125, "Ice Quest Giver", "IceSideQuest", 2, 8),
        BFQuest("Magma Ninja", 1175, "Fire Quest Giver", "FireSideQuest", 1, 8),
        BFQuest("Lava Pirate", 1200, "Fire Quest Giver", "FireSideQuest", 2, 8),
    }),
    BFIsland(2, "Cursed Ship", {"CursedShip", "Ship"}, 1250, 1350, {
        BFQuest("Ship Deckhand", 1250, "Rear Crew Quest Giver", "ShipQuest1", 1, 8),
        BFQuest("Ship Engineer", 1275, "Rear Crew Quest Giver", "ShipQuest1", 2, 8),
        BFQuest("Ship Steward", 1300, "Front Crew Quest Giver", "ShipQuest2", 1, 8),
        BFQuest("Ship Officer", 1325, "Front Crew Quest Giver", "ShipQuest2", 2, 9),
    }),
    BFIsland(2, "Ice Castle", {"IceCastle", "Frost"}, 1350, 1425, {
        BFQuest("Arctic Warrior", 1350, "Frost Quest Giver", "FrostQuest", 1, 8),
        BFQuest("Snow Lurker", 1375, "Frost Quest Giver", "FrostQuest", 2, 9),
    }),
    BFIsland(2, "Forgotten Island", {"ForgottenIsland", "Forgotten"}, 1425, 1500, {
        BFQuest("Sea Soldier", 1425, "Forgotten Quest Giver", "ForgottenQuest", 1, 8),
        BFQuest("Water Fighter", 1450, "Forgotten Quest Giver", "ForgottenQuest", 2, 8),
    }),
    BFIsland(2, "Cafe", {"Cafe"}, 700, 1500, {}),
    BFIsland(2, "Don Swan's Mansion", {"DonSwansMansion", "SwanMansion"}, 700, 1500, {}),
    BFIsland(2, "Dark Arena", {"DarkArena"}, 1000, 1500, {}),
    BFIsland(2, "Remote Island", {"RemoteIsland"}, 700, 1500, {}),
    BFIsland(2, "Cave Island", {"CaveIsland"}, 700, 1500, {}),
    BFIsland(2, "Indra Island", {"IndraIsland"}, 700, 1500, {}),

    -- Third Sea
    BFIsland(3, "Port Town", {"PortTown", "PiratePort"}, 1500, 1575, {
        BFQuest("Pirate Millionaire", 1500, "Pirate Port Quest Giver", "PiratePortQuest", 1, 8),
        BFQuest("Pistol Billionaire", 1525, "Pirate Port Quest Giver", "PiratePortQuest", 2, 8),
    }),
    BFIsland(3, "Hydra Island", {"HydraIsland", "Amazon"}, 1575, 1700, {
        BFQuest("Dragon Crew Warrior", 1575, "Dragon Crew Quest Giver", "AmazonQuest", 1, 8),
        BFQuest("Dragon Crew Archer", 1600, "Dragon Crew Quest Giver", "AmazonQuest", 2, 8),
        BFQuest("Hydra Enforcer", 1625, "Hydra Town Quest Giver", "AmazonQuest2", 1, 8),
        BFQuest("Venomous Assailant", 1650, "Hydra Town Quest Giver", "AmazonQuest2", 2, 8),
    }),
    BFIsland(3, "Great Tree", {"GreatTree", "MarineTreeIsland"}, 1700, 1775, {
        BFQuest("Marine Commodore", 1700, "Marine Tree Quest Giver", "MarineTreeIsland", 1, 8),
        BFQuest("Marine Rear Admiral", 1725, "Marine Tree Quest Giver", "MarineTreeIsland", 2, 9),
    }),
    BFIsland(3, "Floating Turtle", {"FloatingTurtle", "DeepForest"}, 1775, 1975, {
        BFQuest("Fishman Raider", 1775, "Turtle Adventure Quest Giver", "DeepForestIsland3", 1, 8),
        BFQuest("Fishman Captain", 1800, "Turtle Adventure Quest Giver", "DeepForestIsland3", 2, 8),
        BFQuest("Forest Pirate", 1825, "Deep Forest Quest Giver", "DeepForestIsland", 1, 8),
        BFQuest("Mythological Pirate", 1850, "Deep Forest Quest Giver", "DeepForestIsland", 2, 8),
        BFQuest("Jungle Pirate", 1900, "Deep Forest Area 2 Quest Giver", "DeepForestIsland2", 1, 8),
        BFQuest("Musketeer Pirate", 1925, "Deep Forest Area 2 Quest Giver", "DeepForestIsland2", 2, 8),
    }),
    BFIsland(3, "Haunted Castle", {"HauntedCastle"}, 1975, 2075, {
        BFQuest("Reborn Skeleton", 1975, "Haunted Castle Quest Giver 1", "HauntedQuest1", 1, 8),
        BFQuest("Living Zombie", 2000, "Haunted Castle Quest Giver 1", "HauntedQuest1", 2, 8),
        BFQuest("Demonic Soul", 2025, "Haunted Castle Quest Giver 2", "HauntedQuest2", 1, 8),
        BFQuest("Possessed Mummy", 2050, "Haunted Castle Quest Giver 2", "HauntedQuest2", 2, 8),
    }),
    BFIsland(3, "Sea of Treats", {"SeaOfTreats", "PeanutLand", "IceCreamLand", "CakeLand", "ChocolateLand", "CandyLand", "CandyCaneLand"}, 2075, 2450, {
        BFQuest("Peanut Scout", 2075, "Peanut Quest Giver", "CakeQuest1", 1, 8),
        BFQuest("Peanut President", 2100, "Peanut Quest Giver", "CakeQuest1", 2, 8),
        BFQuest("Ice Cream Chef", 2125, "Ice Cream Quest Giver", "CakeQuest2", 1, 8),
        BFQuest("Ice Cream Commander", 2150, "Ice Cream Quest Giver", "CakeQuest2", 2, 8),
        BFQuest("Cookie Crafter", 2200, "Cake Quest Giver 1", "CakeQuest1", 1, 8),
        BFQuest("Cake Guard", 2225, "Cake Quest Giver 1", "CakeQuest1", 2, 8),
        BFQuest("Baking Staff", 2250, "Cake Quest Giver 2", "CakeQuest2", 1, 8),
        BFQuest("Head Baker", 2275, "Cake Quest Giver 2", "CakeQuest2", 2, 8),
        BFQuest("Cocoa Warrior", 2300, "Chocolate Quest Giver 1", "ChocQuest1", 1, 8),
        BFQuest("Chocolate Bar Battler", 2325, "Chocolate Quest Giver 1", "ChocQuest1", 2, 8),
        BFQuest("Sweet Thief", 2350, "Chocolate Quest Giver 2", "ChocQuest2", 1, 8),
        BFQuest("Candy Rebel", 2375, "Chocolate Quest Giver 2", "ChocQuest2", 2, 8),
        BFQuest("Candy Pirate", 2400, "Candy Cane Quest Giver", "CandyQuest1", 1, 8),
        BFQuest("Snow Demon", 2425, "Candy Cane Quest Giver", "CandyQuest1", 2, 8),
    }),
    BFIsland(3, "Tiki Outpost", {"TikiOutpost", "Tiki"}, 2450, 2600, {
        BFQuest("Isle Outlaw", 2450, "Tiki Quest Giver 1", "TikiQuest1", 1, 8),
        BFQuest("Island Boy", 2475, "Tiki Quest Giver 1", "TikiQuest1", 2, 8),
        BFQuest("Sun-kissed Warrior", 2500, "Tiki Quest Giver 2", "TikiQuest2", 1, 8),
        BFQuest("Isle Champion", 2525, "Tiki Quest Giver 2", "TikiQuest2", 2, 8),
        BFQuest("Serpent Hunter", 2550, "Tiki Quest Giver 3", "TikiQuest3", 1, 8),
        BFQuest("Skull Slayer", 2575, "Tiki Quest Giver 3", "TikiQuest3", 2, 8),
    }),
    BFIsland(3, "Submerged Island", {"SubmergedIsland", "Submerged"}, 2600, 2800, {
        BFQuest("Reef Bandit", 2600, "Submerged Quest Giver 1", "SubmergedQuest1", 1, 8),
        BFQuest("Coral Pirate", 2625, "Submerged Quest Giver 1", "SubmergedQuest1", 2, 8),
        BFQuest("Sea Chanter", 2650, "Submerged Quest Giver 2", "SubmergedQuest2", 1, 8),
        BFQuest("Ocean Prophet", 2675, "Submerged Quest Giver 2", "SubmergedQuest2", 2, 8),
        BFQuest("High Disciple", 2700, "Submerged Quest Giver 3", "SubmergedQuest3", 1, 8),
        BFQuest("Grand Devotee", 2725, "Submerged Quest Giver 3", "SubmergedQuest3", 2, 8),
    }),
    BFIsland(3, "Castle on the Sea", {"CastleOnTheSea", "Castle"}, 1500, 3000, {}),
    BFIsland(3, "Dimensional Shift", {"DimensionalShift"}, 2000, 3000, {}),
    BFIsland(3, "Heavenly Dimension", {"HeavenlyDimension", "HeavenDimension"}, 2000, 3000, {}),
    BFIsland(3, "Hell Dimension", {"HellDimension"}, 2000, 3000, {}),
    BFIsland(3, "Sea Events", {"Sea", "SeaEvent", "Terrorshark"}, 1500, 3000, {}),
}

local BF_BOSSES = {
    BFBoss(1, "Gorilla King", {"The Gorilla King"}, "Jungle", 25),
    BFBoss(1, "Chef", {}, "Pirate Village", 55),
    BFBoss(1, "Saber Expert", {}, "Jungle", 200, "Puzzle Boss"),
    BFBoss(1, "The Saw", {"Saw"}, "Middle Town", 100, "Raid Boss"),
    BFBoss(1, "Yeti", {}, "Frozen Village", 105),
    BFBoss(1, "Mob Leader", {}, "Jean-Luc Island", 120),
    BFBoss(1, "Vice Admiral", {}, "Marine Fortress", 130),
    BFBoss(1, "Warden", {}, "Prison", 220),
    BFBoss(1, "Chief Warden", {}, "Prison", 230, "Legacy Boss"),
    BFBoss(1, "Swan", {}, "Prison", 240, "Legacy Boss"),
    BFBoss(1, "Magma General", {"Magma Admiral"}, "Magma Village", 350),
    BFBoss(1, "Fishman Lord", {}, "Underwater City", 425),
    BFBoss(1, "Sky Warlord", {"Wysper"}, "Upper Skylands", 500),
    BFBoss(1, "Lightning God", {"Thunder God"}, "Upper Skylands", 575),
    BFBoss(1, "Cyborg", {"Cyborg (Boss)"}, "Fountain City", 675),
    BFBoss(1, "Ice Admiral", {}, "Frozen Village", 700),
    BFBoss(1, "Greybeard", {}, "Marine Fortress", 750, "Raid Boss"),

    BFBoss(2, "Diamond", {"Diamond (Boss)"}, "Kingdom of Rose", 750),
    BFBoss(2, "Jeremy", {}, "Kingdom of Rose", 850),
    BFBoss(2, "Orbitus", {"Fajita"}, "Green Zone", 925),
    BFBoss(2, "Don Swan", {}, "Don Swan's Mansion", 1000),
    BFBoss(2, "Smoke Admiral", {}, "Hot and Cold", 1150),
    BFBoss(2, "Darkbeard", {}, "Dark Arena", 1000, "Raid Boss"),
    BFBoss(2, "Order", {}, "Hot and Cold", 1250, "Raid Boss"),
    BFBoss(2, "Cursed Captain", {}, "Cursed Ship", 1350, "Raid Boss"),
    BFBoss(2, "Awakened Ice Admiral", {}, "Ice Castle", 1400),
    BFBoss(2, "Tide Keeper", {}, "Forgotten Island", 1475),

    BFBoss(3, "Stone", {}, "Port Town", 1550),
    BFBoss(3, "Hydra Leader", {}, "Hydra Island", 1675),
    BFBoss(3, "Kilo Admiral", {}, "Great Tree", 1750),
    BFBoss(3, "Captain Elephant", {}, "Floating Turtle", 1875),
    BFBoss(3, "Beautiful Pirate", {}, "Hydra Island", 1950),
    BFBoss(3, "Longma", {}, "Floating Turtle", 2000),
    BFBoss(3, "Cursed Skeleton Boss", {}, "Haunted Castle", 2025, "Puzzle Boss"),
    BFBoss(3, "Cake Queen", {}, "Sea of Treats", 2175),
    BFBoss(3, "Heaven's Guardian", {}, "Heavenly Dimension", 2200, "Puzzle Boss"),
    BFBoss(3, "Hell's Messenger", {}, "Hell Dimension", 2200, "Puzzle Boss"),
    BFBoss(3, "Cake Prince", {}, "Sea of Treats", 2175, "Summoned Boss"),
    BFBoss(3, "Dough King", {}, "Dimensional Shift", 2300, "Summoned Boss"),
    BFBoss(3, "Terrorshark", {}, "Sea Events", 2000, "Sea Event"),
    BFBoss(3, "Leviathan", {}, "Sea Events", nil, "Sea Event"),
    BFBoss(3, "rip_indra", {"Rip Indra"}, "Castle on the Sea", 5000, "Raid Boss"),
}

-- Magnetized NPCs are ordinary island enemies with an event modifier. The
-- event can choose only the lowest-level enemy group on an island; these are
-- route hints, not a replacement for live modifier detection.
local MAGNET_EVENT = {
    name = "Magnet Night Event",
    token = "Magnet Token",
    skipped = {
        ["Castle on the Sea"] = "hub/safe zone; no normal local enemy route",
        ["Great Tree"] = "current event reference excludes this island",
    },
    routes = {
        -- Third Sea: shortest practical route for a high-level account.
        -- One wide scan covers Peanut, Ice Cream, Cake, Chocolate, and
        -- Candy Cane Land when those sub-islands are streamed together.
        {key = "Sea3:SeaOfTreats", sea = 3, island = "Sea of Treats", label = "Sea of Treats (all five lands)", spawnNames = {"Sea of Treats", "Peanut Land", "Ice Cream Land", "Cake Land", "Chocolate Land", "Candy Cane Land"}, enemy = "lowest event groups", enemyNames = {"Peanut Scout", "Ice Cream Chef", "Cookie Crafter", "Cocoa Warrior", "Candy Pirate"}, scanRange = 3500, guaranteed = true},
        {key = "Sea3:FloatingTurtle", sea = 3, island = "Floating Turtle", label = "Floating Turtle", spawnNames = {"Floating Turtle"}, enemy = "Fishman Raider", guaranteed = true},
        {key = "Sea3:HauntedCastle", sea = 3, island = "Haunted Castle", label = "Haunted Castle", spawnNames = {"Haunted Castle"}, enemy = "Reborn Skeleton", guaranteed = true},
        {key = "Sea3:PortTown", sea = 3, island = "Port Town", label = "Port Town", spawnNames = {"Port Town"}, enemy = "Pirate Millionaire"},
        {key = "Sea3:HydraIsland", sea = 3, island = "Hydra Island", label = "Hydra Island", spawnNames = {"Hydra Island"}, enemy = "Dragon Crew Warrior"},
        {key = "Sea3:TikiOutpost", sea = 3, island = "Tiki Outpost", label = "Tiki Outpost", spawnNames = {"Tiki Outpost"}, enemy = "Isle Outlaw"},
        {key = "Sea3:SubmergedIsland", sea = 3, island = "Submerged Island", label = "Submerged Island", spawnNames = {"Submerged Island"}, enemy = "Reef Bandit"},

        -- Second Sea: useful for the newer account.
        {key = "Sea2:KingdomOfRose", sea = 2, island = "Kingdom of Rose", label = "Kingdom of Rose", spawnNames = {"Kingdom of Rose"}, enemy = "Raider"},
        {key = "Sea2:GreenZone", sea = 2, island = "Green Zone", label = "Green Zone", spawnNames = {"Green Zone", "Docks 3"}, enemy = "Marine Lieutenant"},
        {key = "Sea2:Graveyard", sea = 2, island = "Graveyard Island", label = "Graveyard Island", spawnNames = {"Graveyard", "Graveyard Island"}, enemy = "Zombie"},
        {key = "Sea2:SnowMountain", sea = 2, island = "Snow Mountain", label = "Snow Mountain", spawnNames = {"Snow Mountain"}, enemy = "Snow Trooper"},
        {key = "Sea2:HotAndCold", sea = 2, island = "Hot and Cold", label = "Hot and Cold", spawnNames = {"Hot and Cold", "Lava"}, enemy = "Lab Subordinate"},
        {key = "Sea2:CursedShip", sea = 2, island = "Cursed Ship", label = "Cursed Ship", spawnNames = {"Cursed Ship", "Haunted Ship"}, enemy = "Ship Deckhand"},
        {key = "Sea2:IceCastle", sea = 2, island = "Ice Castle", label = "Ice Castle", spawnNames = {"Ice Castle"}, enemy = "Arctic Warrior"},
        {key = "Sea2:ForgottenIsland", sea = 2, island = "Forgotten Island", label = "Forgotten Island", spawnNames = {"Forgotten Island"}, enemy = "Sea Soldier"},
    },
}

local function normalizeName(value)
    local text = string.lower(tostring(value or ""))
    return (text:gsub("[^%w]", ""))
end

-- =========================================================
-- ITEM OBJECTIVE DATABASE
-- =========================================================
-- An objective source may be an enemy, a tree/world object, or a sea event.
-- Only enemy sources are fully automatable by the current combat adapter.
local ITEM_OBJECTIVES = {
    {
        name = "Vampire Fang",
        aliases = {"Vampire Fangs", "VampireFang"},
        kind = "enemy",
        sources = {
            {
                enemy = "Vampire",
                island = "Graveyard",
                sea = 2,
                level = 975,
                dropRate = "very low / community estimates vary",
            },
        },
        uses = "Sanguine Art, Shark Rod, and weapon upgrades",
    },
    {
        name = "Demonic Wisp",
        aliases = {"Demonic Wisps", "DemonicWisp"},
        kind = "enemy",
        sources = {
            {
                enemy = "Demonic Soul",
                island = "Haunted Castle",
                sea = 3,
                level = 2025,
                dropRate = "very low / not officially published",
            },
        },
        uses = "Sanguine Art, Cursed Dual Katana, Hallow Scythe, and Abyssal Bait",
    },
    {
        name = "Dark Fragment",
        aliases = {"Dark Fragments", "DarkFragment"},
        kind = "enemy",
        sources = {
            {
                enemy = "Darkbeard",
                island = "Dark Arena",
                sea = 2,
                level = 1000,
                isBoss = true,
                dropRate = "raid-boss reward / not officially published",
            },
        },
        uses = "Sanguine Art and other high-level crafting",
        note = "Darkbeard must be summoned; this is not a normal quest enemy.",
    },
    {
        name = "Scrap Metal",
        aliases = {"Scrap", "ScrapMetal"},
        kind = "enemy",
        sources = {
            {enemy = "Pirate", island = "Pirate Village", sea = 1, level = 35},
            {enemy = "Brute", island = "Pirate Village", sea = 1, level = 45},
            {enemy = "Gladiator", island = "Colosseum", sea = 1, level = 275},
            {enemy = "Mercenary", island = "Kingdom of Rose", sea = 2, level = 725},
            {enemy = "Marine Captain", island = "Green Zone", sea = 2, level = 900},
            {enemy = "Lab Subordinate", island = "Hot and Cold", sea = 2, level = 1100},
            {enemy = "Pirate Millionaire", island = "Port Town", sea = 3, level = 1500},
            {enemy = "Pistol Billionaire", island = "Port Town", sea = 3, level = 1525},
            {enemy = "Forest Pirate", island = "Floating Turtle", sea = 3, level = 1825},
            {enemy = "Jungle Pirate", island = "Floating Turtle", sea = 3, level = 1900},
        },
        uses = "Weapon, gun, and crafting upgrades",
    },
    {
        name = "Ectoplasm",
        aliases = {"Ectoplasms"},
        kind = "enemy",
        sources = {
            {enemy = "Ship Deckhand", island = "Cursed Ship", sea = 2, level = 1250},
            {enemy = "Ship Engineer", island = "Cursed Ship", sea = 2, level = 1275},
            {enemy = "Ship Steward", island = "Cursed Ship", sea = 2, level = 1300},
            {enemy = "Ship Officer", island = "Cursed Ship", sea = 2, level = 1325},
        },
        uses = "Ghoul, Midnight Blade, Bizarre Revolver, Ghoul Mask, and Skull Guitar",
    },
    {
        name = "Bones",
        aliases = {"Bone"},
        kind = "enemy",
        sources = {
            {enemy = "Reborn Skeleton", island = "Haunted Castle", sea = 3, level = 1975},
            {enemy = "Living Zombie", island = "Haunted Castle", sea = 3, level = 2000},
            {enemy = "Demonic Soul", island = "Haunted Castle", sea = 3, level = 2025},
            {enemy = "Possessed Mummy", island = "Haunted Castle", sea = 3, level = 2050},
        },
        uses = "Death King Random Surprise and Soul Guitar crafting",
    },
    {
        name = "Conjured Cocoa",
        aliases = {"Cocoa", "ConjuredCocoa"},
        kind = "enemy",
        sources = {
            {enemy = "Cocoa Warrior", island = "Sea of Treats", sea = 3, level = 2300},
            {enemy = "Chocolate Bar Battler", island = "Sea of Treats", sea = 3, level = 2325},
        },
        uses = "Sweet Chalice preparation and weapon upgrades",
        note = "Ten Conjured Cocoa are exchanged with God's Chalice to make Sweet Chalice.",
    },
    {
        name = "Dragon Scale",
        aliases = {"Dragon Scales", "DragonScale"},
        kind = "enemy",
        sources = {
            {enemy = "Dragon Crew Warrior", island = "Hydra Island", sea = 3, level = 1575},
            {enemy = "Dragon Crew Archer", island = "Hydra Island", sea = 3, level = 1600},
        },
        uses = "Weapon upgrades and Godhuman progression",
    },
    {
        name = "Mini Tusk",
        aliases = {"MiniTusks"},
        kind = "enemy",
        sources = {
            {enemy = "Mythological Pirate", island = "Floating Turtle", sea = 3, level = 1850},
        },
        uses = "Weapon upgrades",
    },
    {
        name = "Fish Tail",
        aliases = {"Fish Tails", "FishTail"},
        kind = "enemy",
        sources = {
            {enemy = "Fishman Raider", island = "Floating Turtle", sea = 3, level = 1775},
            {enemy = "Fishman Captain", island = "Floating Turtle", sea = 3, level = 1800},
        },
        uses = "Weapon upgrades and Godhuman progression",
    },
    {
        name = "Gunpowder",
        aliases = {"Gun Powder"},
        kind = "enemy",
        sources = {
            {enemy = "Pistol Billionaire", island = "Port Town", sea = 3, level = 1525},
        },
        uses = "Material objective; the current catalog lists no active crafting use",
    },
    {
        name = "Mystic Droplet",
        aliases = {"Mystic Droplets", "MysticDroplet"},
        kind = "enemy",
        sources = {
            {enemy = "Sea Soldier", island = "Forgotten Island", sea = 2, level = 1425},
            {enemy = "Water Fighter", island = "Forgotten Island", sea = 2, level = 1450},
        },
        uses = "Weapon upgrades and Godhuman progression",
    },
    {
        name = "Nightmare Catcher",
        aliases = {"NightmareCatcher"},
        kind = "enemy",
        sources = {
            {enemy = "Reborn Skeleton", island = "Haunted Castle", sea = 3, level = 1975},
            {enemy = "Living Zombie", island = "Haunted Castle", sea = 3, level = 2000},
        },
        uses = "Pain upgrades",
    },
    {
        name = "Volt Capsule",
        aliases = {"Volt Capsules", "VoltCapsule"},
        kind = "enemy",
        sources = {
            {enemy = "Sea Chanter", island = "Submerged Island", sea = 3, level = 2650},
            {enemy = "Ocean Prophet", island = "Submerged Island", sea = 3, level = 2675},
        },
        uses = "Lightning upgrades",
    },
    {
        name = "Magma Ore",
        aliases = {"Magma Ores", "MagmaOre"},
        kind = "enemy",
        sources = {
            {enemy = "Magma Ninja", island = "Hot and Cold", sea = 2, level = 1175},
            {enemy = "Lava Pirate", island = "Hot and Cold", sea = 2, level = 1200},
        },
        uses = "Weapon upgrades and Godhuman progression",
    },
    {
        name = "Magnet Token",
        aliases = {"Magnet Tokens", "MagnetToken", "MagnetTokens"},
        kind = "event",
        sources = {
            {
                source = "Magnetized or Overcharged Magnetized enemies",
                island = "Third Sea",
                sea = 3,
                level = 1500,
                dropRate = "17-35 per marked enemy (current community reference)",
            },
        },
        uses = "Magnet Gacha; 500 tokens per roll",
        note = "Enable Magnet Event mode. Normal NPC kills do not count.",
    },
    {
        name = "Wooden Plank",
        aliases = {"Wood", "Wood Planks", "WoodenPlank"},
        kind = "tree",
        sources = {
            {
                source = "Breakable trees",
                level = 1,
                dropRate = "varies with Shipwright subclass",
            },
        },
        uses = "Ship and crafting systems",
        note = "This is a world/tree objective, not an enemy drop.",
    },
    {
        name = "Leviathan Heart",
        aliases = {"Leviathan Hearts", "LeviathanHeart"},
        kind = "sea-event",
        sources = {
            {
                source = "Leviathan",
                island = "Tiki Outpost",
                sea = 3,
                level = 1500,
                dropRate = "sea-event reward",
            },
        },
        uses = "Sanguine Art and high-level crafting",
        note = "Requires a Leviathan sea event; this is not a normal NPC farm.",
    },
    {
        name = "God's Chalice",
        aliases = {"Gods Chalice", "GodsChalice", "God Chalice"},
        kind = "special",
        sources = {
            {
                source = "Elite Pirates or rare Third Sea chests",
                island = "Castle on the Sea",
                sea = 3,
                level = 1500,
            },
        },
        uses = "Summoning rip_indra and preparing Sweet Chalice",
        note = "Do not consume or trade automatically; this item is a fragile progression gate.",
    },
    {
        name = "Sweet Chalice",
        aliases = {"SweetChalice"},
        kind = "special",
        sources = {
            {
                source = "Sweet Crafter",
                island = "Sea of Treats",
                sea = 3,
                level = 2300,
            },
        },
        uses = "Summoning Dough King",
        note = "Requires God's Chalice and 10 Conjured Cocoa; do not exchange automatically.",
    },
    {
        name = "Spikey Trident",
        aliases = {"Spiky Trident", "SpikeyTrident"},
        kind = "special",
        sources = {
            {
                source = "Dough King possible drop",
                island = "Sea of Treats",
                sea = 3,
                level = 2300,
            },
        },
        uses = "Late-game sword and Dough King progression",
        note = "Requires the Dough King summon chain and a boss fight; no normal NPC farm source.",
    },
    {
        name = "Skull Guitar",
        aliases = {"Soul Guitar", "SkullGuitar"},
        kind = "special",
        sources = {
            {
                source = "Weird Machine after Skull Guitar Puzzle",
                island = "Haunted Castle",
                sea = 3,
                level = 2300,
            },
        },
        uses = "Mythical gun",
        note = "Requires 500 Bones, 250 Ectoplasm, 1 Dark Fragment, and 5,000 Fragments.",
    },
    {
        name = "Fist of Darkness",
        aliases = {"FistOfDarkness"},
        kind = "special",
        sources = {
            {
                source = "Sea Beast or rare Second Sea chest",
                island = "Dark Arena",
                sea = 2,
                level = 700,
            },
        },
        uses = "Summoning Darkbeard and Cyborg/Slayer progression",
        note = "Disappears on death or leaving the server; sea-beast/chest adapter required.",
    },
}

-- Crafting context is kept separate from the farm source table so the UI can
-- explain why a material is being collected without pretending that a boss or
-- sea event is an ordinary quest target.
local CRAFTING_RECIPES = {
    ["Sanguine Art"] = {
        trainer = "Shafi",
        island = "Tiki Outpost",
        sea = 3,
        beli = 5000000,
        fragments = 5000,
        materials = {
            {item = "Leviathan Heart", amount = 1},
            {item = "Dark Fragment", amount = 2},
            {item = "Demonic Wisp", amount = 20},
            {item = "Vampire Fang", amount = 20},
        },
    },
}

local function getRecipeRequirement(itemName)
    for recipeName, recipe in pairs(CRAFTING_RECIPES) do
        for _, material in ipairs(recipe.materials) do
            if normalizeName(material.item) == normalizeName(itemName) then
                return recipeName, recipe
            end
        end
    end
    return nil, nil
end

local function formatRecipeRequirement(itemName)
    local recipeName, recipe = getRecipeRequirement(itemName)
    if not recipe then
        return nil
    end

    local parts = {}
    for _, material in ipairs(recipe.materials) do
        table.insert(parts, string.format("%d %s", material.amount, material.item))
    end
    return string.format(
        "%s: %s + %d fragments + %d beli",
        recipeName,
        table.concat(parts, ", "),
        recipe.fragments,
        recipe.beli
    )
end

local function getIslandDataByName(rawName)
    local needle = normalizeName(rawName)
    if needle == "" then
        return nil
    end

    local best, bestLength = nil, 0
    for _, island in ipairs(BF_ISLANDS) do
        local names = {island.name}
        for _, alias in ipairs(island.aliases) do
            table.insert(names, alias)
        end
        for _, name in ipairs(names) do
            local normalized = normalizeName(name)
            if normalized ~= "" and string.find(needle, normalized, 1, true)
                and #normalized > bestLength then
                best, bestLength = island, #normalized
            end
        end
    end
    return best
end

local ENEMY_PATTERNS = {}
local BOSS_PATTERNS = {}
for _, island in ipairs(BF_ISLANDS) do
    for _, quest in ipairs(island.quests) do
        table.insert(ENEMY_PATTERNS, {normalizeName(quest.enemy), quest.enemy})
    end
end
for _, boss in ipairs(BF_BOSSES) do
    table.insert(ENEMY_PATTERNS, {normalizeName(boss.name), boss.name})
    table.insert(BOSS_PATTERNS, {normalizeName(boss.name), boss.name})
    for _, alias in ipairs(boss.aliases) do
        table.insert(ENEMY_PATTERNS, {normalizeName(alias), boss.name})
        table.insert(BOSS_PATTERNS, {normalizeName(alias), boss.name})
    end
end
table.sort(ENEMY_PATTERNS, function(a, b) return #a[1] > #b[1] end)
table.sort(BOSS_PATTERNS, function(a, b) return #a[1] > #b[1] end)

local function canonicalEnemyName(rawName)
    local needle = normalizeName(rawName)
    for _, pair in ipairs(ENEMY_PATTERNS) do
        if needle == pair[1]
            or string.find(needle, pair[1], 1, true) then
            return pair[2]
        end
    end
    return rawName
end

local currentContext = {
    sea = nil,
    island = nil,
    area = nil,
    islandData = nil,
    progressionIsland = nil,
    recommendedQuest = nil,
    locationKnown = false,
}
local lastContextRefresh = -math.huge

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
assert(player, "solo_farm_v2 must run on the client")

local stopped = false
local connections = {}
local activeTween = nil
local lastAction = "Starting"
local lastError = ""
local lastStatusAt = 0

local state = {
    generalFarm = false,
    specificFarm = false,
    bossFarm = false,
    chestFinder = false,
    magnetEvent = false,
    teleportEnabled = false,
    intraIslandFT = false,
}

local stats = {
    enemiesKilled = 0,
    bossesKilled = 0,
    magnetizedKilled = 0,
    chestsCollected = 0,
    scans = 0,
    startedAt = 0,
}

local currentSpecificTarget = nil
local currentTargetModel = nil
local questAcceptedFor = nil
local farmStartedAt = 0
local seaGateReached = false
local pendingTravel = nil
local travelGoal = nil
local travelIndex = 0
local selectedDestination = nil

local comm = nil
local spawnFolder = nil
local spawns = {}
local spawnCooldown = {}
local lastSpawnRefresh = -math.huge

local enemyCache = {}
local enemyCacheRange = 0
local lastEnemyScan = -math.huge
local chestCache = {}
local lastChestScan = -math.huge

local ui = {}
local objectiveMode = "Leveling"
local itemTargetName = "Vampire Fang"
local itemTargetAmount = 20
local itemObjectiveComplete = false
local inventorySnapshot = nil
local lastInventoryRead = -math.huge
local magnetRouteIndex = 0
local magnetServerHopRequested = false
local magnetZoneState = {}
local magnetWindowToken = nil

local function log(message)
    if CFG.Debug then
        print("[Solo Farm V2] " .. tostring(message))
    end
end

local function setStatus(message, isError)
    lastAction = tostring(message)
    lastError = isError and tostring(message) or ""
    lastStatusAt = os.clock()
    if ui.status and ui.status.Parent then
        ui.status.Text = lastAction
        ui.status.TextColor3 = isError
            and Color3.fromRGB(255, 145, 145)
            or Color3.fromRGB(205, 220, 235)
    end
    if isError then
        warn("[Solo Farm V2] " .. lastError)
    else
        log(lastAction)
    end
end

local function disconnectAll()
    for _, connection in ipairs(connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(connections)
end

local function safeCall(label, callback)
    local ok, result = xpcall(callback, debug.traceback)
    if not ok then
        setStatus(label .. " failed", true)
        log(result)
        return false, result
    end
    return true, result
end

local function getCharacterParts()
    local character = player.Character
    if not character or not character:IsDescendantOf(workspace) then
        return nil
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if root and humanoid and humanoid.Health > 0 then
        return character, root, humanoid
    end
end

local function waitForCharacter(timeout)
    local deadline = os.clock() + (timeout or CFG.CharacterTimeout)
    repeat
        local character, root, humanoid = getCharacterParts()
        if character then
            return character, root, humanoid
        end
        task.wait(0.15)
    until stopped or os.clock() >= deadline
end

local function getModelRoot(model)
    if not model or not model:IsA("Model") then
        return nil
    end
    return model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart", true)
end

local function getModelPosition(model)
    local root = getModelRoot(model)
    return root and root.Position
end

local function isEnemyModel(model)
    if not model or not model:IsA("Model") then
        return false
    end
    if model == player.Character or Players:GetPlayerFromCharacter(model) then
        return false
    end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and getModelRoot(model) ~= nil
end

local function stripEnemyModifiers(value)
    local text = tostring(value or "")
    -- Clients/updates have rendered the event label as either Magnetized or
    -- Magnified. Strip both spellings before matching the ordinary NPC name.
    text = text:gsub("%b[]", " ")
    text = text:gsub("Overcharged%s+Magnetized", " ")
    text = text:gsub("Overcharged%s+Magnified", " ")
    text = text:gsub("Magnetized", " ")
    text = text:gsub("Magnified", " ")
    return text
end

local function enemyMetadataText(model)
    if not model then
        return ""
    end

    local parts = {model.Name}
    for _, attributeName in ipairs({
        "DisplayName",
        "EnemyType",
        "NPCName",
        "Modifier",
        "Status",
        "Tag",
    }) do
        local value = model:GetAttribute(attributeName)
        if typeof(value) == "string" and value ~= "" then
            table.insert(parts, value)
        end
    end

    -- Some clients render the modifier only through a BillboardGui label.
    -- Read text for detection, but never use it as an attack command.
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
            if descendant.Text and descendant.Text ~= "" then
                table.insert(parts, descendant.Text)
            end
        end
    end
    return table.concat(parts, " ")
end

local function isMagnetizedModel(model)
    if not model then
        return false, nil
    end

    local overcharged = model:GetAttribute("OverchargedMagnetized") == true
        or model:GetAttribute("IsOverchargedMagnetized") == true
        or model:GetAttribute("OverchargedMagnified") == true
        or model:GetAttribute("IsOverchargedMagnified") == true
    local marked = model:GetAttribute("Magnetized") == true
        or model:GetAttribute("IsMagnetized") == true
        or model:GetAttribute("Magnified") == true
        or model:GetAttribute("IsMagnified") == true
    local magnified = model:GetAttribute("Magnified") == true
        or model:GetAttribute("IsMagnified") == true
        or model:GetAttribute("OverchargedMagnified") == true
        or model:GetAttribute("IsOverchargedMagnified") == true

    local ok, magnetizedTag, magnifiedTag = pcall(function()
        return CollectionService:HasTag(model, "Magnetized")
            or CollectionService:HasTag(model, "OverchargedMagnetized"),
            CollectionService:HasTag(model, "Magnified")
                or CollectionService:HasTag(model, "OverchargedMagnified")
    end)
    if ok and (magnetizedTag or magnifiedTag) then
        marked = true
    end
    if ok and magnifiedTag then
        magnified = true
    end

    local text = string.lower(enemyMetadataText(model))
    local overchargedText = string.find(text, "overcharged magnetized", 1, true)
        or string.find(text, "overchargedmagnetized", 1, true)
        or string.find(text, "overcharged magnified", 1, true)
        or string.find(text, "overchargedmagnified", 1, true)
    if overchargedText then
        overcharged = true
        marked = true
        magnified = string.find(text, "magnified", 1, true) ~= nil
    elseif string.find(text, "magnetized", 1, true)
        or string.find(text, "magnified", 1, true) then
        marked = true
        magnified = string.find(text, "magnified", 1, true) ~= nil
    end

    if overcharged then
        return marked, magnified and "Overcharged Magnified" or "Overcharged Magnetized"
    end
    return marked, magnified and "Magnified" or "Magnetized"
end

local function classifyEnemyType(model)
    if not isEnemyModel(model) then
        return nil
    end

    local displayName = model:GetAttribute("DisplayName")
        or model:GetAttribute("EnemyType")
        or model:GetAttribute("NPCName")
    if typeof(displayName) == "string" and displayName ~= "" then
        local cleaned = stripEnemyModifiers(displayName):gsub("%s+", " ")
        return cleaned:match("^%s*(.-)%s*$")
    end

    local lowerName = normalizeName(stripEnemyModifiers(model.Name))
    for _, pair in ipairs(ENEMY_PATTERNS) do
        if string.find(lowerName, pair[1], 1, true) then
            return pair[2]
        end
    end
    return nil
end

local function isBossModel(model)
    if not isEnemyModel(model) then
        return false
    end

    local bossAttribute = model:GetAttribute("IsBoss")
    if typeof(bossAttribute) == "boolean" then
        return bossAttribute
    end

    local lowerName = normalizeName(model.Name)
    for _, pair in ipairs(BOSS_PATTERNS) do
        if string.find(lowerName, pair[1], 1, true) then
            return true
        end
    end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.MaxHealth >= 50000
end

local function getPlayerLevel()
    local containers = {
        player:FindFirstChild("Data"),
        player:FindFirstChild("leaderstats"),
    }
    for _, container in ipairs(containers) do
        if container then
            local level = container:FindFirstChild("Level")
            if level and (level:IsA("IntValue") or level:IsA("NumberValue")) then
                return math.floor(level.Value)
            end
        end
    end
    return nil
end

local function getBestQuestForLevel(island, level, enemyName)
    if not island then
        return nil
    end

    local wanted = enemyName and normalizeName(enemyName) or nil
    if not wanted
        and normalizeName(island.name) == normalizeName("Kingdom of Rose")
        and level and level >= 775
        and level < 925 then
        for _, quest in ipairs(island.quests) do
            if normalizeName(quest.enemy) == normalizeName("Swan Pirate") then
                return quest
            end
        end
    end
    local best
    for _, quest in ipairs(island.quests) do
        local matchesEnemy = not wanted
            or normalizeName(quest.enemy) == wanted
            or string.find(wanted, normalizeName(quest.enemy), 1, true) ~= nil
            or string.find(normalizeName(quest.enemy), wanted, 1, true) ~= nil
        if matchesEnemy and (not level or quest.level <= level)
            and (not best or quest.level > best.level) then
            best = quest
        end
    end
    return best
end

local function getBestProgressionIsland(sea, level, enemyName)
    if not enemyName and sea == 2 and level and level >= 775 and level < 925 then
        return getIslandDataByName("Kingdom of Rose")
    end

    local bestIsland, bestQuestLevel = nil, -math.huge
    for _, island in ipairs(BF_ISLANDS) do
        if island.sea == sea then
            local quest = getBestQuestForLevel(island, level, enemyName)
            if quest and quest.level > bestQuestLevel then
                bestIsland = island
                bestQuestLevel = quest.level
            end
        end
    end
    return bestIsland
end

local function getBestBossForLevel(sea, level)
    local best
    for _, boss in ipairs(BF_BOSSES) do
        if boss.sea == sea and boss.level and boss.level <= (level or 1)
            and (not best or boss.level > best.level) then
            best = boss
        end
    end
    return best
end

local function findQuestForEnemy(enemyName, level)
    local normalized = normalizeName(enemyName)
    local best
    for _, island in ipairs(BF_ISLANDS) do
        local quest = getBestQuestForLevel(island, level, normalized)
        if quest and (not best or quest.level > best.level) then
            best = {
                island = island,
                quest = quest,
            }
        end
    end
    return best
end

local function getItemObjectiveByName(rawName)
    local needle = normalizeName(rawName)
    for _, item in ipairs(ITEM_OBJECTIVES) do
        if needle == normalizeName(item.name) then
            return item
        end
        for _, alias in ipairs(item.aliases) do
            if needle == normalizeName(alias) then
                return item
            end
        end
    end
    return nil
end

local function chooseItemSource(item, level, context)
    if not item then
        return nil, false
    end

    local best, bestLevel = nil, -math.huge
    local fallback, fallbackLevel = nil, math.huge
    for _, source in ipairs(item.sources) do
        if source.level and source.level <= (level or 1)
            and (not context.sea or not source.sea or source.sea == context.sea)
            and source.level > bestLevel then
            best, bestLevel = source, source.level
        end
        if source.level and source.level < fallbackLevel then
            fallback, fallbackLevel = source, source.level
        end
    end

    if best then
        return best, true
    end
    return fallback, fallback ~= nil and fallback.level <= (level or 1)
end

local function describeItemObjective(item, level, context)
    if not item then
        return "Item mode: choose a supported material and amount."
    end

    local source, sourceReady = chooseItemSource(item, level, context)
    if not source then
        return item.name .. " has no source in the database."
    end

    local sourceName = source.enemy or source.source or "world source"
    local location = source.island or "multiple locations"
    local readiness = sourceReady
        and "ready"
        or string.format("requires level %d", source.level or 0)
    local details = string.format(
        "%s: %s at %s (%s)",
        item.name,
        sourceName,
        location,
        readiness
    )
    if item.dropRate then
        details = details .. " • " .. item.dropRate
    elseif source.dropRate then
        details = details .. " • " .. source.dropRate
    end
    if item.note then
        details = details .. " • " .. item.note
    end
    if item.uses then
        details = details .. " • Uses: " .. item.uses
    end
    local recipeDetails = formatRecipeRequirement(item.name)
    if recipeDetails then
        details = details .. " • " .. recipeDetails
    end
    if source.sea and context.sea and source.sea ~= context.sea then
        details = details .. string.format(" • switch to Sea %d", source.sea)
    end
    return details
end

local function countItemInInventoryTable(data, item)
    if type(data) ~= "table" or not item then
        return nil, false
    end

    local target = normalizeName(item.name)
    local count, found = 0, false
    for _, entry in pairs(data) do
        if type(entry) == "table" then
            local entryName = entry.Name or entry.name or entry.ItemName or entry.itemName
            if entryName and normalizeName(entryName) == target then
                local amount = tonumber(entry.Count or entry.count or entry.Amount or entry.amount)
                count += amount or 1
                found = true
            end
        end
    end
    return count, true
end

local function countItemInReplicatedValues(item)
    local containers = {
        player:FindFirstChild("Inventory"),
        player:FindFirstChild("Items"),
        player:FindFirstChild("Data"),
    }
    local target = normalizeName(item.name)
    local count, found = 0, false

    for _, container in ipairs(containers) do
        if container then
            for _, object in ipairs(container:GetDescendants()) do
                if normalizeName(object.Name) == target then
                    local amount
                    if object:IsA("IntValue") or object:IsA("NumberValue") then
                        amount = object.Value
                    else
                        amount = object:GetAttribute("Count")
                            or object:GetAttribute("Amount")
                    end
                    if tonumber(amount) then
                        count += tonumber(amount)
                        found = true
                    end
                end
            end
        end
    end
    return count, found
end

local function readItemCount(item, force)
    if not item then
        return nil, false
    end

    local now = os.clock()
    if not force and now - lastInventoryRead < 2.5 then
        if inventorySnapshot then
            return countItemInInventoryTable(inventorySnapshot, item)
        end
        return countItemInReplicatedValues(item)
    end

    lastInventoryRead = now
    if comm then
        -- The inventory command is inferred from public community clients;
        -- treat a failed response as unknown rather than assuming zero.
        local ok, result = pcall(function()
            return comm:InvokeServer("getInventory")
        end)
        if ok and type(result) == "table" then
            inventorySnapshot = result
            return countItemInInventoryTable(result, item)
        end
    end

    return countItemInReplicatedValues(item)
end

local refreshSpawns

local function detectCurrentContext(force)
    local now = os.clock()
    if not force and now - lastContextRefresh < CFG.ContextRefreshInterval then
        return currentContext
    end

    lastContextRefresh = now
    refreshSpawns(true)

    local _, root = getCharacterParts()
    local nearest, nearestDistance = nil, math.huge
    if root then
        for _, spawn in ipairs(spawns) do
            if spawn.island then
                local distance = (root.Position - spawn.position).Magnitude
                if distance < nearestDistance then
                    nearest, nearestDistance = spawn, distance
                end
            end
        end
    end

    local level = getPlayerLevel() or 1
    local levelSea = level >= 1500 and 3 or (level >= 700 and 2 or 1)
    local islandData = nearest and nearest.island or nil
    if not islandData or nearestDistance > 500 then
        islandData = nil
        for _, candidate in ipairs(BF_ISLANDS) do
            if candidate.sea == levelSea
                and level >= candidate.minLevel
                and level <= candidate.maxLevel
                and #candidate.quests > 0 then
                islandData = candidate
                break
            end
        end
    end

    local sea = islandData and islandData.sea or levelSea
    local currentIslandFitsLevel = islandData
        and #islandData.quests > 0
        and level >= islandData.minLevel
        and level <= islandData.maxLevel
    local efficientProgressionIsland = getBestProgressionIsland(sea, level)
    local prefersSwanRoute = sea == 2 and level >= 775 and level < 925
    local progressionIsland = prefersSwanRoute
        and efficientProgressionIsland
        or currentIslandFitsLevel
        and islandData
        or efficientProgressionIsland

    currentContext.sea = sea
    currentContext.islandData = islandData
    currentContext.progressionIsland = progressionIsland
    currentContext.island = islandData and islandData.name or "Unknown"
    currentContext.area = nearest and nearest.name or currentContext.island
    currentContext.locationKnown = nearest ~= nil and nearestDistance <= 500
    currentContext.recommendedQuest = getBestQuestForLevel(progressionIsland, level)
    return currentContext
end

-- =========================================================
-- SPAWN / TRAVEL
-- =========================================================
local function refreshServices()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    comm = remotes and remotes:FindFirstChild("CommF_")

    local world = workspace:FindFirstChild("_WorldOrigin")
    spawnFolder = world and world:FindFirstChild("PlayerSpawns")
end

refreshSpawns = function(force)
    if not force and os.clock() - lastSpawnRefresh < 4 then
        return
    end
    lastSpawnRefresh = os.clock()
    refreshServices()
    table.clear(spawns)

    if not spawnFolder then
        return
    end

    local teamName = string.lower(player.Team and player.Team.Name or "")
    local preferredFolder = string.find(teamName, "marine", 1, true) and "Marines"
        or string.find(teamName, "pirate", 1, true) and "Pirates"
        or nil
    local folder = preferredFolder and spawnFolder:FindFirstChild(preferredFolder)

    if not folder and not preferredFolder then
        for _, child in ipairs(spawnFolder:GetChildren()) do
            if child:IsA("Folder") then
                folder = child
                break
            end
        end
    end
    if not folder then
        return
    end

    for _, object in ipairs(folder:GetChildren()) do
        local position
        if object:IsA("BasePart") then
            position = object.Position
        elseif object:IsA("Model") then
            position = getModelPosition(object)
        end

        if position then
            table.insert(spawns, {
                name = object.Name,
                key = folder.Name .. "/" .. object.Name,
                position = position,
                island = getIslandDataByName(object.Name),
                team = player.Team,
            })
        end
    end
end

local function nearestSpawn(position, excludeKey)
    local result, bestDistance = nil, math.huge
    for _, spawn in ipairs(spawns) do
        if spawn.key ~= excludeKey and os.clock() >= (spawnCooldown[spawn.key] or 0) then
            local distance = (position - spawn.position).Magnitude
            if distance < bestDistance then
                result, bestDistance = spawn, distance
            end
        end
    end
    return result, bestDistance
end

local function cancelMovement()
    if activeTween then
        pcall(function()
            activeTween:Cancel()
        end)
        activeTween = nil
    end
end

local function moveTo(position, speed)
    local character, root, humanoid = getCharacterParts()
    if not character or not root or not humanoid then
        return false, "character unavailable"
    end

    local distance = (root.Position - position).Magnitude
    if distance <= CFG.AttackDistance then
        return true, "near"
    end
    if distance > CFG.MaxDirectMoveDistance then
        return false, "too far"
    end

    cancelMovement()
    local goal = CFrame.new(position + Vector3.new(0, 2, 0))
    local duration = math.max(0.08, distance / (speed or CFG.MoveSpeed))
    local tween = TweenService:Create(
        root,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        {CFrame = goal}
    )
    activeTween = tween
    tween:Play()

    local deadline = os.clock() + duration + 2
    repeat
        task.wait(0.05)
        if stopped or player.Character ~= character or humanoid.Health <= 0 then
            tween:Cancel()
            if activeTween == tween then
                activeTween = nil
            end
            return false, "movement interrupted"
        end
    until tween.PlaybackState ~= Enum.PlaybackState.Playing or os.clock() >= deadline

    if tween.PlaybackState == Enum.PlaybackState.Playing then
        tween:Cancel()
    end
    if activeTween == tween then
        activeTween = nil
    end

    local arrived = (root.Position - position).Magnitude <= math.max(8, CFG.AttackDistance)
    return arrived, arrived and "arrived" or "movement incomplete"
end

local function horizontalDistance(first, second)
    local offset = first - second
    return math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
end

local function chooseTravelHop(target)
    if not target then
        return nil
    end

    refreshSpawns()
    local _, root = getCharacterParts()
    if not root then
        return target
    end

    local directDistance = horizontalDistance(root.Position, target.position)
    if directDistance <= CFG.MaxTeleportHopDistance then
        return target
    end

    local currentSpawn = nearestSpawn(root.Position)
    local best, bestDistance = target, directDistance
    for _, candidate in ipairs(spawns) do
        if candidate.key ~= target.key
            and (not currentSpawn or candidate.key ~= currentSpawn.key)
            and (state.magnetEvent
                or os.clock() >= (spawnCooldown[candidate.key] or 0)) then
            local fromCurrent = horizontalDistance(root.Position, candidate.position)
            local toGoal = horizontalDistance(candidate.position, target.position)
            if fromCurrent <= CFG.MaxTeleportHopDistance
                and toGoal < bestDistance then
                best, bestDistance = candidate, toGoal
            end
        end
    end

    if best ~= target then
        log(string.format(
            "Long travel %.0f studs: routing through %s (%.0f studs from goal)",
            directDistance,
            best.name,
            bestDistance
        ))
    end
    return best
end

local function respawnAtSpawn(spawn)
    if stopped or not spawn then
        return false, "no spawn"
    end

    local character, root, humanoid = getCharacterParts()
    if not character or not root or not humanoid then
        return false, "character unavailable"
    end

    if horizontalDistance(root.Position, spawn.position) <= CFG.AlreadyAtSpawnRadius then
        return true, "already there"
    end
    if not comm then
        return false, "CommF_ unavailable"
    end

    local oldCharacter = character
    local oldPosition = root.Position
    local head = character:FindFirstChild("Head")
        or character:WaitForChild("Head", 5)
    if not head then
        return false, "head unavailable"
    end

    local invokeOk, invokeResult = pcall(function()
        return comm:InvokeServer("SetLastSpawnPoint", spawn.name)
    end)
    if not invokeOk then
        return false, "spawn request failed: " .. tostring(invokeResult)
    end

    -- Match the working teleport scripts: allow the server's spawn selection
    -- to propagate, then destroy Head before the old character model.
    local ping = 0.05
    pcall(function()
        ping = player:GetNetworkPing()
    end)
    task.wait(math.max(0.1, (ping * 2) + (1 / 60)))
    if stopped or player.Character ~= oldCharacter or humanoid.Health <= 0 then
        return false, "character changed before travel"
    end

    pcall(function()
        if head.Parent then
            head:Destroy()
        end
    end)
    task.wait()
    pcall(function()
        if oldCharacter.Parent then
            oldCharacter:Destroy()
        end
    end)

    local deadline = os.clock() + CFG.CharacterTimeout
    local newCharacter, newRoot, newHumanoid
    repeat
        if stopped then
            return false, "stopped"
        end
        newCharacter, newRoot, newHumanoid = getCharacterParts()
        if newCharacter and newCharacter ~= oldCharacter then
            break
        end
        task.wait(0.15)
    until os.clock() >= deadline

    if not newCharacter or newCharacter == oldCharacter
        or not newRoot or not newHumanoid then
        return false, "respawn timeout"
    end

    task.wait(CFG.ExploreWait)
    refreshServices()
    refreshSpawns(true)
    local distanceFromTarget = horizontalDistance(newRoot.Position, spawn.position)
    if distanceFromTarget > CFG.TeleportArrivalRadius then
        log(string.format(
            "Travel ended %.0f studs from %s (moved %.0f)",
            distanceFromTarget,
            spawn.name,
            (newRoot.Position - oldPosition).Magnitude
        ))
        return false, "destination not confirmed"
    end

    return true, "arrived"
end

local function requestTravel(spawn)
    if not spawn then
        return false
    end
    travelGoal = spawn
    pendingTravel = chooseTravelHop(spawn)
    return pendingTravel ~= nil
end

local function getBossDataByName(rawName)
    local needle = normalizeName(rawName)
    for _, boss in ipairs(BF_BOSSES) do
        if needle == normalizeName(boss.name) then
            return boss
        end
        for _, alias in ipairs(boss.aliases) do
            if needle == normalizeName(alias) then
                return boss
            end
        end
    end
    return nil
end

local function findSpawnForIsland(island)
    if not island then
        return nil
    end
    refreshSpawns()

    local _, root = getCharacterParts()
    local best, bestDistance = nil, math.huge
    for _, spawn in ipairs(spawns) do
        if spawn.island == island then
            local distance = root and (root.Position - spawn.position).Magnitude or 0
            if distance < bestDistance then
                best, bestDistance = spawn, distance
            end
        end
    end
    return best
end

local function queueTravelToIsland(island, reason)
    local spawn = findSpawnForIsland(island)
    if not spawn then
        setStatus("No spawn found for " .. (island and island.name or "unknown island"), true)
        return false
    end

    local _, root = getCharacterParts()
    if root and horizontalDistance(root.Position, spawn.position)
        <= CFG.AlreadyAtSpawnRadius then
        return false
    end

    requestTravel(spawn)
    setStatus("Travel queued: " .. spawn.name .. (reason and (" (" .. reason .. ")") or ""))
    return true
end

local function processTravel()
    if not pendingTravel then
        return false
    end

    local spawn = pendingTravel
    local goal = travelGoal
    pendingTravel = nil
    local ok, reason = false, "not attempted"
    for attempt = 1, CFG.TeleportRetries do
        setStatus(string.format(
            "Traveling to %s (%d/%d)",
            spawn.name,
            attempt,
            CFG.TeleportRetries
        ))
        ok, reason = respawnAtSpawn(spawn)
        if ok or stopped then
            break
        end
        if attempt < CFG.TeleportRetries then
            task.wait(CFG.TeleportRetryDelay)
        end
    end
    if ok then
        local reachedGoal = not goal
        if goal then
            local _, root = getCharacterParts()
            reachedGoal = goal.key == spawn.key
                or (root and horizontalDistance(root.Position, goal.position)
                    <= CFG.TeleportArrivalRadius)
        end

        if reachedGoal then
            travelGoal = nil
            setStatus("Arrived at " .. spawn.name)
        else
            pendingTravel = chooseTravelHop(goal)
            if pendingTravel and pendingTravel.key ~= spawn.key then
                setStatus("Hop complete: continuing to " .. goal.name)
            else
                travelGoal = nil
                setStatus("Arrived near " .. spawn.name)
            end
        end
        spawnCooldown[spawn.key] = nil
    else
        spawnCooldown[spawn.key] = os.clock() + CFG.TravelCooldown
        travelGoal = nil
        setStatus("Travel failed: " .. reason, true)
    end
    return true
end

local function queueNextSpawn()
    refreshSpawns()
    if #spawns == 0 then
        setStatus("No island spawns detected", true)
        return false
    end

    local _, root = getCharacterParts()
    local currentSpawn = root and nearestSpawn(root.Position)
    local currentKey = currentSpawn and currentSpawn.key or nil

    for _ = 1, #spawns do
        travelIndex = (travelIndex % #spawns) + 1
        local spawn = spawns[travelIndex]
        if spawn.key ~= currentKey
            and os.clock() >= (spawnCooldown[spawn.key] or 0) then
            return requestTravel(spawn)
        end
    end
    setStatus("All destinations are on cooldown")
    return false
end

-- =========================================================
-- ENEMY SCANNING
-- =========================================================
local function scanEnemies(maxRange, force)
    local now = os.clock()
    if not force
        and now - lastEnemyScan < CFG.EnemyScanInterval
        and enemyCacheRange >= maxRange then
        return enemyCache
    end

    lastEnemyScan = now
    enemyCacheRange = maxRange
    table.clear(enemyCache)
    stats.scans += 1

    local _, root = getCharacterParts()
    if not root then
        return enemyCache
    end

    local enemyFolder = workspace:FindFirstChild("Enemies")
    local objects = enemyFolder and enemyFolder:GetChildren() or workspace:GetDescendants()
    for _, object in ipairs(objects) do
        if object:IsA("Model") and isEnemyModel(object) then
            local modelRoot = getModelRoot(object)
            local humanoid = object:FindFirstChildOfClass("Humanoid")
            local enemyType = classifyEnemyType(object)
            if modelRoot and humanoid and enemyType then
                local distance = (root.Position - modelRoot.Position).Magnitude
                if distance <= maxRange then
                    local magnetized, magnetVariant = false, nil
                    if state.magnetEvent then
                        magnetized, magnetVariant = isMagnetizedModel(object)
                    end
                    table.insert(enemyCache, {
                        model = object,
                        root = modelRoot,
                        humanoid = humanoid,
                        type = enemyType,
                        isBoss = isBossModel(object),
                        isMagnetized = magnetized,
                        magnetVariant = magnetVariant,
                        position = modelRoot.Position,
                    })
                end
            end
        end
    end
    return enemyCache
end

local function nearestLiving(enemies, predicate)
    local _, root = getCharacterParts()
    if not root then
        return nil
    end

    local result, bestDistance = nil, math.huge
    for _, enemy in ipairs(enemies) do
        if enemy.model
            and enemy.model.Parent
            and enemy.humanoid
            and enemy.humanoid.Health > 0
            and (not predicate or predicate(enemy)) then
            local position = getModelPosition(enemy.model)
            if position then
                local distance = (root.Position - position).Magnitude
                if distance < bestDistance then
                    enemy.position = position
                    enemy.root = getModelRoot(enemy.model)
                    result, bestDistance = enemy, distance
                end
            end
        end
    end
    return result
end

-- =========================================================
-- ATTACK / QUEST HOOKS
-- =========================================================
local function getUsableTool()
    local character = player.Character
    local backpack = player:FindFirstChildOfClass("Backpack")

    local tool = character and character:FindFirstChildOfClass("Tool")
    if tool then
        return tool
    end
    if backpack then
        return backpack:FindFirstChildOfClass("Tool")
    end
end

local function performAttack(enemy)
    -- Generic default: equip the first Tool and activate it.
    -- Replace this function with the target game's real combat input when
    -- its weapon system requires a specific remote or ability call.
    if not enemy or not enemy.model or not enemy.model.Parent then
        return false
    end

    local _, _, humanoid = getCharacterParts()
    local tool = getUsableTool()
    if not humanoid or not tool then
        return false
    end

    pcall(function()
        if tool.Parent ~= player.Character then
            humanoid:EquipTool(tool)
            task.wait()
        end
        tool:Activate()
    end)
    return true
end

local function getEnemyLevel(enemy)
    if not enemy or not enemy.model then
        return 1
    end
    local level = enemy.model:GetAttribute("Level")
        or enemy.model:GetAttribute("EnemyLevel")
    return typeof(level) == "number" and math.floor(level) or 1
end

local function acceptQuestForEnemy(enemyType, enemyLevel)
    local playerLevel = getPlayerLevel() or enemyLevel or 1
    local match = findQuestForEnemy(enemyType, playerLevel)
    local quest = match and match.quest

    -- These quest identifiers are inferred from the game's public client
    -- quest flow and common community implementations. The server remains
    -- authoritative; failure falls back to an in-world ClickDetector.
    if CFG.UseBloxFruitsQuestRemote and comm and quest and quest.questName then
        local invoked, result = pcall(function()
            return comm:InvokeServer(
                "StartQuest",
                quest.questName,
                quest.questIndex,
                1
            )
        end)
        if invoked and result ~= false then
            log(string.format(
                "Quest remote started %s for %s at %s",
                quest.questName,
                quest.enemy,
                match.island.name
            ))
            return true
        end
    end

    local _, root = getCharacterParts()
    if not root then
        return false
    end

    for _, object in ipairs(workspace:GetDescendants()) do
        if object:IsA("ClickDetector") then
            local holder = object.Parent
            local model = holder and holder:FindFirstAncestorOfClass("Model")
            local position = model and getModelPosition(model)
            local lowerName = normalizeName(model and model.Name or "")
            local giverName = quest and normalizeName(quest.giver) or ""
            local looksLikeQuestGiver = string.find(lowerName, "quest", 1, true)
                or string.find(lowerName, "giver", 1, true)
                or (giverName ~= "" and string.find(lowerName, giverName, 1, true))
            if position
                and looksLikeQuestGiver
                and (root.Position - position).Magnitude <= 100 then
                local clicked = pcall(function()
                    object:Click()
                end)
                if clicked then
                    log(string.format(
                        "Quest helper clicked %s for %s Lv%d",
                        model.Name,
                        enemyType,
                        enemyLevel
                    ))
                    return true
                end
            end
        end
    end
    return false
end

local function ensureQuest(enemy)
    if not CFG.EnableQuestHelper or not enemy then
        return
    end

    local level = getPlayerLevel()
    local enemyLevel = getEnemyLevel(enemy)
    local questMatch = findQuestForEnemy(enemy.type, level or enemyLevel)
    local questLevel = questMatch and questMatch.quest.level or enemyLevel
    local questKey = enemy.type .. ":" .. tostring(questLevel)
    if level and questLevel <= level and questAcceptedFor ~= questKey then
        if acceptQuestForEnemy(enemy.type, questLevel) then
            questAcceptedFor = questKey
        end
    end
end

-- =========================================================
-- CHEST DETECTION
-- =========================================================
local function looksLikeChest(object)
    local name = string.lower(object.Name or "")
    return string.find(name, "chest", 1, true) ~= nil
        or object:GetAttribute("IsChest") == true
end

local function chestPartFor(object)
    if object:IsA("BasePart") then
        return object
    end
    if not object:IsA("Model") then
        return nil
    end

    for _, descendant in ipairs(object:GetDescendants()) do
        if descendant:IsA("BasePart")
            and (descendant:FindFirstChild("TouchInterest")
                or descendant:FindFirstChildOfClass("TouchTransmitter")
                or descendant:FindFirstChildOfClass("ClickDetector")
                or descendant.Name == "Handle") then
            return descendant
        end
    end
    return getModelRoot(object)
end

local function chestAvailable(record)
    local part = record and record.part
    if not part or not part.Parent or not part:IsDescendantOf(workspace) then
        return false
    end

    -- The working chest finders only treat a chest as collectable when the
    -- game has replicated its touch/click interaction. This prevents V2 from
    -- counting decorative or streamed-in-but-not-ready chest models.
    return part:FindFirstChild("TouchInterest") ~= nil
        or part:FindFirstChildOfClass("TouchTransmitter") ~= nil
        or part:FindFirstChildOfClass("ClickDetector") ~= nil
        or (record.object and record.object:FindFirstChildOfClass("ClickDetector", true) ~= nil)
end

local function scanChests(force)
    local now = os.clock()
    if not force and now - lastChestScan < CFG.ChestScanInterval then
        return chestCache
    end

    lastChestScan = now
    table.clear(chestCache)
    local seen = {}

    for _, object in ipairs(workspace:GetDescendants()) do
        if (object:IsA("Model") or object:IsA("BasePart"))
            and looksLikeChest(object) then
            local part = chestPartFor(object)
            if part and not seen[part] then
                seen[part] = true
                table.insert(chestCache, {
                    object = object,
                    part = part,
                    name = object.Name,
                    position = part.Position,
                })
            end
        end
    end
    return chestCache
end

local function collectChest(record)
    if not chestAvailable(record) then
        return "unavailable"
    end

    local distance
    local _, root = getCharacterParts()
    if not root then
        return "character unavailable"
    end
    distance = (root.Position - record.position).Magnitude
    if distance > CFG.MaxDirectMoveDistance then
        return "too far"
    end

    setStatus("Collecting " .. record.name)
    local moved, moveReason = moveTo(record.position, CFG.MoveSpeed)
    if not moved then
        return moveReason
    end

    local clickDetector = record.part:FindFirstChildOfClass("ClickDetector")
        or record.object:FindFirstChildOfClass("ClickDetector", true)
    if clickDetector then
        pcall(function()
            clickDetector:Click()
        end)
    end

    local deadline = os.clock() + 2
    repeat
        task.wait(0.1)
        if not chestAvailable(record) then
            stats.chestsCollected += 1
            return "collected"
        end
    until os.clock() >= deadline

    return "not confirmed"
end

local function closestSpawnIgnoringCooldown(position)
    local result, bestDistance = nil, math.huge
    for _, spawn in ipairs(spawns) do
        local distance = horizontalDistance(position, spawn.position)
        if distance < bestDistance then
            result, bestDistance = spawn, distance
        end
    end
    return result, bestDistance
end

-- =========================================================
-- MODE CYCLES
-- =========================================================
local function travelForPosition(position)
    refreshSpawns()
    local _, root = getCharacterParts()
    local currentSpawn = root and nearestSpawn(root.Position)
    local spawn = nearestSpawn(position, currentSpawn and currentSpawn.key or nil)
    if not spawn then
        return false
    end
    return requestTravel(spawn)
end

local function attackEnemy(enemy, isBoss)
    if not enemy or not enemy.model or not enemy.model.Parent then
        return "target lost"
    end

    local position = getModelPosition(enemy.model)
    local humanoid = enemy.model:FindFirstChildOfClass("Humanoid")
    if not position or not humanoid or humanoid.Health <= 0 then
        return "target dead"
    end

    local _, root = getCharacterParts()
    if not root then
        return "character unavailable"
    end

    local distance = (root.Position - position).Magnitude
    if distance > CFG.AttackDistance then
        if distance > CFG.MaxDirectMoveDistance then
            if state.teleportEnabled then
                travelForPosition(position)
                return "travel queued"
            end
            return "target too far"
        end

        local moved, reason = moveTo(position, isBoss and CFG.MoveSpeed * 0.6 or CFG.MoveSpeed)
        if not moved then
            return reason
        end
    end

    if enemy.model ~= currentTargetModel then
        currentTargetModel = enemy.model
        questAcceptedFor = nil
    end

    performAttack(enemy)
    setStatus((isBoss and "Attacking boss: " or "Attacking: ") .. enemy.type)
    task.wait(CFG.AttackInterval)

    if humanoid.Health <= 0 or not humanoid.Parent then
        if isBoss then
            stats.bossesKilled += 1
        elseif enemy.isMagnetized then
            stats.magnetizedKilled += 1
        else
            stats.enemiesKilled += 1
        end
        currentTargetModel = nil
        return "killed"
    end
    return "attacked"
end

local function enemyMatchesName(actual, wanted)
    local left, right = normalizeName(actual), normalizeName(wanted)
    return left == right
        or string.find(left, right, 1, true) ~= nil
        or string.find(right, left, 1, true) ~= nil
end

local function getMagnetClock()
    local format = CFG.MagnetEventTimeBase == "UTC" and "!*t" or "*t"
    local ok, clock = pcall(os.date, format)
    if not ok or type(clock) ~= "table" or type(clock.min) ~= "number" then
        return nil
    end
    return clock
end

local function magnetWindowText()
    local startMinute = math.clamp(
        math.floor(tonumber(CFG.MagnetEventStartMinute) or 0),
        0,
        59
    )
    local duration = math.max(
        1,
        math.floor(tonumber(CFG.MagnetEventDurationMinutes) or 10)
    )
    local endMinute = (startMinute + duration) % 60

    if CFG.MagnetEventTimeBase == "UTC" then
        local offset = math.floor(
            tonumber(CFG.MagnetEventLocalOffsetMinutes) or 330
        )
        local localStart = (startMinute + offset) % 60
        local localEnd = (startMinute + duration + offset) % 60
        return string.format(
            "UTC XX:%02d–XX:%02d / %s XX:%02d–XX:%02d",
            startMinute,
            endMinute,
            tostring(CFG.MagnetEventLocalLabel or "local"),
            localStart,
            localEnd
        )
    end

    return string.format(
        "local XX:%02d–XX:%02d",
        startMinute,
        endMinute
    )
end

local function magnetEventWindowOpen()
    local clock = getMagnetClock()
    if not clock then
        return false
    end
    local startMinute = math.clamp(
        math.floor(tonumber(CFG.MagnetEventStartMinute) or 0),
        0,
        59
    )
    local duration = math.max(
        1,
        math.floor(tonumber(CFG.MagnetEventDurationMinutes) or 10)
    )
    local active = clock.min >= startMinute and clock.min < startMinute + duration
    if active then
        local token = string.format(
            "%s:%s:%s:%s",
            tostring(clock.year or 0),
            tostring(clock.yday or 0),
            tostring(clock.hour or 0),
            tostring(startMinute)
        )
        if magnetWindowToken ~= token then
            table.clear(magnetZoneState)
            magnetRouteIndex = 0
            magnetServerHopRequested = false
            magnetWindowToken = token
        end
    end
    return active
end

local function spawnMatchesRoute(spawn, route)
    if not spawn or not route then
        return false
    end
    local spawnName = normalizeName(spawn.name)
    for _, wanted in ipairs(route.spawnNames or {}) do
        local normalized = normalizeName(wanted)
        if normalized ~= ""
            and (spawnName == normalized
                or string.find(spawnName, normalized, 1, true)
                or string.find(normalized, spawnName, 1, true)) then
            return true
        end
    end
    return route.island
        and spawn.island
        and normalizeName(route.island) == normalizeName(spawn.island.name)
end

local function findMagnetRouteSpawn(route)
    if not route then
        return nil
    end
    refreshSpawns()
    local _, root = getCharacterParts()
    local best, bestDistance = nil, math.huge
    for _, spawn in ipairs(spawns) do
        if spawnMatchesRoute(spawn, route) then
            local distance = root and horizontalDistance(root.Position, spawn.position) or 0
            if distance < bestDistance then
                best, bestDistance = spawn, distance
            end
        end
    end
    return best
end

local function getMagnetZoneState(route)
    local key = route and (route.key or route.island) or "unknown"
    local zone = magnetZoneState[key]
    if not zone then
        zone = {
            key = key,
            label = route and (route.label or route.island) or "unknown zone",
            scans = 0,
            noEnemyScans = 0,
            noMarkedScans = 0,
            everLoaded = false,
            everFoundMagnetized = false,
            cleared = false,
            confidence = nil,
            lastScanAt = -math.huge,
            lastEnemyCount = 0,
            lastTargets = {},
        }
        magnetZoneState[key] = zone
    end
    return zone
end

local function scanMagnetZone(route)
    local zone = getMagnetZoneState(route)
    local now = os.clock()
    if now - zone.lastScanAt < CFG.MagnetZoneLoadWait then
        return zone.lastTargets, zone.lastEnemyCount, zone
    end

    local scanRange = route.scanRange or CFG.MagnetZoneScanRange
    local enemies = scanEnemies(scanRange, true)
    local marked = {}
    local normalCount = 0
    for _, enemy in ipairs(enemies) do
        local isRouteEnemy = route.enemy == "lowest event groups"
            or enemyMatchesName(enemy.type, route.enemy)
        if route.enemyNames then
            isRouteEnemy = false
            for _, enemyName in ipairs(route.enemyNames) do
                if enemyMatchesName(enemy.type, enemyName) then
                    isRouteEnemy = true
                    break
                end
            end
        end
        if not enemy.isBoss and isRouteEnemy then
            normalCount += 1
            if enemy.isMagnetized then
                table.insert(marked, enemy)
            end
        end
    end

    zone.scans += 1
    zone.lastScanAt = now
    zone.lastEnemyCount = normalCount
    zone.lastTargets = marked

    if normalCount > 0 then
        zone.everLoaded = true
        zone.noEnemyScans = 0
    else
        zone.noEnemyScans += 1
    end

    if #marked > 0 then
        zone.everFoundMagnetized = true
        zone.noMarkedScans = 0
        zone.cleared = false
        zone.confidence = nil
    else
        zone.noMarkedScans += 1
    end

    if #marked == 0
        and zone.everLoaded
        and zone.noMarkedScans >= 2 then
        -- We saw live NPC models in this zone and they are now gone or no
        -- longer marked: this is a verified clear for this server pass.
        zone.cleared = true
        zone.confidence = "verified"
    elseif zone.noEnemyScans >= 2 then
        -- Arrival was confirmed, but no enemy model ever replicated. Do not
        -- call this a verified clear; it may be streaming or contested.
        zone.cleared = true
        zone.confidence = "unknown"
    end

    return marked, normalCount, zone
end

local function resetMagnetDiscovery()
    table.clear(magnetZoneState)
    magnetRouteIndex = 0
    magnetServerHopRequested = false
    magnetWindowToken = nil
end

local function requestMagnetServerHop(context)
    if magnetServerHopRequested then
        return true
    end
    magnetServerHopRequested = true

    if type(CFG.ServerHopAdapter) == "function" then
        local ok, result = pcall(CFG.ServerHopAdapter, {
            reason = "Magnet route clear",
            sea = context and context.sea or nil,
            event = MAGNET_EVENT.name,
        })
        if ok and result ~= false then
            setStatus("Magnet route clear; server-hop adapter requested a new server")
            return true
        end
    end

    setStatus(
        "Magnet route clear, but no supported server-hop adapter is configured"
    )
    return false
end

local function currentRouteAtPlayer(route)
    local spawn = findMagnetRouteSpawn(route)
    local _, root = getCharacterParts()
    if spawn and root then
        return spawn, horizontalDistance(root.Position, spawn.position)
    end
    return spawn, math.huge
end

local function runMagnetEventCycle()
    local tokenObjective = objectiveMode == "Item"
        and getItemObjectiveByName(itemTargetName)
        or nil
    if tokenObjective and tokenObjective.kind == "event" then
        local count, known = readItemCount(tokenObjective)
        if known and count >= itemTargetAmount then
            state.magnetEvent = false
            state.generalFarm = false
            setStatus(string.format(
                "Magnet Token objective complete: %d/%d",
                count,
                itemTargetAmount
            ))
            return
        end
    end

    if not magnetEventWindowOpen() then
        setStatus("Magnet Event: waiting for " .. magnetWindowText())
        return
    end

    local context = detectCurrentContext(true)
    local routeCount = #MAGNET_EVENT.routes
    if routeCount == 0 then
        setStatus("Magnet Event: no route data", true)
        return
    end

    local currentRouteIndex, currentRoute, currentSpawn, currentDistance
    for index, route in ipairs(MAGNET_EVENT.routes) do
        if route.sea == context.sea then
            local spawn, distance = currentRouteAtPlayer(route)
            if spawn and distance <= CFG.AlreadyAtSpawnRadius then
                currentRouteIndex = index
                currentRoute = route
                currentSpawn = spawn
                currentDistance = distance
                break
            end
        end
    end

    if currentRoute then
        magnetRouteIndex = currentRouteIndex
        local marked, normalCount, zone = scanMagnetZone(currentRoute)
        local target = nearestLiving(marked, function(enemy)
            return enemy.isMagnetized == true and not enemy.isBoss
        end)
        if target then
            setStatus(string.format(
                "Magnet Event: %s %s at %s",
                target.magnetVariant or "Magnetized",
                target.type,
                currentRoute.label or currentRoute.island
            ))
            attackEnemy(target, false)
            return
        end

        if not zone.cleared then
            setStatus(string.format(
                "Scanning %s: waiting for NPC models (%d scans)",
                zone.label,
                zone.scans
            ))
            return
        end

        setStatus(string.format(
            "Cleared %s (%s; %d NPCs seen)",
            zone.label,
            zone.confidence or "unknown",
            normalCount
        ))
    end

    local _, root = getCharacterParts()
    for offset = 1, routeCount do
        local index = ((magnetRouteIndex + offset - 1) % routeCount) + 1
        local route = MAGNET_EVENT.routes[index]
        if not context.sea or not route.sea or route.sea == context.sea then
            local zone = getMagnetZoneState(route)
            if not zone.cleared then
                local spawn = findMagnetRouteSpawn(route)
                if spawn then
                    magnetRouteIndex = index
                    if not root
                        or not currentSpawn
                        or currentSpawn.key ~= spawn.key then
                        requestTravel(spawn)
                        setStatus(string.format(
                            "Magnet Event: traveling to %s (%s)",
                            route.label or route.island,
                            route.enemy
                        ))
                        return
                    end
                end
            end
        end
    end

    local allCleared, allVerified, matchingRoutes = true, true, 0
    for _, route in ipairs(MAGNET_EVENT.routes) do
        if route.sea == context.sea then
            matchingRoutes += 1
            local zone = getMagnetZoneState(route)
            if not zone.cleared then
                allCleared = false
            end
            if zone.confidence ~= "verified" then
                allVerified = false
            end
        end
    end

    if matchingRoutes == 0 then
        setStatus("Magnet Event: no configured route for Sea " .. tostring(context.sea))
    elseif allCleared and allVerified and CFG.MagnetServerHopAfterClear then
        requestMagnetServerHop(context)
    elseif allCleared then
        setStatus("Magnet Event pass complete; some zones were not verified")
    else
        setStatus("Magnet Event: route scan waiting for the next loaded zone")
    end
end

local function runItemCycle()
    local item = getItemObjectiveByName(itemTargetName)
    if not item then
        setStatus("Choose a supported item objective first", true)
        return
    end

    local count, countKnown = readItemCount(item)
    if countKnown and count >= itemTargetAmount then
        if not itemObjectiveComplete then
            itemObjectiveComplete = true
            state.generalFarm = false
            if item.kind == "event" then
                state.magnetEvent = false
            end
            setStatus(string.format(
                "Item objective complete: %s %d/%d",
                item.name,
                count,
                itemTargetAmount
            ))
        end
        return
    end
    itemObjectiveComplete = false

    local context = detectCurrentContext()
    local level = getPlayerLevel() or 1
    local source, sourceReady = chooseItemSource(item, level, context)
    if not source then
        setStatus("No source is defined for " .. item.name, true)
        return
    end

    local progressText = countKnown
        and string.format("%d/%d", count, itemTargetAmount)
        or string.format("?/%d", itemTargetAmount)

    if not sourceReady then
        setStatus(string.format(
            "%s: reach level %d first (%s)",
            item.name,
            source.level or 0,
            progressText
        ))
        return
    end

    if source.sea and context.sea and source.sea ~= context.sea then
        setStatus(string.format(
            "%s requires Sea %d; current location is Sea %d. Switch seas manually.",
            item.name,
            source.sea,
            context.sea
        ))
        return
    end

    if item.kind == "event" then
        state.magnetEvent = true
        local toggle = ui.toggles and ui.toggles.magnetEvent
        if toggle and toggle.button then
            toggle.button.Text = "ON"
            toggle.button.BackgroundColor3 = Color3.fromRGB(45, 150, 105)
        end
        setStatus("Magnet Token objective armed; waiting for " .. magnetWindowText())
        return
    end

    if item.kind ~= "enemy" then
        if source.island and state.teleportEnabled then
            queueTravelToIsland(getIslandDataByName(source.island), item.name)
        end
        setStatus(string.format(
            "%s %s: %s",
            item.name,
            progressText,
            item.note or "This objective needs a world or event action."
        ))
        return
    end

    local enemies = scanEnemies(CFG.EnemyScanRange)
    local target = nearestLiving(enemies, function(enemy)
        local correctType = enemyMatchesName(enemy.type, source.enemy)
        local correctKind = source.isBoss and enemy.isBoss or not source.isBoss and not enemy.isBoss
        return correctKind and correctType
    end)

    if not target then
        local sourceIsland = getIslandDataByName(source.island)
        setStatus(string.format(
            "%s %s: no %s near %s",
            item.name,
            progressText,
            source.enemy,
            context.island or "current area"
        ))
        if state.teleportEnabled and sourceIsland then
            queueTravelToIsland(sourceIsland, item.name)
        end
        return
    end

    if not source.isBoss then
        ensureQuest(target)
    end
    attackEnemy(target, source.isBoss or target.isBoss)
end

local function runFarmCycle(mode)
    if mode == "General Farm" and objectiveMode == "Item" then
        runItemCycle()
        return
    end

    local context = detectCurrentContext()
    local level = getPlayerLevel() or 1

    if CFG.PauseAtFirstSeaGate
        and CFG.ProgressionGoalLevel > 0
        and context.locationKnown
        and context.sea == 1
        and level >= CFG.ProgressionGoalLevel then
        if not seaGateReached then
            setStatus(string.format(
                "First Sea goal reached (Lv%d). Enter Second Sea to resume.",
                CFG.ProgressionGoalLevel
            ))
        end
        seaGateReached = true
        return
    end
    seaGateReached = false

    local range = mode == "Boss Farm" and CFG.BossScanRange or CFG.EnemyScanRange
    local enemies = scanEnemies(range)
    local target
    local travelIsland

    if mode == "Boss Farm" then
        target = nearestLiving(enemies, function(enemy)
            return enemy.isBoss
        end)
        local bestBoss = getBestBossForLevel(context.sea, level)
        travelIsland = bestBoss and getIslandDataByName(bestBoss.island) or nil
    elseif mode == "Specific Farm" then
        if not currentSpecificTarget or currentSpecificTarget == "" then
            setStatus("Set a specific enemy target first")
            return
        end
        local desired = canonicalEnemyName(currentSpecificTarget)
        target = nearestLiving(enemies, function(enemy)
            return normalizeName(enemy.type) == normalizeName(desired) and not enemy.isBoss
        end)
        local questMatch = findQuestForEnemy(desired, level)
        travelIsland = questMatch and questMatch.island or nil
    else
        local quest = context.recommendedQuest
        target = nearestLiving(enemies, function(enemy)
            return not enemy.isBoss
                and (not quest or normalizeName(enemy.type) == normalizeName(quest.enemy))
        end)
        travelIsland = context.progressionIsland
    end

    if not target then
        local location = context.island or "Unknown island"
        setStatus(mode .. ": no matching target near " .. location)
        if state.teleportEnabled and travelIsland then
            queueTravelToIsland(travelIsland, mode == "General Farm"
                and "level progression"
                or "target location")
        end
        return
    end

    if mode == "Specific Farm" or mode == "General Farm" then
        ensureQuest(target)
    end
    attackEnemy(target, mode == "Boss Farm")
end

local function runChestCycle()
    local chests = scanChests()
    local _, root = getCharacterParts()
    if not root then
        setStatus("Chest Finder: waiting for character")
        return
    end

    refreshSpawns()
    local currentSpawn, currentSpawnDistance = closestSpawnIgnoringCooldown(root.Position)
    local nearestLocal, localDistance = nil, math.huge
    local nearestOther, otherSpawn, otherDistance = nil, nil, math.huge
    for _, chest in ipairs(chests) do
        if chestAvailable(chest) then
            local distance = (root.Position - chest.part.Position).Magnitude
            local chestSpawn, spawnDistance = closestSpawnIgnoringCooldown(chest.part.Position)
            local isLocal = distance <= CFG.LocalIslandRadius
                or (currentSpawn and chestSpawn and chestSpawn.key == currentSpawn.key
                    and currentSpawnDistance <= CFG.LocalIslandRadius)

            if isLocal and distance < localDistance then
                nearestLocal, localDistance = chest, distance
            elseif not isLocal and chestSpawn
                and chestSpawn.key ~= (currentSpawn and currentSpawn.key)
                and os.clock() >= (spawnCooldown[chestSpawn.key] or 0)
                and spawnDistance < otherDistance then
                nearestOther, otherSpawn, otherDistance = chest, chestSpawn, spawnDistance
            end
        end
    end

    if nearestLocal then
        local result = collectChest(nearestLocal)
        if result == "too far" and state.teleportEnabled then
            local chestSpawn = closestSpawnIgnoringCooldown(nearestLocal.position)
            requestTravel(chestSpawn)
        elseif result == "not confirmed" then
            setStatus("Chest interaction not confirmed")
        elseif result ~= "collected" and result ~= "unavailable" then
            setStatus("Chest: " .. result, true)
        end
        return
    end

    if nearestOther and otherSpawn and state.teleportEnabled then
        requestTravel(otherSpawn)
        setStatus("No local chests; traveling to " .. otherSpawn.name)
        return
    end

    setStatus("Chest Finder: no visible chests")
    if state.teleportEnabled then
        queueNextSpawn()
    end
end

local function updateFarmTimer()
    local farming = state.generalFarm or state.specificFarm or state.bossFarm
    if not farming then
        farmStartedAt = 0
        return
    end

    if farmStartedAt == 0 then
        farmStartedAt = os.clock()
    end

    if CFG.FarmDurationMinutes > 0
        and os.clock() - farmStartedAt >= CFG.FarmDurationMinutes * 60 then
        state.generalFarm = false
        state.specificFarm = false
        state.bossFarm = false
        farmStartedAt = 0
        setStatus("Farm duration complete")
    end
end

local function enabledModes()
    local modes = {}
    if state.magnetEvent then table.insert(modes, "Magnet Event") end
    if state.generalFarm then table.insert(modes, "General Farm") end
    if state.specificFarm then table.insert(modes, "Specific Farm") end
    if state.bossFarm then table.insert(modes, "Boss Farm") end
    if state.chestFinder then table.insert(modes, "Chest Finder") end
    return modes
end

local function describeMagnetState(context)
    local parts = {
        "Magnet Event " .. (magnetEventWindowOpen() and "LIVE" or "armed"),
        "window " .. magnetWindowText(),
    }
    local shown = 0
    for _, route in ipairs(MAGNET_EVENT.routes) do
        if route.sea == (context and context.sea) then
            local zone = magnetZoneState[route.key or route.island]
            local stateText = zone and (zone.cleared
                and (zone.confidence or "cleared")
                or (zone.scans > 0 and "scanning" or "pending"))
                or "pending"
            local certainty = route.guaranteed and "guaranteed" or "candidate"
            table.insert(parts, certainty .. " " .. (route.label or route.island) .. ":" .. stateText)
            shown += 1
            if shown >= 3 then
                break
            end
        end
    end
    return table.concat(parts, " | ")
end

-- =========================================================
-- UI
-- =========================================================
local function make(className, properties, parent)
    local object = Instance.new(className)
    for property, value in pairs(properties or {}) do
        pcall(function()
            object[property] = value
        end)
    end
    object.Parent = parent
    return object
end

local function addCorner(object, radius)
    make("UICorner", {
        CornerRadius = UDim.new(0, radius or 8),
    }, object)
end

local function updateMetrics()
    if not ui.metrics or not ui.metrics.Parent then
        return
    end

    local level = getPlayerLevel()
    local context = detectCurrentContext()
    local quest = context.recommendedQuest
    local objectiveItem = objectiveMode == "Item"
        and getItemObjectiveByName(itemTargetName)
        or nil
    local objectiveCount, objectiveKnown
    if objectiveItem then
        objectiveCount, objectiveKnown = readItemCount(objectiveItem)
    end
    local objectiveText = state.magnetEvent
        and "Magnet Event"
        or objectiveItem
        and string.format(
            "%s %s/%d",
            objectiveItem.name,
            objectiveKnown and tostring(objectiveCount) or "?",
            itemTargetAmount
        )
        or objectiveMode
    if ui.objectiveInfo and ui.objectiveInfo.Parent then
        ui.objectiveInfo.Text = state.magnetEvent
            and describeMagnetState(context)
            or objectiveMode == "Item"
            and describeItemObjective(objectiveItem, level or 1, context)
            or "Item target is used when Reason is set to Item."
    end
    local elapsed = stats.startedAt > 0 and (os.clock() - stats.startedAt) or 0
    local farmElapsed = farmStartedAt > 0 and (os.clock() - farmStartedAt) or 0
    ui.metrics.Text = string.format(
        "Objective: %s\nRoute 1 -> 2  |  Sea %s  |  %s\nArea: %s  |  Level %s / Goal %s\nNext: %s Lv%s  |  Giver: %s\nKills %d  |  Magnet %d  |  Bosses %d  |  Chests %d\nUptime %02dm %02ds  |  Farm %02dm %02ds / %sm",
        objectiveText,
        context.sea and tostring(context.sea) or "?",
        context.island or "Detecting...",
        context.area or "Detecting...",
        level and tostring(level) or "?",
        CFG.ProgressionGoalLevel > 0 and tostring(CFG.ProgressionGoalLevel) or "-",
        quest and quest.enemy or "none",
        quest and tostring(quest.level) or "-",
        quest and quest.giver or "-",
        stats.enemiesKilled,
        stats.magnetizedKilled,
        stats.bossesKilled,
        stats.chestsCollected,
        math.floor(elapsed / 60),
        math.floor(elapsed % 60),
        math.floor(farmElapsed / 60),
        math.floor(farmElapsed % 60),
        CFG.FarmDurationMinutes == 0 and "∞" or tostring(CFG.FarmDurationMinutes)
    )

    local modes = enabledModes()
    ui.mode.Text = #modes > 0
        and ("Rotation: " .. table.concat(modes, "  →  "))
        or "Rotation: idle"
    ui.destination.Text = selectedDestination
        and ("Destination: " .. selectedDestination.name)
        or "Destination: none selected"
end

local function updateToggleVisual(toggle, enabled)
    if not toggle or not toggle.button then
        return
    end
    toggle.button.Text = enabled and "ON" or "OFF"
    toggle.button.BackgroundColor3 = enabled
        and Color3.fromRGB(45, 150, 105)
        or Color3.fromRGB(55, 65, 78)
end

local function bindToggle(key, label, description, parent, callback)
    local row = make("Frame", {
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundColor3 = Color3.fromRGB(29, 35, 45),
        BorderSizePixel = 0,
    }, parent)
    addCorner(row, 7)

    local title = make("TextLabel", {
        Size = UDim2.new(1, -80, 0, 22),
        Position = UDim2.fromOffset(12, 5),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = Color3.fromRGB(235, 240, 248),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = label,
    }, row)

    make("TextLabel", {
        Size = UDim2.new(1, -80, 0, 18),
        Position = UDim2.fromOffset(12, 27),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(155, 170, 188),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = description,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)

    local button = make("TextButton", {
        Size = UDim2.fromOffset(52, 28),
        Position = UDim2.new(1, -64, 0.5, -14),
        BackgroundColor3 = Color3.fromRGB(55, 65, 78),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(245, 250, 255),
        Text = "OFF",
        AutoButtonColor = true,
    }, row)
    addCorner(button, 6)

    local toggle = {button = button}
    ui.toggles[key] = toggle
    button.Activated:Connect(function()
        state[key] = not state[key]
        if state[key] and (key == "generalFarm" or key == "specificFarm" or key == "bossFarm") then
            if farmStartedAt == 0 then farmStartedAt = os.clock() end
        end
        callback(state[key])
        updateToggleVisual(toggle, state[key])
        updateMetrics()
    end)
end

-- Forward declaration so the header close button can stop the scheduler even
-- though the lifecycle implementation is defined below the UI builder.
local stopAll

local function createUI()
    if not CFG.LoadUI then
        return
    end

    local playerGui = player:WaitForChild("PlayerGui", 10)
    if not playerGui then
        return
    end

    local old = playerGui:FindFirstChild("SoloFarmV2")
    if old then
        old:Destroy()
    end

    local screen = make("ScreenGui", {
        Name = "SoloFarmV2",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
        DisplayOrder = 20,
    }, playerGui)
    ui.screen = screen

    local camera = workspace.CurrentCamera
    local function getExpandedSize()
        local viewport = camera and camera.ViewportSize or Vector2.new(900, 600)
        local width = math.clamp(math.floor(viewport.X * 0.45), 360, 520)
        local height = math.clamp(math.floor(viewport.Y * 0.78), 460, 720)
        return UDim2.fromOffset(width, height)
    end
    local expandedSize = getExpandedSize()

    local panel = make("Frame", {
        Size = expandedSize,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0.06, 0),
        BackgroundColor3 = Color3.fromRGB(18, 22, 29),
        BorderSizePixel = 0,
    }, screen)
    ui.panel = panel
    addCorner(panel, 12)

    local stroke = make("UIStroke", {
        Color = Color3.fromRGB(66, 87, 112),
        Thickness = 1,
        Transparency = 0.25,
    }, panel)

    local header = make("Frame", {
        Size = UDim2.new(1, 0, 0, 48),
        BackgroundColor3 = Color3.fromRGB(24, 31, 42),
        BorderSizePixel = 0,
    }, panel)
    addCorner(header, 12)

    make("TextLabel", {
        Size = UDim2.new(1, -124, 0, 26),
        Position = UDim2.fromOffset(14, 7),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 18,
        TextColor3 = Color3.fromRGB(105, 205, 255),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "SOLO FARM V2  •  1 → 2 SEA",
    }, header)

    local minimize = make("TextButton", {
        Size = UDim2.fromOffset(30, 28),
        Position = UDim2.new(1, -40, 0, 10),
        BackgroundColor3 = Color3.fromRGB(44, 56, 72),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = Color3.fromRGB(230, 240, 250),
        Text = "—",
    }, header)
    addCorner(minimize, 6)

    local close = make("TextButton", {
        Size = UDim2.fromOffset(30, 28),
        Position = UDim2.new(1, -76, 0, 10),
        BackgroundColor3 = Color3.fromRGB(128, 49, 57),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 19,
        TextColor3 = Color3.fromRGB(255, 235, 235),
        Text = "×",
        AutoButtonColor = true,
    }, header)
    addCorner(close, 6)

    local restore = make("TextButton", {
        Size = UDim2.fromOffset(58, 58),
        Position = UDim2.new(1, -76, 1, -76),
        BackgroundColor3 = Color3.fromRGB(35, 92, 125),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = Color3.fromRGB(240, 250, 255),
        Text = "SF\n+",
        TextWrapped = true,
        Visible = false,
        AutoButtonColor = true,
    }, screen)
    addCorner(restore, 14)
    ui.restore = restore

    local statusBar = make("Frame", {
        Size = UDim2.new(1, -20, 0, 68),
        Position = UDim2.fromOffset(10, 58),
        BackgroundColor3 = Color3.fromRGB(26, 32, 42),
        BorderSizePixel = 0,
    }, panel)
    addCorner(statusBar, 8)

    ui.status = make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 25),
        Position = UDim2.fromOffset(10, 8),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = Color3.fromRGB(205, 220, 235),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Ready",
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, statusBar)

    ui.mode = make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 16),
        Position = UDim2.fromOffset(10, 35),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(145, 165, 185),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Rotation: idle",
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, statusBar)

    ui.destination = make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 15),
        Position = UDim2.fromOffset(10, 51),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(145, 165, 185),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Destination: none selected",
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, statusBar)

    ui.metrics = make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 106),
        Position = UDim2.fromOffset(10, 134),
        BackgroundColor3 = Color3.fromRGB(23, 29, 38),
        BorderSizePixel = 0,
        Font = Enum.Font.Code,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(185, 205, 225),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Text = "Kills  0   |   Bosses  0   |   Chests  0",
    }, panel)
    addCorner(ui.metrics, 8)

    local body = make("ScrollingFrame", {
        Size = UDim2.new(1, -20, 1, -260),
        Position = UDim2.fromOffset(10, 250),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Color3.fromRGB(75, 100, 130),
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, panel)
    local bodyLayout = make("UIListLayout", {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, body)
    make("UIPadding", {
        PaddingBottom = UDim.new(0, 8),
    }, body)

    ui.toggles = {}

    local objectiveTitle = make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = Color3.fromRGB(105, 205, 255),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "OBJECTIVE  •  choose why you are farming",
    }, body)

    local objectiveCard = make("Frame", {
        Size = UDim2.new(1, 0, 0, 136),
        BackgroundColor3 = Color3.fromRGB(29, 35, 45),
        BorderSizePixel = 0,
    }, body)
    addCorner(objectiveCard, 7)

    local objectiveModeButton = make("TextButton", {
        Size = UDim2.new(1, -20, 0, 28),
        Position = UDim2.fromOffset(10, 8),
        BackgroundColor3 = Color3.fromRGB(52, 111, 153),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(240, 248, 255),
        Text = "Reason: Leveling  (tap to change)",
    }, objectiveCard)
    addCorner(objectiveModeButton, 6)

    local itemBox = make("TextBox", {
        Size = UDim2.new(1, -116, 0, 28),
        Position = UDim2.fromOffset(10, 48),
        BackgroundColor3 = Color3.fromRGB(42, 50, 63),
        BorderSizePixel = 0,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(235, 240, 248),
        PlaceholderText = "Item: Vampire Fang",
        PlaceholderColor3 = Color3.fromRGB(145, 160, 180),
        Text = itemTargetName,
        ClearTextOnFocus = false,
    }, objectiveCard)
    addCorner(itemBox, 6)

    local amountBox = make("TextBox", {
        Size = UDim2.fromOffset(94, 28),
        Position = UDim2.new(1, -104, 0, 48),
        BackgroundColor3 = Color3.fromRGB(42, 50, 63),
        BorderSizePixel = 0,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(235, 240, 248),
        PlaceholderText = "Amount",
        PlaceholderColor3 = Color3.fromRGB(145, 160, 180),
        Text = tostring(itemTargetAmount),
        ClearTextOnFocus = false,
    }, objectiveCard)
    addCorner(amountBox, 6)

    ui.objectiveInfo = make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 40),
        Position = UDim2.fromOffset(10, 82),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextColor3 = Color3.fromRGB(165, 185, 205),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Text = "Item mode: choose a supported material and amount.",
    }, objectiveCard)

    local objectiveModes = {"Leveling", "Item", "Money", "Experience"}
    local objectiveModeIndex = 1
    objectiveModeButton.Activated:Connect(function()
        objectiveModeIndex = (objectiveModeIndex % #objectiveModes) + 1
        objectiveMode = objectiveModes[objectiveModeIndex]
        itemObjectiveComplete = false
        objectiveModeButton.Text = "Reason: " .. objectiveMode .. "  (tap to change)"
        setStatus("Objective changed to " .. objectiveMode)
        updateMetrics()
    end)

    itemBox.FocusLost:Connect(function()
        local selected = getItemObjectiveByName(itemBox.Text)
        if selected then
            itemTargetName = selected.name
            itemBox.Text = selected.name
            itemObjectiveComplete = false
            setStatus("Item target: " .. selected.name)
            updateMetrics()
        else
            setStatus("Unsupported item; choose a name from the supported objective database", true)
            itemBox.Text = itemTargetName
        end
    end)

    amountBox.FocusLost:Connect(function()
        local amount = math.floor(tonumber(amountBox.Text) or itemTargetAmount)
        itemTargetAmount = math.max(1, amount)
        amountBox.Text = tostring(itemTargetAmount)
        itemObjectiveComplete = false
        setStatus("Item amount set to " .. tostring(itemTargetAmount))
        updateMetrics()
    end)

    local farmTitle = make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = Color3.fromRGB(105, 205, 255),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "FARMING  •  General Farm follows the objective",
    }, body)

    bindToggle(
        "generalFarm",
        "General Farm",
        "Runs the selected objective using the right enemy/location",
        body,
        function(value)
            setStatus(value and "General Farm enabled" or "General Farm disabled")
        end
    )
    bindToggle(
        "magnetEvent",
        "Magnet Event",
        "Prioritizes marked NPCs during the 10-minute UTC event window",
        body,
        function(value)
            if value then
                resetMagnetDiscovery()
                setStatus("Magnet Event armed — waiting for " .. magnetWindowText())
            else
                setStatus("Magnet Event disabled")
            end
        end
    )
    bindToggle(
        "specificFarm",
        "Specific Farm",
        "Targets a known Blox Fruits enemy by name",
        body,
        function(value)
            setStatus(value and "Specific Farm enabled" or "Specific Farm disabled")
        end
    )
    bindToggle(
        "bossFarm",
        "Boss Farm",
        "Targets nearby boss models",
        body,
        function(value)
            setStatus(value and "Boss Farm enabled" or "Boss Farm disabled")
        end
    )
    bindToggle(
        "chestFinder",
        "Chest Finder",
        "Collects visible chest models or parts",
        body,
        function(value)
            setStatus(value and "Chest Finder enabled" or "Chest Finder disabled")
        end
    )

    local targetCard = make("Frame", {
        Size = UDim2.new(1, 0, 0, 48),
        BackgroundColor3 = Color3.fromRGB(29, 35, 45),
        BorderSizePixel = 0,
    }, body)
    addCorner(targetCard, 7)

    local targetBox = make("TextBox", {
        Size = UDim2.new(1, -116, 0, 28),
        Position = UDim2.fromOffset(10, 10),
        BackgroundColor3 = Color3.fromRGB(42, 50, 63),
        BorderSizePixel = 0,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(235, 240, 248),
        PlaceholderText = "Enemy name, e.g. Bandit",
        PlaceholderColor3 = Color3.fromRGB(145, 160, 180),
        Text = "",
        ClearTextOnFocus = false,
    }, targetCard)
    addCorner(targetBox, 6)

    local setTarget = make("TextButton", {
        Size = UDim2.fromOffset(94, 28),
        Position = UDim2.new(1, -104, 0, 10),
        BackgroundColor3 = Color3.fromRGB(52, 111, 153),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(240, 248, 255),
        Text = "Set target",
    }, targetCard)
    addCorner(setTarget, 6)
    setTarget.Activated:Connect(function()
        currentSpecificTarget = targetBox.Text ~= ""
            and canonicalEnemyName(targetBox.Text)
            or nil
        if currentSpecificTarget then
            targetBox.Text = currentSpecificTarget
        end
        questAcceptedFor = nil
        setStatus(currentSpecificTarget
            and ("Target set: " .. currentSpecificTarget)
            or "Specific target cleared")
    end)

    local travelTitle = make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(105, 205, 255),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "TRAVEL",
    }, body)

    bindToggle(
        "teleportEnabled",
        "Auto Travel",
        "Allows travel when a target is too far away",
        body,
        function(value)
            setStatus(value and "Auto Travel enabled" or "Auto Travel disabled")
        end
    )
    bindToggle(
        "intraIslandFT",
        "Intra-Island Movement",
        "Reserved for game-specific movement routing",
        body,
        function(value)
            setStatus(value
                and "Intra-Island Movement enabled"
                or "Intra-Island Movement disabled")
        end
    )

    local travelCard = make("Frame", {
        Size = UDim2.new(1, 0, 0, 48),
        BackgroundColor3 = Color3.fromRGB(29, 35, 45),
        BorderSizePixel = 0,
    }, body)
    addCorner(travelCard, 7)

    local cycleDestination = make("TextButton", {
        Size = UDim2.new(1, -116, 0, 28),
        Position = UDim2.fromOffset(10, 10),
        BackgroundColor3 = Color3.fromRGB(42, 50, 63),
        BorderSizePixel = 0,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(235, 240, 248),
        Text = "Select destination",
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, travelCard)
    addCorner(cycleDestination, 6)

    local travelNow = make("TextButton", {
        Size = UDim2.fromOffset(94, 28),
        Position = UDim2.new(1, -104, 0, 10),
        BackgroundColor3 = Color3.fromRGB(52, 111, 153),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(240, 248, 255),
        Text = "Travel now",
    }, travelCard)
    addCorner(travelNow, 6)

    cycleDestination.Activated:Connect(function()
        refreshSpawns(true)
        if #spawns == 0 then
            selectedDestination = nil
            cycleDestination.Text = "No islands detected"
            setStatus("No island spawns detected", true)
            return
        end
        local current = 0
        if selectedDestination then
            for index, spawn in ipairs(spawns) do
                if spawn.key == selectedDestination.key then
                    current = index
                    break
                end
            end
        end
        selectedDestination = spawns[(current % #spawns) + 1]
        cycleDestination.Text = selectedDestination.name
        updateMetrics()
    end)

    travelNow.Activated:Connect(function()
        if selectedDestination then
            requestTravel(selectedDestination)
            setStatus("Queued travel to " .. selectedDestination.name)
        else
            setStatus("Select a destination first")
        end
    end)

    local settingsTitle = make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(105, 205, 255),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "SETTINGS",
    }, body)

    local durationButton = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = Color3.fromRGB(29, 35, 45),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(225, 235, 245),
        Text = "Farm duration: 60 min",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, body)
    addCorner(durationButton, 7)
    local durations = {15, 30, 60, 120, 0}
    local durationIndex = 3
    durationButton.Activated:Connect(function()
        durationIndex = (durationIndex % #durations) + 1
        CFG.FarmDurationMinutes = durations[durationIndex]
        durationButton.Text = CFG.FarmDurationMinutes == 0
            and "Farm duration: unlimited"
            or ("Farm duration: " .. CFG.FarmDurationMinutes .. " min")
        setStatus("Farm duration updated")
        updateMetrics()
    end)

    local debugButton = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = Color3.fromRGB(29, 35, 45),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(225, 235, 245),
        Text = "Debug logging: OFF",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, body)
    addCorner(debugButton, 7)
    debugButton.Activated:Connect(function()
        CFG.Debug = not CFG.Debug
        debugButton.Text = "Debug logging: " .. (CFG.Debug and "ON" or "OFF")
        setStatus("Debug logging " .. (CFG.Debug and "enabled" or "disabled"))
    end)

    local magnetClockButton = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = Color3.fromRGB(29, 35, 45),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(225, 235, 245),
        Text = "Magnet window: " .. magnetWindowText(),
        TextXAlignment = Enum.TextXAlignment.Left,
    }, body)
    addCorner(magnetClockButton, 7)
    magnetClockButton.Activated:Connect(function()
        CFG.MagnetEventTimeBase = CFG.MagnetEventTimeBase == "UTC"
            and "LOCAL"
            or "UTC"
        resetMagnetDiscovery()
        magnetClockButton.Text = "Magnet window: " .. magnetWindowText()
        setStatus("Magnet event clock set to " .. magnetWindowText())
    end)

    local refreshButton = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = Color3.fromRGB(42, 83, 108),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(235, 245, 255),
        Text = "Refresh scans and islands",
    }, body)
    addCorner(refreshButton, 7)
    refreshButton.Activated:Connect(function()
        refreshSpawns(true)
        local context = detectCurrentContext(true)
        scanEnemies(CFG.EnemyScanRange, true)
        scanChests(true)
        setStatus(string.format(
            "Refreshed: Sea %s / %s — %d islands, %d enemies, %d chests",
            context.sea and tostring(context.sea) or "?",
            context.island or "unknown island",
            #spawns,
            #enemyCache,
            #chestCache
        ))
    end)

    local stopButton = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 40),
        BackgroundColor3 = Color3.fromRGB(135, 48, 55),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(255, 235, 235),
        Text = "STOP ALL SYSTEMS",
    }, body)
    addCorner(stopButton, 7)
    stopButton.Activated:Connect(function()
        state.generalFarm = false
        state.specificFarm = false
        state.bossFarm = false
        state.chestFinder = false
        state.magnetEvent = false
        state.teleportEnabled = false
        state.intraIslandFT = false
        pendingTravel = nil
        travelGoal = nil
        cancelMovement()
        for key, toggle in pairs(ui.toggles) do
            updateToggleVisual(toggle, false)
        end
        setStatus("All systems stopped")
        updateMetrics()
    end)

    close.Activated:Connect(function()
        if stopAll then
            stopAll()
        end
    end)

    local minimized = false
    minimize.Activated:Connect(function()
        minimized = true
        panel.Visible = false
        restore.Visible = true
    end)

    restore.Activated:Connect(function()
        minimized = false
        expandedSize = getExpandedSize()
        panel.Size = expandedSize
        panel.Visible = true
        restore.Visible = false
    end)

    if camera then
        table.insert(connections, camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            if not minimized and panel.Visible then
                expandedSize = getExpandedSize()
                panel.Size = expandedSize
            end
        end))
    end

    -- Dragging is deliberately limited to the header so controls remain easy
    -- to click on touch devices.
    local dragging = false
    local dragStart
    local startPosition
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = Vector2.new(input.Position.X, input.Position.Y)
            startPosition = panel.Position
        end
    end)
    header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    table.insert(connections, RunService.RenderStepped:Connect(function()
        if dragging and dragStart and startPosition then
            local input = game:GetService("UserInputService"):GetMouseLocation()
            local delta = input - dragStart
            panel.Position = UDim2.new(
                startPosition.X.Scale,
                startPosition.X.Offset + delta.X,
                startPosition.Y.Scale,
                startPosition.Y.Offset + delta.Y
            )
        end
    end))

    setStatus("Ready — choose a mode")
    updateMetrics()
end

-- =========================================================
-- LIFECYCLE / SCHEDULER
-- =========================================================
stopAll = function()
    stopped = true
    cancelMovement()
    disconnectAll()
    if ui.screen then
        ui.screen:Destroy()
        ui.screen = nil
    end
    setStatus("Stopped")
end

stats.startedAt = os.clock()
local uiLoaded, uiError = xpcall(createUI, debug.traceback)
if not uiLoaded then
    warn("[Solo Farm V2] UI failed to load; core scheduler will continue")
    log(uiError)
end
refreshServices()
refreshSpawns(true)

task.spawn(function()
    local cursor = 0
    while not stopped do
        local ok, errorMessage = xpcall(function()
            updateFarmTimer()

            if processTravel() then
                return
            end

            local modes = enabledModes()
            if #modes == 0 then
                setStatus("Idle — enable a mode")
                return
            end

            if state.magnetEvent
                and CFG.MagnetEventPreemptsFarm
                and magnetEventWindowOpen() then
                runMagnetEventCycle()
                return
            end

            cursor = (cursor % #modes) + 1
            local mode = modes[cursor]
            if mode == "Magnet Event" then
                runMagnetEventCycle()
            elseif mode == "Chest Finder" then
                runChestCycle()
            else
                runFarmCycle(mode)
            end
        end, debug.traceback)

        if not ok then
            setStatus("Scheduler recovered from an error", true)
            log(errorMessage)
            task.wait(0.5)
        end

        task.wait(CFG.SchedulerInterval)
    end
end)

task.spawn(function()
    while not stopped do
        task.wait(0.5)
        updateMetrics()
    end
end)

table.insert(connections, player.CharacterAdded:Connect(function()
    currentTargetModel = nil
    questAcceptedFor = nil
    activeTween = nil
    setStatus("Character respawned — resuming")
end))

setStatus("Ready — choose a mode")
log("Solo Farm V2 loaded")
