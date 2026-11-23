-- KindleMap navigation state (Lua 5.1 + cjson). Used by gpsd.lua.
--
-- Files in RUN (RAM):
--   nav.json    state: none|calculating|rerouting|active|arrived|error + progress
--   route.json  current route (router.lua); route.js same, for the WAF
--   route.lock  router running (ignored after 90 s)

local json = require("cjson")

local M = {}
local BASE, RUN

local floor, sqrt, cos, rad = math.floor, math.sqrt, math.cos, math.rad
local M_LAT = 111320
local M_LON = 111320 * cos(rad(-12.9))

local OFF_ROUTE_M = { bike = 35, car = 50 }
local DEFAULT_SPEED = { bike = 4.2, car = 8.0 }
local ARRIVE_M = 25

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function write_atomic(path, data)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(data)
  f:close()
  return os.rename(tmp, path)
end

local function decode_file(path)
  local raw = read_file(path)
  if not raw or raw == "" then return nil end
  local ok, v = pcall(json.decode, raw)
  if ok and type(v) == "table" then return v end
  return nil
end

local function now_ms() return os.time() * 1000 end

function M.init(base, run)
  BASE, RUN = base, run
end

function M.state()
  return decode_file(RUN .. "/nav.json") or { state = "none" }
end

local function save(nav)
  nav.updated_ms = now_ms()
  write_atomic(RUN .. "/nav.json", json.encode(nav))
end

-- Compact view embedded in location.js for the Kindle screen.
function M.summary()
  local nav = M.state()
  if nav.state == "none" then return nil end
  return {
    state = nav.state, route_id = nav.route_id, profile = nav.profile,
    dest = nav.dest, next = nav.next, ["then"] = nav["then"],
    remaining_m = nav.remaining_m, eta_s = nav.eta_s, along_m = nav.along_m,
    off_m = nav.off_m, error = nav.error,
  }
end

---------------------------------------------------------------- routing

local function shell_quote(s)
  return "'" .. string.gsub(tostring(s or ""), "'", "") .. "'"
end

local function router_running()
  local raw = read_file(RUN .. "/route.lock")
  if not raw then return false end
  local started = tonumber(raw) or 0
  return os.time() - started < 90
end

-- Start the router in the background (does not block the HTTP reply).
function M.start(profile, flat, flon, dest, state)
  if router_running() then return false, "rota já sendo calculada" end
  write_atomic(RUN .. "/route.lock", tostring(os.time()))
  save({ state = state or "calculating", profile = profile, dest = dest, off_count = 0 })
  local cmd = string.format(
    "KINDLEMAP_BASE=%s KINDLEMAP_RUN=%s nohup lua %s/router.lua %s %.6f %.6f %.6f %.6f %s </dev/null >>%s/router.log 2>&1 &",
    shell_quote(BASE), shell_quote(RUN), BASE, profile, flat, flon, dest.lat, dest.lon,
    shell_quote(dest.label), RUN)
  os.execute(cmd)
  return true
end

function M.cancel()
  os.remove(RUN .. "/route.json")
  os.remove(RUN .. "/route.js")
  save({ state = "none" })
end

---------------------------------------------------------------- progress

local function maneuver_view(m, along)
  if not m then return nil end
  return { type = m.type, mod = m.mod, name = m.name, exit = m.exit,
    lat = m.lat, lon = m.lon, dist_m = floor(m.at_m - along + 0.5) }
end

-- Called for every accepted fix. Updates nav.json; may trigger a reroute.
function M.on_fix(fix)
  local nav = M.state()
  local st = nav.state
  if st ~= "active" and st ~= "rerouting" then return end
  if st == "rerouting" and router_running() then return end
  local route = decode_file(RUN .. "/route.json")
  if not route or route.id ~= nav.route_id then
    if st == "rerouting" and route then nav.route_id = route.id; nav.last_i = 1 else return end
  end

  local pts, cum = route.pts, route.cum
  local n = #cum
  local plat, plon = fix.latitude, fix.longitude
  local last_i = math.max(1, math.min(nav.last_i or 1, n - 1))
  local lo, hi = math.max(1, last_i - 3), math.min(n - 1, last_i + 120)
  local best_d, best_i, best_along
  for i = lo, hi do
    local alat, alon = pts[2 * i - 1] / 1e6, pts[2 * i] / 1e6
    local blat, blon = pts[2 * i + 1] / 1e6, pts[2 * i + 2] / 1e6
    local bx, by = (blon - alon) * M_LON, (blat - alat) * M_LAT
    local px, py = (plon - alon) * M_LON, (plat - alat) * M_LAT
    local l2 = bx * bx + by * by
    local t = l2 > 0 and (px * bx + py * by) / l2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local dx, dy = px - bx * t, py - by * t
    local d = sqrt(dx * dx + dy * dy)
    if not best_d or d < best_d - 0.5 then
      best_d, best_i, best_along = d, i, cum[i] + (cum[i + 1] - cum[i]) * t
    end
  end
  if not best_d then return end

  local profile = route.profile or "bike"
  nav.off_m = floor(best_d + 0.5)
  if best_d > (OFF_ROUTE_M[profile] or 40) then
    nav.off_count = (nav.off_count or 0) + 1
    if nav.off_count >= 2 then
      local dest = route.dest
      nav.state = "rerouting"
      save(nav)
      M.start(profile, plat, plon, dest, "rerouting")
      return
    end
    save(nav)
    return
  end

  nav.state = "active"
  nav.off_count = 0
  nav.last_i = best_i
  nav.along_m = floor(best_along + 0.5)
  local remaining = math.max(0, route.dist_m - best_along)
  nav.remaining_m = floor(remaining + 0.5)
  local dest = route.dest
  local ddx = (dest.lon - plon) * M_LON
  local ddy = (dest.lat - plat) * M_LAT
  if remaining < ARRIVE_M or sqrt(ddx * ddx + ddy * ddy) < ARRIVE_M then
    nav.state = "arrived"
  end
  local speed = (type(fix.speed_mps) == "number" and fix.speed_mps > 1.5) and fix.speed_mps
    or DEFAULT_SPEED[profile] or 4
  nav.eta_s = floor(remaining / speed + 0.5)

  local mans = route.maneuvers or {}
  local k = 1
  while k <= #mans and mans[k].at_m <= best_along + 3 do k = k + 1 end
  nav.next = maneuver_view(mans[k], best_along)
  nav["then"] = maneuver_view(mans[k + 1], best_along)
  nav.dest = dest
  nav.profile = profile
  save(nav)
end

---------------------------------------------------------------- search

local ACCENTS = {
  ["á"] = "a", ["à"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a",
  ["é"] = "e", ["ê"] = "e", ["è"] = "e", ["í"] = "i", ["î"] = "i",
  ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o", ["ú"] = "u", ["ü"] = "u",
  ["ç"] = "c", ["ñ"] = "n",
}

local function normalise(s)
  s = string.lower(s or "")
  for k, v in pairs(ACCENTS) do s = string.gsub(s, k, v) end
  s = string.gsub(s, "Á", "a"); s = string.gsub(s, "É", "e"); s = string.gsub(s, "Í", "i")
  s = string.gsub(s, "Ó", "o"); s = string.gsub(s, "Ú", "u"); s = string.gsub(s, "Ç", "c")
  s = string.gsub(s, "Ã", "a"); s = string.gsub(s, "Õ", "o"); s = string.gsub(s, "Â", "a")
  s = string.gsub(s, "Ê", "e"); s = string.gsub(s, "Ô", "o")
  s = string.gsub(s, "[^%w]+", " ")
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

function M.search(q, near_lat, near_lon)
  local idx = decode_file(BASE .. "/data/search.json")
  if not idx then return nil, "search.json não instalado" end
  local nq = normalise(q)
  if #nq < 2 then return {} end
  local tokens = {}
  for tk in string.gmatch(nq, "%S+") do tokens[#tokens + 1] = tk end
  local hits = {}
  for _, it in ipairs(idx.items) do
    local key = it[1]
    local ok = true
    local score = it[6] or 0
    for _, tk in ipairs(tokens) do
      local p = string.find(key, tk, 1, true)
      if not p then ok = false; break end
      if p == 1 then score = score + 6
      elseif string.sub(key, p - 1, p - 1) == " " then score = score + 3 end
    end
    if ok then
      if key == nq then score = score + 10 end
      if near_lat then
        local dx = (it[5] / 1e6 - near_lon) * M_LON
        local dy = (it[4] / 1e6 - near_lat) * M_LAT
        local km = sqrt(dx * dx + dy * dy) / 1000
        score = score - math.min(6, km / 3)
      end
      hits[#hits + 1] = { score = score, it = it }
    end
  end
  table.sort(hits, function (a, b) return a.score > b.score end)
  local out = {}
  for i = 1, math.min(12, #hits) do
    local it = hits[i].it
    out[#out + 1] = { label = it[2], kind = it[3], lat = it[4] / 1e6, lon = it[5] / 1e6 }
  end
  return out
end

return M
