#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
read -r -a COMPOSE_PARTS <<< "$COMPOSE_CMD"
SKIP_ADAPTER_BUILD_WHEN_RUNNING="${SKIP_ADAPTER_BUILD_WHEN_RUNNING:-1}"
FORCE_RECREATE_APP_CONTAINERS="${FORCE_RECREATE_APP_CONTAINERS:-0}"
MAX_ORACLE_NODES="${MAX_ORACLE_NODES:-32}"

compose() {
  "${COMPOSE_PARTS[@]}" "$@"
}

node_services() {
  local count="$1"
  if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 || count > MAX_ORACLE_NODES )); then
    echo "[ERROR] invalid node count: ${count} (supported: 1-${MAX_ORACLE_NODES})" >&2
    return 1
  fi
  local i
  for i in $(seq 1 "$count"); do
    echo "oracle-node-$i"
  done
}

cleanup_legacy_scaled_oracle_nodes() {
  local names=()
  mapfile -t names < <(compose ps -a --format json oracle-node 2>/dev/null | sed -n 's/.*"Name":"\([^"]*\)".*/\1/p')
  if [[ ${#names[@]} -eq 0 ]]; then
    return 0
  fi
  echo "[INFO] removing legacy scaled oracle-node containers: ${names[*]}"
  compose rm -f -s -v oracle-node >/dev/null 2>&1 || true
}

cleanup_fixed_oracle_nodes() {
  local services=()
  local i
  for i in $(seq 1 "$MAX_ORACLE_NODES"); do
    services+=("oracle-node-$i")
  done
  compose rm -f -s -v "${services[@]}" >/dev/null 2>&1 || true
}

repair_oracle_id_alignment() {
  echo "[INFO] repairing oracle id alignment to match running node containers"
  python3 ./scripts/repair_oracle_id_alignment.py \
    --compose-cmd "$COMPOSE_CMD" \
    --workspace .
}

service_running() {
  local svc="$1"
  compose ps --status running --services "$svc" 2>/dev/null | grep -qx "$svc"
}

mkdir -p runtime logs

if [[ ! -f .env ]]; then
  cp .env.example .env
fi

source .env

BASE_CONFIG="${CONTRACT_CONFIG_FILE:-../../ContractAutoDeploy/config-eth.yml}"
RUNTIME_CONFIG="./runtime/config-runtime.yml"

if [[ ! -f "$BASE_CONFIG" ]]; then
  echo "[ERROR] 未找到合约配置文件: $BASE_CONFIG"
  exit 1
fi

if [[ "$BASE_CONFIG" == "$RUNTIME_CONFIG" ]]; then
  echo "[INFO] BASE_CONFIG 与 RUNTIME_CONFIG 相同，跳过复制: $BASE_CONFIG"
else
  cp "$BASE_CONFIG" "$RUNTIME_CONFIG"
fi

# 优先使用 ganache 容器 IP，完全绕过服务名 DNS 与 host-gateway 差异。
GANACHE_IP="$(compose exec -T ganache sh -lc "hostname -i | cut -d' ' -f1" 2>/dev/null | tr -d '\r' | head -n1)"
if [[ -n "${GANACHE_IP}" ]]; then
  RUNTIME_NODE_ADDRESS="http://${GANACHE_IP}:${GANACHE_PORT}"
else
  # 回退到 host-gateway（若当前环境不支持 exec 探测）
  RUNTIME_NODE_ADDRESS="http://host.docker.internal:${GANACHE_PORT}"
fi
if grep -qE '^nodeAddress:' "$RUNTIME_CONFIG"; then
  sed -i "s|^nodeAddress:.*|nodeAddress: \"${RUNTIME_NODE_ADDRESS}\"|" "$RUNTIME_CONFIG"
else
  echo "nodeAddress: \"${RUNTIME_NODE_ADDRESS}\"" >> "$RUNTIME_CONFIG"
fi
echo "[INFO] runtime nodeAddress 已设置为: ${RUNTIME_NODE_ADDRESS}"

# 统一部署私钥，避免使用到历史无余额账户导致合约部署失败。
DEPLOYER_PRIVATE_KEY="${CONTRACT_DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
if grep -qE '^privateKey:' "$RUNTIME_CONFIG"; then
  sed -i "s|^privateKey:.*|privateKey: \"${DEPLOYER_PRIVATE_KEY}\"|" "$RUNTIME_CONFIG"
else
  echo "privateKey: \"${DEPLOYER_PRIVATE_KEY}\"" >> "$RUNTIME_CONFIG"
fi
echo "[INFO] runtime deployer privateKey 已设置"

upsert_env() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

extract_addr() {
  local text="$1"
  local name="$2"
  echo "$text" | sed -n "s/.*Contract ${name} Deployed: \(0x[a-fA-F0-9]\{40\}\).*/\1/p" | tail -n 1
}

echo "[1/5] 启动基础链路（ganache/kafka/mysql）"
compose up -d mysql zookeeper kafka ganache

echo "[1.1/5] 等待 MySQL 就绪并初始化数据库"
MYSQL_WAIT_MAX_TRIES="${MYSQL_WAIT_MAX_TRIES:-60}"
mysql_try=0
until false; do
  mysql_try=$((mysql_try + 1))
  mysql_ping_out=""
  if mysql_ping_out=$(timeout 8s "${COMPOSE_PARTS[@]}" exec -T mysql mysqladmin ping -h 127.0.0.1 -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>&1); then
    break
  fi
  if (( mysql_try == 1 )) && echo "$mysql_ping_out" | grep -qiE 'permission denied|cannot connect to the docker daemon|docker.sock|no configuration file provided|unknown shorthand flag'; then
    echo "[ERROR] 执行 mysql 健康检查失败（非 MySQL 未就绪）:"
    echo "        $mysql_ping_out"
    echo "[HINT] 请确认 docker compose 命令可用并有权限。"
    echo "[HINT] 可用示例: COMPOSE_CMD=\"sudo docker compose --env-file .env\" bash scripts/deploy-and-sync-contracts.sh"
    exit 1
  fi
  if (( mysql_try >= MYSQL_WAIT_MAX_TRIES )); then
    echo "[ERROR] MySQL 在 ${MYSQL_WAIT_MAX_TRIES} 次尝试后仍未就绪，退出"
    exit 1
  fi
  echo "[INFO] waiting mysql... (${mysql_try}/${MYSQL_WAIT_MAX_TRIES})"
  sleep 2
done

NODE_COUNT="${NODE_REPLICA_COUNT:-4}"
SQLS="CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE};"
for i in $(seq 1 "$NODE_COUNT"); do
  SQLS+=" CREATE DATABASE IF NOT EXISTS oracle_node_${i};"
done
compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "$SQLS"

DUMP_FILE="../../OracleAdapter/database-dump.sql"
if [[ ! -f "$DUMP_FILE" ]]; then
  echo "[ERROR] 未找到数据库初始化文件: $DUMP_FILE"
  exit 1
fi

seed_if_missing() {
  local db="$1"
  local has_table
  has_table=$(compose exec -T mysql mysql -N -s -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_name='entity_node';")
  if [[ "$has_table" == "0" ]]; then
    echo "[INFO] 数据库 ${db} 缺少表结构，导入初始化SQL"
     compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "$db" < "$DUMP_FILE"
  else
    echo "[INFO] 数据库 ${db} 已存在表结构，跳过导入"
  fi
}

seed_if_missing "${MYSQL_DATABASE}"
for i in $(seq 1 "$NODE_COUNT"); do
  seed_if_missing "oracle_node_${i}"
done

echo "[2/5] 使用 runtime 配置部署主合约(deploy all)"
ALL_LOG="logs/deploy-all-$(date +%Y%m%d-%H%M%S).log"
ALL_OUT=$(CONTRACT_CONFIG_FILE="$RUNTIME_CONFIG" compose run --rm contract-deployer deploy all 2>&1 | tee "$ALL_LOG")

ENTITY=$(extract_addr "$ALL_OUT" "EntityManager")
REP=$(extract_addr "$ALL_OUT" "RepManager")
REQ=$(extract_addr "$ALL_OUT" "RequestManager")
PROXY=$(extract_addr "$ALL_OUT" "OracleServiceProxy")
EVI=$(extract_addr "$ALL_OUT" "EvidenceManager")

for v in ENTITY REP REQ PROXY EVI; do
  if [[ -z "${!v}" ]]; then
    echo "[ERROR] 从 deploy all 日志解析地址失败: $v"
    echo "日志文件: $ALL_LOG"
    exit 1
  fi
done

sed -i "s|^entityManagerAddress:.*|entityManagerAddress: \"$ENTITY\"|" "$RUNTIME_CONFIG"
sed -i "s|^repManagerAddress:.*|repManagerAddress: \"$REP\"|" "$RUNTIME_CONFIG"
sed -i "s|^requestManagerAddress:.*|requestManagerAddress: \"$REQ\"|" "$RUNTIME_CONFIG"
sed -i "s|^oracleProxyAddress:.*|oracleProxyAddress: \"$PROXY\"|" "$RUNTIME_CONFIG"

echo "[3/5] 部署 RequestTest 合约(deploy req-test)"
REQTEST_LOG="logs/deploy-reqtest-$(date +%Y%m%d-%H%M%S).log"
REQTEST_OUT=$(CONTRACT_CONFIG_FILE="$RUNTIME_CONFIG" compose run --rm contract-deployer deploy req-test 2>&1 | tee "$REQTEST_LOG")
REQ_TEST=$(extract_addr "$REQTEST_OUT" "RequestTest")
if [[ -z "$REQ_TEST" ]]; then
  echo "[ERROR] 从 deploy req-test 日志解析 RequestTest 地址失败"
  echo "日志文件: $REQTEST_LOG"
  exit 1
fi

echo "[4/5] 回填 .env 合约地址"
upsert_env CHAIN_CONTRACT_ENTITY_MANAGER "$ENTITY"
upsert_env CHAIN_CONTRACT_REPUTATION_MANAGER "$REP"
upsert_env CHAIN_CONTRACT_REQUEST_MANAGER "$REQ"
upsert_env CHAIN_CONTRACT_ORACLE_PROXY "$PROXY"
upsert_env CHAIN_CONTRACT_CROSS_CHAIN_EVIDENCE "$EVI"
upsert_env CHAIN_CONTRACT_REQUEST_TEST "$REQ_TEST"

echo "[4.1/5] 校验链上合约代码是否存在"
check_code() {
  local name="$1"
  local addr="$2"
  local resp
  local code
  resp=$(curl -s -X POST "http://127.0.0.1:${GANACHE_PORT}" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"${addr}\",\"latest\"],\"id\":1}")
  code=$(echo "$resp" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
  if [[ -z "$code" || "$code" == "0x" ]]; then
    echo "[ERROR] ${name} 地址无合约代码: ${addr}"
    echo "[ERROR] RPC返回: ${resp}"
    exit 1
  fi
  echo "[INFO] ${name} 合约代码校验通过: ${addr}"
}

check_code "RequestTest" "$REQ_TEST"
check_code "RequestManager" "$REQ"
check_code "OracleProxy" "$PROXY"


if [[ "$SKIP_ADAPTER_BUILD_WHEN_RUNNING" == "1" ]] && service_running "oracle-adapter"; then
  echo "[4.2/5] oracle-adapter 已在运行，跳过镜像重建"
else
  echo "[4.2/5] 构建 oracle-adapter 镜像"
  compose build oracle-adapter
fi

echo "[5/5] 使 adapter 与 node 生效新地址"
mapfile -t NODE_SERVICES < <(node_services "${NODE_REPLICA_COUNT:-4}")
cleanup_legacy_scaled_oracle_nodes
if [[ "$FORCE_RECREATE_APP_CONTAINERS" == "1" ]]; then
  echo "[INFO] FORCE_RECREATE_APP_CONTAINERS=1，强制重建 adapter/node 容器"
  compose up -d --force-recreate oracle-adapter
  compose up -d --force-recreate "${NODE_SERVICES[@]}"
else
  echo "[INFO] 默认按需更新（不强制重建）"
  compose up -d oracle-adapter
  compose up -d "${NODE_SERVICES[@]}"
fi

repair_oracle_id_alignment

echo "[5.1/5] 校验 adapter 容器内生效地址"
for key in \
  CHAIN_CONTRACT_ENTITY_MANAGER \
  CHAIN_CONTRACT_REPUTATION_MANAGER \
  CHAIN_CONTRACT_REQUEST_MANAGER \
  CHAIN_CONTRACT_ORACLE_PROXY \
  CHAIN_CONTRACT_CROSS_CHAIN_EVIDENCE \
  CHAIN_CONTRACT_REQUEST_TEST; do
  container_val=$(compose exec -T oracle-adapter sh -lc "printenv '$key' || true" 2>/dev/null | tr -d '\r')
  file_val=$(grep -E "^${key}=" .env | head -n1 | cut -d'=' -f2-)
  if [[ -z "$container_val" ]]; then
    echo "[ERROR] adapter 容器内缺少环境变量: $key"
    exit 1
  fi
  if [[ "$container_val" != "$file_val" ]]; then
    echo "[ERROR] adapter 容器环境变量与 .env 不一致: $key"
    echo "[ERROR] container=$container_val"
    echo "[ERROR] .env=$file_val"
    exit 1
  fi
done
echo "[INFO] adapter 容器合约地址与 .env 一致"

echo "==== 合约地址同步完成 ===="
echo "ENTITY_MANAGER=$ENTITY"
echo "REPUTATION_MANAGER=$REP"
echo "REQUEST_MANAGER=$REQ"
echo "ORACLE_PROXY=$PROXY"
echo "CROSS_CHAIN_EVIDENCE=$EVI"
echo "REQUEST_TEST=$REQ_TEST"
echo "已写入: deploy/docker-lab/.env"
