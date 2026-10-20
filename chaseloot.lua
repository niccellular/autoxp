-- chase loot: the rare tradeable drops AutoXP loots (FIGHT.chaseLoot in init.lua); nothing else is looted.
-- patterns: Lua patterns matched against the lowercased item name; named: exact lowercased names; never: names
-- never looted even when they match. Wanted: Night of Shadows chase loot, the "Blood-soaked ..." items.
return {
    patterns = {
        '^blood%-soaked',       -- Night of Shadows: Blood-soaked ...
    },
    named = {},
    never = {},
}
