-- Замер «сколько реально меняется в окне мегабазы» (TAR-166, замер №5).
-- Окно — прямоугольник размером с экран. Считаем, что пересекает его край (предметы на
-- конвейерах, роботы, вагоны) и что происходит внутри (манипуляторы, крафты), а также
-- сколько стоит клиент, если вне окна всё заморожено.
local M = {}

local BELT_TYPES = {"transport-belt", "underground-belt", "splitter", "linked-belt", "loader", "loader-1x1"}
local ROBOT_TYPES = {"construction-robot", "logistic-robot"}
local STOCK_TYPES = {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"}
local CRAFTER_TYPES = {"assembling-machine", "furnace", "rocket-silo"}

local function surface()
  return game.surfaces["nauvis"]
end

local function inside(w, pos)
  return pos.x >= w.x0 and pos.x < w.x1 and pos.y >= w.y0 and pos.y < w.y1
end

local function area(w)
  return {{w.x0, w.y0}, {w.x1, w.y1}}
end

-- Размеры базы и самые частые типы сущностей игрока.
function M.info()
  local all = surface().find_entities_filtered{force = "player"}
  local by_type, x0, y0, x1, y1 = {}, math.huge, math.huge, -math.huge, -math.huge
  for _, e in pairs(all) do
    by_type[e.type] = (by_type[e.type] or 0) + 1
    local p = e.position
    if p.x < x0 then x0 = p.x end
    if p.y < y0 then y0 = p.y end
    if p.x > x1 then x1 = p.x end
    if p.y > y1 then y1 = p.y end
  end
  local top = {}
  for t, n in pairs(by_type) do top[#top + 1] = {t, n} end
  table.sort(top, function(a, b) return a[2] > b[2] end)
  local out = {total = #all, bbox = {x0, y0, x1, y1}, top = {}}
  for i = 1, math.min(15, #top) do out.top[i] = top[i] end
  return helpers.table_to_json(out)
end

-- Конвейеры окна, у которых сосед по ленте снаружи: входящие (in) и выходящие (out).
local function edge_belts(w)
  local ins, outs = {}, {}
  for _, b in pairs(surface().find_entities_filtered{area = area(w), type = BELT_TYPES}) do
    local n = b.belt_neighbours
    for _, src in pairs(n.inputs) do
      if not inside(w, src.position) then ins[#ins + 1] = b break end
    end
    for _, dst in pairs(n.outputs) do
      if not inside(w, dst.position) then outs[#outs + 1] = b break end
    end
    -- Подземный вход внутри, выход снаружи (и наоборот) — тоже пересечение.
    if b.type == "underground-belt" and b.neighbours and not inside(w, b.neighbours.position) then
      if b.belt_to_ground_type == "input" then outs[#outs + 1] = b else ins[#ins + 1] = b end
    end
  end
  return ins, outs
end

-- n случайных окон w×h с центром на случайной сущности игрока (то есть там, где застроено).
function M.windows(msg)
  local all = surface().find_entities_filtered{force = "player", type = CRAFTER_TYPES}
  local rng = game.create_random_generator(msg.seed or 1)
  local out = {}
  for i = 1, msg.n do
    local c = all[rng(#all)].position
    local w = {x0 = math.floor(c.x - msg.w / 2), y0 = math.floor(c.y - msg.h / 2)}
    w.x1, w.y1 = w.x0 + msg.w, w.y0 + msg.h
    local s = surface()
    local ins, outs = edge_belts(w)
    out[i] = {
      x0 = w.x0, y0 = w.y0, x1 = w.x1, y1 = w.y1,
      entities = s.count_entities_filtered{area = area(w), force = "player"},
      belts = s.count_entities_filtered{area = area(w), type = BELT_TYPES},
      inserters = s.count_entities_filtered{area = area(w), type = "inserter"},
      crafters = s.count_entities_filtered{area = area(w), type = CRAFTER_TYPES},
      edge_in = #ins, edge_out = #outs,
    }
  end
  return helpers.table_to_json(out)
end

-- Набор id предметов на лентах конвейера.
local function item_ids(b, into)
  for lane = 1, b.get_max_transport_line_index() do
    for _, it in pairs(b.get_transport_line(lane).get_detailed_contents()) do
      into[it.unique_id] = true
    end
  end
end

local function unit_set(w, types)
  local set = {}
  for _, e in pairs(surface().find_entities_filtered{area = area(w), type = types}) do
    set[e.unit_number] = true
  end
  return set
end

local function count_new(cur, prev)
  local n = 0
  for id in pairs(cur) do if not prev[id] then n = n + 1 end end
  return n
end

-- Начать наблюдение за окнами на ticks тиков.
function M.flow_start(msg)
  local list = {}
  for i, w in ipairs(msg.windows) do
    local ins, outs = edge_belts(w)
    local inserters = surface().find_entities_filtered{area = area(w), type = "inserter"}
    local crafters = surface().find_entities_filtered{area = area(w), type = CRAFTER_TYPES}
    local finished = 0
    for _, c in pairs(crafters) do finished = finished + c.products_finished end
    local held = {}
    for k, ins_e in pairs(inserters) do held[k] = ins_e.held_stack.valid_for_read end
    list[i] = {
      w = w, ins = ins, outs = outs, inserters = inserters, held = held,
      crafters = crafters, finished0 = finished,
      prev_in = {}, prev_out = {}, prev_robots = unit_set(w, ROBOT_TYPES), prev_stock = unit_set(w, STOCK_TYPES),
      items_in = 0, items_out = 0, robots_in = 0, stock_in = 0, swings = 0,
    }
  end
  storage.mega_flow = {list = list, left = msg.ticks, ticks = msg.ticks}
  return #list
end

-- Вызывается из on_tick мода.
function M.on_tick()
  local f = storage.mega_flow
  if not f or f.left <= 0 then return end
  f.left = f.left - 1
  for _, s in ipairs(f.list) do
    -- Предмет въехал: появился id на входящем краевом конвейере, которого не было тиком раньше.
    local cur = {}
    for _, b in ipairs(s.ins) do if b.valid then item_ids(b, cur) end end
    s.items_in = s.items_in + count_new(cur, s.prev_in)
    s.prev_in = cur
    -- Выехал: id был на выходящем краевом конвейере и пропал.
    cur = {}
    for _, b in ipairs(s.outs) do if b.valid then item_ids(b, cur) end end
    s.items_out = s.items_out + count_new(s.prev_out, cur)
    s.prev_out = cur
    cur = unit_set(s.w, ROBOT_TYPES)
    s.robots_in = s.robots_in + count_new(cur, s.prev_robots)
    s.prev_robots = cur
    cur = unit_set(s.w, STOCK_TYPES)
    s.stock_in = s.stock_in + count_new(cur, s.prev_stock)
    s.prev_stock = cur
    -- Взмах манипулятора: рука стала полной или пустой.
    for k, ie in ipairs(s.inserters) do
      if ie.valid then
        local h = ie.held_stack.valid_for_read
        if h ~= s.held[k] then s.swings = s.swings + 1 end
        s.held[k] = h
      end
    end
  end
end

-- Итог наблюдения: всё в пересчёте на тик.
function M.flow_result()
  local f = storage.mega_flow
  if not f then error("наблюдение не запускалось") end
  if f.left > 0 then return "running " .. f.left end
  local out = {}
  for i, s in ipairs(f.list) do
    local finished = 0
    for _, c in pairs(s.crafters) do if c.valid then finished = finished + c.products_finished end end
    local t = f.ticks
    out[i] = {
      edge_in = #s.ins, edge_out = #s.outs,
      items_in = s.items_in / t, items_out = s.items_out / t,
      robots_in = s.robots_in / t, stock_in = s.stock_in / t,
      swings = s.swings / t, crafts = (finished - s.finished0) / t,
    }
  end
  storage.mega_flow = nil
  return helpers.table_to_json(out)
end

-- Заморозить всё обновляемое вне окна. Возвращает {заморожено, не замораживается (вне окна)}.
function M.freeze_outside(msg)
  local frozen, skipped = 0, 0
  for _, e in pairs(surface().find_entities_filtered{force = "player"}) do
    if not inside(msg, e.position) then
      if e.is_updatable then
        e.disabled_by_script = true
        if e.disabled_by_script then frozen = frozen + 1 else skipped = skipped + 1 end
      else
        skipped = skipped + 1
      end
    end
  end
  return helpers.table_to_json{frozen = frozen, skipped = skipped}
end

-- Очистить конвейеры вне окна (содержимое «у ядра»). Возвращает число очищенных.
function M.clear_belts_outside(msg)
  local n = 0
  for _, b in pairs(surface().find_entities_filtered{type = BELT_TYPES}) do
    if not inside(msg, b.position) then
      for lane = 1, b.get_max_transport_line_index() do b.get_transport_line(lane).clear() end
      n = n + 1
    end
  end
  return n
end

-- «Здоровье» базы: статусы машин и манипуляторов, поезда, наука в минуту.
-- Нужно, чтобы понять, работает ли база после загрузки (например, после миграции 1.1 → 2.0).
function M.health()
  local s = surface()
  local status_name = {}
  for k, v in pairs(defines.entity_status) do status_name[v] = k end
  local function histogram(types)
    local h = {}
    for _, e in pairs(s.find_entities_filtered{force = "player", type = types}) do
      local k = status_name[e.status] or "none"
      h[k] = (h[k] or 0) + 1
    end
    return h
  end
  local state_name = {}
  for k, v in pairs(defines.train_state) do state_name[v] = k end
  local trains, moving, states = 0, 0, {}
  for _, t in pairs(game.train_manager.get_trains{surface = s}) do
    trains = trains + 1
    if t.speed ~= 0 then moving = moving + 1 end
    local k = state_name[t.state] or "?"
    states[k] = (states[k] or 0) + 1
  end
  local stats = game.forces.player.get_item_production_statistics(s)
  local science = {}
  for _, name in ipairs{"automation-science-pack", "logistic-science-pack", "military-science-pack",
                         "chemical-science-pack", "production-science-pack", "utility-science-pack",
                         "space-science-pack"} do
    science[name] = stats.get_flow_count{
      name = name, category = "output", precision_index = defines.flow_precision_index.one_minute,
      count = true,
    }
  end
  return helpers.table_to_json{
    tick = game.tick,
    crafters = histogram(CRAFTER_TYPES),
    drills = histogram("mining-drill"),
    inserters = histogram("inserter"),
    trains = trains, trains_moving = moving, train_states = states,
    science_per_min = science,
  }
end

return M
