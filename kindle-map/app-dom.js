/* KindleMap — ES5 DOM renderer + GPS client for the Mesquite WebKit (KT4, 5.18.1.1.1).
 *
 * Position source: local receiver (receiver/gpsd.lua under tcpsvd, port 8765).
 *  1. XHR  http://127.0.0.1:8765/api/location  (preferred)
 *  2. <script src="location.js">  (file:// fallback; the receiver keeps
 *     /tmp/kindlemap/location.js updated and start-gps.sh symlinks it here)
 * Both deliver the same snapshot to KindleGpsMap.receive().
 */
(function () {
  'use strict';

  var RECEIVER = 'http://127.0.0.1:8765';
  var POLL_MS = 2000;
  var STALE_S = 15;      // docs/protocol.md: stale after 15 s
  var LOST_S = 60;       // docs/protocol.md: disconnected after 60 s
  var TRAIL_MAX = 40;
  var TRAIL_MIN_M = 25;  // only add a crumb after moving this far
  var TILE = 256;

  function $(id) { return document.getElementById(id); }

  var el = {
    app: $('app'), top: $('top'), map: $('map'), tiles: $('tiles'), trail: $('trail'),
    marker: $('marker'), arrow: $('marker-arrow'), note: $('map-note'), help: $('help'),
    controls: $('controls'), status: $('status'), statusText: $('status-text'),
    gps: $('gps-state'), speed: $('speed'), heading: $('heading'), detail: $('detail-line'),
    nav: $('nav'), navIcon: $('nav-icon'), navExit: $('nav-exit'), navDist: $('nav-dist'),
    navName: $('nav-name'), navThen: $('nav-then'), route: $('route'), routeSegs: $('route-segs'),
    turnDot: $('turn-dot')
  };

  var state = {
    pack: null,
    zoom: 10,
    center: { lat: -12.875, lon: -38.45 },
    follow: true,
    fix: null,
    receivedMs: 0,
    receiverOk: false,
    receiverInfo: null,
    mode: 'file',
    pollCount: 0,
    trail: [],
    width: 600,
    mapHeight: 510,
    lastGpsClass: '',
    lastText: {},
    cmdSeq: null,
    nav: null,        // nav summary from location.js
    route: null,      // decoded route.js
    routeId: null,
    routeLoading: null,
    autoZoom: true,   // navigation picks zoom; +/- turns it off, SEGUIR back on
    zoomWant: null,
    zoomWantCount: 0,
    lastTilesZoom: null
  };

  /* ---------------------------------------------------------------- utils */

  function now() { return new Date().getTime(); }

  function setText(node, key, text) {
    // Avoid touching the DOM when nothing changed: every write may refresh E Ink.
    if (state.lastText[key] === text) { return; }
    state.lastText[key] = text;
    node.innerHTML = text;
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  function mercY(lat) {
    var r = clamp(lat, -85.05112878, 85.05112878) * Math.PI / 180;
    return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2;
  }

  function world(lat, lon, z) {
    var n = Math.pow(2, z) * TILE;
    return { x: (lon + 180) / 360 * n, y: mercY(lat) * n };
  }

  function distanceM(a, b) {
    var R = 6371000, rad = Math.PI / 180;
    var dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad;
    var h = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
    return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
  }

  function compass(deg) {
    var names = ['N', 'NE', 'L', 'SE', 'S', 'SO', 'O', 'NO'];
    return names[Math.round(deg / 45) % 8];
  }

  function minZoom() { return state.pack && typeof state.pack.min_zoom === 'number' ? state.pack.min_zoom : 9; }
  function maxZoom() { return state.pack && typeof state.pack.max_zoom === 'number' ? state.pack.max_zoom : 14; }
  function overviewZoom() { return state.pack && state.pack.overview_zoom ? state.pack.overview_zoom : 10; }
  function detailZoom() { return state.pack && state.pack.detail_zoom ? state.pack.detail_zoom : 14; }

  /* --------------------------------------------------------------- layout */

  function px(node, left, top, width, height) {
    node.style.left = left + 'px';
    node.style.top = top + 'px';
    node.style.width = width + 'px';
    node.style.height = height + 'px';
  }

  var BUTTONS = [
    // id, x, width. Kept away from the right edge (reported dead touch zone).
    ['btn-follow', 8, 118],
    ['btn-overview', 134, 110],
    ['btn-detail', 252, 130],
    ['btn-out', 392, 70],
    ['btn-in', 470, 70]
  ];

  function layout() {
    var w = window.innerWidth || document.documentElement.clientWidth || 600;
    var h = window.innerHeight || document.documentElement.clientHeight || 680;
    if (w < 300) { w = 600; }
    if (h < 300) { h = 680; }
    // Mesquite may report 800 px while the window sits below the 120 px
    // system bar; anything past 680 px is off-screen (buttons vanished).
    if (h > 680) { h = 680; }
    var topH = navActive() ? 112 : 64, ctrlH = 76, statusH = 30;
    el.top.style.display = navActive() ? 'none' : 'block';
    el.nav.style.display = navActive() ? 'block' : 'none';
    px(el.nav, 0, 0, w, topH);
    var mapH = h - topH - ctrlH - statusH;
    state.width = w;
    state.mapHeight = mapH;
    px(el.app, 0, 0, w, h);
    px(el.top, 0, 0, w, topH);
    px(el.map, 0, topH, w, mapH);
    px(el.tiles, 0, 0, w, mapH);
    px(el.trail, 0, 0, w, mapH);
    px(el.route, 0, 0, w, mapH);
    px(el.controls, 0, topH + mapH, w, ctrlH);
    px(el.status, 0, topH + mapH + ctrlH, w, statusH);
    var scale = w / 600, i;
    for (i = 0; i < BUTTONS.length; i += 1) {
      var b = $(BUTTONS[i][0]);
      b.style.left = Math.round(BUTTONS[i][1] * scale) + 'px';
      b.style.width = Math.round(BUTTONS[i][2] * scale) + 'px';
    }
    $('heading').style.left = (w - 240) + 'px';
    $('detail-line').style.left = (w - 240) + 'px';
    px(el.help, 30, Math.max(10, Math.round(mapH / 2 - 150)), w - 60, 300);
  }

  /* ---------------------------------------------------------------- tiles */

  var tileCache = {};
  var tileCacheSize = 0;

  function tileUrl(z, x, y) {
    var t = (state.pack && state.pack.tile_template) || 'tiles/{z}/{x}/{y}.png';
    return 'map-pack/' + t.replace('{z}', z).replace('{x}', x).replace('{y}', y);
  }

  function tileImg(z, x, y) {
    var n = Math.pow(2, z);
    if (x < 0 || y < 0 || x >= n || y >= n) { return null; }
    var key = z + '/' + x + '/' + y;
    var img = tileCache[key];
    if (!img) {
      if (tileCacheSize > 120) { tileCache = {}; tileCacheSize = 0; }
      img = document.createElement('img');
      img.className = 'tile';
      img.width = TILE;
      img.height = TILE;
      // Sea / empty tiles are not generated: stay hidden until loaded, never a broken icon.
      img.style.visibility = 'hidden';
      img.onload = function () { this.style.visibility = 'visible'; };
      img.onerror = function () { this.style.visibility = 'hidden'; };
      img.src = tileUrl(z, x, y);
      tileCache[key] = img;
      tileCacheSize += 1;
    }
    return img;
  }

  // E Ink refresh after the map moved (the panel otherwise keeps the old map):
  // wait until the new tiles are drawn, then ask the receiver to run eips.
  // partial = no flash, every move; full = flash, on zoom change or every 30 s.
  var FULL_EVERY_MS = 30000;
  var refreshTimer = null, refreshDeadline = 0, lastFullMs = 0, pendingFull = false;
  function requestRefresh(images, zoomChanged) {
    if (refreshTimer) { window.clearTimeout(refreshTimer); }
    if (zoomChanged) { pendingFull = true; }
    refreshDeadline = now() + 2500;
    function check() {
      var i, pending = 0;
      for (i = 0; i < images.length; i += 1) { if (!images[i].complete) { pending += 1; } }
      if (pending > 0 && now() < refreshDeadline) { refreshTimer = window.setTimeout(check, 150); return; }
      refreshTimer = window.setTimeout(function () {
        refreshTimer = null;
        var full = pendingFull || now() - lastFullMs >= FULL_EVERY_MS;
        if (full) { lastFullMs = now(); pendingFull = false; }
        var beacon = new Image();
        beacon.src = RECEIVER + '/api/refresh?mode=' + (full ? 'full' : 'partial') + '&t=' + now();
      }, 250);
    }
    check();
  }

  function drawTiles() {
    while (el.tiles.firstChild) { el.tiles.removeChild(el.tiles.firstChild); }
    if (!state.pack) { return; }
    var shown = [];
    var c = world(state.center.lat, state.center.lon, state.zoom);
    var left = c.x - state.width / 2, top = c.y - state.mapHeight / 2;
    var x0 = Math.floor(left / TILE), x1 = Math.floor((left + state.width) / TILE);
    var y0 = Math.floor(top / TILE), y1 = Math.floor((top + state.mapHeight) / TILE);
    var x, y, img;
    for (y = y0; y <= y1; y += 1) {
      for (x = x0; x <= x1; x += 1) {
        img = tileImg(state.zoom, x, y);
        if (img) {
          img.style.left = Math.round(x * TILE - left) + 'px';
          img.style.top = Math.round(y * TILE - top) + 'px';
          el.tiles.appendChild(img);
          shown.push(img);
        }
      }
    }
    var key = state.zoom + ':' + Math.round(left) + ':' + Math.round(top);
    if (key !== state.lastTilesKey) {
      var zoomChanged = state.zoom !== state.lastTilesZoom;
      state.lastTilesKey = key;
      state.lastTilesZoom = state.zoom;
      requestRefresh(shown, zoomChanged);
    }
  }

  function screenPoint(lat, lon) {
    var c = world(state.center.lat, state.center.lon, state.zoom);
    var p = world(lat, lon, state.zoom);
    return { x: p.x - c.x + state.width / 2, y: p.y - c.y + state.mapHeight / 2 };
  }

  /* ---------------------------------------------------- marker and trail */

  function drawTrail() {
    while (el.trail.firstChild) { el.trail.removeChild(el.trail.firstChild); }
    if (navActive()) { return; }
    var i, p, d;
    for (i = 0; i < state.trail.length - 1; i += 1) {
      p = screenPoint(state.trail[i].lat, state.trail[i].lon);
      if (p.x < 0 || p.y < 0 || p.x > state.width || p.y > state.mapHeight) { continue; }
      d = document.createElement('div');
      d.className = 'crumb';
      d.style.left = Math.round(p.x) + 'px';
      d.style.top = Math.round(p.y) + 'px';
      el.trail.appendChild(d);
    }
  }

  function placeMarker() {
    if (!state.fix) { el.marker.style.display = 'none'; return; }
    var p = screenPoint(state.fix.lat, state.fix.lon);
    if (p.x < -20 || p.y < -20 || p.x > state.width + 20 || p.y > state.mapHeight + 20) {
      el.marker.style.display = 'none';
      return;
    }
    el.marker.style.display = 'block';
    el.marker.style.left = Math.round(p.x) + 'px';
    el.marker.style.top = Math.round(p.y) + 'px';
    var moving = typeof state.fix.course === 'number' && typeof state.fix.speed === 'number' && state.fix.speed > 1;
    if (moving) {
      var rot = 'rotate(' + Math.round(state.fix.course) + 'deg)';
      el.arrow.style.webkitTransform = rot;
      el.arrow.style.transform = rot;
      el.arrow.style.display = 'block';
    } else {
      el.arrow.style.display = 'none';
    }
  }

  function redraw() {
    drawTiles();
    drawRoute();
    drawTrail();
    placeMarker();
    updateNote();
  }

  function centreOnFix() {
    if (!state.fix) { return; }
    state.center = { lat: state.fix.lat, lon: state.fix.lon };
  }

  function insidePack(lat, lon) {
    var b = state.pack && state.pack.bounds;
    if (!b) { return true; }
    return lat >= b.south && lat <= b.north && lon >= b.west && lon <= b.east;
  }

  function updateNote() {
    var text = '';
    if (!state.pack) {
      text = 'SEM PACK DE MAPA — só posição e rastro';
    } else if (state.fix && !insidePack(state.fix.lat, state.fix.lon)) {
      text = 'FORA DA ÁREA DO MAPA';
    }
    el.note.style.display = text ? 'block' : 'none';
    setText(el.note, 'note', text);
  }


  /* ---------------------------------------------------------- navigation */

  var NAV_STATES = { calculating: 1, rerouting: 1, active: 1, arrived: 1, error: 1 };
  function navActive() { return !!(state.nav && NAV_STATES[state.nav.state]); }

  var TURN_TEXT = {
    straight: 'Siga em frente', slight_left: 'Mantenha-se à esquerda', slight_right: 'Mantenha-se à direita',
    left: 'Vire à esquerda', right: 'Vire à direita', sharp_left: 'Vire acentuado à esquerda',
    sharp_right: 'Vire acentuado à direita', uturn: 'Faça o retorno', arrive: 'Chegada'
  };
  var TURN_SHORT = {
    straight: 'em frente', slight_left: 'leve à esq.', slight_right: 'leve à dir.', left: 'à esquerda',
    right: 'à direita', sharp_left: 'acentuada à esq.', sharp_right: 'acentuada à dir.', uturn: 'retorno',
    arrive: 'chegada'
  };

  function fmtDist(m) {
    if (typeof m !== 'number') { return ''; }
    if (m >= 1000) { return (Math.round(m / 100) / 10).toFixed(1).replace('.', ',') + ' km'; }
    if (m >= 100) { return Math.round(m / 10) * 10 + ' m'; }
    return Math.max(0, Math.round(m / 5) * 5) + ' m';
  }

  function maneuverText(m) {
    if (!m) { return ''; }
    if (m.type === 'roundabout') { return 'Rotatória: ' + (m.exit || 1) + 'ª saída'; }
    return TURN_TEXT[m.mod] || m.mod;
  }

  function loadRoute(id) {
    if (state.routeLoading === id) { return; }
    state.routeLoading = id;
    var head = document.getElementsByTagName('head')[0];
    var sc = document.createElement('script');
    sc.type = 'text/javascript';
    sc.src = 'route.js?t=' + now();
    sc.onload = function () { head.removeChild(sc); state.routeLoading = null; };
    sc.onerror = function () { head.removeChild(sc); state.routeLoading = null; };
    head.appendChild(sc);
  }

  function onRoute(r) {
    if (!r || !r.pts) { return; }
    var pts = [], i;
    for (i = 0; i + 1 < r.pts.length; i += 2) { pts.push({ lat: r.pts[i] / 1e6, lon: r.pts[i + 1] / 1e6 }); }
    state.route = { id: r.id, profile: r.profile, pts: pts, cum: r.cum, maneuvers: r.maneuvers || [], dest: r.dest };
    state.routeId = r.id;
    state.autoZoom = true;
    if (!viewForNav(true)) { redraw(); }
  }

  function handleNav(nav) {
    var was = navActive();
    state.nav = (nav && typeof nav === 'object' && nav.state && nav.state !== 'none') ? nav : null;
    var is = navActive();
    if (!is) {
      if (was) {
        state.route = null; state.routeId = null;
        layout(); redraw();
      }
      return;
    }
    if (state.nav.route_id && state.nav.route_id !== state.routeId) { loadRoute(state.nav.route_id); }
    if (!was) { state.autoZoom = true; layout(); redraw(); }
    updateNavPanel();
  }

  function updateNavPanel() {
    if (!navActive()) { return; }
    var nav = state.nav, st = nav.state, icon = '', dist = '', name = '', then = '';
    if (st === 'calculating' || st === 'rerouting') {
      dist = st === 'calculating' ? 'Calculando…' : 'Recalculando…';
      name = (nav.dest && nav.dest.label) || '';
    } else if (st === 'error') {
      dist = 'Sem rota';
      name = nav.error || '';
    } else if (st === 'arrived') {
      icon = 'arrive';
      dist = 'Você chegou';
      name = (nav.dest && nav.dest.label) || '';
    } else {
      var n = nav.next;
      if (n) {
        icon = n.type === 'roundabout' ? 'roundabout' : n.mod;
        dist = fmtDist(n.dist_m);
        name = maneuverText(n) + (n.name ? ' · ' + n.name : '');
      } else {
        // new route, progress arrives with the next GPS fix
        icon = 'straight';
        dist = 'Rota pronta';
        name = (nav.dest && nav.dest.label) || '';
      }
      var t = nav['then'];
      if (t && n && t.dist_m - n.dist_m < 400) {
        then = 'depois ' + (t.type === 'roundabout' ? 'rotatória' : (TURN_SHORT[t.mod] || t.mod)) +
          ' em ' + fmtDist(t.dist_m - n.dist_m) + (t.name ? ' · ' + t.name : '');
      } else if (typeof nav.remaining_m === 'number') {
        then = fmtDist(nav.remaining_m) + ' até o destino · ' + Math.max(1, Math.round((nav.eta_s || 0) / 60)) + ' min';
      }
    }
    if (state.lastText.navIcon !== icon) {
      state.lastText.navIcon = icon;
      el.navIcon.style.visibility = icon ? 'visible' : 'hidden';
      if (icon) { el.navIcon.src = 'icons/' + icon + '.png'; }
    }
    var exitTxt = (st === 'active' && nav.next && nav.next.type === 'roundabout') ? String(nav.next.exit || 1) : '';
    el.navExit.style.display = exitTxt ? 'block' : 'none';
    setText(el.navExit, 'navExit', exitTxt);
    setText(el.navDist, 'navDist', dist || '&nbsp;');
    setText(el.navName, 'navName', name || '&nbsp;');
    setText(el.navThen, 'navThen', then || '&nbsp;');
  }

  // Route line in DOM: rotated divs (casing white, line black) for the part not yet travelled.
  function segDiv(cls, a, b, h) {
    var dx = b.x - a.x, dy = b.y - a.y;
    var len = Math.sqrt(dx * dx + dy * dy);
    var d = document.createElement('div');
    d.className = cls;
    d.style.left = Math.round(a.x) + 'px';
    d.style.top = Math.round(a.y - h / 2) + 'px';
    d.style.width = Math.round(len + 1) + 'px';
    var rot = 'rotate(' + (Math.atan2(dy, dx) * 180 / Math.PI).toFixed(1) + 'deg)';
    d.style.webkitTransform = rot;
    d.style.transform = rot;
    return d;
  }

  function drawRoute() {
    var box = el.routeSegs;
    while (box.firstChild) { box.removeChild(box.firstChild); }
    el.turnDot.style.display = 'none';
    var r = state.route;
    if (!navActive() || !r || state.nav.state === 'error') { return; }
    var along = (state.nav && typeof state.nav.along_m === 'number') ? state.nav.along_m : 0;
    var pts = r.pts, cum = r.cum, i = 0;
    while (i < pts.length - 2 && cum[i + 1] <= along) { i += 1; }
    var screen = [];
    var f = cum[i + 1] > cum[i] ? Math.max(0, Math.min(1, (along - cum[i]) / (cum[i + 1] - cum[i]))) : 0;
    var start = { lat: pts[i].lat + (pts[i + 1].lat - pts[i].lat) * f, lon: pts[i].lon + (pts[i + 1].lon - pts[i].lon) * f };
    screen.push(screenPoint(start.lat, start.lon));
    for (i = i + 1; i < pts.length; i += 1) { screen.push(screenPoint(pts[i].lat, pts[i].lon)); }
    var W = state.width, H = state.mapHeight, M = 40, lines = [], joints = [], k, a, b;
    for (k = 0; k + 1 < screen.length; k += 1) {
      a = screen[k]; b = screen[k + 1];
      if (Math.max(a.x, b.x) < -M || Math.min(a.x, b.x) > W + M || Math.max(a.y, b.y) < -M || Math.min(a.y, b.y) > H + M) { continue; }
      box.appendChild(segDiv('rc', a, b, 18));
      lines.push([a, b]);
    }
    for (k = 0; k < lines.length; k += 1) {
      box.appendChild(segDiv('rl', lines[k][0], lines[k][1], 9));
      var j = document.createElement('div');
      j.className = 'rj';
      j.style.left = Math.round(lines[k][1].x) + 'px';
      j.style.top = Math.round(lines[k][1].y) + 'px';
      box.appendChild(j);
    }
    var n = state.nav.next;
    if (n && typeof n.lat === 'number') {
      var tp = screenPoint(n.lat, n.lon);
      if (tp.x > -20 && tp.y > -20 && tp.x < W + 20 && tp.y < H + 20) {
        el.turnDot.style.left = Math.round(tp.x) + 'px';
        el.turnDot.style.top = Math.round(tp.y) + 'px';
        el.turnDot.style.display = 'block';
      }
    }
  }

  // Position always at the centre (north up). Zoom from speed, or framed on the
  // next turn when it is close. Returns true when it redrew the map.
  var MOVE_PX = 4;

  function speedZoom(car, kmh) {
    if (car) { return kmh <= 35 ? 17 : (kmh <= 65 ? 16 : 15); }
    return kmh <= 25 ? 17 : 16;
  }

  // Speed zoom with hysteresis: +-3 km/h around band edges keeps the current
  // zoom, and a change must be asked by 2 fixes in a row.
  function autoSpeedZoom(car) {
    var kmh = (typeof state.fix.speed === 'number' ? state.fix.speed : 0) * 3.6;
    var cur = state.zoom;
    var want = speedZoom(car, kmh);
    if (speedZoom(car, kmh - 3) === cur || speedZoom(car, kmh + 3) === cur) { want = cur; }
    if (want === cur) { state.zoomWant = null; state.zoomWantCount = 0; return cur; }
    if (state.zoomWant === want) { state.zoomWantCount += 1; } else { state.zoomWant = want; state.zoomWantCount = 1; }
    return state.zoomWantCount >= 2 ? want : cur;
  }

  // Largest zoom (<= 17) where the turn fits on screen with the position centred.
  function turnZoom(n) {
    var z, fix = state.fix;
    for (z = Math.min(maxZoom(), 17); z > 13; z -= 1) {
      var a = world(fix.lat, fix.lon, z), b = world(n.lat, n.lon, z);
      if (Math.abs(a.x - b.x) < state.width * 0.42 && Math.abs(a.y - b.y) < state.mapHeight * 0.42) { break; }
    }
    return z;
  }

  function movedEnough() {
    var p = screenPoint(state.fix.lat, state.fix.lon);
    var dx = p.x - state.width / 2, dy = p.y - state.mapHeight / 2;
    return dx * dx + dy * dy >= MOVE_PX * MOVE_PX;
  }

  function applyView(z, force) {
    var zoomChanged = z !== state.zoom;
    var moved = movedEnough();
    if (!force && !zoomChanged && !moved) { return false; }
    state.zoom = z;
    state.center = { lat: state.fix.lat, lon: state.fix.lon };
    redraw();
    return true;
  }

  function viewForNav(force) {
    if (!navActive() || !state.route || !state.fix || !state.follow) { return false; }
    var z = state.zoom;
    if (state.autoZoom) {
      var car = state.route.profile === 'car';
      var near = car ? 400 : 250;
      var n = state.nav.next;
      if (n && typeof n.dist_m === 'number' && n.dist_m <= near && state.nav.state === 'active') {
        z = turnZoom(n);
        state.zoomWant = null; state.zoomWantCount = 0;
      } else {
        z = Math.min(maxZoom(), autoSpeedZoom(car));
      }
      if (z !== state.zoom) { setActive('btn-overview', false); setActive('btn-detail', false); }
    }
    return applyView(z, force);
  }

  /* ---------------------------------------------------------- status UI */

  function setGps(cls, text) {
    if (state.lastGpsClass !== cls) {
      el.gps.className = cls;
      state.lastGpsClass = cls;
    }
    setText(el.gps, 'gps', text);
  }

  function showHelp(show) {
    if (!show) { el.help.style.display = 'none'; return; }
    var info = state.receiverInfo || {};
    var ip = info.ip || 'IP?';
    var token = info.token || '?';
    var html;
    if (!state.receiverOk) {
      html = '<b>Receptor de GPS desligado</b><br>' +
        'Conecte o Kindle ao hotspot do celular e abra, na biblioteca, ' +
        '<b>KindleMap GPS - Iniciar</b>.';
    } else {
      html = '<b>Aguardando posição do celular</b><br>' +
        'OwnTracks (modo HTTP):<br>http://' + ip + ':8765/owntracks?token=' + token + '<br>' +
        'GPSLogger: http://' + ip + ':8765/api/update?token=' + token + '&amp;lat=%LAT&amp;lon=%LON&amp;spd=%SPD&amp;dir=%DIR&amp;acc=%ACC';
    }
    setText(el.help, 'help', html);
    el.help.style.display = 'block';
  }

  function refreshStatus() {
    var age = state.fix ? Math.max(0, Math.round((now() - state.receivedMs) / 1000)) : null;
    var stale = age !== null && age > STALE_S;
    var lost = age !== null && age > LOST_S;

    if (!state.receiverOk && !state.fix) {
      setGps('', 'DESLIGADO');
    } else if (!state.fix) {
      setGps('', 'AGUARDANDO');
    } else if (lost) {
      setGps('stale', 'SEM SINAL');
    } else if (stale) {
      setGps('stale', 'GPS ANTIGO');
    } else {
      setGps('ok', 'GPS OK');
    }

    var markerCls = stale ? 'stale' : '';
    if (el.marker.className !== markerCls) { el.marker.className = markerCls; }

    if (state.fix && !stale && typeof state.fix.speed === 'number') {
      setText(el.speed, 'speed', Math.round(state.fix.speed * 3.6) + ' <span id="speed-unit">km/h</span>');
    } else {
      setText(el.speed, 'speed', '-- <span id="speed-unit">km/h</span>');
    }
    if (state.fix && !stale && typeof state.fix.course === 'number' && typeof state.fix.speed === 'number' && state.fix.speed > 1) {
      setText(el.heading, 'heading', compass(state.fix.course) + ' ' + Math.round(state.fix.course) + '&deg;');
    } else {
      setText(el.heading, 'heading', '&nbsp;');
    }
    if (state.fix) {
      // Age changes every second; rounding to 5 s limits partial refreshes.
      var shownAge = age < 10 ? age : Math.floor(age / 5) * 5;
      var acc = typeof state.fix.accuracy === 'number' ? '±' + Math.round(state.fix.accuracy) + ' m · ' : '';
      setText(el.detail, 'detail', acc + 'há ' + shownAge + ' s');
    } else {
      setText(el.detail, 'detail', '&nbsp;');
    }

    var info = state.receiverInfo;
    var line;
    if (!state.receiverOk) {
      line = 'Receptor desligado';
    } else if (info && info.ip) {
      line = info.ip + ':8765' + (info.token ? ' · token ' + info.token : '') + '';
    } else {
      line = 'Receptor ativo · sem Wi‑Fi';
    }
    if (navActive() && state.nav.dest) {
      line = '→ ' + (state.nav.dest.label || 'destino') + (typeof state.nav.remaining_m === 'number' ?
        ' · ' + fmtDist(state.nav.remaining_m) + ' · ' + Math.max(1, Math.round((state.nav.eta_s || 0) / 60)) + ' min' : '');
      if (stale) { line = (lost ? 'SEM SINAL GPS · ' : 'GPS ANTIGO · ') + line; }
    }
    setText(el.statusText, 'status', line);
    showHelp(!state.fix);
  }

  /* ------------------------------------------------------- data intake */

  function receive(snap, via) {
    state.receiverOk = true;
    if (snap && typeof snap === 'object') {
      state.receiverInfo = { ip: snap.ip || null, token: snap.token || (state.receiverInfo && state.receiverInfo.token) || null };
      handleNav(snap.nav);
      var f = snap.fix;
      if (f && typeof f.latitude === 'number' && typeof f.longitude === 'number') {
        var received = typeof f.received_ms === 'number' ? f.received_ms : now();
        if (received !== state.receivedMs) { acceptFix(f, received); }
      }
      handleCommand(snap.cmd);
    }
    if (via) { state.mode = via; }
    refreshStatus();
  }

  function acceptFix(f, received) {
    var fix = {
      lat: f.latitude,
      lon: f.longitude,
      speed: typeof f.speed_mps === 'number' ? f.speed_mps : null,
      course: typeof f.course_deg === 'number' ? f.course_deg : null,
      accuracy: typeof f.accuracy_m === 'number' ? f.accuracy_m : null
    };
    var first = !state.fix;
    var last = state.trail.length ? state.trail[state.trail.length - 1] : null;
    if (!last || distanceM(last, fix) >= TRAIL_MIN_M) {
      state.trail.push({ lat: fix.lat, lon: fix.lon });
      if (state.trail.length > TRAIL_MAX) { state.trail.shift(); }
    }
    state.fix = fix;
    state.receivedMs = received;
    if (navActive()) {
      if (!viewForNav(first)) {
        // map not moved: only the marker (and the turn dot) change
        placeMarker();
        updateNote();
      }
      return;
    }
    if (state.follow && applyView(state.zoom, first)) {
      return;
    } else if (state.follow) {
      placeMarker();
      updateNote();
    } else {
      // Only the marker and new crumb move: small partial refresh.
      drawTrail();
      placeMarker();
      updateNote();
    }
  }

  function pollFile() {
    var head = document.getElementsByTagName('head')[0];
    var s = document.createElement('script');
    var done = false;
    s.type = 'text/javascript';
    s.src = 'location.js?t=' + now();
    s.onload = function () { done = true; head.removeChild(s); };
    s.onerror = function () {
      if (done) { return; }
      done = true;
      head.removeChild(s);
      state.receiverOk = false;
      refreshStatus();
    };
    head.appendChild(s);
  }

  function poll() {
    // Always use the local file channel: every XHR makes Mesquite turn on the
    // system activity spinner (JunoStatusBarDriver SpinnerHelper), which keeps
    // the UI "busy" and swallows taps. Reading a local file does not.
    state.pollCount += 1;
    pollFile();
    refreshStatus();
  }

  /* --------------------------------------------------------- controls */

  function setActive(id, on) {
    var b = $(id);
    var cls = 'btn' + (b.className.indexOf('square') >= 0 ? ' square' : '') + (on ? ' active' : '');
    if (b.className !== cls) { b.className = cls; }
  }

  // Commands from the phone control page (/control on the receiver). The
  // Kindle touchscreen does not reach this WAF, so the phone is the remote.
  function handleCommand(cmd) {
    var seq = cmd && typeof cmd.seq === 'number' ? cmd.seq : 0;
    // First snapshot after boot: remember the last command without replaying it.
    if (state.cmdSeq === null) { state.cmdSeq = seq; return; }
    if (!cmd || typeof cmd.seq !== 'number') { return; }
    if (cmd.seq === state.cmdSeq) { return; }
    state.cmdSeq = cmd.seq;
    debugLog('cmd ' + cmd.c);
    if (cmd.c === 'in') { setZoom(state.zoom + 1); }
    else if (cmd.c === 'out') { setZoom(state.zoom - 1); }
    else if (cmd.c === 'detail') { setZoom(detailZoom()); }
    else if (cmd.c === 'overview') { setZoom(overviewZoom()); }
    else if (cmd.c === 'follow') { toggleFollow(); }
  }

  function setZoom(z) {
    state.autoZoom = false;
    state.zoom = clamp(z, minZoom(), maxZoom());
    setActive('btn-overview', state.zoom === overviewZoom());
    setActive('btn-detail', state.zoom === detailZoom());
    if (state.follow) { centreOnFix(); }
    redraw();
  }

  var lastTouch = 0;
  function bind(id, fn) {
    var b = $(id);
    b.addEventListener('touchend', function (e) { lastTouch = now(); e.preventDefault(); fn(); }, false);
    b.addEventListener('click', function () { if (now() - lastTouch > 700) { fn(); } }, false);
  }

  bind('btn-overview', function () { setZoom(overviewZoom()); });
  bind('btn-detail', function () { setZoom(detailZoom()); });
  bind('btn-out', function () { setZoom(state.zoom - 1); });
  bind('btn-in', function () { setZoom(state.zoom + 1); });
  bind('btn-follow', function () { toggleFollow(); });

  function toggleFollow() {
    state.follow = !state.follow;
    setActive('btn-follow', state.follow);
    if (state.follow) {
      state.autoZoom = true;
      if (!viewForNav(true) && state.fix) { centreOnFix(); redraw(); }
    }
  }

  /* ------------------------------------------------------------- boot */

  function applyPack(pack) {
    if (!pack || !pack.center) { return; }
    state.pack = pack;
    state.center = {
      lat: typeof pack.center.latitude === 'number' ? pack.center.latitude : pack.center.lat,
      lon: typeof pack.center.longitude === 'number' ? pack.center.longitude : pack.center.lon
    };
    state.zoom = overviewZoom();
    if (pack.attribution) { $('attribution').innerHTML = pack.attribution.replace('©', '&copy;'); }
  }

  /* --------------------------------------------- touch diagnostics */

  // Touch diagnostics are off by default: every XHR turns on the system
  // activity spinner. Set DEBUG = true to log events to /tmp/kindlemap/events.log.
  var DEBUG = false;
  function debugLog(msg) {
    if (!DEBUG) { return; }
    try {
      var x = new XMLHttpRequest();
      x.open('GET', RECEIVER + '/api/log?e=' + encodeURIComponent(msg), true);
      x.send(null);
    } catch (ignore) {}
  }

  function logEvent(e) {
    var t = e.target || {};
    var p = (e.changedTouches && e.changedTouches[0]) || e;
    debugLog(e.type + ' id=' + (t.id || t.tagName) + ' x=' + Math.round(p.clientX || 0) + ' y=' + Math.round(p.clientY || 0));
  }

  var EVENTS = ['touchstart', 'touchend', 'mousedown', 'mouseup', 'click', 'tap', 'gesturestart'];
  var ei;
  for (ei = 0; ei < EVENTS.length; ei += 1) {
    document.addEventListener(EVENTS[ei], logEvent, true);
  }
  window.onerror = function (msg, src, line) { debugLog('jserror ' + msg + ' @' + line); };
  debugLog('boot ' + window.innerWidth + 'x' + window.innerHeight + ' ontouchstart=' + ('ontouchstart' in window) +
    ' kindle=' + (typeof window.kindle) + ' appmgr=' + (window.kindle && typeof window.kindle.appmgr));

  /* ------------------------------------------- Kindle app lifecycle */

  // Same pattern as Amazon's own WAFs (shared/applicationManager.js and
  // webview.js): handle appmgr load/go and configure the system chrome bar on
  // "go". Without these callbacks mesquite logs "cannot find callback
  // function" and the app receives no input.
  function configureChrome() {
    try {
      window.kindle.messaging.sendMessage('com.lab126.chromebar', 'configureChrome', {
        appId: 'com.lucaslima.kindlemap',
        searchBar: { clientParams: { profile: { name: 'default', buttons: [
          { id: 'menu', state: 'disabled', handling: 'system' }
        ] } } }
      });
      debugLog('chrome configured');
    } catch (e) { debugLog('chrome error ' + e); }
  }

  if (window.kindle && window.kindle.appmgr) {
    window.kindle.appmgr.onload = function () { debugLog('appmgr load'); };
    window.kindle.appmgr.ongo = function (args) {
      // Optional launch parameter: app://com.lucaslima.kindlemap?zoom=14
      var q = typeof args === 'string' ? args : (args && (args.queryString || args.query || '')) || '';
      var m = /zoom=(\d+)/.exec(String(q));
      debugLog('appmgr go ' + String(q).slice(0, 60));
      configureChrome();
      if (m) { setZoom(parseInt(m[1], 10)); } else { redraw(); }
    };
    window.kindle.appmgr.onpause = function () { debugLog('appmgr pause'); };
    window.kindle.appmgr.onunload = function () { debugLog('appmgr unload'); };
  }

  window.KindleGpsMap = {
    receive: receive,
    route: onRoute,
    setFix: function (f) { receive({ fix: f }, null); },
    redraw: redraw,
    state: state
  };

  layout();
  if (window.KINDLE_MAP_PACK) { applyPack(window.KINDLE_MAP_PACK); }
  redraw();
  refreshStatus();
  window.addEventListener('resize', function () { layout(); redraw(); }, false);
  poll();
  window.setInterval(poll, POLL_MS);
}());
