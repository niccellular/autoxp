# AutoXP

MacroQuest Lua automation for leveling: finds and pulls mobs, fights, heals, rests and travels, with an ImGui window.

## Install

Put this folder at `<MQ>/lua/autoxp` (or junction it there), then in game:

```
/lua run autoxp [zone]
/autoxp start|stop|pause|resume|show|scan|spells|save
/autoxp mode <Manual|Hunter|Assist|Chase>
/autoxp role <tank|dps>
/autoxp heal|cc [on|off]
```

Settings are saved per character in `<MQ>/config/autoxp_<Name>.lua`; the log goes to `<MQ>/lua/autoxp_log.txt`.

## Requires

- MQ2Nav with meshes for the zones you hunt, MQ2MoveUtils, MQ2EasyFind (travel to the hunt zone).
- Route checks around other mobs use a `Navigation.PathPoints[<dest>]` member added to a local MQ2Nav build.
  On a stock MQ2Nav, pulls fall back to plain path length.

## What it does

- **Modes:** Hunter (finds mobs in a level range and radius), Assist, Chase, Manual.
- **Role:** Tank (front, taunt, stun-lock, target priority, keeps mobs in front) or DPS (behind or at range).
  Heal and CC are separate duties.
- **Class setup:** scans skills, disciplines and class AAs; fills spell lists from memorized gems (heals, stuns, nukes,
  DoTs, slows, mez, pet, buffs); casters and priests fight from range.
- **Pulling:** pull spell, ranged item or Pull ability from a safe distance, then holds while the mob comes.
  Picks the shortest walking route that stays clear of other NPCs, detouring when needed.
- **Movement:** 3D distance and line of sight; navigates on the mesh instead of sticking through walls or floors.
- **Spells:** memorizes higher-level versions of memorized spells out of combat; lists missing spells for your level.
