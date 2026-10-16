-- autoxp: CWTN-style automation with ImGui front end.
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
local CONFIG = string.format('%s/autoxp_%s.lua', mq.configDir, mq.TLO.Me.CleanName() or 'default')
local MODES = { 'Manual', 'Hunter', 'Assist', 'Chase' }
local ROLES = { 'Off', 'Tank', 'DPS', 'Heal', 'CC', 'Emergency', 'Pull' }

-- settings (persisted) -------------------------------------------------------------------
local S = {
    mode = 'Hunter', role = 'Tank', heal = true, cc = false, ccStuns = '',
    zone = 'southro', travel = true,
    minlvl = 15, maxlvl = 25, radius = 1500, kills = 5,
    assistName = '', assistAt = 95, chaseName = '', chaseDist = 30,
    restPct = 50, restTo = 90,
    selfHealPct = 50, groupHealPct = 40, emergencyPct = 20, healSpells = '',
    nukes = '', nukeManaMin = 30, stuns = '', buffs = '', useTaunt = true, prioritize = true, showRadius = true,
    combatBuffs = 'Yaulp', stunCooldown = true, keepInFront = true,
    avoidMobs = true, avoidRadius = 40, pullMethod = 'Auto', pullSpell = '', pullDist = 100, autoMem = true, gemSig = '', memBuffs = true,
    style = 'Auto', castRange = 100, mez = '', dots = '', debuffs = '', petSpell = '', usePet = true, class = '',
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
    ourTarget = 0, pickId = 0, swapGem = nil, buffLevel = 0,
}
local logf = io.open(mq.luaDir .. '/autoxp_log.txt', 'a')
local function log(fmt, ...)
    local s = os.date('%H:%M:%S ') .. string.format(fmt, ...)
    table.insert(R.log, s)
    if #R.log > 300 then table.remove(R.log, 1) end
    if logf then logf:write(s .. '\n'); logf:flush() end
end

local function setState(s) if R.state ~= s then R.state = s; R.stateSince = mq.gettime() end end
local function inState() return mq.gettime() - R.stateSince end
local function hp() return mq.TLO.Me.PctHPs() or 100 end
local function mana() return mq.TLO.Me.PctMana() or 0 end
local function myId() return mq.TLO.Me.ID() or 0 end
local function totalXp() return (mq.TLO.Me.Level() or 0) * 100 + (mq.TLO.Me.PctExp() or 0) end
local function casting() return mq.TLO.Me.Casting() ~= nil end
local function spawn(id) return id and id > 0 and mq.TLO.Spawn('id ' .. id) or nil end
local function alive(s) return s and s() and s.Type() ~= 'Corpse' and (s.PctHPs() or 1) > 0 end
local function save() mq.pickle(CONFIG, S) end

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
    -- combat classes only: never merchants, bankers or GMs
    if id ~= R.pickId and t.Type() == 'NPC' and cls >= 1 and cls <= 16 and alive(spawn(id)) then
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
local RANGED = { WIZ = true, MAG = true, NEC = true, ENC = true, CLR = true, DRU = true, SHM = true }
local function ranged()
    if S.style == 'Auto' then return RANGED[mq.TLO.Me.Class.ShortName() or ''] == true end
    return S.style == 'Ranged'
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
local function navTo(id)
    local dist = R.pull and math.floor(R.pull.dist * 0.9) or ranged() and math.floor(S.castRange * 0.8) or 12
    mq.cmdf('/nav id %d distance=%d lineofsight=on', id, dist); R.lastNav = mq.gettime()
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
        R.attacking = true
    end
end
local function attackOff() mq.cmd('/attack off'); R.attacking = false end

local function doPet(t)
    if not S.usePet or (mq.TLO.Me.Pet.ID() or 0) == 0 then return false end
    if alive(t) and R.petTarget ~= t.ID() and targetId(t.ID()) then
        mq.cmd('/pet attack'); R.petTarget = t.ID(); log('pet attack %s', t.CleanName())
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

local function spellReady(name)
    if name == '' or blocked(name) then return false end
    return mq.TLO.Me.Gem(name)() ~= nil and mq.TLO.Me.SpellReady(name)()
end

-- cast a gem spell on spawn id (self id for self/beneficial). Verifies the target before casting.
local function castOn(name, id, why)
    if not spellReady(name) or casting() then return false end
    local sp = mq.TLO.Spell(name)
    local selfOnly = sp() and (sp.TargetType() == 'Self')
    if not selfOnly and id and id > 0 and id ~= myId() then
        local s = spawn(id)
        if not s or not s() or not s.LineOfSight() or (s.Distance3D() or 999) > (sp.MyRange() or sp.Range() or 200) then return false end
    end
    if not selfOnly and id and id > 0 and not targetId(id) then backoff(name, 'could not target', 5000); return false end
    if mq.TLO.Me.Sitting() then mq.cmd('/stand'); mq.delay(300) end
    local resume = holdMovement()
    mq.cmdf('/cast "%s"', name)
    mq.delay(1000, function() return casting() end)
    if not casting() then resume(); backoff(name, why); restoreFight(); return false end
    log('cast %s -> %s (%s)', name, (id and id > 0) and (mq.TLO.Spawn('id ' .. id).CleanName() or id) or 'self', why)
    mq.delay(12000, function() return not casting() end)
    resume()
    if id ~= R.targetId then restoreFight() end
    return true
end

-- class abilities: skills (/doability), AAs (/alt act), disciplines (/disc)
local function abilityReady(a)
    if blocked(a.name) then return false end
    if a.kind == 'skill' then return mq.TLO.Me.AbilityReady(a.name)() == true
    elseif a.kind == 'aa' then return mq.TLO.Me.AltAbilityReady(a.name)() == true
    elseif a.kind == 'disc' then return mq.TLO.Me.CombatAbilityReady(a.name)() == true end
    return false
end

local function useAbility(a, id, why)
    if not abilityReady(a) or casting() then return false end
    if id and id > 0 and id ~= myId() then
        local s = spawn(id)
        if not s or not s() or not s.LineOfSight() or (a.kind == 'skill' and (s.Distance3D() or 999) > 30) then return false end
    end
    if id and id > 0 and not targetId(id) then return false end
    if a.kind == 'skill' then mq.cmdf('/doability "%s"', a.name)
    elseif a.kind == 'aa' then mq.cmdf('/alt act %d', mq.TLO.Me.AltAbility(a.name).ID() or 0)
    elseif a.kind == 'disc' then mq.cmdf('/disc %s', a.name) end
    log('use %s %s (%s)', a.kind, a.name, why)
    failedUntil[a.name] = mq.gettime() + 1500   -- debounce
    mq.delay(300)
    if id ~= R.targetId then restoreFight() end
    return true
end

local function abilitiesFor(role)
    local out = {}
    for _, a in ipairs(S.abilities) do if a.role == role and a.enabled ~= false then table.insert(out, a) end end
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
local function scanAbilities()
    local found, seen = {}, {}
    local function add(name, kind)
        if type(name) == 'string' and name ~= '' and name ~= 'NULL' and not seen[name] then
            seen[name] = true
            local role, enabled = defaultRole(name, kind), true
            for _, old in ipairs(S.abilities) do if old.name == name then enabled = old.enabled ~= false end end
            table.insert(found, { name = name, kind = kind, role = role, enabled = enabled })
        end
    end
    -- combat skills the character actually has
    for _, sk in ipairs(COMBAT_SKILLS) do
        if (mq.TLO.Me.Skill(sk)() or 0) > 0 then add(sk, 'skill') end
    end
    -- combat abilities (disciplines)
    for i = 1, 300 do local c = mq.TLO.Me.CombatAbility(i)(); if type(c) == 'string' and c ~= '' then add(c, 'disc') end end
    -- class AAs only (AA window Class tab = List3), owned and activatable
    local l = mq.TLO.Window('AAWindow').Child('List3')
    for r = 1, (l.Items() or 0) do
        local name = l.List(r, 1)()
        if type(name) == 'string' and mq.TLO.Me.AltAbility(name)() and mq.TLO.Me.AltAbility(name).Spell() then add(name, 'aa') end
    end
    S.abilities = found
    log('scanned %d abilities', #found)
    for _, a in ipairs(found) do log('  %s %-24s -> %s', a.kind, a.name, a.role) end
    save()
end
local mapRadius = -1
local function updateMapRadius()
    local want = (R.running and S.mode == 'Hunter' and S.showRadius) and S.radius or 0
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

-- self buffs from the spell book: HP, stat, resist, haste and proc buffs of 10+ minutes, best of each line
local BUFFCAT = { ['HP Buffs'] = true, ['Statistic Buffs'] = true }
local BUFFSUB = { Haste = true, ['Combat Innates'] = true }
local BUFFTT = { Self = true, Single = true, ['Group v1'] = true, ['Group v2'] = true }
local function refreshBuffs()
    local lvl = mq.TLO.Me.Level() or 0
    R.buffLevel = lvl
    local best = {}
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        if b() and b.SpellType() == 'Beneficial' and (b.Level() or 0) <= lvl and BUFFTT[b.TargetType() or '']
            and (BUFFCAT[b.Category() or ''] or BUFFSUB[b.Subcategory() or '']) and (b.Duration.TotalSeconds() or 0) >= 600 then
            -- one per line; each resist (fire, cold, poison, disease, magic) is its own line
            local key = (b.Category() or '') .. '/' .. (b.Subcategory() or '')
            if b.Subcategory() == 'Resist Buff' then
                for spa = 46, 50 do if b.HasSPA(spa)() then key = key .. '/' .. spa end end
            end
            if not best[key] or (b.Level() or 0) > best[key].lvl then best[key] = { name = b.Name(), lvl = b.Level() or 0 } end
        end
    end
    local out = {}
    for _, b in pairs(best) do table.insert(out, b) end
    table.sort(out, function(a, b) return a.lvl > b.lvl end)
    local names = {}
    for _, b in ipairs(out) do table.insert(names, b.name) end
    local s = table.concat(names, ', ')
    if s ~= S.buffs then S.buffs = s; log('self buffs from the book: %s', s) end
end

local function fillFromGems()
    local heals, stuns, nukes, mez, dots, debuffs, pet = {}, {}, {}, {}, {}, {}, ''
    for g = 1, 13 do
        local sp = mq.TLO.Me.Gem(g)
        if sp() then
            local name, cat, sub = sp.Name(), sp.Category() or '', sp.Subcategory() or ''
            local bene = sp.SpellType() == 'Beneficial'
            if cat == 'Heals' and sub == 'Heals' then table.insert(heals, name)
            elseif sub:find('Stun') then table.insert(stuns, name)
            elseif sub == 'Enthrall' then table.insert(mez, name)
            elseif sub == 'Slow' then table.insert(debuffs, name)
            elseif not bene and cat == 'Direct Damage' then table.insert(nukes, name)
            elseif not bene and cat == 'Damage Over Time' then table.insert(dots, name)
            elseif cat == 'Pet' and sub:find('^Sum:') then pet = name end
        end
    end
    byLevel(heals); byLevel(stuns); byLevel(nukes); byLevel(dots); byLevel(debuffs); byLevel(mez)
    S.healSpells, S.stuns, S.nukes = table.concat(heals, ', '), table.concat(stuns, ', '), table.concat(nukes, ', ')
    refreshBuffs()
    S.ccStuns, S.mez, S.dots, S.debuffs, S.petSpell = S.stuns, table.concat(mez, ', '), table.concat(dots, ', '), table.concat(debuffs, ', '), pet
    log('from gems: heals=[%s] stuns=[%s] nukes=[%s] dots=[%s] mez=[%s] slows=[%s] pet=[%s] buffs=[%s]',
        S.healSpells, S.stuns, S.nukes, S.dots, S.mez, S.debuffs, S.petSpell, S.buffs)
    pickPullSpell()
end

-- first start on a character (or a different class): build ability and spell lists from the game
local function autoSetup()
    local cls = mq.TLO.Me.Class.ShortName() or ''
    if S.class == cls then return end
    log('setting up for %s (%s)', cls, ranged() and 'ranged' or 'melee')
    S.class, S.role = cls, RANGED[cls] and 'DPS' or S.role
    local ok, err = pcall(scanAbilities)
    if not ok then log('scan failed: %s', tostring(err)) end
    fillFromGems()
end

local function stopAll(reason)
    attackOff(); mq.cmd('/stick off'); mq.cmd('/nav stop'); petBackOff()
    if R.state == 'TRAVEL' then mq.cmd('/travelto stop') end
    if R.swapGem and R.swapGem.name ~= '' then mq.cmdf('/memspell %d "%s"', R.swapGem.g, R.swapGem.name) end
    R.running = false; R.paused = false; R.targetId, R.pickId, R.swapGem = 0, 0, nil
    setState('IDLE')
    updateMapRadius()
    save()
    log('stopped: %s', reason or 'user')
end

local function start()
    R.running, R.paused, R.kills = true, false, 0
    R.xp0, R.aa0, R.started = totalXp(), mq.TLO.Me.PctAAExp() or 0, mq.gettime()
    log('start: mode=%s role=%s heal=%s cc=%s zone=%s', S.mode, S.role, S.heal and 'on' or 'off', S.cc and 'on' or 'off', S.zone)
    autoSetup()
    if S.pullSpell == '' then pickPullSpell() end
    if #S.abilities == 0 then local ok, err = pcall(scanAbilities); if not ok then log('scan failed: %s', tostring(err)) end end
    save()
    updateMapRadius()
    if S.mode == 'Hunter' and S.travel and mq.TLO.Zone.ShortName() ~= S.zone then
        mq.cmdf('/travelto %s', S.zone); R.travelTarget, R.travelTries = S.zone, 0; setState('TRAVEL')
    else
        setState('BUFF')
    end
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

-- roles -----------------------------------------------------------------------------------
local function doHeal()
    if not S.heal then return false end
    -- emergency abilities (e.g. Lay on Hands) first
    if hp() < S.emergencyPct then
        for _, a in ipairs(abilitiesFor('Emergency')) do if useAbility(a, myId(), string.format('emergency %d%%', hp())) then return true end end
    end
    local heals = list(S.healSpells)
    local function tryHeal(id, why)
        for _, a in ipairs(abilitiesFor('Heal')) do if useAbility(a, id, why) then return true end end
        for _, h in ipairs(heals) do if castOn(h, id, why) then return true end end
        return false
    end
    if hp() < S.selfHealPct and tryHeal(myId(), string.format('self %d%%', hp())) then return true end
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        if m() and m.Present() and not m.OtherZone() and (m.PctHPs() or 100) < S.groupHealPct and (m.Distance() or 999) < 150 then
            if tryHeal(m.ID(), string.format('%s %d%%', m.CleanName(), m.PctHPs())) then return true end
        end
    end
    return false
end

local function doCC(t)
    if not S.cc or hp() < 40 then return false end
    local adds = hostiles()
    if #adds > 1 then
        for _, x in ipairs(adds) do
            if x.ID() ~= R.targetId and not mezzed(x) and (x.Distance() or 999) < S.castRange then
                for _, m in ipairs(list(S.mez)) do
                    if castOn(m, x.ID(), 'mez add') then
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
        for _, s in ipairs(stuns) do if castOn(s, t.ID(), 'interrupt') then return true end end
    end
    for _, x in ipairs(hostiles()) do
        if x.ID() ~= R.targetId and x.Distance() < 60 then
            for _, a in ipairs(abilitiesFor('CC')) do if useAbility(a, x.ID(), 'add') then return true end end
            for _, s in ipairs(stuns) do if castOn(s, x.ID(), 'add') then return true end end
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
    return false
end

local function doDps(t)
    -- both roles use DPS abilities + nukes; Tank-only abilities/stuns are handled in doTank
    if not alive(t) then return false end
    for _, a in ipairs(abilitiesFor('DPS')) do if useAbility(a, t.ID(), 'dps') then return true end end
    if (t.PctHPs() or 0) > 40 then
        for _, d in ipairs(list(S.debuffs)) do if not t.MyBuff(d)() and castOn(d, t.ID(), 'slow') then return true end end
    end
    if mana() < S.nukeManaMin then return false end
    if (t.PctHPs() or 0) > 40 then
        for _, d in ipairs(list(S.dots)) do if not t.MyBuff(d)() and castOn(d, t.ID(), 'dot') then return true end end
    end
    for _, n in ipairs(list(S.nukes)) do if castOn(n, t.ID(), 'nuke') then return true end end
    return false
end

-- swap the lowest-level memorized spell that has a better scribed version of the same kind
-- (same category, subcategory and target type, at or below my level)
local function upgradeGems()
    if not S.autoMem or mq.gettime() - R.lastMemCheck < 60000 then return false end
    R.lastMemCheck = mq.gettime()
    local lvl, book, mem, gems = mq.TLO.Me.Level() or 0, {}, {}, {}
    for i = 1, (mq.TLO.Me.NumGems() or 8) do
        local s = mq.TLO.Me.Gem(i)
        if s() then mem[s.Name()] = true; table.insert(gems, { g = i, s = s, lvl = s.Level() or 0 }) end
    end
    for i = 1, 1120 do
        local b = mq.TLO.Me.Book(i)
        if b() and not mem[b.Name()] and (b.Level() or 0) <= lvl then
            table.insert(book, { name = b.Name(), lvl = b.Level() or 0, cat = b.Category(), sub = b.Subcategory(), tt = b.TargetType() })
        end
    end
    table.sort(gems, function(a, b) return a.lvl < b.lvl end)
    for _, m in ipairs(gems) do
        local cat, sub, tt, best = m.s.Category(), m.s.Subcategory(), m.s.TargetType(), nil
        for _, b in ipairs(book) do
            if b.lvl > m.lvl and b.cat == cat and b.sub == sub and b.tt == tt and (not best or b.lvl > best.lvl) then best = b end
        end
        if best then
            log('memorizing %s (L%d) over %s (L%d) in gem %d', best.name, best.lvl, m.s.Name(), m.lvl, m.g)
            mq.cmdf('/memspell %d "%s"', m.g, best.name)
            mq.delay(20000, function() return mq.TLO.Me.Gem(m.g).Name() == best.name or #hostiles() > 0 end)
            R.lastMemCheck = 0   -- look at the next gem right away
            return true
        end
    end
    return false
end

-- self buffs, best first: cast whatever is missing and would stack. A buff that isn't memorized
-- borrows a gem (an empty one, else the last), which gets its spell back once everything is up
local function restoreGem()
    local s = R.swapGem
    if not s then return false end
    if s.name == '' or mq.TLO.Me.Gem(s.g).Name() == s.name then R.swapGem = nil; return false end
    log('putting %s back in gem %d', s.name, s.g)
    mq.cmdf('/memspell %d "%s"', s.g, s.name)
    mq.delay(20000, function() return mq.TLO.Me.Gem(s.g).Name() == s.name or #hostiles() > 0 end)
    if mq.TLO.Me.Gem(s.g).Name() == s.name then R.swapGem = nil end
    return true
end

local function doBuffs()
    if (mq.TLO.Me.Level() or 0) ~= R.buffLevel then refreshBuffs() end
    for _, b in ipairs(list(S.buffs)) do
        local sp = mq.TLO.Spell(b)
        if sp() and not mq.TLO.Me.Buff(b)() and sp.Stacks() and not blocked(b) and (mq.TLO.Me.CurrentMana() or 0) >= (sp.Mana() or 0) then
            if spellReady(b) then castOn(b, myId(), 'buff'); return true end
            local swap = R.swapGem
            if swap and mq.TLO.Me.Gem(swap.g).Name() == b then
                if mq.gettime() - (swap.at or 0) < 15000 then return true end   -- gem still refreshing
                backoff(b, 'not ready after memorizing', 120000)
            elseif not mq.TLO.Me.Gem(b)() and S.memBuffs and mq.TLO.Me.Book(b)() then
                if not swap then
                    local g = mq.TLO.Me.NumGems() or 8
                    for i = 1, g do if not mq.TLO.Me.Gem(i)() then g = i; break end end
                    swap = { g = g, name = mq.TLO.Me.Gem(g).Name() or '' }
                    R.swapGem = swap
                end
                log('memorizing %s in gem %d to buff', b, swap.g)
                mq.cmdf('/memspell %d "%s"', swap.g, b)
                mq.delay(20000, function() return mq.TLO.Me.Gem(swap.g).Name() == b or #hostiles() > 0 end)
                swap.at = mq.gettime()
                if mq.TLO.Me.Gem(swap.g).Name() ~= b then backoff(b, 'memorize', 60000) end
                return true
            end
        end
    end
    return restoreGem()
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

-- route safety: MQ2Nav path waypoints vs every NPC near the route -----------------------------
local function pathPoints(dest)
    local s = mq.TLO.Navigation.PathPoints(dest)()
    if not s then return nil end
    local pts = {}
    for x, y, z in s:gmatch('(-?%d+),(-?%d+),(-?%d+)') do table.insert(pts, { tonumber(x), tonumber(y), tonumber(z) }) end
    return #pts > 0 and pts or nil
end

local function pathLen(pts)
    local len = 0
    for k = 1, #pts - 1 do
        local a, b = pts[k], pts[k + 1]
        len = len + math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2 + (b[3] - a[3]) ^ 2)
    end
    return len
end

-- 2D distance from p to segment ab, and how far along it (0..1) the closest point is
local function segDist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local f = l2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
    return math.sqrt((px - ax - f * dx) ^ 2 + (py - ay - f * dy) ^ 2), f
end

-- NPCs (not the target) within avoidRadius of the route on the same level
local function mobsOnRoute(pts, skipId)
    local hits = {}
    if not pts or #pts < 2 then return hits end
    for i = 1, 80 do
        local n = mq.TLO.NearestSpawn(i, 'npc radius 1500')
        if not n() then break end
        if n.ID() ~= skipId and alive(n) and n.ConColor() ~= 'GREY' then
            local nx, ny, nz = n.X(), n.Y(), n.Z()
            for k = 1, #pts - 1 do
                local a, b = pts[k], pts[k + 1]
                local d, f = segDist(nx, ny, a[1], a[2], b[1], b[2])
                if d < S.avoidRadius and math.abs(nz - (a[3] + (b[3] - a[3]) * f)) < 25 then
                    table.insert(hits, { spawn = n, seg = k }); break
                end
            end
        end
    end
    return hits
end

-- a waypoint beside the first mob on the route, on whichever side has a clear path to it
local function detourFor(pts, hit)
    local a, b = pts[hit.seg], pts[hit.seg + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 1 then return nil end
    local px, py = -dy / l, dx / l
    local mx, my = hit.spawn.X(), hit.spawn.Y()
    for _, mult in ipairs({ 2, 3 }) do
        for _, side in ipairs({ 1, -1 }) do
            local wx, wy = mx + side * px * S.avoidRadius * mult, my + side * py * S.avoidRadius * mult
            local dest = string.format('loc %.0f %.0f %.0f', wy, wx, a[3])
            local wp = pathPoints(dest)
            if wp and #mobsOnRoute(wp, 0) == 0 then
                return { x = wx, y = wy, dest = dest, around = hit.spawn.CleanName() }
            end
        end
    end
    return nil
end

local function pickTarget()
    -- anything already on us comes first (priority order)
    R.pendingDetour, R.pullCandidate = nil, false
    local best = bestTarget()
    if best then return best.ID() end
    if S.mode == 'Manual' then
        local t = mq.TLO.Target
        if t() and t.Type() == 'NPC' and R.attacking then return t.ID() end
        return nil
    elseif S.mode == 'Hunter' then
        if R.kills >= S.kills then stopAll(string.format('done: %d kills', R.kills)); return nil end
        local q = string.format('npc range %d %d radius %d noalert 1 targetable', S.minlvl, S.maxlvl, S.radius)
        -- shortest safe walk among the 10 nearest reachable candidates: each mob near the route costs 400 units.
        -- NearestSpawn is 2D, so the nearest can be floors away with no path; skip those and look further
        local best, bestScore, bestPts, bestHits, found = nil, nil, nil, nil, 0
        for i = 1, 50 do
            local s = mq.TLO.NearestSpawn(i, q)
            if not s() or found >= 10 then break end
            local id = s.ID()
            if (R.skip[id] or 0) < mq.gettime() then
                -- route checks need MQ2Nav's PathPoints member; without it, rank by path length only
                local pts = pathPoints('id ' .. id)
                local len = pts and pathLen(pts) or mq.TLO.Navigation.PathLength('id ' .. id)() or -1
                if len < 0 then len = nil; R.skip[id] = mq.gettime() + 30000 end   -- off the navmesh
                if len and len < S.radius * 1.5 then
                    found = found + 1
                    local hits = S.avoidMobs and mobsOnRoute(pts, id) or {}
                    local score = len + #hits * 400
                    if not bestScore or score < bestScore then best, bestScore, bestPts, bestHits = id, score, pts, hits end
                end
            end
        end
        if best and #bestHits > 0 then
            R.pendingDetour = detourFor(bestPts, bestHits[1])
            if not R.pendingDetour then log('no clear route: %d mob(s) near the path', #bestHits) end
        end
        R.pullCandidate = best ~= nil
        return best
    else
        local who = S.mode == 'Assist' and S.assistName or S.chaseName
        if who == '' then return nil end
        if mq.gettime() - R.lastAssist > 1500 then mq.cmdf('/assist %s', who); R.lastAssist = mq.gettime(); mq.delay(300) end
        local t = mq.TLO.Target
        if t() and t.Type() == 'NPC' and (t.PctHPs() or 100) <= S.assistAt then return t.ID() end
        return nil
    end
end

-- one tick of the state machine -----------------------------------------------------------
local function step()
    noticePick()
    if casting() then return end
    if doHeal() then return end
    local st = R.state
    if followPick(st) then return end
    local here = mq.TLO.Zone.ShortName() or ''

    -- hunt zone changed while running: leave once we're not fighting
    if S.mode == 'Hunter' and S.travel and here ~= S.zone and st ~= 'TRAVEL' and st ~= 'FIGHT' and R.pickId == 0 and #hostiles() == 0 then
        mq.cmd('/stick off'); mq.cmd('/nav stop'); attackOff(); R.targetId = 0
        mq.cmdf('/travelto %s', S.zone)
        R.travelTarget, R.travelTries, R.lastMoveAt = S.zone, 0, mq.gettime()
        log('hunt zone is %s (here: %s) - traveling', S.zone, here)
        setState('TRAVEL')
        return
    end

    if st == 'TRAVEL' then
        if here == S.zone then log('arrived in %s', S.zone); mq.cmd('/nav reload'); setState('BUFF'); return end
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
        if not R.swapGem then
            if upgradeGems() then return end
            local sig = gemSig()
            if sig ~= S.gemSig then
                if S.gemSig ~= '' then log('memorized spells changed - refreshing spell lists') end
                S.gemSig = sig; fillFromGems()
            end
        end
        if S.usePet and S.petSpell ~= '' and (mq.TLO.Me.Pet.ID() or 0) == 0 and spellReady(S.petSpell) then castOn(S.petSpell, myId(), 'summon pet'); return end
        if doBuffs() then return end
        setState('FIND')

    elseif st == 'REST' then
        if #hostiles() > 0 then mq.cmd('/stand'); setState('FIND'); return end
        if hp() >= S.restTo and (mana() >= S.restTo or (mq.TLO.Me.MaxMana() or 0) == 0) then
            mq.cmd('/stand'); log('rested: HP %d%% mana %d%%', hp(), mana()); setState('BUFF')
        elseif not mq.TLO.Me.Sitting() then mq.cmd('/sit') end

    elseif st == 'FIND' then
        if S.mode == 'Chase' and S.chaseName ~= '' then
            local c = mq.TLO.Spawn('pc =' .. S.chaseName)
            if c() and (c.Distance() or 0) > S.chaseDist and not mq.TLO.Navigation.Active() then mq.cmdf('/nav id %d', c.ID()) end
        end
        if S.mode == 'Hunter' and #hostiles() == 0 and (hp() < S.restPct or (mq.TLO.Me.MaxMana() or 0) > 0 and mana() < 20) then setState('REST'); return end
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
                -- come to a full stop first: a pull cast right after /nav stop gets interrupted
                mq.cmd('/nav stop')
                mq.delay(1500, function() return not mq.TLO.Me.Moving() end)
                mq.delay(400)
            end
            if not pullReady(R.pull) then
                R.pullWait = R.pullWait or mq.gettime()
                if mq.gettime() - R.pullWait > 6000 then log('pull not ready - walking in'); R.pull = nil; navTo(t.ID()) end
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
            if nextT then
                R.targetId, R.targetName, R.opened = nextT.ID(), nextT.CleanName(), false
                log('next add: %s (%s)', R.targetName, nextT.Class.ShortName() or '?')
                attackOn(); closeIn(nextT); setState('FIGHT'); return
            end
            attackOff(); mq.cmd('/stick off'); petBackOff(); R.targetId = 0
            setState((S.mode == 'Hunter' and (hp() < S.restPct or mana() < 20)) and 'REST' or 'BUFF')
            return
        end
        if (mq.TLO.Target.ID() or 0) ~= R.targetId or not R.attacking then restoreFight() end
        if hp() < 12 and S.mode == 'Hunter' then stopAll('HP critical'); return end
        for _, b in ipairs(list(S.combatBuffs)) do
            if not mq.TLO.Me.Buff(b)() and not mq.TLO.Me.Song(b)() and spellReady(b) then if castOn(b, myId(), 'combat buff') then return end end
        end
        if not ranged() and mq.gettime() < R.holdUntil then
            if reachable(t, 35) then
                R.holdUntil = 0; mq.cmd('/attack on'); stick()
            else
                if mq.gettime() - R.lastFace > 1000 then mq.cmdf('/face fast id %d', t.ID()); R.lastFace = mq.gettime() end
                return
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
        if doCC(t) then return end
        if doDps(t) then return end
        if inState() > 300000 then log('fight timeout'); attackOff(); R.pickId = 0; setState('FIND') end
    end
end

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
    DPS = 'DPS: melee from behind, or cast from range (casters/priests); never taunt or stun-lock.\nUses DPS abilities, slows, DoTs and nukes; the pet joins the fight.',
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

local function draw()
    if not R.open then return end
    local show
    R.open, show = ImGui.Begin('AutoXP', R.open)
    if show then
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
        if m ~= S.mode then S.mode = m; log('mode %s', m) end
        updateMapRadius()
        ImGui.Text('Role:'); ImGui.SameLine(); roleButton('Tank'); ImGui.SameLine(); roleButton('DPS')
        ImGui.SameLine(); ImGui.Text('   Duties:'); ImGui.SameLine()
        toggle('Heal', 'heal', 'Heal: heal yourself / group members below the Healing thresholds,\nand use Emergency abilities (Lay on Hands) below the emergency threshold.')
        ImGui.SameLine()
        toggle('CC', 'cc', 'CC: mez adds (Mez list), interrupt a casting target and stun adds\nthat are not your current target (CC stuns list). Mezzed adds are left for last.')
        ImGui.Separator()

        ImGui.Text(string.format('%s  L%d %s  %s', mq.TLO.Me.CleanName() or '?', mq.TLO.Me.Level() or 0, mq.TLO.Me.Class.ShortName() or '', mq.TLO.Zone.ShortName() or '?'))
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
                S.showRadius = ImGui.Checkbox('Show pull radius on map (Hunter)', S.showRadius)
                S.avoidMobs = ImGui.Checkbox('Avoid other mobs when pulling', S.avoidMobs)
                tip('Prefer pulls whose walking route stays clear of other NPCs, and detour around one when needed.')
                if S.avoidMobs then S.avoidRadius = ImGui.SliderInt('Avoid radius', S.avoidRadius, 20, 120) end
                ImGui.SetNextItemWidth(110)
                local pm = combo('Pull with', S.pullMethod, PULLS)
                if pm ~= S.pullMethod then S.pullMethod = pm; log('pull with %s', pm) end
                tip('Hunter pulls. Auto: the pull spell, else a ranged item (bow/throwing), else an ability marked Pull, else walk in.')
                local pp = pullPlan()
                ImGui.SameLine(); ImGui.TextDisabled(pp and string.format('(%s: %s, range %d)', pp.how:lower(), pp.name, pp.range) or '(walk in)')
                S.pullSpell = ImGui.InputText('Pull spell', S.pullSpell)
                S.pullDist = ImGui.SliderInt('Pull distance', S.pullDist, 40, 200)
                tip('Pull from this far at most (and never past 80% of the pull range); moves closer if the pull fails.')
                S.kills = ImGui.SliderInt('Kill count (Hunter)', S.kills, 1, 500)
                S.assistName = ImGui.InputText('Main assist', S.assistName)
                S.assistAt = ImGui.SliderInt('Assist at %', S.assistAt, 1, 100)
                S.chaseName = ImGui.InputText('Chase target', S.chaseName)
                S.chaseDist = ImGui.SliderInt('Chase distance', S.chaseDist, 10, 200)
                S.restPct = ImGui.SliderInt('Rest below %', S.restPct, 5, 95)
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
                S.nukes = ImGui.InputText('Nukes (DPS)', S.nukes)
                S.dots = ImGui.InputText('DoTs (DPS, once per target)', S.dots)
                S.debuffs = ImGui.InputText('Slows (once per target)', S.debuffs)
                S.mez = ImGui.InputText('Mez (CC adds)', S.mez)
                S.petSpell = ImGui.InputText('Pet summon', S.petSpell)
                S.usePet = ImGui.Checkbox('Use pet', S.usePet)
                S.nukeManaMin = ImGui.SliderInt('Nuke above mana %', S.nukeManaMin, 0, 100)
                S.stuns = ImGui.InputText('Tank stuns (opener / stun-lock)', S.stuns)
                S.ccStuns = ImGui.InputText('CC stuns (adds / interrupts)', S.ccStuns)
                S.stunCooldown = ImGui.Checkbox('Stun on cooldown during fights (Tank)', S.stunCooldown)
                S.combatBuffs = ImGui.InputText('Combat buffs (recast in fight)', S.combatBuffs)
                S.buffs = ImGui.InputText('Self buffs', S.buffs)
                tip('Filled from the spell book: HP, stat, resist, haste and proc buffs of 10+ minutes, best of each line.')
                S.memBuffs = ImGui.Checkbox('Memorize missing buffs (borrows the last gem, then puts it back)', S.memBuffs)
                S.useTaunt = ImGui.Checkbox('Taunt when aggro < 100% (Tank)', S.useTaunt)
                S.prioritize = ImGui.Checkbox('Tank target priority: casters > healers > hybrids > melee', S.prioritize)
                S.keepInFront = ImGui.Checkbox('Reposition so all mobs are in front of me (melee)', S.keepInFront)
                if ImGui.Button('Fill from memorized gems') then fillFromGems() end
                S.autoMem = ImGui.Checkbox('Auto-memorize spell upgrades (out of combat)', S.autoMem)
                tip('Swaps a memorized spell for a higher-level scribed spell of the same kind (e.g. Stun over Cease).\nSpell lists refresh from the gems whenever they change.')
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Abilities') then
                if ImGui.Button('Scan class abilities') then scanAbilities() end
                ImGui.SameLine(); ImGui.Text(string.format('%d found', #S.abilities))
                for i, a in ipairs(S.abilities) do
                    local on = a.enabled ~= false
                    local c = on and ON or OFF
                    ImGui.PushStyleColor(ImGuiCol.Button, c[1], c[2], c[3], c[4])
                    if ImGui.Button(string.format('%s##ab%d', on and 'ON' or 'OFF', i), 50, 22) then
                        a.enabled = not on; log('%s %s', a.name, a.enabled and 'ON' or 'OFF'); save()
                    end
                    ImGui.PopStyleColor()
                    ImGui.SameLine()
                    local ready = abilityReady(a)
                    ImGui.TextColored(ready and 0.5 or 0.6, ready and 1 or 0.6, ready and 0.5 or 0.6, 1, string.format('%s  (%s, %s)', a.name, a.kind, a.role))
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Healing') then
                S.healSpells = ImGui.InputText('Heals (best first)', S.healSpells)
                S.selfHealPct = ImGui.SliderInt('Heal self below %', S.selfHealPct, 5, 95)
                S.groupHealPct = ImGui.SliderInt('Heal group below %', S.groupHealPct, 5, 95)
                S.emergencyPct = ImGui.SliderInt('Emergency abilities below %', S.emergencyPct, 5, 60)
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Log') then
                for i = math.max(1, #R.log - 30), #R.log do ImGui.TextWrapped(R.log[i]) end
                ImGui.EndTabItem()
            end
            ImGui.EndTabBar()
        end
        if ImGui.Button('Save settings') then save(); log('settings saved') end
    end
    ImGui.End()
    if not R.open then R.terminate = true end
end

mq.imgui.init('AutoXP', draw)
mq.bind('/autoxp', function(cmd, a1)
    local duties = { heal = true, cc = true }
    if cmd == 'start' then start() elseif cmd == 'stop' then stopAll('command')
    elseif cmd == 'pause' then setPaused(true) elseif cmd == 'resume' then setPaused(false)
    elseif cmd == 'spells' then startSpellScan(); log('checking spell book...')
    elseif cmd == 'show' then R.open = true elseif cmd == 'scan' then scanAbilities() elseif cmd == 'save' then save(); log('settings saved')
    elseif cmd == 'mode' and a1 then
        for _, m in ipairs(MODES) do if m:lower() == a1:lower() then S.mode = m; log('mode %s', m) end end
    elseif cmd == 'role' and a1 and (a1:lower() == 'tank' or a1:lower() == 'dps') then S.role = a1:lower() == 'tank' and 'Tank' or 'DPS'; log('role %s', S.role)
    elseif cmd == 'tank' then S.role = 'Tank'; log('role Tank') elseif cmd == 'dps' then S.role = 'DPS'; log('role DPS')
    elseif duties[cmd] then S[cmd] = (a1 == nil and not S[cmd]) or a1 == 'on'; log('%s %s', cmd, S[cmd] and 'ON' or 'OFF')
    end
end)
log('AutoXP loaded: /autoxp start|stop|pause|resume|show|scan|save|mode <Manual|Hunter|Assist|Chase>|role <tank|dps>|heal|cc [on|off]|spells')

startSpellScan()
while not R.terminate do
    if not SP.scanning and SP.done and (mq.TLO.Me.Level() or 0) ~= SP.level then startSpellScan() end
    local sok, serr = pcall(stepSpellScan)
    if not sok then log('spell scan error: %s', tostring(serr)); SP.scanning = false end
    if R.running and not R.paused then
        local ok, err = pcall(step)
        if not ok then log('error: %s', tostring(err)); stopAll('error') end
    end
    mq.delay(100)
end
stopAll('window closed')
save()
if logf then logf:close() end
