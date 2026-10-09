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
