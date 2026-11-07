# mongo-sharding-repl — шардирование + репликация MongoDB (задание 3)

Состав стенда:

| Сервис | Роль | Порт |
|---|---|---|
| `configSrv` | config server (replica set `config_server`), метаданные кластера | 27017 |
| `shard1-1`, `shard1-2`, `shard1-3` | шард 1: replica set `shard1` из трёх узлов | 27018 |
| `shard2-1`, `shard2-2`, `shard2-3` | шард 2: replica set `shard2` из трёх узлов | 27019 |
| `mongos_router` | роутер, единая точка входа для приложения | 27020 |
| `pymongo_api` | приложение `kazhem/pymongo_api:1.0.0` | 8080 |

В каждом шарде один узел PRIMARY принимает запись, два SECONDARY держат копию данных. Если PRIMARY падает, оставшиеся два узла за несколько секунд выбирают нового, и приложение продолжает работать.

Коллекция `somedb.helloDoc` шардируется по ключу `{ name: "hashed" }`.

## Запуск

```shell
cd mongo-sharding-repl
docker compose up -d
./scripts/mongo-init.sh
```

Скрипт идемпотентный. В конце он печатает состояние каждой реплики и количество документов на ней, например:

```
    shard1-1 [PRIMARY]: 492 документов, реплик в наборе: 3
    shard1-2 [SECONDARY]: 492 документов, реплик в наборе: 3
    shard1-3 [SECONDARY]: 492 документов, реплик в наборе: 3
    shard2-1 [PRIMARY]: 508 документов, реплик в наборе: 3
    shard2-2 [SECONDARY]: 508 документов, реплик в наборе: 3
    shard2-3 [SECONDARY]: 508 документов, реплик в наборе: 3
```

## Что делает скрипт (шаги настройки вручную)

1. Инициализировать config server:

```shell
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate({ _id: "config_server", configsvr: true, members: [{ _id: 0, host: "configSrv:27017" }] })
EOF
```

2. Настроить репликацию для каждого шарда: объединить три узла в replica set. Команда выполняется на любом одном узле набора:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.initiate({ _id: "shard1", members: [
  { _id: 0, host: "shard1-1:27018", priority: 2 },
  { _id: 1, host: "shard1-2:27018" },
  { _id: 2, host: "shard1-3:27018" }
] })
EOF

docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.initiate({ _id: "shard2", members: [
  { _id: 0, host: "shard2-1:27019", priority: 2 },
  { _id: 1, host: "shard2-2:27019" },
  { _id: 2, host: "shard2-3:27019" }
] })
EOF
```

`priority: 2` у первого узла делает его предпочтительным PRIMARY. Без этого PRIMARY может стать любой из трёх.

3. Подождать 10–20 секунд, пока в наборах пройдут выборы PRIMARY (проверка: `rs.status()`). Затем добавить шарды в роутер, указав все реплики, и наполнить базу:

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { name: "hashed" })
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({ age: i, name: "ly" + i })
db.helloDoc.countDocuments()
EOF
```

## Проверка

Состояние реплик шарда 1:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.status().members.forEach(m => print(m.name, m.stateStr))
EOF
```

Количество документов на шарде (запрос к любой реплике):

```shell
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Приложение: http://localhost:8080. В JSON:
- `collections.helloDoc.documents_count`: всего документов (1000);
- `shards`: шарды и их реплики, например `"shard1": "shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018"` (по 3 реплики на шард).

## Остановка

```shell
docker compose down -v   # -v удаляет и данные
```
