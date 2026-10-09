# factorio-distributed-mod

Клиентский мод-коннектор проекта Factorio Distributed.

Локальный Factorio запускается как сервер и только **рисует** мир. Сам мир считает внешнее ядро
([factorio-distributed-core](https://github.com/Fatoom333/factorio-distributed-core)), которое управляет клиентом через RCON (`/c` + Lua).

Задачи мода:
- принимать изменения мира от ядра и применять их к сущностям;
- передавать ядру действия игрока;
- не давать собственной симуляции Factorio «спорить» с ядром.

Статус: заготовка. Есть только `remote`-интерфейс `factorio_distributed.ping` для проверки связи по RCON.

## Лицензия

MIT, см. [LICENSE](LICENSE).
