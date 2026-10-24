# AutoXP

MacroQuest Lua automation for leveling: finds and pulls mobs, fights, heals, rests and travels, with an ImGui window.

## Install

Put this folder at `<MQ>/lua/autoxp` (or junction it there), then in game:

```
/lua run autoxp [zone]          (travels to the zone)
/autoxp start|stop|pause|resume|show|scan|spells|save
/autoxp mode <Manual|Hunter|Named|Assist|Chase>
/autoxp role <tank|dps>
/autoxp heal|cc|debuff|nuke|dot|buff|rez [on|off]
/autoxp group          (show / hide the AutoXP Group window)
/autoxp hud            (show / hide the HUD)
/autoxp backup [on|off]          (backup tank)
/autoxp anchor [on|off]          (Tank: the pull circle stays where I stand now)
/autoxp set <setting> <value>    (any plain setting, e.g. groupHealPct 65)
/autoxp travel [zone]            (travel there, the whole group with "Whole group" on)
/autoxp travel stop
/autoxp named reload|scrape         (Named mode's zone data: load again / read eqresource.com again)
/autoxp invis [ivu]              (cast my invis AAs - what the Named leader asks of the group)
```

Settings are saved per character in `<MQ>/config/autoxp_<Name>.lua`; the log goes to `<MQ>/lua/autoxp_log_<Name>.txt`.

## Requires

- MQ2Nav with meshes for the zones you hunt, MQ2MoveUtils, MQ2EasyFind (travel).
- Named mode in a zone without `named/<zone>.lua`: Python 3 (`pythonw` on the PATH) to read it from eqresource.com.

## What it does

- **Modes:**
  - **Hunter:** pulls mobs in a level range within the pull radius, in the zone it is in (see Pulling).
  - **Named:** the tank hunts only the zone's named mobs and their placeholders, from eqresource.com's Named pages,
    going invisible for walks past other NPCs while the group follows in Chase (see Named mode below; settings on the
    Named tab).
  - **Assist:** fights the group main assist's target (or the "Main assist" character's) once it is at or under
    "Assist at %" (default 95) and has reached the tank; doesn't follow anyone.
  - **Chase:** follows the group main tank (or the "Chase target" character) to within "Chase distance" (default 30),
    and fights like Assist.
  - **Manual:** pulls nothing; fights what is on it and what you target and attack (as Tank, your target is its pick).
- **Role:** Tank (front, taunt, stun-lock, target priority, keeps mobs in front) or DPS (behind or at range).
  Duties are separate toggles: Heal, CC, Debuff, Nuke, DoT, Buff, Rez (e.g. a healer can opt out of nukes or DoTs).
  **Backup** (backup tank): while the group main tank is dead or out of the zone, this character tanks in its place
  (Tank role), and goes back to its own role once the main tank is alive and the fight is over.
  Non-tanks in Chase / Assist join a pulled mob once it has reached the main tank (or after 6s), so they don't
  pull it off the tank on the way in. Following the group main assist, they fight its target whenever it is on their
  extended target list (first pick, next add, and when it switches mid-fight), not their own priority pick.
- **Class setup:** scans skills, disciplines and class AAs; fills spell lists from memorized gems (heals, stuns and hate
  spells, nukes and lifetaps, DoTs, slows, mez, mana spells, pet, buffs); casters and priests fight from range.
  A ranger with a bow holds 40 off its target and backs away when it comes closer, unless backing up would take it
  toward another NPC within the alone radius (one not already fighting the group): then it walks around the mob (30
  degrees at a time either way) to the nearest side where backing up is clear, and backs away there; with no such side
  it holds its spot, and melees the mob while it is too close to shoot. A melee DPS that casts (not the tank, not a bard) gets up to 4s to walk
  behind its target before a debuff, nuke, DoT, burn or DPS ability stops it for a cast (each cast stops the stick);
  heals, mezzes and defense go out at once.
  A list you edit (Spells / Healing tabs, or the settings file's `userLists`) stays as you wrote it when the gems
  change; "Fill from memorized gems" refills them all.
- **Travel** (Travel tab, `/autoxp travel <zone>`): EasyFind to a zone, in any mode, AutoXP started or not. A trip
  leaves once nothing holds it back: no fight, HP and mana above "Rest below %", no resurrection sickness, nobody in
  the group dead or low, no corpse here waiting for a rez. On the way it heals, mezzes and defends; a mob on the
  extended target list within 150 of it or of anyone in the group here stops the trip to fight it, and it sets off again once
  nothing holds it back. The Hunter doesn't pull while a trip waits. **Whole group** sends Travel and Stop to every group member (DanNet `/dggexecute`);
  each leaves once its own holds clear, and the Hunter pulls only once everyone is in the zone. **Return after death**
  (off by default): alive again in another zone after a death (a respawn at the bind point), travel back to the zone
  it died in, or on to the trip it was on.
- **Guild Lobby corpse summon:** alive again in the Guild Lobby within 3 hours of a death elsewhere, a character walks
  to the nearest Priestess of Luclin and says Summon (3 tries), then waits up to 3 minutes for a rez before a trip
  leaves. A character with the Rez duty holds its own trip until the group's corpses there are resurrected (5 minutes
  each at most).
- **Pulling:** pull spell, ranged item or Pull ability from a safe distance, then holds while the mob comes. The tank
  never pulls alone: no pull while a group member here is over 200 away (the hold says when the group main tank is
  someone else - Chase follows the main tank), and near the target it waits up to 60s for the group to catch up.
  Where it stops to pull, no other NPC may be within the alone radius (grey ones, Find Window NPCs and mobs already
  fighting the group aside): with one there it walks to the nearest clear spot around the mob (at the pull distance or
  farther out, within the pull's range; up to 120 degrees around either way, in sight of it) and pulls from there,
  and with none clear it pulls from where it stands.
  A fight that starts on the group during the walk (a mob on the extended target list within 150 of anyone in the
  group) comes first: the tank drops the pull and goes for that mob.
  Hunter picks the mob with the fewest other NPCs within the alone radius (default 100), then the closest by
  walking distance, but only one whose walking route passes no other mob within the alone radius (grey ones and Find
  Window NPCs aside): a route past other mobs drags them along. With no clear route it waits and looks again (the log
  names the mobs in the way). It holds pulls while anyone is under "Rest below %" HP, a healer, CC or nuker (CLR, DRU, SHM,
  ENC, BRD, MAG, WIZ, NEC) is under it in mana (a bard: under 20%), a groupmate is casting its buffs (up to 60s each; a bard's songs
  don't count) or a groupmate is walking to or resurrecting a corpse (up to 3 minutes each).
  NPCs listed in the zone's Find Window (quest givers, merchants, bankers) are never hunted.
  **Anchor** (Tank role, next to Backup): the pull circle normally moves with the tank. Clicking Anchor drops it where
  the tank stands: Hunter then pulls only mobs within the pull radius of that spot, and the map circle (an MQ2Map
  maploc) stays there. It is set only by the button (or `/autoxp anchor`), kept for that zone across reloads, and
  lifted by clicking it again.
- **Named mode** (Named tab): the tank hunts only the zone's named mobs and their placeholders; the group follows in
  Chase. The zone's named, placeholders, the map points players posted in the page comments and every named drop
  (tradeable, or the classes that can use a No Trade one) come from eqresource.com's Named pages, kept in
  `named/<zone>.lua` (the seven Laurion's Song zones are included; another zone is read in the background by
  `tools/named_scrape.py` the first time). Targets are the live spawns with those names - the client sees the whole
  zone; a placeholder of a named with posted map points counts only near one, and one under 100% HP that isn't on
  the extended target list is left to whoever is fighting it. A named up goes first, then the placeholders clockwise
  around the zone (north at 12) from where the tank stands. Before a walk past other NPCs the group goes invisible:
  invisibility versus undead first when undead are along the way (Group Perfected Invisibility to Undead, cast by
  whoever has it), then the bard's Selo's Sonata and Shauri's Sonorous Clouding (AAs 3704, 231; "Invis with" /
  "IVU with" set others); after three asks it goes anyway. It holds for the same reasons as the Hunter, pulls with the
  pull spell, fights what comes, and the chase looter hands out the drops.
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
  the best rez spell, once per corpse (remembered for 3 hours across reloads), standing still for the cast; a group
  member still dead 45s after a rez (interrupted, or the offer lost) is rezzed again. Out of combat a corpse out of reach
  (a group member's, or its own) is dragged over with `/corpse` (a groupmate's needs their consent) - never walked to;
  one that doesn't come (out of range) is looked at again every minute, and let go (`/corpsedrop`) once rezzed. The
  Hunter tank holds its pulls meanwhile.
- **Chase loot:** out of fights, every 3s, from the Advanced Loot window: each character loots its own personal
  chase drops and the group leader hands out the shared ones ("Chase loot", on by default): tradeable ones to himself,
  No Trade ones to a group member of a class that can use them (the classes are listed with the item; the member given
  fewest of that item so far, skipping one who didn't take it). What counts is in
  `chaseloot.lua` (name patterns, exact item names, never-loot): Night of Shadows' "Blood-soaked ..." items and
  Deepshade's named gear, Laurion's Song's "... of Memoryforged Desolation" items, the tradeable named gear of Laurion
  Inn, Timorous Falls and Ankexfen Keep, the No Trade named gear of the LS tier 2 zones, and LS named power sources;
  in a zone with a `named/<zone>.lua`, every drop of its named (Named mode's data, any mode). Nothing else is looted; the file is re-read every minute, so edits apply without a reload.
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
