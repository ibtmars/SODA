#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
NODE_COUNT="${NODE_COUNT:-4}"
RUN_SMOKE="${RUN_SMOKE:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
DATA_SOURCE_URL="${DATA_SOURCE_URL:-http://host.docker.internal:8080/}"
SINGLE_ORACLE_MODE="${SINGLE_ORACLE_MODE:-false}"
SINGLE_ORACLE_ID="${SINGLE_ORACLE_ID:-1020000033319542830000016401}"
MAX_ORACLE_NODES="${MAX_ORACLE_NODES:-32}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-cmd)
      COMPOSE_CMD="$2"
      shift 2
      ;;
    --node-count)
      NODE_COUNT="$2"
      shift 2
      ;;
    --run-smoke)
      RUN_SMOKE="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD="$2"
      shift 2
      ;;
    --data-source-url)
      DATA_SOURCE_URL="$2"
      shift 2
      ;;
    --single-oracle-mode)
      SINGLE_ORACLE_MODE="$2"
      shift 2
      ;;
    --single-oracle-id)
      SINGLE_ORACLE_ID="$2"
      shift 2
      ;;
    *)
      echo "[ERROR] unknown arg: $1"
      echo "Usage: $0 [--compose-cmd 'sudo docker compose'] [--node-count 4] [--run-smoke 1] [--skip-build 0] [--data-source-url http://host.docker.internal:8080/] [--single-oracle-mode true|false] [--single-oracle-id 102...6401]"
      exit 1
      ;;
  esac
done

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "[INFO] .env not found, created from .env.example"
fi

upsert_env() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

node_services() {
  local count="$1"
  if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 || count > MAX_ORACLE_NODES )); then
    echo "[ERROR] invalid node count: ${count} (supported: 1-${MAX_ORACLE_NODES})" >&2
    return 1
  fi
  local out=()
  local i
  for i in $(seq 1 "$count"); do
    out+=("oracle-node-$i")
  done
  printf '%s\n' "${out[@]}"
}

cleanup_legacy_scaled_oracle_nodes() {
  eval "$COMPOSE_CMD rm -f -s -v oracle-node >/dev/null 2>&1 || true"
}

cleanup_fixed_oracle_nodes() {
  local services=()
  local i
  for i in $(seq 1 "$MAX_ORACLE_NODES"); do
    services+=("oracle-node-$i")
  done
  eval "$COMPOSE_CMD rm -f -s -v ${services[*]} >/dev/null 2>&1 || true"
}

upsert_env NODE_REPLICA_COUNT "$NODE_COUNT"
upsert_env BENCHMARK_SINGLE_ORACLE_MODE "$SINGLE_ORACLE_MODE"
upsert_env BENCHMARK_SINGLE_ORACLE_ID "$SINGLE_ORACLE_ID"

echo "[INFO] compose command: $COMPOSE_CMD"
echo "[INFO] node count: $NODE_COUNT"
echo "[INFO] run smoke: $RUN_SMOKE"
echo "[INFO] skip build: $SKIP_BUILD"
echo "[INFO] single oracle mode: $SINGLE_ORACLE_MODE"
echo "[INFO] single oracle id: $SINGLE_ORACLE_ID"

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "[1/6] build images (adapter/node/vrf/contract/k6)"
  eval "$COMPOSE_CMD build oracle-adapter oracle-node vrf contract-deployer k6"
else
  echo "[1/6] skip image build"
fi

echo "[2/6] start base services"
eval "$COMPOSE_CMD up -d mysql zookeeper kafka ganache vrf"

echo "[3/6] deploy contracts + sync env + recreate adapter/node"
COMPOSE_CMD="$COMPOSE_CMD" NODE_REPLICA_COUNT="$NODE_COUNT" FORCE_RECREATE_APP_CONTAINERS=1 ./scripts/deploy-and-sync-contracts.sh

echo "[3.1/6] enforce oracle-node scale=${NODE_COUNT}"
mapfile -t NODE_SERVICES < <(node_services "$NODE_COUNT")
cleanup_legacy_scaled_oracle_nodes
eval "$COMPOSE_CMD up -d ${NODE_SERVICES[*]}"
eval "$COMPOSE_CMD ps ${NODE_SERVICES[*]}"

echo "[4/6] wait adapter endpoint"
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:15000/record/list" >/dev/null 2>&1; then
    echo "[INFO] adapter is ready"
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "[ERROR] adapter not ready after 120s"
    eval "$COMPOSE_CMD logs --since 5m oracle-adapter | tail -n 200"
    exit 1
  fi
  sleep 2
done

echo "[5/6] check ganache rpc"
RPC_RES=$(curl -s -X POST "http://127.0.0.1:7545" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
echo "[INFO] ganache rpc response: $RPC_RES"

if [[ "$RUN_SMOKE" == "1" ]]; then
  echo "[6/6] run smoke benchmark gate"
  python3 scripts/experiment_two.py \
    --compose-cmd "$COMPOSE_CMD" \
    --workspace . \
    --mode MNMS \
    --run-es-sweep \
    --node-count "$NODE_COUNT" \
    --es-values "1" \
    --data-source-url "$DATA_SOURCE_URL" \
    --smoke-only \
    --smoke-vus 1 \
    --smoke-http-timeout 20s \
    --smoke-settle-timeout 30 \
    --idle-timeout 90
else
  echo "[6/6] skip smoke benchmark"
fi

echo ""
echo "[DONE] full deploy finished"
echo "next:"
echo "  - check status: $COMPOSE_CMD ps"
echo "  - adapter health: curl -s http://127.0.0.1:15000/record/list"
echo "  - run benchmark: python3 scripts/snss_benchmark.py --compose-cmd '$COMPOSE_CMD' --workspace . --data-source-url '$DATA_SOURCE_URL'"
