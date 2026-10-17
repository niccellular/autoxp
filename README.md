# AutoXP

MacroQuest Lua automation for leveling: finds and pulls mobs, fights, heals, rests and travels, with an ImGui window.

## Install

Put this folder at `<MQ>/lua/autoxp` (or junction it there), then in game:

```
/lua run autoxp [zone]
/autoxp start|stop|pause|resume|show|scan|spells|save
/autoxp mode <Manual|Hunter|Assist|Chase>
/autoxp role <tank|dps>
/autoxp heal|cc|debuff|nuke|dot|buff|rez [on|off]
/autoxp group          (show / hide the AutoXP Group window)
/autoxp hud            (show / hide the HUD)
/autoxp backup [on|off]          (backup tank)
/autoxp set <setting> <value>    (any plain setting, e.g. groupHealPct 65)
```

Settings are saved per character in `<MQ>/config/autoxp_<Name>.lua`; the log goes to `<MQ>/lua/autoxp_log_<Name>.txt`.

## Requires

- MQ2Nav with meshes for the zones you hunt, MQ2MoveUtils, MQ2EasyFind (travel to the hunt zone).

## What it does

- **Modes:** Hunter (finds mobs in a level range and radius), Assist, Chase, Manual.
- **Role:** Tank (front, taunt, stun-lock, target priority, keeps mobs in front) or DPS (behind or at range).
  Duties are separate toggles: Heal, CC, Debuff, Nuke, DoT, Buff, Rez (e.g. a healer can opt out of nukes or DoTs).
  **Backup** (backup tank): while the group main tank is dead or out of the zone, this character tanks in its place
  (Tank role), and goes back to its own role once the main tank is alive and the fight is over.
  Non-tanks in Chase / Assist join a pulled mob once it has reached the main tank (or after 6s), so they don't
  pull it off the tank on the way in.
- **Class setup:** scans skills, disciplines and class AAs; fills spell lists from memorized gems (heals, stuns, nukes,
  DoTs, slows, mez, pet, buffs); casters and priests fight from range.
- **Pulling:** pull spell, ranged item or Pull ability from a safe distance, then holds while the mob comes.
  Hunter picks the mob with the fewest other NPCs within the alone radius (default 100), then the closest by
  walking distance, and holds pulls while anyone is under "Rest below %" HP, a healer, CC or nuker (CLR, DRU, SHM,
  ENC, BRD, MAG, WIZ, NEC) is under it in mana, or a groupmate is casting its buffs (up to 60s each).
  NPCs listed in the zone's Find Window (quest givers, merchants, bankers) are never hunted.
- **Movement:** 3D distance and line of sight; navigates on the mesh instead of sticking through walls or floors.
- **Spells:** memorizes higher-level versions of memorized spells out of combat; lists missing spells for your level.
  Healers (Heal duty) keep the two best direct single-target heals and the two best heals-over-time memorized.
- **CC duty:** mezzes adds as soon as they show up (in any state, right after heals) and never the tank's target.
  Two or more awake adds around the caster take the AE mez (bards: Wave of ..., kept memorized; a nuke's gem is
  used when Nuke duty is off), otherwise single mezzes nearest first; a resisted mez is recast right away, and
  after a 2nd resist on the same add the mezzer gives up on it (back to the other adds and songs).
- **Debuff duty:** slow, malo and cripple the target, then each add — a malo'd add takes a mez far more often
  (bard mezzes are Magic-resisted) and a slowed one hits softer. With a bard or enchanter in the group the adds
  waiting on a mez get the malo first, from any state. Mezzed adds only get debuffs that do no damage.
  Debuff abilities (role Debuff: Malaise, Wind of Malaise, Sha's Reprisal...) go before the Debuffs list, and a mob
  gets one of each kind (malo, slow, cripple). Who debuffs is per character: turn Debuff off on a healer to keep it
  healing (e.g. the mage malos, the beastlord slows, the shaman heals).
- **Abilities scan:** class and archetype AAs (never a gate / teleport / evac one automatically).
- **Buff duty:** self, group and pet buffs; each group member in range is checked every 30s, and a group version
  within 10 levels of the best single-target one wins (one cast buffs everybody). Idle with nothing around, the
  buffers go over their buffs before the next pull.
- **Mana:** under 50% mana, in or out of combat, clicks a Modulation Shard from the bags (above 70% HP), else uses
  a Mana ability (role Mana: Elemental Conversion; Summon Modulation Shard only when none is in the bags).
- **Rez duty:** in a fight only Call of the Wild (no exp, on someone still dead); out of combat an exp rez AA or
  the best rez spell, once per corpse. Out of combat a character with a rez also resurrects its own corpse, walking
  to it on the mesh first.
- **Pets:** mages hand two summoned weapons to every unarmed pet in the group (noticed while idle too), using a
  folded pack from the bags before casting the grant again; the pouch is destroyed once it's empty.
- **Group window:** one row per DanNet peer running AutoXP — HP / mana / endurance, AutoXP state, target, status
  icons (dead, rez sickness, invis, invis vs undead, aggro, casting, sitting, stunned, pet, cure needed, other zone)
  and its latest log line; hover a name for details (duties, kills, XP and AA per hour), click it to target.
  Each AutoXP publishes its status as the `${AutoXP}` TLO and reads the others through one DanNet observer each.
  A DPS column and the group's total DPS come from each character's own count.
- **HUD:** a small see-through window: DPS now (last 10s), this fight, last fight and per second of fighting;
  damage this session split into melee / spells / DoTs / pets / damage shields; top hit; kills per hour and seconds
  per kill; XP and AA per hour and time to level; group DPS. Right-click it to reset the stats or hide it.
  Damage is read from your own combat messages (keep "My hits", "My pet's hits" and DoT messages on in the chat
  filters); `${AutoXP[dps]}` gives the raw breakdown.
