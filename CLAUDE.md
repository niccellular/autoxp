## AutoXP — working rules

MacroQuest Lua leveling automation (`init.lua`, `zones.lua`). Private repo niccellular/autoxp, branch `main`.

### Where it runs
- `<MQ>/lua/autoxp` is a **junction** to this folder, so `/lua run autoxp` runs this working copy.
  Never create `lua/autoxp.lua` — a file there shadows the folder. MQ runtime: `openvanilla-master/build/solution/bin/debug`.
- Log: `<MQ>/lua/autoxp_log.txt`. Settings per character: `<MQ>/config/autoxp_<Name>.lua`.

### Editing workflow
1. Patch with a small Python script (exact old/new strings, assert each occurs once; keep CRLF/LF as found).
   In a Bash heredoc, `\n` in a Lua string becomes a real newline — build it with `chr(92) + 'n'`.
2. Syntax check: `build/solution/vcpkg_installed/x64-windows-static/tools/luajit/luajit.exe -e "print(loadfile('init.lua'))"`.
3. Check nothing is used before its `local function` definition (a forward reference silently becomes a nil global).
4. Reload only between fights (`${Me.XTarget}` == 0): `/autoxp save` FIRST (`/lua stop` kills the script without
   saving, so unsaved UI changes like the hunt zone are lost), then `/lua stop autoxp`, `/lua run autoxp`, `/autoxp start`.
   Whatever is targeted at start counts as the player's pick.
5. Watch the log for the change, then commit/push only when asked (ncellular, no attribution).

### MQ / ImGui gotchas
- `ImGui.SetTooltip` is printf-style: always `SetTooltip('%s', text)` (a literal `%` crashes the overlay).
  If ImGui pauses after an error: `/mqoverlay resume`.
- Inline `/lua parse` mangles strings with `/` or spaces — write a temporary `lua/mqt_*.lua` probe, delete it after.
- Unloading a plugin (e.g. mq2moveutils, mq2nav) kills scripts using its TLOs — restart AutoXP after.
- `NearestSpawn … radius` is 2D; multi-floor zones fill the nearest list with mobs on other floors.
  A mob with `PathLength == -1` is off the navmesh (velketor's mesh only connects one floor).
- `Navigation.PathPoints` exists only in our patched MQ2Nav; stock MQ2Nav falls back to `PathLength`.
- A living mob can read `PctHPs` 0 and a fresh corpse can read 3% — death is `Type() == 'Corpse'`, never HP%.
