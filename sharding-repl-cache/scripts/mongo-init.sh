#!/bin/bash
# Инициализация шардированного кластера MongoDB с репликацией и наполнение данными.
# Каждый шард — replica set из 3 узлов. Запуск: ./scripts/mongo-init.sh (после `docker compose up -d`)
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
# Ждём, пока в replica set узла будет выбран PRIMARY (любой из членов набора)
wait_primary() {
  for _ in $(seq 120); do
    primary=$(docker compose exec -T "$1" mongosh --port "$2" --quiet --eval 'db.hello().primary || ""' 2>/dev/null | tr -d '\r')
    if [ -n "$primary" ]; then
      echo "    replica set узла $1: PRIMARY = $primary"; return 0
    fi
    sleep 1
  done
  echo "ОШИБКА: в replica set узла $1 не выбран PRIMARY за 120 секунд" >&2; exit 1
}

echo "==> 1. Инициализация config server (replica set config_server)"
wait_ping configSrv 27017
docker compose exec -T configSrv mongosh --port 27017 --quiet <<JS
try { rs.status(); print("    уже инициализирован") } catch (e) {
  printjson(rs.initiate({ _id: "config_server", configsvr: true, members: [{ _id: 0, host: "configSrv:27017" }] }).ok)
}
JS

echo "==> 2. Инициализация replica set shard1 (shard1-1, shard1-2, shard1-3)"
for n in 1 2 3; do wait_ping shard1-$n 27018; done
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<JS
try { rs.status(); print("    уже инициализирован") } catch (e) {
  printjson(rs.initiate({ _id: "shard1", members: [
    { _id: 0, host: "shard1-1:27018", priority: 2 },
    { _id: 1, host: "shard1-2:27018" },
    { _id: 2, host: "shard1-3:27018" }
  ] }).ok)
}
JS

echo "==> 3. Инициализация replica set shard2 (shard2-1, shard2-2, shard2-3)"
for n in 1 2 3; do wait_ping shard2-$n 27019; done
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<JS
try { rs.status(); print("    уже инициализирован") } catch (e) {
  printjson(rs.initiate({ _id: "shard2", members: [
    { _id: 0, host: "shard2-1:27019", priority: 2 },
    { _id: 1, host: "shard2-2:27019" },
    { _id: 2, host: "shard2-3:27019" }
  ] }).ok)
}
JS

echo "==> 4. Ожидание выбора PRIMARY"
wait_primary configSrv 27017
wait_primary shard1-1 27018
wait_primary shard2-1 27019

echo "==> 5. Регистрация шардов в роутере, шардирование somedb.helloDoc, наполнение данными"
wait_ping mongos_router 27020
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<JS
(() => {
  sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
  sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019")
  sh.enableSharding("somedb")
  sh.shardCollection("somedb.helloDoc", { name: "hashed" })
  const coll = db.getSiblingDB("somedb").helloDoc
  if (coll.countDocuments() === 0) {
    const docs = []
    for (let i = 0; i < 1000; i++) docs.push({ age: i, name: "ly" + i })
    coll.insertMany(docs, { writeConcern: { w: "majority" } })
  }
  print("    Всего документов (через mongos): " + coll.countDocuments())
})()
JS

echo "==> 6. Состояние реплик и количество документов на каждом узле"
for pair in shard1-1:27018 shard1-2:27018 shard1-3:27018 shard2-1:27019 shard2-2:27019 shard2-3:27019; do
  svc=${pair%%:*}; port=${pair##*:}
  docker compose exec -T "$svc" mongosh --port "$port" --quiet --eval '
    db.getMongo().setReadPref("primaryPreferred");
    const st = rs.status().members.find(m => m.self).stateStr;
    print("    '"$svc"' [" + st + "]: " + db.getSiblingDB("somedb").helloDoc.countDocuments() + " документов, реплик в наборе: " + rs.conf().members.length)'
done
