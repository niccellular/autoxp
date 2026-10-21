-- chase loot: the rare drops AutoXP loots (FIGHT.chaseLoot in init.lua); nothing else is looted.
-- patterns: Lua patterns matched against the lowercased item name; named: exact lowercased names; never: names
-- never looted even when they match. Re-read every minute, so edits here apply without a reload.
-- A named entry is true (tradeable: the group leader takes a shared one) or the classes that can use a No Trade item,
-- e.g. 'BER MNK WAR' or 'ALL': a shared one goes to a group member of one of those classes, a personal one is looted
-- only by them.
return {
    patterns = {
        '^blood%-soaked',       -- Night of Shadows: Blood-soaked ...
        'of memoryforged desolation$',  -- Laurion's Song: ... of Memoryforged Desolation (trash drops)
    },
    named = {
        -- Night of Shadows, Deepshade: named-mob gear
        ["gilded wand of theatrics"] = true,        -- Drinil
        ["preserved warder's claw"] = true,         -- Psylopsybyl
        ["lost child's doll"] = true,               -- Agaricusus
        ["fragmented crystalline fangs"] = true,    -- Faceted Windra
        ["khala dun arming sword"] = true,
        ["spiritbound epee"] = true,
        ["adorned deepdweller's dagger"] = true,
        ["performer's lucky charm"] = true,
        ["mud-encrusted stole"] = true,
        ["fluorescent fungal cape"] = true,
        -- Laurion's Song, Laurion Inn: named-mob gear (tradeable)
        ["abide"] = true,                                    -- an efreeti
        ["avowed relic of holy revelation"] = true,          -- a statue
        ["bow of fiery revelation"] = true,                  -- a luggald
        ["chalice of celebration"] = true,                   -- a queen widow
        ["club of fiery revelation"] = true,                 -- an owlbear
        ["cummerbund of crippling revelation"] = true,       -- a luggald
        ["ethereal embrace"] = true,                         -- a spectre
        ["forgebound emberquartz earring of the minion"] = true, -- a water dragon
        ["forgebound smallsword of remembered revelation"] = true, -- a water dragon
        ["geonidian steely mask"] = true,                    -- a geonid
        ["illusory indicolite lavaliere"] = true,            -- a spectre
        ["lustrous lapidified bauble"] = true,               -- a lich
        ["pauldrons of the steely myrmidon"] = true,         -- a statue
        ["queen's royal forgebound ring"] = true,            -- a brood queen
        ["royal slasher of consumption"] = true,             -- a brood queen
        ["ruminate"] = true,                                 -- a djinn
        ["sword of forgebound pugnaciousness"] = true,       -- a geonid, a statue
        ["undulating ocelli"] = true,                        -- a queen recluse
        -- Laurion's Song, Timorous Falls: named-mob gear (tradeable)
        ["band of delirious rambling"] = true,               -- A Rallosian Lunatic
        ["cadence cudgel"] = true,                           -- SingleMalt
        ["chiseled chelicera"] = true,                       -- Bunion
        ["choker of collected ire"] = true,                  -- The Dreaded Red Eye
        ["corrupted thirst"] = true,                         -- The Dreaded Red Eye
        ["faktor, destroyer of spinal columns"] = true,      -- A Rallosian Sorcerer, Big Dipper
        ["nightstalker's embrace"] = true,                   -- Big Dipper
        ["oni mask of horatio"] = true,                      -- Horatio
        ["ox tongue of the falls"] = true,                   -- SingleMalt
        ["phoenix tear"] = true,                             -- Flariton
        ["reprisal"] = true,                                 -- Flariton
        ["shoru's elastic band"] = true,                     -- Shoru
        ["song's faint memento"] = true,                     -- Ticktock
        ["sorcerer's outro talisman"] = true,                -- A Rallosian Sorcerer
        ["ticktock's ritual blade of the influencer"] = true, -- Ticktock
        ["willbreaker, the dark omen"] = true,               -- Big Dipper
        -- Laurion's Song, Ankexfen Keep: named-mob gear (tradeable)
        ["bloodthirsty shank"] = true,                       -- Chef Goremand
        ["blue claw"] = true,                                -- Mortimus
        ["bunny song"] = true,                               -- Guard Captain Krizad
        ["diminutive dissonant defender"] = true,            -- Rimeclaw
        ["fandrel's melody"] = true,                         -- Lorekeeper Fandrel
        ["glimmerglish"] = true,                             -- Stablemaster Magna
        ["incandescent spiritualist mantle"] = true,         -- The Mountain Cryptid, Uncia the Snowstalker
        ["laurie's song"] = true,                            -- Lorekeeper Fandrel
        ["magna's refrain"] = true,                          -- Stablemaster Magna
        ["mallet of reprised strength"] = true,              -- Ankexfen Experiment
        ["mooga"] = true,                                    -- Underboss Lazam
        ["mortie's hammer"] = true,                          -- Mortimus
        ["sharp hook"] = true,                               -- Rimeclaw
        ["thick fur ensemble"] = true,                       -- The Mountain Cryptid
        ["vermilion coda of tribute"] = true,                -- Uncia the Snowstalker
        ["wolyenie, eloquent elegy"] = true,                 -- The Mountain Cryptid
        -- Laurion's Song, Moors of Nokk: No Trade named-mob gear (handed to a class that can use it)
        ["battlestaff of virtue"] = 'ENC MAG NEC WIZ',       -- Sergeant Kveldulf
        ["crimson cloak of the bloodmoon"] = 'ALL',          -- Chaplain Kor Bloodmoon
        ["flea infested pauldrons"] = 'ALL',                 -- Fleawalker
        ["kharsk's hoop of companionship"] = 'BST MAG NEC',  -- Sergeant Kharsk
        ["kor's ritual scepter"] = 'CLR DRU SHM',            -- Chaplain Kor Bloodmoon
        ["kveldulf's stud of war"] = 'ALL',                  -- Sergeant Kveldulf
        ["mongrel's muzzle"] = 'BRD PAL SHD WAR',            -- Fleawalker
        ["rod of the firestarter"] = 'BER BST MNK PAL RNG SHD WAR', -- Firestarter Tlag
        ["sash of nokk fury"] = 'ALL',                       -- Captain Defan
        ["scourge blade of tarantis"] = 'PAL SHD',           -- Tarantis
        ["tarantis pedipalp"] = 'ALL',                       -- Tarantis
        ["terrapin scale cloak"] = 'ALL',                    -- Tutt
        ["the sergeant's keepsake"] = 'ALL',                 -- Sergeant Kharsk
        -- Laurion's Song, Unkempt Woods: No Trade named-mob gear (handed to a class that can use it)
        ["basirt's crimson cape"] = 'ALL',                   -- Tenderstump
        ["ceremonial brawler of the rebellion"] = 'BST MNK', -- Oka
        ["dreamspiral"] = 'BRD BST RNG ROG WAR',             -- Oka
        ["feather fury"] = 'PAL ROG SHD WAR',                -- Honored Elder Skraiw
        ["rusty claptrap"] = 'ALL',                          -- Grenn Rustblade
        ["signet of dalnavy"] = 'ALL',                       -- General Orrak
        ["skraiw's golden skull talisman"] = 'ALL',          -- Honored Elder Skraiw
        ["taloned heater shield"] = 'BRD BST MNK PAL RNG ROG SHD WAR', -- Sergeant Korsh
        ["tilion's sword of war"] = 'WAR',                   -- General Orrak
        ["vision of tenderstump"] = 'BER PAL RNG SHD WAR',   -- Tenderstump
        ["voosi's crusher"] = 'BRD BST MNK RNG ROG WAR',     -- Stinky
        ["wyndrazer"] = 'RNG',                               -- Stinky
        ["ze`lee's folly"] = 'BRD RNG ROG WAR',              -- Drillmaster Suja
        -- Laurion's Song, The Hero's Forge: No Trade named-mob gear (handed to a class that can use it)
        ["adorned alloyed dagger"] = 'ENC MAG NEC WIZ',      -- Alloy
        ["compressed stone shard"] = 'ALL',                  -- Terrastride
        ["comrade's cincture of calamity"] = 'ALL',          -- Arcanaforged
        ["emblazoned goblet of vitality"] = 'ALL',           -- Kindleheart
        ["emonet's signet of dedication"] = 'ALL',           -- Ingot
        ["fabulous facade of festivities"] = 'ALL',          -- Valorforged
        ["geomimus' spare wand"] = 'ENC MAG NEC WIZ',        -- Geomimus
        ["guide to the forge"] = 'ALL',                      -- Alloy
        ["mighty mud mantle"] = 'ALL',                       -- Battleforged
        ["sliver of victory"] = 'PAL SHD',                   -- Battleforged
        ["sorick's staff of the transcending spirit"] = 'BST MNK', -- Valorforged
        ["stone-fired blackflame belt"] = 'ALL',             -- Geomimus, Goliath Forge Frog
        ["twisted shank of the quarry"] = 'BRD BST RNG ROG WAR', -- Geomimus
        ["wrought-iron rampart"] = 'BRD PAL SHD WAR',        -- Ingot
        -- Laurion's Song, Pal'Lomen: No Trade named-mob gear (handed to a class that can use it)
        ["blackened shoulder pads"] = 'ALL',                 -- Queen Hotaria
        ["bug squasher"] = 'BRD BST MNK RNG ROG WAR',        -- Bonestripper
        ["carapace locket"] = 'ALL',                         -- Bonestripper
        ["charka's nimbleness"] = 'ALL',                     -- Charka
        ["crushenda"] = 'BER PAL RNG SHD WAR',               -- Crusher the Rusher
        ["death dealer"] = 'ROG',                            -- Fernstalker
        ["general dotal's chicken crusher"] = 'CLR DRU SHM', -- General Dotal
        ["grungy bauble"] = 'ALL',                           -- Charka
        ["hardened brass goblin earring"] = 'ALL',           -- Violet Violence
        ["hardened brass goblin ring"] = 'ALL',              -- General Dotal
        ["kele's tail cutter"] = 'BRD RNG ROG WAR',          -- Fernstalker
        ["protection of periwinkle"] = 'CLR DRU ENC MAG NEC SHM WIZ', -- Cind the Kind
        ["sharpened metallic fingernails"] = 'BST MNK',      -- Tonnar Blevak
        ["white gold goblin earring"] = 'ALL',               -- Tonnar Blevak
        -- Laurion's Song, every zone: named-mob power sources (tradeable)
        ["emberquartz conjuror source"] = true,
        ["emberquartz protector source"] = true,
        ["emberquartz slayer source"] = true,
        ["emberquartz wayfarer source"] = true,
    },
    never = {},
}
