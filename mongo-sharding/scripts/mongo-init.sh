#!/bin/bash
# Инициализация шардированного кластера MongoDB и наполнение данными.
# Запуск: ./scripts/mongo-init.sh (после `docker compose up -d`)
set -e
cd "$(dirname "$0")/.."

# Ждём, пока mongod/mongos начнёт принимать подключения
# (не дольше 120 секунд, иначе — ошибка с подсказкой)
wait_ping() {
  for _ in $(seq 120); do
    docker compose exec -T "$1" mongosh --port "$2" --quiet --eval 'db.adminCommand("ping").ok' 2>/dev/null | grep -q 1 && return 0
    sleep 1
  done
  echo "ОШИБКА: $1:$2 не отвечает. Проверьте 'docker compose ps' и 'docker compose logs $1'" >&2; exit 1
}
# Ждём, пока узел станет PRIMARY своего replica set
wait_primary() {
  for _ in $(seq 120); do
    if docker compose exec -T "$1" mongosh --port "$2" --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
      echo "    $1: PRIMARY"; return 0
    fi
    sleep 1
  done
  echo "ОШИБКА: $1 не стал PRIMARY за 120 секунд" >&2; exit 1
}

echo "==> 1. Инициализация config server (replica set config_server)"
wait_ping configSrv 27017
docker compose exec -T configSrv mongosh --port 27017 --quiet <<JS
try { rs.status(); print("    уже инициализирован") } catch (e) {
  printjson(rs.initiate({ _id: "config_server", configsvr: true, members: [{ _id: 0, host: "configSrv:27017" }] }).ok)
}
JS

echo "==> 2. Инициализация шарда shard1 (replica set shard1)"
wait_ping shard1 27018
docker compose exec -T shard1 mongosh --port 27018 --quiet <<JS
try { rs.status(); print("    уже инициализирован") } catch (e) {
  printjson(rs.initiate({ _id: "shard1", members: [{ _id: 0, host: "shard1:27018" }] }).ok)
}
JS

echo "==> 3. Инициализация шарда shard2 (replica set shard2)"
wait_ping shard2 27019
docker compose exec -T shard2 mongosh --port 27019 --quiet <<JS
try { rs.status(); print("    уже инициализирован") } catch (e) {
  printjson(rs.initiate({ _id: "shard2", members: [{ _id: 0, host: "shard2:27019" }] }).ok)
}
JS

echo "==> 4. Ожидание PRIMARY"
wait_primary configSrv 27017
wait_primary shard1 27018
wait_primary shard2 27019

echo "==> 5. Регистрация шардов в роутере, шардирование somedb.helloDoc, наполнение данными"
wait_ping mongos_router 27020
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<JS
(() => {
  sh.addShard("shard1/shard1:27018")
  sh.addShard("shard2/shard2:27019")
  sh.enableSharding("somedb")
  sh.shardCollection("somedb.helloDoc", { name: "hashed" })
  const coll = db.getSiblingDB("somedb").helloDoc
  if (coll.countDocuments() === 0) {
    const docs = []
    for (let i = 0; i < 1000; i++) docs.push({ age: i, name: "ly" + i })
    coll.insertMany(docs)
  }
  print("    Всего документов (через mongos): " + coll.countDocuments())
})()
JS

echo "==> 6. Документов на каждом шарде"
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval 'print("    shard1: " + db.getSiblingDB("somedb").helloDoc.countDocuments())'
docker compose exec -T shard2 mongosh --port 27019 --quiet --eval 'print("    shard2: " + db.getSiblingDB("somedb").helloDoc.countDocuments())'
