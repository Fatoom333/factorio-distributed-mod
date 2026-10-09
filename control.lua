-- Коннектор клиента: принимает состояние мира от ядра и отдаёт ядру действия игрока.
-- Транспорт — своя команда `/fd <JSON>` по RCON. Не `/c` и не `/sc`: команды мода
-- не отключают достижения (проверено в factorio-partner 08.10.2026) и не дают
-- выполнять по RCON произвольный Lua-код.
-- Ответ — ровно одна строка через rcon.print.

local ops = {}

ops.ping = function()
  return "pong"
end

ops.tick = function()
  return game.tick
end

-- Ответ заданной длины: замер направления клиент → ядро.
ops.echo = function(msg)
  return string.rep("x", msg.n)
end

-- Пустая операция: поле pad несёт балласт, меряем только передачу и разбор JSON.
ops.noop = function()
  return game.tick
end

-- Замер RCON (TAR-166): сетка сундуков, которую ядро «перезаписывает» пачками.
-- Каждое обновление — [номер_сундука, сколько_железных_плит].
local function bench_clear(surface, side)
  for _, e in pairs(surface.find_entities{{0, 0}, {side, side}}) do
    if e.type ~= "character" then e.destroy() end
  end
end

-- Готовит прямоугольник под постройку: генерирует чанки, сносит всё, кроме персонажей,
-- засыпает воду.
local function prepare_area(surface, x0, y0, w, h)
  surface.request_to_generate_chunks({x0 + w / 2, y0 + h / 2}, math.ceil(math.max(w, h) / 64) + 1)
  surface.force_generate_chunk_requests()
  for _, e in pairs(surface.find_entities{{x0, y0}, {x0 + w, y0 + h}}) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = x0, x0 + w - 1 do
    for y = y0, y0 + h - 1 do
      tiles[#tiles + 1] = {name = "landfill", position = {x, y}}
    end
  end
  surface.set_tiles(tiles)
end

-- Создаёт n сундуков квадратом от (0, 0), на засыпанной земле.
ops.bench_setup = function(msg)
  local n = msg.n
  local surface = game.surfaces["nauvis"]
  local side = math.ceil(math.sqrt(n))
  bench_clear(surface, math.max(side, storage.bench_side or 0))
  prepare_area(surface, 0, 0, side, side)

  local inventories = {}
  for i = 0, n - 1 do
    local chest = surface.create_entity{
      name = "wooden-chest",
      position = {i % side + 0.5, math.floor(i / side) + 0.5},
      force = "player",
    }
    if not chest then error("bench_setup: не удалось поставить сундук " .. i) end
    inventories[i + 1] = chest.get_inventory(defines.inventory.chest)
  end
  storage.bench_side = side
  storage.bench_inventories = inventories
  return n
end

-- Применяет пачку обновлений к сундукам.
ops.bench_apply = function(msg)
  local inventories = storage.bench_inventories
  local updates = msg.u
  for i = 1, #updates do
    local u = updates[i]
    local inv = inventories[u[1]]
    inv.clear()
    if u[2] > 0 then inv.insert{name = "iron-plate", count = u[2]} end
  end
  return game.tick
end

-- То же, но без применения: меряет только передачу и разбор JSON.
ops.bench_parse = function()
  return game.tick
end

-- Замер заморозки (TAR-166, схема «окно вокруг игрока»): disabled_by_script.

-- Какие типы сущностей принимают disabled_by_script. Ставит по одной штуке каждого
-- типа в полосе y = -200 и возвращает {имя = {is_updatable, disabled после записи}}.
local PROBE = {
  "transport-belt", "underground-belt", "splitter", "inserter", "burner-inserter",
  "assembling-machine-2", "electric-mining-drill", "burner-mining-drill", "stone-furnace",
  "pipe", "storage-tank", "pump", "lab", "boiler", "steam-engine", "solar-panel",
  "accumulator", "small-electric-pole", "radar", "beacon", "wooden-chest", "roboport",
  "car", "small-lamp", "arithmetic-combinator", "gun-turret",
}

ops.fz_probe = function()
  local surface = game.surfaces["nauvis"]
  prepare_area(surface, 0, -200, #PROBE * 12, 12)
  local out = {}
  for k, name in ipairs(PROBE) do
    local ok, e = pcall(surface.create_entity, {
      name = name, position = {k * 12 - 6, -194}, force = "player",
      type = name == "underground-belt" and "input" or nil,
    })
    if not ok or not e then
      out[name] = "не поставилась"
    else
      local upd = e.is_updatable
      e.disabled_by_script = true
      out[name] = {upd, e.disabled_by_script, e.active}
    end
  end
  return helpers.table_to_json(out)
end

-- Сетка из n закольцованных конвейеров 2×2 (шаг 3 клетки) от (0, 300), заполненных плитами.
-- Кольца крутятся вечно и без электричества — честная нагрузка на движок конвейеров.
ops.fz_loops_setup = function(msg)
  local surface = game.surfaces["nauvis"]
  local per_row = math.ceil(math.sqrt(msg.n))
  local side = per_row * 3
  prepare_area(surface, 0, 300, side, side)
  local d = defines.direction
  local ring = {{0, 0, d.east}, {1, 0, d.south}, {1, 1, d.west}, {0, 1, d.north}}
  local belts, updatable = {}, 0
  for i = 0, msg.n - 1 do
    local bx, by = (i % per_row) * 3, 300 + math.floor(i / per_row) * 3
    for _, r in ipairs(ring) do
      local b = surface.create_entity{
        name = "transport-belt", position = {bx + r[1] + 0.5, by + r[2] + 0.5},
        direction = r[3], force = "player",
      }
      belts[#belts + 1] = b
      if b.is_updatable then updatable = updatable + 1 end
    end
  end
  -- Заполняем после постройки: у замкнутого кольца линии уже связаны.
  for _, b in ipairs(belts) do
    for lane = 1, 2 do
      local line = b.get_transport_line(lane)
      for _ = 1, 3 do
        if not line.insert_at_back({name = "iron-plate", count = 1}) then break end
      end
    end
  end
  storage.fz = {belts = belts, x1 = side, y1 = 300 + side}
  return helpers.table_to_json{belts = #belts, updatable = updatable}
end

-- Позиции предметов на первых трёх конвейерах — по двум снимкам видно, едут ли они.
ops.fz_snapshot = function()
  local parts = {}
  for k = 1, 3 do
    for lane = 1, 2 do
      for _, item in ipairs(storage.fz.belts[k].get_transport_line(lane).get_detailed_contents()) do
        parts[#parts + 1] = string.format("%.3f", item.position)
      end
    end
  end
  return table.concat(parts, ",")
end

-- Заморозить/разморозить все кольца repeat раз подряд (для замера цены одного переключения).
-- Возвращает, сколько конвейеров после последней записи читаются как disabled.
ops.fz_set = function(msg)
  local belts = storage.fz.belts
  local value = msg.disabled
  local rep = msg["repeat"] or 1
  for r = 1, rep do
    -- При нескольких повторах чередуем, чтобы каждая запись реально меняла состояние;
    -- последний повтор всегда ставит value.
    local v = value
    if (rep - r) % 2 == 1 then v = not value end
    for i = 1, #belts do belts[i].disabled_by_script = v end
  end
  local n = 0
  for i = 1, #belts do
    if belts[i].disabled_by_script then n = n + 1 end
  end
  return n
end

-- Сдвиг окна: найти конвейеры в полосе и переключить. Полоса — {x0, y0, x1, y1}.
-- repeat — для замера цены. Возвращает, сколько сущностей в полосе.
ops.fz_area_set = function(msg)
  local surface = game.surfaces["nauvis"]
  local found
  local rep = msg["repeat"] or 1
  for r = 1, rep do
    local v = msg.disabled
    if (rep - r) % 2 == 1 then v = not v end
    found = surface.find_entities_filtered{
      area = {{msg.x0, msg.y0}, {msg.x1, msg.y1}}, type = "transport-belt",
    }
    for i = 1, #found do found[i].disabled_by_script = v end
  end
  return #found
end

ops.fz_speed = function(msg)
  game.speed = msg.speed
  return game.speed
end

-- Сносит кольца (для замера UPS пустого мира).
ops.fz_clear = function()
  for _, b in ipairs(storage.fz and storage.fz.belts or {}) do
    if b.valid then b.destroy() end
  end
  storage.fz = nil
  return "ok"
end

-- Замер заполнения полосы при входе в окно: LuaTransportLine.insert_at.
-- Ряды прямых конвейеров по 32 клетки от (0, 1000), вплотную, через ряд.
ops.ins_setup = function(msg)
  local surface = game.surfaces["nauvis"]
  local rows = math.ceil(msg.n / 32)
  prepare_area(surface, 0, 1000, 32, rows * 2)
  local lines = {}
  for i = 0, msg.n - 1 do
    local b = surface.create_entity{
      name = "transport-belt", position = {i % 32 + 0.5, 1000 + math.floor(i / 32) * 2 + 0.5},
      direction = defines.direction.east, force = "player",
    }
    lines[#lines + 1] = b.get_transport_line(1)
    lines[#lines + 1] = b.get_transport_line(2)
  end
  storage.ins = lines
  return #lines
end

-- repeat раз: (если fill) поставить на каждую ленту 4 плиты через insert_at, затем clear.
-- Возвращает, сколько вставок удалось в последнем повторе.
ops.ins_fill = function(msg)
  local lines = storage.ins
  local plate = {name = "iron-plate", count = 1}
  local ok = 0
  for _ = 1, msg["repeat"] or 1 do
    ok = 0
    for i = 1, #lines do
      local line = lines[i]
      if msg.fill then
        local len = line.line_length
        for k = 1, 4 do
          if line.insert_at(len * (k - 0.5) / 4, plate) then ok = ok + 1 end
        end
      end
      line.clear()
    end
  end
  return ok
end

-- Замер клиент → ядро: синтетические «действия игрока».
-- Каждые every тиков мод создаёт per_tick событий; ядро забирает их опросом (poll)
-- или читает из файла script-output/fd-events.jsonl (mode = "file").
local EVENTS_FILE = "fd-events.jsonl"

ops.ev_start = function(msg)
  storage.ev = {every = msg.every, per_tick = msg.per_tick, mode = msg.mode, seq = 0, queue = {}}
  return "ok"
end

-- Останавливает генерацию, возвращает сколько событий создано всего.
ops.ev_stop = function()
  local seq = storage.ev and storage.ev.seq or 0
  storage.ev = nil
  return seq
end

-- Отдаёт накопленные события и текущий тик, очищает очередь.
ops.poll = function()
  local ev = storage.ev
  local queue = ev and ev.queue or {}
  if ev then ev.queue = {} end
  return helpers.table_to_json{now = game.tick, ev = queue}
end

script.on_event(defines.events.on_tick, function(e)
  local ev = storage.ev
  if not ev or e.tick % ev.every ~= 0 then return end
  local lines = ev.mode == "file" and {} or nil
  for j = 1, ev.per_tick do
    ev.seq = ev.seq + 1
    local item = {t = e.tick, i = ev.seq, a = "build", n = "assembling-machine-2", x = j, y = -j}
    if lines then
      lines[j] = helpers.table_to_json(item)
    else
      ev.queue[#ev.queue + 1] = item
    end
  end
  if lines then
    -- for_player = 0: пишет только сервер (у клиентов мультиплеера файла не будет).
    helpers.write_file(EVENTS_FILE, table.concat(lines, "\n") .. "\n", true, 0)
  end
end)

local function handle(cmd)
  -- Только сервер/RCON. Из чата игрока команда не работает.
  if cmd.player_index ~= nil then
    local p = game.get_player(cmd.player_index)
    if p then p.print("/fd — служебная команда ядра, из чата недоступна") end
    return
  end
  local ok, msg = pcall(helpers.json_to_table, cmd.parameter or "")
  if not ok or type(msg) ~= "table" then
    rcon.print("error: bad json")
    return
  end
  local op = ops[msg.op]
  if not op then
    rcon.print("error: unknown op")
    return
  end
  local okr, res = pcall(op, msg)
  if not okr then
    rcon.print("error: " .. tostring(res))
    return
  end
  rcon.print(res)
end

commands.add_command("fd", "Служебная команда ядра Factorio Distributed (только RCON)", handle)
