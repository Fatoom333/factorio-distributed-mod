-- Сцены для сверки модели ядра с настоящей игрой (этап M0).
-- Мод строит сцену из JSON на отдельной пустой поверхности и каждый тик пишет состояние
-- в файл-эталон (<name>.dump.jsonl в script-output). Формат сцены и эталона — в
-- factorio-distributed-core/tests/fidelity/README.md.
--
-- Фаза «тик 0». Состояние читаем только в обработчике on_tick, всегда в одной и той же фазе
-- тика (до обновления сущностей), поэтому соседние снимки отстоят ровно на один тик игры.
--   1. scene_build строит сущности, сундуки пустые; манипуляторы питаются и «прогреваются»
--      (буфер энергии полный) не меньше WARMUP тиков.
--   2. scene_run только ставит флаг. В ближайшем on_tick сундуки заполняются предметами и
--      тут же пишется снимок t = 0: предметы лежат в сундуках, ни один манипулятор ещё
--      не обновился с ними. Снимок t = k — состояние после k обновлений игры.
--   3. После снимка t = ticks файл пишется целиком (helpers.write_file, только сервер).

local M = {}

local SURFACE = "fd-scene"
local WARMUP = 60
local AREA = 48

local DIRS = {
  north = defines.direction.north, east = defines.direction.east,
  south = defines.direction.south, west = defines.direction.west,
}

local function round(x)
  return math.floor(x + 0.5)
end

local function num(x)
  local s = string.format("%.4f", x):gsub("0+$", ""):gsub("%.$", "")
  return s
end

local function get_surface()
  local surface = game.surfaces[SURFACE]
  if not surface then
    surface = game.create_surface(SURFACE, {width = 256, height = 256, peaceful_mode = true})
  end
  return surface
end

-- Пустая плоскость: генерируем чанки, сносим всё, кладём lab-плитку.
local function clear_surface(surface)
  surface.request_to_generate_chunks({0, 0}, 2)
  surface.force_generate_chunk_requests()
  for _, e in pairs(surface.find_entities{{-AREA - 16, -AREA - 16}, {AREA + 16, AREA + 16}}) do
    if e.valid then e.destroy() end
  end
  local tiles = {}
  for x = -AREA, AREA - 1 do
    for y = -AREA, AREA - 1 do
      tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}}
    end
  end
  surface.set_tiles(tiles)
end

-- Бесконечное питание: интерфейс + подстанции вдоль x над сценой (y = -6), шаг 14 клеток.
local function build_power(surface, scene)
  local lo, hi
  for _, s in ipairs(scene.entities) do
    if s.name:find("inserter", 1, true) then
      local x = s.position[1]
      lo = lo and math.min(lo, x) or x
      hi = hi and math.max(hi, x) or x
    end
  end
  if not lo then return 0 end
  local n = 0
  local sx = math.floor(lo)
  local first = sx
  while true do
    local sub = surface.create_entity{name = "substation", position = {sx, -6}, force = "player"}
    if not sub then error("scene_build: не поставилась подстанция") end
    n = n + 1
    if sx + 7 >= hi then break end
    sx = sx + 14
  end
  local ei = surface.create_entity{name = "electric-energy-interface", position = {first - 3, -6}, force = "player"}
  if not ei then error("scene_build: не поставился источник энергии") end
  ei.electric_buffer_size = 1e12
  ei.power_production = 1e9
  ei.energy = 1e12
  return n + 1
end

function M.build(msg)
  local scene = msg.scene
  if type(scene) ~= "table" or type(scene.entities) ~= "table" or type(scene.name) ~= "string" then
    error("scene_build: нужны scene.name и scene.entities")
  end
  if storage.scene_run then error("scene_build: идёт запись") end
  if not scene.name:match("^[%w_%-]+$") then error("scene_build: плохое имя сцены") end
  storage.scene = nil
  storage.scene_done = nil

  local surface = get_surface()
  clear_surface(surface)

  local recs = {}
  for i, s in ipairs(scene.entities) do
    local dir = DIRS[s.direction or "north"]
    if not dir then error("scene_build: плохое direction у сущности " .. i) end
    local e = surface.create_entity{
      name = s.name, position = s.position, direction = dir, force = "player",
    }
    if not e then error("scene_build: не поставилась сущность " .. i .. " " .. s.name) end
    local kind
    if e.type == "transport-belt" then kind = "belt"
    elseif e.type == "inserter" then kind = "inserter"
    elseif e.type == "container" then kind = "chest"
    else error("scene_build: тип не поддержан: " .. e.type) end
    recs[i] = {
      entity = e, unit_number = e.unit_number, kind = kind,
      x = s.position[1], y = s.position[2], items = s.items,
    }
  end
  build_power(surface, scene)
  storage.scene = {name = scene.name, ticks = scene.ticks, entities = recs, built_tick = game.tick}
  return "ok " .. #recs
end

-- Пикап/дроп манипуляторов и направления: проверка правила direction (в игре).
function M.info()
  local sc = storage.scene
  if not sc then error("scene_info: сцены нет") end
  local out = {}
  for i, r in ipairs(sc.entities) do
    local e = r.entity
    local o = {name = e.name, position = {r.x, r.y}, direction = e.direction, unit_number = r.unit_number}
    if r.kind == "inserter" then
      o.pickup = {e.pickup_position.x, e.pickup_position.y}
      o.drop = {e.drop_position.x, e.drop_position.y}
    end
    out[i] = o
  end
  return helpers.table_to_json(out)
end

function M.run(msg)
  local sc = storage.scene
  if not sc then error("scene_run: сначала scene_build") end
  if storage.scene_run then error("scene_run: уже идёт") end
  local left = WARMUP - (game.tick - sc.built_tick)
  if left > 0 then error("not ready, wait " .. left .. " ticks") end
  local ticks = msg.ticks or sc.ticks
  local file = msg.file or (sc.name .. ".dump.jsonl")
  if type(ticks) ~= "number" or ticks < 1 then error("scene_run: нужен ticks") end
  storage.scene_done = nil
  storage.scene_error = nil
  storage.scene_run = {pending = true, left = ticks, t = 0, file = file, lines = {}}
  return "ok"
end

function M.status()
  local run = storage.scene_run
  if run then return "running " .. (run.left + (run.pending and 1 or 0)) end
  if storage.scene_error then return "error " .. storage.scene_error end
  if storage.scene_done then return "done " .. storage.scene_done end
  return "idle"
end

local function fill_chests(sc)
  for _, r in ipairs(sc.entities) do
    if r.kind == "chest" and r.items then
      local inv = r.entity.get_inventory(defines.inventory.chest)
      inv.clear()
      for name, count in pairs(r.items) do
        local inserted = inv.insert{name = name, count = count}
        if inserted ~= count then error("scene_run: сундук не вместил " .. name) end
      end
    end
  end
end

local function snapshot(sc, t)
  local belts, inserters, chests = {}, {}, {}
  for _, r in ipairs(sc.entities) do
    local e = r.entity
    if not e.valid then error("scene: сущность пропала") end
    if r.kind == "belt" then
      local lanes = {}
      for lane = 1, 2 do
        local items = {}
        for _, it in ipairs(e.get_transport_line(lane).get_detailed_contents()) do
          items[#items + 1] = {name = it.stack.name, p = round(it.position * 256)}
        end
        table.sort(items, function(a, b) return a.p < b.p end)
        local parts = {}
        for k, it in ipairs(items) do
          parts[k] = string.format('{"item":"%s","p":%d}', it.name, it.p)
        end
        lanes[lane] = "[" .. table.concat(parts, ",") .. "]"
      end
      belts[#belts + 1] = string.format('{"pos":[%s,%s],"lines":[%s,%s]}',
        num(r.x), num(r.y), lanes[1], lanes[2])
    elseif r.kind == "inserter" then
      local hs = e.held_stack
      local held, count = "null", 0
      if hs.valid_for_read then
        held = '"' .. hs.name .. '"'
        count = hs.count
      end
      local hp = e.held_stack_position
      inserters[#inserters + 1] = string.format('{"pos":[%s,%s],"held":%s,"held_count":%d,"hand":[%d,%d]}',
        num(r.x), num(r.y), held, count, round(hp.x * 256), round(hp.y * 256))
    else
      local totals = {}
      for _, c in ipairs(e.get_inventory(defines.inventory.chest).get_contents()) do
        totals[c.name] = (totals[c.name] or 0) + c.count
      end
      local names = {}
      for name in pairs(totals) do names[#names + 1] = name end
      table.sort(names)
      local parts = {}
      for k, name in ipairs(names) do
        parts[k] = string.format('"%s":%d', name, totals[name])
      end
      chests[#chests + 1] = string.format('{"pos":[%s,%s],"items":{%s}}',
        num(r.x), num(r.y), table.concat(parts, ","))
    end
  end
  return string.format('{"t":%d,"belts":[%s],"inserters":[%s],"chests":[%s]}',
    t, table.concat(belts, ","), table.concat(inserters, ","), table.concat(chests, ","))
end

function M.on_tick()
  local run = storage.scene_run
  if not run then return end
  local sc = storage.scene
  local ok, err = pcall(function()
    if run.pending then
      fill_chests(sc)
      run.pending = false
    else
      run.t = run.t + 1
      run.left = run.left - 1
    end
    run.lines[#run.lines + 1] = snapshot(sc, run.t)
  end)
  if not ok then
    storage.scene_run = nil
    storage.scene_done = nil
    storage.scene_error = tostring(err)
    return
  end
  if run.left == 0 and not run.pending then
    helpers.write_file(run.file, table.concat(run.lines, "\n") .. "\n", false, 0)
    storage.scene_done = run.file
    storage.scene_run = nil
  end
end

return M
