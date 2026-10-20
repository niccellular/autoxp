-- autoxp: group automation with ImGui front end.
-- Modes: Hunter (find+pull), Assist (MA's target), Chase (follow a toon), Manual (act on own target).
-- Role: Tank or DPS; duties: Heal, CC. Abilities, spell lists and melee/ranged style follow the character's class.
-- /lua run autoxp [zone]   then /autoxp start|stop|pause|resume|show|scan|spells|mode <m>|role <tank|dps>|heal|cc [on|off]
local mq = require('mq')
local ImGui = require('ImGui')

local args = { ... }
local ZONES = {}
do
    local ok, z = pcall(dofile, mq.luaDir .. '/autoxp/zones.lua')
    if ok and type(z) == 'table' then ZONES = z end
end
local function zoneInfo(short)
    for _, z in ipairs(ZONES) do if z.short == short then return z end end
    return nil
end
-- the character's name; a dead character's spawn is "<Name>'s corpse", which must not pick another settings file
local ME = ((mq.TLO.Me.CleanName() or 'default'):gsub("'s corpse%d*$", ''))
local CONFIG = string.format('%s/autoxp_%s.lua', mq.configDir, ME)
local MODES = { 'Manual', 'Hunter', 'Assist', 'Chase' }
local ROLES = { 'Off', 'Tank', 'DPS', 'Burn', 'Defense', 'Heal', 'Emergency', 'CC', 'Debuff', 'Buff', 'Endurance', 'Mana', 'Pet', 'Pull' }
local SHOWROLES = { 'All', 'Off', 'Tank', 'DPS', 'Burn', 'Defense', 'Heal', 'Emergency', 'CC', 'Debuff', 'Buff', 'Endurance', 'Mana', 'Pet', 'Pull' }

-- settings (persisted) -------------------------------------------------------------------
local S = {
    mode = 'Hunter', role = 'Tank', heal = true, cc = false, debuff = true, nuke = true, dot = true, buff = true, rez = false, ccStuns = '',
    zone = 'southro', travel = true,
    minlvl = 15, maxlvl = 25, radius = 1500,
    assistName = '', assistAt = 95, chaseName = '', chaseDist = 30,
    restPct = 50, restTo = 90,
    selfHealPct = 50, groupHealPct = 40, tankHealPct = 75, emergencyPct = 20, healSpells = '',
    nukes = '', nukeManaMin = 30, dotManaMin = 40, stuns = '', buffs = '', useTaunt = true, prioritize = true, showRadius = true,
    combatBuffs = 'Yaulp', stunCooldown = true, keepInFront = true,
    avoidMobs = true, avoidRadius = 100, pullVer = 0, pullMethod = 'Auto', pullSpell = '', pullDist = 100, autoMem = true, gemSig = '', memBuffs = true,
    style = 'Auto', castRange = 100, mez = '', dots = '', twincastNukes = '', itNukes = '', debuffs = '', petSpell = '', usePet = true, shrinkPet = true, chaseLoot = true, class = '',
    songs = '', restSongs = '', songManaMin = 10, fillVer = 0, swapGem = false,
    tankBuffs = '', manaSpells = '', manaPct = 50, userLists = {}, rezDone = {},
    defPct = 50, panicPct = 30, endPct = 30, burnNamed = true, burnLevel = true, burnAdds = true, burnCount = 5,
    abilVer = 0, abilOrdered = false, abilFilter = 'All', pouchNames = 'Pouch of Quellious, Phantom Weapon Pack', showPeers = true, showHud = true, backupTank = false,
    abilities = {},   -- { {name=, kind='skill'|'aa'|'disc', role=} }
}
local function loadConfig(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    f:close()
    local ok, v = pcall(dofile, path)
    return ok and type(v) == 'table' and v or nil
end
do
    local saved = loadConfig(CONFIG) or loadConfig(mq.configDir .. '/autoxp.lua')
    if saved then
        for k, v in pairs(saved) do if S[k] ~= nil then S[k] = v end end
        if saved.role == nil and saved.tank == false and saved.dps then S.role = 'DPS' end
        if saved.ccStuns == nil and saved.stuns then S.ccStuns = saved.stuns end
    end
end
if S.role ~= 'Tank' and S.role ~= 'DPS' then S.role = 'Tank' end
if args[1] then S.zone = args[1] end

-- runtime ---------------------------------------------------------------------------------
local R = {
    open = true, running = false, paused = false, terminate = false,
    state = 'IDLE', stateSince = 0, targetId = 0, targetName = '', kills = 0,
    xp0 = 0, aa0 = 0, started = 0, log = {}, opened = false, lastAssist = 0,
    attacking = false, lastSwitch = 0, lastReposition = 0, zoneFilter = '',
    travelTarget = '', travelTries = 0, lastMoveAt = 0, lastPos = nil, mezzed = {}, petTarget = 0,
    skip = {}, lastNav = 0, fightZone = '', waypoint = nil, pendingDetour = nil,
    pull = nil, pullCandidate = false, pullWait = nil, holdUntil = 0, lastFace = 0, lastMemCheck = 0, pullTries = 0,
    ourTarget = 0, pickId = 0, swapGem = nil, buffLevel = 0, nukeLevel = 0, nukeDebuff = nil,
    mobCast = {}, buffTry = {}, buffChecked = {}, songNext = {}, abilUsed = {}, lastRoles = 0, rolesWarned = false, rezLevel = -1, rezName = '', restSongLevel = -1, feignAt = 0, cast = nil, petTry = 0, duckAt = 0, burnUntil = 0, lastHunt = 0, holdWhy = nil, tooCloseAt = 0, noRouteAt = 0, armFail = {}, armCheck = 0, rezzed = {}, diedAt = {}, abilNext = {}, mezResist = {}, noMez = {}, lastMez = nil, healMemLevel = -1, hotUntil = {}, findZone = '', findNames = {}, tankBuffUntil = {}, reagentNote = {},
}
-- one log per character: several clients run AutoXP at once
local logf = io.open(mq.luaDir .. '/autoxp_log_' .. ME .. '.txt', 'a')
local function log(fmt, ...)
    local s = os.date('%H:%M:%S ') .. string.format(fmt, ...)
    table.insert(R.log, s)
    if #R.log > 300 then table.remove(R.log, 1) end
    if logf then logf:write(s .. '\n'); logf:flush() end
end

-- an error outside step() (a chat event, a window) is logged once instead of ending the script: five clients stopped
-- mid-fight at once (2026-10-16 19:15) with nothing in their logs, and the group wiped without its tank
local function oops(where, err)
    if err ~= R.lastOops then R.lastOops = err; log('%s error: %s', where, tostring(err)) end
end

local function setState(s) if R.state ~= s then R.state = s; R.stateSince = mq.gettime() end end
local function inState() return mq.gettime() - R.stateSince end
local function hp() return mq.TLO.Me.PctHPs() or 100 end
local function mana() return mq.TLO.Me.PctMana() or 0 end
local function myId() return mq.TLO.Me.ID() or 0 end
local function totalXp() return (mq.TLO.Me.Level() or 0) * 100 + (mq.TLO.Me.PctExp() or 0) end
local DPS = {}   -- damage and session stats, filled in by the DPS section (before the UI)
local FIGHT = {}   -- fight rules (AE, disciplines, turns, reagents, combat and tank buffs), filled in after the helpers they use
local function casting()
    -- a bard keeps "casting" the song it holds; only the cast bar means busy
    if mq.TLO.Me.Class.ShortName() == 'BRD' then return mq.TLO.Window('CastingWindow').Open() == true end
    return mq.TLO.Me.Casting() ~= nil
end
local function spawn(id) return id and id > 0 and mq.TLO.Spawn('id ' .. id) or nil end
-- dead = corpse; a living mob can read 0% HP (a sliver left), so HP% never means dead
local function alive(s) return s and s() and s.Type() ~= 'Corpse' end
-- a borrowed gem is saved too, so a reload in the middle of buffing still puts the spell back
-- low on mana and should sit for it (bards don't: they sing their regen songs instead)
-- low on mana or endurance and should sit for it
local function manaLow()
    if (mq.TLO.Me.MaxMana() or 0) > 0 and (mq.TLO.Me.PctMana() or 100) < S.restPct then return true end
    return (mq.TLO.Me.PctEndurance() or 100) < S.restPct
end

local function save()
    S.swapGem = R.swapGem and { g = R.swapGem.g, name = R.swapGem.name } or false
    local role = S.role
    if R.backupFrom then S.role = R.backupFrom end   -- tanking as the backup tank is never saved as my role
    mq.pickle(CONFIG, S)
    S.role = role
end

local function list(str)
    local out = {}
    for b in string.gmatch(str or '', '[^,]+') do
        b = b:gsub('^%s+', ''):gsub('%s+$', '')
        if b ~= '' then table.insert(out, b) end
    end
    return out
end

-- targeting / attack ----------------------------------------------------------------------
-- the player's pick: an NPC targeted by anyone but us; we fight it until it dies
local function noticePick()
    local id = mq.TLO.Target.ID() or 0
    if id == 0 or id == R.ourTarget then return end
    R.ourTarget = id
    if mq.gettime() - R.lastAssist < 1500 then return end   -- /assist targets for us
    local t = mq.TLO.Target
    local cls = t.Class.ID() or 0
    -- Tank role in Manual mode only (Hunter ignores clicks); combat classes only: never merchants, bankers or GMs
    if S.role == 'Tank' and S.mode == 'Manual' and id ~= R.pickId and t.Type() == 'NPC' and cls >= 1 and cls <= 16 and alive(spawn(id)) then
        R.pickId = id
        log('you picked %s - fighting it', t.CleanName())
    end
end
local function targetId(id, timeout)
    noticePick()
    if (mq.TLO.Target.ID() or 0) == id then return true end
    R.ourTarget = id
    mq.cmdf('/target id %d', id)
    mq.delay(timeout or 600, function() return (mq.TLO.Target.ID() or 0) == id end)
    R.ourTarget = mq.TLO.Target.ID() or 0
    return R.ourTarget == id
end

-- casters and priests fight from range; everyone else melees
local RANGED = { WIZ = true, MAG = true, NEC = true, ENC = true, CLR = true, DRU = true, SHM = true, RNG = true }
local function ranged()
    if S.style == 'Auto' then return RANGED[mq.TLO.Me.Class.ShortName() or ''] == true end
    return S.style == 'Ranged'
end
-- archery needs some distance: "too close" re-applies the stick that backs us up
local ARCHERY = 40
mq.event('axpTooClose', 'Your target is too close to use ranged combat#*#', function() R.tooCloseAt = mq.gettime() end)

-- a ranger with a bow equipped: auto-fire from range instead of melee
local function archer()
    return ranged() and mq.TLO.Me.Class.ShortName() == 'RNG' and mq.TLO.Me.Inventory('ranged').Type() == 'Archery'
end
local function stick()
    if not ranged() then mq.cmd(S.role == 'Tank' and '/stick 8 moveback' or '/stick 8 behind moveback') end
end

-- Spawn.Distance is 2D: a mob on another floor reads as close, so use 3D distance plus line of sight;
-- melee also needs the same level (a mob straight above or below can't be hit)
local function reachable(s, range, anyLevel)
    if (s.Distance3D() or 999) >= range or s.LineOfSight() ~= true then return false end
    return anyLevel or ranged() or math.abs((s.Z() or 0) - (mq.TLO.Me.Z() or 0)) < 15
end
-- like /nav target: the whole path, re-pathed to the mob as it moves (MQ2Nav, every 200ms), and the caller stops it
-- once reachable() says so. MQ2Nav's own distance= / lineofsight= stop goes by the navmesh (distance to the path's
-- end, a mesh raycast): it could stop where EQ has no line of sight or on another floor, and each re-nav stopped
-- there again until the approach gave up ("no path to ... - skipping it")
local function navTo(id)
    mq.cmdf('/nav id %d distance=0', id); R.lastNav = mq.gettime()
end
-- melee: stick only when we can see it up close, otherwise path to it; casters just need range + sight
local function closeIn(s)
    if ranged() then
        if not reachable(s, S.castRange) then navTo(s.ID()) end
    elseif reachable(s, 35) then stick()
    else mq.cmd('/stick off'); navTo(s.ID()) end
end

local function attackOn()
    if R.targetId > 0 and targetId(R.targetId) then
        local t = spawn(R.targetId)
        if ranged() or not (t and (t.Distance3D() or 999) < 40) then mq.cmdf('/face fast id %d', R.targetId) else mq.cmd('/attack on') end
        if archer() and not mq.TLO.Me.AutoFire() then mq.cmd('/autofire') end
        R.attacking = true
    end
end
local function attackOff()
    mq.cmd('/attack off')
    if mq.TLO.Me.AutoFire() then mq.cmd('/autofire') end
    R.attacking = false
end

-- the swarm pets (Ravening Servant, Chattering Bones, Spirit Call) go with it: /pet swarm with the attack, and again 5s
-- later for the ones summoned since
local function doPet(t)
    if not S.usePet or (mq.TLO.Me.Pet.ID() or 0) == 0 then return false end
    if alive(t) and R.petTarget ~= t.ID() and targetId(t.ID()) then
        mq.cmd('/pet attack'); mq.cmd('/pet swarm'); R.petTarget, R.swarmAt = t.ID(), mq.gettime() + 5000
        log('pet attack %s', t.CleanName())
    elseif R.swarmAt and mq.gettime() >= R.swarmAt and alive(t) and R.petTarget == t.ID() and mq.TLO.Target.ID() == t.ID() then
        mq.cmd('/pet swarm'); R.swarmAt = nil
    end
    return false
end
local function petBackOff()
    if R.petTarget ~= 0 and (mq.TLO.Me.Pet.ID() or 0) > 0 then mq.cmd('/pet back off') end
    R.petTarget = 0
end

-- restore the fight target (and auto-attack) after we switched away to cast something
local function restoreFight()
    local t = spawn(R.targetId)
    if alive(t) and (R.state == 'FIGHT') then attackOn() end
end

-- movement must stop before a cast can start
local function holdMovement()
    local wasStick = mq.TLO.Stick.Active() == true
    local wasNav = mq.TLO.Navigation.Active() == true
    local moving = wasStick or wasNav or mq.TLO.Me.Moving()
    if wasStick then mq.cmd('/stick pause') end
    if wasNav then mq.cmd('/nav pause') end
    mq.delay(1500, function() return not mq.TLO.Me.Moving() end)
    -- the Moving flag clears before the server sees us stopped; casting then gets interrupted
    if moving then mq.delay(300) end
    return function()
        if wasStick then mq.cmd('/stick unpause') end
        if wasNav and mq.TLO.Navigation.Paused() then mq.cmd('/nav pause') end
    end
end

-- casting ---------------------------------------------------------------------------------
local failedUntil = {}   -- spell/ability -> gettime() before which we don't retry
local function backoff(name, why, ms) failedUntil[name] = mq.gettime() + (ms or 30000); log('%s failed (%s) - backing off', name, why) end
local function blocked(name) return (failedUntil[name] or 0) > mq.gettime() end

-- a spell that keeps fizzling or getting interrupted (untrained casting skill, low channeling) backs off
local castFails = {}
local function castFailed(spell, how)
    if not spell or spell == '' then return end
    local now, f = mq.gettime(), castFails[spell] or {}
    table.insert(f, now)
    while #f > 0 and now - f[1] > 30000 do table.remove(f, 1) end
    castFails[spell] = f
    R.songNext[spell] = nil   -- an interrupted song didn't start its recast
    if R.cast and R.cast.id then
        R.rezzed[R.cast.id] = nil
        if R.cast.rezKey then S.rezDone[R.cast.rezKey] = nil end
        if R.cast.kind == 'cc' then R.mezzed[R.cast.id] = nil end
    end
    if #f >= 3 then castFails[spell] = nil; backoff(spell, how .. ' 3 times in 30s', 60000) end
end
mq.event('axpFizzle', 'Your #1# spell fizzles!', function(_, spell) castFailed(spell, 'fizzled') end)
mq.event('axpInterrupt1', 'Your #1# spell is interrupted.', function(_, spell) castFailed(spell, 'interrupted') end)
mq.event('axpInterrupt2', 'Your spell is interrupted.', function() castFailed(R.cast and R.cast.name, 'interrupted') end)

local function spellReady(name)
    if name == '' or blocked(name) or not mq.TLO.Me.Gem(name)() then return false end
    -- a bard's SpellReady reads true while any song plays (Regar's Lively Crescendo was sung on its recast 850 times):
    -- the gem's own timer says when it's back
    if mq.TLO.Me.Class.ShortName() == 'BRD' then return (tonumber(mq.TLO.Me.GemTimer(name)()) or 0) == 0 end
    return mq.TLO.Me.SpellReady(name)() == true
end

-- memorized and off its own recast (while another spell casts, every gem reads "not ready")
local function gemUp(name)
    return name ~= '' and not blocked(name) and mq.TLO.Me.Gem(name)() ~= nil and (tonumber(mq.TLO.Me.GemTimer(name)()) or 0) == 0
end

-- a spell for one kind of body: Undead (turn undead) or Summoned (Turn Summoned: constructs and elementals only)
local function wrongBody(sp, s)
    local tt, body = sp() and sp.TargetType() or '', s.Body.Name() or ''
    if tt == 'Undead' then return not body:find('Undead') end
    if tt == 'Summoned' then return not (body:find('Construct') or body:find('Elemental') or body:find('Summoned')) end
    return false
end

-- dead mid-tick: nothing is tried. Each try waited a second to see it fail - Pindaini died at 13:36:52 and went
-- through 15 burns and songs, each "failed" and backed off, before step() saw she was dead (13:37:10)
function FIGHT.dead() return mq.TLO.Me.State() == 'HOVER' or mq.TLO.Me.Dead() == true end

-- start casting a gem spell on spawn id (self id for self/beneficial) and return; step() waits for it.
-- kind 'heal' / 'cc' marks casts that are never ducked for a heal / a mez
local function castOn(name, id, why, kind)
    if FIGHT.dead() or not spellReady(name) or casting() or mq.TLO.Me.SpellInCooldown() or mq.TLO.Me.Stunned() then return false end
    if FIGHT.keepInvis() then return false end
    local sp = mq.TLO.Spell(name)
    -- not enough mana: every heal failed one after another (a shaman at 0% mana, 2026-10-17 14:16)
    if (mq.TLO.Me.CurrentMana() or 0) < (sp.Mana() or 0) or FIGHT.noReagent(sp) then return false end
    -- a bard's group and self songs need no target: singing one leaves the fight target (and the melee) on the mob
    local bard = mq.TLO.Me.Class.ShortName() == 'BRD'
    local tt = sp() and sp.TargetType() or ''
    local selfOnly = tt == 'Self' or (bard and (tt == 'Group v1' or tt == 'Group v2' or tt == 'AE PC v2'))
    if not selfOnly and id and id > 0 and id ~= myId() then
        local s = spawn(id)
        if not s or not s() or not s.LineOfSight() or (s.Distance3D() or 999) > (sp.MyRange() or sp.Range() or 200) then return false end
        if s.Type() == 'Corpse' and sp.TargetType() ~= 'Corpse' then return false end
        if wrongBody(sp, s) then return false end
    end
    -- an AE waits while it would hit a mezzed add or pull an idle mob (mezzes and CC stuns are meant for adds)
    if kind ~= 'cc' and FIGHT.aeBlocked(sp, id) then return false end
    if not selfOnly and id and id > 0 and not targetId(id) then backoff(name, 'could not target', 5000); return false end
    if mq.TLO.Me.Sitting() then mq.cmd('/stand'); mq.delay(300) end
    -- the book stays open briefly after memorizing ("too distracted to cast")
    mq.delay(2000, function() return not mq.TLO.Window('SpellBookWnd').Open() end)
    if mq.TLO.Window('SpellBookWnd').Open() then mq.cmd('/windowstate SpellBookWnd close'); mq.delay(300) end
    local resume = bard and function() end or holdMovement()
    if bard and mq.TLO.Me.Casting() then mq.cmd('/stopsong'); mq.delay(200) end
    mq.cmdf('/cast "%s"', name)
    -- an instant spell (these DoTs) never shows as casting: the global spell cooldown starting says it went off
    mq.delay(1000, function() return casting() or mq.TLO.Me.SpellInCooldown() end)
    if not casting() and not mq.TLO.Me.SpellInCooldown() then resume(); backoff(name, why, (kind == 'heal' or why == 'song') and 3000 or nil); restoreFight(); return false end
    log('cast %s -> %s (%s)', name, (id and id > 0) and (mq.TLO.Spawn('id ' .. id).CleanName() or id) or 'self', why)
    R.cast = { name = name, id = id, kind = kind, resume = resume }
    return true
end

-- class abilities: skills (/doability), AAs (/alt act), disciplines (/disc)
local function readyNow(a)
    if a.kind == 'skill' then return mq.TLO.Me.AbilityReady(a.name)() == true
    elseif a.kind == 'aa' then return mq.TLO.Me.AltAbilityReady(a.name)() == true
    elseif a.kind == 'disc' then return mq.TLO.Me.CombatAbilityReady(a.name)() == true end
    return false
end

-- a shield block (SPA 320: Deflection Discipline, Shield Flash) needs a shield in the off hand. Looked at on every use,
-- so swapping to a two-hander and back is followed (Ramakrr fights with nothing in the off hand)
FIGHT.shieldNeed = {}
function FIGHT.noShield(name, sp)
    local need = FIGHT.shieldNeed[name]
    if need == nil then need = (sp and sp() and sp.HasSPA(320)() == true) or false; FIGHT.shieldNeed[name] = need end
    return need and mq.TLO.Me.Inventory('offhand').Type() ~= 'Shield'
end

local function abilityReady(a)
    if blocked(a.name) or not readyNow(a) or (R.abilNext[a.name] or 0) > mq.gettime() then return false end
    if a.kind == 'skill' then return true end
    local sp = a.kind == 'aa' and mq.TLO.Me.AltAbility(a.name).Spell or mq.TLO.Spell(a.name)
    if FIGHT.noShield(a.name, sp) then return false end
    -- its endurance and its mana (Rallying Call costs 25000 of each: at 16% mana it "did not fire" every 20s)
    return not sp() or ((sp.EnduranceCost() or 0) <= (mq.TLO.Me.CurrentEndurance() or 0)
        and (sp.Mana() or 0) <= (mq.TLO.Me.CurrentMana() or 0))
end

local function useAbility(a, id, why)
    if FIGHT.dead() or not abilityReady(a) or casting() or FIGHT.keepInvis() then return false end
    -- an AA with a reuse timer that reads ready again just after it went off didn't take: the game refused it on landing
    -- (Focused Paragon of Spirits on a groupmate under Paragon of Spirit, "used" 12 times in 12s at 08:00:22)
    if a.kind == 'aa' and mq.gettime() - (R.abilUsed[a.name] or 0) < 5000 and (mq.TLO.Me.AltAbility(a.name).ReuseTime() or 0) >= 10 then
        R.abilUsed[a.name] = nil; backoff(a.name, 'did not take', 30000); return false
    end
    -- a beneficial single-target one used with no target goes on me (Voice of Thule: "You must first select a target")
    if not id and a.kind ~= 'skill' then
        local sp = a.kind == 'aa' and mq.TLO.Me.AltAbility(a.name).Spell or mq.TLO.Spell(a.name)
        if sp() and sp.TargetType() == 'Single' and sp.SpellType() == 'Beneficial' then id = myId() end
    end
    -- not on top of the buffs it doesn't go with (notWith), nor ahead of its turn among abilities sharing its excl tag
    if (a.notWith and FIGHT.buffOn(a.notWith)) or (a.excl and FIGHT.exclWait(a)) then return false end
    if a.kind ~= 'skill' and FIGHT.aeBlocked(a.kind == 'aa' and mq.TLO.Me.AltAbility(a.name).Spell or mq.TLO.Spell(a.name), id or R.targetId) then
        return false
    end
    if id and id > 0 and id ~= myId() then
        local s = spawn(id)
        if not s or not s() or not s.LineOfSight() or (a.kind == 'skill' and (s.Distance3D() or 999) > 30) then return false end
        if s.Type() == 'Corpse' then
            local sp = a.kind == 'aa' and mq.TLO.Me.AltAbility(a.name).Spell or mq.TLO.Spell(a.name)
            if a.kind == 'skill' or not sp() or sp.TargetType() ~= 'Corpse' then return false end
        end
        if a.kind ~= 'skill' and wrongBody(a.kind == 'aa' and mq.TLO.Me.AltAbility(a.name).Spell or mq.TLO.Spell(a.name), s) then return false end
    end
    if id and id > 0 and not targetId(id) then return false end
    -- an AA or disc with a cast time (Lupine Spirit, Visionary's Unity, Maelstrom of Blades) breaks if stick or nav
    -- moves during it: hold still like a spell cast, and let step() wait for it (watchCast resumes the movement)
    local asp = a.kind == 'aa' and mq.TLO.Me.AltAbility(a.name).Spell or a.kind == 'disc' and mq.TLO.Spell(a.name) or nil
    local resume = asp and asp() and (asp.MyCastTime() or 0) > 0 and mq.TLO.Me.Class.ShortName() ~= 'BRD' and holdMovement() or nil
    local function held()
        if not resume then return end
        if casting() then R.cast = { name = a.name, id = id, kind = 'ability', resume = resume } else resume() end
    end
    if a.kind == 'skill' then mq.cmdf('/doability "%s"', a.name)
    elseif a.kind == 'aa' then mq.cmdf('/alt act %d', mq.TLO.Me.AltAbility(a.name).ID() or 0)
    elseif a.kind == 'disc' then mq.cmdf('/disc %s', a.name) end
    -- an AA with no reuse timer (beastlord Gelid Rending / Bite of the Asp, ranger Heavy Arrow, Selo's Kick...) always
    -- reads ready, so whether it fired can't be told: trust it, and use it again after 3s (or its spell's recast)
    if a.kind == 'aa' and (mq.TLO.Me.AltAbility(a.name).ReuseTime() or 0) == 0 then
        local sp = mq.TLO.Me.AltAbility(a.name).Spell
        R.abilNext[a.name] = mq.gettime() + math.max(3000, sp() and sp.RecastTime() or 0)
        mq.delay(200)
        held()
        if id ~= R.targetId then restoreFight() end
        log('use %s %s (%s)', a.kind, a.name, why)
        R.myBuffsAt = 0
        return true
    end
    mq.delay(1000, function() return not readyNow(a) end)
    held()
    if id ~= R.targetId then restoreFight() end
    if readyNow(a) then backoff(a.name, 'did not fire', 20000); return false end
    log('use %s %s (%s)', a.kind, a.name, why)
    R.abilUsed[a.name] = mq.gettime()
    R.myBuffsAt = 0
    return true
end

-- feign death (SPA 74) drops aggro: never part of a rotation, only used by doShed
local fdCache = {}
local function dropsAggro(a)
    if fdCache[a.name] == nil then
        local sp = a.kind == 'aa' and mq.TLO.Me.AltAbility(a.name).Spell or mq.TLO.Spell(a.name)
        fdCache[a.name] = a.name:lower():find('feign') ~= nil or (sp() and sp.HasSPA(74)() == true) or false
    end
    return fdCache[a.name]
end

local function abilitiesFor(role)
    local out = {}
    for _, a in ipairs(S.abilities) do if a.role == role and a.enabled ~= false and not dropsAggro(a) then table.insert(out, a) end end
    return out
end

-- guess a sensible default role for a scanned ability
local function defaultRole(name, kind)
    local n = name:lower()
    if n:find('throw') or n:find('shot') or n:find('arrow') then return 'Pull' end
    if n:find('taunt') or n:find('bash') or n:find('slam') or n:find('kick') or n:find('disarm') or n:find('stun') or n:find('challenge') then return 'Tank' end
    if n:find('lay on hands') or n:find('divine') or n:find('fortitude') or n:find('armor of') then return 'Emergency' end
    if n:find('heal') or n:find('cure') or n:find('touch') then return 'Heal' end
    if kind == 'disc' then return 'DPS' end
    return 'Off'
end

local COMBAT_SKILLS = { 'Taunt', 'Bash', 'Disarm', 'Kick', 'Slam', 'Intimidation', 'Round Kick', 'Flying Kick',
    'Tiger Claw', 'Eagle Strike', 'Dragon Punch', 'Backstab', 'Frenzy' }
-- what an ability does, read from its spell and the spells it triggers: SPA -> base, duration, target
local function abilitySpell(a)
    if a.kind == 'aa' then return mq.TLO.Me.AltAbility(a.name).Spell end
    if a.kind == 'disc' then return mq.TLO.Spell(a.name) end
    return nil
end

local function spellFx(sp)
    local fx, dur, tt = {}, sp.Duration.TotalSeconds() or 0, sp.TargetType() or ''
    local function add(s)
        for i = 1, (s.NumEffects() or 0) do
            local at, b = s.Attrib(i)(), s.Base(i)()
            if at and at ~= 254 and at ~= 10 and fx[at] == nil then fx[at] = b or 0 end
        end
    end
    add(sp)
    if fx[374] or fx[470] then
        for i = 1, (sp.NumEffects() or 0) do
            local tr = sp.Trigger(i)
            if tr() then add(tr); dur = math.max(dur, tr.Duration.TotalSeconds() or 0) end
        end
    end
    return fx, dur, tt
end

-- effects that make an ability offensive (only counted when positive)
local OFFENSE = { [2] = true, [85] = true, [119] = true, [169] = true, [171] = true, [177] = true, [178] = true, [184] = true,
    [185] = true, [186] = true, [200] = true, [216] = true, [220] = true, [279] = true, [294] = true, [330] = true,
    [339] = true, [364] = true, [419] = true, [433] = true }

-- Defense tiers: panic = short big absorb or block, mitigate = less melee damage taken, sustain = the rest
local function defTier(fx, dur)
    if fx[320] or (math.max(fx[161] or 0, fx[162] or 0, fx[55] or 0) >= 50 and dur <= 30) then return 'panic' end
    if (fx[168] or 0) < 0 then return 'mitigate' end
    return 'sustain'
end

local function descRole(d)
    d = (d or ''):lower()
    if d:find('hatred') or d:find('attention') or d:find('taunt') then return 'Tank' end
    if d:find('absorb') or d:find('damage you take') or d:find('reducing damage done') or d:find('block') or d:find('parry')
        or d:find('riposte') or d:find('mitigat') or d:find('withstand') then return 'Defense' end
    if d:find('endurance to your pool') or (d:find('endurance') and (d:find('regenerat') or d:find('restor'))) then return 'Endurance' end
    if d:find('critical') or d:find('accuracy') or d:find('damage of your') or d:find('melee damage') or d:find('haste')
        or d:find('strikes') or d:find('attack') then return 'Offense' end
    return nil
end

local UTILITY_SKILLS = { ['Bind Wound'] = true, ['Disarm Traps'] = true, ['Forage'] = true, ['Hide'] = true, ['Pick Lock'] = true,
    ['Sense Heading'] = true, ['Sneak'] = true, ['Pick Pockets'] = true, ['Tracking'] = true, ['Fishing'] = true,
    ['Sense Traps'] = true, ['Begging'] = true, ['Remove Trap'] = true }

-- role from what the ability does: its effects, the game's category, then its description
-- (names only for skills and Lay on Hands)
local function classify(name, kind)
    local n = name:lower()
    if kind == 'skill' then
        if n:find('taunt') then return 'Tank' end
        if n:find('mend') then return 'Emergency' end
        if n:find('feign') or n:find('intimidat') then return 'Off' end
        return 'DPS'
    end
    if n:find('lay on hands') then return 'Emergency' end
    -- a passive AA (Gelid Rending, Bite of the Asp, Heavy Arrow) procs on its own: /alt act does nothing
    if kind == 'aa' and (mq.TLO.Me.AltAbility(name).Description() or ''):find('^This passive ability') then return 'Off' end
    local sp = abilitySpell({ name = name, kind = kind })
    if not sp or not sp() then return defaultRole(name, kind) end
    local fx, dur, tt = spellFx(sp)
    local self, group = tt == 'Self', tt:find('^Group') ~= nil
    local cat = '/' .. (sp.Category() or '') .. '/' .. (sp.Subcategory() or '') .. '/'
    local function is(...) for _, w in ipairs({ ... }) do if cat:find('/' .. w .. '/', 1, true) then return true end end return false end
    local function pos(k) return (fx[k] or 0) > 0 end
    local off = false
    for k in pairs(OFFENSE) do if pos(k) then off = true end end
    -- an AA that can't be kept up (Heart of Skyfire: 3 minutes, 15 minute reuse) is a burn, not a buff
    local reuse = kind == 'aa' and (mq.TLO.Me.AltAbility(name).ReuseTime() or 0) or 0

    if fx[74] then return 'Off' end                                   -- feign death: only to shed aggro (doShed)
    if fx[63] then return 'Off' end                                   -- memory blur (Silent Displacement): the tank's hate goes too
    if fx[26] or fx[83] or fx[88] or fx[104] or fx[145] then return 'Off' end   -- gate / teleport / evac: never automatic
    do   -- gives mana (Elemental Conversion, Cannibalization): used when mana runs low, keeping HP back for one that costs it
        local d = (sp.Description() or ''):lower()
        if kind ~= 'disc' and not off and d:find('mana') and (d:find('restore') or d:find('return')) then return 'Mana' end
    end
    -- my pet's (Pet / Pet2 target): one that makes it hit harder is a burn (Companion's Fury), a heal is for when it's low
    -- (Mend Companion), the rest guard it while a mob wears it down (Companion's Aegis, Host in the Shell, Fortification,
    -- Second Wind Ward); moving, shrinking or making the mobs forget it is never automatic
    if tt:find('^Pet') then
        if off then return 'Burn' end
        if fx[194] or fx[298] or next(fx) == nil then return 'Off' end
        return 'Pet', (pos(0) and dur == 0) and 'heal' or 'guard'
    end
    -- run speed (Lupine Spirit fired 744 times as DPS): the bard's Selo's covers it
    if (sp.SpellType() or ''):find('^Beneficial') and pos(3) then return 'Off' end
    if pos(92) or pos(192) or pos(114) or fx[444] or is('Hatred') then return 'Tank' end
    -- a knockback with no real damage (Sonic Displacement: 1 point) only pushes the mob off the tank
    if not off and (sp.PushBack() or 0) > 0 and (fx[0] or 0) > -100 then return 'Off' end
    if self and (fx[0] or 0) < 0 then return 'Off' end               -- costs your own health (HP -> mana)
    -- real defense: a sizeable absorb, less damage taken, avoidance or block (a 5% rune riding on a burn isn't)
    if (self or group) and ((fx[161] or 0) >= 20 or (fx[162] or 0) >= 20 or pos(55) or (fx[168] or 0) < 0 or (fx[172] or 0) >= 20
        or fx[320] or fx[443] or fx[446] or fx[450] or fx[451] or fx[452]) then
        return 'Defense', defTier(fx, dur)
    end
    if self and pos(189) and not off then return 'Endurance' end
    if is('Quick Heal', 'Duration Heals') then return 'Heal' end
    if not self and not group and (is('Resist Debuffs', 'Slow', 'Disempowering') or (fx[11] and fx[11] < 100)
        or (fx[46] or 0) < 0 or (fx[47] or 0) < 0 or (fx[48] or 0) < 0 or (fx[49] or 0) < 0 or (fx[50] or 0) < 0) then
        return 'Debuff'
    end
    if off then
        if dur == 0 or not (self or group) then return 'DPS' end
        -- by its own duration (bundled effects can last longer): 5 min+ or until cancelled is kept up, shorter is a burn
        local own = sp.Duration.TotalSeconds() or 0
        if own == 0 then own = dur end
        if kind == 'disc' then return 'Burn' end                         -- discs share the one active slot
        return (own < 0 or (own >= 300 and reuse <= own + 60)) and 'Buff' or 'Burn'
    end
    if is('Offensive', 'Skill Attacks', 'Techniques', 'Melee Damage', 'Throwing') then return (self or group) and dur > 0 and 'Burn' or 'DPS' end
    if pos(0) or pos(79) or pos(100) then
        if pos(15) or pos(189) then return (self or group) and 'Buff' or 'Off' end   -- regen bundles (Paragon)
        if not self or dur == 0 then return 'Heal' end
    end
    if fx[193] or (fx[0] or 0) < 0 then return 'DPS' end
    if not self and fx[21] then return 'CC' end
    if self and dur >= 120 then return reuse <= dur + 60 and 'Buff' or 'Burn' end
    local d = descRole(sp.Description())
    if d == 'Offense' then return (self or group) and dur > 0 and 'Burn' or 'DPS' end
    if d == 'Defense' then return 'Defense', defTier(fx, dur) end
    return d or 'Off'
end

-- why an ability is or isn't ready, with the seconds left when there's a timer
local function abilityCooldown(a)
    local tm
    if a.kind == 'disc' then tm = mq.TLO.Me.CombatAbilityTimer(a.name)
    elseif a.kind == 'aa' then tm = mq.TLO.Me.AltAbilityTimer(a.name)
    else tm = mq.TLO.Me.AbilityTimer(a.name) end
    return tm and tm() and (tm.TotalSeconds() or 0) or 0
end

local function abilityStatus(a)
    local back = (failedUntil[a.name] or 0) - mq.gettime()
    if back > 0 then return 'backed off', 'AutoXP tried it and it did not fire - waiting before the next try', math.ceil(back / 1000) end
    if a.kind ~= 'skill' and FIGHT.noShield(a.name, abilitySpell(a)) then return 'blocked', 'Needs a shield in the off hand', 0 end
    if readyNow(a) then return 'ready', 'Ready to use now', 0 end
    local cd = abilityCooldown(a)
    if cd > 0 then return 'cooldown', 'On cooldown (ranks of one line share it)', cd end
    if a.kind == 'disc' and mq.TLO.Me.ActiveDisc() then return 'blocked', 'Another discipline is running: ' .. mq.TLO.Me.ActiveDisc(), 0 end
    local sp = abilitySpell(a)
    local cost = sp and sp() and (sp.EnduranceCost() or 0) or 0
    if cost > (mq.TLO.Me.CurrentEndurance() or 0) then return 'blocked', string.format('Needs %d endurance', cost), 0 end
    return 'not ready', "The game says it can't be used right now (something it needs isn't there)", 0
end

local function fmtSecs(s)
    if s >= 60 then return string.format('%d:%02d', math.floor(s / 60), s % 60) end
    return string.format('%ds', s)
end

-- when each role fires (Abilities tab tooltip)
local ABILUSE = {
    Off = 'Never used.', Tank = 'Tank role only: on cooldown in fights (Taunt when your aggro slips).',
    DPS = 'On cooldown in fights.', Burn = 'On burns: a named mob on XTarget, a target at/above your level, the burn mob count, or /autoxp burn.',
    Defense = 'panic: below Panic HP %.  mitigate: below Defense HP %.\nsustain: below Defense HP %, or (Tank role) on a named or 2+ mobs.',
    Heal = 'When you or a group member are under the heal thresholds.', Emergency = 'When your HP is under the emergency %.',
    CC = 'Interrupting a casting mob and stunning adds.', Buff = 'Kept up out of combat.',
    Debuff = 'Debuff duty: once per mob, before the Debuffs list (malo on adds waiting for a mez first).',
    Endurance = 'Out of combat when endurance is under the endurance %.\nOne for a single target (Rallying Call): a groupmate under 30% mana, else the lowest under the endurance %.',
    Pull = 'As the pull method.',
    Mana = 'When your mana is under the mana-tools %, in or out of combat; one that costs health keeps 20% HP back\n(30% in a fight). Summon Modulation Shard only when none is in the bags.\nOne for others goes to the group: single target (Focused Paragon) on the lowest under 80% mana (60% if its\nreuse is over 2 min), a group one under 60%, one used on the mob when a caster is under 30%\n(Reflexive Rebuttal) or you are under the mana-tools % (Thought Leech).',
    Pet = 'In fights: heal (Mend Companion) under 30% pet HP; guard (Companion\'s Aegis, Host in the Shell) once the pet\nis under 80% HP and the guard isn\'t on it.',
}

local ABILVER = 14   -- bump when classify() changes: abilities are rescanned once (roles you set yourself stay)
local function scanAbilities()
    local found, seen, oldPos = {}, {}, {}
    for i, old in ipairs(S.abilities) do oldPos[old.name] = i end
    local function add(name, kind)
        if type(name) == 'string' and name ~= '' and name ~= 'NULL' and not seen[name] then
            seen[name] = true
            local role, tier = classify(name, kind)
            local enabled, userRole, prev = true, false, nil
            for _, old in ipairs(S.abilities) do
                if old.name == name then
                    enabled, prev = old.enabled ~= false, old
                    if old.userRole then role, tier, userRole = old.role, old.tier or tier, true end
                end
            end
            local sp = abilitySpell({ name = name, kind = kind })
            local lvl = sp and sp() and (sp.Level() or 0) or 0
            table.insert(found, { name = name, kind = kind, role = role, tier = tier, enabled = enabled, userRole = userRole,
                lvl = lvl < 255 and lvl or 0, id = sp and sp() and sp.ID() or 0, timer = kind == 'disc' and sp and sp() and sp.RecastTimerID() or 0,
                excl = prev and prev.excl, notWith = prev and prev.notWith })
        end
    end
    -- activated combat skills the character has (Combat Skills page), minus utility ones
    for i = 0, 100 do
        local k = mq.TLO.Skill(i)
        local sk = k() and k.Name()
        if sk and k.Activated() and not UTILITY_SKILLS[sk] and (mq.TLO.Me.Skill(sk)() or 0) > 0 then add(sk, 'skill') end
    end
    -- combat abilities (disciplines)
    for i = 1, 300 do local c = mq.TLO.Me.CombatAbility(i)(); if type(c) == 'string' and c ~= '' then add(c, 'disc') end end
    -- class and archetype AAs (AA window Class tab = List3, Archetype = List2), owned and activatable; the lists fill
    -- once the window is open
    local w = mq.TLO.Window('AAWindow')
    local opened = false
    -- the list fills over a second or two: it is read once its count has held still for 1.5s (read at the first row,
    -- Ramakrr kept 20 of his 46 AAs); a window that stays empty gets a second try
    for _ = 1, 2 do
        if not w.Open() then w.DoOpen(); opened = true end
        local last, since = -1, mq.gettime()
        mq.delay(12000, function()
            local c = w.Child('List3').Items() or 0
            if c ~= last then last, since = c, mq.gettime() end
            return c > 0 and mq.gettime() - since > 1500
        end)
        if (w.Child('List3').Items() or 0) > 0 then break end
        w.DoClose(); mq.delay(1000)
    end
    local nAA = 0
    for _, tab in ipairs({ 'List3', 'List2' }) do   -- Class, then Archetype (Malaise, Wind of Malaise...)
        local l = w.Child(tab)
        for r = 1, (l.Items() or 0) do
            local name = l.List(r, 1)()
            if type(name) == 'string' and mq.TLO.Me.AltAbility(name)() and mq.TLO.Me.AltAbility(name).Spell() then add(name, 'aa'); nAA = nAA + 1 end
        end
    end
    if opened then w.DoClose() end
    -- a saved AA the window list didn't show (it was still filling) is still mine: kept, with its role and place
    for _, old in ipairs(S.abilities) do
        if old.kind == 'aa' and not seen[old.name] and mq.TLO.Me.AltAbility(old.name)() and mq.TLO.Me.AltAbility(old.name).Spell() then
            add(old.name, 'aa'); nAA = nAA + 1
        end
    end
    -- the AA lists stayed empty (the window was slow to load): keep the saved list instead of losing every AA
    -- (a bard ran a whole evening with 9 abilities and no burns that way)
    if nAA == 0 and (mq.TLO.Me.AAPointsTotal() or 0) > 0 then
        log('ability scan: the AA window list stayed empty - kept the saved abilities'); return
    end
    -- ranks of one line share a timer: only the best (highest level, then newest) is used, whatever its role - one you
    -- placed yourself (or turned Off) counts too, so an older rank can't spend the timer elsewhere (Sanguine Blade as
    -- DPS kept Incarnadine Blade from its burns); the rest are Off
    local best = {}
    for _, a in ipairs(found) do
        if a.timer > 0 and (a.role ~= 'Off' or a.userRole) then
            local b = best[a.timer]
            if not b or a.lvl > b.lvl or (a.lvl == b.lvl and a.id > b.id) then best[a.timer] = a end
        end
    end
    for _, a in ipairs(found) do
        local b = a.timer > 0 and not a.userRole and best[a.timer]
        if b and b ~= a then a.role, a.note = 'Off', 'older rank' end
    end
    -- discs under half my level (Resistant, Fearless...) aren't worth an automatic slot
    local half = math.floor((mq.TLO.Me.Level() or 0) / 2)
    for _, a in ipairs(found) do
        if a.kind == 'disc' and a.lvl > 0 and a.lvl < half and not a.userRole and a.role ~= 'Off' then
            if a.role == 'Defense' then a.tier = 'panic'                     -- still a panic button
            else a.role, a.note = 'Off', 'low level' end
        end
    end
    -- your order if you've arranged it, else newest first
    if S.abilOrdered then
        table.sort(found, function(a, b) return (oldPos[a.name] or 10000 + a.id) < (oldPos[b.name] or 10000 + b.id) end)
    else
        table.sort(found, function(a, b) if a.lvl ~= b.lvl then return a.lvl > b.lvl end return a.id > b.id end)
    end
    S.abilities, S.abilVer = found, ABILVER
    log('scanned %d abilities', #found)
    for _, a in ipairs(found) do
        if a.role ~= 'Off' then log('  %s %-28s -> %s%s', a.kind, a.name, a.role, a.tier and (' (' .. a.tier .. ')') or '') end
    end
    save()
end
local mapRadius = -1
local function updateMapRadius()
    local want = (R.running and S.mode == 'Hunter') and S.radius or 0
    if want ~= mapRadius then
        mq.cmdf('/mapfilter SpellRadius %d', want)
        mapRadius = want
    end
end

-- pull spell: longest-range single-target detrimental gem (stun > nuke > DoT > other); never mez, root or calm
local function pickPullSpell()
    local best, bestRank, bestRange, bestLvl
    for g = 1, 13 do
        local sp = mq.TLO.Me.Gem(g)
        if sp() and sp.SpellType() == 'Detrimental' and sp.TargetType() == 'Single' then
            local cat, sub, rng, lvl = sp.Category() or '', sp.Subcategory() or '', sp.Range() or 0, sp.Level() or 0
            if rng >= 80 and sub ~= 'Enthrall' and sub ~= 'Root' and sub ~= 'Calm' then
                local rank = sub:find('Stun') and 1 or cat == 'Direct Damage' and 2 or cat == 'Damage Over Time' and 3 or 4
                if not best or rank < bestRank or (rank == bestRank and (rng > bestRange or (rng == bestRange and lvl > bestLvl))) then
                    best, bestRank, bestRange, bestLvl = sp.Name(), rank, rng, lvl
                end
            end
        end
    end
    S.pullSpell = best or ''
    log('pull spell: %s', best or 'none')
end

-- how Hunter pulls: Auto = pull spell, else a ranged item (bow/throwing), else a Pull ability, else walk in
local PULLS = { 'Auto', 'Melee', 'Spell', 'Ranged', 'Ability' }
local function pullPlan()
    local m = S.pullMethod
    if (m == 'Auto' or m == 'Spell') and S.pullSpell ~= '' and mq.TLO.Me.Gem(S.pullSpell)() then
        local sp = mq.TLO.Spell(S.pullSpell)
        return { how = 'Spell', name = S.pullSpell, range = math.min(sp.MyRange() or sp.Range() or 100, 200) }
    end
    if m == 'Auto' or m == 'Ranged' then
        local r = mq.TLO.Me.Inventory('ranged')
        if r() and (r.Range() or 0) > 30 then return { how = 'Ranged', name = r.Name(), range = math.min(r.Range(), 200) } end
    end
    if m == 'Auto' or m == 'Ability' then
        for _, a in ipairs(abilitiesFor('Pull')) do
            local sp = a.kind == 'aa' and mq.TLO.Me.AltAbility(a.name).Spell or mq.TLO.Spell(a.name)
            local rng = sp() and sp.Range() or 0
            if rng > 30 then return { how = 'Ability', name = a.name, ability = a, range = math.min(rng, 200) } end
        end
    end
    return nil
end

local function pullReady(p)
    if p.how == 'Spell' then return spellReady(p.name) end
    if p.how == 'Ability' then return abilityReady(p.ability) end
    return true
end

local function doPull(t)
    local p = R.pull
    if p.how == 'Spell' then return castOn(p.name, t.ID(), 'pull') end
    if p.how == 'Ability' then return useAbility(p.ability, t.ID(), 'pull') end
    if not targetId(t.ID()) then return false end
    mq.cmdf('/face fast id %d', t.ID()); mq.delay(300)
    mq.cmd('/ranged')
    log('pull %s with %s', t.CleanName(), p.name)
    return true
end

local function byLevel(names)
    table.sort(names, function(a, b) return (mq.TLO.Spell(a).Level() or 0) > (mq.TLO.Spell(b).Level() or 0) end)
    return names
end

local function gemSig()
    local g = {}
    for i = 1, (mq.TLO.Me.NumGems() or 8) do g[i] = mq.TLO.Me.Gem(i).Name() or '' end
    return table.concat(g, '|')
end

-- who a buff is for, by its effects: haste/attack/STR/DEX go to melee, mana regen/INT/WIS/max mana to
-- classes that use mana, anything else (HP, AC, stamina, resists, Unity bundles) to everyone
local buffWho, wantsBuff, hasBuff, buffStacks, refreshBuffs
do   -- its tables and helpers stay out of the main chunk (LuaJIT allows it 200 locals)
local MELEE = { WAR = true, PAL = true, SHD = true, MNK = true, ROG = true, BER = true, RNG = true, BST = true, BRD = true }
local NOMANA = { WAR = true, MNK = true, ROG = true, BER = true }
local MELEESPA = { [2] = true, [4] = true, [5] = true, [11] = true, [169] = true, [171] = true, [176] = true, [177] = true,
    [182] = true, [184] = true, [185] = true, [186] = true, [216] = true, [220] = true, [279] = true, [330] = true, [364] = true }
local CASTERSPA = { [8] = true, [9] = true, [15] = true, [97] = true, [294] = true }
local COREPA = { [0] = true, [1] = true, [46] = true, [47] = true, [48] = true, [49] = true, [50] = true, [69] = true }
local NOSPA = { [10] = true, [254] = true }

-- a Unity spell lasts seconds and casts the real buffs; anything else is its own buff
local function buffParts(sp)
    local parts, seen = {}, {}
    if (sp.Duration.TotalSeconds() or 0) < 600 then
        for i = 1, (sp.NumEffects() or 0) do
            local tr = sp.Trigger(i)
            if tr() and not seen[tr.ID()] then seen[tr.ID()] = true; table.insert(parts, tr) end
        end
    end
    if #parts == 0 then parts[1] = sp end
    return parts
end

local function buffSecs(sp)
    local d = 0
    for _, part in ipairs(buffParts(sp)) do d = math.max(d, part.Duration.TotalSeconds() or 0) end
    return d
end

local function buffSpas(sp)
    local set = {}
    for _, part in ipairs(buffParts(sp)) do
        for i = 1, (part.NumEffects() or 0) do
            local a = part.Attrib(i)()
            if a and not NOSPA[a] then set[a] = true end
        end
    end
    return set
end

local whoCache = {}
function buffWho(name)
    if whoCache[name] then return whoCache[name] end
    local melee, caster, core = false, false, false
    for a in pairs(buffSpas(mq.TLO.Spell(name))) do
        if MELEESPA[a] then melee = true elseif CASTERSPA[a] then caster = true elseif COREPA[a] then core = true end
    end
    local who = (core or melee == caster) and 'all' or (melee and 'melee' or 'caster')
    whoCache[name] = who
    return who
end

function wantsBuff(cls, who, meleeSelf)
    if who == 'melee' then return MELEE[cls] or meleeSelf end
    if who == 'caster' then return not NOMANA[cls] end
    return true
end

-- the buff (or any buff a Unity spell casts) is on me, or on s (a targeted spawn)
function hasBuff(name, s)
    for _, part in ipairs(buffParts(mq.TLO.Spell(name))) do
        local n = part.Name()
        if s then if s.Buff(n)() then return true end
        elseif mq.TLO.Me.Buff(n)() or mq.TLO.Me.Song(n)() then return true end
    end
    return false
end

-- a buff the game refused ("Your X spell did not take hold on Y. (Blocked by Z.)") isn't cast again where Z is on:
-- Stacks / StacksTarget can say yes while a better buff of its kind blocks it (Celerity under Exceptional Velocity).
-- Learned from the first refusal of each pair, for this session
local BLOCKEDBY = {}
mq.event('axpBlocked', 'Your #1# spell did not take hold#*#(Blocked by #2#.)', function(_, spell, by)
    BLOCKEDBY[spell] = BLOCKEDBY[spell] or {}
    if not BLOCKEDBY[spell][by] then
        BLOCKEDBY[spell][by] = true
        log('%s is blocked by %s - not cast where that is on', spell, by)
    end
end)

function buffStacks(name, onTarget)
    for by in pairs(BLOCKEDBY[name] or {}) do
        if onTarget and mq.TLO.Target.Buff(by)() or not onTarget and (mq.TLO.Me.Buff(by)() or mq.TLO.Me.Song(by)()) then
            return false
        end
    end
    for _, part in ipairs(buffParts(mq.TLO.Spell(name))) do
        if (onTarget and part.StacksTarget() or not onTarget and part.Stacks()) then return true end
    end
    return false
end

-- buffs from the spell book: HP, stat, resist, haste and proc buffs of 10+ minutes (Unity spells count by
-- what they cast), best of each line, skipping lines whose best is under half my level
local BUFFCAT = { ['HP Buffs'] = true, ['Statistic Buffs'] = true }
local BUFFSUB = { Haste = true, ['Combat Innates'] = true, ['Damage Shield'] = true }
local BUFFTT = { Self = true, Single = true, ['Group v1'] = true, ['Group v2'] = true }
function refreshBuffs()
    local lvl = mq.TLO.Me.Level() or 0
    R.buffLevel = lvl
    local best = {}
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        if b() and b.SpellType() == 'Beneficial' and (b.Level() or 0) <= lvl and (b.Level() or 0) >= math.floor(lvl / 2)
            and BUFFTT[b.TargetType() or ''] and (BUFFCAT[b.Category() or ''] or BUFFSUB[b.Subcategory() or '']) and buffSecs(b) >= 600 then
            -- one per line; each resist (fire, cold, poison, disease, magic) is its own line
            local key = (b.Category() or '') .. '/' .. (b.Subcategory() or '')
            if b.Subcategory() == 'Resist Buff' then
                for spa = 46, 50 do if b.HasSPA(spa)() then key = key .. '/' .. spa end end
            end
            -- damage shields: the best self-only one and the best one for others (the tank) are separate picks
            if b.Subcategory() == 'Damage Shield' then key = key .. (b.TargetType() == 'Self' and '/self' or '/other') end
            -- a group version within 10 levels of the best one wins: one cast buffs everybody
            local grp = (b.TargetType() or ''):find('^Group') ~= nil
            local rank = (b.Level() or 0) + (grp and 10 or 0)
            if not best[key] or rank > best[key].rank then best[key] = { name = b.Name(), lvl = b.Level() or 0, rank = rank } end
        end
    end
    local out, unity = {}, {}
    for _, b in pairs(best) do
        local sp = mq.TLO.Spell(b.name)
        if buffParts(sp)[1].ID() ~= sp.ID() then for a in pairs(buffSpas(sp)) do unity[a] = true end end
    end
    for _, b in pairs(best) do
        local sp, covered = mq.TLO.Spell(b.name), nil
        if buffParts(sp)[1].ID() == sp.ID() then
            for a in pairs(buffSpas(sp)) do covered = (covered ~= false) and unity[a] == true end
        end
        if not covered then table.insert(out, b) end
    end
    table.sort(out, function(a, b) return a.lvl > b.lvl end)
    local names = {}
    for _, b in ipairs(out) do table.insert(names, b.name) end
    local s = table.concat(names, ', ')
    if S.userLists.buffs then
        if s ~= R.bookBuffs then R.bookBuffs = s; log('buffs: keeping your list (from the book it would be: %s)', s) end
    elseif s ~= S.buffs then S.buffs = s; log('buffs from the book: %s', s) end
end
end

local DEBUFFSUB = { Slow = true, ['Resist Debuffs'] = true, Disempowering = true }
local SONGTT = { Self = true, ['Group v1'] = true, ['Group v2'] = true, ['AE PC v2'] = true }
-- a song that regenerates health/mana for the group (Chorus, Pulse) or bursts it (Crescendo)
local function REGENSONG(sp)
    return sp.SpellType() == 'Beneficial' and (sp.Category() == 'Regen' or (sp.HasSPA(15)() and (sp.TargetType() or ''):find('^Group')))
end
-- the casting skill is trained enough (75% of its cap) not to fizzle all the time
local function trained(sp)
    local sk = sp.Skill() or ''
    local cap = mq.TLO.Me.SkillCap(sk)() or 0
    return cap == 0 or (mq.TLO.Me.Skill(sk)() or 0) >= cap * 0.75
end

local FILLVER = 6   -- bump when the gem classification changes, to refill every character's lists once

-- the base of one effect of a spell (SPA 0 health, 15 mana, 192 hate), 0 without it
function FIGHT.spa(sp, spa)
    for i = 1, (sp.NumEffects() or 0) do
        if sp.Attrib(i)() == spa then return sp.Base(i)() or 0 end
    end
    return 0
end
function FIGHT.tap(name) return mq.TLO.Spell(name).Category() == 'Taps' end

local function fillFromGems()
    local heals, stuns, hate, nukes, mez, dots, debuffs, songs, rest, mana, pet = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, ''
    local untrained = {}
    local bard = mq.TLO.Me.Class.ShortName() == 'BRD'
    for g = 1, 13 do
        local sp = mq.TLO.Me.Gem(g)
        if sp() then
            local name, cat, sub = sp.Name(), sp.Category() or '', sp.Subcategory() or ''
            local bene = sp.SpellType() == 'Beneficial'
            if not bene and not trained(sp) then table.insert(untrained, name)
            elseif bard and bene then
                if SONGTT[sp.TargetType() or ''] then table.insert(songs, name) end
                if REGENSONG(sp) then table.insert(rest, name) end
            -- instant mana for myself (Gather Zeal, Traumatic Exchange): cast when mana runs low
            elseif bene and sp.TargetType() == 'Self' and (sp.Duration.TotalSeconds() or 0) == 0 and FIGHT.spa(sp, 15) > 0 then
                table.insert(mana, name)
            elseif cat == 'Heals' and (sub == 'Heals' or sub == 'Quick Heal' or sub == 'Duration Heals') then table.insert(heals, name)
            elseif sub:find('Stun') then
                table.insert(stuns, name)
                if not bene and cat == 'Direct Damage' and sp.HasSPA(0)() then table.insert(nukes, name) end
            -- a pure hate spell (Terror, Petition for Power): the tank's opener and lost-aggro list
            elseif not bene and sub == 'Jolt' and FIGHT.spa(sp, 192) > 0 then table.insert(hate, name)
            elseif sub == 'Enthrall' and (sp.TargetType() == 'Single' or sp.TargetType() == 'PB AE' or sp.TargetType() == 'Targeted AE') then table.insert(mez, name)
            elseif not bene and DEBUFFSUB[sub] and sp.TargetType() == 'Single' then table.insert(debuffs, name)
            elseif not bene and cat == 'Direct Damage' then table.insert(nukes, name)
            elseif not bene and cat == 'Damage Over Time' then table.insert(dots, name)
            -- lifetaps (a shadowknight's damage and healing): instant ones are nukes, ones that last are DoTs
            elseif not bene and cat == 'Taps' then table.insert((sp.Duration.TotalSeconds() or 0) > 0 and dots or nukes, name)
            elseif cat == 'Pet' and sub == 'Sum: Swarm' then table.insert(nukes, name)
            elseif cat == 'Pet' and sub:find('^Sum:') then pet = name end
        end
    end
    byLevel(heals); byLevel(stuns); byLevel(hate); byLevel(nukes); byLevel(dots); byLevel(debuffs); byLevel(mez)
    local tank = {}
    for _, l in ipairs({ stuns, hate }) do for _, n in ipairs(l) do table.insert(tank, n) end end
    -- a list you edited (or set in the settings file) stays as you wrote it: what it lacks is only logged
    local function set(key, names)
        if not S.userLists[key] then S[key] = table.concat(names, ', '); return end
        local have, extra = {}, {}
        for _, n in ipairs(list(S[key])) do have[n] = true end
        for _, n in ipairs(names) do if not have[n] then table.insert(extra, n) end end
        if #extra > 0 then log('%s: keeping your list (also memorized: %s)', key, table.concat(extra, ', ')) end
    end
    set('healSpells', heals); set('stuns', tank); set('ccStuns', stuns); set('nukes', nukes); set('mez', mez)
    set('dots', dots); set('debuffs', debuffs); set('manaSpells', mana)
    S.petSpell = pet
    refreshBuffs()
    if bard then set('songs', songs); set('restSongs', rest) end
    if #untrained > 0 then log('not using %s: casting skill too low (they fizzle)', table.concat(untrained, ', ')) end
    S.fillVer = FILLVER
    log('from gems: heals=[%s] stuns=[%s] nukes=[%s] dots=[%s] mez=[%s] debuffs=[%s] mana=[%s] pet=[%s] buffs=[%s]%s',
        S.healSpells, S.stuns, S.nukes, S.dots, S.mez, S.debuffs, S.manaSpells, S.petSpell, S.buffs, bard and (' songs=[' .. S.songs .. ']') or '')
    if not (S.userLists.pullSpell and mq.TLO.Me.Gem(S.pullSpell)()) then pickPullSpell() end
end

local TANKS = { WAR = true, PAL = true, SHD = true }

-- first start on a character (or a different class): build ability and spell lists from the game
local function autoSetup()
    local cls = mq.TLO.Me.Class.ShortName() or ''
    if S.class == cls then return end
    log('setting up for %s (%s)', cls, ranged() and 'ranged' or 'melee')
    S.class, S.role = cls, TANKS[cls] and 'Tank' or 'DPS'
    local ok, err = pcall(scanAbilities)
    if not ok then log('scan failed: %s', tostring(err)) end
    fillFromGems()
end

local function stopAll(reason)
    attackOff(); mq.cmd('/stick off'); mq.cmd('/nav stop'); petBackOff()
    if R.state == 'TRAVEL' then mq.cmd('/travelto stop') end
    if R.swapGem and R.swapGem.name ~= '' then mq.cmdf('/memspell %d "%s"', R.swapGem.g, R.swapGem.name) end
    if R.cast then R.cast.resume(); R.cast = nil end
    R.running = false; R.paused = false; R.targetId, R.pickId, R.swapGem = 0, 0, nil
    setState('IDLE')
    updateMapRadius()
    save()
    log('stopped: %s', reason or 'user')
end

-- the hunt zone is the zone I'm in, whenever AutoXP starts or Hunter is switched on (a zone given on the command
-- line, /lua run autoxp <zone>, holds for the first start: it travels there)
local function huntHere()
    local here = mq.TLO.Zone.ShortName() or ''
    if here ~= '' and here ~= S.zone then S.zone = here; log('hunt zone %s (the zone I am in)', here) end
end

local function start()
    if args[1] and not R.argZone then R.argZone = true else huntHere() end
    R.running, R.paused, R.kills, R.nukeLevel, R.healMemLevel, R.lastRoles, R.rolesWarned = true, false, 0, 0, -1, 0, false
    R.xp0, R.aa0, R.started = totalXp(), mq.TLO.Me.PctAAExp() or 0, mq.gettime()
    log('start: mode=%s role=%s heal=%s cc=%s debuff=%s nuke=%s dot=%s buff=%s rez=%s zone=%s', S.mode, S.role, S.heal and 'on' or 'off',
        S.cc and 'on' or 'off', S.debuff and 'on' or 'off', S.nuke and 'on' or 'off', S.dot and 'on' or 'off', S.buff and 'on' or 'off',
        S.rez and 'on' or 'off', S.zone)
    autoSetup()
    if S.swapGem and not R.swapGem then R.swapGem = { g = S.swapGem.g, name = S.swapGem.name } end
    if S.fillVer ~= FILLVER then fillFromGems() end
    if (S.pullVer or 0) < 1 then
        -- mobs 40 away came along with "alone" pulls (Sleeper's Tomb): the old default goes to the new one
        if S.avoidRadius == 40 then S.avoidRadius = 100; log('alone radius 40 -> 100 (the new default)') end
        S.pullVer = 1
    end
    if S.abilVer ~= ABILVER then local ok, err = pcall(scanAbilities); if not ok then log('scan failed: %s', tostring(err)) end end
    if S.pullSpell == '' then pickPullSpell() end
    if #S.abilities == 0 then local ok, err = pcall(scanAbilities); if not ok then log('scan failed: %s', tostring(err)) end end
    save()
    updateMapRadius()
    setState('BUFF')   -- a Hunter in the wrong zone travels from step(), once nothing holds it back
end

-- target priority (tank): casters > healers > hybrids > melee -------------------------------
local PRIO = { WIZ = 1, MAG = 1, NEC = 1, ENC = 1, CLR = 2, DRU = 2, SHM = 2, PAL = 3, SHD = 3, RNG = 3, BST = 3, BRD = 3 }
local function prio(s) return PRIO[s.Class.ShortName() or ''] or 4 end

local function hostiles()
    local out = {}
    for i = 1, (mq.TLO.Me.XTarget() or 0) do
        local x = mq.TLO.Me.XTarget(i)
        if x() and (x.ID() or 0) > 0 and x.Type() == 'NPC' and (x.Distance() or 999) < 150 then
            local s = mq.TLO.Spawn('id ' .. x.ID())
            if alive(s) then table.insert(out, s) end
        end
    end
    return out
end

local function mezzed(s)
    if (R.mezzed[s.ID()] or 0) > mq.gettime() then return true end
    return (mq.TLO.Target.ID() or 0) == s.ID() and mq.TLO.Target.Mezzed() ~= nil
end

-- someone (me or a group member in range) is below the heal thresholds
local function healTargets()
    local mt = mq.TLO.Group.MainTank.ID() or 0
    local out = {}
    local function add(id, name, pct, limit)
        if pct < limit then table.insert(out, { id = id, name = name, pct = pct, urgency = pct - limit }) end
    end
    add(myId(), 'self', hp(), myId() == mt and math.max(S.selfHealPct, S.tankHealPct) or S.selfHealPct)
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        if m() and m.Present() and not m.OtherZone() and m.Type() ~= 'Corpse' and (m.Distance() or 999) < 150 then
            local id = m.ID() or 0
            add(id, m.CleanName() or '?', m.PctHPs() or 100, id == mt and S.tankHealPct or S.groupHealPct)
        end
    end
    table.sort(out, function(a, b) return a.urgency < b.urgency end)
    return out
end

local function hurt() return #healTargets() > 0 end

-- nothing on XTarget and nobody hurt: safe to memorize or stand around buffing
local function quiet() return #hostiles() == 0 and not hurt() end

-- mez breaks: forget the mez so the add gets mezzed again right away
local function unmez(name)
    name = (name or ''):lower()
    for _, s in ipairs(hostiles()) do if (s.CleanName() or ''):lower() == name then R.mezzed[s.ID()] = nil end end
end
mq.event('axpWake', '#1# has been awakened by #2#.', function(_, who) unmez(who) end)
mq.event('axpWorn', 'Your #1# spell has worn off of #2#.', function(_, _, who) unmez(who) end)
mq.event('axpResist', '#1# resisted your #2#!', function(_, who, spell)
    -- a resisted debuff isn't on that mob: try it again
    local name = who:lower()
    for _, s in ipairs(hostiles()) do
        if (s.CleanName() or ''):lower() == name then R.mobCast[s.ID() .. '|' .. spell] = nil end
    end
    -- a resisted mez: again right away, but after the 2nd resist on that add the mezzer gives up on it
    for _, m in ipairs(list(S.mez)) do
        if m == spell then
            local id = R.lastMez and (R.lastMez.name or ''):lower() == name and R.lastMez.id or nil
            if not id then
                for _, s in ipairs(hostiles()) do if (s.CleanName() or ''):lower() == name then id = s.ID(); break end end
            end
            unmez(who)
            if id then
                R.mezResist[id] = (R.mezResist[id] or 0) + 1
                if R.mezResist[id] >= 2 then R.noMez[id] = true; log('%s resisted %s twice - giving up mezzing it', who, spell); return end
            end
            log('%s resisted %s - mezzing again', who, spell)
            return
        end
    end
end)

local function bestTarget()
    local best, bp, bm
    for _, s in ipairs(hostiles()) do
        if s.ID() == R.pickId then return s, 0 end
        local p, m = prio(s), mezzed(s)
        if not best or (bm and not m) or (bm == m and (p < bp or (p == bp and (s.PctHPs() or 100) < (best.PctHPs() or 100)))) then
            best, bp, bm = s, p, m
        end
    end
    return best, bp
end

-- bards: keep the Songs list going in order (re-sing with 3s or less left) and the Selo's run-speed AA
-- up for the group; songs that cost mana wait while mana is under songManaMin %, except regen songs
local function songUp(name)
    local s = mq.TLO.Me.Song(name)
    if not s() then s = mq.TLO.Me.Buff(name) end
    return s() and (s.Duration.TotalSeconds() or 0) > 3
end

local function doSongs()
    if mq.TLO.Me.Class.ShortName() ~= 'BRD' or casting() or FIGHT.keepInvis() then return false end
    local SELO = "Selo's Sonata"
    local aa = mq.TLO.Me.AltAbility(SELO)
    if aa() and mq.TLO.Me.AltAbilityReady(SELO)() then
        local tr = aa.Spell.Trigger(1)
        -- let it finish: a song started right after it doesn't take
        if not tr() or not songUp(tr.Name()) then mq.cmdf('/alt act %d', aa.ID()); mq.delay(800); return true end
    end
    local calm = #hostiles() == 0 and R.state ~= 'FIGHT'
    for _, s in ipairs(list(calm and S.restSongs ~= '' and S.restSongs or S.songs)) do
        local sp = mq.TLO.Spell(s)
        if sp() and not songUp(s) and spellReady(s) and mq.gettime() >= (R.songNext[s] or 0)
            and (mq.TLO.Me.CurrentMana() or 0) >= (sp.Mana() or 0)
            and ((sp.Mana() or 0) == 0 or mana() >= S.songManaMin or sp.Category() == 'Regen') then
            if castOn(s, myId(), 'song') then
                -- a song whose recast outlasts it (Regar's Lively Crescendo: 30s, 45s recast) reads ready before it is;
                -- and its buff shows a moment after the cast bar closes (Psalm sung twice in a row, 2026-10-17 22:30:42)
                R.songNext[s] = mq.gettime() + (sp.MyCastTime() or 0) + (sp.RecastTime() or 0) + 1000
                return true
            end
        end
    end
    return false
end

-- roles -----------------------------------------------------------------------------------
local function doHeal()
    if not S.heal then return false end
    -- emergency abilities (e.g. Lay on Hands) first
    if hp() < S.emergencyPct then
        for _, a in ipairs(abilitiesFor('Emergency')) do if useAbility(a, myId(), string.format('emergency %d%%', hp())) then return true end end
    end
    -- the heal list split: single-target heals, group heals, heals over time
    local single, group, hot = {}, {}, {}
    for _, h in ipairs(list(S.healSpells)) do
        local sp = mq.TLO.Spell(h)
        if sp() then
            if sp.Subcategory() == 'Duration Heals' then table.insert(hot, h)
            elseif (sp.TargetType() or ''):find('^Group') then table.insert(group, h)
            else table.insert(single, h) end
        end
    end
    local who = healTargets()
    if #who > 0 then
        local t = who[1]
        local why = string.format('%s %d%%', t.name, t.pct)
        -- two or more hurt: a group heal reaches them all
        if #who >= 2 then
            for _, g in ipairs(group) do if castOn(g, myId(), string.format('%d hurt, %s', #who, why), 'heal') then return true end end
        end
        -- under 35%: instant heal abilities, then the fastest heal; otherwise the biggest heal, abilities kept for later
        local urgent = t.pct < 35
        if urgent then
            for _, a in ipairs(abilitiesFor('Heal')) do if useAbility(a, t.id, why) then return true end end
            table.sort(single, function(a, b) return (mq.TLO.Spell(a).MyCastTime() or 0) < (mq.TLO.Spell(b).MyCastTime() or 0) end)
        end
        for _, h in ipairs(single) do if castOn(h, t.id, why, 'heal') then return true end end
        -- single heals all on cooldown: a group heal still reaches them, then the abilities
        for _, g in ipairs(group) do if castOn(g, myId(), why, 'heal') then return true end end
        if not urgent then
            for _, a in ipairs(abilitiesFor('Heal')) do if useAbility(a, t.id, why) then return true end end
        end
    end
    -- heals-over-time kept up while the tank is fighting and has taken any damage: a group one while it's not on me,
    -- a single-target one on the tank, again when it runs out
    if #hot > 0 and #hostiles() > 0 then
        local mt = mq.TLO.Group.MainTank
        if mt() and mt.Type() ~= 'Corpse' and (mt.PctHPs() or 100) < 95 then
            local why = string.format('HoT, tank %d%%', mt.PctHPs() or 0)
            for _, h in ipairs(hot) do
                local sp = mq.TLO.Spell(h)
                if sp.TargetType() == 'Single' then
                    if mq.gettime() >= (R.hotUntil[h .. mt.ID()] or 0) and castOn(h, mt.ID(), why, 'heal') then
                        R.hotUntil[h .. mt.ID()] = mq.gettime() + (sp.Duration.TotalSeconds() or 18) * 1000
                        return true
                    end
                elseif not hasBuff(h) and castOn(h, myId(), why, 'heal') then return true end
            end
        end
    end
    return false
end

-- CC duty: mez the adds - never my target or the tank's (the group main assist's). Two or more awake adds around
-- me take an AE mez (PB AE / targeted AE in the Mez list); otherwise one at a time, nearest first (castOn checks
-- each mez's own range and line of sight)
local function doCC(t)
    if not S.cc or hp() < 40 then return false end
    local adds = hostiles()
    if #adds > 1 then
        local keep = { [R.targetId] = true, [mq.TLO.Me.GroupAssistTarget.ID() or 0] = true }
        local single = {}
        for _, m in ipairs(list(S.mez)) do
            local sp = mq.TLO.Spell(m)
            local tt = sp.TargetType() or ''
            if tt == 'Single' then table.insert(single, m)
            elseif gemUp(m) and not blocked(m) then
                -- AE mez first: centred on the awake add with the most awake adds around it. A PB AE (bard) steps in
                -- there first - songs carry on while moving - and gives up stepping after 5s
                local r = (sp.AERange() or 0) > 0 and sp.AERange() or 30
                local function d3(a, b) return math.sqrt((a.X() - b.X()) ^ 2 + (a.Y() - b.Y()) ^ 2 + (a.Z() - b.Z()) ^ 2) end
                local awake = {}
                for _, x in ipairs(adds) do
                    -- a named isn't mezzed (immune, or not worth waking)
                    if not keep[x.ID()] and not mezzed(x) and not R.noMez[x.ID()] and not x.Named() and x.LineOfSight() then table.insert(awake, x) end
                end
                local best, bestN = nil, 0
                for _, a in ipairs(awake) do
                    local n = 0
                    for _, b in ipairs(awake) do if d3(a, b) <= r * 0.9 then n = n + 1 end end
                    if n > bestN then best, bestN = a, n end
                end
                if best and bestN >= 2 then
                    local now = mq.gettime()
                    if tt == 'PB AE' and (best.Distance3D() or 999) > r * 0.6 then
                        if (R.aeStepAt or 0) == 0 then R.aeStepAt = now end
                        if now - R.aeStepAt < 5000 then
                            if not mq.TLO.Navigation.Active() then mq.cmdf('/nav id %d distance=%d', best.ID(), math.floor(r * 0.4)) end
                            return true
                        end
                    else
                        if mq.TLO.Navigation.Active() and (R.aeStepAt or 0) > 0 then mq.cmd('/nav stop') end
                        local center = tt == 'Targeted AE' and best or mq.TLO.Me
                        local hit = {}
                        for _, x in ipairs(awake) do if d3(center, x) <= r then table.insert(hit, x) end end
                        if castOn(m, tt == 'Targeted AE' and best.ID() or myId(), string.format('AE mez, %d adds', #hit), 'cc') then
                            local untilT = now + ((sp.Duration.TotalSeconds() or 18) - 6) * 1000
                            for _, x in ipairs(hit) do R.mezzed[x.ID()] = untilT end
                            R.aeStepAt = 0
                            return true
                        end
                    end
                else
                    R.aeStepAt = 0
                end
            end
        end
        table.sort(adds, function(a, b) return (a.Distance3D() or 999) < (b.Distance3D() or 999) end)
        for _, x in ipairs(adds) do
            if not keep[x.ID()] and not mezzed(x) and not R.noMez[x.ID()] and not x.Named() then
                for _, m in ipairs(single) do
                    if castOn(m, x.ID(), 'mez add', 'cc') then
                        R.lastMez = { id = x.ID(), name = x.CleanName() }
                        R.mezzed[x.ID()] = mq.gettime() + ((mq.TLO.Spell(m).Duration.TotalSeconds() or 18) - 6) * 1000
                        return true
                    end
                end
            end
        end
    end
    local stuns = list(S.ccStuns)
    if t and alive(t) and t.Casting() and t.Distance() < 60 then
        for _, a in ipairs(abilitiesFor('CC')) do if useAbility(a, t.ID(), 'interrupt') then return true end end
        for _, s in ipairs(stuns) do if castOn(s, t.ID(), 'interrupt', 'cc') then return true end end
    end
    for _, x in ipairs(hostiles()) do
        if x.ID() ~= R.targetId and x.Distance() < 60 and not mezzed(x) then   -- never wake a mezzed add
            for _, a in ipairs(abilitiesFor('CC')) do if useAbility(a, x.ID(), 'add') then return true end end
            for _, s in ipairs(stuns) do if castOn(s, x.ID(), 'add', 'cc') then return true end end
        end
    end
    return false
end

-- melee positioning: if any hostile is behind/flanking us, step to the far side of our target
-- (away from the other mobs) so the target and all adds are in front of us.
local function relBearing(s)
    local d = math.abs(((s.HeadingTo.Degrees() or 0) - (mq.TLO.Me.Heading.Degrees() or 0) + 540) % 360 - 180)
    return d   -- 0 = dead ahead, 180 = directly behind
end

local function keepMobsInFront(t)
    if ranged() or S.role ~= 'Tank' or not S.keepInFront or not alive(t) or mq.gettime() - R.lastReposition < 4000 then return false end
    local close = {}
    for _, s in ipairs(hostiles()) do if (s.Distance() or 999) < 30 then table.insert(close, s) end end
    if #close < 2 then return false end
    local behind = 0
    for _, s in ipairs(close) do if relBearing(s) > 100 then behind = behind + 1 end end
    if behind == 0 then return false end
    -- centroid of the other mobs
    local ay, ax, n = 0, 0, 0
    for _, s in ipairs(close) do if s.ID() ~= t.ID() then ay, ax, n = ay + s.Y(), ax + s.X(), n + 1 end end
    if n == 0 then return false end
    ay, ax = ay / n, ax / n
    local ty, tx = t.Y(), t.X()
    local dy, dx = ty - ay, tx - ax
    local len = math.sqrt(dy * dy + dx * dx)
    if len < 2 then
        -- adds stacked on the target: back straight away from the pile instead
        dy, dx = mq.TLO.Me.Y() - ty, mq.TLO.Me.X() - tx
        len = math.sqrt(dy * dy + dx * dx)
        if len < 1 then return false end
    end
    local gy, gx = ty + dy / len * 12, tx + dx / len * 12
    R.lastReposition = mq.gettime()
    log('%d mob(s) behind me - repositioning to keep %d in front', behind, #close)
    mq.cmd('/stick off')
    mq.cmdf('/moveto loc %.1f %.1f', gy, gx)
    mq.delay(3000, function()
        local my, mx = mq.TLO.Me.Y(), mq.TLO.Me.X()
        return math.sqrt((my - gy) ^ 2 + (mx - gx) ^ 2) < 3
    end)
    mq.cmd('/moveto off')
    mq.cmdf('/face fast id %d', t.ID())
    mq.cmd('/stick 8 moveback')
    if not R.attacking then attackOn() end
    return true
end

local function doTank(t)
    if S.role ~= 'Tank' or not alive(t) then return false end
    if S.prioritize and R.targetId ~= R.pickId and mq.gettime() - R.lastSwitch > 3000 then
        local best, bp = bestTarget()
        if best and best.ID() ~= R.targetId and bp < prio(t) then
            log('switch target -> %s (%s, prio %d)', best.CleanName(), best.Class.ShortName() or '?', bp)
            R.targetId, R.targetName, R.lastSwitch, R.opened = best.ID(), best.CleanName(), mq.gettime(), false
            attackOn(); closeIn(best); return true
        end
    end
    if not R.opened then
        R.opened = true
        for _, s in ipairs(list(S.stuns)) do if castOn(s, t.ID(), 'opener') then return true end end
    elseif S.stunCooldown and (t.PctHPs() or 100) > 5 then
        for _, s in ipairs(list(S.stuns)) do if castOn(s, t.ID(), 'stun') then return true end end
    end
    if S.useTaunt and (mq.TLO.Me.PctAggro() or 100) < 100 then
        for _, a in ipairs(abilitiesFor('Tank')) do
            if a.name:lower():find('taunt') and useAbility(a, t.ID(), string.format('aggro %d%%', mq.TLO.Me.PctAggro() or 0)) then return true end
        end
    end
    for _, a in ipairs(abilitiesFor('Tank')) do
        if not a.name:lower():find('taunt') and useAbility(a, t.ID(), 'tank') then return true end
    end
    -- aggro slipping: the hate and stun spells too (Terror of Tarantis)
    if (mq.TLO.Me.PctAggro() or 100) < 100 then
        for _, s in ipairs(list(S.stuns)) do if castOn(s, t.ID(), string.format('aggro %d%%', mq.TLO.Me.PctAggro() or 0)) then return true end end
    end
    return false
end

-- whether my spell is on the mob: AutoXP's own record of what it cast where (the spell's duration, 15s to 2 min;
-- a resist clears it). Never Spawn.MyBuff / Spell.Trigger here: on some Luclin mobs and trigger spells those native
-- lookups fault and kill the script ("Abnormal exception thrown from coroutine!")
local function onMob(t, name)
    return mq.gettime() < (R.mobCast[(t.ID() or 0) .. '|' .. name] or 0)
end

-- counted as on the mob for its duration (15s to 2 min) when the buff can't be seen; a resist clears it
local function castOnMob(name, t, why)
    if not castOn(name, t.ID(), why) then return false end
    local secs = math.min(120, math.max(15, mq.TLO.Spell(name).Duration.TotalSeconds() or 15))
    R.mobCast[t.ID() .. '|' .. name] = mq.gettime() + secs * 1000
    return true
end

local DEB = {}   -- debuff helpers (one table: the main chunk is near LuaJIT's 200-local limit)
-- my debuffs: the Debuff abilities first (Malaise, Sha's Reprisal...: instant), then the Debuffs list. Each has a kind
-- (malo, slow, cripple) and a mob gets one of each kind - an ability on cooldown falls back to the spell
-- the kind from the spell's own category and effects - never by following its triggers (that native lookup can fault);
-- a debuff that only casts another spell (Wind of Malaise) is told by its name
function DEB.kind(sp)
    local sub = sp.Subcategory() or ''
    if sub == 'Resist Debuffs' then return 'malo' end
    if sub == 'Slow' then return 'slow' end
    if sub == 'Disempowering' then return 'cripple' end
    for i = 1, (sp.NumEffects() or 0) do
        local at, b = sp.Attrib(i)(), sp.Base(i)() or 0
        if at and at >= 46 and at <= 50 and b < 0 then return 'malo' end
        if at == 11 and b < 100 then return 'slow' end
    end
    local n = (sp.Name() or ''):lower()
    if n:find('mala') or n:find('malo') or n:find('tash') then return 'malo' end
    if n:find('slow') or n:find('reprisal') or n:find('drows') or n:find('languid') then return 'slow' end
    if n:find('crippl') or n:find('incapacit') then return 'cripple' end
    return sub
end

function DEB.list()
    local sig = S.debuffs
    for _, a in ipairs(abilitiesFor('Debuff')) do sig = sig .. '|' .. a.name end
    if R.dlist and R.dlistSig == sig then return R.dlist end
    R.dlistSig = sig
    local out = {}
    for _, a in ipairs(abilitiesFor('Debuff')) do
        local sp = abilitySpell(a)
        if sp and sp() then table.insert(out, { abil = a, spell = sp.Name(), kind = DEB.kind(sp), dmg = sp.HasSPA(0)() }) end
    end
    for _, d in ipairs(list(S.debuffs)) do
        local sp = mq.TLO.Spell(d)
        if sp() then table.insert(out, { spell = d, kind = DEB.kind(sp), dmg = sp.HasSPA(0)() }) end
    end
    R.dlist, R.dlistAt = out, mq.gettime()
    return out
end

-- the kinds of debuff my target wears, from the target window: every caster's, so a shaman's malo counts for the mage
-- (both malo'd every mob). Read again every 2s; nil for a mob that isn't my target (only my own record counts there)
function DEB.worn(m)
    local t = mq.TLO.Target
    if not (t() and t.ID() == m.ID() and t.BuffsPopulated()) then return nil end
    if R.wornId == m.ID() and mq.gettime() - (R.wornAt or 0) < 2000 then return R.worn end
    local kinds = {}
    for i = 1, (t.BuffCount() or 0) do
        local n = t.Buff(i).Name()
        local sp = n and mq.TLO.Spell(n)
        if sp and sp() then kinds[DEB.kind(sp)] = true end
    end
    R.worn, R.wornId, R.wornAt = kinds, m.ID(), mq.gettime()
    return kinds
end

function DEB.has(m, dl, kind)
    local worn = DEB.worn(m)
    if worn and worn[kind] then return true end
    for _, e in ipairs(dl) do if e.kind == kind and onMob(m, e.spell) then return true end end
    return false
end

-- an ability's debuff counts as on the mob for its duration; one whose own spell lasts 0s only casts the real debuff
-- (Malaise X -> Malosinetra, 20 minutes): 2 minutes. At the 15s floor Malaise went out every 15s on the same mob
function DEB.on(m, e, why)
    if not e.abil then return castOnMob(e.spell, m, why) end
    if not useAbility(e.abil, m.ID(), why) then return false end
    local dur = mq.TLO.Spell(e.spell).Duration.TotalSeconds() or 0
    R.mobCast[m.ID() .. '|' .. e.spell] = mq.gettime() + (dur > 0 and math.min(120, math.max(15, dur)) or 120) * 1000
    return true
end

-- Debuff duty: slow, malo and cripple the target, then each add (a malo'd add takes a mez far more often, a slowed
-- one hits softer). A mezzed add only gets debuffs that do no damage, so the mez holds
local function doDebuff(t)
    if not S.debuff then return false end
    local mobs = {}
    local tid = alive(t) and t.ID() or 0
    -- a named keeps its debuffs (the slow!) to the end; other mobs aren't worth one under 40%
    if tid > 0 and (t.PctHPs() or 0) > (t.Named() and 5 or 40) then table.insert(mobs, t) end
    for _, x in ipairs(hostiles()) do
        local xid = x.ID() or 0
        if xid ~= tid and (x.PctHPs() or 0) > 40 and x.LineOfSight() then table.insert(mobs, x) end
    end
    local dl = DEB.list()
    for _, m in ipairs(mobs) do
        local mid = m.ID() or 0
        local asleep = mid ~= tid and mezzed(m)
        for _, e in ipairs(dl) do
            if not DEB.has(m, dl, e.kind) and not (asleep and e.dmg) and DEB.on(m, e, mid == tid and 'debuff' or 'debuff add') then return true end
        end
    end
    return false
end

local function topAggro()
    if (mq.TLO.Me.PctAggro() or 0) >= 100 then return true end
    for i = 1, (mq.TLO.Me.XTarget() or 0) do
        if (mq.TLO.Me.XTarget(i).PctAggro() or 0) >= 100 then return true end
    end
    return false
end

local function doShed(t)
    if S.role ~= 'DPS' or (mq.TLO.Group.Members() or 0) == 0 or mq.TLO.Me.Feigning() or not topAggro() then return false end
    for _, a in ipairs(S.abilities) do
        if a.enabled ~= false and dropsAggro(a) and useAbility(a, R.targetId, 'drop aggro') then
            R.feignAt = mq.gettime(); attackOff(); mq.cmd('/stick off')
            return true
        end
    end
    return false
end

local function abilityUp(a)
    local sp = abilitySpell(a)
    if not sp or not sp() then return false end
    if (mq.TLO.Me.ActiveDisc.ID() or 0) == sp.ID() then return true end
    if hasBuff(sp.Name()) then return true end
    -- an aura shows under the ability's own name, not its spell's (Pact of the Wolf XV, cast by "Invoke Pact of the
    -- Wolf XV", was re-used every 20s and "did not fire")
    return a.kind == 'aa' and FIGHT.buffOn(a.name)
end

-- one of my buffs or songs starts with one of these names ('Auspice' matches Auspice of the Hunter, any rank); the
-- names are read at most every 0.5s (and again after an ability fires)
function FIGHT.buffOn(names)
    local now = mq.gettime()
    if not R.myBuffs or now - R.myBuffsAt > 500 then
        local t = {}
        for i = 1, 50 do local b = mq.TLO.Me.Buff(i).Name(); if b then t[#t + 1] = b end end
        for i = 1, 35 do local b = mq.TLO.Me.Song(i).Name(); if b then t[#t + 1] = b end end
        R.myBuffs, R.myBuffsAt = t, now
    end
    for _, n in ipairs(list(names)) do
        for _, b in ipairs(R.myBuffs) do if b:find(n, 1, true) == 1 then return true end end
    end
    return false
end

-- abilities sharing an excl tag take turns (Outrider's Accuracy, then Group Guardian of the Forest, then Guardian of the
-- Forest): one waits while another of its tag is up, or while one listed before it is ready to go first
function FIGHT.exclWait(a)
    local before = true
    for _, o in ipairs(S.abilities) do
        if o == a then before = false
        elseif o.excl == a.excl and o.enabled ~= false and o.role ~= 'Off' and (abilityUp(o) or (before and abilityReady(o))) then return true end
    end
    return false
end

-- one discipline runs at a time: one that lasts waits while another runs (Spite of Mirenilla "did not fire" 41 times
-- under Carapace)
function FIGHT.discBusy(a)
    if a.kind ~= 'disc' then return false end
    local active = mq.TLO.Me.ActiveDisc()
    if not active or active == '' or active == a.name then return false end
    return (mq.TLO.Spell(a.name).Duration.TotalSeconds() or 0) > 0
end

-- a detrimental AE (PB, targeted, directional) needs 2+ mobs on XTarget, no mezzed one in its reach and no idle NPC
-- there for it to pull in (a bard's Vainglorious Shout woke the adds it had just mezzed)
function FIGHT.aeBlocked(sp, id)
    if not sp or not sp() or sp.SpellType() ~= 'Detrimental' then return false end
    local tt = sp.TargetType() or ''
    if not (tt:find('AE') or tt:find('Directional') or tt:find('Beam')) then return false end
    local mobs = hostiles()
    if #mobs < 2 then return true end
    local c = tt == 'Targeted AE' and spawn(id) or mq.TLO.Me
    if not c or not c() then return true end
    local r = math.max(30, sp.AERange() or 0)
    local cx, cy, cz, near = c.X() or 0, c.Y() or 0, c.Z() or 0, 0
    for _, x in ipairs(mobs) do
        if math.sqrt(((x.X() or 0) - cx) ^ 2 + ((x.Y() or 0) - cy) ^ 2) <= r + 10 and math.abs((x.Z() or 0) - cz) < 50 then
            if mezzed(x) then return true end
            near = near + 1
        end
    end
    return (mq.TLO.SpawnCount(string.format('npc loc %.0f %.0f %.0f radius %d zradius 50', cx, cy, cz, r))() or 0) > near
end

-- a spell whose reagent isn't in the bags is skipped (Heartbreak needs CLASS 3 Wood Silver Tip Arrows: 463 failed casts)
function FIGHT.noReagent(sp)
    for i = 1, 4 do
        local id = sp.ReagentID(i)()
        if id and id > 0 and (mq.TLO.FindItemCount(id)() or 0) < math.max(1, sp.ReagentCount(i)() or 1) then
            local n = sp.Name() or '?'
            if not R.reagentNote[n] then R.reagentNote[n] = true; log('not casting %s: its reagent (item %d) is not in the bags', n, id) end
            return true
        end
    end
    -- and one it needs but doesn't use up (Goblin Skin's Pearl: memorized, "You are missing Pearl", once a minute)
    for i = 1, 4 do
        local id = sp.NoExpendReagentID(i)()
        if id and id > 0 and (mq.TLO.FindItemCount(id)() or 0) < 1 then
            local n = sp.Name() or '?'
            if not R.reagentNote[n] then R.reagentNote[n] = true; log('not casting %s: it needs item %d in the bags', n, id) end
            return true
        end
    end
    return false
end

-- in a fight, after the burns: my combat buffs (not under a better one the game said blocks it: Twincast under Improved
-- Twincast). Ahead of the burns the Twincast spell went first and Improved Twincast waited for it to fade (28s and 23s
-- on two named pulls)
function FIGHT.selfCombatBuffs()
    for _, b in ipairs(list(S.combatBuffs)) do
        if spellReady(b) and not mq.TLO.Me.Buff(b)() and not mq.TLO.Me.Song(b)() and buffStacks(b, false)
            and castOn(b, myId(), 'combat buff') then return true end
    end
    return false
end

-- in a fight: tank buffs on the group main tank (a mage's Igneous Veil and Boiling Skin, a shaman's Moroseness), recast
-- when my own cast of it runs out
function FIGHT.tankBuffs()
    local mt = mq.TLO.Group.MainTank
    local id = S.tankBuffs ~= '' and mt() and mt.Type() ~= 'Corpse' and mt.ID() or 0
    if id == 0 then return false end
    for _, b in ipairs(list(S.tankBuffs)) do
        local key = b .. '|' .. id
        if mq.gettime() >= (R.tankBuffUntil[key] or 0) and spellReady(b) and castOn(b, id, 'tank buff') then
            R.tankBuffUntil[key] = mq.gettime() + math.max(10, (mq.TLO.Spell(b).Duration.TotalSeconds() or 10) - 6) * 1000
            return true
        end
    end
    return false
end

-- invisible (bard group invis while traveling) and not in a fight: nothing that breaks it - no cast, ability, song or
-- item click. A fight is any NPC on the extended target list, or my own pull / engage (APPROACH, FIGHT)
function FIGHT.keepInvis()
    local me = mq.TLO.Me
    if not (me.Invis(1)() or me.Invis(2)() or me.Invis(3)()) then R.invisNote = nil; return false end
    if R.state == 'FIGHT' or R.state == 'APPROACH' then return false end
    for i = 1, (me.XTarget() or 0) do
        local x = me.XTarget(i)
        if (x.ID() or 0) > 0 and x.Type() == 'NPC' then return false end
    end
    if not R.invisNote then R.invisNote = true; log('invisible - no casts, abilities or songs until a fight') end
    return true
end

-- Defense abilities by tier: panic below panicPct, mitigate below defPct, sustain (Carapace / Mantle style)
-- below defPct, or for the Tank role on a named mob or 2+ mobs (a mage's absorbs went at 100% HP whenever it held aggro)
local function doDefense()
    local mobs = hostiles()
    if #mobs == 0 then return false end
    local h, t = hp(), spawn(R.targetId)
    local tank = S.role == 'Tank'
    for _, a in ipairs(abilitiesFor('Defense')) do
        local tier = a.tier or 'sustain'
        local want = (tier == 'panic' and h < S.panicPct) or (tier == 'mitigate' and h < S.defPct)
            or (tier == 'sustain' and (h < S.defPct or (tank and (#mobs >= 2 or (alive(t) and t.Named())))))
        if want and not abilityUp(a) then
            -- only one discipline runs at a time: stop an offensive one so the defensive one can start
            local active = mq.TLO.Me.ActiveDisc()
            local busy = false
            if a.kind == 'disc' and active and active ~= a.name then
                local def = false
                for _, o in ipairs(S.abilities) do if o.name == active and o.role == 'Defense' then def = true end end
                if def then busy = true                                       -- a defensive disc is already running
                else log('stopping %s for %s', active, a.name); mq.cmd('/stopdisc'); mq.delay(300) end
            end
            if not busy and useAbility(a, nil, string.format('%s, HP %d%%', tier, h)) then return true end
        end
    end
    return false
end

-- my pet's abilities (role Pet), in a fight: a heal under 30% pet HP (Mend Companion), a guard not on it yet once a mob
-- wears it under 80% (Companion's Aegis, Host in the Shell, Companion's Fortification); they used to sit Off
function FIGHT.petGuard()
    local pet = mq.TLO.Me.Pet
    if (pet.ID() or 0) == 0 or #hostiles() == 0 then return false end
    local php = pet.PctHPs() or 100
    if php >= 80 then return false end
    for _, a in ipairs(abilitiesFor('Pet')) do
        local sp = abilitySpell(a)
        local on = sp and sp() and (sp.Duration.TotalSeconds() or 0) > 0 and mq.TLO.Pet.Buff(sp.Name())() ~= nil
        local want = (a.tier == 'heal' and php < 30) or (a.tier ~= 'heal' and not on)
        if want and useAbility(a, nil, string.format('pet HP %d%%', php)) then return true end
    end
    return false
end

-- Burn abilities, in list order: a named mob anywhere on XTarget, a target at/above my level, the burn mob count (5: at
-- 3 the long burns went on trash pulls), or /autoxp burn (60s). Abilities with an excl tag take
-- turns, and a discipline that lasts waits for the running one
local function burning(t)
    if mq.gettime() < R.burnUntil then return true end
    if S.burnNamed then
        for _, x in ipairs(hostiles()) do if x.Named() then return true end end
    end
    if not alive(t) then return false end
    return (S.burnNamed and t.Named()) or (S.burnLevel and (t.Level() or 0) >= (mq.TLO.Me.Level() or 0))
        or (S.burnAdds and #hostiles() >= S.burnCount) or false
end

local function doBurn(t)
    if not burning(t) then return false end
    for _, a in ipairs(abilitiesFor('Burn')) do
        if not abilityUp(a) and not FIGHT.discBusy(a) and useAbility(a, nil, 'burn') then return true end
    end
    return false
end

-- out of combat: endurance discs below endPct, and long self buffs from abilities
local doEndurance, stowCursor
do   -- doMana stays out of the main chunk (LuaJIT allows it 200 locals)
-- a summoned item left on the cursor (a Modulation Shard or mod rod from a group summon, a pet weapon) goes into the
-- bags after 2s: with a full hand nothing can be memorized. Not while a trade, give, merchant or bank window is open;
-- a mage's folded pack is left to the pet weapons (it is unfolded from the cursor)
local STOWWND = { 'TradeWnd', 'GiveWnd', 'MerchantWnd', 'BigBankWnd' }
function stowCursor()
    local cur = mq.TLO.Cursor
    local name = cur.Name()
    if not name or name:find('^Folded Pack') or not (cur.NoRent() or name:find('^Summoned: ')) then R.cursorSeen = nil; return false end
    for _, w in ipairs(STOWWND) do if mq.TLO.Window(w).Open() then return false end end
    local now = mq.gettime()
    if not R.cursorSeen or R.cursorSeen.name ~= name then R.cursorSeen = { name = name, at = now }; return false end
    if now - R.cursorSeen.at < 2000 or now - (R.cursorAt or 0) < 10000 then return false end
    R.cursorAt = now
    mq.cmd('/autoinventory')
    mq.delay(1000, function() return not mq.TLO.Cursor() end)
    log(mq.TLO.Cursor() and 'no room in the bags for %s' or 'put %s in the bags', name)
    return true
end

-- one that costs health for mana (Cannibalization, Traumatic Exchange) leaves me above 20% HP after it (30% in a fight)
local function hpLeft(sp)
    if not sp or not sp() then return true end
    local cost = -math.min(0, FIGHT.spa(sp, 0))
    return cost == 0 or (mq.TLO.Me.CurrentHPs() or 0) - cost > (mq.TLO.Me.MaxHPs() or 0) * (#hostiles() > 0 and 0.3 or 0.2)
end

-- the group member (me too) lowest in mana (those who use it) or endurance, under a % and in range: a gift goes to whoever
-- needs it most. Its id, name and %
local NOMANACLS = { WAR = true, MNK = true, ROG = true, BER = true }
local function needy(what, below, range, notMe)
    local id, name, pct
    local function try(n, sid, p) if p < below and (not pct or p < pct) then id, name, pct = sid, n, p end end
    local me = mq.TLO.Me
    if not notMe and (what ~= 'mana' or (me.MaxMana() or 0) > 0) then
        try(me.CleanName(), myId(), what == 'mana' and mana() or (me.PctEndurance() or 100))
    end
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        if m.Present() and not m.OtherZone() and m.Type() ~= 'Corpse' and (m.Spawn.ID() or 0) > 0 and (m.Spawn.Distance3D() or 999) <= range
            and (what ~= 'mana' or not NOMANACLS[m.Class.ShortName() or '']) then
            try(m.Name() or '?', m.Spawn.ID() or 0, what == 'mana' and (m.PctMana() or 100) or (m.PctEndurance() or 100))
        end
    end
    return id, name, pct
end

-- a Mana ability for others goes where it's needed: a single-target one (Focused Paragon of Spirits) on
-- the group member lowest in mana under 80% (60% when its reuse is over 2 minutes), a group one (Paragon of Spirit) when
-- anyone is under 60%, one used on the mob in a fight when a caster is under 30% (a bard's Reflexive Rebuttal: its
-- recourse is the group's mana) or I am under the mana-tools % (Thought Leech). They went on me only: Nhambuko gave
-- herself 177 Focused Paragons while Pindaini sat at 52% mana holding the pulls, and Reflexive Rebuttal and Thought
-- Leech, aimed at their own casters, "did not fire" 107 and 18 times
-- a gift that costs my own mana only while I keep the mana-tools % after paying it: Rallying Call (25000 mana) on Seaeni
-- took Pindaini from 29% to 13% and the Hunter waited on her (12:31, 12:43)
local function canGive(sp)
    local cost, max = sp.Mana() or 0, mq.TLO.Me.MaxMana() or 0
    return cost == 0 or (max > 0 and ((mq.TLO.Me.CurrentMana() or 0) - cost) * 100 / max >= S.manaPct)
end
local function forOthers(sp)
    if not sp or not sp() then return nil end
    if sp.SpellType() == 'Detrimental' then return 'mob' end
    local tt = sp.TargetType() or ''
    return (tt == 'Single' and 'one') or (tt:find('^Group') and 'all') or nil
end
local function giveMana()
    -- while my group one is up (Paragon of Spirit) the single-target one waits: "Focused Paragon of Spirit is blocked by
    -- Paragon of Spirit" on Pindaini, 2026-10-18 07:50:29
    local groupUp = false
    for _, a in ipairs(abilitiesFor('Mana')) do
        local sp = abilitySpell(a)
        if forOthers(sp) == 'all' and FIGHT.buffOn(sp.Name()) then groupUp = true end
    end
    for _, a in ipairs(abilitiesFor('Mana')) do
        local sp = abilitySpell(a)
        local how = abilityReady(a) and forOthers(sp)
        if how == 'one' and groupUp then how = nil end
        if how == 'mob' then
            -- a caster under 30% only for one whose mana goes to the group ("restores mana to your group"): Thought Leech
            -- fills only me and went at 07:54:45 for Seaeni at 28%
            local t = spawn(R.targetId)
            local who, name, p
            if (sp.Description() or ''):lower():find('group') then who, name, p = needy('mana', 30, 500) end
            if not who and (mq.TLO.Me.MaxMana() or 0) > 0 and mana() < S.manaPct then who, name, p = myId(), mq.TLO.Me.CleanName(), mana() end
            if who and R.state == 'FIGHT' and alive(t) and useAbility(a, t.ID(), string.format('%s at %d%% mana', name, p)) then return true end
        elseif how then
            local reuse = a.kind == 'aa' and (mq.TLO.Me.AltAbility(a.name).ReuseTime() or 0) or 0
            local who, name, p = needy('mana', (how == 'one' and reuse <= 120) and 80 or 60,
                how == 'one' and (sp.Range() or 100) or math.max(50, sp.AERange() or 0))
            if who and (who == myId() or canGive(sp)) and hpLeft(sp)
                and useAbility(a, how == 'one' and who or nil, string.format('%s at %d%% mana', name, p)) then return true end
        end
    end
    return false
end

-- mana under the mana-tools % (default 50): a Modulation Shard from the bags (it trades health for mana: above 70% HP),
-- else a Mana ability of my own (Elemental Conversion, Cannibalization; Summon Modulation Shard only when no shard is in
-- the bags), else a Mana spell (Gather Zeal, Traumatic Exchange). The ones for others go first, wherever they're needed
local function doMana()
    if casting() or FIGHT.keepInvis() then return false end
    if giveMana() then return true end
    if (mq.TLO.Me.MaxMana() or 0) == 0 or mana() >= S.manaPct then return false end
    local shard = mq.TLO.FindItem('Modulation Shard')
    if shard() and hp() > 70 and (shard.TimerReady() or 0) == 0 and mq.gettime() - (R.shardAt or 0) > 3000 then
        R.shardAt = mq.gettime()
        mq.cmdf('/useitem "%s"', shard.Name())
        log('click %s (mana %d%%)', shard.Name(), mana())
        return true
    end
    local why = string.format('mana %d%%', mana())
    for _, a in ipairs(abilitiesFor('Mana')) do
        local sp = abilitySpell(a)
        if not forOthers(sp) and not (a.name:find('Modulation Shard') and shard()) and hpLeft(sp) and useAbility(a, nil, why) then return true end
    end
    for _, s in ipairs(list(S.manaSpells)) do
        if hpLeft(mq.TLO.Spell(s)) and castOn(s, myId(), why) then return true end
    end
    return false
end

-- out of combat: Endurance abilities. One for a single target (a bard's Rallying Call) goes to another
-- groupmate under 30% mana, else to whoever else is lowest in endurance under the endurance %; my own is the self one,
-- which is free (Rallying Call costs 25000 mana and endurance, Rallying Solo nothing). A self one goes under the
-- endurance %, or under 30% mana when it gives mana (Rallying Solo)
function doEndurance()
    if doMana() then return true end
    if #hostiles() > 0 then return false end
    local low = (mq.TLO.Me.PctEndurance() or 100) < S.endPct
    local lowMana = (mq.TLO.Me.MaxMana() or 0) > 0 and mana() < 30
    for _, a in ipairs(abilitiesFor('Endurance')) do
        local sp = abilitySpell(a)
        if sp and sp() and sp.TargetType() == 'Single' then
            if abilityReady(a) and canGive(sp) then
                local r = sp.Range() or 100
                local who, name, p = needy('mana', 30, r, true)
                local what = 'mana'
                if not who then who, name, p = needy('endurance', S.endPct, r, true); what = 'endurance' end
                if who and useAbility(a, who, string.format('%s at %d%% %s', name, p, what)) then return true end
            end
        elseif (low or (lowMana and sp and sp() and (sp.Description() or ''):lower():find('mana')))
            and not abilityUp(a) and useAbility(a, nil, low and 'endurance' or string.format('mana %d%%', mana())) then
            return true
        end
    end
    return false
end
end


local function doAbilityBuffs()
    if #hostiles() > 0 then return false end
    for _, a in ipairs(abilitiesFor('Buff')) do
        if not abilityUp(a) and useAbility(a, nil, 'buff') then return true end
    end
    return false
end

-- fight duties by class (heals always come first, in step): bards and enchanters CC then debuff, healers debuff
-- then CC, everyone else CC then debuff (a bard's songs come last, in fightTick)
local CCFIRST = { BRD = true, ENC = true }
local HEALER = { CLR = true, DRU = true, SHM = true }
-- Debuff duty, with a mezzer in the group (a bard or enchanter, or me on CC duty): the adds a mez is waiting on
-- (not my target or the tank's) get the resist debuff (malo / tash) first, from any state - mezzes are resisted far
-- less after it. A mezzed add only gets one that does no damage
local function doMalo()
    if not S.debuff then return false end
    local adds = hostiles()
    if #adds < 2 then return false end
    local mezzer = S.cc
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        if m.Present() and CCFIRST[m.Class.ShortName() or ''] then mezzer = true end
    end
    if not mezzer then return false end
    local tank = mq.TLO.Me.GroupAssistTarget.ID() or 0
    local dl = DEB.list()
    for _, x in ipairs(adds) do
        local xid = x.ID() or 0
        if xid ~= R.targetId and xid ~= tank and (x.PctHPs() or 0) > 40 and x.LineOfSight() and not DEB.has(x, dl, 'malo') then
            for _, e in ipairs(dl) do
                if e.kind == 'malo' and not (mezzed(x) and e.dmg) and DEB.on(x, e, 'malo for mez') then return true end
            end
        end
    end
    return false
end

local function doDuties(t)
    local cls = mq.TLO.Me.Class.ShortName() or ''
    if HEALER[cls] then return doDebuff(t) or doCC(t) end
    return doCC(t) or doDebuff(t)
end

-- a proc window first: under Gift of Mana (the next spell costs no mana) the most expensive ready DoT
-- or nuke, at any mana; under a twincast (Twincast, Improved Twincast, Bifold Focus) the most expensive one above its
-- mana %. The list order spent the free or doubled spell on whatever came first.
-- With a twincast order set (Twincast nukes; Improved Twincast nukes while that one is on) the first ready one of it
-- instead, and no other nuke until the twincast ends (returns false, true): a bolt would spend the doubled cast. Zenban
-- cast Spear under a twincast 211 times of 389 and Bolt 22
function FIGHT.procSpell(t)
    local gift = FIGHT.buffOn('Gift of Mana, Gift of Radiant Mana, Gift of Exquisite Radiant Mana')
    if not gift and not FIGHT.buffOn('Twincast, Improved Twincast, Bifold Focus') then return false end
    if not gift and S.nuke then
        local order = FIGHT.buffOn('Improved Twincast') and S.itNukes ~= '' and S.itNukes or S.twincastNukes
        if order ~= '' then
            for _, n in ipairs(list(order)) do
                if (mana() >= S.nukeManaMin or FIGHT.tap(n)) and castOn(n, t.ID(), 'nuke, twincast') then return true end
            end
            return false, true
        end
    end
    local best, cost, dot = nil, -1, false
    local function consider(name, isDot, floor)
        if not gift and mana() < floor and not FIGHT.tap(name) then return end
        local m = mq.TLO.Spell(name).Mana() or 0
        if m > cost and spellReady(name) and not (isDot and onMob(t, name)) then best, cost, dot = name, m, isDot end
    end
    if S.dot and (t.PctHPs() or 0) > (t.Named() and 5 or 40) then for _, d in ipairs(list(S.dots)) do consider(d, true, S.dotManaMin) end end
    if S.nuke then for _, n in ipairs(list(S.nukes)) do consider(n, false, S.nukeManaMin) end end
    if not best then return false end
    local why = gift and 'gift of mana' or 'twincast'
    if dot then return castOnMob(best, t, 'dot, ' .. why) end
    return castOn(best, t.ID(), 'nuke, ' .. why)
end

local function doDps(t)
    -- both roles use DPS abilities + nukes; Tank-only abilities/stuns are handled in doTank
    if not alive(t) then return false end
    local proc, hold = FIGHT.procSpell(t)
    if proc then return true end
    -- spells first when one is ready (DoTs once per mob, then nukes); the instant abilities fill the gaps between
    -- casts. Abilities first starved the spells: one with no reuse timer is ready again every few seconds.
    -- A beastlord's abilities go first (Wallop, Bestial Fierceness, Chameleon Strike, then the spells; its
    -- Eagle Strike and Round Kick mostly go off by the game's auto-skill, so they read not ready in a fight)
    local first = mq.TLO.Me.Class.ShortName() == 'BST'
    if first then
        for _, a in ipairs(abilitiesFor('DPS')) do if not FIGHT.discBusy(a) and useAbility(a, t.ID(), 'dps') then return true end end
    end
    -- under Nuke above mana % only the lifetaps go on (they heal), under DoTs above mana % only the lifetap DoTs; a named
    -- gets its DoTs down to 5%
    local nukeOk, dotOk = mana() >= S.nukeManaMin, mana() >= S.dotManaMin
    if S.dot and (t.PctHPs() or 0) > (t.Named() and 5 or 40) then
        for _, d in ipairs(list(S.dots)) do if (dotOk or FIGHT.tap(d)) and not onMob(t, d) and castOnMob(d, t, 'dot') then return true end end
    end
    if S.nuke and not hold then
        for _, n in ipairs(list(S.nukes)) do if (nukeOk or FIGHT.tap(n)) and castOn(n, t.ID(), 'nuke') then return true end end
    end
    if not first then
        for _, a in ipairs(abilitiesFor('DPS')) do if not FIGHT.discBusy(a) and useAbility(a, t.ID(), 'dps') then return true end end
    end
    return false
end

-- swap the lowest-level memorized spell that has a better scribed version of the same kind
-- (same category, subcategory and target type, at or below my level)
local function upgradeGems()
    if not S.autoMem or mq.gettime() - R.lastMemCheck < 60000 then return false end
    R.lastMemCheck = mq.gettime()
    local lvl, book, mem, gems, timers, mine = mq.TLO.Me.Level() or 0, {}, {}, {}, {}, {}
    -- a spell in a list you set yourself stays memorized
    for k in pairs(S.userLists) do if type(S[k]) == 'string' then for _, n in ipairs(list(S[k])) do mine[n] = true end end end
    for i = 1, (mq.TLO.Me.NumGems() or 8) do
        local s = mq.TLO.Me.Gem(i)
        if s() then
            local tm = s.RecastTimerID() or 0
            mem[s.Name()], timers[tm] = true, (timers[tm] or 0) + 1
            if not mine[s.Name()] then table.insert(gems, { g = i, s = s, lvl = s.Level() or 0, timer = tm }) end
        end
    end
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        if b() and not mem[b.Name()] and (b.Level() or 0) <= lvl then
            table.insert(book, { name = b.Name(), lvl = b.Level() or 0, cat = b.Category(), sub = b.Subcategory(), tt = b.TargetType(),
                timer = b.RecastTimerID() or 0 })
        end
    end
    table.sort(gems, function(a, b) return a.lvl < b.lvl end)
    for _, m in ipairs(gems) do
        local cat, sub, tt, best = m.s.Category(), m.s.Subcategory(), m.s.TargetType(), nil
        for _, b in ipairs(book) do
            -- never another rank of a line memorized in another gem (ranks share a recast timer): Focused Whirlwind of
            -- Arrows went in over Ecliptic Fusillade next to Focused Frenzy of Arrows
            local otherRank = b.timer > 0 and (timers[b.timer] or 0) - (m.timer == b.timer and 1 or 0) > 0
            if b.lvl > m.lvl and b.cat == cat and b.sub == sub and b.tt == tt and not otherRank and (not best or b.lvl > best.lvl) then best = b end
        end
        if best then
            log('memorizing %s (L%d) over %s (L%d) in gem %d', best.name, best.lvl, m.s.Name(), m.lvl, m.g)
            mq.cmdf('/memspell %d "%s"', m.g, best.name)
            mq.delay(20000, function() return mq.TLO.Me.Gem(m.g).Name() == best.name or not quiet() end)
            R.lastMemCheck = 0   -- look at the next gem right away
            return true
        end
    end
    return false
end

-- keep the (Nuke duty) best plain nuke and undead nuke, (CC duty) single-target mez and (Debuff duty) slow, malo and cripple from the book memorized,
-- in an empty gem or over the lowest self-buff gem (those buffs still get cast by borrowing a gem).
-- Checked on start, level-up and when Nuke, Debuff or CC is toggled
local function nukeKind(s)
    if s.SpellType() == 'Beneficial' then return nil end
    local sub, tt = s.Subcategory() or '', s.TargetType() or ''
    if S.nuke and s.Category() == 'Direct Damage' and not sub:find('Stun') then
        if tt == 'Undead' then return 'undead' end
        if tt == 'Single' then return 'nuke' end
    end
    if S.debuff and DEBUFFSUB[sub] and tt == 'Single' then return sub end
    if S.cc and sub == 'Enthrall' and tt == 'Single' then return 'Enthrall' end
    if S.cc and sub == 'Enthrall' and (tt == 'PB AE' or tt == 'Targeted AE') then return 'EnthrallAE' end
end

local function memNukes()
    local lvl = mq.TLO.Me.Level() or 0
    if not S.autoMem or (R.nukeLevel == lvl and R.nukeDebuff == S.debuff and R.nukeCC == S.cc and R.nukeNuke == S.nuke) then return false end
    local nukeGems = {}
    local have, isBuff, buffGems, best = {}, {}, {}, {}
    for _, b in ipairs(list(S.buffs)) do isBuff[b] = true end
    for i = 1, (mq.TLO.Me.NumGems() or 8) do
        local s = mq.TLO.Me.Gem(i)
        if s() then
            local k = nukeKind(s)
            if k then
                if trained(s) then have[k] = true else table.insert(buffGems, { g = i, lvl = -1, name = s.Name() }) end
                if k == 'nuke' then table.insert(nukeGems, { g = i, lvl = s.Level() or 0, name = s.Name() }) end
            end
            if isBuff[s.Name()] then table.insert(buffGems, { g = i, lvl = s.Level() or 0, name = s.Name() }) end
            -- a nuke whose duty is off (and that isn't the Hunter's pull spell) holds a free gem
            if not S.nuke and not k and s.SpellType() ~= 'Beneficial' and s.Category() == 'Direct Damage'
                and not (s.Subcategory() or ''):find('Stun') and not (S.mode == 'Hunter' and s.Name() == S.pullSpell) then
                table.insert(buffGems, { g = i, lvl = s.Level() or 0, name = s.Name() })
            end
        else
            table.insert(buffGems, { g = i, lvl = -1, name = '' })   -- empty gems first
        end
    end
    -- kinds already covered: a Debuff ability of that kind (Sha's Reprisal slows), or a list you set yourself
    for _, e in ipairs(DEB.list()) do
        if e.abil then have[({ malo = 'Resist Debuffs', slow = 'Slow', cripple = 'Disempowering' })[e.kind] or e.kind] = true end
    end
    if S.userLists.debuffs then have.Slow, have['Resist Debuffs'], have.Disempowering = true, true, true end
    if S.userLists.nukes then have.nuke, have.undead = true, true end
    if S.userLists.mez then have.Enthrall, have.EnthrallAE = true, true end
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        -- under half my level isn't worth a gem (a beastlord memorized the L56 Incapacitate)
        local k = b() and (b.Level() or 0) <= lvl and (b.Level() or 0) >= math.floor(lvl / 2) and trained(b) and nukeKind(b)
        if k and not have[k] and not blocked(b.Name()) and (not best[k] or b.Level() > best[k].lvl) then best[k] = { name = b.Name(), lvl = b.Level() or 0 } end
    end
    table.sort(buffGems, function(a, b) return a.lvl < b.lvl end)
    table.sort(nukeGems, function(a, b) return a.lvl < b.lvl end)
    for _, k in ipairs({ 'Enthrall', 'EnthrallAE', 'Slow', 'Resist Debuffs', 'Disempowering', 'undead', 'nuke' }) do
        local n = best[k]
        -- a mez may take the lowest nuke's gem when nothing else is free (bards have no spare gems)
        local m = buffGems[1] or (k == 'Enthrall' and #nukeGems > 1 and nukeGems[1]) or nil
        if n and m then
            log('memorizing %s (L%d, %s) in gem %d%s', n.name, n.lvl, k, m.g, m.name ~= '' and (' over ' .. m.name) or '')
            mq.cmdf('/memspell %d "%s"', m.g, n.name)
            mq.delay(20000, function() return mq.TLO.Me.Gem(m.g).Name() == n.name or not quiet() end)
            if mq.TLO.Me.Gem(m.g).Name() ~= n.name and #hostiles() == 0 then backoff(n.name, 'memorize', 600000) end
            return true
        end
    end
    R.nukeLevel, R.nukeDebuff, R.nukeCC, R.nukeNuke = lvl, S.debuff, S.cc, S.nuke
    return false
end

local function usedSpells()
    local used = {}
    for _, k in ipairs({ 'healSpells', 'stuns', 'ccStuns', 'nukes', 'dots', 'debuffs', 'mez', 'buffs', 'combatBuffs', 'songs', 'restSongs' }) do
        for _, n in ipairs(list(S[k])) do used[n] = true end
    end
    for _, n in ipairs({ S.petSpell, S.pullSpell }) do used[n] = true end
    return used
end

-- healers (Heal duty on): keep the two best single-target direct heals and the two best heals-over-time (not
-- self-only wards) from the book memorized, each from a different line (a shared recast timer, or the same kind,
-- target, recast and cast time). The gem taken: an empty one, a spell too untrained to cast, a nuke / DoT whose duty
-- is off, a self buff (those get cast by borrowing a gem), a leftover under half my level nothing uses, and only
-- then a nuke. Checked on start and level-up
local function memHeals()
    local lvl = mq.TLO.Me.Level() or 0
    if not S.autoMem or not S.heal or S.userLists.healSpells or not HEALER[mq.TLO.Me.Class.ShortName() or ''] or R.healMemLevel == lvl then return false end
    local direct, hot = {}, {}
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        if b() and (b.Level() or 0) <= lvl and b.Category() == 'Heals' and b.SpellType() == 'Beneficial' and not blocked(b.Name()) and trained(b) then
            local sub, tt, timer = b.Subcategory() or '', b.TargetType() or '', b.RecastTimerID() or 0
            local e = { name = b.Name(), lvl = b.Level() or 0, line = timer > 0 and ('t' .. timer)
                or string.format('%s|%s|%d|%d', sub, tt, b.RecastTime() or 0, math.floor((b.MyCastTime() or 0) / 500)) }
            if sub == 'Duration Heals' and tt ~= 'Self' then table.insert(hot, e)
            elseif (sub == 'Heals' or sub == 'Quick Heal') and tt == 'Single' then table.insert(direct, e) end
        end
    end
    local want, wantSet = {}, {}
    for _, l in ipairs({ direct, hot }) do
        table.sort(l, function(a, b) return a.lvl > b.lvl end)
        local seen, n = {}, 0
        for _, e in ipairs(l) do
            if n < 2 and not seen[e.line] then seen[e.line] = true; n = n + 1; table.insert(want, e.name); wantSet[e.name] = true end
        end
    end
    local missing
    for _, n in ipairs(want) do if not mq.TLO.Me.Gem(n)() then missing = n; break end end
    if not missing then R.healMemLevel = lvl; return false end
    local used, isBuff, isNuke, isDot = usedSpells(), {}, {}, {}
    for _, n in ipairs(list(S.buffs)) do isBuff[n] = true end
    for _, n in ipairs(list(S.nukes)) do isNuke[n] = true end
    for _, n in ipairs(list(S.dots)) do isDot[n] = true end
    local slot, slotPrio
    for i = 1, (mq.TLO.Me.NumGems() or 8) do
        local g = mq.TLO.Me.Gem(i)
        local n = g() and g.Name() or ''
        local prio
        if n == '' then prio = 0
        elseif wantSet[n] or (S.mode == 'Hunter' and n == S.pullSpell) then prio = nil
        elseif not trained(g) then prio = 1
        elseif (isNuke[n] and not S.nuke) or (isDot[n] and not S.dot) then prio = 2
        elseif isBuff[n] then prio = 3
        elseif not used[n] and (g.Level() or 0) < lvl / 2 then prio = 4
        elseif isNuke[n] then prio = 5 end
        if prio and (not slotPrio or prio < slotPrio) then slot, slotPrio = i, prio end
    end
    if not slot then log('no gem to spare for %s', missing); R.healMemLevel = lvl; return false end
    local over = mq.TLO.Me.Gem(slot).Name()
    log('memorizing %s (heal) in gem %d%s', missing, slot, over and (' over ' .. over) or '')
    mq.cmdf('/memspell %d "%s"', slot, missing)
    mq.delay(20000, function() return mq.TLO.Me.Gem(slot).Name() == missing or not quiet() end)
    if mq.TLO.Me.Gem(slot).Name() ~= missing and quiet() then backoff(missing, 'memorize', 600000) end
    return true
end

local function memRestSongs()
    local lvl = mq.TLO.Me.Level() or 0
    if not S.autoMem or mq.TLO.Me.Class.ShortName() ~= 'BRD' or R.restSongLevel == lvl then return false end
    R.restSongLevel = lvl
    local best
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        if b() and (b.Level() or 0) <= lvl and REGENSONG(b) and b.TargetType() ~= 'Self' and (not best or b.Level() > best.lvl) then
            best = { name = b.Name(), lvl = b.Level() or 0 }
        end
    end
    if not best or mq.TLO.Me.Gem(best.name)() then return false end
    local used = usedSpells()
    for i = 1, (mq.TLO.Me.NumGems() or 8) do
        local g = mq.TLO.Me.Gem(i)
        if not g() or not used[g.Name()] then
            log('memorizing %s (L%d, rest song) in gem %d%s', best.name, best.lvl, i, g() and (' over ' .. g.Name()) or '')
            mq.cmdf('/memspell %d "%s"', i, best.name)
            mq.delay(20000, function() return mq.TLO.Me.Gem(i).Name() == best.name or not quiet() end)
            return true
        end
    end
    log('no free gem for rest song %s', best.name)
    return false
end

-- self buffs, best first: cast whatever is missing and would stack. A buff that isn't memorized
-- borrows a gem (an empty one, else the last), which gets its spell back once everything is up
local function restoreGem()
    local s = R.swapGem
    if not s then return false end
    if s.name == '' or mq.TLO.Me.Gem(s.g).Name() == s.name then R.swapGem = nil; return false end
    log('putting %s back in gem %d', s.name, s.g)
    if mq.TLO.Cursor() then mq.cmd('/autoinventory'); mq.delay(1000, function() return not mq.TLO.Cursor() end) end   -- a full hand can't open the book
    mq.cmdf('/memspell %d "%s"', s.g, s.name)
    mq.delay(20000, function() return mq.TLO.Me.Gem(s.g).Name() == s.name or not quiet() end)
    if mq.TLO.Me.Gem(s.g).Name() == s.name then R.swapGem = nil end
    return true
end

-- cast buff b on id (group spells on myself), memorizing it into a borrowed gem first if needed.
-- true when it did something; the same buff on the same target is retried after a minute at most
local function tryBuff(b, id, why)
    local key = id .. '|' .. b
    if blocked(b) or mq.gettime() - (R.buffTry[key] or 0) < 60000 or FIGHT.noReagent(mq.TLO.Spell(b)) then return false end
    if spellReady(b) then
        R.buffTry[key] = mq.gettime()
        local tt = mq.TLO.Spell(b).TargetType() or ''
        castOn(b, tt:find('^Group') and myId() or id, why)
        return true
    end
    local swap = R.swapGem
    if swap and mq.TLO.Me.Gem(swap.g).Name() == b then
        if mq.gettime() - (swap.at or 0) < 15000 then return true end   -- gem still refreshing
        backoff(b, 'not ready after memorizing', 120000)
    elseif not mq.TLO.Me.Gem(b)() and S.memBuffs and mq.TLO.Me.Book(b)() and quiet() then
        if not swap then
            local g = mq.TLO.Me.NumGems() or 8
            for i = 1, g do if not mq.TLO.Me.Gem(i)() then g = i; break end end
            swap = { g = g, name = mq.TLO.Me.Gem(g).Name() or '' }
            R.swapGem = swap
        end
        log('memorizing %s in gem %d to buff', b, swap.g)
        if mq.TLO.Cursor() then mq.cmd('/autoinventory'); mq.delay(1000, function() return not mq.TLO.Cursor() end) end   -- a full hand can't open the book
        mq.cmdf('/memspell %d "%s"', swap.g, b)
        mq.delay(20000, function() return mq.TLO.Me.Gem(swap.g).Name() == b or not quiet() end)
        swap.at = mq.gettime()
        if mq.TLO.Me.Gem(swap.g).Name() ~= b then backoff(b, 'memorize', 60000) end
        return true
    end
    return false
end

local function doBuffs()
    if FIGHT.keepInvis() or casting() then return false end   -- (a bard's song playing: a buff or memorize would cut it)
    if (mq.TLO.Me.Level() or 0) ~= R.buffLevel then refreshBuffs() end
    local buffs = list(S.buffs)
    local function usable(b)
        local sp = mq.TLO.Spell(b)
        return sp() and not blocked(b) and (mq.TLO.Me.CurrentMana() or 0) >= (sp.Mana() or 0)
    end
    local cls = mq.TLO.Me.Class.ShortName() or ''
    for _, b in ipairs(buffs) do
        if usable(b) and wantsBuff(cls, buffWho(b), not ranged()) and not hasBuff(b) and buffStacks(b, false) then
            if tryBuff(b, myId(), 'buff') then return true end
        end
    end
    -- Buff duty: group members in range, each looked at once a minute
    if S.buff then
        for i = 1, (mq.TLO.Group.Members() or 0) do
            local m = mq.TLO.Group.Member(i)
            local id = m.ID() or 0
            if id > 0 and m.Present() and not m.OtherZone() and m.Type() ~= 'Corpse' and (m.Distance() or 999) < 100 and m.LineOfSight()
                and mq.gettime() - (R.buffChecked[id] or 0) > 30000 then
                local mcls, want = m.Class.ShortName() or '', {}
                for _, b in ipairs(buffs) do
                    if usable(b) and mq.TLO.Spell(b).TargetType() ~= 'Self' and wantsBuff(mcls, buffWho(b), false) then table.insert(want, b) end
                end
                if #want > 0 and targetId(id) then
                    mq.delay(1500, function() return mq.TLO.Target.BuffsPopulated() end)
                    for _, b in ipairs(want) do
                        if not hasBuff(b, mq.TLO.Target) and buffStacks(b, true) and tryBuff(b, id, 'buff ' .. (m.CleanName() or id)) then return true end
                    end
                end
                R.buffChecked[id] = mq.gettime()
            end
        end
    end
    return restoreGem()
end

-- chase loot (chaseloot.lua: Night of Shadows' Blood-soaked items, Deepshade named gear): rare drops worth keeping. Out of a fight, every 3s, from the Advanced Loot
-- window: my own personal chase drops are looted, and the group leader gives the shared ones to himself. Nothing else
-- is touched. An item is tried once a minute (a lore one I already carry would otherwise be retried in a loop)
do
local CHASE, chaseAt, tried = nil, 0, {}
local function isChase(name)
    -- read again every minute: edits to chaseloot.lua apply without a reload (a broken edit keeps the last good list)
    if not CHASE or mq.gettime() - chaseAt > 60000 then
        chaseAt = mq.gettime()
        local ok, t = pcall(dofile, mq.luaDir .. '/autoxp/chaseloot.lua')
        if ok and type(t) == 'table' then CHASE = t
        else
            log('chase loot list failed to load: %s', tostring(t))
            CHASE = CHASE or { patterns = {}, named = {}, never = {} }
        end
    end
    local l = name:lower()
    if CHASE.never[l] then return false end
    if CHASE.named[l] then return true end
    for _, p in ipairs(CHASE.patterns) do if l:find(p) then return true end end
    return false
end
function FIGHT.chaseLoot()
    if not S.chaseLoot or mq.gettime() - (R.lootAt or 0) < 3000 or casting() or #hostiles() > 0 then return false end
    R.lootAt = mq.gettime()
    local al, now = mq.TLO.AdvLoot, mq.gettime()
    if al.LootInProgress() then return false end
    for i = 1, (al.PCount() or 0) do
        local n = al.PList(i).Name()
        if n and now - (tried['p' .. n] or 0) > 60000 and isChase(n) then
            tried['p' .. n] = now
            mq.cmdf('/advloot personal %d loot', i)
            log('chase loot: %s', n)
            return true
        end
    end
    if mq.TLO.Group.Leader.Name() ~= ME then return false end   -- the leader hands out the shared loot
    for i = 1, (al.SCount() or 0) do
        local n = al.SList(i).Name()
        if n and now - (tried['s' .. n] or 0) > 60000 and isChase(n) then
            tried['s' .. n] = now
            mq.cmdf('/advloot shared %d giveto %s', i, ME)
            log('chase loot: %s (shared, to me)', n)
            return true
        end
    end
    return false
end
end

-- pet classes: summon the best pet in the book (mages: water first) and keep the best pet buff of each line
-- on it (haste, misc, block: 10 min+). A gem is borrowed for any that isn't memorized
local petBook, doPetCare
do   -- its tables stay out of the main chunk (LuaJIT allows it 200 locals)
local PETORDER = { MAG = { 'Sum: Water', 'Sum: Earth', 'Sum: Fire', 'Sum: Air' } }
local NOTPET = { ['Sum: Swarm'] = true, ['Sum: Familiar'] = true, ['Sum: Bodyguard'] = true }
local PETBUFF = { ['Pet Haste'] = true, ['Pet Misc Buffs'] = true, Block = true }
-- shrinks my pet: a pet-target pet shrink (SPA 298, Diminutive Companion) or a single-target shrink (SPA 89 under 100%,
-- Shrink); no duration, so never an illusion
local function shrinks(sp)
    local tt = sp.TargetType() or ''
    if (tt ~= 'Pet' and tt ~= 'Single') or (sp.Duration.TotalSeconds() or 0) > 0 or not (sp.SpellType() or ''):find('^Beneficial') then return false end
    if sp.HasSPA(298)() then return true end
    for i = 1, (sp.NumEffects() or 0) do
        if sp.Attrib(i)() == 89 then return (sp.Base(i)() or 100) < 100 end
    end
    return false
end
function petBook()
    local lvl = mq.TLO.Me.Level() or 0
    if R.petBook and R.petBook.lvl == lvl then return R.petBook end
    local pb, sum, buffs = { lvl = lvl, buffs = {} }, {}, {}
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        if b() and (b.Level() or 0) <= lvl and b.Category() == 'Create Item' and b.Subcategory() == 'Summon Weapon'
            and (b.Name() or ''):find('^Grant') and b.TargetType() == 'Single' then
            if not pb.weapon or (b.Level() or 0) > pb.weaponLvl then pb.weapon, pb.weaponLvl = b.Name(), b.Level() or 0 end
        elseif b() and (b.Level() or 0) <= lvl and (b.HasSPA(298)() or b.HasSPA(89)()) and shrinks(b) then
            if not pb.shrink or (b.Level() or 0) > pb.shrinkLvl then pb.shrink, pb.shrinkLvl = b.Name(), b.Level() or 0 end
        elseif b() and (b.Level() or 0) <= lvl and b.Category() == 'Pet' then
            local sub, tt, l = b.Subcategory() or '', b.TargetType() or '', b.Level() or 0
            if sub:find('^Sum:') and not NOTPET[sub] and tt == 'Self' then
                if not sum[sub] or l > sum[sub].lvl then sum[sub] = { name = b.Name(), lvl = l } end
            elseif PETBUFF[sub] and tt == 'Pet' and b.SpellType() == 'Beneficial' and (b.Duration.TotalSeconds() or 0) >= 600 then
                if not buffs[sub] or l > buffs[sub].lvl then buffs[sub] = { name = b.Name(), lvl = l } end
            end
        end
    end
    for _, sub in ipairs(PETORDER[mq.TLO.Me.Class.ShortName() or ''] or {}) do
        if sum[sub] then pb.summon = sum[sub].name; break end
    end
    if not pb.summon then
        local best
        for _, s in pairs(sum) do if not best or s.lvl > best.lvl then best = s end end
        pb.summon = best and best.name
    end
    for _, s in pairs(buffs) do table.insert(pb.buffs, s.name) end
    R.petBook = pb
    if pb.summon then log('pet: %s%s', pb.summon, #pb.buffs > 0 and (', buffs ' .. table.concat(pb.buffs, ', ')) or '') end
    return pb
end

-- shrink my pet, again while each one makes it smaller (down to the smallest the game allows), once per pet: a new pet,
-- or the same one after zoning, has a new spawn id. An ability first (Diminutive Companion, a shaman's or beastlord's
-- Shrink; one switched OFF in the Abilities tab isn't used), else the book's spell (Shrink)
local function shrinkPet(pet)
    local sh = R.petShrink
    if not sh or sh.id ~= pet.ID() then sh = { id = pet.ID(), n = 0, at = 0 }; R.petShrink = sh end
    if sh.done or casting() or mq.gettime() < sh.at or (pet.Distance3D() or 999) > 100 then return false end
    local h = pet.Height() or 0
    if sh.h and (h > sh.h - 0.05 or sh.n >= 8) then
        sh.done = true
        if sh.n > 1 then log('pet shrunk to %.2f', h) end
        return false
    end
    local why = string.format('shrink pet, height %.2f', h)
    local function used(wait) sh.h, sh.n, sh.at = h, sh.n + 1, mq.gettime() + wait; return true end
    local have = false
    for _, a in ipairs(S.abilities) do
        local sp = a.kind == 'aa' and a.enabled ~= false and abilitySpell(a)
        if sp and sp() and shrinks(sp) then
            have = true
            if useAbility(a, sp.TargetType() == 'Single' and pet.ID() or nil, why) then return used(2000) end
        end
    end
    local b = not have and petBook().shrink
    if not b then return false end
    if spellReady(b) then
        return castOn(b, pet.ID(), why) and used(2000 + (mq.TLO.Spell(b).MyCastTime() or 0))
    end
    return tryBuff(b, pet.ID(), why)   -- memorizes it
end

function doPetCare()
    if not S.usePet or FIGHT.keepInvis() then return false end
    local pb = petBook()
    local pet = mq.TLO.Me.Pet
    if (pet.ID() or 0) == 0 then
        -- the Pet summon setting when it names a real pet, else the book's best
        local sp = S.petSpell ~= '' and not NOTPET[mq.TLO.Spell(S.petSpell).Subcategory() or ''] and S.petSpell or pb.summon
        return sp ~= nil and sp ~= '' and tryBuff(sp, myId(), 'summon pet')
    end
    for _, b in ipairs(pb.buffs) do
        if not blocked(b) and not mq.TLO.Pet.Buff(b)() and mq.TLO.Spell(b).StacksPet() and tryBuff(b, pet.ID(), 'pet buff') then return true end
    end
    return S.shrinkPet and shrinkPet(pet) or false
end
end

-- mages: two summoned weapons for every unarmed pet in the group (mine and group members'). The grant, cast on me,
-- gives a folded pack (one left in the bags is used first): it unfolds from a top-level slot into a pouch of weapons,
-- handed out best first. The pouch is destroyed once it's empty (leftover weapons wait for the next pet)
local doPetWeapons, petsToArm
do   -- its helpers stay out of the main chunk (LuaJIT allows it 200 locals)
local WEAPONPREF = { 'Fireblade', 'Iceblade', 'Ragesword', 'Rageblade', 'Mindblade', 'Shortsword' }
local function petWeapons()
    local found = {}
    for i = 23, 34 do
        local b = mq.TLO.Me.Inventory(i)
        for j = 1, (b() and b.Container() or 0) do
            local n = b.Item(j)() and b.Item(j).Name() or ''
            if n:find('^Summoned: ') then
                local rank, t = nil, b.Item(j).Type() or ''
                for k, w in ipairs(WEAPONPREF) do if n:find(w) then rank = k; break end end
                -- any other summoned weapon comes last (a grant's weapon names change with its rank)
                if not rank and (t:find('^[12]H') or t == 'Piercing' or t == 'Hand to Hand') then rank = #WEAPONPREF + 1 end
                if rank then table.insert(found, { name = n, rank = rank }) end
            end
        end
    end
    table.sort(found, function(a, b) return a.rank < b.rank end)
    return found
end

local function unarmedPets()
    local out = {}
    local function add(pt)
        if pt() and (pt.ID() or 0) > 0 and (pt.Primary() or 0) == 0 and (pt.Distance3D() or 999) < 100 and pt.LineOfSight()
            and mq.gettime() - (R.armFail[pt.ID()] or -600000) > 600000 then table.insert(out, pt) end
    end
    add(mq.TLO.Me.Pet)
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        if m.Present() and not m.OtherZone() then add(m.Pet) end
    end
    return out
end

-- the weapon pouch: a temporary top-level bag named like one a folded pack unfolded into (names are learned),
-- holding nothing but summoned items
local function weaponPouch()
    local names = {}
    for _, n in ipairs(list(S.pouchNames)) do names[n] = true end
    for i = 23, 32 do
        local b = mq.TLO.Me.Inventory(i)
        if b() and names[b.Name() or ''] and b.NoRent() and (b.Container() or 0) > 0 then
            local only = true
            for j = 1, b.Container() do
                if b.Item(j)() and not (b.Item(j).Name() or ''):find('^Summoned: ') then only = false end
            end
            if only then return i, b end
        end
    end
end

-- a mage notices an unarmed pet while idle (checked every 5s), not only after a fight
function petsToArm()
    if mq.TLO.Me.Class.ShortName() ~= 'MAG' or not S.usePet or mq.gettime() - R.armCheck < 5000 or FIGHT.keepInvis() then return false end
    R.armCheck = mq.gettime()
    return quiet() and #unarmedPets() > 0
end

-- destroy the cursor item only if it's what we expect (a summoned weapon, or the pouch we unfolded)
local function destroyIf(ok)
    local n = mq.TLO.Cursor.Name() or ''
    if n ~= '' and ok(n) then mq.cmd('/destroy'); mq.delay(1500, function() return not mq.TLO.Cursor() end); return true end
    if mq.TLO.Cursor() then mq.cmd('/autoinventory'); mq.delay(1000) end
    return false
end

function doPetWeapons()
    if mq.TLO.Me.Class.ShortName() ~= 'MAG' or not S.usePet or not quiet() or FIGHT.keepInvis() then return false end
    local cur = mq.TLO.Cursor.Name()
    if cur then
        if cur:find('^Folded Pack') then
            -- unfolding only works from a top-level inventory slot
            local slot
            for i = 23, 32 do if not mq.TLO.Me.Inventory(i)() then slot = i; break end end
            if not slot then
                log('no free top-level inventory slot to unfold %s', cur); mq.cmd('/autoinventory')
                if petBook().weapon then backoff(petBook().weapon, 'no free top-level slot', 600000) end
                return true
            end
            mq.cmdf('/itemnotify pack%d leftmouseup', slot - 22)
            mq.delay(2000, function() return not mq.TLO.Cursor() end)
            mq.cmdf('/itemnotify pack%d rightmouseup', slot - 22)
            mq.delay(1500, casting)
            mq.delay(15000, function() return not casting() end)
            return true
        end
        if (mq.TLO.Cursor.Container() or 0) > 0 then   -- the unfolded pouch
            if not (', ' .. S.pouchNames .. ','):find(', ' .. cur .. ',', 1, true) then S.pouchNames = S.pouchNames .. ', ' .. cur end
            mq.cmd('/autoinventory'); return true
        end
        if cur:find('^Summoned: ') then mq.cmd('/autoinventory'); return true end
        return false
    end
    local pets, weapons = unarmedPets(), petWeapons()
    local ps, pouch = weaponPouch()
    -- an empty pouch goes right away
    if ps and (pouch.Items() or 0) == 0 then
        local name = pouch.Name()
        mq.cmdf('/itemnotify pack%d leftmouseup', ps - 22)
        mq.delay(2000, function() return mq.TLO.Cursor() ~= nil end)
        if destroyIf(function(n) return n == name end) then log('pouch empty - destroyed %s', name) end
        return true
    end
    if #pets == 0 then return false end
    if #weapons < 2 then
        local g = petBook().weapon
        if not g or blocked(g) then return false end
        local slot
        for i = 23, 32 do if not mq.TLO.Me.Inventory(i)() then slot = i; break end end
        if not slot then
            log('no free top-level inventory slot to unfold the pet weapons'); backoff(g, 'no free top-level slot', 600000)
            return false
        end
        -- a folded pack from an earlier grant before casting another
        local pack = g:gsub('^Grant ', 'Folded Pack of ')
        if mq.TLO.FindItem('=' .. pack)() then
            mq.cmdf('/itemnotify "%s" leftmouseup', pack)
            mq.delay(2000, function() return mq.TLO.Cursor.Name() == pack end)
            return true
        end
        return tryBuff(g, myId(), 'pet weapons')
    end
    local pt = pets[1]
    if (pt.Distance3D() or 999) > 15 then
        if not mq.TLO.Navigation.Active() then mq.cmdf('/nav id %d distance=8', pt.ID()) end
        return true
    end
    if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
    if not targetId(pt.ID()) then return false end
    -- two different weapons, best first
    local pick = { weapons[1].name }
    for k = 2, #weapons do if weapons[k].name ~= pick[1] then pick[2] = weapons[k].name; break end end
    pick[2] = pick[2] or weapons[2].name
    local given = {}
    for _, w in ipairs(pick) do
        mq.cmdf('/itemnotify "%s" leftmouseup', w)
        mq.delay(2000, function() return mq.TLO.Cursor.Name() == w end)
        if mq.TLO.Cursor.Name() == w then
            mq.cmd('/click left target')
            mq.delay(2000, function() return not mq.TLO.Cursor() end)
            table.insert(given, w)
        end
    end
    if mq.TLO.Window('GiveWnd').Open() then
        mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
        mq.delay(3000, function() return not mq.TLO.Window('GiveWnd').Open() end)
    end
    mq.delay(1500)
    if mq.TLO.Cursor() then mq.cmd('/autoinventory') end
    if (pt.Primary() or 0) == 0 then
        R.armFail[pt.ID()] = mq.gettime(); log('%s did not take the weapons - trying again in 10 min', pt.CleanName() or '?')
    else
        log('armed %s with %s', pt.CleanName() or '?', table.concat(given, ' + '))
    end
    return true
end
end

-- Rez duty: resurrect group members' corpses, and out of combat my own. In a fight only Call of the Wild, on someone
-- still dead (back with no exp; an exp rez still works later). Out of combat a rez AA that returns exp, else the best rez
-- spell in the book (memorized into a borrowed gem if needed) - once per corpse (it stays after the rez; remembered for
-- 3 hours across reloads). Out of combat a corpse further away is walked to first, and the Hunter tank waits for that
-- (the ${AutoXP} 'C' flag): released members' corpses were left behind while the tank kept pulling
local doRez
do   -- its tables stay out of the main chunk (LuaJIT allows it 200 locals)
local REZAA = { 'Blessing of Resurrection', 'Rejuvenation of Spirit', 'Divine Resurrection' }
local COMBATREZ = { 'Call of the Wild' }
local function rezSpell()
    local lvl = mq.TLO.Me.Level() or 0
    if R.rezLevel == lvl then return R.rezName end
    R.rezLevel, R.rezName = lvl, ''
    local best = 0
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        if b() and b.Subcategory() == 'Resurrection' and b.TargetType() == 'Corpse' and (b.Level() or 0) > best then
            best, R.rezName = b.Level() or 0, b.Name()
        end
    end
    return R.rezName
end

local function corpseKey(c) return string.format('%s|%s|%d', mq.TLO.Zone.ShortName() or '', c.CleanName() or '', c.ID() or 0) end
local function rezzedBefore(c)
    local t = S.rezDone[corpseKey(c)]
    return R.rezzed[c.ID()] or (t ~= nil and os.time() - t < 10800)
end
local function markRezzed(c)
    local now = os.time()
    for k, t in pairs(S.rezDone) do if now - t > 10800 then S.rezDone[k] = nil end end
    R.rezzed[c.ID()], S.rezDone[corpseKey(c)] = true, now
    return corpseKey(c)
end
local function canRez()
    for _, n in ipairs(REZAA) do if mq.TLO.Me.AltAbility(n)() then return true end end
    return rezSpell() ~= ''
end

-- in a fight someone who died stays dead for 10s while the heals go to the living, and is rezzed only while the main
-- tank and main assist still stand (a rez in a wipe only gives the mobs another target; out of combat is unchanged)
function FIGHT.rezNow(name)
    if mq.gettime() - (R.diedAt[name] or mq.gettime()) < 10000 then return false end
    for _, m in ipairs({ mq.TLO.Group.MainTank, mq.TLO.Group.MainAssist }) do
        if m.Name() and (not m.Present() or m.Type() == 'Corpse') then return false end
    end
    return true
end

function doRez()
    if not S.rez or FIGHT.keepInvis() then return false end
    local fight = #hostiles() > 0
    local who = {}
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        local n = m.Name()
        if n then
            local dead = m.Type() == 'Corpse'
            if dead then R.diedAt[n] = R.diedAt[n] or mq.gettime() else R.diedAt[n] = nil end
            table.insert(who, { name = n, dead = dead })
        end
    end
    -- my own corpse too, out of combat: resurrecting it wins the experience back
    if not fight then table.insert(who, { name = ME, me = true }) end
    R.corpseSkip = R.corpseSkip or {}
    for _, w in ipairs(who) do
        local name = w.me and 'my corpse' or w.name
        local c = mq.TLO.Spawn('pccorpse ' .. w.name .. "'s corpse")
        local cid = c and c() and c.ID() or 0
        local near = cid > 0 and (c.Distance3D() or 999) < 100 and c.LineOfSight()
        if not fight and cid > 0 and not near and not rezzedBefore(c) and (R.corpseSkip[cid] or 0) < mq.gettime() and canRez() then
            local len = mq.TLO.Navigation.PathLength('id ' .. cid)() or -1
            local stuck = R.corpseWalk == cid and mq.gettime() - R.corpseWalkAt > 90000
            if len < 0 or len > 1500 or stuck then
                -- no path (look again in a minute), too far, or still not there after 90s (leave it 10 minutes)
                R.corpseSkip[cid] = mq.gettime() + ((len < 0 and not stuck) and 60000 or 600000)
                if R.corpseWalk == cid then R.corpseWalk = nil; mq.cmd('/nav stop'); log('could not reach the corpse of %s - leaving it', name) end
            else
                if not mq.TLO.Navigation.Active() then mq.cmdf('/nav id %d distance=20', cid) end
                if R.corpseWalk ~= cid then R.corpseWalk, R.corpseWalkAt = cid, mq.gettime(); log('walking to the corpse of %s to resurrect it', name) end
                R.rezBusyAt = mq.gettime()
                return true
            end
        end
        if near and not rezzedBefore(c) and (not fight or (w.dead and FIGHT.rezNow(w.name))) then
            local key = c.ID() .. '|rez'
            for _, n in ipairs(fight and COMBATREZ or REZAA) do
                if mq.TLO.Me.AltAbilityReady(n)() and mq.gettime() - (R.buffTry[key] or 0) > (fight and 10000 or 60000) and targetId(c.ID()) then
                    R.buffTry[key], R.rezBusyAt = mq.gettime(), mq.gettime()
                    if mq.TLO.Me.Sitting() then mq.cmd('/stand'); mq.delay(300) end
                    mq.cmdf('/alt act %d', mq.TLO.Me.AltAbility(n).ID() or 0)
                    mq.delay(1000, casting)
                    if casting() or not mq.TLO.Me.AltAbilityReady(n)() then
                        log('rez %s (%s)', name, n)
                        local rk = not fight and markRezzed(c) or nil
                        if casting() then R.cast = { name = n, id = c.ID(), kind = 'heal', resume = function() end, rezKey = rk } end
                    end
                    return true
                end
            end
            local sp = not fight and rezSpell() or ''
            if sp ~= '' and tryBuff(sp, c.ID(), 'rez ' .. name) then
                R.rezBusyAt = mq.gettime()
                if R.cast and R.cast.id == c.ID() then R.cast.rezKey = markRezzed(c) end
                return true
            end
        end
    end
    return false
end
end

local function engage(id)
    local t = spawn(id)
    if not alive(t) then return end
    R.targetId, R.targetName, R.opened, R.fightZone = id, t.CleanName(), false, mq.TLO.Zone.ShortName() or ''
    targetId(id)
    log('engage %s (L%d %s) at %.0f', R.targetName, t.Level() or 0, t.Class.ShortName() or '?', t.Distance() or 0)
    if S.mode == 'Manual' then setState('FIGHT'); return end
    R.pull, R.pullWait, R.holdUntil = R.pullCandidate and pullPlan() or nil, nil, 0
    if R.pull then
        R.pull.dist, R.pullTries = math.min(S.pullDist, R.pull.range * 0.8), 0
        log('pulling with %s %s from %d', R.pull.how:lower(), R.pull.name, R.pull.dist)
    end
    R.waypoint, R.pendingDetour = R.pendingDetour, nil
    if R.waypoint then
        log('routing around %s', R.waypoint.around)
        mq.cmdf('/nav %s', R.waypoint.dest); R.lastNav = mq.gettime()
    else
        navTo(id)
    end
    setState('APPROACH')
end

-- go after the player's pick: switch to it mid-fight, otherwise engage it (Manual waits until it's on us)
local function followPick(st)
    if R.pickId == 0 then return false end
    if S.role ~= 'Tank' or S.mode ~= 'Manual' then R.pickId = 0; return false end
    local t = spawn(R.pickId)
    if not alive(t) then R.pickId = 0; return false end
    if R.targetId == R.pickId and (st == 'APPROACH' or st == 'FIGHT') then return false end
    if st == 'FIGHT' then
        log('switch target -> %s (your pick)', t.CleanName())
        R.targetId, R.targetName, R.opened, R.holdUntil = t.ID(), t.CleanName(), false, 0
        attackOn(); closeIn(t)
        return true
    end
    if S.mode == 'Manual' then return false end
    if st == 'TRAVEL' then mq.cmd('/travelto stop') end
    if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
    local onUs = false
    for _, x in ipairs(hostiles()) do if x.ID() == t.ID() then onUs = true end end
    R.pendingDetour, R.pullCandidate = nil, S.mode == 'Hunter' and not onUs
    engage(t.ID())
    return true
end

-- reasons not to pull yet: resurrection sickness (mine or a group member's), a dead or missing member,
-- a healer or CC class under "Rest below %" mana
local SICK = { 'Resurrection Sickness', 'Revival Sickness' }
-- classes the Hunter waits for (mana under the rest %): healers, CC and the nukers (a nuker out of mana stops nuking)
local HEALCC = { CLR = true, DRU = true, SHM = true, ENC = true, BRD = true, MAG = true, WIZ = true, NEC = true }
local function pullHold(travel)
    for _, b in ipairs(SICK) do if mq.TLO.Me.Buff(b)() then return 'I have ' .. b end end
    if hp() < S.restPct then return string.format('I am at %d%% HP', hp()) end
    local buffer = DPS.peerBuffing and DPS.peerBuffing()
    if buffer then return buffer .. ' is buffing' end
    local rezzer = DPS.peerRezzing and DPS.peerRezzing()
    if rezzer then return rezzer .. ' is resurrecting a corpse' end
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        local name = m.Name() or '?'
        if m.OtherZone() then
            if not travel then return name .. ' is not in the zone' end
        elseif not m.Present() or m.Type() == 'Corpse' then
            return name .. ' is dead'
        else
            local s = m.Spawn
            for _, b in ipairs(SICK) do if s() and s.CachedBuff(b)() then return name .. ' has ' .. b end end
            -- a bard only under 20%: its songs and single mez cost nothing, and it settles near 52% (Pindaini held the
            -- pulls 34% of the time at 51-54% under a 55% line, Focused Paragons or not, 2026-10-18)
            local cls = m.Class.ShortName() or ''
            if HEALCC[cls] and (m.PctMana() or 100) < (cls == 'BRD' and math.min(20, S.restPct) or S.restPct) then
                return string.format('%s is at %d%% mana', name, m.PctMana() or 0)
            end
            if (m.PctHPs() or 100) < S.restPct then return string.format('%s is at %d%% HP', name, m.PctHPs() or 0) end
        end
    end
    return nil
end

-- the hunt-zone trip waits for the same things (not for members who are elsewhere), for my own mana too, and never
-- leaves groupmates behind: Chase followers don't follow into another zone. Ramakrr respawned in the Guild Lobby with
-- the group, set off for Deepshade alone at 10% mana and died on the way (2026-10-19 22:36)
local function travelHeld()
    local hold = pullHold(true)
    if not hold and (mq.TLO.Me.MaxMana() or 0) > 0 and mana() < S.restPct then hold = string.format('I am at %d%% mana', mana()) end
    if not hold then
        for i = 1, (mq.TLO.Group.Members() or 0) do
            local m = mq.TLO.Group.Member(i)
            if m.Present() and not m.OtherZone() then hold = (m.Name() or '?') .. ' is here and would stay behind'; break end
        end
    end
    if hold and hold ~= R.travelWhy then log('not traveling yet: %s', hold) end
    R.travelWhy = hold   -- its own field: sharing the pull hold's made both log every tick
    return hold ~= nil
end

-- Tank role: make myself the group's main tank and main assist (needs group leader), so Chase and
-- Assist characters with no name typed in follow / assist me
-- Backup tank (Backup on): in a fight while the group's main tank (not me) is dead or out of the zone, tank in its
-- place - the Tank role (taunt, Tank abilities, mobs in front, target priority). Back to my own role when the fight
-- is over (nothing on the extended target list); the next fight checks again. Out of a fight (the tank travelling)
-- nothing changes
local function backupCheck()
    if not S.backupTank then
        if R.backupFrom then S.role, R.backupFrom = R.backupFrom, nil; log('backup tank off - back to %s', S.role) end
        return
    end
    local mt = mq.TLO.Group.MainTank
    local name = mt() and mt.Name() or ''
    if name == '' or name == (mq.TLO.Me.CleanName() or '') then return end
    local down = mt.OtherZone() or not mt.Present() or mt.Type() == 'Corpse'
    local fight = #hostiles() > 0
    if down and fight and not R.backupFrom and S.role ~= 'Tank' then
        R.backupFrom, S.role = S.role, 'Tank'
        log('main tank %s is down - tanking as the backup tank', name)
    elseif R.backupFrom and not fight then
        S.role, R.backupFrom = R.backupFrom, nil
        log('fight over - backup tank back to %s', S.role)
    end
end

local function claimGroupRoles()
    backupCheck()
    if S.role ~= 'Tank' or (mq.TLO.Group.Members() or 0) == 0 or mq.gettime() - R.lastRoles < 30000 then return end
    R.lastRoles = mq.gettime()
    local me = mq.TLO.Me.CleanName() or ''
    local tank, assist = mq.TLO.Group.MainTank.Name() == me, mq.TLO.Group.MainAssist.Name() == me
    if tank and assist then return end
    if mq.TLO.Group.Leader.Name() ~= me then
        if not R.rolesWarned then log('Tank: not the group leader - cannot make myself main tank / main assist'); R.rolesWarned = true end
        return
    end
    if not tank then mq.cmdf('/grouproles set %s 1', me) end
    if not assist then mq.cmdf('/grouproles set %s 2', me) end
    log('Tank: set myself as group main tank and main assist')
end

-- a typed name wins; blank = the group's main tank (Chase) or main assist (Assist), never myself
local function groupLead(typed, role)
    if typed ~= '' then return typed end
    local n = (role == 'tank' and mq.TLO.Group.MainTank.Name() or mq.TLO.Group.MainAssist.Name()) or ''
    return n ~= (mq.TLO.Me.CleanName() or '') and n or ''
end

-- NPCs listed in the Find Window (quest givers, merchants, bankers...) are never hunted. Read once per zone: the
-- window is opened if it's closed (that asks the server for the zone's list), read when the list settles, closed again
local function findable()
    local zone = mq.TLO.Zone.ShortName() or ''
    if R.findZone == zone then return R.findNames end
    local wasOpen = mq.TLO.Window('FindLocationWnd').Open()
    if not wasOpen then mq.cmd('/windowstate FindLocationWnd open') end
    local l = mq.TLO.Window('FindLocationWnd').Child('FLW_FindLocationList')
    local last, since = -1, mq.gettime()
    mq.delay(4000, function()
        local c = l.Items() or 0
        if c ~= last then last, since = c, mq.gettime() end
        return c > 0 and mq.gettime() - since > 1000
    end)
    local names, list_ = {}, {}
    for i = 1, (l.Items() or 0) do
        local cat, name = l.List(i, 1)() or '', l.List(i, 2)() or ''
        if name ~= '' and cat ~= '(Group)' and cat ~= 'Zone Connection' then names[name:lower()] = true; table.insert(list_, name) end
    end
    if not wasOpen then mq.cmd('/windowstate FindLocationWnd close') end
    R.findZone, R.findNames = zone, names
    log('not hunting Find Window NPCs in %s: %s', zone, #list_ > 0 and table.concat(list_, ', ') or 'none listed')
    return names
end

-- a pulled mob is joined once it has reached the main tank (within 30), or after 6s - so nobody pulls its aggro off
-- the tank on the way in (a pull spell alone can take it under the assist %, and it's on the extended target list
-- as soon as it aggros)
local function atTank(t)
    local mt = mq.TLO.Group.MainTank
    if not mt() or not mt.Present() or mt.Type() == 'Corpse' or (mt.ID() or 0) == myId() then return true end
    local s = mq.TLO.Spawn('id ' .. (mt.ID() or 0))
    if s() and t.X() and s.X() then
        if math.sqrt((t.X() - s.X()) ^ 2 + (t.Y() - s.Y()) ^ 2 + (t.Z() - s.Z()) ^ 2) <= 30 then return true end
    end
    if R.assistSeen ~= t.ID() then R.assistSeen, R.assistSeenAt = t.ID(), mq.gettime() end
    return mq.gettime() - R.assistSeenAt >= 6000
end

-- the mobs a walk to a pull passes: NPCs within the alone radius of the walking route (MQ2Nav's path points), on the
-- same level (30 up or down), other than the pull itself and the ones next to it (its company, counted apart). Walking
-- the group past them dragged them along to the pull. mobs = { {id, x, y, z, name} } read once per look; returns their
-- names, or nil when MQ2Nav gives no path points (not checked)
function FIGHT.routeBlockers(c, mobs)
    local s = mq.TLO.Navigation.PathPoints('id ' .. c.id)()
    if not s or s == '' then return nil end
    local pts = {}
    for x, y, z in s:gmatch('(-?[%d.]+),(-?[%d.]+),(-?[%d.]+)') do pts[#pts + 1] = { tonumber(x), tonumber(y), tonumber(z) } end
    local r, out = S.avoidRadius, {}
    for _, m in ipairs(mobs) do
        local dx, dy = m.x - c.x, m.y - c.y
        if m.id ~= c.id and (dx * dx + dy * dy > r * r or math.abs(m.z - c.z) > 40) then
            for k = 1, #pts - 1 do
                local a, b = pts[k], pts[k + 1]
                local sx, sy = b[1] - a[1], b[2] - a[2]
                local l2 = sx * sx + sy * sy
                local f = l2 > 0 and math.max(0, math.min(1, ((m.x - a[1]) * sx + (m.y - a[2]) * sy) / l2)) or 0
                local ex, ey = m.x - a[1] - f * sx, m.y - a[2] - f * sy
                if ex * ex + ey * ey < r * r and math.abs(m.z - (a[3] + (b[3] - a[3]) * f)) < 30 then
                    out[#out + 1] = m.name; break
                end
            end
        end
    end
    return out
end

local function pickTarget()
    -- anything already on us comes first (priority order); a non-tank following the group waits for it to reach the tank
    R.pendingDetour, R.pullCandidate = nil, false
    local best = bestTarget()
    if best then
        if S.role == 'Tank' or (S.mode ~= 'Chase' and S.mode ~= 'Assist') or atTank(best) then return best.ID() end
        return nil
    end
    if S.mode == 'Manual' then
        local t = mq.TLO.Target
        if t() and t.Type() == 'NPC' and R.attacking then return t.ID() end
        return nil
    elseif S.mode == 'Hunter' then
        -- a mob already on the extended target list (on its way, or beyond hostiles() range): go for the nearest
        -- one; never pull another while any is listed (an unreachable one just means waiting)
        local listed, near, nd = false, nil, nil
        for i = 1, (mq.TLO.Me.XTarget() or 0) do
            local x = mq.TLO.Me.XTarget(i)
            if x() and (x.ID() or 0) > 0 and x.Type() == 'NPC' and alive(spawn(x.ID())) then
                listed = true
                local d = x.Distance3D() or 9999
                if (R.skip[x.ID()] or 0) < mq.gettime() and (not nd or d < nd) then near, nd = x.ID(), d end
            end
        end
        if near then return near end
        if listed then return nil end
        local hold = pullHold()
        if hold then
            if hold ~= R.holdWhy then log('not pulling yet: %s', hold); R.holdWhy = hold end
            return nil
        end
        if R.holdWhy then log('group ready - pulling again'); R.holdWhy = nil end
        -- route checks cost: look for a new pull at most every 1.5s
        if mq.gettime() - R.lastHunt < 1500 then return nil end
        R.lastHunt = mq.gettime()
        local q = string.format('npc range %d %d radius %d noalert 1 targetable', S.minlvl, S.maxlvl, S.radius)
        -- every mob in level range within the pull radius, by walking distance (NearestSpawn is 2D, so check the
        -- path), ranked by the fewest other NPCs within avoidRadius of it (alone first), then the closest. The first
        -- whose route passes no other mob is pulled; with none clear, no pull (mobs wander and respawn: look again)
        local cands = {}
        local npcs = findable()
        for i = 1, math.min(mq.TLO.SpawnCount(q)() or 0, 40) do
            local s = mq.TLO.NearestSpawn(i, q)
            if not s() then break end
            local id = s.ID()
            if (R.skip[id] or 0) < mq.gettime() and not npcs[(s.CleanName() or ''):lower()] then
                local len = mq.TLO.Navigation.PathLength('id ' .. id)() or -1
                if len < 0 then R.skip[id] = mq.gettime() + 30000                     -- off the navmesh
                elseif len <= S.radius then
                    -- (the mob itself can miss the count: "-1 other(s)")
                    local near = math.max(0, (mq.TLO.SpawnCount(string.format('npc loc %.0f %.0f %.0f radius %d zradius 40',
                        s.X(), s.Y(), s.Z(), S.avoidRadius))() or 1) - 1)
                    table.insert(cands, { id = id, len = len, near = near, name = s.CleanName(), x = s.X() or 0, y = s.Y() or 0,
                        z = s.Z() or 0, key = near * 1e6 + len })
                end
            end
        end
        if #cands == 0 then
            if mq.gettime() - R.noRouteAt > 30000 then log('no mobs to pull within %d', S.radius); R.noRouteAt = mq.gettime() end
            return nil
        end
        table.sort(cands, function(a, b) return a.key < b.key end)
        -- every NPC a route could pass (the route stays within the pull radius of me), grey ones and Find Window NPCs aside
        local mobs, rq = {}, string.format('npc radius %d', S.radius + S.avoidRadius)
        for i = 1, math.min(mq.TLO.SpawnCount(rq)() or 0, 100) do
            local m = mq.TLO.NearestSpawn(i, rq)
            if not m() then break end
            if m.ConColor() ~= 'GREY' and not npcs[(m.CleanName() or ''):lower()] then
                table.insert(mobs, { id = m.ID(), x = m.X() or 0, y = m.Y() or 0, z = m.Z() or 0, name = m.CleanName() or '?' })
            end
        end
        local blocked = {}
        for _, c in ipairs(cands) do
            local b = FIGHT.routeBlockers(c, mobs)
            if not b or #b == 0 then
                if R.routeWait then log('a clear route again'); R.routeWait = nil end
                log('closest pull: %s, %.0f away, %s', c.name or '?', c.len, c.near == 0 and 'alone' or (c.near .. ' other(s) next to it'))
                R.pullCandidate = true
                return c.id
            end
            if #blocked < 3 then table.insert(blocked, string.format('%s past %s', c.name or '?', table.concat(b, ', '))) end
        end
        if mq.gettime() - (R.routeWait or 0) > 30000 then
            log('every pull within %d has mobs in the way - waiting (%s)', S.radius, table.concat(blocked, '; '))
            R.routeWait = mq.gettime()
        end
        return nil
    else
        local who = S.mode == 'Assist' and groupLead(S.assistName, 'assist') or groupLead(S.chaseName, 'tank')
        if who == '' then return nil end
        local t
        if (S.mode == 'Assist' and S.assistName or S.chaseName) == '' then
            -- the group main assist's target, shared by the game: no /assist (it can switch auto-attack on)
            t = mq.TLO.Me.GroupAssistTarget
        else
            if mq.gettime() - R.lastAssist > 1500 then mq.cmdf('/assist %s', who); R.lastAssist = mq.gettime(); mq.delay(300) end
            t = mq.TLO.Target
        end
        if t() and t.Type() == 'NPC' and (t.PctHPs() or 100) <= S.assistAt and atTank(t) then return t.ID() end
        if mq.TLO.Me.Combat() then attackOff() end   -- "attack on assist" before we mean to fight
        return nil
    end
end

mq.event('axpCannotCast', 'You cannot cast #1# on #2#.', function(_, _, who)
    local t = spawn(R.targetId ~= 0 and R.targetId or R.pickId)
    if alive(t) and t.Type() == 'NPC' and t.CleanName() == who and (R.state == 'APPROACH' or R.state == 'FIGHT') then
        log('%s cannot be attacked - skipping it', who)
        R.skip[t.ID()] = mq.gettime() + 600000; R.targetId, R.pickId = 0, 0
        mq.cmd('/nav stop'); attackOff(); setState('FIND')
    end
end)
-- a mob in a safe area (a Coldain camp): it and every NPC within 200 of it are skipped for 10 minutes. The Hunter cast at
-- a Coldain reclaimer for 5 minutes, until the fight timeout ("You cannot cast detrimental spells..." 444 times, 14:11)
mq.event('axpSafeArea', 'You cannot cast detrimental spells because you are in a safe area.', function()
    local t = spawn(R.targetId ~= 0 and R.targetId or R.pickId)
    if not (alive(t) and t.Type() == 'NPC' and (R.state == 'APPROACH' or R.state == 'FIGHT')) then return end
    local q, n = string.format('npc loc %.0f %.0f radius 200', t.X() or 0, t.Y() or 0), 0
    for i = 1, 40 do
        local s = mq.TLO.NearestSpawn(i, q)
        if not s() then break end
        R.skip[s.ID()] = mq.gettime() + 600000; n = n + 1
    end
    R.skip[t.ID()] = mq.gettime() + 600000
    log('%s is in a safe area - skipping it and %d NPC(s) around it', t.CleanName(), n)
    R.targetId, R.pickId = 0, 0
    mq.cmd('/nav stop'); attackOff(); setState('FIND')
end)

local function healNeeded()
    if not S.heal then return false end
    if hp() < S.emergencyPct and #abilitiesFor('Emergency') > 0 then return true end
    if not hurt() then return false end
    for _, h in ipairs(list(S.healSpells)) do if gemUp(h) then return true end end
    for _, a in ipairs(abilitiesFor('Heal')) do if abilityReady(a) then return true end end
    return false
end

local function ccNeeded()
    if not S.cc or hp() < 40 then return false end
    local range = 0
    for _, m in ipairs(list(S.mez)) do
        if gemUp(m) then
            local sp = mq.TLO.Spell(m)
            range = math.max(range, sp.TargetType() == 'Single' and (sp.MyRange() or sp.Range() or 0) or (sp.AERange() or 0))
        end
    end
    if range == 0 then return false end
    local adds = hostiles()
    if #adds < 2 then return false end
    local tank = mq.TLO.Me.GroupAssistTarget.ID() or 0
    for _, x in ipairs(adds) do
        if x.ID() ~= R.targetId and x.ID() ~= tank and not mezzed(x) and not R.noMez[x.ID()] and not x.Named() and x.LineOfSight()
            and (x.Distance3D() or 999) <= range then
            return true
        end
    end
    return false
end

-- CC from any state (a Chase bard waiting on the assist target too), right after heals: an add that needs a mez
-- gets it now - a song ducked for it isn't followed by another song
local function doMez() return ccNeeded() and doCC(spawn(R.targetId)) end

-- the cast in progress: true while we wait for it. A cast that isn't a heal is stopped for a heal someone
-- needs now, one that isn't a heal or CC for an add that needs mezzing; one about to land always finishes,
-- and after a duck the next one waits 4s (so an unreachable heal target can't stop every cast)
local function watchCast()
    local c = R.cast
    -- a bard sings on the move: while a song (not a mez) plays the rest of the tick goes on - following, closing in,
    -- the target and melee; every cast, ability, click and memorize waits for the cast bar
    local song = mq.TLO.Me.Class.ShortName() == 'BRD' and (not c or c.kind ~= 'cc')
    if not c then return casting() and not song end
    if not casting() then
        R.cast = nil; c.resume()
        if c.id ~= R.targetId then restoreFight() end
        return false
    end
    if c.kind == 'heal' or (tonumber(mq.TLO.Me.CastTimeLeft()) or 1000) < 500 or mq.gettime() - R.duckAt < 4000 then return not song end
    local need = (healNeeded() and 'heal') or (c.kind ~= 'cc' and ccNeeded() and 'mez') or nil
    if not need then return not song end
    log('ducking %s for a %s', c.name, need)
    mq.cmd(mq.TLO.Me.Class.ShortName() == 'BRD' and '/stopsong' or '/stopcast')
    mq.delay(500, function() return not casting() end)
    R.cast, R.duckAt = nil, mq.gettime()
    c.resume()
    return false
end

-- the spawn Chase follows / Assist assists
local function leadSpawn()
    local who = S.mode == 'Assist' and groupLead(S.assistName, 'assist') or groupLead(S.chaseName, 'tank')
    local c = who ~= '' and mq.TLO.Spawn('=' .. who) or nil
    return c and c() and c.Type() ~= 'Corpse' and c or nil
end

-- Chase: walk to within half the chase distance of the leader once they're further than it. With no path from here (a
-- spot the rest of the mesh doesn't connect to) walk straight at them until there is one: /nav did nothing and Seaeni
-- stood 2200 away from the group for 12 minutes (2026-10-18 13:17)
local function chaseFollow()
    if S.mode ~= 'Chase' then return end
    local c = leadSpawn()
    if not c or (c.Distance() or 0) <= S.chaseDist or mq.TLO.Navigation.Active() then return end
    local near = math.max(10, math.floor(S.chaseDist / 2))
    if R.chaseStraightAt and mq.gettime() - R.chaseStraightAt < 3000 then return end   -- walking straight: look again every 3s
    if not mq.TLO.Navigation.PathExists('id ' .. c.ID())() then
        if not R.chaseStraightAt then log('no path to %s - walking straight at them', c.CleanName()) end
        R.chaseStraightAt = mq.gettime()
        mq.cmdf('/moveto id %d mdist %d', c.ID(), near)
        return
    end
    if R.chaseStraightAt then R.chaseStraightAt = nil; mq.cmd('/moveto off'); log('path to %s again', c.CleanName()) end
    mq.cmdf('/nav id %d distance=%d', c.ID(), near)
end

-- one tick of the state machine -----------------------------------------------------------
-- the FIGHT state, split out of step() (LuaJIT allows a function 60 upvalues)
local function fightTick()
    local t = spawn(R.targetId)
    if not alive(t) and (mq.TLO.Zone.ShortName() or '') ~= R.fightZone then
        log('left %s mid-fight - lost %s', R.fightZone, R.targetName)
        attackOff(); mq.cmd('/stick off'); petBackOff(); R.targetId = 0; setState('FIND')
        return
    end
    if not alive(t) then
        local nextT = bestTarget()
        R.kills = R.kills + 1
        log('killed %s in %.1fs (kills %d)', R.targetName, inState() / 1000, R.kills)
        DPS.kill(inState() / 1000)
        if nextT then
            R.targetId, R.targetName, R.opened = nextT.ID(), nextT.CleanName(), false
            log('next add: %s (%s)', R.targetName, nextT.Class.ShortName() or '?')
            attackOn(); closeIn(nextT); setState('FIGHT'); return
        end
        attackOff(); mq.cmd('/stick off'); petBackOff(); R.targetId = 0
        setState((S.mode == 'Hunter' and (hp() < S.restPct or manaLow())) and 'REST' or 'BUFF')
        return
    end
    if doRez() then return end
    if (mq.TLO.Target.ID() or 0) ~= R.targetId or not R.attacking then restoreFight() end
    if hp() < 12 and S.mode == 'Hunter' and (mq.TLO.Group.Members() or 0) == 0 then stopAll('HP critical'); return end
    if FIGHT.tankBuffs() then return end
    if not ranged() and mq.gettime() < R.holdUntil then
        if reachable(t, 35) then
            R.holdUntil = 0; mq.cmd('/attack on'); stick()
        else
            if mq.gettime() - R.lastFace > 1000 then mq.cmdf('/face fast id %d', t.ID()); R.lastFace = mq.gettime() end
            return
        end
    end
    if archer() then
        -- keep facing it (auto-fire only shoots what's in front) and keep auto-fire on once it's in range
        if mq.gettime() - R.lastFace > 1500 then mq.cmdf('/face fast id %d', t.ID()); R.lastFace = mq.gettime() end
        if not mq.TLO.Me.AutoFire() and reachable(t, S.castRange) then mq.cmd('/autofire') end
        -- in range: hold ARCHERY units off it, backing up when it comes closer (MoveUtils moveback)
        if reachable(t, S.castRange) and not mq.TLO.Navigation.Active()
            and (not mq.TLO.Stick.Active() or mq.gettime() - R.tooCloseAt < 1000) then
            R.tooCloseAt = 0
            mq.cmdf('/stick id %d %d moveback', t.ID(), ARCHERY)
        elseif not reachable(t, S.castRange) and mq.TLO.Stick.Active() then
            mq.cmd('/stick off')
        end
    end
    if ranged() then
        -- stay in casting range with line of sight
        local far = not reachable(t, S.castRange)
        if far and not mq.TLO.Navigation.Active() and mq.gettime() - R.lastNav > 3000 then navTo(t.ID())
        elseif not far and mq.TLO.Navigation.Active() and reachable(t, S.castRange * 0.8) then mq.cmd('/nav stop') end
    end
    if not ranged() then
        -- out of reach (too far, another floor or behind a wall): path to it; stick only once it's in sight
        if not reachable(t, 35) then
            if not mq.TLO.Navigation.Active() and mq.gettime() - R.lastNav > 3000 then mq.cmd('/stick off'); navTo(t.ID()) end
        elseif mq.TLO.Navigation.Active() then mq.cmd('/nav stop'); stick()
        elseif not mq.TLO.Stick.Active() then stick() end
        if reachable(t, 35) and not mq.TLO.Me.Combat() then mq.cmd('/attack on') end
    end
    doPet(t)
    if keepMobsInFront(t) then return end
    if doTank(t) then return end
    if doShed(t) then return end
    if FIGHT.petGuard() then return end
    if doDuties(t) then return end
    if doBurn(t) then return end
    if FIGHT.selfCombatBuffs() then return end
    if doEndurance() then return end   -- in a fight only its mana part acts (shard, Mana abilities)
    if doDps(t) then return end
    -- a bard's songs after its abilities (Fierce Eye, Kick, the burns, Bellow, then the songs): a song every
    -- tick left the abilities only the moments when every song in the list was up
    if doSongs() then return end
    if inState() > 300000 then log('fight timeout'); attackOff(); R.pickId = 0; setState('FIND') end
end

local function step()
    -- dead: drop the fight and wait for a rez (or a respawn), then start over from BUFF
    if mq.TLO.Me.State() == 'HOVER' or mq.TLO.Me.Dead() then
        if not R.dead then R.dead = true; R.targetId, R.pickId, R.cast = 0, 0, nil; setState('BUFF'); log('died - waiting for a rez') end
        return
    end
    if R.dead then R.dead = false; log('alive again') end
    noticePick()
    if watchCast() then return end
    claimGroupRoles()
    if R.feignAt > 0 and mq.gettime() - R.feignAt > 3000 then
        R.feignAt = 0
        if mq.TLO.Me.Feigning() then mq.cmd('/stand'); mq.delay(300); restoreFight() end
    end
    -- heals, then a mez, then (out of a fight) songs: a song ducked for a mez isn't restarted before the mez
    if doHeal() then return end
    if doMez() then return end
    if doMalo() then return end
    if R.state ~= 'FIGHT' and R.state ~= 'REST' and doSongs() then return end
    if doDefense() then return end
    local st = R.state
    if followPick(st) then return end
    local here = mq.TLO.Zone.ShortName() or ''

    -- hunt zone changed while running: leave once we're not fighting
    if S.mode == 'Hunter' and S.travel and here ~= S.zone and st ~= 'TRAVEL' and st ~= 'FIGHT' and R.pickId == 0 and #hostiles() == 0
        and not travelHeld() then
        mq.cmd('/stick off'); mq.cmd('/nav stop'); attackOff(); R.targetId = 0
        mq.cmdf('/travelto %s', S.zone)
        R.travelTarget, R.travelTries, R.lastMoveAt = S.zone, 0, mq.gettime()
        log('hunt zone is %s (here: %s) - traveling', S.zone, here)
        setState('TRAVEL')
        return
    end

    if st == 'TRAVEL' then
        if here == S.zone then log('arrived in %s', S.zone); mq.cmd('/nav reload'); setState('BUFF'); return end
        if travelHeld() then mq.cmd('/travelto stop'); setState('BUFF'); return end
        if R.travelTarget ~= S.zone then
            log('travel destination changed -> %s', S.zone)
            mq.cmd('/travelto stop'); mq.cmdf('/travelto %s', S.zone)
            R.travelTarget, R.travelTries, R.lastMoveAt = S.zone, 0, mq.gettime()
            return
        end
        -- progress / stall detection (moving or zoning counts as progress)
        local pos = string.format('%s:%.0f:%.0f', here, mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if pos ~= R.lastPos then R.lastPos, R.lastMoveAt = pos, mq.gettime() end
        if mq.gettime() - R.lastMoveAt > 30000 then
            R.travelTries = R.travelTries + 1
            if R.travelTries > 3 then stopAll('travel stalled (EasyFind could not route?)'); return end
            log('travel stalled in %s - retrying /travelto %s (%d/3)', here, S.zone, R.travelTries)
            mq.cmd('/travelto stop'); mq.cmdf('/travelto %s', S.zone)
            R.lastMoveAt = mq.gettime()
        end
        if inState() > 30 * 60 * 1000 then stopAll('travel timeout') end

    elseif st == 'BUFF' then
        if #hostiles() > 0 then setState('FIND'); return end
        chaseFollow()
        -- (not while a bard's song plays: the spell book would cut it off)
        if not R.swapGem and quiet() and not casting() then
            if upgradeGems() then return end
            local sig = gemSig()
            if sig ~= S.gemSig then
                if S.gemSig ~= '' then log('memorized spells changed - refreshing spell lists') end
                S.gemSig = sig; fillFromGems()
            end
            if memNukes() then return end
            if memRestSongs() then return end
            if memHeals() then return end
        end
        if FIGHT.chaseLoot() then return end
        if doPetCare() then return end
        if doPetWeapons() then return end
        if doRez() then return end
        if doEndurance() then return end
        if doAbilityBuffs() then return end
        if doBuffs() then return end
        setState('FIND')

    elseif st == 'REST' then
        if #hostiles() > 0 then mq.cmd('/stand'); setState('FIND'); return end
        if doRez() then return end
        if FIGHT.chaseLoot() then return end
        if S.mode == 'Chase' then
            local lead = leadSpawn()
            if lead and (lead.Distance() or 0) > S.chaseDist then mq.cmd('/stand'); setState('FIND'); return end
        end
        local endu = mq.TLO.Me.PctEndurance() or 100
        if hp() >= S.restTo and (mana() >= S.restTo or (mq.TLO.Me.MaxMana() or 0) == 0) and endu >= S.restTo then
            mq.cmd('/stand'); log('rested: HP %d%% mana %d%% endurance %d%%', hp(), mana(), endu); setState('BUFF')
        elseif doEndurance() then return
        elseif not mq.TLO.Me.Sitting() then mq.cmd('/sit') end

    elseif st == 'FIND' then
        if doRez() then return end
        if doEndurance() then return end
        if petsToArm() then setState('BUFF'); return end
        -- group buffs come before the next pull: idle with nothing around, go buff (a member every 30s at most)
        if #hostiles() == 0 and mq.gettime() - (R.idleBuffAt or 0) > 5000 then
            R.idleBuffAt = mq.gettime()
            setState('BUFF'); return
        end
        chaseFollow()
        if #hostiles() == 0 and (hp() < S.restPct or manaLow()) then
            local lead = S.mode == 'Chase' and leadSpawn() or nil
            if not lead or (lead.Distance() or 0) <= S.chaseDist then
                log('medding: HP %d%% mana %d%% endurance %d%%', hp(), mana(), mq.TLO.Me.PctEndurance() or 0); setState('REST'); return
            end
        end
        local id = pickTarget()
        if id then engage(id) end

    elseif st == 'APPROACH' then
        local t = spawn(R.targetId)
        if not alive(t) then setState('FIND'); return end
        if R.waypoint then
            -- detour leg: then head for the target (or straight there if something already aggroed)
            local w = R.waypoint
            local d = math.sqrt(((mq.TLO.Me.X() or 0) - w.x) ^ 2 + ((mq.TLO.Me.Y() or 0) - w.y) ^ 2)
            if d < 15 or #hostiles() > 0 or (not mq.TLO.Navigation.Active() and mq.gettime() - R.lastNav > 2000) then
                R.waypoint = nil; navTo(t.ID())
            end
            return
        end
        if R.pull and reachable(t, R.pull.dist, true) then
            if mq.TLO.Navigation.Active() or mq.TLO.Me.Moving() then
                -- come to a full stop first: a pull cast right after /nav stop gets interrupted (a bard's song isn't)
                mq.cmd('/nav stop')
                if mq.TLO.Me.Class.ShortName() ~= 'BRD' then
                    mq.delay(1500, function() return not mq.TLO.Me.Moving() end)
                    mq.delay(400)
                end
            end
            if not pullReady(R.pull) then
                R.pullWait = R.pullWait or mq.gettime()
                if mq.gettime() - R.pullWait > (R.pull.how == 'Spell' and 15000 or 6000) then log('pull not ready - walking in'); R.pull = nil; navTo(t.ID()) end
                return
            end
            if doPull(t) then
                -- melee holds here and lets it come; casters fight from where they stand
                R.pull, R.holdUntil, R.attacking = nil, mq.gettime() + 12000, true
                setState('FIGHT'); return
            end
            -- the server refused it (range / line of sight): step closer and try again
            failedUntil[R.pull.name] = nil
            R.pullTries = R.pullTries + 1
            if R.pullTries > 2 then log('pull failed - walking in'); R.pull = nil
            else R.pull.dist = math.max(30, R.pull.dist * 0.6); log('pull failed - moving in to %d', R.pull.dist) end
            navTo(t.ID())
            return
        end
        local inRange = ranged() and reachable(t, S.castRange * 0.8)
        local navOff = not mq.TLO.Navigation.Active() and mq.gettime() - R.lastNav > 2000
        if inRange or reachable(t, 25) or (navOff and reachable(t, 50)) then
            mq.cmd('/nav stop')
            stick()
            attackOn()
            setState('FIGHT')
        elseif navOff then
            if inState() < 60000 and mq.TLO.Navigation.PathExists('id ' .. t.ID())() then
                navTo(t.ID())
            else
                log('no path to %s - skipping it', R.targetName)
                R.skip[t.ID()] = mq.gettime() + 120000; R.targetId, R.pickId = 0, 0; setState('FIND')
            end
        elseif inState() > 120000 then log('approach timeout'); mq.cmd('/nav stop'); R.pickId = 0; setState('FIND') end

    elseif st == 'FIGHT' then
        fightTick()
    end
end

-- missing spells: base-rank class spells at/below my level that are not in the spell book or combat abilities
local SP = { scanning = false, nextId = 1, lastHit = 0, level = 0, seen = {}, found = {}, list = {}, done = false, lastCheck = 0 }
local SPELL_ID_MAX = 120000

local function haveSpell(name)
    for _, rk in ipairs({ '', ' Rk. II', ' Rk. III' }) do
        if mq.TLO.Me.Book(name .. rk)() or mq.TLO.Me.CombatAbility(name .. rk)() then return true end
    end
    return false
end

local function startSpellScan()
    SP.scanning, SP.nextId, SP.lastHit, SP.seen, SP.found = true, 1, 0, {}, {}
    SP.level = mq.TLO.Me.Level() or 0
end

-- processes a chunk of spell ids per main-loop tick so the client never stalls
local function stepSpellScan()
    if not SP.scanning then
        -- drop entries that got scribed since the scan
        if #SP.list > 0 and mq.gettime() - SP.lastCheck > 10000 then
            SP.lastCheck = mq.gettime()
            local keep = {}
            for _, s in ipairs(SP.list) do if not haveSpell(s.name) then table.insert(keep, s) end end
            if #keep ~= #SP.list then log('missing spells: %d left', #keep) end
            SP.list = keep
        end
        return
    end
    local lvl, last = SP.level, math.min(SP.nextId + 2499, SPELL_ID_MAX)
    for id = SP.nextId, last do
        local sp = mq.TLO.Spell(id)
        local l = sp.Level()
        if l then
            SP.lastHit = id
            if l >= 1 and l <= lvl then
                local name = sp.Name()
                if name and not SP.seen[name] and not name:find(' Rk%.') and (sp.Rank() or 0) <= 1 then
                    SP.seen[name] = true
                    if not haveSpell(name) then table.insert(SP.found, { level = l, name = name }) end
                end
            end
        end
    end
    SP.nextId = last + 1
    if SP.nextId > SPELL_ID_MAX or (SP.nextId > 40000 and SP.nextId - SP.lastHit > 10000) then
        SP.scanning, SP.done = false, true
        table.sort(SP.found, function(a, b) if a.level ~= b.level then return a.level > b.level end return a.name < b.name end)
        SP.list, SP.lastCheck = SP.found, mq.gettime()
        if #SP.list > 0 then
            local names = {}
            for i, s in ipairs(SP.list) do if i <= 12 then table.insert(names, string.format('L%d %s', s.level, s.name)) end end
            log('missing %d spell(s) at or below L%d: %s%s', #SP.list, lvl, table.concat(names, ', '), #SP.list > 12 and ', ...' or '')
        else
            log('spell book is complete for L%d', lvl)
        end
    end
end

local function setPaused(p)
    if p == R.paused then return end
    R.paused = p
    if p then
        attackOff(); mq.cmd('/nav stop'); mq.cmd('/stick off')
        if R.state == 'TRAVEL' then mq.cmd('/travelto stop') end
    elseif R.state == 'TRAVEL' then
        mq.cmdf('/travelto %s', S.zone); R.travelTarget, R.lastMoveAt = S.zone, mq.gettime()
    end
    log(p and 'paused' or 'resumed')
end

-- DPS ---------------------------------------------------------------------------------------
-- My damage, read from the chat: my hits and spells ("You ... for N points of"), damage shields ("by YOUR"), my pet
-- and swarm pets ("<pet> ...", "<Me>`s pet ..."), DoT ticks ("has taken N damage from X by <Me>" / "from your X").
-- A fight runs from the first hit until 8s without one; its DPS is its damage over that time. Session numbers count
-- from load (or the HUD's Reset stats)
do
    local D
    local function fresh()
        D = { since = mq.gettime(), xp0 = totalXp(), aa0 = (mq.TLO.Me.AAPointsTotal() or 0) * 100 + (mq.TLO.Me.PctAAExp() or 0),
            total = 0, by = { melee = 0, spell = 0, dot = 0, pet = 0, ds = 0 }, combatMs = 0, fightStart = nil, fightLast = 0,
            fightDmg = 0, lastFight = 0, recent = {}, top = 0, topBy = '', kills = 0, killMs = 0 }
    end
    fresh()

    local function endFight()
        local dur = math.max(1000, D.fightLast - D.fightStart)
        D.combatMs, D.lastFight, D.fightStart = D.combatMs + dur, D.fightDmg * 1000 / dur, nil
    end

    local function add(kind, n, what)
        local now = mq.gettime()
        if D.fightStart and now - D.fightLast > 8000 then endFight() end
        if not D.fightStart then D.fightStart, D.fightDmg = now, 0 end
        D.fightLast, D.fightDmg, D.total = now, D.fightDmg + n, D.total + n
        D.by[kind] = D.by[kind] + n
        table.insert(D.recent, { now, n })
        if n > D.top then D.top, D.topBy = n, what end
    end

    mq.event('axpDmgHit', '#*# for #1# points of #*#', function(line, amount)
        local n = tonumber(amount)
        if not n or n <= 0 then return end
        if line:find('^You ') then
            local spell = line:match(' damage by (.+)$')
            if spell then spell = spell:gsub('%s*%(.-%)$', ''):gsub('%.$', '') end
            add(spell and 'spell' or 'melee', n, spell or 'melee')
        elseif line:find(' by YOUR ', 1, true) then
            add('ds', n, 'damage shield')
        else
            local pet = mq.TLO.Me.Pet.CleanName() or ''
            if (pet ~= '' and line:sub(1, #pet + 1) == pet .. ' ') or line:sub(1, #ME + 2) == ME .. '`s' then add('pet', n, 'pet') end
        end
    end)
    mq.event('axpDmgDot', '#*# has taken #1# damage #2#', function(_, amount, rest)
        local n = tonumber(amount)
        if not n or n <= 0 then return end
        local spell = rest:match('^from your (.+)%.') or rest:match('^from (.+) by ' .. ME .. '%.')
        if spell then add('dot', n, spell) end
    end)

    function DPS.tick()
        local now = mq.gettime()
        if D.fightStart and now - D.fightLast > 8000 then endFight() end
        while D.recent[1] and now - D.recent[1][1] > 10000 do table.remove(D.recent, 1) end
    end
    function DPS.kill(secs) D.kills, D.killMs = D.kills + 1, D.killMs + secs * 1000 end
    function DPS.reset() fresh(); log('stats reset') end

    function DPS.fmt(n)
        n = n or 0
        if n >= 1e9 then return string.format('%.2fB', n / 1e9) elseif n >= 1e6 then return string.format('%.2fM', n / 1e6)
        elseif n >= 1e4 then return string.format('%.1fk', n / 1e3) end
        return tostring(math.floor(n + 0.5))
    end

    -- now: the last 10s of this fight; fight: this fight so far; last: the last fight; avg: per second of fighting
    function DPS.stats()
        local now = mq.gettime()
        local s = { now = 0, fight = 0, last = D.lastFight, total = D.total, by = D.by, top = D.top, topBy = D.topBy,
            kills = D.kills, killAvg = D.kills > 0 and D.killMs / D.kills / 1000 or 0, fighting = D.fightStart ~= nil,
            session = now - D.since }
        local combat = D.combatMs
        if D.fightStart then
            local el = math.max(1000, now - D.fightStart)
            local sum = 0
            for _, r in ipairs(D.recent) do sum = sum + r[2] end
            s.fight, s.now, combat = D.fightDmg * 1000 / el, sum * 1000 / math.min(10000, el), combat + el
        end
        s.avg = combat > 0 and D.total * 1000 / combat or 0
        s.hrs = s.session / 3600000
        s.xph = s.hrs > 0.02 and (totalXp() - D.xp0) / s.hrs or 0
        s.aaph = s.hrs > 0.02 and ((mq.TLO.Me.AAPointsTotal() or 0) * 100 + (mq.TLO.Me.PctAAExp() or 0) - D.aa0) / 100 / s.hrs or 0
        return s
    end

    -- ${AutoXP[dps]}: total|melee|spell|dot|pet|ds|top|top by|last fight DPS
    function DPS.line()
        return table.concat({ D.total, D.by.melee, D.by.spell, D.by.dot, D.by.pet, D.by.ds, D.top, D.topBy, math.floor(D.lastFight) }, '|')
    end
end

local draw, peersTick
do   -- the UI helpers stay out of the main chunk (LuaJIT allows it 200 locals)
-- ImGui -----------------------------------------------------------------------------------
local ON, OFF = {0.15, 0.55, 0.2, 1}, {0.3, 0.3, 0.3, 1}
local STATECOL = { IDLE = {0.7, 0.7, 0.7, 1}, TRAVEL = {0.4, 0.7, 1, 1}, FIGHT = {1, 0.4, 0.4, 1}, REST = {0.5, 1, 0.5, 1} }

-- SetTooltip takes a format string; pass text through %s so a literal % can't break it
local function tip(text) if text and ImGui.IsItemHovered() then ImGui.SetTooltip('%s', text) end end

local function toggle(label, key, help)
    local c = S[key] and ON or OFF
    ImGui.PushStyleColor(ImGuiCol.Button, c[1], c[2], c[3], c[4])
    if ImGui.Button(label, 70, 26) then S[key] = not S[key]; log('%s %s', label, S[key] and 'ON' or 'OFF') end
    ImGui.PopStyleColor()
    if help then tip(help) end
end

local ROLEHELP = {
    Tank = 'Tank: melee from the front, taunt when aggro slips, pick targets casters > healers > hybrids > melee,\nstun opener + stun-lock (Tank stuns), use Tank abilities (Bash, Disarm...), keep all mobs in front of you.',
    DPS = 'DPS: melee from behind, or cast from range (casters/priests); never taunt or stun-lock.\nUses DPS abilities, DoTs and nukes (DoT / Nuke duties; damage stuns and undead nukes count as nukes); the pet joins the fight.',
}
local function roleButton(r)
    local c = (S.role == r) and ON or OFF
    ImGui.PushStyleColor(ImGuiCol.Button, c[1], c[2], c[3], c[4])
    if ImGui.Button(r, 70, 26) and S.role ~= r then S.role = r; log('role %s', r) end
    ImGui.PopStyleColor()
    tip(ROLEHELP[r])
end

local function bar(frac, label) ImGui.ProgressBar(math.max(0, math.min(1, frac)), -1, 0, label) end

local function combo(label, cur, items)
    local out = cur
    if ImGui.BeginCombo(label, cur) then
        for _, it in ipairs(items) do
            local a, b = ImGui.Selectable(it, cur == it)
            local clicked = b; if clicked == nil then clicked = a end
            if clicked and cur ~= it then out = it end
        end
        ImGui.EndCombo()
    end
    return out
end

-- Group window ------------------------------------------------------------------------------
-- Every AutoXP publishes its character's status as the ${AutoXP} TLO: one '|'-separated string, rebuilt once a
-- second. The group window watches each DanNet peer's ${AutoXP} with a single observer (DanNet re-reads it at most
-- once a second and sends it only when it changed; a 5s heartbeat field tells a quiet peer from a gone one)
local drawPeers
do
    local FIELDS = { 'beat', 'cls', 'lvl', 'zone', 'hp', 'mana', 'endu', 'run', 'state', 'mode', 'role', 'duties',
        'tgt', 'tgtHp', 'haters', 'cast', 'flags', 'pet', 'petHp', 'cures', 'kills', 'xph', 'aaph', 'last', 'dps' }
    local DUTY = { H = 'Heal', C = 'CC', D = 'Debuff', N = 'Nuke', T = 'DoT', B = 'Buff', R = 'Rez' }
    local CURE = { P = 'Poison', D = 'Disease', C = 'Curse', X = 'Corruption' }
    -- FontAwesome glyphs (merged into the ImGui font) and EQ spell icons (A_SpellIcons cells)
    local FA = { BED = '\xef\x88\xb6', BOLT = '\xef\x83\xa7', MAGIC = '\xef\x83\x90', PAW = '\xef\x86\xb0',
        FLASK = '\xef\x83\x83', WARN = '\xef\x81\xb1', MAP = '\xef\x81\x81', PLAY = '\xef\x81\x8b',
        PAUSE = '\xef\x81\x8c', STOP = '\xef\x81\x8d', FEIGN = '\xef\x88\x9b', LOST = '\xef\x84\xa7' }
    local ICON = { invis = 18, ivu = 33, sick = 154 }   -- Invisibility, Invisibility versus Undead, Resurrection Sickness
    local P = { status = '', at = 0, readAt = 0, rows = {}, observing = {}, tried = {}, beat = {}, redo = {} }
    local anim

    local function buildStatus()
        local me = mq.TLO.Me
        local flags = ''
        if me.State() == 'HOVER' or me.Dead() then flags = flags .. 'D' end
        if me.Sitting() then flags = flags .. 'S' end
        if me.Invis(1)() then flags = flags .. 'I' end
        if me.Invis(2)() then flags = flags .. 'U' end
        if me.Stunned() then flags = flags .. 'Z' end
        if me.Feigning() then flags = flags .. 'F' end
        if mq.gettime() - (R.rezBusyAt or 0) < 5000 then flags = flags .. 'C' end   -- walking to or resurrecting a corpse
        for _, b in ipairs(SICK) do if me.Buff(b)() then flags = flags .. 'R'; break end end
        local cures = ''
        for _, c in ipairs({ { 'P', me.CountersPoison() }, { 'D', me.CountersDisease() }, { 'C', me.CountersCurse() }, { 'X', me.CountersCorruption() } }) do
            if (c[2] or 0) > 0 then cures = cures .. c[1] .. c[2] end
        end
        local duties = ''
        for _, d in ipairs({ { 'H', S.heal }, { 'C', S.cc }, { 'D', S.debuff }, { 'N', S.nuke }, { 'T', S.dot }, { 'B', S.buff }, { 'R', S.rez } }) do
            if d[2] then duties = duties .. d[1] end
        end
        local st = DPS.stats()
        local t, pet = mq.TLO.Target, me.Pet
        local hasPet = (pet.ID() or 0) > 0
        local v = {
            math.floor(mq.gettime() / 5000) % 100, me.Class.ShortName() or '', me.Level() or 0, mq.TLO.Zone.ShortName() or '',
            me.PctHPs() or 0, (me.MaxMana() or 0) > 0 and (me.PctMana() or 0) or -1,
            (me.MaxEndurance() or 0) > 0 and (me.PctEndurance() or 0) or -1,
            not R.running and 'stop' or R.paused and 'pause' or 'run', R.state or '', S.mode, S.role, duties,
            t() and (t.CleanName() or '') or '', t() and (t.PctHPs() or 0) or 0, #hostiles(),
            casting() and (me.Casting.Name() or '') or '', flags,
            hasPet and (pet.CleanName() or '') or '', hasPet and (pet.PctHPs() or 0) or 0, cures, R.kills,
            st.hrs > 0.02 and string.format('%.1f', st.xph) or '', st.hrs > 0.02 and string.format('%.2f', st.aaph) or '',
            (R.log[#R.log] or ''):sub(1, 110), math.floor(st.fighting and st.fight or st.last),
        }
        for i, x in ipairs(v) do v[i] = (tostring(x):gsub('[|$]', '/')) end
        return table.concat(v, '|')
    end

    local function parse(s)
        if not s or s == '' or s == 'NULL' then return nil end
        local d, n = {}, 0
        for f in (s .. '|'):gmatch('([^|]*)|') do n = n + 1; if FIELDS[n] then d[FIELDS[n]] = f end end
        if n < #FIELDS then return nil end
        for _, k in ipairs({ 'lvl', 'hp', 'mana', 'endu', 'tgtHp', 'haters', 'petHp', 'kills', 'dps' }) do d[k] = tonumber(d[k]) or 0 end
        return d
    end

    -- main loop, every pass: my status once a second; the peers (window open) once a second
    function peersTick()
        local now = mq.gettime()
        if now - P.at >= 1000 then P.at, P.status = now, buildStatus() end
        -- a running Hunter reads its groupmates even with both windows hidden: it waits for their buffs and rezzes
        if not S.showPeers and not S.showHud and not (R.running and S.mode == 'Hunter') then
            for peer in pairs(P.observing) do mq.cmdf('/dobserve %s -q AutoXP -drop', peer) end
            P.observing, P.rows = {}, {}
            return
        end
        if now - P.readAt < 1000 then return end
        P.readAt = now
        local rows = { { name = ME, me = true, d = parse(P.status), fresh = true } }
        if mq.TLO.Plugin('mq2dannet').IsLoaded() then
            local self = mq.TLO.DanNet.Name() or ''
            for peer in (mq.TLO.DanNet.Peers() or ''):gmatch('[^|]+') do
                if peer ~= self then
                    -- the DanNet TLO forgets the peer after one member: each read starts again from DanNet(peer)
                    if mq.TLO.DanNet(peer).ObserveSet('AutoXP')() then P.observing[peer] = true
                    elseif now - (P.tried[peer] or 0) > 10000 then P.tried[peer] = now; mq.cmdf('/dobserve %s -q AutoXP', peer) end
                    local d = parse(mq.TLO.DanNet(peer).Observe('AutoXP')())
                    local b = P.beat[peer]
                    if d and (not b or b.v ~= d.beat) then P.beat[peer] = { v = d.beat, at = now } end
                    -- a peer whose client restarted keeps its old observer here, frozen at the last status (Nhambuko
                    -- showed offline after reconnecting): one unchanged for 20s is dropped (at most every 30s) and set
                    -- up again 10s later
                    if P.observing[peer] and now - (P.beat[peer] and P.beat[peer].at or now) > 20000 and now - (P.redo[peer] or 0) > 30000 then
                        P.redo[peer], P.observing[peer], P.tried[peer] = now, nil, now
                        mq.cmdf('/dobserve %s -q AutoXP -drop', peer)
                    end
                    local n = peer:gsub('^[^_]*_', '')
                    table.insert(rows, { name = n:sub(1, 1):upper() .. n:sub(2), d = d,
                        fresh = d ~= nil and now - (P.beat[peer] and P.beat[peer].at or 0) < 15000 })
                end
            end
        end
        -- me first, then my group in group order, then everyone else by name
        local order = {}
        for i = 1, (mq.TLO.Group.Members() or 0) do order[mq.TLO.Group.Member(i).Name() or ''] = i end
        table.sort(rows, function(a, b)
            if (a.me or false) ~= (b.me or false) then return a.me == true end
            local oa, ob = order[a.name] or 99, order[b.name] or 99
            if oa ~= ob then return oa < ob end
            return a.name < b.name
        end)
        P.rows = rows
    end

    local function hpCol(pct)
        if pct >= 70 then return 0.2, 0.7, 0.25 elseif pct >= 35 then return 0.85, 0.7, 0.1 end
        return 0.85, 0.2, 0.2
    end

    local function pbar(pct, r, g, b)
        if pct < 0 then ImGui.TextDisabled('-'); return end
        ImGui.PushStyleColor(ImGuiCol.PlotHistogram, r, g, b, 1)
        ImGui.ProgressBar(math.max(0, math.min(1, pct / 100)), -1, 15, tostring(pct))
        ImGui.PopStyleColor()
    end

    local function details(r)
        local d = r.d
        if not d then return r.name .. ': no status - AutoXP is not running there, or DanNet has not answered yet' end
        local duties = {}
        for c in d.duties:gmatch('.') do table.insert(duties, DUTY[c] or c) end
        local lines = {
            string.format('%s  L%d %s  in %s', r.name, d.lvl, d.cls, d.zone),
            string.format('AutoXP %s: %s, mode %s, role %s', d.run, d.state, d.mode, d.role),
            'Duties: ' .. (#duties > 0 and table.concat(duties, ', ') or 'none'),
            string.format('Kills %d', d.kills) .. (d.xph ~= '' and ('   XP ' .. d.xph .. '%/h') or '') .. (d.aaph ~= '' and ('   AA ' .. d.aaph .. '/h') or ''),
        }
        if d.pet ~= '' then table.insert(lines, string.format('Pet: %s %d%%', d.pet, d.petHp)) end
        if d.last ~= '' then table.insert(lines, 'Last: ' .. d.last) end
        if not r.fresh then table.insert(lines, '(no update for 15s or more)') end
        return table.concat(lines, '\n')
    end

    local function drawRow(r)
        local d = r.d
        local dead = d and d.flags:find('D') ~= nil
        ImGui.TableNextRow()
        -- name (click: target them); the tooltip has the details
        ImGui.TableNextColumn()
        if dead then ImGui.PushStyleColor(ImGuiCol.Text, 1, 0.35, 0.35, 1)
        elseif not d or not r.fresh then ImGui.PushStyleColor(ImGuiCol.Text, 0.55, 0.55, 0.55, 1)
        else ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 1, 1) end
        local _, pressed = ImGui.Selectable(r.name .. '##grp' .. r.name, false)
        if pressed then mq.cmdf('/target pc =%s', r.name) end
        ImGui.PopStyleColor()
        tip(details(r))
        ImGui.TableNextColumn(); if d then ImGui.Text(string.format('%d %s', d.lvl, d.cls)) end
        ImGui.TableNextColumn(); if d then pbar(d.hp, hpCol(d.hp)) end
        ImGui.TableNextColumn(); if d then pbar(d.mana, 0.25, 0.45, 0.95) end
        ImGui.TableNextColumn(); if d then pbar(d.endu, 0.85, 0.6, 0.15) end
        ImGui.TableNextColumn(); if d and d.dps > 0 then ImGui.Text(DPS.fmt(d.dps)); tip('This fight (or the last one)') end
        -- AutoXP: running / paused / stopped, and its state
        ImGui.TableNextColumn()
        if d then
            local ic, c = FA.PLAY, { 0.4, 0.9, 0.4 }
            if d.run == 'pause' then ic, c = FA.PAUSE, { 1, 0.8, 0.3 } elseif d.run == 'stop' then ic, c = FA.STOP, { 0.6, 0.6, 0.6 } end
            ImGui.TextColored(c[1], c[2], c[3], 1, ic); tip('AutoXP ' .. d.run)
            ImGui.SameLine(0, 4)
            local sc = STATECOL[d.state] or { 1, 1, 0.5, 1 }
            ImGui.TextColored(sc[1], sc[2], sc[3], 1, d.state)
        end
        ImGui.TableNextColumn(); if d and d.tgt ~= '' then ImGui.Text(string.format('%s %d%%', d.tgt, d.tgtHp)) end
        -- status icons
        ImGui.TableNextColumn()
        if not d or not r.fresh then
            ImGui.TextColored(0.55, 0.55, 0.55, 1, FA.LOST); tip(d and 'No update for 15s or more' or 'No status: AutoXP is not running there?')
        else
            local first = true
            local function nxt() if not first then ImGui.SameLine(0, 4) end; first = false end
            local function fa(icon, cr, cg, cb, text) nxt(); ImGui.TextColored(cr, cg, cb, 1, icon); tip(text) end
            local function eq(cell, text)
                anim = anim or mq.FindTextureAnimation('A_SpellIcons')
                if not anim then return end
                nxt(); anim:SetTextureCell(cell); ImGui.DrawTextureAnimation(anim, 16, 16); tip(text)
            end
            if dead then nxt(); ImGui.TextColored(1, 0.3, 0.3, 1, 'DEAD') end
            if d.flags:find('R') then eq(ICON.sick, 'Resurrection Sickness') end
            if d.flags:find('I') then eq(ICON.invis, 'Invisible') end
            if d.flags:find('U') then eq(ICON.ivu, 'Invisible versus undead') end
            if d.haters > 0 then
                fa(FA.WARN, 1, 0.35, 0.35, d.haters .. ' on extended target')
                ImGui.SameLine(0, 2); ImGui.TextColored(1, 0.35, 0.35, 1, tostring(d.haters))
            end
            if d.cast ~= '' then fa(FA.MAGIC, 0.75, 0.55, 1, 'Casting ' .. d.cast) end
            if d.flags:find('S') then fa(FA.BED, 0.6, 0.8, 1, 'Sitting') end
            if d.flags:find('Z') then fa(FA.BOLT, 1, 0.9, 0.2, 'Stunned') end
            if d.flags:find('F') then fa(FA.FEIGN, 0.7, 0.7, 0.7, 'Feigning death') end
            if d.pet ~= '' then
                local pr, pg, pb = hpCol(d.petHp)
                fa(FA.PAW, pr, pg, pb, string.format('Pet %s %d%%', d.pet, d.petHp))
            end
            if d.cures ~= '' then
                local out = {}
                for k, n in d.cures:gmatch('(%a)(%d+)') do table.insert(out, (CURE[k] or k) .. ' ' .. n) end
                fa(FA.FLASK, 0.4, 1, 0.6, 'Needs a cure: ' .. table.concat(out, ', '))
            end
            if d.zone ~= (mq.TLO.Zone.ShortName() or '') then fa(FA.MAP, 1, 0.65, 0.2, 'In ' .. d.zone) end
        end
        -- what it last did (its latest log line)
        ImGui.TableNextColumn()
        if d and d.last ~= '' then ImGui.TextDisabled(d.last:sub(10)); tip(d.last) end
    end

    function drawPeers()
        if not S.showPeers then return end
        ImGui.SetNextWindowSize(860, 215, ImGuiCond.FirstUseEver)
        local open, show = ImGui.Begin('AutoXP Group##axpgroup', true)
        if not open then S.showPeers = false end
        if show then
            local okB, errB = pcall(function()
            local sum = 0
            for _, r in ipairs(P.rows) do if r.d and r.fresh then sum = sum + r.d.dps end end
            if sum > 0 then ImGui.TextColored(0.4, 0.8, 1, 1, 'Group DPS ' .. DPS.fmt(sum)); tip('Each character\'s DPS this fight (or the last one), added up') end
            local tf = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInnerV, ImGuiTableFlags.SizingFixedFit, ImGuiTableFlags.Resizable)
            if ImGui.BeginTable('##axppeers', 10, tf) then
                ImGui.TableSetupColumn('Name', 0, 80)
                ImGui.TableSetupColumn('Lvl', 0, 55)
                ImGui.TableSetupColumn('HP', 0, 55)
                ImGui.TableSetupColumn('Mana', 0, 55)
                ImGui.TableSetupColumn('End', 0, 55)
                ImGui.TableSetupColumn('DPS', 0, 50)
                ImGui.TableSetupColumn('AutoXP', 0, 80)
                ImGui.TableSetupColumn('Target', 0, 140)
                ImGui.TableSetupColumn('Status', 0, 120)
                ImGui.TableSetupColumn('Doing', ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableHeadersRow()
                for _, r in ipairs(P.rows) do drawRow(r) end
                ImGui.EndTable()
            end
            end)
            if not okB then oops('group window', errB) end
        end
        ImGui.End()
    end

    -- HUD: a small see-through window with my DPS and session stats; right-click for Reset stats / Hide HUD
    -- a groupmate casting in its BUFF state (from its ${AutoXP} status), for up to 60s each - the Hunter waits for it.
    -- Not a bard: it sings in every state, so a song isn't buffing
    function DPS.peerBuffing()
        local now = mq.gettime()
        R.buffHold = R.buffHold or {}
        for _, r in ipairs(P.rows) do
            if not r.me and r.d and r.fresh and r.d.state == 'BUFF' and r.d.cast ~= '' and r.d.run == 'run'
                and mq.TLO.Spawn('pc =' .. r.name).Class.ShortName() ~= 'BRD' then
                R.buffHold[r.name] = R.buffHold[r.name] or now
                if now - R.buffHold[r.name] < 60000 then return r.name end
            else
                R.buffHold[r.name] = nil
            end
        end
    end

    -- a groupmate walking to or resurrecting a corpse (its ${AutoXP} 'C' flag), for up to 3 minutes each - the Hunter waits
    function DPS.peerRezzing()
        local now = mq.gettime()
        R.rezHold = R.rezHold or {}
        for _, r in ipairs(P.rows) do
            if not r.me and r.d and r.fresh and r.d.flags:find('C') and r.d.run == 'run' then
                R.rezHold[r.name] = R.rezHold[r.name] or now
                if now - R.rezHold[r.name] < 180000 then return r.name end
            else
                R.rezHold[r.name] = nil
            end
        end
    end

    function DPS.drawHud()
        if not S.showHud then return end
        ImGui.SetNextWindowBgAlpha(0.6)
        local wf = bit32.bor(ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoFocusOnAppearing, ImGuiWindowFlags.NoNav)
        local _, show = ImGui.Begin('AutoXP HUD##axphud', true, wf)
        if show then
            local okB, errB = pcall(function()
            local s, f = DPS.stats(), DPS.fmt
            local sc = STATECOL[R.state] or { 1, 1, 0.5, 1 }
            local secs = math.floor(s.session / 1000)
            ImGui.TextColored(1, 0.85, 0.4, 1, ME)
            ImGui.SameLine(); ImGui.TextColored(sc[1], sc[2], sc[3], 1, not R.running and 'STOPPED' or R.paused and 'PAUSED' or R.state)
            ImGui.SameLine(); ImGui.TextDisabled(string.format('%d:%02d:%02d', math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60))
            tip('Session time (since load or Reset stats)')
            ImGui.TextDisabled('DPS'); ImGui.SameLine(); ImGui.TextColored(0.4, 1, 0.4, 1, f(s.now)); tip('The last 10 seconds of this fight')
            ImGui.SameLine(); ImGui.TextDisabled('fight'); ImGui.SameLine(); ImGui.Text(f(s.fight)); tip('This fight so far')
            ImGui.SameLine(); ImGui.TextDisabled('last'); ImGui.SameLine(); ImGui.Text(f(s.last)); tip('The last fight')
            ImGui.SameLine(); ImGui.TextDisabled('avg'); ImGui.SameLine(); ImGui.Text(f(s.avg)); tip('Per second of fighting, this session')
            if s.total > 0 then
                local parts = {}
                for _, k in ipairs({ 'melee', 'spell', 'dot', 'pet', 'ds' }) do
                    if s.by[k] > 0 then table.insert(parts, string.format('%s %d%%', k, math.floor(s.by[k] * 100 / s.total + 0.5))) end
                end
                ImGui.TextDisabled('Dmg'); ImGui.SameLine(); ImGui.Text(f(s.total) .. '   ' .. table.concat(parts, '  '))
                tip('Damage this session: melee, spells, DoTs, pets, damage shields')
                ImGui.TextDisabled('Top'); ImGui.SameLine(); ImGui.Text(f(s.top) .. '  ' .. s.topBy)
            end
            local kills = tostring(s.kills)
            if s.hrs > 0.02 then kills = kills .. string.format('  %.0f/h', s.kills / s.hrs) end
            if s.kills > 0 then kills = kills .. string.format('  %.0fs each', s.killAvg) end
            ImGui.TextDisabled('Kills'); ImGui.SameLine(); ImGui.Text(kills)
            local xp = string.format('%.1f%%/h', s.xph)
            if s.xph > 0 then
                local h = (100 - (mq.TLO.Me.PctExp() or 0)) / s.xph
                xp = xp .. string.format('  level in %dh%02dm', math.floor(h), math.floor(h * 60) % 60)
            end
            ImGui.TextDisabled('XP'); ImGui.SameLine(); ImGui.Text(xp .. string.format('   AA %.2f/h', s.aaph))
            local sum, n = 0, 0
            for _, r in ipairs(P.rows) do if r.d and r.fresh and r.d.dps > 0 then sum, n = sum + r.d.dps, n + 1 end end
            if n > 1 then
                ImGui.TextDisabled('Group'); ImGui.SameLine(); ImGui.TextColored(0.4, 0.8, 1, 1, f(sum) .. ' DPS')
                tip('Each character\'s DPS this fight (or the last one), added up')
            end
            if ImGui.BeginPopupContextWindow() then
                if ImGui.MenuItem('Reset stats') then DPS.reset() end
                if ImGui.MenuItem('Hide HUD') then S.showHud = false end
                ImGui.EndPopup()
            end
            end)
            if not okB then oops('HUD', errB) end
        end
        ImGui.End()
    end

    -- ${AutoXP}: this character's packed status (what the group window of every other client reads);
    -- ${AutoXP[dps]}: my damage breakdown. A TLO function returns the MQ type name and the value
    pcall(mq.AddTopLevelObject, 'AutoXP', function(idx)
        if idx == 'dps' then return 'string', DPS.line() end
        return 'string', P.status
    end)
end

function draw()
    if not R.open then return end
    -- a spell list edited here is yours: gem changes and the spell book leave it alone
    local function listInput(label, key)
        local v = ImGui.InputText(label, S[key])
        if v ~= S[key] then S[key] = v; S.userLists[key] = true end
    end
    local show
    R.open, show = ImGui.Begin('AutoXP', R.open)
    if show then
        local okBody, errBody = pcall(function()
        if not R.running then
            if ImGui.Button('Start', 70, 26) then start() end
        else
            if ImGui.Button(R.paused and 'Resume' or 'Pause', 70, 26) then setPaused(not R.paused) end
            ImGui.SameLine()
            if ImGui.Button('Stop', 70, 26) then stopAll('user') end
        end
        ImGui.SameLine()
        local c = STATECOL[R.state] or {1, 1, 0.5, 1}
        ImGui.TextColored(c[1], c[2], c[3], c[4], string.format('%s%s', R.state, R.paused and ' (paused)' or ''))

        ImGui.SetNextItemWidth(110)
        local m = combo('Mode', S.mode, MODES)
        if m ~= S.mode then S.mode = m; log('mode %s', m); if m == 'Hunter' then huntHere() end end
        updateMapRadius()
        ImGui.Text('Role:'); ImGui.SameLine(); roleButton('Tank'); ImGui.SameLine(); roleButton('DPS')
        ImGui.SameLine()
        toggle('Backup', 'backupTank', 'Backup tank: while the group main tank is dead or out of the zone, tank in its place\n(Tank role: taunt, Tank abilities, mobs in front, target priority); back to DPS once it is alive\nand nothing is on the extended target list.')
        ImGui.Text('Duties:'); ImGui.SameLine()
        toggle('Heal', 'heal', 'Heal: heal yourself / group members below the Healing thresholds,\nand use Emergency abilities (Lay on Hands) below the emergency threshold.')
        ImGui.SameLine()
        toggle('CC', 'cc', 'CC: mez adds (Mez list), interrupt a casting target and stun adds\nthat are not your current target (CC stuns list). Mezzed adds are left for last.')
        ImGui.SameLine()
        toggle('Debuff', 'debuff', 'Debuff: slow, malo/tash and cripple the target once each (Debuffs list).\nThe best of each line in your spell book is kept memorized.')
        ImGui.SameLine()
        toggle('Nuke', 'nuke', 'Nuke: cast nukes at the target in a fight (Nukes list: damage stuns and swarm pets too).\nThe best nuke and undead nuke in your spell book are kept memorized.')
        ImGui.SameLine()
        toggle('DoT', 'dot', 'DoT: put each damage-over-time spell on the target once (DoTs list) while it is above 40%.')
        ImGui.SameLine()
        toggle('Rez', 'rez', 'Rez: in a fight, Call of the Wild on a dead group member (no exp, they can still get an exp rez).\nOut of combat, an exp rez AA (Blessing of Resurrection, Rejuvenation of Spirit) or your best rez spell, once per corpse.')
        ImGui.SameLine()
        toggle('Buff', 'buff', 'Buff: keep group members buffed too. HP, AC, resist and Unity buffs go to everyone,\nhaste, attack and strength to melee, mana regen to classes that use mana.')
        ImGui.Separator()

        ImGui.Text(string.format('%s  L%d %s  %s', mq.TLO.Me.CleanName() or '?', mq.TLO.Me.Level() or 0, mq.TLO.Me.Class.ShortName() or '', mq.TLO.Zone.ShortName() or '?'))
        -- DanNet peers (refreshed once a second; "server_name" shown as "Name")
        if mq.gettime() - (R.peersAt or 0) > 1000 then
            R.peersAt, R.peers = mq.gettime(), nil
            if mq.TLO.Plugin('mq2dannet').IsLoaded() then
                local names = {}
                for peer in (mq.TLO.DanNet.Peers() or ''):gmatch('[^|]+') do
                    local n = peer:gsub('^[^_]*_', '')
                    table.insert(names, n:sub(1, 1):upper() .. n:sub(2))
                end
                table.sort(names)
                R.peers = names
            end
        end
        if ImGui.SmallButton(S.showHud and 'Hide HUD##hud' or 'Show HUD##hud') then S.showHud = not S.showHud end
        tip('AutoXP HUD: my DPS (now, this fight, last fight, session), damage breakdown, kills and XP / AA per hour.\nRight-click it to reset the stats.')
        if R.peers then
            ImGui.SameLine()
            if ImGui.SmallButton(S.showPeers and 'Hide group##grp' or 'Show group##grp') then S.showPeers = not S.showPeers end
            tip('AutoXP Group window: HP, mana, endurance, DPS, AutoXP state, target and status of every DanNet peer.')
            ImGui.SameLine()
            ImGui.TextColored(0.5, 0.8, 1, 1, string.format('DanNet (%d): %s', #R.peers, table.concat(R.peers, ' ')))
        end
        bar(hp() / 100, string.format('HP %d%%', hp()))
        bar(mana() / 100, string.format('Mana %d%%', mana()))
        bar((mq.TLO.Me.PctExp() or 0) / 100, string.format('XP %.2f%%', mq.TLO.Me.PctExp() or 0))
        if SP.scanning then
            ImGui.TextDisabled(string.format('Checking spell book... %d%%', math.floor(100 * SP.nextId / SPELL_ID_MAX)))
        elseif #SP.list > 0 then
            ImGui.PushStyleColor(ImGuiCol.Text, 1, 0.75, 0.2, 1)
            local open = ImGui.TreeNode(string.format('Missing %d spell(s) at or below L%d###missingspells', #SP.list, SP.level))
            ImGui.PopStyleColor()
            tip('Base-rank class spells at or below your level that are not in your spell book\nor combat abilities. Most are sold by your class spell vendors (Plane of Knowledge).')
            if open then
                for _, s in ipairs(SP.list) do ImGui.Text(string.format('L%-3d %s', s.level, s.name)) end
                if ImGui.SmallButton('Rescan') then startSpellScan() end
                ImGui.TreePop()
            end
        end
        if R.started > 0 then
            ImGui.Text(string.format('Kills %d   XP +%.3f%%   AA +%.3f%%   %.1f min', R.kills, totalXp() - R.xp0,
                (mq.TLO.Me.PctAAExp() or 0) - R.aa0, (mq.gettime() - R.started) / 60000))
        end
        local t = spawn(R.targetId)
        if alive(t) then
            ImGui.Text(string.format('Target: %s (L%d %s %s) %.0f%s', R.targetName, t.Level() or 0, t.Class.ShortName() or '?', t.ConColor() or '?', t.Distance() or 0,
                R.targetId == R.pickId and '  - your pick' or ''))
            bar((t.PctHPs() or 0) / 100, string.format('%d%%', t.PctHPs() or 0))
        end
        local hs = hostiles()
        if #hs > 1 then
            ImGui.TextColored(1, 0.6, 0.2, 1, string.format('%d hostiles:', #hs))
            for _, s in ipairs(hs) do ImGui.Text(string.format('  %s %s %d%% (prio %d)', s.CleanName(), s.Class.ShortName() or '?', s.PctHPs() or 0, prio(s))) end
        end

        -- only the tabs scroll: the status above and the Save button below stay in view
        ImGui.BeginChild('##tabs', 0, -ImGui.GetFrameHeightWithSpacing(), false)
        R.inChild = true
        if ImGui.BeginTabBar('tabs') then
            if ImGui.BeginTabItem('General') then
                local zi = zoneInfo(S.zone)
                ImGui.Text('Hunt zone:'); ImGui.SameLine()
                ImGui.TextColored(0.4, 0.8, 1, 1, zi and string.format('%s (%s)', zi.name, zi.short) or S.zone)
                if zi then ImGui.SameLine(); ImGui.TextColored(0.6, 0.6, 0.6, 1, '- ' .. zi.exp) end
                if ImGui.Button('Use current zone') then S.zone = mq.TLO.Zone.ShortName() or S.zone; log('hunt zone %s', S.zone) end
                ImGui.SameLine()
                ImGui.SameLine()
                ImGui.SetNextItemWidth(220)
                if ImGui.BeginCombo('##zonepick', 'Browse by expansion...', ImGuiComboFlags.HeightLarge) then
                    local lastExp
                    for _, z in ipairs(ZONES) do
                        if z.exp ~= lastExp then ImGui.TextColored(1, 0.8, 0.3, 1, z.exp); lastExp = z.exp end
                        local a, b = ImGui.Selectable(string.format('   %s  (%s)##z%d', z.name, z.short, z.id), S.zone == z.short)
                        local clicked = b; if clicked == nil then clicked = a end
                        if clicked and S.zone ~= z.short then S.zone = z.short; log('hunt zone %s (%s)', z.name, z.short) end
                    end
                    ImGui.EndCombo()
                end
                ImGui.SetNextItemWidth(260)
                R.zoneFilter = ImGui.InputText('Search zones', R.zoneFilter or '')
                local f = (R.zoneFilter or ''):lower()
                if #f >= 2 then
                    local shown = 0
                    for _, z in ipairs(ZONES) do
                        if z.name:lower():find(f, 1, true) or z.short:find(f, 1, true) then
                            shown = shown + 1
                            if shown > 15 then ImGui.TextColored(0.6, 0.6, 0.6, 1, '   ...more, keep typing'); break end
                            local a, b = ImGui.Selectable(string.format('   %s  (%s)  - %s##s%d', z.name, z.short, z.exp, z.id), S.zone == z.short)
                            local clicked = b; if clicked == nil then clicked = a end
                            if clicked then S.zone = z.short; R.zoneFilter = ''; log('hunt zone %s (%s)', z.name, z.short) end
                        end
                    end
                    if shown == 0 then ImGui.TextColored(1, 0.5, 0.5, 1, '   no matching zones') end
                end
                S.travel = ImGui.Checkbox('Travel there first (EasyFind)', S.travel)
                S.minlvl = ImGui.SliderInt('Min level', S.minlvl, 1, 130)
                S.maxlvl = ImGui.SliderInt('Max level', S.maxlvl, S.minlvl, 130)
                S.radius = ImGui.SliderInt('Pull radius', S.radius, 100, 5000)
                S.avoidRadius = ImGui.SliderInt('Alone radius', S.avoidRadius, 40, 200)
                tip('Hunter pulls the closest mob in level range within the pull radius, preferring one with no other NPC this close to it, and only one whose walking route passes no other mob this close.')
                ImGui.SetNextItemWidth(110)
                local pm = combo('Pull with', S.pullMethod, PULLS)
                if pm ~= S.pullMethod then S.pullMethod = pm; log('pull with %s', pm) end
                tip('Hunter pulls. Auto: the pull spell, else a ranged item (bow/throwing), else an ability marked Pull, else walk in.')
                local pp = pullPlan()
                ImGui.SameLine(); ImGui.TextDisabled(pp and string.format('(%s: %s, range %d)', pp.how:lower(), pp.name, pp.range) or '(walk in)')
                listInput('Pull spell', 'pullSpell')
                S.pullDist = ImGui.SliderInt('Pull distance', S.pullDist, 40, 200)
                tip('Pull from this far at most (and never past 80% of the pull range); moves closer if the pull fails.')
                S.assistName = ImGui.InputText('Main assist', S.assistName)
                tip('Assist mode: whose target to attack. Blank = the group main assist (a Tank-role AutoXP sets itself).')
                S.assistAt = ImGui.SliderInt('Assist at %', S.assistAt, 1, 100)
                S.chaseName = ImGui.InputText('Chase target', S.chaseName)
                tip('Chase mode: who to follow and assist. Blank = the group main tank (a Tank-role AutoXP sets itself).')
                S.chaseDist = ImGui.SliderInt('Chase distance', S.chaseDist, 10, 200)
                S.restPct = ImGui.SliderInt('Rest below %', S.restPct, 5, 95)
                tip('Sit to rest / med when HP or mana drops below this out of combat (any mode; Chase only next to the leader).')
                S.restTo = ImGui.SliderInt('Rest until %', S.restTo, 20, 100)
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Spells') then
                ImGui.SetNextItemWidth(110)
                local st = combo('Combat style', S.style, { 'Auto', 'Melee', 'Ranged' })
                if st ~= S.style then S.style = st; log('combat style %s', st) end
                tip('Auto: casters and priests (WIZ MAG NEC ENC CLR DRU SHM) cast from range, everyone else melees.')
                ImGui.SameLine(); ImGui.TextDisabled(ranged() and '(ranged)' or '(melee)')
                if ranged() then S.castRange = ImGui.SliderInt('Cast range', S.castRange, 30, 200) end
                listInput('Nukes (DPS)', 'nukes')
                listInput('Twincast nukes, in order', 'twincastNukes')
                tip('Under a twincast buff: the first ready one of these, and no other nuke until it ends. Empty: the most expensive ready nuke.')
                listInput('Improved Twincast nukes, in order', 'itNukes')
                tip('Under Improved Twincast (a burn): these instead of the Twincast list.')
                listInput('DoTs (DPS, once per target)', 'dots')
                listInput('Debuffs: slow, malo, cripple (once per target)', 'debuffs')
                listInput('Mez (CC adds)', 'mez')
                S.petSpell = ImGui.InputText('Pet summon', S.petSpell)
                S.usePet = ImGui.Checkbox('Use pet', S.usePet)
                ImGui.SameLine(); S.shrinkPet = ImGui.Checkbox('Shrink pet', S.shrinkPet)
                S.chaseLoot = ImGui.Checkbox('Chase loot', S.chaseLoot)
                tip('Out of fights: loot my own chase drops (chaseloot.lua) from Advanced Loot; the group leader also gives the shared ones to himself.')
                tip('Shrink each new pet (Diminutive Companion, Shrink) down to the smallest it goes, out of fights.')
                S.nukeManaMin = ImGui.SliderInt('Nuke above mana %', S.nukeManaMin, 0, 100)
                tip('Under it only lifetaps are cast (they heal). Under Gift of Mana (the next spell is free) any mana will do.')
                S.dotManaMin = ImGui.SliderInt('DoTs above mana %', S.dotManaMin, 0, 100)
                tip('DoTs (not lifetaps) wait under this.')
                listInput('Mana spells (Gather Zeal, Traumatic Exchange)', 'manaSpells')
                S.manaPct = ImGui.SliderInt('Mana tools below mana %', S.manaPct, 10, 95)
                tip('Mana spells, Mana abilities and Modulation Shards under this.\nOne that costs health keeps 20% HP back (30% in a fight).')
                listInput('Tank stuns and hate (opener / stun-lock / lost aggro)', 'stuns')
                listInput('CC stuns (adds / interrupts)', 'ccStuns')
                S.stunCooldown = ImGui.Checkbox('Stun on cooldown during fights (Tank)', S.stunCooldown)
                listInput('Combat buffs (recast in fight)', 'combatBuffs')
                listInput('Tank buffs (kept on the main tank in fights)', 'tankBuffs')
                tip('Short buffs for the group main tank (damage shields, Moroseness), recast when your cast of it runs out.')
                if mq.TLO.Me.Class.ShortName() == 'BRD' then
                    listInput('Songs (kept going, first = most important)', 'songs')
                    listInput('Rest songs (no mobs on XTarget: regen)', 'restSongs')
                    tip("Filled from the memorized group/self songs in gem order. Selo's Sonata (AA) is kept up for the group too.")
                    S.songManaMin = ImGui.SliderInt('Songs that cost mana above mana %', S.songManaMin, 0, 100)
                end
                listInput('Buffs', 'buffs')
                tip('Filled from the spell book: HP, stat, resist, haste, Unity and proc buffs of 10+ minutes, best of each line.\nHaste/attack/strength only on melee, mana regen only on classes with mana; group members with the Buff duty.\nOnce you edit it, the book no longer refills it.')
                S.memBuffs = ImGui.Checkbox('Memorize missing buffs (borrows the last gem, then puts it back)', S.memBuffs)
                S.useTaunt = ImGui.Checkbox('Taunt when aggro < 100% (Tank)', S.useTaunt)
                S.prioritize = ImGui.Checkbox('Tank target priority: casters > healers > hybrids > melee', S.prioritize)
                S.keepInFront = ImGui.Checkbox('Reposition so all mobs are in front of me (melee)', S.keepInFront)
                if ImGui.Button('Fill from memorized gems') then S.userLists = {}; fillFromGems() end
                tip('Refills every spell list from the gems and the book, including lists you edited (they stop being yours).\nA list you edit keeps your order when the gems change.')
                S.autoMem = ImGui.Checkbox('Auto-memorize spell upgrades and nukes (out of combat)', S.autoMem)
                tip('Swaps a memorized spell for a higher-level scribed spell of the same kind (e.g. Stun over Cease),\nand keeps the best nuke and undead nuke memorized over a self-buff gem.\nSpell lists refresh from the gems whenever they change.')
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Abilities') then
                if ImGui.Button('Scan class abilities') then R.wantScan = true end
                tip('Reads skills, disciplines and class AAs and sorts them by what their spells do.\nRoles you pick yourself are kept on a rescan; older ranks of a line are set Off.')
                ImGui.SameLine(); ImGui.Text(string.format('%d found', #S.abilities))
                ImGui.SameLine()
                if ImGui.Button('Burn now (60s)') then R.burnUntil = mq.gettime() + 60000; log('burn: manual, 60s') end
                S.burnNamed = ImGui.Checkbox('Burn on named', S.burnNamed); ImGui.SameLine()
                S.burnLevel = ImGui.Checkbox('Burn at/above my level', S.burnLevel); ImGui.SameLine()
                S.burnAdds = ImGui.Checkbox('Burn on mobs:', S.burnAdds); ImGui.SameLine(); ImGui.SetNextItemWidth(110)
                S.burnCount = ImGui.SliderInt('##burnCount', S.burnCount, 2, 10)
                tip('Burn once this many mobs are on the extended target list.')
                S.defPct = ImGui.SliderInt('Defense below HP %', S.defPct, 10, 90)
                tip('Defense (mitigate) abilities below this. Sustained ones (Carapace, Mantle) also while tanking a named or 2+ mobs.')
                S.panicPct = ImGui.SliderInt('Panic below HP %', S.panicPct, 5, 60)
                tip('Defense (panic) abilities - short big absorbs and blocks (Spurn, Deflection) - below this.')
                S.endPct = ImGui.SliderInt('Endurance abilities below %', S.endPct, 5, 90)
                ImGui.SetNextItemWidth(120)
                S.abilFilter = combo('Show##abf', S.abilFilter, SHOWROLES)
                local older = 0
                for _, a in ipairs(S.abilities) do if a.note == 'older rank' or a.note == 'low level' then older = older + 1 end end
                if older > 0 then
                    ImGui.SameLine()
                    R.showOld = ImGui.Checkbox(string.format('show %d older / low-level', older), R.showOld or false)
                end
                ImGui.Separator()
                local move
                for i, a in ipairs(S.abilities) do
                    if (S.abilFilter == 'All' or a.role == S.abilFilter) and (R.showOld or (a.note ~= 'older rank' and a.note ~= 'low level')) then
                        local on = a.enabled ~= false
                        local c = on and ON or OFF
                        ImGui.PushStyleColor(ImGuiCol.Button, c[1], c[2], c[3], c[4])
                        if ImGui.Button(string.format('%s##ab%d', on and 'ON' or 'OFF', i), 44, 20) then
                            a.enabled = not on; log('%s %s', a.name, a.enabled and 'ON' or 'OFF'); save()
                        end
                        ImGui.PopStyleColor()
                        ImGui.SameLine(); ImGui.SetNextItemWidth(95)
                        local r = combo('##role' .. i, a.role, ROLES)
                        if r ~= a.role then a.role, a.userRole, a.note = r, true, nil; log('%s -> %s', a.name, r); save() end
                        ImGui.SameLine(); if ImGui.SmallButton('^##up' .. i) and i > 1 then move = { i, i - 1 } end
                        ImGui.SameLine(); if ImGui.SmallButton('v##dn' .. i) and i < #S.abilities then move = { i, i + 1 } end
                        ImGui.SameLine()
                        local st, why, secs = abilityStatus(a)
                        local ready = st == 'ready'
                        ImGui.TextColored(ready and 0.5 or 0.6, ready and 1 or 0.6, ready and 0.5 or 0.6, 1,
                            string.format('%s  (%s%s%s)', a.name, a.kind, a.tier and (', ' .. a.tier) or '', a.note and (', ' .. a.note) or ''))
                        tip(string.format('%s\n%s%s', ABILUSE[a.role] or '', why, secs > 0 and (' - ' .. fmtSecs(secs) .. ' left') or ''))
                    end
                end
                if move then
                    S.abilities[move[1]], S.abilities[move[2]] = S.abilities[move[2]], S.abilities[move[1]]
                    S.abilOrdered = true; save()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Healing') then
                listInput('Heals (best first)', 'healSpells')
                S.selfHealPct = ImGui.SliderInt('Heal self below %', S.selfHealPct, 5, 95)
                S.tankHealPct = ImGui.SliderInt('Heal main tank below %', S.tankHealPct, 5, 95)
                tip('The group main tank is healed below this; it comes first when it is the most behind its threshold.')
                S.groupHealPct = ImGui.SliderInt('Heal group below %', S.groupHealPct, 5, 95)
                S.emergencyPct = ImGui.SliderInt('Emergency abilities below %', S.emergencyPct, 5, 60)
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Log') then
                -- newest on top
                for i = #R.log, math.max(1, #R.log - 30), -1 do ImGui.TextWrapped(R.log[i]) end
                ImGui.EndTabItem()
            end
            ImGui.EndTabBar()
        end
        R.inChild = false
        ImGui.EndChild()
        if ImGui.Button('Save settings') then save(); log('settings saved') end
        end)
        if not okBody then
            oops('window', errBody)
            if R.inChild then R.inChild = false; ImGui.EndChild() end
        end
    end
    ImGui.End()
    local okP, errP = pcall(drawPeers)
    if not okP then oops('group window', errP) end
    local okH, errH = pcall(DPS.drawHud)
    if not okH then oops('HUD', errH) end
    if not R.open then R.terminate = true end
end
end

mq.imgui.init('AutoXP', draw)
mq.bind('/autoxp', function(cmd, a1, a2)
    local duties = { heal = true, cc = true, debuff = true, nuke = true, dot = true, buff = true, rez = true }
    if cmd == 'start' then start() elseif cmd == 'stop' then stopAll('command')
    elseif cmd == 'pause' then setPaused(true) elseif cmd == 'resume' then setPaused(false)
    elseif cmd == 'spells' then startSpellScan(); log('checking spell book...')
    elseif cmd == 'burn' then R.burnUntil = mq.gettime() + 60000; log('burn: manual, 60s')
    elseif cmd == 'show' then R.open = true elseif cmd == 'scan' then R.wantScan = true elseif cmd == 'save' then save(); log('settings saved')
    elseif cmd == 'mode' and a1 then
        for _, m in ipairs(MODES) do
            if m:lower() == a1:lower() then
                local was = S.mode
                S.mode = m; log('mode %s', m)
                if m == 'Hunter' and was ~= 'Hunter' then huntHere() end
            end
        end
    elseif cmd == 'role' and a1 and (a1:lower() == 'tank' or a1:lower() == 'dps') then S.role = a1:lower() == 'tank' and 'Tank' or 'DPS'; log('role %s', S.role)
    elseif cmd == 'tank' then S.role = 'Tank'; log('role Tank') elseif cmd == 'dps' then S.role = 'DPS'; log('role DPS')
    elseif cmd == 'group' then S.showPeers = not S.showPeers
    elseif cmd == 'hud' then S.showHud = not S.showHud
    elseif cmd == 'backup' then S.backupTank = (a1 == nil and not S.backupTank) or a1 == 'on'; log('backup tank %s', S.backupTank and 'ON' or 'OFF')
    elseif cmd == 'set' and a1 and a2 and S[a1] ~= nil and type(S[a1]) ~= 'table' then
        -- /autoxp set <setting> <value>: any plain setting, e.g. groupHealPct 65
        if type(S[a1]) == 'number' then S[a1] = tonumber(a2) or S[a1]
        elseif type(S[a1]) == 'boolean' then S[a1] = a2 == 'on' or a2 == 'true' or a2 == '1'
        else S[a1] = a2 end
        log('%s = %s', a1, tostring(S[a1]))
    elseif duties[cmd] then S[cmd] = (a1 == nil and not S[cmd]) or a1 == 'on'; log('%s %s', cmd, S[cmd] and 'ON' or 'OFF')
    end
end)
log('AutoXP loaded: /autoxp start|stop|pause|resume|show|scan|save|mode <Manual|Hunter|Assist|Chase>|role <tank|dps>|heal|cc|debuff|nuke|dot|buff|rez [on|off]|backup|group|hud [on|off]|set <setting> <value>|spells|burn')

startSpellScan()
while not R.terminate do
    if not SP.scanning and SP.done and (mq.TLO.Me.Level() or 0) ~= SP.level then pcall(startSpellScan) end
    local sok, serr = pcall(stepSpellScan)
    if not sok then log('spell scan error: %s', tostring(serr)); SP.scanning = false end
    if R.wantScan then
        R.wantScan = false
        local ok, err = pcall(scanAbilities)
        if not ok then log('scan failed: %s', tostring(err)) end
    end
    local eok, eerr = pcall(mq.doevents)
    if not eok then oops('event', eerr) end
    local dok, derr = pcall(DPS.tick)
    if not dok then oops('dps', derr) end
    -- settings saved every 15s: /lua stop (or a crash) skips the save on exit, and a toggle made since was lost
    if mq.gettime() - (R.savedAt or 0) > 15000 then R.savedAt = mq.gettime(); pcall(save) end
    local pok, perr = pcall(peersTick)
    if not pok and perr ~= R.peerErr then R.peerErr = perr; log('group view error: %s', tostring(perr)) end
    if R.running and not R.paused then
        pcall(stowCursor)
        local ok, err = pcall(step)
        if not ok then log('error: %s', tostring(err)); stopAll('error') end
    end
    mq.delay(50)
end
stopAll('window closed')
save()
if logf then logf:close() end
