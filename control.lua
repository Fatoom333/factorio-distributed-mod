-- Коннектор клиента: принимает состояние мира от ядра (через RCON /c ...)
-- и отдаёт ядру действия игрока.
-- Пока заготовка: интерфейс для вызова из RCON.

remote.add_interface("factorio_distributed", {
  -- Проверка связи: /c remote.call("factorio_distributed", "ping")
  ping = function()
    rcon.print("pong")
  end,
})
