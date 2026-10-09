# factorio-distributed-mod

Клиентский мод-коннектор проекта Factorio Distributed.

Локальный Factorio запускается как сервер и только **рисует** мир. Сам мир считает внешнее ядро
([factorio-distributed-core](https://github.com/Fatoom333/factorio-distributed-core)), которое управляет клиентом через RCON — своей командой мода `/fd <JSON>` (не `/c`: команды мода не отключают достижения и не выполняют произвольный Lua).

Задачи мода:
- принимать изменения мира от ядра и применять их к сущностям;
- передавать ядру действия игрока;
- не давать собственной симуляции Factorio «спорить» с ядром.

Статус: замеры перед проектированием. Команда `/fd` (только от сервера/RCON) умеет `ping`, `tick` и операции замеров — см. [factorio-distributed-core/bench](https://github.com/Fatoom333/factorio-distributed-core/tree/main/bench).

## Лицензия

Apache-2.0, см. [LICENSE](LICENSE). Автор — Tartaluga; при распространении копий и переделок файл [NOTICE](NOTICE) нужно сохранять.
