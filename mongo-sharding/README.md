# mongo-sharding — шардирование MongoDB (задание 2)

Состав стенда:

| Сервис | Роль | Порт |
|---|---|---|
| `configSrv` | config server (replica set `config_server`), хранит метаданные кластера | 27017 |
| `shard1` | шард 1 (replica set `shard1` из одного узла) | 27018 |
| `shard2` | шард 2 (replica set `shard2` из одного узла) | 27019 |
| `mongos_router` | роутер, единая точка входа для приложения | 27020 |
| `pymongo_api` | приложение `kazhem/pymongo_api:1.0.0` | 8080 |

Коллекция `somedb.helloDoc` шардируется по хешированному ключу `{ name: "hashed" }`, поэтому документы распределяются между шардами примерно поровну.

## Запуск

```shell
cd mongo-sharding
docker compose up -d
./scripts/mongo-init.sh
```

Скрипт идемпотентный: повторный запуск ничего не сломает. В конце он печатает количество документов всего и на каждом шарде, например:

```
    Всего документов (через mongos): 1000
    shard1: 492
    shard2: 508
```

## Что делает скрипт (шаги инициализации вручную)

1. Инициализировать replica set config server:

```shell
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate({ _id: "config_server", configsvr: true, members: [{ _id: 0, host: "configSrv:27017" }] })
EOF
```

2. Инициализировать шарды. В MongoDB каждый шард обязан быть replica set, здесь он из одного узла:

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate({ _id: "shard1", members: [{ _id: 0, host: "shard1:27018" }] })
EOF

docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate({ _id: "shard2", members: [{ _id: 0, host: "shard2:27019" }] })
EOF
```

3. Подождать несколько секунд, пока узлы станут PRIMARY, затем добавить шарды в роутер, включить шардирование и наполнить базу:

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1:27018")
sh.addShard("shard2/shard2:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { name: "hashed" })
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({ age: i, name: "ly" + i })
db.helloDoc.countDocuments()
EOF
```

## Проверка

Количество документов на каждом шарде:

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Приложение: http://localhost:8080. В JSON видно `"mongo_topology_type": "Sharded"`, общее число документов `collections.helloDoc.documents_count` (1000) и список шардов в поле `shards`.

## Остановка

```shell
docker compose down -v   # -v удаляет и данные
```
