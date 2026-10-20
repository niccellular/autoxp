-- chase loot: the rare tradeable drops AutoXP loots (FIGHT.chaseLoot in init.lua); nothing else is looted.
-- patterns: Lua patterns matched against the lowercased item name; named: exact lowercased names; never: names
-- never looted even when they match. Re-read every minute, so edits here apply without a reload.
return {
    patterns = {
        '^blood%-soaked',       -- Night of Shadows: Blood-soaked ...
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
    },
    never = {},
}
