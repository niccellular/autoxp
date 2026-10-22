-- Named mode (FIGHT.named in init.lua): hunt only a zone's named mobs and their placeholders.
-- Data: named/<zone>.lua - the named, their placeholders, the map points posted in the page comments and the named
-- drops, written by tools/named_scrape.py from eqresource.com; a zone without one is read in the background (pythonw)
-- the first time it is hunted. Targets: the live spawns named like a named or a placeholder - the client sees the whole
-- zone. A placeholder of a named with posted map points counts only within 100 of one (the same name elsewhere is
-- trash), and one under 100% HP that isn't on my extended target list is someone else's. A named up goes first (the
-- closest), then the placeholders clockwise around the zone (north at 12, around the centre of the map points and
-- targets) from where I stand. A walk that passes other NPCs (or ends next to some) is made invisible: invisibility
-- versus undead first when any of them is undead (a cast after the invis would drop it), then invisibility -
-- /autoxp invis [ivu] to the group (DanNet), each casting its own Invis with / IVU with AAs
local mq = require('mq')
local ImGui = require('ImGui')

return function(X)
local S, R, log = X.S, X.R, X.log
local DIR = mq.luaDir .. '/autoxp/named'
local N = { loot = {}, targets = {}, kills = {}, status = '' }
local D, names, spotsOf = nil, {}, {}   -- the zone's data; lowercased spawn name -> { kind, named = {...} }; named -> map points
local words = {}                        -- the spawn-search words for those names
local seen, engaged = {}, {}            -- named spawns announced; spawn id -> the target I went for (kills)

-- each name is searched for by its longest word that the spawn search wouldn't read as a keyword or a class ('a
-- spiritforged wizard' -> spiritforged; one search covers every name with that word), its exact name checked here.
-- mq.getFilteredSpawns took 300ms a pass in Laurion Inn (a Lua call per spawn of the zone)
local NOTWORD = {}
for w in ([[alert any aura banker banner body campfire chest class corpse dps fellowship flyer gm group guild guildname
    healer id knight lfg light loc los mercenary merchant mount name named nearalert next noalert nogroup noguild nopcnear
    nopet notid notnearalert npc npccorpse npcpet object pc pccorpse pcpet pet playerstate prev race radius raid range
    slower tank targetable timer trader trap tribute trigger untargetable xtarhater zradius bard beastlord berserker cleric
    druid enchanter magician monk necromancer paladin ranger rogue shadowknight shaman warrior wizard war clr pal rng shd
    dru mnk brd rog shm nec wiz mag enc bst ber]]):gmatch('%S+') do NOTWORD[w] = true end
local function searchWord(name)
    local best = ''
    for w in name:gmatch('%S+') do if not NOTWORD[w] and not tonumber(w) and #w > #best then best = w end end
    return best
end

local function here() return mq.TLO.Zone.ShortName() or '' end
local function readFile(p) local f = io.open(p, 'r'); if not f then return nil end; local s = f:read('*a'); f:close(); return s end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function phCount() local n = 0; for _, e in pairs(names) do if e.kind == 'ph' then n = n + 1 end end; return n end
local function tip(text) if text and ImGui.IsItemHovered() then ImGui.SetTooltip('%s', text) end end

-- clock bearing of p around the centre c: degrees clockwise from north (in-game +Y is north, +X is west)
local function bearing(p, c) return math.deg(math.atan2(-(p.x - c.x), p.y - c.y)) % 360 end
local function oclock(b) local h = math.floor(b / 30 + 0.5) % 12; return h == 0 and 12 or h end
local function near(p, q, r) local dy, dx = p.y - q.y, p.x - q.x; return dy * dy + dx * dx <= r * r end

-- the zone's data file: false (the reason in N.err) when there's none or it doesn't load
local function load(z)
    local p = DIR .. '/' .. z .. '.lua'
    if not readFile(p) then return false end
    local ok, t = pcall(dofile, p)
    if not ok or type(t) ~= 'table' then N.err = string.format('named/%s.lua: %s', z, tostring(t)); return false end
    D, names, spotsOf, N.err = t, {}, {}, nil
    for _, n in ipairs(t.named or {}) do names[n.name:lower()] = { kind = 'named', named = { n } } end
    for _, n in ipairs(t.named or {}) do
        for _, ph in ipairs(n.ph or {}) do
            local k = ph:lower()
            names[k] = names[k] or { kind = 'ph', named = {} }
            if names[k].kind == 'ph' then table.insert(names[k].named, n) end
        end
    end
    for _, s in ipairs(t.spots or {}) do
        for _, n in ipairs(s.named or {}) do
            local k = n:lower()
            spotsOf[k] = spotsOf[k] or {}
            table.insert(spotsOf[k], s)
        end
    end
    words = {}
    for k in pairs(names) do words[searchWord(k)] = true end
    N.loot = t.loot or {}
    log('named: %s - %d named, %d placeholders, %d map points, %d drops', t.name or z, #(t.named or {}), phCount(), #(t.spots or {}), count(N.loot))
    return true
end

-- this zone's data, loaded once per zone. With scrape, a zone without any is read from eqresource.com in the
-- background (pythonw: no console window), looked for every 5s and given up after 10 minutes
function N.ready(scrape)
    local z = here()
    if z == '' then return false end
    if N.zone ~= z then
        N.zone, D, names, spotsOf, N.loot, N.targets, N.goal, seen, engaged = z, nil, {}, {}, {}, {}, nil, {}, {}
        load(z)
    end
    if D then return true end
    local now, run = mq.gettime(), N.run
    if run and run.zone == z then
        if now - run.checked < 5000 then return false end
        run.checked = now
        if load(z) then N.run = nil; return true end
        local e = readFile(DIR .. '/' .. z .. '.err')
        if e or now - run.at > 600000 then
            N.run, N.failed = nil, z
            N.err = e and ('eqresource.com: ' .. e:gsub('%s+$', '')) or 'the eqresource.com read never finished (pythonw on the PATH?)'
            log('named: no data for %s - %s', z, N.err)
        end
        return false
    end
    if not scrape or N.failed == z then return false end
    local zi = X.zoneInfo(z)
    if not zi then N.failed, N.err = z, z .. ' is not in zones.lua'; log('named: %s', N.err); return false end
    os.remove(DIR .. '/' .. z .. '.err')
    local ok, err = pcall(os.execute, string.format('start "" /B pythonw "%s/autoxp/tools/named_scrape.py" %s "%s" "%s" "%s"',
        mq.luaDir, z, zi.name, zi.exp, DIR))
    if not ok then N.failed, N.err = z, 'could not start the scraper: ' .. tostring(err); log('named: %s', N.err); return false end
    N.run = { zone = z, at = now, checked = now }
    log('named: no data for %s yet - reading eqresource.com in the background', zi.name)
    return false
end

-- read the zone again from eqresource.com (the Named tab, /autoxp named scrape)
function N.rescrape()
    local z = here()
    os.remove(DIR .. '/' .. z .. '.lua')
    N.zone, N.failed, N.run, D = nil, nil, nil, nil
    N.ready(true)
end

-- a named drop of this zone: true (tradeable) or the classes that can use the No Trade item; nil when it isn't one
function N.lootFor(item)
    if N.zone ~= here() then N.ready(false) end
    return N.loot[item]
end

-- a placeholder counts within 100 of a posted map point of one of its named (none posted for them: anywhere)
local function atSpot(t)
    local posted = false
    for _, n in ipairs(t.of) do
        for _, s in ipairs(spotsOf[n.name:lower()] or {}) do
            posted = true
            if near(t, s, 100) then return true end
        end
    end
    return not posted
end

-- the live named and placeholders (whole zone) in route order: a named first (the closest), then clockwise from my
-- clock position (one within 150 of me counts as where I stand)
function N.scan()
    if not D then N.targets = {}; return N.targets end
    local now, xt = mq.gettime(), {}
    for i = 1, (mq.TLO.Me.XTarget() or 0) do
        local id = mq.TLO.Me.XTarget(i).ID() or 0
        if id > 0 then xt[id] = true end
    end
    local out, got = {}, {}
    for w in pairs(words) do
        local q = 'npc ' .. w
        for i = 1, math.min(mq.TLO.SpawnCount(q)() or 0, 50) do
            local s = mq.TLO.NearestSpawn(i, q)
            if not s() then break end
            local id = s.ID() or 0
            local e = not got[id] and names[(s.CleanName() or ''):lower()]
            if e then
                got[id] = true
                if (R.skip[id] or 0) < now and ((s.PctHPs() or 100) >= 100 or xt[id]) then
                    local t = { id = id, name = s.CleanName() or '?', kind = e.kind, of = e.named, y = s.Y() or 0, x = s.X() or 0, z = s.Z() or 0 }
                    if t.kind == 'named' or atSpot(t) then out[#out + 1] = t end
                end
            end
        end
    end
    -- the ones I went for that are gone: killed
    for id, t in pairs(engaged) do
        local s = mq.TLO.Spawn('id ' .. id)
        if not (s() and s.Type() ~= 'Corpse') then
            local k = t.name:lower()
            engaged[id], N.kills[k] = nil, (N.kills[k] or 0) + 1
        end
    end
    local c, n = { y = 0, x = 0 }, 0
    for _, p in ipairs(D.spots or {}) do c.y, c.x, n = c.y + p.y, c.x + p.x, n + 1 end
    for _, t in ipairs(out) do c.y, c.x, n = c.y + t.y, c.x + t.x, n + 1 end
    if n > 0 then c.y, c.x = c.y / n, c.x / n end
    local me = { y = mq.TLO.Me.Y() or 0, x = mq.TLO.Me.X() or 0 }
    local b0 = bearing(me, c)
    N.myClock = oclock(b0)
    for _, t in ipairs(out) do
        t.bearing = bearing(t, c)
        t.clock, t.dist = oclock(t.bearing), math.sqrt((t.y - me.y) ^ 2 + (t.x - me.x) ^ 2)
        t.turn = t.dist < 150 and 0 or (t.bearing - b0) % 360
    end
    for _, t in ipairs(out) do
        if t.kind == 'named' and not seen[t.id] then seen[t.id] = true; log('named: %s is up (%d o\'clock, %.0f away)', t.name, t.clock, t.dist) end
    end
    table.sort(out, function(a, b)
        if (a.kind == 'named') ~= (b.kind == 'named') then return a.kind == 'named' end
        if a.kind == 'named' then return a.dist < b.dist end
        if a.turn ~= b.turn then return a.turn < b.turn end
        return a.dist < b.dist
    end)
    N.targets, N.scannedAt = out, mq.gettime()
    return out
end

-- what a walk to t passes: any NPC, and any undead one, within the alone radius of MQ2Nav's path (sampled every half
-- radius, same level) or next to t, t itself aside - by spawn-search counts. nil when MQ2Nav gives no path points
local function along(t)
    local s = mq.TLO.Navigation.PathPoints('id ' .. t.id)()
    if not s or s == '' then return nil end
    local pts = {}
    for x, y, z in s:gmatch('(-?[%d.]+),(-?[%d.]+),(-?[%d.]+)') do pts[#pts + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
    pts[#pts + 1] = { x = t.x, y = t.y, z = t.z }
    local r, any, undead = S.avoidRadius, false, false
    local function look(x, y, z)
        local q = string.format('npc notid %d loc %.0f %.0f %.0f radius %d zradius 40', t.id, x, y, z, r)
        if not any and (mq.TLO.SpawnCount(q)() or 0) > 0 then any = true end
        if not undead and (mq.TLO.SpawnCount('body undead ' .. q)() or 0) > 0 then undead = true end
    end
    for k = 1, #pts - 1 do
        local a, b = pts[k], pts[k + 1]
        local steps = math.max(1, math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) / (r / 2)))
        for j = 0, steps - 1 do
            local f = j / steps
            look(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f)
            if any and undead then return true, true end
        end
    end
    look(t.x, t.y, t.z)
    return any, undead
end

-- the group invisible for the walk: versus undead first when undead are along it, then invisible (the invis step
-- waits for invisibility only: a caster may lose its own versus-undead casting it - logged). Asked again every 12s;
-- after the third ask it goes anyway (someone out of range, or nobody with the AAs) and says who wasn't
local function invisReady(g)
    local now = mq.gettime()
    g.phase, g.asked, g.n = g.phase or (g.ivu and 'ivu' or 'invis'), g.asked or 0, g.n or 0
    local missing = X.DPS.notInvis and X.DPS.notInvis(g.phase == 'invis', g.phase == 'ivu') or {}
    if #missing == 0 or (g.n >= 3 and now - g.asked > 12000) then
        if #missing > 0 then
            log('named: %s still not %s - going anyway', table.concat(missing, ', '), g.phase == 'ivu' and 'invisible versus undead' or 'invisible')
        end
        if g.phase == 'ivu' then g.phase, g.asked, g.n = 'invis', 0, 0; return false end
        local lost = g.ivu and X.DPS.notInvis and X.DPS.notInvis(false, true) or {}
        if #lost > 0 then log('named: %s not invisible versus undead any more', table.concat(lost, ', ')) end
        return true
    end
    if now - g.asked > 12000 then
        g.asked, g.n = now, g.n + 1
        if (mq.TLO.Group.Members() or 0) > 0 and mq.TLO.Plugin('mq2dannet').IsLoaded() then
            mq.cmdf('/dggexecute /autoxp invis%s', g.phase == 'ivu' and ' ivu' or '')
        end
        R.invisWant = { ivu = g.phase == 'ivu', at = now }
        log('named: %s for the walk to %s (not yet: %s)', g.phase == 'ivu' and 'invisibility versus undead' or 'invisibility', g.t.name, table.concat(missing, ', '))
    end
    N.status = string.format('waiting for %s: %s', g.phase == 'ivu' and 'invisibility versus undead' or 'invisibility', table.concat(missing, ', '))
    return false
end

-- the Named leader's next target (pickTarget: nothing on the extended target list, the group ready): the first in route
-- order with a path, once the group is invisible for the walk
function N.pick()
    if not N.ready(true) then
        N.status = N.run and 'reading eqresource.com...' or ('no named data: ' .. (N.err or 'none for this zone'))
        return nil
    end
    local now, g = mq.gettime(), N.goal
    if g and (not X.alive(mq.TLO.Spawn('id ' .. g.t.id)) or now - g.at > 90000) then N.goal, g = nil, nil end
    if not g then
        if now - (N.scanAt or 0) < 3000 then return nil end
        N.scanAt = now
        local ts = N.scan()
        for _, t in ipairs(ts) do
            local len = mq.TLO.Navigation.PathLength('id ' .. t.id)() or -1
            if len < 0 then
                R.skip[t.id] = now + 60000
                log('named: no path to %s - skipping it for a minute', t.name)
            else
                g = { t = t, len = len, at = now }
                if S.namedInvis and len > S.pullDist + 20 then
                    local any, undead = along(t)
                    g.invis, g.ivu = any ~= false, undead == true   -- no path points: invisible anyway
                end
                break
            end
        end
        if not g then
            N.status = #ts == 0 and 'nothing up - waiting' or 'no path to anything up - waiting'
            if not N.idle then N.idle = true; log('named: %s', N.status) end
            return nil
        end
        N.idle, N.goal = nil, g
        local t = g.t
        log('named: next %s%s at %d o\'clock, %.0f away%s', t.name, t.kind == 'ph' and (' (placeholder of ' .. t.of[1].name .. ')') or ' (named)',
            t.clock, g.len, g.invis and (g.ivu and ' - invisible, versus undead too' or ' - invisible') or '')
    end
    if g.invis and not invisReady(g) then return nil end
    N.goal = nil
    engaged[g.t.id] = g.t
    N.status = string.format('going for %s (%d o\'clock)', g.t.name, g.t.clock)
    R.pullCandidate = true
    return g.t.id
end

-- my AAs for /autoxp invis [ivu]: the Invis with / IVU with list (AA ids or names), else a bard's Selo's Sonata and
-- Shauri's Sonorous Clouding (3704, 231) for invis, and Group Perfected Invisibility to Undead for ivu
local function aaIds(str)
    local out = {}
    for _, a in ipairs(X.list(str)) do
        local aa = mq.TLO.Me.AltAbility(tonumber(a) or a)
        if aa() and aa.ID() then out[#out + 1] = aa.ID() end
    end
    return out
end
function N.invisAAs(ivu)
    local str = ivu and S.ivuWith or S.invisWith
    if str ~= '' then return aaIds(str) end
    if ivu then return aaIds('Group Perfected Invisibility to Undead') end
    if mq.TLO.Me.Class.ShortName() == 'BRD' then return aaIds('3704, 231') end
    return {}
end

-- /autoxp invis [ivu] (the Named leader before a walk): my AAs one at a time, 1.5s apart (a bard stops its song
-- first); dropped after 20s or in a fight. True while it has the character. Cast even when I'm invisible myself: the
-- leader asks only when someone isn't (Lolelena, buffing as the invis landed, stayed visible through two asks)
function N.invisTick()
    local w = R.invisWant
    if not w then return false end
    local now, me = mq.gettime(), mq.TLO.Me
    if now - w.at > 20000 or #X.hostiles() > 0 then R.invisWant = nil; return false end
    w.todo = w.todo or N.invisAAs(w.ivu)
    if #w.todo == 0 then R.invisWant = nil; return false end
    if now < (w.next or 0) or X.casting() then return true end
    local id = table.remove(w.todo, 1)
    if me.AltAbilityReady(id)() then
        if me.Class.ShortName() == 'BRD' and not w.stopped then mq.cmd('/stopsong'); w.stopped = true end
        mq.cmdf('/alt activate %d', id)
        log('%s (%s for the walk)', me.AltAbility(id).Name() or tostring(id), w.ivu and 'invisibility versus undead' or 'invisibility')
    end
    w.next = now + 1500
    return true
end

-- /autoxp named reload | scrape
function N.command(a)
    if a == 'scrape' then N.rescrape()
    elseif a == 'reload' then N.zone = nil; N.ready(false) end
end

-- the Named tab
function N.draw()
    N.ready(N.run ~= nil)
    local z = here()
    ImGui.PushTextWrapPos(0)
    if D then
        ImGui.TextColored(0.4, 0.8, 1, 1, string.format('%s: %d named, %d placeholders, %d map points, %d drops', D.name or z, #(D.named or {}),
            phCount(), #(D.spots or {}), count(N.loot)))
        tip(D.url)
    elseif N.run and N.run.zone == z then
        ImGui.TextColored(1, 0.8, 0.3, 1, 'reading eqresource.com in the background...')
    else
        ImGui.TextColored(1, 0.5, 0.5, 1, N.err or 'no named data for this zone yet: Named mode reads it from eqresource.com')
    end
    ImGui.PopTextWrapPos()
    if ImGui.SmallButton('Read eqresource.com again') then N.rescrape() end
    tip('Read this zone\'s named, placeholders, posted map points and drops from eqresource.com again (in the background).')
    S.namedInvis = ImGui.Checkbox('Invisible walks', S.namedInvis)
    tip('Before a walk that passes other NPCs, the group goes invisible (/autoxp invis to every member):\ninvisibility versus undead first when undead are along the way, then invisibility.\nAfter three asks (36s) it goes anyway.')
    ImGui.SetNextItemWidth(160)
    S.invisWith = ImGui.InputText('Invis with', S.invisWith)
    tip('My AAs for the group invis, ids or names, in order. Empty: a bard uses Selo\'s Sonata and\nShauri\'s Sonorous Clouding (3704, 231); other classes cast nothing.')
    ImGui.SetNextItemWidth(160)
    S.ivuWith = ImGui.InputText('IVU with', S.ivuWith)
    tip('My AAs for invisibility versus undead, ids or names. Empty: Group Perfected Invisibility to Undead, if I have it.')
    if N.status ~= '' then ImGui.TextColored(1, 0.8, 0.3, 1, N.status) end
    if not D then return end
    ImGui.Separator()
    -- the window can't wait on a scan (a pass of spawn searches): the main loop runs it (Look now) or Named mode's pick
    if ImGui.SmallButton('Look now') then N.wantLook = true end
    tip('Look for the named and placeholders up in the zone now (Named mode looks before every pull).')
    ImGui.SameLine()
    ImGui.Text(string.format('Up %s, in route order (I was at %s o\'clock):', N.scannedAt and string.format('%ds ago', math.floor((mq.gettime() - N.scannedAt) / 1000)) or 'not looked yet',
        N.myClock or '?'))
    if #N.targets == 0 then ImGui.TextDisabled('   nothing') end
    for i, t in ipairs(N.targets) do
        if i > 15 then ImGui.TextDisabled(string.format('   ...%d more', #N.targets - 15)); break end
        local s = string.format('%2d. %s%s - %d o\'clock, %.0f away', i, t.name, t.kind == 'ph' and (' (ph: ' .. t.of[1].name .. ')') or '', t.clock, t.dist)
        if t.kind == 'named' then ImGui.TextColored(1, 0.6, 0.2, 1, s) else ImGui.Text(s) end
    end
    if ImGui.TreeNode(string.format('%d named###namedlist', #(D.named or {}))) then
        for _, n in ipairs(D.named or {}) do
            local ph = 0
            for _, p in ipairs(n.ph or {}) do ph = ph + (N.kills[p:lower()] or 0) end
            ImGui.Text(string.format('%s  (ph: %s)%s - killed %d, placeholders %d', n.name, table.concat(n.ph or {}, ', '),
                spotsOf[n.name:lower()] and ', map points' or '', N.kills[n.name:lower()] or 0, ph))
        end
        ImGui.TreePop()
    end
end

return N
end
