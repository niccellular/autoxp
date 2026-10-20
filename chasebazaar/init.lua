-- chasebazaar: buy chase loot from the Bazaar by parcel - one of each item, at or under MAX_PRICE_PP.
-- The list (list.lua): the level 125 chase loot, "... of Unbound Radiance". Searches go through
-- MQ2Bzsrch (/bzsrch, ${Bazaar}); a buy is the search window's Buy button, then the confirmation's Use Plat button
-- (never tokens). Skipped: items already in your bags or bank, and ones bought before (remembered per character in
-- config/chasebazaar_bought_<Name>.txt - a parcel isn't in the bags until it's picked up).
--   /lua run autoxp/chasebazaar           search and buy, a full pass every PASS_GAP_S
--   /lua run autoxp/chasebazaar dry       search and report only, never buys
--   /lua run autoxp/chasebazaar once      one pass, then stop (combine: dry once)
--   /chasebazaar stop                     stop after the current search
-- Log: lua/chasebazaar_log.txt
local mq = require('mq')

local MAX_PRICE_PP      = 100      -- never pay more than this for one item (listings here are about 1pp)
local SEARCH_GAP_MS     = 1000     -- pause between searches (each also waits for the Query button)
local SEARCH_TIMEOUT_MS = 15000    -- wait this long for a search's results
local PASS_GAP_S        = 60       -- pause between full passes

local DRY, ONCE = false, false
for _, a in ipairs({ ... }) do
    if a == 'dry' then DRY = true elseif a == 'once' then ONCE = true end
end

local ME = mq.TLO.Me.CleanName() or 'x'
local logf = io.open(mq.luaDir .. '/chasebazaar_log.txt', 'a')
local function log(fmt, ...)
    local s = string.format(fmt, ...)
    print('\ag[ChaseBazaar]\ax ' .. s)
    logf:write(os.date('%m-%d %H:%M:%S ') .. s .. '\n'); logf:flush()
end

local running = true
mq.bind('/chasebazaar', function(a) if a == 'stop' then running = false; log('stopping after this search') end end)

local LIST = dofile(mq.luaDir .. '/autoxp/chasebazaar/list.lua')

local function trim(s) return ((s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function isChase(name)
    local l = name:lower()
    if LIST.never[l] then return false end
    if LIST.named[l] then return true end
    for _, p in ipairs(LIST.patterns) do if l:find(p) then return true end end
    return false
end

-- bought before (this character, any run): one name per line
local boughtFile = mq.configDir .. '/chasebazaar_bought_' .. ME .. '.txt'
local bought = {}
do
    local f = io.open(boughtFile, 'r')
    if f then for line in f:lines() do if trim(line) ~= '' then bought[trim(line):lower()] = true end end; f:close() end
end
local function markBought(name)
    bought[name:lower()] = true
    local f = io.open(boughtFile, 'a'); if f then f:write(name .. '\n'); f:close() end
end
local function owned(name)
    return (mq.TLO.FindItemCount('=' .. name)() or 0) + (mq.TLO.FindItemBankCount('=' .. name)() or 0) > 0
end

-- search terms: each name pattern as plain text (Lua pattern escapes dropped; for 'a.*b' the longer piece), then every
-- exact name that no pattern search already covers, alphabetically
local function searchTerms()
    local out, seen, plain = {}, {}, {}
    local function add(s)
        s = trim(s)
        if #s >= 3 and not seen[s] then seen[s] = true; table.insert(out, s) end
    end
    for _, p in ipairs(LIST.patterns) do
        local best = ''
        for piece in ((p:gsub('%%(.)', '%1')) .. '.*'):gmatch('(.-)%.%*') do if #piece > #best then best = piece end end
        best = best:gsub('[%^%$]', '')
        add(best)
        if #best >= 3 then table.insert(plain, best) end
    end
    local names = {}
    for n in pairs(LIST.named) do table.insert(names, n) end
    table.sort(names)
    for _, n in ipairs(names) do
        local covered = false
        for _, q in ipairs(plain) do if n:find(q, 1, true) then covered = true; break end end
        if not covered then add(n) end
    end
    return out
end

local function searchWnd() return mq.TLO.Window('BazaarSearchWnd') end
local function ensureWindow()
    if searchWnd().Open() then return true end
    mq.cmd('/bazaar')
    mq.delay(3000, function() return searchWnd().Open() end)
    return searchWnd().Open()
end

-- run one search (at or under the price cap) and return the chase listings in it: { name, priceCp, trader }, read from
-- the result list itself (columns: 2 name, 4-7 price in pp / gp / sp / cp, 8 trader) - the rows are what Buy acts on
local function rowPrice(lst, row)
    return (tonumber(lst.List(row, 4)()) or 0) * 1000 + (tonumber(lst.List(row, 5)()) or 0) * 100
        + (tonumber(lst.List(row, 6)()) or 0) * 10 + (tonumber(lst.List(row, 7)()) or 0)
end
local function search(term)
    -- the game keeps the Query button off for a while after each search, and MQ2Bzsrch gives up after 7s of waiting
    -- for it ("Timed out waiting for BZR_QueryButton"): wait for it here first
    local qb = searchWnd().Child('BZR_QueryButton')
    mq.delay(60000, function() return qb.Enabled() or not running end)
    if not qb.Enabled() then log('the Query button stayed off for a minute - search "%s" skipped', term); return {} end
    mq.cmdf('/bzsrch price 0 %d %s', MAX_PRICE_PP, term)
    mq.delay(300)
    mq.delay(SEARCH_TIMEOUT_MS, function() return mq.TLO.Bazaar.Done() end)
    local lst = searchWnd().Child('BZR_ItemList')
    -- MQ2Bzsrch calls a search done (and empty) after 5s with nothing back: give a slow answer 5s more
    if (lst.Items() or 0) == 0 then mq.delay(5000, function() return (lst.Items() or 0) > 0 end) end
    local out = {}
    for row = 1, (lst.Items() or 0) do
        local name = trim(lst.List(row, 2)())
        if name ~= '' and isChase(name) then
            table.insert(out, { name = name, priceCp = rowPrice(lst, row), trader = trim(lst.List(row, 8)()) })
        end
    end
    return out
end

-- the result list row for a listing: same name, trader and price. The rows aren't in ${Bazaar.Item} order (row 1 was
-- another trader's item), so never select by index. Columns: 2 name, 3 qty, 4-7 price in pp / gp / sp / cp, 8 trader
local function findRow(r)
    local lst = searchWnd().Child('BZR_ItemList')
    for row = 1, (lst.Items() or 0) do
        if trim(lst.List(row, 2)()) == r.name and trim(lst.List(row, 8)()) == r.trader and rowPrice(lst, row) == r.priceCp then return row end
    end
end

local function buy(r)
    local lst = searchWnd().Child('BZR_ItemList')
    local row = findRow(r)
    if not row then log('  %s from %s: not in the result list any more', r.name, r.trader); return false end
    mq.cmdf('/notify BazaarSearchWnd BZR_ItemList listselect %d', row)
    mq.delay(1500, function() return lst.GetCurSel() == row end)
    if lst.GetCurSel() ~= row then log('  %s: could not select its row', r.name); return false end
    mq.cmd('/notify BazaarSearchWnd BZR_BuyButton leftmouseup')
    local cw = mq.TLO.Window('BazaarConfirmationWnd')
    mq.delay(4000, function() return cw.Open() end)
    if not cw.Open() then log('  %s: no confirmation window', r.name); return false end
    local label, total = cw.Child('BZC_ItemLabel').Text() or '', cw.Child('BZC_TotalPrice').Text() or ''
    if not label:lower():find(r.name:lower(), 1, true) then
        log('  %s: the confirmation is for "%s" - cancelled', r.name, label)
        mq.cmd('/notify BazaarConfirmationWnd BZC_CancelButton leftmouseup')
        return false
    end
    mq.cmd('/notify BazaarConfirmationWnd BZC_UsePlatButton leftmouseup')
    mq.delay(4000, function() return not cw.Open() end)
    if cw.Open() then
        mq.cmd('/notify BazaarConfirmationWnd BZC_CancelButton leftmouseup')
        log('  %s: the purchase did not go through', r.name)
        return false
    end
    log('  bought %s from %s, total %s (it comes by parcel)', r.name, r.trader, total)
    return true
end

local function pass(terms)
    local seen, nBought = 0, 0
    for i, term in ipairs(terms) do
        if not running then return end
        if i % 100 == 0 then log('%d of %d searches done', i, #terms) end
        local best = {}
        for _, r in ipairs(search(term)) do
            local k = r.name:lower()
            if r.priceCp <= MAX_PRICE_PP * 1000 and not bought[k] and (not best[k] or r.priceCp < best[k].priceCp) then best[k] = r end
        end
        for k, r in pairs(best) do
            seen = seen + 1
            if owned(r.name) then
                bought[k] = true
            elseif DRY then
                log('  for sale: %s at %s from %s', r.name, r.priceCp < 1000 and (r.priceCp .. 'cp') or string.format('%.2fpp', r.priceCp / 1000), r.trader)
            elseif buy(r) then
                markBought(r.name); nBought = nBought + 1
            end
        end
        mq.delay(SEARCH_GAP_MS)
    end
    log('pass done: %d chase item(s) under %dpp seen, %d bought', seen, MAX_PRICE_PP, nBought)
end

if mq.TLO.EverQuest.GameState() ~= 'INGAME' then log('not in game'); return end
if not mq.TLO.Plugin('mq2bzsrch').IsLoaded() then mq.cmd('/plugin mq2bzsrch'); mq.delay(1000) end
if not ensureWindow() then log('could not open the Bazaar search window (/bazaar)'); return end
local terms = searchTerms()
log('start%s%s: %d searches a pass, cap %dpp, %d item(s) bought before', DRY and ' (dry run)' or '', ONCE and ' (one pass)' or '',
    #terms, MAX_PRICE_PP, (function() local n = 0 for _ in pairs(bought) do n = n + 1 end return n end)())
-- a pass that errors is logged and the next one starts on time (the window is opened again if it was closed): the
-- script stopped silently once after 45 minutes with the search window shut
while running do
    if not ensureWindow() then log('the Bazaar search window would not open - trying again next pass')
    else
        local ok, err = pcall(pass, terms)
        if not ok then log('pass failed: %s', tostring(err)) end
    end
    if ONCE or not running then break end
    log('next pass in %ds', PASS_GAP_S)
    mq.delay(PASS_GAP_S * 1000, function() return not running end)
end
log('stopped')
logf:close()
