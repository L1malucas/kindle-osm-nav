-- KindleMap offline router (Lua 5.1 + cjson, KT4).
--
--   lua router.lua <bike|car> <from_lat> <from_lon> <to_lat> <to_lon> [label]
--
-- Reads  $KINDLEMAP_BASE/data/graph.json (tools/build_graph.py)
-- Writes $KINDLEMAP_RUN/route.json + route.js (atomic), or nav.json with an
-- error state. Run in the background by gpsd.lua; guarded by route.lock.

local BASE = os.getenv("KINDLEMAP_BASE") or "/mnt/us/kindlemap"
local RUN = os.getenv("KINDLEMAP_RUN") or "/tmp/kindlemap"
local json = require("cjson")

local floor, sqrt, abs, cos, sin, atan2, rad, deg =
  math.floor, math.sqrt, math.abs, math.cos, math.sin, math.atan2, math.rad, math.deg

---------------------------------------------------------------- io helpers

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function write_atomic(path, data)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(data)
  f:close()
  os.rename(tmp, path)
end

local function now_ms() return os.time() * 1000 end

---------------------------------------------------------------- geometry

-- Local equirectangular metres around the study area (|error| < 0.1 % here).
local M_LAT = 111320
local M_LON = 111320 * cos(rad(-12.9))

local function dist_m(alat, alon, blat, blon)
  local dx = (blon - alon) * M_LON
  local dy = (blat - alat) * M_LAT
  return sqrt(dx * dx + dy * dy)
end

local function bearing(alat, alon, blat, blon)
  local b = deg(atan2((blon - alon) * M_LON, (blat - alat) * M_LAT))
  if b < 0 then b = b + 360 end
  return b
end

-- Project p onto segment a-b; returns fraction t in [0,1] and distance.
local function project(plat, plon, alat, alon, blat, blon)
  local ax, ay = 0, 0
  local bx, by = (blon - alon) * M_LON, (blat - alat) * M_LAT
  local px, py = (plon - alon) * M_LON, (plat - alat) * M_LAT
  local l2 = bx * bx + by * by
  local t = 0
  if l2 > 0 then t = (px * bx + py * by) / l2 end
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local dx, dy = px - bx * t, py - by * t
  return t, sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------- graph

local G

local function load_graph()
  local raw = read_file(BASE .. "/data/graph.json")
  if not raw then error("graph.json not found") end
  G = json.decode(raw)
  raw = nil
  collectgarbage("collect")
end

-- Polyline of edge e (1-based) from u to v as two arrays of degrees.
local function edge_points(e)
  local la, lo = { G.n_lat[G.e_u[e]] / 1e6 }, { G.n_lon[G.e_u[e]] / 1e6 }
  local g0, gn = G.e_g0[e], G.e_gn[e]
  for k = g0, g0 + gn - 1 do
    la[#la + 1] = G.g_lat[k] / 1e6
    lo[#lo + 1] = G.g_lon[k] / 1e6
  end
  la[#la + 1] = G.n_lat[G.e_v[e]] / 1e6
  lo[#lo + 1] = G.n_lon[G.e_v[e]] / 1e6
  return la, lo
end

local PROFILE = {
  bike = { cost = "e_cost_bike", fwd = 1, back = 2, vmax = "bike_max_mps" },
  car = { cost = "e_cost_car", fwd = 4, back = 8, vmax = "car_max_mps" },
}

local function has(flags, bit) return floor(flags / bit) % 2 == 1 end

-- Nearest usable edge to (lat, lon): edge, position along edge (m), length.
local function snap(lat, lon, prof)
  local gd = G.grid_deg
  local ix, iy = floor(lon / gd), floor(lat / gd)
  for radius = 1, 4 do
    local best, be, bpos
    local seen = {}
    for x = ix - radius, ix + radius do
      for y = iy - radius, iy + radius do
        local cell = G.grid[x .. ":" .. y]
        if cell then
          for _, e in ipairs(cell) do
            if not seen[e] and G[prof.cost][e] > 0 then
              seen[e] = true
              local la, lo = edge_points(e)
              local acc = 0
              for k = 1, #la - 1 do
                local seg = dist_m(la[k], lo[k], la[k + 1], lo[k + 1])
                local t, d = project(lat, lon, la[k], lo[k], la[k + 1], lo[k + 1])
                if not best or d < best then
                  best, be, bpos = d, e, acc + seg * t
                end
                acc = acc + seg
              end
            end
          end
        end
      end
    end
    if best and best < 400 then return be, bpos, best end
  end
  return nil
end

---------------------------------------------------------------- A*

local function astar(prof, s_edge, s_pos, t_edge, t_pos, tlat, tlon)
  local cost = G[prof.cost]
  local flags, e_u, e_v, e_len = G.e_flags, G.e_u, G.e_v, G.e_len
  local adj_start, adj_edge = G.adj_start, G.adj_edge
  local n_lat, n_lon = G.n_lat, G.n_lon
  local vmax = G[prof.vmax]
  local fwd, back = prof.fwd, prof.back

  local function part(e, metres) -- cost of travelling `metres` on edge e
    return cost[e] * metres / math.max(e_len[e], 0.1)
  end

  local g, prev_n, prev_e = {}, {}, {}
  local heap_n, heap_f, size = {}, {}, 0
  local function push(n, f)
    size = size + 1
    local i = size
    while i > 1 do
      local p = floor(i / 2)
      if heap_f[p] <= f then break end
      heap_n[i], heap_f[i] = heap_n[p], heap_f[p]
      i = p
    end
    heap_n[i], heap_f[i] = n, f
  end
  local function pop()
    local n, f = heap_n[1], heap_f[1]
    local ln, lf = heap_n[size], heap_f[size]
    heap_n[size], heap_f[size] = nil, nil
    size = size - 1
    local i = 1
    while true do
      local c = i * 2
      if c > size then break end
      if c < size and heap_f[c + 1] < heap_f[c] then c = c + 1 end
      if heap_f[c] >= lf then break end
      heap_n[i], heap_f[i] = heap_n[c], heap_f[c]
      i = c
    end
    if size > 0 then heap_n[i], heap_f[i] = ln, lf end
    return n, f
  end
  local function h(n)
    return dist_m(n_lat[n] / 1e6, n_lon[n] / 1e6, tlat, tlon) / vmax * 10
  end

  -- virtual start: leave the start edge towards either end
  local slen = e_len[s_edge]
  if has(flags[s_edge], fwd) then
    local n = e_v[s_edge]
    g[n] = part(s_edge, slen - s_pos); prev_n[n] = 0; prev_e[n] = s_edge
    push(n, g[n] + h(n))
  end
  if has(flags[s_edge], back) then
    local n = e_u[s_edge]
    local c = part(s_edge, s_pos)
    if not g[n] or c < g[n] then
      g[n] = c; prev_n[n] = 0; prev_e[n] = -s_edge
      push(n, c + h(n))
    end
  end

  -- goal: reach an end of the target edge, then travel along it
  local best, best_end
  local direct
  if s_edge == t_edge then
    if t_pos >= s_pos and has(flags[s_edge], fwd) then direct = part(s_edge, t_pos - s_pos) end
    if t_pos < s_pos and has(flags[s_edge], back) then direct = part(s_edge, s_pos - t_pos) end
    if direct then best, best_end = direct, "direct" end
  end
  local tl = e_len[t_edge]
  local goal_u = has(flags[t_edge], fwd) and part(t_edge, t_pos) or nil        -- u -> pos
  local goal_v = has(flags[t_edge], back) and part(t_edge, tl - t_pos) or nil  -- v -> pos

  local closed = {}
  local expanded = 0
  while size > 0 do
    local n, f = pop()
    if best and f >= best then break end
    if not closed[n] then
      closed[n] = true
      expanded = expanded + 1
      local gn = g[n]
      if n == e_u[t_edge] and goal_u and (not best or gn + goal_u < best) then
        best, best_end = gn + goal_u, "u"
      end
      if n == e_v[t_edge] and goal_v and (not best or gn + goal_v < best) then
        best, best_end = gn + goal_v, "v"
      end
      for k = adj_start[n], adj_start[n + 1] - 1 do
        local se = adj_edge[k]
        local e = se > 0 and se or -se
        local fl = flags[e]
        if cost[e] > 0 and ((se > 0 and has(fl, fwd)) or (se < 0 and has(fl, back))) then
          local m = se > 0 and e_v[e] or e_u[e]
          local ng = gn + cost[e]
          if not closed[m] and (not g[m] or ng < g[m]) then
            g[m] = ng; prev_n[m] = n; prev_e[m] = se
            push(m, ng + h(m))
          end
        end
      end
    end
  end
  if not best then return nil, expanded end

  -- reconstruct signed edge list
  local seq = {}
  if best_end ~= "direct" then
    local n = best_end == "u" and e_u[t_edge] or e_v[t_edge]
    while true do
      local se = prev_e[n]
      table.insert(seq, 1, se)
      if prev_n[n] == 0 then break end
      n = prev_n[n]
    end
  end
  return { seq = seq, end_kind = best_end, cost = best }, expanded
end

---------------------------------------------------------------- route geometry

-- Points of edge e between positions a and b (metres from u), in travel order.
local function slice(e, a, b)
  local la, lo = edge_points(e)
  local cum = { 0 }
  for k = 1, #la - 1 do cum[k + 1] = cum[k] + dist_m(la[k], lo[k], la[k + 1], lo[k + 1]) end
  local scale = G.e_len[e] / math.max(cum[#cum], 0.1)
  local function at(pos)
    pos = pos / scale
    for k = 1, #la - 1 do
      if cum[k + 1] >= pos then
        local t = (pos - cum[k]) / math.max(cum[k + 1] - cum[k], 0.001)
        return la[k] + (la[k + 1] - la[k]) * t, lo[k] + (lo[k + 1] - lo[k]) * t
      end
    end
    return la[#la], lo[#lo]
  end
  local out = {}
  local lo_pos, hi_pos = math.min(a, b), math.max(a, b)
  local p1lat, p1lon = at(lo_pos)
  out[#out + 1] = { p1lat, p1lon }
  for k = 2, #la - 1 do
    local pos = cum[k] * scale
    if pos > lo_pos and pos < hi_pos then out[#out + 1] = { la[k], lo[k] } end
  end
  local p2lat, p2lon = at(hi_pos)
  out[#out + 1] = { p2lat, p2lon }
  if a > b then -- reverse for backward travel
    local r = {}
    for i = #out, 1, -1 do r[#r + 1] = out[i] end
    out = r
  end
  return out
end

local function build_route(res, s_edge, s_pos, t_edge, t_pos)
  local legs = {} -- {edge, from_pos, to_pos}
  local seq = res.seq
  if res.end_kind == "direct" then
    legs[1] = { s_edge, s_pos, t_pos }
  else
    for i, se in ipairs(seq) do
      local e = se > 0 and se or -se
      local len = G.e_len[e]
      local a, b = 0, len
      if se < 0 then a, b = len, 0 end
      if i == 1 then a = s_pos end
      legs[#legs + 1] = { e, a, b }
    end
    legs[#legs + 1] = { t_edge, res.end_kind == "u" and 0 or G.e_len[t_edge], t_pos }
  end

  local pts, cum = {}, {}
  local leg_start = {} -- index in pts where each leg starts
  for i, leg in ipairs(legs) do
    local sl = slice(leg[1], leg[2], leg[3])
    leg_start[i] = math.max(1, #pts)
    for j, p in ipairs(sl) do
      if #pts == 0 or j > 1 then
        local last = pts[#pts]
        local d = last and dist_m(last[1], last[2], p[1], p[2]) or 0
        if not last or d > 0.3 then
          pts[#pts + 1] = p
          cum[#pts] = (cum[#pts - 1] or 0) + d
        end
      end
    end
  end
  return legs, leg_start, pts, cum
end

---------------------------------------------------------------- maneuvers

local function turn_type(angle)
  local a = abs(angle)
  local side = angle > 0 and "right" or "left"
  if a < 25 then return "straight", "straight" end
  if a < 50 then return "turn", "slight_" .. side end
  if a < 135 then return "turn", side end
  if a < 165 then return "turn", "sharp_" .. side end
  return "uturn", "uturn"
end

-- bearing of the route around index i: back (incoming) or ahead (outgoing)
local function local_bearing(pts, cum, i, ahead)
  local target = ahead and cum[i] + 15 or cum[i] - 15
  local j = i
  if ahead then
    while j < #pts and cum[j] < target do j = j + 1 end
    return bearing(pts[i][1], pts[i][2], pts[j][1], pts[j][2])
  end
  while j > 1 and cum[j] > target do j = j - 1 end
  return bearing(pts[j][1], pts[j][2], pts[i][1], pts[i][2])
end

local function maneuvers(legs, leg_start, pts, cum)
  local out = {}
  local function name_of(e) return G.names[G.e_name[e] + 1] or "" end
  local function is_round(e) return has(G.e_flags[e], 16) end
  local i = 2
  while i <= #legs do
    local prev_e, e = legs[i - 1][1], legs[i][1]
    local idx = leg_start[i]
    local node_deg = 0
    -- junction node between the two legs
    local se_prev = legs[i - 1]
    local node = se_prev[3] >= G.e_len[prev_e] - 0.01 and G.e_v[prev_e] or G.e_u[prev_e]
    node_deg = G.n_deg[node] or 2
    if is_round(e) and not is_round(prev_e) then
      -- entering a roundabout: count exits until we leave it
      local exits, j = 0, i
      while j <= #legs and is_round(legs[j][1]) do
        local lj = legs[j]
        local endn = lj[3] >= G.e_len[lj[1]] - 0.01 and G.e_v[lj[1]] or G.e_u[lj[1]]
        if (G.n_deg[endn] or 2) > 2 then exits = exits + 1 end
        j = j + 1
      end
      local exit_name = j <= #legs and name_of(legs[j][1]) or ""
      out[#out + 1] = { type = "roundabout", mod = "roundabout", exit = math.max(1, exits),
        name = exit_name, i = idx }
      i = j + 1
    else
      local a_in = local_bearing(pts, cum, idx, false)
      local a_out = local_bearing(pts, cum, idx, true)
      local angle = a_out - a_in
      if angle > 180 then angle = angle - 360 elseif angle < -180 then angle = angle + 360 end
      local kind, mod = turn_type(angle)
      local same_name = name_of(e) == name_of(prev_e)
      -- Only real decisions: a junction, not straight (name spelling changes are
      -- noise in OSM), and no slight bend that stays on the same street.
      local slight = string.sub(mod, 1, 6) == "slight"
      if node_deg > 2 and kind ~= "straight" and not (slight and same_name and name_of(e) ~= "") then
        out[#out + 1] = { type = kind, mod = mod, name = name_of(e), i = idx }
      end
      i = i + 1
    end
  end
  -- drop maneuvers closer than 15 m to the previous one (keep the later)
  local merged = {}
  for _, m in ipairs(out) do
    local last = merged[#merged]
    if cum[m.i] < 15 then
      -- leaving the start point: not an instruction
    else
    if last and cum[m.i] - cum[last.i] < 15 then merged[#merged] = m else merged[#merged + 1] = m end
    end
  end
  merged[#merged + 1] = { type = "arrive", mod = "arrive", name = "", i = #pts }
  for _, m in ipairs(merged) do
    m.lat = pts[m.i][1]
    m.lon = pts[m.i][2]
    m.at_m = floor(cum[m.i] + 0.5)
  end
  return merged
end

---------------------------------------------------------------- main

local function finish()
  os.remove(RUN .. "/route.lock")
  -- refresh location.js so the Kindle sees the new state without waiting for a fix
  os.execute(string.format("KINDLEMAP_BASE='%s' KINDLEMAP_RUN='%s' lua '%s/gpsd.lua' --write-status >/dev/null 2>&1",
    BASE, RUN, BASE))
end

local function fail(msg, profile, dest)
  write_atomic(RUN .. "/nav.json", json.encode({ state = "error", error = msg,
    profile = profile, dest = dest, updated_ms = now_ms() }))
  io.stderr:write("router: ", msg, "\n")
  finish()
  os.exit(1)
end

local profile, flat, flon, tlat, tlon, label = arg[1], tonumber(arg[2]), tonumber(arg[3]),
  tonumber(arg[4]), tonumber(arg[5]), arg[6] or ""
local dest = { lat = tlat, lon = tlon, label = label }
local prof = PROFILE[profile or ""]
if not prof or not flat or not flon or not tlat or not tlon then
  io.stderr:write("usage: lua router.lua <bike|car> from_lat from_lon to_lat to_lon [label]\n")
  os.exit(2)
end

local t0 = os.clock()
local ok, err = pcall(load_graph)
if not ok then fail("graph: " .. tostring(err), profile, dest) end
local t_load = os.clock() - t0

local s_edge, s_pos, s_d = snap(flat, flon, prof)
if not s_edge then fail("origem longe de qualquer via", profile, dest) end
local t_edge, t_pos, t_d = snap(tlat, tlon, prof)
if not t_edge then fail("destino longe de qualquer via", profile, dest) end

local res, expanded = astar(prof, s_edge, s_pos, t_edge, t_pos, tlat, tlon)
if not res then fail("sem rota para este perfil", profile, dest) end

local legs, leg_start, pts, cum = build_route(res, s_edge, s_pos, t_edge, t_pos)
local mans = maneuvers(legs, leg_start, pts, cum)

local flat_pts = {}
for i, p in ipairs(pts) do
  flat_pts[#flat_pts + 1] = floor(p[1] * 1e6 + 0.5)
  flat_pts[#flat_pts + 1] = floor(p[2] * 1e6 + 0.5)
end
local cum_out = {}
for i = 1, #cum do cum_out[i] = floor(cum[i] * 10 + 0.5) / 10 end

math.randomseed(os.time())
local route = {
  id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
  profile = profile, dest = dest,
  dist_m = floor(cum[#cum] + 0.5), time_s = floor(res.cost / 10 + 0.5),
  pts = flat_pts, cum = cum_out, maneuvers = mans,
  snap_m = { floor(s_d + 0.5), floor(t_d + 0.5) },
  stats = { load_s = t_load, total_s = os.clock() - t0, expanded = expanded },
  created_ms = now_ms(),
}
local encoded = json.encode(route)
write_atomic(RUN .. "/route.json", encoded)
write_atomic(RUN .. "/route.js", "if(window.KindleGpsMap){window.KindleGpsMap.route(" .. encoded .. ");}\n")
write_atomic(RUN .. "/nav.json", json.encode({ state = "active", route_id = route.id, profile = profile,
  dest = dest, last_i = 1, off_count = 0, updated_ms = now_ms() }))
finish()
io.stdout:write(string.format("route %s: %.1f km, %d min, %d pts, %d maneuvers, load %.1fs total %.1fs, expanded %d\n",
  profile, route.dist_m / 1000, floor(route.time_s / 60), #pts, #mans, t_load, os.clock() - t0, expanded))
