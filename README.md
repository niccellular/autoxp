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

- **Modes:** Hunter (finds mobs in a level range and radius), Assist, Chase, Manual. The hunt zone is the zone the
  character is in whenever AutoXP starts or Hunter is switched on; picking another in the window while running
  travels there (and `/lua run autoxp <zone>` travels there on the first start).
- **Role:** Tank (front, taunt, stun-lock, target priority, keeps mobs in front) or DPS (behind or at range).
  Duties are separate toggles: Heal, CC, Debuff, Nuke, DoT, Buff, Rez (e.g. a healer can opt out of nukes or DoTs).
  **Backup** (backup tank): while the group main tank is dead or out of the zone, this character tanks in its place
  (Tank role), and goes back to its own role once the main tank is alive and the fight is over.
  Non-tanks in Chase / Assist join a pulled mob once it has reached the main tank (or after 6s), so they don't
  pull it off the tank on the way in.
- **Class setup:** scans skills, disciplines and class AAs; fills spell lists from memorized gems (heals, stuns and hate
  spells, nukes and lifetaps, DoTs, slows, mez, mana spells, pet, buffs); casters and priests fight from range.
  A list you edit (Spells / Healing tabs, or the settings file's `userLists`) stays as you wrote it when the gems
  change; "Fill from memorized gems" refills them all.
- **Hunt-zone travel:** a Hunter in the wrong zone travels to its hunt zone only with its own HP and mana above "Rest
  below %", and never while a groupmate is in the same zone (Chase followers don't follow into another zone).
- **Pulling:** pull spell, ranged item or Pull ability from a safe distance, then holds while the mob comes.
  Hunter picks the mob with the fewest other NPCs within the alone radius (default 100), then the closest by
  walking distance, but only one whose walking route passes no other mob within the alone radius (grey ones and Find
  Window NPCs aside): a route past other mobs drags them along. With no clear route it waits and looks again (the log
  names the mobs in the way). It holds pulls while anyone is under "Rest below %" HP, a healer, CC or nuker (CLR, DRU, SHM,
  ENC, BRD, MAG, WIZ, NEC) is under it in mana (a bard: under 20%), a groupmate is casting its buffs (up to 60s each; a bard's songs
  don't count) or a groupmate is walking to or resurrecting a corpse (up to 3 minutes each).
  NPCs listed in the zone's Find Window (quest givers, merchants, bankers) are never hunted.
- **Movement:** 3D distance and line of sight; navigates on the mesh instead of sticking through walls or floors.
  It goes to a mob like `/nav target` (the whole path, re-pathed as the mob moves) and stops itself once the mob is
  in range, in sight and on its floor.
- **Spells:** memorizes higher-level versions of memorized spells out of combat (never over a spell in a list you
  edited, never a second rank of a line already memorized); lists missing spells for your level. A spell whose
  reagent isn't in the bags is skipped (logged once).
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
- **Abilities scan:** class and archetype AAs (never a gate / teleport / evac one automatically; passive AAs,
  run-speed ones, memory blurs and knockbacks with no real damage (Silent / Sonic Displacement) are Off; an AA that
  can't be kept up is a burn, not a buff; a pet AA is a burn when it makes the pet hit harder, else role Pet).
  Per ability in the settings file:
  `excl = '<tag>'` makes abilities with that tag take turns (the next only once the earlier ones are used and faded),
  `notWith = 'A, B'` skips it while a buff starting with A or B is on you.
- **Fights:** burns on any named on the extended target list, or on 5+ mobs there (Burn on mobs); a discipline that
  lasts waits for the running one. Under Gift of Mana (the next spell is free) the most expensive ready DoT or nuke goes
  first, at any mana; under a twincast (Twincast, Improved Twincast, Bifold Focus) the most expensive one above its
  mana %, or with a twincast order set ("Twincast nukes", "Improved Twincast nukes") the first ready one of it and no
  other nuke until the twincast ends. Your combat buffs go after the burns (the Twincast spell no longer holds up
  Improved Twincast). Swarm pets are sent in with the pet (/pet swarm). A spell is skipped while an item it needs
  (used up or not) isn't in the bags. DoTs wait under "DoTs above mana %" (40), nukes under "Nuke above mana %". A beastlord's abilities go before
  its spells.
  A detrimental AE (PB, targeted, directional) only goes off with 2+ mobs on XTarget, no mezzed one in its reach and
  no idle NPC there. Named mobs are never mezzed, and keep their DoTs and debuffs down to 5%. The tank casts its hate
  spells when its aggro slips. Tank buffs (a list) are kept on the group main tank in fights (a mage's short damage
  shields), recast when your cast of it runs out.
- **Invisibility:** while invisible and not in a fight (nothing on the extended target list, not pulling or
  engaging), no casts, abilities, songs, item clicks, buffs or rezzes: a bard's group invis lasts the trip.
- **Bards:** in a fight the abilities go first (Fierce Eye, Kick, the burns, Bellow), then the next
  song in the Songs list. Songs are sung on the move: following, closing in and melee carry on during a song, and a
  group or self song keeps the fight target.
- **Buff duty:** self, group and pet buffs; each group member in range is checked every 30s, and a group version
  within 10 levels of the best single-target one wins (one cast buffs everybody). Idle with nothing around, the
  buffers go over their buffs before the next pull. A buff the game refuses ("Blocked by" a better one) isn't
  cast again on anyone who has that better buff.
- **Mana:** under the mana-tools % (default 50), in or out of combat, clicks a Modulation Shard from the bags (above
  70% HP), else uses a Mana ability (role Mana: Elemental Conversion, Cannibalization; Summon Modulation Shard only
  when none is in the bags), else a Mana spell (Gather Zeal, Traumatic Exchange). One that costs health keeps 20% HP
  back (30% in a fight). A Mana ability for others goes to the group: a single-target one (Focused Paragon of Spirits)
  on whoever is lowest under 80% mana, a group one (Paragon of Spirit) when anyone is under 60%, one used on the mob
  when a caster is under 30% (a bard's Reflexive Rebuttal) or its own mana is low (Thought Leech). Out of combat a
  bard's Rallying Call goes to a caster under 30% mana.
- **Cursor:** a summoned item left on the cursor (Modulation Shard, mod rod, pet weapon) goes into the bags after 2s
  (with a full hand nothing can be memorized); never while a trade, give, merchant or bank window is open.
- **Rez duty:** in a fight only Call of the Wild (no exp, on someone still dead), 10s after they died and only while
  the main tank and main assist are alive (heals come first); out of combat an exp rez AA or
  the best rez spell, once per corpse (remembered for 3 hours across reloads). Out of combat it walks on the mesh to
  any group member's corpse in the zone (and its own), giving up on one after 90s; the Hunter tank holds its pulls
  meanwhile.
- **Chase loot:** out of fights, every 3s, from the Advanced Loot window: each character loots its own personal
  chase drops and the group leader gives the shared ones to himself ("Chase loot", on by default). What counts is in
  `chaseloot.lua` (name patterns, exact item names, never-loot): Night of Shadows' "Blood-soaked ..." items and
  Deepshade's named gear. Nothing else is looted; the file is re-read every minute, so edits apply without a reload.
- **Pets:** mages hand two summoned weapons to every unarmed pet in the group (noticed while idle too), using a
  folded pack from the bags before casting the grant again; the pouch is destroyed once it's empty. In fights a pet
  under 80% HP gets its guards (role Pet: Companion's Aegis, Host in the Shell, Companion's Fortification) and one under
  30% its heal (Mend Companion). Out of fights each new pet is shrunk (Diminutive Companion, Shrink AA, else a Shrink
  spell from the book) down to the smallest it goes ("Shrink pet", on by default).
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
