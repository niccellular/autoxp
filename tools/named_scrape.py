"""Named-mode data for one zone from eqresource.com. AutoXP runs it in the background the first time a zone is hunted in
Named mode (no named/<zone>.lua yet); by hand:

    python named_scrape.py <zone short> "<zone name>" "<expansion>" <out dir>

Writes <out dir>/<zone>.lua: the zone's named with their placeholders (Named All Info page), the map points posted in
the Named Spawn Overview page's comments (EQ map lines "P x, y, z, r, g, b, size, label": map x/y are the in-game X/Y
negated). On failure it writes <out dir>/<zone>.err with the reason instead."""
import difflib, html, os, re, sys, urllib.request
from datetime import date

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'


class Fail(Exception):
    pass


def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': 'text/html', 'Accept-Language': 'en-US,en;q=0.9'})
    return urllib.request.urlopen(req, timeout=30).read().decode('utf-8', 'replace')


def lines(t):
    """a page's text, one trimmed line per element"""
    t = re.sub(r'<script.*?</script>', '', t, flags=re.S)
    t = re.sub(r'<style.*?</style>', '', t, flags=re.S)
    s = html.unescape(re.sub(r'<[^>]+>', '\n', t)).replace('\xa0', ' ').replace('�', ' ')
    return [l for l in (re.sub(r'\s+', ' ', x).strip() for x in s.split('\n')) if l]


def norm(s):
    """'Laurion's Inn' and 'Laurion Inn' -> 'laurioninn'"""
    s = re.sub(r"'s\b", '', s.lower())
    s = re.sub(r'^the ', '', s)
    return re.sub(r'[^a-z0-9]', '', s)


def zone_page(short, name, exp):
    """the expansion's site (its initials: Laurion's Song -> ls) and the zone's page key there"""
    sub = ''.join(w[0] for w in re.findall(r"[A-Za-z']+", exp)).lower()
    base = 'https://%s.eqresource.com/' % sub
    try:
        t = get(base)
    except Exception as e:
        raise Fail('%s: %s' % (base, e))
    zones = [(k, html.unescape(d).strip()) for k, d in re.findall(r'<a href="([a-z0-9]+)\.php">([^<]+)</a>\s*<div id="\1"', t)
             if 'allname%s.php' % k in t]
    if not zones:
        raise Fail('no named pages on %s' % base)
    for k, d in zones:
        if k == short or norm(d) == norm(name):
            return base, k, d
    for k, d in zones:
        if k.startswith(short) or short.startswith(k) or k.endswith(short):
            return base, k, d
    k, d = max(zones, key=lambda z: difflib.SequenceMatcher(None, norm(z[1]), norm(name)).ratio())
    if difflib.SequenceMatcher(None, norm(d), norm(name)).ratio() >= 0.75:
        return base, k, d
    raise Fail('%s is not among the named pages on %s (%s)' % (name, base, ', '.join(d for _, d in zones)))


def parse_named(t):
    """[{name, ph=[...], items=[(id, name)]}] from a Named All Info page"""
    out = []
    for m in re.finditer(r'<font size="\+1">\s*(.*?)\s*</font>(.*?)(?=<font size="\+1">|<div id="footer"|$)', t, re.S):
        name = re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', '', m.group(1)))).strip()
        body = m.group(2)
        ph = []
        pm = re.search(r'<li>\s*PH:(.*?)</li>', body, re.S)
        if pm:
            txt = re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', '', pm.group(1)))).strip()
            for p in re.split(r'\s+-or-\s+|\s*,\s*|\s+or\s+|\s*/\s*', txt):
                p = p.strip(' .')
                if p and p.lower() not in ('none', 'unknown', 'n/a', 'no ph', '?') and not p.startswith('('):
                    ph.append(p)
        if name:
            out.append({'name': name, 'ph': ph})
    return out


def parse_spots(t, named):
    """map points posted on the Named Spawn Overview page: [{y, x, z, names}] in in-game coordinates"""
    known = {n['name'].lower(): n['name'] for n in named}
    spots = []
    for l in lines(t):
        m = re.match(r'P\s+(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,(.*)$', l)
        if not m:
            continue
        label = m.group(4).split(',')[-1]
        names = []
        for n in re.split(r'[\\/]', label):
            n = re.sub(r'\s+', ' ', n.replace('_', ' ')).strip()
            if not n:
                continue
            hit = known.get(n.lower()) or next(iter(difflib.get_close_matches(n.lower(), list(known), 1, 0.85)), None)
            names.append(known.get(hit, hit) if hit else n)
        spots.append({'y': -float(m.group(2)), 'x': -float(m.group(1)), 'z': float(m.group(3)), 'names': names})
    return spots


def lua_str(s):
    return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"')


def main():
    short, name, exp, out = sys.argv[1:5]
    os.makedirs(out, exist_ok=True)
    err = os.path.join(out, short + '.err')
    if os.path.exists(err):
        os.remove(err)
    try:
        base, key, shown = zone_page(short, name, exp)
        named = parse_named(get(base + 'allname%s.php' % key))
        if not named:
            raise Fail('no named on %sallname%s.php' % (base, key))
        try:
            spots = parse_spots(get(base + 'name%s.php' % key), named)
        except Exception:
            spots = []
        o = ['-- %s (%s): generated by tools/named_scrape.py from %sallname%s.php and %sname%s.php, %s' %
             (shown, short, base, key, base, key, date.today().isoformat()),
             'return {',
             '    zone = %s, name = %s, url = %s,' % (lua_str(short), lua_str(shown), lua_str(base + 'name%s.php' % key)),
             '    named = {']
        for n in named:
            o.append('        { name = %s, ph = { %s } },' % (lua_str(n['name']), ', '.join(lua_str(p) for p in n['ph'])))
        o.append('    },')
        o.append('    -- map points posted in the page comments (in-game y, x, z) and the named that spawn there')
        o.append('    spots = {')
        for s in spots:
            o.append('        { y = %.1f, x = %.1f, z = %.1f, named = { %s } },' % (s['y'], s['x'], s['z'], ', '.join(lua_str(n) for n in s['names'])))
        o.append('    },')
        o.append('}')
        tmp = os.path.join(out, short + '.tmp')
        open(tmp, 'w', encoding='utf-8', newline='\r\n').write('\n'.join(o) + '\n')
        os.replace(tmp, os.path.join(out, short + '.lua'))
        print('%s: %d named, %d map points' % (shown, len(named), len(spots)))
    except Exception as e:
        open(err, 'w', encoding='utf-8').write('%s\n' % e)
        print('failed:', e)
        sys.exit(1)


if __name__ == '__main__':
    main()
