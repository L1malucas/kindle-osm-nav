-- KindleMap GPS receiver (Lua 5.1 + cjson, KT4 firmware 5.18.1.1.1).
-- Runs once per TCP connection under busybox tcpsvd:
--   tcpsvd -c 8 0 8765 lua /mnt/us/kindlemap/gpsd.lua
-- stdin/stdout are the socket. State lives in /tmp (RAM), never in flash.
--
-- Accepted inputs (see docs/protocol.md):
--   POST /api/location   JSON v1 {latitude, longitude, speed_mps, course_deg, ...}
--   POST /owntracks      OwnTracks HTTP mode {_type:"location", lat, lon, vel, cog, acc, tst}
--   GET  /api/update?lat=..&lon=..&spd=..&dir=..&acc=..   (GPSLogger "Custom URL")
--   GET  /api/location   last fix (localhost free; remote requires token)
--   GET  /api/status     receiver state
-- Special mode: `lua gpsd.lua --write-status` only rewrites status files and exits.

local VERSION = "0.4.0"
local PORT = 8765
local BASE = os.getenv("KINDLEMAP_BASE") or "/mnt/us/kindlemap"
local RUN = os.getenv("KINDLEMAP_RUN") or "/tmp/kindlemap"
local TOKEN_FILE = BASE .. "/token"
local STATE_FILE = RUN .. "/location.json"
local JS_FILE = RUN .. "/location.js"
local CMD_FILE = RUN .. "/cmd.json"
local MAX_BODY = 16384

local ok_json, json = pcall(require, "cjson")
if not ok_json then
  io.stderr:write("cjson not available\n")
  os.exit(1)
end

package.path = BASE .. "/?.lua;" .. package.path
local nav = require("nav")
nav.init(BASE, RUN)

---------------------------------------------------------------- helpers

local function trim(s)
  return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_atomic(path, data)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(data)
  f:close()
  return os.rename(tmp, path)
end

local function url_decode(s)
  s = string.gsub(s or "", "+", " ")
  return (string.gsub(s, "%%(%x%x)", function (h) return string.char(tonumber(h, 16)) end))
end

local function parse_query(q)
  local out = {}
  for pair in string.gmatch(q or "", "[^&]+") do
    local k, v = string.match(pair, "^([^=]*)=?(.*)$")
    if k and k ~= "" then out[url_decode(k)] = url_decode(v) end
  end
  return out
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64decode(data)
  data = string.gsub(data or "", "[^" .. B64 .. "=]", "")
  return (string.gsub(string.gsub(data, ".", function (x)
    if x == "=" then return "" end
    local r, f = "", (string.find(B64, x, 1, true) - 1)
    for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
    return r
  end), "%d%d%d?%d?%d?%d?%d?%d?", function (x)
    if #x ~= 8 then return "" end
    local c = 0
    for i = 1, 8 do c = c + (string.sub(x, i, i) == "1" and 2 ^ (8 - i) or 0) end
    return string.char(c)
  end))
end

local function num(v)
  if type(v) == "number" then return v end
  if type(v) == "string" and v ~= "" then return tonumber(v) end
  return nil
end

local function now_ms()
  -- Lua 5.1 has only second resolution; enough for a 3 s poll.
  return os.time() * 1000
end

local function wlan_ip()
  local p = io.popen("ip -4 -o addr show wlan0 2>/dev/null")
  if not p then return nil end
  local out = p:read("*a") or ""
  p:close()
  return string.match(out, "inet (%d+%.%d+%.%d+%.%d+)")
end

local function token()
  return trim(read_file(TOKEN_FILE) or "")
end

---------------------------------------------------------------- state

local function load_fix()
  local raw = read_file(STATE_FILE)
  if not raw or raw == "" then return nil end
  local ok, value = pcall(json.decode, raw)
  if ok and type(value) == "table" then return value end
  return nil
end

local function snapshot(fix, include_token)
  local snap = {
    ok = true,
    version = VERSION,
    port = PORT,
    ip = wlan_ip() or json.null,
    server_ms = now_ms(),
    fix = fix or json.null
  }
  if include_token then snap.token = token() end
  -- Latest map command from the phone control page (zoom etc.).
  local raw = read_file(CMD_FILE)
  if raw and raw ~= "" then
    local ok, cmd = pcall(json.decode, raw)
    if ok and type(cmd) == "table" then snap.cmd = cmd end
  end
  snap.nav = nav.summary() or json.null
  return snap
end

-- location.js is read by the WAF via <script src> when XHR to localhost is
-- blocked. It is local-only (symlinked into the app folder), so it may
-- carry the token for display on the Kindle screen.
local function write_js(fix)
  local body = "if(window.KindleGpsMap){window.KindleGpsMap.receive(" ..
    json.encode(snapshot(fix, true)) .. ",'file');}\n"
  write_atomic(JS_FILE, body)
end

local function store_fix(fix)
  write_atomic(STATE_FILE, json.encode(fix))
  pcall(nav.on_fix, fix)
  write_js(fix)
end

---------------------------------------------------------------- normalisation

local function normalise(t, default_source)
  if type(t) ~= "table" then return nil, "payload is not an object" end
  local fix = {}
  if t._type ~= nil then
    -- OwnTracks: vel km/h, cog degrees, acc metres, tst epoch seconds.
    if t._type ~= "location" then return nil, "ignored" end
    fix.latitude = num(t.lat)
    fix.longitude = num(t.lon)
    fix.accuracy_m = num(t.acc)
    local vel = num(t.vel)
    fix.speed_mps = vel and vel >= 0 and vel / 3.6 or nil
    fix.course_deg = num(t.cog)
    local tst = num(t.tst)
    fix.timestamp_utc = tst and os.date("!%Y-%m-%dT%H:%M:%SZ", tst) or nil
    fix.source = "owntracks"
  else
    fix.latitude = num(t.latitude) or num(t.lat)
    fix.longitude = num(t.longitude) or num(t.lon) or num(t.lng)
    fix.accuracy_m = num(t.accuracy_m) or num(t.acc)
    fix.speed_mps = num(t.speed_mps) or num(t.spd) or num(t.speed)
    fix.course_deg = num(t.course_deg) or num(t.dir) or num(t.bearing) or num(t.course)
    fix.timestamp_utc = type(t.timestamp_utc) == "string" and t.timestamp_utc or
      (type(t.time) == "string" and t.time or nil)
    fix.source = type(t.source) == "string" and t.source or
      (type(t.src) == "string" and t.src or default_source)
  end
  if not fix.latitude or not fix.longitude then return nil, "latitude/longitude missing" end
  if fix.latitude < -90 or fix.latitude > 90 or fix.longitude < -180 or fix.longitude > 180 then
    return nil, "latitude/longitude out of range"
  end
  if fix.latitude == 0 and fix.longitude == 0 then return nil, "null island" end
  if fix.speed_mps and fix.speed_mps < 0 then fix.speed_mps = nil end
  if fix.course_deg and (fix.course_deg < 0 or fix.course_deg > 360) then fix.course_deg = nil end
  if fix.accuracy_m and fix.accuracy_m < 0 then fix.accuracy_m = nil end
  if fix.source and #fix.source > 24 then fix.source = string.sub(fix.source, 1, 24) end
  fix.received_ms = now_ms()
  return fix
end

---------------------------------------------------------------- HTTP

local REASONS = { [200] = "OK", [202] = "Accepted", [204] = "No Content", [409] = "Conflict", [500] = "Internal Server Error", [303] = "See Other", [400] = "Bad Request",
  [401] = "Unauthorized", [404] = "Not Found", [405] = "Method Not Allowed",
  [413] = "Payload Too Large" }

local function respond(status, ctype, body, extra)
  body = body or ""
  io.write("HTTP/1.0 ", status, " ", REASONS[status] or "OK", "\r\n",
    extra or "",
    "Content-Type: ", ctype, "\r\n",
    "Content-Length: ", #body, "\r\n",
    "Cache-Control: no-store\r\n",
    "Access-Control-Allow-Origin: *\r\n",
    "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n",
    "Access-Control-Allow-Headers: Content-Type, Authorization, X-Token\r\n",
    "Connection: close\r\n\r\n", body)
  io.flush()
end

local function respond_json(status, value, callback)
  local body = json.encode(value)
  if callback and string.match(callback, "^[%w_%.]+$") then
    respond(status, "application/javascript; charset=utf-8", callback .. "(" .. body .. ");")
  else
    respond(status, "application/json; charset=utf-8", body)
  end
end

local function authorised(headers, query)
  local expected = token()
  if expected == "" then return true end
  if query.token == expected then return true end
  if headers["x-token"] and trim(headers["x-token"]) == expected then return true end
  local auth = headers["authorization"] or ""
  local bearer = string.match(auth, "^[Bb]earer%s+(.+)$")
  if bearer and trim(bearer) == expected then return true end
  local basic = string.match(auth, "^[Bb]asic%s+(.+)$")
  if basic then
    local decoded = b64decode(trim(basic))
    local password = string.match(decoded, "^[^:]*:(.*)$")
    if password == expected then return true end
  end
  return false
end


local COMMANDS = { ["in"] = true, out = true, overview = true, detail = true, follow = true }

local function control_page(tok, msg)
  local function btn(c, label, wide)
    return '<a class="b' .. (wide and ' w' or '') .. '" href="/api/cmd?token=' .. tok .. '&c=' .. c .. '">' .. label .. '</a>'
  end
  return [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<title>Mapa Kindle</title><style>
body{font-family:sans-serif;margin:0;padding:12px;background:#fff;color:#000}
h1{font-size:20px;margin:0 0 10px}.g{display:flex;flex-wrap:wrap;gap:10px}
.b{flex:1 1 40%;display:block;text-align:center;padding:26px 0;border:3px solid #000;border-radius:10px;
font-size:30px;font-weight:bold;color:#000;text-decoration:none}.w{flex-basis:100%}
.b:active{background:#000;color:#fff}p{color:#444}
</style></head><body><h1>Controle do mapa no Kindle</h1><div class="g">]] ..
    btn("in", "+") .. btn("out", "&minus;") ..
    btn("detail", "DETALHE") .. btn("overview", "GERAL") ..
    btn("follow", "SEGUIR liga/desliga", true) ..
    '</div><p>' .. (msg or "O Kindle aplica o comando em até 2 s.") .. '</p></body></html>'
end


local NAV_PAGE = [==[<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<title>Rota no Kindle</title><style>
*{box-sizing:border-box}body{font-family:-apple-system,Roboto,sans-serif;margin:0;padding:12px;color:#000;background:#fff}
h1{font-size:20px;margin:0 0 10px}input{width:100%;font-size:20px;padding:14px;border:3px solid #000;border-radius:10px}
.row{display:flex;gap:8px;margin:10px 0}.t{flex:1;padding:14px 0;font-size:18px;font-weight:bold;border:3px solid #000;border-radius:10px;background:#fff;text-align:center}
.t.on{background:#000;color:#fff}#res button{display:block;width:100%;text-align:left;padding:12px;margin:6px 0;font-size:17px;border:2px solid #000;border-radius:8px;background:#fff}
#res small{color:#555}#st{margin:12px 0;padding:12px;border:3px solid #000;border-radius:10px;font-size:18px;min-height:56px}
.z{flex:1;padding:16px 0;font-size:24px;font-weight:bold;border:3px solid #000;border-radius:10px;background:#fff}
.warn{color:#a00}</style></head><body>
<h1>Rota no Kindle</h1>
<input id="q" placeholder="Buscar rua, bairro ou lugar" autocomplete="off">
<div class="row"><button class="t" id="p-bike">Bicicleta</button><button class="t" id="p-car">Moto/carro</button></div>
<div id="res"></div>
<div id="st">Sem rota.</div>
<div class="row"><button class="t" id="cancel">Cancelar rota</button><button class="t" id="again">Recalcular</button></div>
<div class="row"><button class="z" data-c="out">&minus;</button><button class="z" data-c="in">+</button><button class="z" data-c="detail">Detalhe</button><button class="z" data-c="overview">Geral</button></div>
<script>
var T=new URLSearchParams(location.search).get('token')||'';
var profile=localStorage.getItem('km_profile')||'bike', lastDest=null, timer=null;
function $(i){return document.getElementById(i)}
function setP(p){profile=p;localStorage.setItem('km_profile',p);$('p-bike').className='t'+(p=='bike'?' on':'');$('p-car').className='t'+(p=='car'?' on':'')}
setP(profile);$('p-bike').onclick=function(){setP('bike')};$('p-car').onclick=function(){setP('car')};
function api(path,opt){return fetch(path+(path.indexOf('?')<0?'?':'&')+'token='+encodeURIComponent(T),opt).then(function(r){return r.json().then(function(j){j._status=r.status;return j})})}
$('q').oninput=function(){clearTimeout(timer);var q=this.value;if(q.length<3){$('res').innerHTML='';return}
 timer=setTimeout(function(){$('res').innerHTML='Buscando…';api('/api/search?q='+encodeURIComponent(q)).then(function(j){
  var h='';(j.results||[]).forEach(function(r,i){h+='<button data-i="'+i+'">'+r.label+'</button>'});
  $('res').innerHTML=h||'Nada encontrado.';
  [].forEach.call($('res').querySelectorAll('button'),function(b){b.onclick=function(){go(j.results[+b.dataset.i])}})})},400)};
function go(d){lastDest=d;$('res').innerHTML='';$('q').value=d.label;$('st').textContent='Calculando rota no Kindle…';
 api('/api/route',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({lat:d.lat,lon:d.lon,label:d.label,profile:profile})})
 .then(function(j){if(!j.ok){$('st').innerHTML='<span class="warn">'+(j.error||'erro')+'</span>'}})}
$('again').onclick=function(){if(lastDest)go(lastDest)};
$('cancel').onclick=function(){api('/api/route/cancel',{method:'POST'}).then(poll)};
[].forEach.call(document.querySelectorAll('.z'),function(b){b.onclick=function(){fetch('/api/cmd?token='+T+'&c='+b.dataset.c)}});
var TXT={left:'vire à esquerda',right:'vire à direita',slight_left:'mantenha-se à esquerda',slight_right:'mantenha-se à direita',
 sharp_left:'vire acentuado à esquerda',sharp_right:'vire acentuado à direita',uturn:'faça o retorno',straight:'siga em frente',arrive:'chegada'};
function km(m){return m>=1000?(m/1000).toFixed(1).replace('.',',')+' km':Math.round(m/10)*10+' m'}
function poll(){api('/api/nav').then(function(n){var s=n.state,h;
 if(s=='none'||!s)h='Sem rota.';else if(s=='calculating')h='Calculando rota no Kindle…';else if(s=='rerouting')h='Fora da rota: recalculando…';
 else if(s=='error')h='<span class="warn">Erro: '+(n.error||'')+'</span>';else if(s=='arrived')h='<b>Chegou</b> a '+((n.dest||{}).label||'destino');
 else{var x=n.next||{},t=x.type=='roundabout'?'na rotatória, '+x.exit+'ª saída':(TXT[x.mod]||x.mod||'');
  h='<b>'+km(x.dist_m||0)+'</b>: '+t+(x.name?' — '+x.name:'')+'<br><small>'+km(n.remaining_m||0)+' restantes · '+Math.round((n.eta_s||0)/60)+' min</small>'}
 if(n.dest&&!lastDest)lastDest={lat:n.dest.lat,lon:n.dest.lon,label:n.dest.label};$('st').innerHTML=h}).catch(function(){})}
poll();setInterval(poll,3000);
</script></body></html>]==]

local HELP = [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>KindleMap GPS</title>
<style>body{font-family:sans-serif;max-width:40em;margin:1em auto;padding:0 1em}code{background:#eee;padding:2px 4px}</style>
</head><body><h1>KindleMap GPS</h1>
<p>Receptor ativo (v]] .. VERSION .. [[). O token aparece na tela do Kindle.</p>
<h2>OwnTracks (Android/iOS)</h2>
<p>Modo HTTP, URL: <code>http://IP_DO_KINDLE:8765/owntracks?token=TOKEN</code></p>
<h2>GPSLogger (Android)</h2>
<p>Custom URL, método GET:<br><code>http://IP_DO_KINDLE:8765/api/update?token=TOKEN&amp;lat=%LAT&amp;lon=%LON&amp;spd=%SPD&amp;dir=%DIR&amp;acc=%ACC&amp;src=android</code></p>
<h2>Rota (busca de destino)</h2>
<p>Abra <code>http://IP_DO_KINDLE:8765/nav?token=TOKEN</code> no navegador do celular.</p>
<h2>Controle do mapa pelo celular</h2>
<p>Abra <code>http://IP_DO_KINDLE:8765/control?token=TOKEN</code> no navegador do celular.</p>
<h2>Protocolo v1</h2>
<p><code>POST /api/location</code> com JSON <code>{"latitude":..,"longitude":..,"speed_mps":..,"course_deg":..}</code> e cabeçalho <code>X-Token</code>.</p>
</body></html>]]

local function handle()
  local line = io.read("*l")
  if not line then return end
  line = string.gsub(line, "\r$", "")
  local method, target = string.match(line, "^(%u+)%s+(%S+)")
  if not method then
    respond(400, "text/plain", "bad request\n")
    return
  end

  local headers = {}
  while true do
    local h = io.read("*l")
    if not h then break end
    h = string.gsub(h, "\r$", "")
    if h == "" then break end
    local k, v = string.match(h, "^([^:]+):%s*(.*)$")
    if k then headers[string.lower(k)] = v end
  end

  local path, qs = string.match(target, "^([^?]*)%??(.*)$")
  local query = parse_query(qs)
  -- busybox tcpsvd exports TCPREMOTEADDR="ip:port"; unknown counts as remote.
  local remote = os.getenv("TCPREMOTEIP") or
    string.match(os.getenv("TCPREMOTEADDR") or "", "^([%d%.]+):%d+$") or ""
  local is_local = (remote == "127.0.0.1")

  local body = ""
  local length = tonumber(headers["content-length"] or "0") or 0
  if length > MAX_BODY then
    respond(413, "text/plain", "too large\n")
    return
  end
  if length > 0 then
    if string.lower(headers["expect"] or "") == "100-continue" then
      io.write("HTTP/1.1 100 Continue\r\n\r\n")
      io.flush()
    end
    body = io.read(length) or ""
  end

  if method == "OPTIONS" then
    respond(204, "text/plain", "")
    return
  end

  if path == "/control" and method == "GET" then
    if not authorised(headers, query) then
      respond(401, "text/plain; charset=utf-8", "token inválido\n")
      return
    end
    respond(200, "text/html; charset=utf-8", control_page(query.token or token()))
    return
  end

  if path == "/api/cmd" then
    if not authorised(headers, query) then
      respond_json(401, { ok = false, error = "token" })
      return
    end
    local c = query.c or ""
    if not COMMANDS[c] then
      respond_json(400, { ok = false, error = "unknown command" })
      return
    end
    local prev = read_file(CMD_FILE)
    local seq = 0
    if prev then
      local ok, old = pcall(json.decode, prev)
      if ok and type(old) == "table" and type(old.seq) == "number" then seq = old.seq end
    end
    write_atomic(CMD_FILE, json.encode({ seq = seq + 1, c = c }))
    write_js(load_fix())
    -- Back to the control page so a browser refresh does not repeat the command.
    respond(303, "text/plain", "ok\n", "Location: /control?token=" .. (query.token or "") .. "\r\n")
    return
  end

  if path == "/nav" and method == "GET" then
    if not authorised(headers, query) then
      respond(401, "text/plain; charset=utf-8", "token inválido\n")
      return
    end
    respond(200, "text/html; charset=utf-8", NAV_PAGE)
    return
  end

  if string.sub(path, 1, 10) == "/api/route" or path == "/api/search" or path == "/api/nav" then
    if not is_local and not authorised(headers, query) then
      respond_json(401, { ok = false, error = "token" })
      return
    end
    if path == "/api/nav" then
      respond_json(200, nav.state())
      return
    end
    if path == "/api/search" then
      local fix = load_fix()
      local results, err = nav.search(query.q or "", fix and fix.latitude, fix and fix.longitude)
      if not results then
        respond_json(500, { ok = false, error = err })
      else
        respond_json(200, { ok = true, results = results })
      end
      return
    end
    if path == "/api/route/cancel" then
      nav.cancel()
      write_js(load_fix())
      respond_json(200, { ok = true })
      return
    end
    if path == "/api/route" and method == "GET" then
      local raw = read_file(RUN .. "/route.json")
      if raw then respond(200, "application/json; charset=utf-8", raw)
      else respond_json(404, { ok = false, error = "sem rota" }) end
      return
    end
    if path == "/api/route" and method == "POST" then
      local ok, req = pcall(json.decode, body)
      if not ok or type(req) ~= "table" then req = query end
      local tlat, tlon = num(req.lat), num(req.lon)
      local profile = (req.profile == "car") and "car" or "bike"
      if not tlat or not tlon then
        respond_json(400, { ok = false, error = "destino sem coordenadas" })
        return
      end
      local flat, flon = num(req.from_lat), num(req.from_lon)
      if not flat then
        local fix = load_fix()
        if not fix then
          respond_json(409, { ok = false, error = "sem posição GPS do celular ainda" })
          return
        end
        flat, flon = fix.latitude, fix.longitude
      end
      local label = type(req.label) == "string" and string.sub(req.label, 1, 80) or ""
      local started, why = nav.start(profile, flat, flon, { lat = tlat, lon = tlon, label = label })
      write_js(load_fix())
      if started then respond_json(202, { ok = true, state = "calculating" })
      else respond_json(409, { ok = false, error = why }) end
      return
    end
    respond(404, "text/plain", "not found\n")
    return
  end

  if path == "/" and method == "GET" then
    respond(200, "text/html; charset=utf-8", HELP)
    return
  end

  if path == "/api/refresh" and is_local then
    -- E Ink refresh from the current framebuffer, asked by the WAF after the
    -- map moved (partial updates by the system leave the old map on the panel).
    --   mode=partial  no flash, every move, at most 1/s
    --   mode=full     flash (clears ghosting), at most every 4 s
    local full = query.mode ~= "partial"
    local stamp = RUN .. (full and "/refresh-full.ts" or "/refresh-partial.ts")
    local last = tonumber(read_file(stamp) or "0") or 0
    if os.time() - last >= (full and 4 or 1) then
      write_atomic(stamp, tostring(os.time()))
      os.execute("(/usr/sbin/eips -s w=600,h=800" .. (full and " -f" or "") ..
        ") </dev/null >/dev/null 2>&1 &")
      local f = io.open(RUN .. "/refresh.log", "a")
      if f then
        if (f:seek("end") or 0) < 65536 then f:write(os.date("%H:%M:%S "), full and "full\n" or "partial\n") end
        f:close()
      end
    end
    respond(204, "text/plain", "")
    return
  end

  if path == "/api/log" and is_local then
    -- Debug channel for the WAF (touch/click diagnostics). Local only, RAM only.
    local f = io.open(RUN .. "/events.log", "a")
    if f then
      local size = f:seek("end") or 0
      if size < 65536 then
        f:write(os.date("%H:%M:%S "), string.sub(query.e or body or "", 1, 300), "\n")
      end
      f:close()
    end
    respond(204, "text/plain", "")
    return
  end

  if path == "/api/status" and method == "GET" then
    local fix = load_fix()
    write_js(fix)
    local snap = snapshot(nil, is_local)
    snap.has_fix = fix ~= nil
    snap.last_fix_ms = fix and fix.received_ms or json.null
    snap.token_required = token() ~= ""
    respond_json(200, snap, query.callback)
    return
  end

  if path == "/api/location" and method == "GET" then
    if not is_local and not authorised(headers, query) then
      respond_json(401, { ok = false, error = "token" })
      return
    end
    respond_json(200, snapshot(load_fix(), is_local), query.callback)
    return
  end

  local is_update = (path == "/api/location" and method == "POST") or
    path == "/owntracks" or path == "/api/owntracks" or path == "/api/update"
  if not is_update then
    respond(404, "text/plain", "not found\n")
    return
  end

  if not authorised(headers, query) then
    respond_json(401, { ok = false, error = "token" })
    return
  end

  local payload
  if method == "GET" or (body == "" and query.lat) then
    payload = query
  elseif string.find(string.lower(headers["content-type"] or ""), "x-www-form-urlencoded", 1, true) then
    payload = parse_query(body)
  else
    local ok, decoded = pcall(json.decode, body)
    if not ok then
      respond_json(400, { ok = false, error = "invalid json" })
      return
    end
    payload = decoded
  end

  -- OwnTracks may batch several messages in an array; keep the newest location.
  if type(payload) == "table" and payload[1] ~= nil and payload.lat == nil then
    local best
    for _, item in ipairs(payload) do
      if type(item) == "table" and item._type == "location" then
        if not best or (num(item.tst) or 0) >= (num(best.tst) or 0) then best = item end
      end
    end
    payload = best
  end

  local default_source = (path == "/api/update") and "gpslogger" or "phone"
  local fix, err = normalise(payload, default_source)
  if not fix then
    if err == "ignored" then
      respond(200, "application/json", "[]")
    else
      respond_json(400, { ok = false, error = err })
    end
    return
  end
  store_fix(fix)
  -- OwnTracks expects a JSON array; plain clients ignore the body.
  respond(200, "application/json", "[]")
end

if arg and arg[1] == "--write-status" then
  write_js(load_fix())
  os.exit(0)
end

local ok, err = pcall(handle)
if not ok then
  pcall(respond, 400, "text/plain", "error\n")
  io.stderr:write("gpsd error: ", tostring(err), "\n")
end
