#!/usr/bin/env python3
"""Lightweight web dashboard for the Codex-Marveen system.

Dependency-free (Python stdlib only). Serves a single-page UI plus a small JSON
API over the SQLite database: agents, tiered memory (searchable), the kanban
board (add / move), inter-agent messages, and the daily log. Binds to localhost.

Run:  DASHBOARD_PORT=3420 python3 bin/dashboard.py
"""
import json, os, sqlite3, socketserver, subprocess, urllib.parse
import http.server

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.environ.get("DB", os.path.join(ROOT, "store", "system.db"))
PORT = int(os.environ.get("DASHBOARD_PORT", "3420"))
VAULT = os.environ.get("OBSIDIAN_VAULT", os.path.join(ROOT, "store", "vault"))


def vault_list():
    try:
        return sorted(f[:-3] for f in os.listdir(VAULT) if f.endswith(".md"))
    except FileNotFoundError:
        return []


def audit(action, detail=""):
    try:
        q("INSERT INTO audit_log(who,action,detail) VALUES('dashboard',?,?)", (action, detail))
    except Exception:
        pass


def vault_read(name):
    # path-safe: strip separators, only read a .md inside VAULT
    safe = os.path.basename(name).replace("/", "").replace("..", "")
    p = os.path.join(VAULT, safe + ".md")
    if os.path.isfile(p):
        with open(p, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    return ""


def q(sql, args=()):
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    try:
        cur = con.execute(sql, args)
        rows = [dict(r) for r in cur.fetchall()]
        con.commit()
        return rows
    finally:
        con.close()


HTML = r"""<!doctype html>
<html lang="hu"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Codex Assistant · Dashboard</title>
<link rel="manifest" href="/manifest.json">
<meta name="theme-color" content="#0f1216">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Codex">
<link rel="apple-touch-icon" href="/icon.svg">
<link rel="icon" href="/icon.svg">
<style>
  :root{--bg:#0f1216;--card:#1a1f27;--muted:#8b95a5;--fg:#e6e9ef;--acc:#5b9dff;--line:#2a313c}
  @media(prefers-color-scheme:light){:root{--bg:#f4f6fa;--card:#fff;--muted:#5b6472;--fg:#161a20;--acc:#2563eb;--line:#e2e7ef}}
  *{box-sizing:border-box}body{margin:0;font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--fg)}
  header{padding:16px 20px;border-bottom:1px solid var(--line);display:flex;gap:16px;align-items:center;flex-wrap:wrap}
  h1{font-size:18px;margin:0}nav{display:flex;gap:6px;flex-wrap:wrap}
  nav button{background:transparent;border:1px solid var(--line);color:var(--fg);padding:6px 12px;border-radius:8px;cursor:pointer}
  nav button.active{background:var(--acc);border-color:var(--acc);color:#fff}
  main{padding:20px;max-width:1100px;margin:0 auto}
  .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;margin-bottom:12px}
  .muted{color:var(--muted);font-size:13px}
  .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
  input,select,textarea{background:var(--bg);border:1px solid var(--line);color:var(--fg);padding:8px;border-radius:8px;font:inherit}
  button.act{background:var(--acc);border:none;color:#fff;padding:8px 12px;border-radius:8px;cursor:pointer}
  .cols{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
  @media(max-width:800px){.cols{grid-template-columns:1fr 1fr}}
  .col h3{margin:0 0 8px;font-size:13px;text-transform:uppercase;color:var(--muted)}
  .kc{background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:8px;margin-bottom:8px}
  .kc .t{font-weight:600}.pri{font-size:11px;padding:1px 6px;border-radius:6px;border:1px solid var(--line)}
  .pri.urgent{color:#ff6b6b;border-color:#ff6b6b}.pri.high{color:#ffa94d;border-color:#ffa94d}
  .tag{font-size:11px;padding:1px 6px;border-radius:6px;border:1px solid var(--line);color:var(--muted)}
  table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);font-size:13px;vertical-align:top}
  .hide{display:none}
</style></head><body>
<header><h1>🤖 Codex Assistant</h1>
  <nav>
    <button data-t="kanban" class="active">Kanban</button>
    <button data-t="memory">Memória</button>
    <button data-t="agents">Ügynökök</button>
    <button data-t="messages">Üzenetek</button>
    <button data-t="vault">Obsidian</button>
    <button data-t="approvals">Jóváhagyás</button>
    <button data-t="audit">Audit</button>
    <button data-t="log">Napló</button>
  </nav>
  <span class="muted" id="clock" style="margin-left:auto"></span>
</header>
<main>
  <section id="kanban">
    <div class="card"><div class="row">
      <input id="kt" placeholder="Új feladat..." style="flex:1;min-width:180px">
      <select id="kp"><option value="normal">normal</option><option value="low">low</option><option value="high">high</option><option value="urgent">urgent</option></select>
      <button class="act" onclick="addK()">Hozzáad</button>
    </div></div>
    <div class="cols" id="kb"></div>
  </section>

  <section id="memory" class="hide">
    <div class="card"><div class="row">
      <input id="ms" placeholder="Keresés a memóriában..." style="flex:1;min-width:180px" oninput="loadMem()">
      <select id="mc"><option value="hot">hot</option><option value="warm">warm</option><option value="cold">cold</option><option value="shared">shared</option></select>
      <input id="mtext" placeholder="Új emlék tartalma..." style="flex:2;min-width:200px">
      <button class="act" onclick="addMem()">Ment</button>
    </div></div>
    <div class="card"><table id="memt"><tbody></tbody></table></div>
  </section>

  <section id="agents" class="hide"><div class="card"><table id="agt"><thead><tr><th>Ügynök</th><th>Szerep</th><th>Állapot</th></tr></thead><tbody></tbody></table></div></section>
  <section id="messages" class="hide"><div class="card"><table id="msgt"><thead><tr><th>#</th><th>Kitől</th><th>Kinek</th><th>Állapot</th><th>Tartalom</th></tr></thead><tbody></tbody></table></div></section>
  <section id="vault" class="hide"><div class="row" style="align-items:flex-start;gap:12px">
    <div class="card" style="min-width:200px"><h3 style="margin-top:0;font-size:13px;color:var(--muted)">Jegyzetek</h3><div id="vlist"></div></div>
    <div class="card" style="flex:1"><pre id="vbody" style="white-space:pre-wrap;font:inherit;margin:0">Válassz egy jegyzetet…</pre></div>
  </div></section>
  <section id="approvals" class="hide"><div class="card"><table id="appt"><thead><tr><th>#</th><th>Ügynök</th><th>Művelet</th><th>Állapot</th><th></th></tr></thead><tbody></tbody></table></div></section>
  <section id="audit" class="hide"><div class="card"><table id="auditt"><thead><tr><th>Idő</th><th>Ki</th><th>Művelet</th><th>Részlet</th></tr></thead><tbody></tbody></table></div></section>
  <section id="log" class="hide"><div class="card"><table id="logt"><tbody></tbody></table></div></section>
</main>
<script>
const $=s=>document.querySelector(s), api=(p,o)=>fetch(p,o).then(r=>r.json());
function esc(s){return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function ts(x){return x?new Date(x*1000).toLocaleString('hu-HU'):''}
document.querySelectorAll('nav button').forEach(b=>b.onclick=()=>{
  document.querySelectorAll('nav button').forEach(x=>x.classList.remove('active'));b.classList.add('active');
  ['kanban','memory','agents','messages','vault','approvals','audit','log'].forEach(id=>$('#'+id).classList.toggle('hide',id!==b.dataset.t));
  load(b.dataset.t);
});
const COLS=[['planned','Tervezett'],['in_progress','Folyamatban'],['waiting','Várakozik'],['done','Kész']];
async function loadK(){const d=await api('/api/kanban');const kb=$('#kb');kb.innerHTML='';
  const subs=t=>d.filter(x=>x.parent_id===t.id);
  COLS.forEach(([s,label])=>{const c=document.createElement('div');c.className='col';c.innerHTML=`<h3>${label}</h3>`;
    d.filter(x=>x.status===s && !x.parent_id).forEach(t=>{const nx=COLS[(COLS.findIndex(z=>z[0]===s)+1)%4][0];
      const sub=subs(t).map(st=>`<div class="muted" style="font-size:12px;margin-top:3px">• ${esc(st.title)} <span class="tag">${st.status}</span></div>`).join('');
      c.innerHTML+=`<div class="kc"><div class="t">${t.stuck?'⚠️ ':''}${esc(t.title)}</div>
        <div class="row" style="margin-top:6px"><span class="pri ${t.priority}">${t.priority}</span>
        <button class="tag" onclick="moveK(${t.id},'${nx}')">→ ${nx}</button>
        <button class="tag" onclick="breakK(${t.id})">⚙︎ bontás</button></div>${sub}</div>`;});
    kb.appendChild(c);});}
async function addK(){const t=$('#kt').value.trim();if(!t)return;await api('/api/kanban/add',{method:'POST',body:new URLSearchParams({title:t,priority:$('#kp').value})});$('#kt').value='';loadK();}
async function moveK(id,st){await api('/api/kanban/move',{method:'POST',body:new URLSearchParams({id,status:st})});loadK();}
async function breakK(id){await api('/api/kanban/breakdown',{method:'POST',body:new URLSearchParams({id})});setTimeout(loadK,6000);}
async function loadMem(){const term=$('#ms').value.trim();const d=await api('/api/memories'+(term?('?q='+encodeURIComponent(term)):''));
  $('#memt').querySelector('tbody').innerHTML=d.map(m=>`<tr><td><span class="tag">${m.category}</span></td><td>${esc(m.content)}</td><td class="muted">${esc(m.keywords||'')}<br>${ts(m.created_at)}</td></tr>`).join('');}
async function addMem(){const c=$('#mtext').value.trim();if(!c)return;await api('/api/memory/add',{method:'POST',body:new URLSearchParams({content:c,category:$('#mc').value})});$('#mtext').value='';loadMem();}
async function loadAgents(){const d=await api('/api/agents');$('#agt').querySelector('tbody').innerHTML=d.map(a=>`<tr><td><b>${esc(a.name)}</b></td><td>${esc(a.role||'')}</td><td>${a.enabled?'🟢 aktív':'⚪ tiltva'}</td></tr>`).join('');}
async function loadMsg(){const d=await api('/api/messages');$('#msgt').querySelector('tbody').innerHTML=d.map(m=>`<tr><td>${m.id}</td><td>${esc(m.from_agent)}</td><td>${esc(m.to_agent)}</td><td><span class="tag">${m.status}</span></td><td>${esc((m.content||'').slice(0,120))}</td></tr>`).join('');}
async function loadLog(){const d=await api('/api/daily_log');$('#logt').querySelector('tbody').innerHTML=d.map(x=>`<tr><td class="muted" style="white-space:nowrap">${ts(x.created_at)}</td><td>${esc(x.entry)}</td></tr>`).join('');}
async function loadVault(){const d=await api('/api/vault');$('#vlist').innerHTML=d.length?d.map(n=>`<div class="kc" style="cursor:pointer" onclick="openNote('${encodeURIComponent(n)}')">${esc(n)}</div>`).join(''):'<span class="muted">Üres vault</span>';}
async function openNote(n){const d=await api('/api/vault/read?f='+n);$('#vbody').textContent=d.content||'(üres)';}
async function loadApp(){const d=await api('/api/approvals');$('#appt').querySelector('tbody').innerHTML=d.map(a=>`<tr><td>${a.id}</td><td>${esc(a.agent_id||'')}</td><td>${esc(a.action)}</td><td><span class="tag">${a.status}</span></td><td>${a.status==='pending'?`<button class="tag" onclick="resolveApp(${a.id},'approved')">✓</button> <button class="tag" onclick="resolveApp(${a.id},'denied')">✗</button>`:''}</td></tr>`).join('');}
async function resolveApp(id,st){await api('/api/approvals/resolve',{method:'POST',body:new URLSearchParams({id,status:st})});loadApp();}
async function loadAudit(){const d=await api('/api/audit');$('#auditt').querySelector('tbody').innerHTML=d.map(x=>`<tr><td class="muted" style="white-space:nowrap">${ts(x.created_at)}</td><td>${esc(x.who||'')}</td><td>${esc(x.action||'')}</td><td>${esc(x.detail||'')}</td></tr>`).join('');}
function load(t){({kanban:loadK,memory:loadMem,agents:loadAgents,messages:loadMsg,vault:loadVault,approvals:loadApp,audit:loadAudit,log:loadLog}[t]||loadK)();}
setInterval(()=>$('#clock').textContent=new Date().toLocaleTimeString('hu-HU'),1000);
if('serviceWorker' in navigator){navigator.serviceWorker.register('/sw.js').catch(()=>{});}
load('kanban');
</script></body></html>"""


ICON_SVG = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
            '<rect width="512" height="512" rx="96" fill="#0f1216"/>'
            '<rect x="128" y="176" width="256" height="192" rx="40" fill="#1a1f27" stroke="#5b9dff" stroke-width="12"/>'
            '<circle cx="200" cy="272" r="26" fill="#5b9dff"/><circle cx="312" cy="272" r="26" fill="#5b9dff"/>'
            '<rect x="196" y="330" width="120" height="16" rx="8" fill="#5b9dff"/>'
            '<rect x="248" y="120" width="16" height="56" fill="#5b9dff"/><circle cx="256" cy="112" r="18" fill="#5b9dff"/>'
            '</svg>')

SW_JS = r"""const C='codex-assistant-v1';
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.add('/')));self.skipWaiting();});
self.addEventListener('activate',e=>self.clients.claim());
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);
  if(u.pathname.startsWith('/api/'))return;
  e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request).then(resp=>{const cp=resp.clone();caches.open(C).then(c=>c.put(e.request,cp));return resp;}).catch(()=>caches.match('/'))));});
"""


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        try:
            if u.path == "/":
                return self._send(200, HTML, "text/html; charset=utf-8")
            if u.path == "/manifest.json":
                return self._send(200, json.dumps({
                    "name": "Codex Assistant", "short_name": "Codex", "start_url": "/",
                    "display": "standalone", "background_color": "#0f1216", "theme_color": "#0f1216",
                    "icons": [{"src": "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any maskable"}]
                }), "application/manifest+json")
            if u.path == "/icon.svg":
                return self._send(200, ICON_SVG, "image/svg+xml")
            if u.path == "/sw.js":
                return self._send(200, SW_JS, "application/javascript")
            if u.path == "/api/agents":
                return self._send(200, json.dumps(q("SELECT name,role,enabled FROM agents ORDER BY name")))
            if u.path == "/api/memories":
                term = urllib.parse.parse_qs(u.query).get("q", [""])[0]
                if term:
                    try:
                        rows = q("SELECT m.* FROM memories_fts f JOIN memories m ON m.id=f.rowid "
                                 "WHERE memories_fts MATCH ? ORDER BY rank LIMIT 200", (term,))
                    except Exception:
                        rows = q("SELECT * FROM memories WHERE content LIKE ? OR keywords LIKE ? ORDER BY id DESC LIMIT 200",
                                 (f"%{term}%", f"%{term}%"))
                else:
                    rows = q("SELECT * FROM memories ORDER BY id DESC LIMIT 200")
                return self._send(200, json.dumps(rows))
            if u.path == "/api/kanban":
                return self._send(200, json.dumps(q("SELECT * FROM kanban WHERE archived_at IS NULL ORDER BY COALESCE(parent_id,id), parent_id IS NOT NULL, updated_at DESC")))
            if u.path == "/api/messages":
                return self._send(200, json.dumps(q("SELECT * FROM agent_messages ORDER BY id DESC LIMIT 100")))
            if u.path == "/api/daily_log":
                return self._send(200, json.dumps(q("SELECT * FROM daily_log ORDER BY id DESC LIMIT 100")))
            if u.path == "/api/approvals":
                return self._send(200, json.dumps(q("SELECT * FROM approvals ORDER BY (status='pending') DESC, id DESC LIMIT 100")))
            if u.path == "/api/audit":
                return self._send(200, json.dumps(q("SELECT * FROM audit_log ORDER BY id DESC LIMIT 200")))
            if u.path == "/api/vault":
                return self._send(200, json.dumps(vault_list()))
            if u.path == "/api/vault/read":
                name = urllib.parse.parse_qs(u.query).get("f", [""])[0]
                return self._send(200, json.dumps({"name": name, "content": vault_read(name)}))
        except Exception as e:
            return self._send(500, json.dumps({"error": str(e)}))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        ln = int(self.headers.get("Content-Length", "0") or 0)
        data = urllib.parse.parse_qs(self.rfile.read(ln).decode() if ln else "")
        g = lambda k, d="": data.get(k, [d])[0]
        try:
            if u.path == "/api/kanban/add":
                if g("title"):
                    q("INSERT INTO kanban(title,priority) VALUES(?,?)", (g("title"), g("priority", "normal")))
                    audit("kanban.add", g("title"))
                return self._send(200, json.dumps({"ok": True}))
            if u.path == "/api/kanban/move":
                q("UPDATE kanban SET status=?, updated_at=strftime('%s','now') WHERE id=?", (g("status", "planned"), g("id", "0")))
                audit("kanban.move", f"#{g('id')} -> {g('status')}")
                return self._send(200, json.dumps({"ok": True}))
            if u.path == "/api/approvals/resolve":
                st = g("status", "denied")
                st = st if st in ("approved", "denied") else "denied"
                q("UPDATE approvals SET status=?, resolved_at=strftime('%s','now') WHERE id=?", (st, g("id", "0")))
                audit("approval." + st, f"#{g('id')}")
                return self._send(200, json.dumps({"ok": True}))
            if u.path == "/api/kanban/breakdown":
                cid = g("id", "")
                if cid:
                    env = dict(os.environ, DB=DB)
                    subprocess.Popen(["bash", os.path.join(ROOT, "bin", "kanban-breakdown.sh"), cid],
                                     env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return self._send(200, json.dumps({"ok": True, "note": "breakdown running; refresh in a few seconds"}))
            if u.path == "/api/memory/add":
                if g("content"):
                    q("INSERT INTO memories(agent_id,content,category,keywords) VALUES(?,?,?,?)",
                      (g("agent", "main"), g("content"), g("category", "hot"), g("keywords", "")))
                    audit("memory.add", g("category", "hot") + ": " + g("content")[:60])
                return self._send(200, json.dumps({"ok": True}))
        except Exception as e:
            return self._send(500, json.dumps({"error": str(e)}))
        return self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), H) as httpd:
        print(f"[dashboard] http://127.0.0.1:{PORT}  (DB: {DB})")
        httpd.serve_forever()
