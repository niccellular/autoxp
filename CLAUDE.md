## AutoXP — working rules

MacroQuest Lua leveling automation (`init.lua`, `zones.lua`). Private repo niccellular/autoxp, branch `main`.

### Where it runs
- `<MQ>/lua/autoxp` is a **junction** to this folder, so `/lua run autoxp` runs this working copy.
  Never create `lua/autoxp.lua` — a file there shadows the folder. MQ runtime: `openvanilla-master/build/solution/bin/debug`.
- Log: `<MQ>/lua/autoxp_log_<Name>.txt` (one per character). Settings per character: `<MQ>/config/autoxp_<Name>.lua`.

### Editing workflow
1. Patch with a small Python script (exact old/new strings, assert each occurs once; keep CRLF/LF as found).
   In a Bash heredoc, `\n` in a Lua string becomes a real newline — build it with `chr(92) + 'n'`.
2. Syntax check: `build/solution/vcpkg_installed/x64-windows-static/tools/luajit/luajit.exe -e "print(loadfile('init.lua'))"`.
3. Check nothing is used before its `local` / `local function` definition (a forward reference silently becomes a
   nil global — e.g. a table declared below the function that uses it).
4. Reload only between fights (`${Me.XTarget}` == 0): `/autoxp save` FIRST (`/lua stop` kills the script without
   saving, so unsaved UI changes like the hunt zone are lost), then `/lua stop autoxp`, `/lua run autoxp`, `/autoxp start`.
   In Tank role + Manual mode, whatever is targeted at start counts as the player's pick.
5. Watch the log for the change, then commit/push only when asked (ncellular, no attribution).

### MQ / ImGui gotchas
- `ImGui.SetTooltip` is printf-style: always `SetTooltip('%s', text)` (a literal `%` crashes the overlay).
  If ImGui pauses after an error: `/mqoverlay resume`.
- Inline `/lua parse` mangles strings with `/` or spaces — write a temporary `lua/mqt_*.lua` probe, delete it after.
- Unloading a plugin (e.g. mq2moveutils, mq2nav) kills scripts using its TLOs — restart AutoXP after.
- `NearestSpawn … radius` is 2D; multi-floor zones fill the nearest list with mobs on other floors.
  A mob with `PathLength == -1` is off the navmesh (velketor's mesh only connects one floor).
- A living mob can read `PctHPs` 0 and a fresh corpse can read 3% — death is `Type() == 'Corpse'`, never HP%.
- A bard keeps `Me.Casting` set while it holds a song: for bards "busy" is `Window('CastingWindow').Open()`,
  and a new song needs `/stopsong` first. While any spell casts, every gem reads not-ready: use `Me.GemTimer(name)`.
- `/assist` can switch auto-attack on (game option). Followers read `Me.GroupAssistTarget` (the group MA's target) instead.
- Unity spells last ~6s and cast the real buffs (`Spell.Trigger(i)`); judge them by what they trigger.
  SPA 470 triggers resolve only on a character who knows the spell line.
- LuaJIT allows a function at most 60 upvalues: `step()` is near it, so new state logic goes in its own function
  (like `fightTick()`); the luajit `loadfile` check reports "more than 60 upvalues".
- The main chunk is near LuaJIT's 200-local limit ("main function has more than 200 local variables"). The limit
  counts every local live at one point, so a `do … end` block's locals add to the top-level ones above it; they're
  freed after the block. Keep a feature's tables and helpers in a block and expose only what's used outside
  (see the buff helpers, `doPetWeapons`, the UI block).
- Some native lookups fault instead of returning nil and end the script with no Lua error ("Abnormal exception thrown
  from coroutine!"): `Spawn.MyBuff` and `Spell.Trigger` on some Luclin mobs / trigger spells. On a mob, track what
  AutoXP cast itself (`R.mobCast`). To find such a fault, write a breadcrumb file each step (last step before it dies).
- The ImGui callback can't yield: nothing that calls `mq.delay` (e.g. `scanAbilities`) from a button — set a flag
  and run it in the main loop. An error between `BeginChild` / `EndChild` gives "Missing EndChild()", which pauses
  ImGui and ends the script: the error path closes the child.
- A dead group member's slot points at their corpse (`Type() == 'Corpse'`) — skip it for heals and buffs.
- Find Window: `/windowstate FindLocationWnd open` makes the server send the zone's list; read
  `Window('FindLocationWnd').Child('FLW_FindLocationList').List(row, 1)` = category ("Quests", "Zone Connection",
  "(Group)"…), `List(row, 2)` = name, `List(row, 3)` = distance.
- In Git Bash, `python mcp.py raw '/dex …'` turns `/dex` into a Windows path: `export MSYS_NO_PATHCONV=1` first.
  `/dex` to the client MQMCPServer runs on does nothing — send that one its command directly. Which client hosts
  it changes (Ramakrr, later Zenban): check with `/echo ${Me.Name}` before sending anything.
- Group window: each AutoXP publishes `${AutoXP}` (`mq.AddTopLevelObject`, a '|'-separated status rebuilt once a
  second; field order in `FIELDS`). Peers read it with one DanNet observer each (`/dobserve test_<name> -q AutoXP`,
  `DanNet(peer).Observe('AutoXP')`); DanNet only sends changes, so a 5s heartbeat field marks a gone peer.
  A Lua TLO function must `return 'string', value` (type name + value) or it reads NULL. The DanNet TLO forgets
  its peer after one member: never reuse `local dn = mq.TLO.DanNet(peer)` for a second member.
- Damage message formats (DPS): `You crush X for N points of damage. (Critical)`, `You hit X for N points of poison
  damage by Oka's Bite. (Critical Twincast)`, `X is burned by YOUR flames for N points of non-melee damage.`,
  `<PetName> bashes X for N points…`, swarm pets `<Me>\`s pet bashes…`, DoTs `X has taken N damage from <Spell> by
  <Caster>. (Critical)`.
- EQ spell icons in ImGui: `mq.FindTextureAnimation('A_SpellIcons')`, `SetTextureCell(Spell.SpellIcon())`,
  `ImGui.DrawTextureAnimation(anim, 16, 16)` (Invisibility 18, Invisibility versus Undead 33, Resurrection
  Sickness 154). `mq.Icons` isn't deployed in this build: embed FontAwesome 4.7 codepoints as `\xef\x..` strings.

### Group of clients
- All clients share `<MQ>/lua` and `<MQ>/config`; DanNet channel `new_test` reaches the group: `/dgae new_test <cmd>`
  (includes self), `/dex test_<name> <cmd>`, `/dquery test_<name> -q "<TLO>" -t 3000` then read `${DanNet.Q}`.
- Reload the group only when nobody has an XTarget AND nobody is dead (`Me.State` HOVER/DEAD, or a name ending
  "'s corpse" — a dead character also shows XTarget 0) AND nobody is pulling or fighting (AutoXP state APPROACH /
  FIGHT: a pull spell lands before the mob is on any XTarget — a reload then stopped every bot and the tank died): `/dgae new_test /autoxp save`, then `/lua stop autoxp`, `/lua run autoxp`,
  `/autoxp start` a few seconds apart (commands queued during a zone fire all at once and the run hits the old instance).
  Check each `autoxp_log_<Name>.txt` got a new `start:` line.
- Never change a character's mode (or start / stop / travel) to make a calm window for a reload: the user sets
  modes on purpose (a "restored" Hunter once travelled the tank off alone and got him killed). Wait, or ask.
