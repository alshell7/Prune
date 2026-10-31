#!/usr/bin/env python3
"""Generates the autoplaying scenario animations in docs/media (animated SVG, pure CSS, no JS)."""
import os
from html import escape

OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "media")
os.makedirs(OUT, exist_ok=True)
W, H, DUR = 820, 470, 9

BASE_CSS = f"""
  .win {{ fill:#1c1d22; }} .side {{ fill:#24252b; }} .bar {{ fill:#2a2b32; }}
  .t {{ font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',Helvetica,Arial,sans-serif; fill:#e8e8ee; }}
  .s {{ fill:#9a9aa6; }} .b {{ font-weight:600; }} .m {{ font-family:'SF Mono',Menlo,Consolas,monospace; }}
  .card {{ fill:#26272e; stroke:#33343c; }}
  .acc {{ fill:#3b82f6; }} .ok {{ fill:#34c759; }} .warn {{ fill:#ff9f0a; }} .bad {{ fill:#ff453a; }} .teal {{ fill:#40c8e0; }} .pink {{ fill:#ff6b9d; }}
  .loop {{ animation-duration:{DUR}s; animation-iteration-count:infinite; animation-timing-function:cubic-bezier(.4,0,.2,1); }}
  @media (prefers-reduced-motion: reduce) {{ .loop {{ animation:none !important; }} }}
"""

def frame(title, active, body, css=""):
    side_items = ["Overview", "Cleanup", "Security", "Secrets", "Code Backup", "Apps & Extensions", "Offload to Drive", "Project Doctor", "Space Timeline"]
    side = []
    y = 78
    for item in side_items:
        if item == active:
            side.append(f'<rect x="10" y="{y-15}" width="170" height="24" rx="6" class="acc" opacity=".9"/>')
        side.append(f'<text x="24" y="{y+1}" class="t" font-size="12.5" {"" if item == active else "opacity=\".8\""}>{escape(item)}</text>')
        y += 30
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="{escape(title)}">
<style>{BASE_CSS}{css}</style>
<defs>
  <filter id="sh" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-opacity=".35"/></filter>
  <linearGradient id="ring" x1="0" x2="1"><stop offset="0" stop-color="#3b82f6"/><stop offset="1" stop-color="#8b5cf6"/></linearGradient>
</defs>
<rect x="10" y="8" width="{W-20}" height="{H-24}" rx="14" class="win" filter="url(#sh)"/>
<path d="M10 22 a14 14 0 0 1 14 -14 H190 V{H-16} H24 a14 14 0 0 1 -14 -14 Z" class="side"/>
<circle cx="32" cy="30" r="6" fill="#ff5f57"/><circle cx="52" cy="30" r="6" fill="#febc2e"/><circle cx="72" cy="30" r="6" fill="#28c840"/>
<g transform="translate(0,0)">{"".join(side)}</g>
<text x="214" y="36" class="t b" font-size="15">{escape(title)}</text>
<g transform="translate(206,52)">{body}</g>
</svg>'''

def write(name, svg):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(svg)
    print("wrote", name)

# 1. Hero: scan → findings → clean → space returns
hero_css = """
  .scanbar { animation-name: scan; } @keyframes scan { 0%{width:0} 22%{width:560px} 23%,100%{width:560px;opacity:0} }
  .row { opacity:0; animation-name: rowin; } @keyframes rowin { 0%,24%{opacity:0;transform:translateX(16px)} 30%,62%{opacity:1;transform:none} 72%,100%{opacity:0;transform:translateX(300px)} }
  .r2 { animation-delay:.25s } .r3 { animation-delay:.5s } .r4 { animation-delay:.75s }
  .tick { opacity:0; animation-name: tick; } @keyframes tick { 0%,44%{opacity:0} 48%,66%{opacity:1} 72%,100%{opacity:0} }
  .t2 { animation-delay:.2s } .t3 { animation-delay:.4s } .t4 { animation-delay:.6s }
  .used { animation-name: used; transform-origin: center; } @keyframes used { 0%,66%{stroke-dashoffset:40} 80%,100%{stroke-dashoffset:150} }
  .free1 { animation-name: f1; } @keyframes f1 { 0%,66%{opacity:1} 72%,100%{opacity:0} }
  .free2 { animation-name: f2; opacity:0 } @keyframes f2 { 0%,70%{opacity:0} 78%,96%{opacity:1} 100%{opacity:0} }
  .btn { animation-name: press; transform-origin: 520px 360px; } @keyframes press { 0%,58%{transform:scale(1)} 61%{transform:scale(.92)} 64%,100%{transform:scale(1)} }
  .bin { animation-name: bin; transform-origin: 556px 300px; } @keyframes bin { 0%,66%{transform:scale(1)} 70%{transform:scale(1.18)} 76%,100%{transform:scale(1)} }
"""
rows = [("node_modules", "DayBloom · untouched 3 months", "1.5 GB", "Safe", "ok"),
        ("DerivedData", "Xcode builds", "6.2 GB", "Safe", "ok"),
        (".next cache", "AFLABS-CX · rebuilds on dev", "5.1 GB", "Safe", "ok"),
        ("Rust target/", "Old experiment", "3.8 GB", "Low risk", "acc")]
rbody = ""
for i, (n, d, sz, risk, cls) in enumerate(rows):
    y = 128 + i * 46
    rbody += f'''<g class="row loop r{i+1}"><rect x="0" y="{y}" width="430" height="38" rx="8" class="card"/>
<text x="14" y="{y+16}" class="t b" font-size="12.5">{n}</text><text x="14" y="{y+31}" class="t s" font-size="10.5">{d}</text>
<rect x="300" y="{y+11}" width="56" height="16" rx="8" class="{cls}" opacity=".22"/><text x="328" y="{y+23}" class="t" font-size="9.5" text-anchor="middle">{risk}</text>
<text x="420" y="{y+24}" class="t m" font-size="12" text-anchor="end">{sz}</text>
<g class="tick loop t{i+1}"><circle cx="-12" cy="{y+19}" r="8" class="ok"/><path d="M-16 {y+19} l3 3 l6 -6" stroke="#fff" stroke-width="2" fill="none"/></g></g>'''
hero = f'''
<text x="8" y="22" class="t s" font-size="11.5">Smart disk cleanup for developers</text>
<rect x="8" y="38" width="560" height="6" rx="3" fill="#33343c"/><rect x="8" y="38" height="6" rx="3" class="acc scanbar loop"/>
<text x="8" y="66" class="t b" font-size="20">Recommended cleanup</text>
<text x="8" y="94" class="t" font-size="26" font-weight="700" fill="#34c759">16.6 GB</text>
<text x="120" y="94" class="t s" font-size="11">across 4 items · nothing deleted until you review</text>
{rbody}
<g transform="translate(500,96)">
  <circle cx="56" cy="56" r="46" fill="none" stroke="#33343c" stroke-width="12"/>
  <circle cx="56" cy="56" r="46" fill="none" stroke="url(#ring)" stroke-width="12" stroke-linecap="round" stroke-dasharray="289" stroke-dashoffset="40" transform="rotate(-90 56 56)" class="used loop"/>
  <text x="56" y="54" class="t b free1 loop" font-size="15" text-anchor="middle">7.2 GB</text>
  <text x="56" y="54" class="t b free2 loop" font-size="15" text-anchor="middle" fill="#34c759">23.8 GB</text>
  <text x="56" y="72" class="t s" font-size="10" text-anchor="middle">free</text>
</g>
<g class="bin loop"><rect x="520" y="282" width="72" height="32" rx="8" fill="#2f3038"/><text x="556" y="303" class="t" font-size="16" text-anchor="middle">🗑</text></g>
<g class="btn loop"><rect x="452" y="340" width="140" height="34" rx="9" class="acc"/><text x="522" y="362" class="t b" font-size="12.5" text-anchor="middle">Review &amp; Clean</text></g>
'''
write("hero.svg", frame("Overview", "Overview", hero, hero_css))

# 2. External drives: switch disk scope
ext_css = """
  .chipsel { animation-name: chip; } @keyframes chip { 0%,30%{transform:translateX(0)} 36%,64%{transform:translateX(132px)} 70%,100%{transform:translateX(264px)} }
  .pA { animation-name: pa; } @keyframes pa { 0%,30%{opacity:1} 34%,100%{opacity:0} }
  .pB { animation-name: pb; opacity:0 } @keyframes pb { 0%,32%{opacity:0} 38%,64%{opacity:1} 68%,100%{opacity:0} }
  .pC { animation-name: pc; opacity:0 } @keyframes pc { 0%,66%{opacity:0} 72%,96%{opacity:1} 100%{opacity:0} }
  .cursor { animation-name: cur; } @keyframes cur { 0%,26%{transform:translate(60px,30px)} 32%,60%{transform:translate(190px,30px)} 66%,100%{transform:translate(322px,30px)} }
"""
def tiles(items, cls):
    out = f'<g class="{cls} loop">'
    for i, (n, d, sz, badge) in enumerate(items):
        y = 70 + i * 50
        out += f'''<rect x="0" y="{y}" width="580" height="42" rx="9" class="card"/>
<text x="14" y="{y+18}" class="t b" font-size="12.5">{n}</text><text x="14" y="{y+33}" class="t s" font-size="10.5">{d}</text>'''
        if badge:
            out += f'<rect x="{30+len(n)*7.2}" y="{y+6}" width="64" height="16" rx="8" class="teal" opacity=".2"/><text x="{62+len(n)*7.2}" y="{y+18}" class="t" font-size="9.5" fill="#40c8e0" text-anchor="middle">⏏ Work HD</text>'
        out += f'<text x="566" y="{y+26}" class="t m" font-size="12" text-anchor="end">{sz}</text>'
    return out + "</g>"
ext = f'''
<g>
 <rect x="0" y="6" width="124" height="28" rx="14" fill="#2f3038"/><text x="62" y="25" class="t" font-size="12" text-anchor="middle">All disks</text>
 <rect x="132" y="6" width="124" height="28" rx="14" fill="#2f3038"/><text x="194" y="25" class="t" font-size="12" text-anchor="middle">Macintosh HD</text>
 <rect x="264" y="6" width="124" height="28" rx="14" fill="#2f3038"/><text x="326" y="25" class="t" font-size="12" text-anchor="middle">Work HD</text>
 <g class="chipsel loop"><rect x="0" y="6" width="124" height="28" rx="14" class="acc" opacity=".35"/></g>
</g>
{tiles([("DayBloom/target", "Rust build output", "3.8 GB", True), ("~/Library/Developer/Xcode/DerivedData", "Xcode", "6.2 GB", False), ("AFLABS-CX/.next", "Next.js cache", "5.1 GB", True), ("~/.npm/_cacache", "npm cache", "870 MB", False)], "pA")}
{tiles([("~/Library/Developer/Xcode/DerivedData", "Xcode", "6.2 GB", False), ("~/.npm/_cacache", "npm cache", "870 MB", False), ("~/Library/Caches/uv", "uv cache", "4.0 GB", False)], "pB")}
{tiles([("AFLABS-CX/.next", "Next.js cache", "5.1 GB", True), ("DayBloom/target", "Rust build output", "3.8 GB", True), ("vow-offers/tmp/ios-sourcepackages", "Swift package clones · moved project", "1.1 GB", True), ("Downloads/Xcode_26.xip", "Installer, already installed", "8.9 GB", True)], "pC")}
<g class="cursor loop"><path d="M0 0 L0 16 L4 12 L7 19 L10 18 L7 11 L12 11 Z" fill="#fff" stroke="#000" stroke-width=".8"/></g>
<text x="0" y="300" class="t s" font-size="11">Every analyzed disk gets its own totals, suggestions, Code Backup and Secrets results.</text>
'''
write("external-drives.svg", frame("Cleanup · every disk", "Cleanup", ext, ext_css))

# 3. Secrets
sec_css = """
  .scan { animation-name: sl; } @keyframes sl { 0%{transform:translateY(0);opacity:0} 4%{opacity:.9} 26%{transform:translateY(150px);opacity:.9} 30%,100%{transform:translateY(150px);opacity:0} }
  .hl { opacity:0; animation-name: hl; } @keyframes hl { 0%,14%{opacity:0} 18%,100%{opacity:1} }
  .raw { animation-name: raw; } @keyframes raw { 0%,30%{opacity:1} 36%,100%{opacity:0} }
  .mask { opacity:0; animation-name: mask; } @keyframes mask { 0%,32%{opacity:0} 38%,100%{opacity:1} }
  .chain { opacity:0; animation-name: ch; } @keyframes ch { 0%,40%{opacity:0;transform:translateY(8px)} 46%,100%{opacity:1;transform:none} }
  .c2 { animation-delay:.4s } .c3 { animation-delay:.8s }
  .pushed { animation-name: pu; transform-origin: 470px 212px; } @keyframes pu { 0%,52%{transform:scale(1)} 55%{transform:scale(1.25)} 58%,100%{transform:scale(1)} }
  .fix { opacity:0; animation-name: fx; } @keyframes fx { 0%,70%{opacity:0} 74%,100%{opacity:1} }
  .btn2 { animation-name: bp; transform-origin: 500px 330px; } @keyframes bp { 0%,64%{transform:scale(1)} 67%{transform:scale(.92)} 70%,100%{transform:scale(1)} }
"""
sec = f'''
<rect x="0" y="0" width="330" height="170" rx="10" fill="#15161a" stroke="#33343c"/>
<text x="12" y="20" class="t s m" font-size="10.5">.env  ·  credos-it-evalix</text>
<text x="12" y="48" class="t m" font-size="11.5"><tspan fill="#9a9aa6">1</tspan>  NODE_ENV=production</text>
<rect x="8" y="58" width="314" height="20" rx="4" class="bad hl loop" opacity=".18"/>
<text x="12" y="72" class="t m" font-size="11.5"><tspan fill="#9a9aa6">2</tspan>  OPENAI_API_KEY=<tspan class="raw loop">sk-proj-Q7v2KxR9mZ4t…</tspan></text>
<text x="132" y="72" class="t m mask loop" font-size="11.5" fill="#ff9f0a">sk-proj-••••••••7b</text>
<text x="12" y="96" class="t m" font-size="11.5"><tspan fill="#9a9aa6">3</tspan>  DATABASE_URL=${{DB_URL}}</text>
<text x="12" y="120" class="t m" font-size="11.5"><tspan fill="#9a9aa6">4</tspan>  DEBUG=false</text>
<rect x="0" y="10" width="330" height="2" class="acc scan loop"/>
<g class="chain loop"><rect x="0" y="196" width="140" height="48" rx="9" class="card"/><text x="12" y="215" class="t s" font-size="10">FILE</text><text x="12" y="234" class="t b" font-size="12">.env · 1 secret</text></g>
<g class="chain loop c2"><rect x="160" y="196" width="140" height="48" rx="9" class="card"/><text x="172" y="215" class="t s" font-size="10">GIT</text><text x="172" y="234" class="t b" font-size="12" fill="#ff9f0a">Tracked</text></g>
<g class="chain loop c3"><rect x="320" y="196" width="190" height="48" rx="9" class="card" stroke="#ff453a"/><text x="332" y="215" class="t s" font-size="10">REMOTE</text><text x="332" y="234" class="t b" font-size="12" fill="#ff453a">Pushed · rotate now</text>
 <g class="pushed loop"><rect x="440" y="203" width="60" height="18" rx="9" class="bad"/><text x="470" y="216" class="t b" font-size="9.5" text-anchor="middle">PUSHED</text></g></g>
<path d="M140 220 h20 M300 220 h20" stroke="#55565f" stroke-width="2" stroke-dasharray="4 3"/>
<g transform="translate(360,0)">
 <rect x="0" y="0" width="230" height="170" rx="10" class="card"/>
 <text x="14" y="26" class="t b" font-size="13">OpenAI API key</text>
 <text x="14" y="46" class="t s" font-size="10.5">line 2 · matches the key format</text>
 <rect x="14" y="60" width="200" height="6" rx="3" fill="#33343c"/><rect x="14" y="60" width="194" height="6" rx="3" class="bad"/>
 <text x="14" y="84" class="t s" font-size="10">97% sure · value never stored</text>
 <text x="14" y="112" class="t s" font-size="10.5">Also found: 2 env files not ignored,</text>
 <text x="14" y="128" class="t s" font-size="10.5">1 token exported in ~/.zshrc</text>
</g>
<g class="btn2 loop"><rect x="420" y="314" width="170" height="32" rx="9" class="acc"/><text x="505" y="335" class="t b" font-size="12" text-anchor="middle">Stop tracking + ignore</text></g>
<g class="fix loop"><circle cx="12" cy="330" r="9" class="ok"/><path d="M7 330 l3 3 l6 -6" stroke="#fff" stroke-width="2" fill="none"/>
<text x="28" y="334" class="t" font-size="11.5">git rm --cached .env · added to .gitignore · .env.example created</text></g>
'''
write("secrets.svg", frame("Secrets", "Secrets", sec, sec_css))

# 4. Offload
off_css = """
  .mv { animation-name: mv; } @keyframes mv { 0%,8%{transform:translate(0,0);opacity:1} 40%{transform:translate(330px,0);opacity:1} 44%,100%{transform:translate(330px,0);opacity:0} }
  .d2 { animation-delay:.6s } .d3 { animation-delay:1.2s }
  .skip { animation-name: sk; } @keyframes sk { 0%,14%{transform:none;opacity:1} 28%,100%{transform:translate(120px,90px) scale(.6);opacity:0} }
  .prog { animation-name: pg; } @keyframes pg { 0%,6%{width:0} 52%{width:250px} 100%{width:250px} }
  .ver { opacity:0; animation-name: vr; } @keyframes vr { 0%,54%{opacity:0} 58%,100%{opacity:1} }
  .lnk { opacity:0; animation-name: lk; } @keyframes lk { 0%,62%{opacity:0;transform:scale(.6)} 68%,100%{opacity:1;transform:none} }
  .ssd { animation-name: ssd; } @keyframes ssd { 0%,40%{fill:#26272e} 46%,100%{fill:#163a40} }
"""
def folder(x, y, label, cls=""):
    return f'<g class="{cls}"><path d="M{x} {y+6} h18 l5 -6 h27 a4 4 0 0 1 4 4 v34 a4 4 0 0 1 -4 4 h-46 a4 4 0 0 1 -4 -4 Z" fill="#3b82f6" opacity=".9"/><text x="{x+27}" y="{y+56}" class="t" font-size="10" text-anchor="middle">{label}</text></g>'
off = f'''
<rect x="0" y="10" width="190" height="220" rx="12" class="card"/><text x="95" y="36" class="t b" font-size="12.5" text-anchor="middle">💻 This Mac</text>
<rect x="400" y="10" width="190" height="220" rx="12" class="card ssd loop"/><text x="495" y="36" class="t b" font-size="12.5" text-anchor="middle">⏏ Work HD (SSD)</text>
{folder(30, 60, "Projects", "mv loop")}
{folder(118, 60, "Downloads", "mv loop d2")}
{folder(30, 140, "Documents", "mv loop d3")}
<g class="skip loop"><rect x="104" y="146" width="56" height="40" rx="6" fill="#55565f"/><text x="132" y="171" class="t" font-size="9" text-anchor="middle">node_modules</text></g>
<text x="300" y="260" class="t s" font-size="10.5" text-anchor="middle">Rebuildable caches are skipped: less to copy</text>
<rect x="170" y="280" width="250" height="8" rx="4" fill="#33343c"/><rect x="170" y="280" height="8" rx="4" class="teal prog loop"/>
<g class="ver loop"><circle cx="186" cy="312" r="8" class="ok"/><path d="M182 312 l3 3 l6 -6" stroke="#fff" stroke-width="2" fill="none"/>
<text x="200" y="316" class="t" font-size="11.5">SHA-256 verified · 12,408 files</text></g>
<g class="lnk loop"><text x="95" y="120" class="t" font-size="11" text-anchor="middle" fill="#40c8e0">🔗 Projects → Work HD</text><text x="95" y="138" class="t s" font-size="10" text-anchor="middle">paths keep working</text></g>
'''
write("offload.svg", frame("Offload to Drive", "Offload to Drive", off, off_css))

# 5. Doctor + dangling extension
doc_css = """
  .broken { animation-name: br; } @keyframes br { 0%,30%{stroke:#ff453a;stroke-dasharray:6 6} 40%,100%{stroke:#34c759;stroke-dasharray:0} }
  .gap { animation-name: gp; } @keyframes gp { 0%,30%{opacity:1} 38%,100%{opacity:0} }
  .fixed { opacity:0; animation-name: fd; } @keyframes fd { 0%,36%{opacity:0} 42%,100%{opacity:1} }
  .step { opacity:.35; animation-name: st; } @keyframes st { 0%,50%{opacity:.35} 56%,100%{opacity:1} }
  .s2 { animation-delay:.9s } .s3 { animation-delay:1.8s }
  .chk { opacity:0; animation-name: ck; transform-box: fill-box; transform-origin:center; } @keyframes ck { 0%,54%{opacity:0;transform:scale(.4)} 60%,100%{opacity:1;transform:none} }
"""
doc = f'''
<text x="0" y="10" class="t b" font-size="13">Projects moved from ~/Documents/Development</text>
<rect x="0" y="24" width="580" height="74" rx="10" class="card"/>
<text x="14" y="46" class="t b" font-size="12">Meta-Gateway/src</text><text x="14" y="62" class="t s" font-size="10.5">symlink to the project's old location</text>
<line x1="250" y1="58" x2="440" y2="58" stroke-width="3" class="broken loop"/>
<text x="345" y="50" class="t gap loop" font-size="16" text-anchor="middle">✂</text>
<rect x="452" y="44" width="116" height="26" rx="8" class="ok fixed loop" opacity=".25"/><text x="510" y="62" class="t fixed loop" font-size="11" text-anchor="middle" fill="#34c759">Relinked ✓</text>
<text x="14" y="86" class="t s m" font-size="9.5">.venv · worktrees · git object links · stale locks · git gc</text>
<text x="0" y="132" class="t b" font-size="13">Dangling driver: Karabiner VirtualHIDDevice (app gone)</text>
'''
for i, (t, d) in enumerate([("Stop it from loading", "turned off in Login Items &amp; Extensions"), ("Remove leftover files", "/Library/Application Support/org.pqrs → Quarantine"), ("macOS's copy", "disabled extensions never load")]):
    y = 146 + i * 50
    doc += f'''<g class="step loop s{i+1}"><rect x="0" y="{y}" width="580" height="42" rx="9" class="card"/>
<circle cx="22" cy="{y+21}" r="11" fill="#33343c"/><g class="chk loop s{i+1}"><circle cx="22" cy="{y+21}" r="11" class="ok"/><path d="M17 {y+21} l3 3 l6 -6" stroke="#fff" stroke-width="2" fill="none"/></g>
<text x="44" y="{y+18}" class="t b" font-size="12">{t}</text><text x="44" y="{y+33}" class="t s" font-size="10.5">{d}</text></g>'''
write("doctor.svg", frame("Project Doctor · Apps & Extensions", "Project Doctor", doc, doc_css))

# 6. Space timeline
tl_css = """
  .line { stroke-dasharray: 900; animation-name: dr; } @keyframes dr { 0%{stroke-dashoffset:900} 55%,100%{stroke-dashoffset:0} }
  .fc { opacity:0; animation-name: fc; } @keyframes fc { 0%,55%{opacity:0} 62%,100%{opacity:1} }
  .dot { animation-name: dt; } @keyframes dt { 0%,100%{r:4} 50%{r:7} }
"""
pts = [(0, 60), (60, 70), (120, 84), (180, 92), (240, 118), (270, 40), (330, 52), (390, 66), (450, 80), (510, 96)]
path = "M" + " L".join(f"{x+20} {y+40}" for x, y in pts)
tl = f'''
<rect x="0" y="10" width="580" height="210" rx="12" class="card"/>
<text x="16" y="34" class="t b" font-size="12.5">Macintosh HD · 23.8 GB free</text>
<path d="{path}" fill="none" stroke="#3b82f6" stroke-width="3" stroke-linejoin="round" class="line loop"/>
<text x="292" y="72" class="t ok" font-size="10" text-anchor="middle">Cleaned 16.6 GB</text>
<path d="M530 136 L566 190" stroke="#ff9f0a" stroke-width="2" stroke-dasharray="5 4" class="fc loop"/>
<circle cx="530" cy="136" r="4" class="warn dot loop"/>
<g class="fc loop"><rect x="320" y="236" width="260" height="34" rx="9" fill="#3a2a10"/><text x="450" y="257" class="t" font-size="12" text-anchor="middle" fill="#ff9f0a">⚠ Full in ~19 days at 1.2 GB/day</text></g>
'''
write("timeline.svg", frame("Space Timeline", "Space Timeline", tl, tl_css))
