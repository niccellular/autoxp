-- chase loot to buy from the Bazaar (chasebazaar/init.lua): the level 125 chase loot, Shattering of Ro's
-- "... of Unbound Radiance" (Adroit / Brilliant / Secure / Vigorous jewelry, weapons, shields; Allakhazam lists 46).
-- patterns: Lua patterns matched against the lowercased item name; named: exact lowercased names; never: names never
-- bought even when they match. Add other sets here (e.g. 'blood%-soaked' for Night of Shadows).
return {
    patterns = {
        'of unbound radiance',
    },
    named = {},
    never = {},
}
