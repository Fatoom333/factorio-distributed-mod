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

-- Создаёт n сундуков квадратом от (0, 0), на засыпанной земле.
ops.bench_setup = function(msg)
  local n = msg.n
  local surface = game.surfaces["nauvis"]
  local side = math.ceil(math.sqrt(n))
  bench_clear(surface, math.max(side, storage.bench_side or 0))

  surface.request_to_generate_chunks({side / 2, side / 2}, math.ceil(side / 64) + 1)
  surface.force_generate_chunk_requests()
  bench_clear(surface, side)

  local tiles = {}
  for x = 0, side - 1 do
    for y = 0, side - 1 do
      tiles[#tiles + 1] = {name = "landfill", position = {x, y}}
    end
  end
  surface.set_tiles(tiles)

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
