#!/usr/bin/env bash
# CPA Stack 启动编排（ModelScope Docker Studio）
#
# 单容器三进程 + 一个入口：
#   CLIProxyAPI  127.0.0.1:8317   推理网关（凭据与配置来自 Studio Secret）
#   Oh My CPA    127.0.0.1:18901  控制台，挂 /omc
#   Caddy        0.0.0.0:7860     唯一公网入口，分流 + 请求头净化
#
# 持久化布局（/mnt/workspace/cpa-stack 在 Studio 持久盘，跨重启保留）：
#   cpa/config.yaml          由 CPA_CONFIG_B64 解码落盘（0600）
#   cpa/auth/*.json          由 CPA_AUTHS_B64 解包（33 个 OAuth 凭据）
#   cpa/plugins/linux/amd64/ 插件 .so 从镜像复制（CPA 需在同目录写 state）
#   omc/data.snapshot.sqlite OMC 库的持久快照
#
# OMC 的活动 SQLite 跑在容器本地 /tmp（OSSFS 上 WAL 会页级损坏），
# 每 60 秒做一次 quick_check 校验的快照落持久盘，启动时按校验结果恢复。
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/mnt/workspace/cpa-stack}"
CPA_DATA_DIR="${DATA_ROOT}/cpa"
CPA_CONFIG="${CPA_DATA_DIR}/config.yaml"
CPA_PLUGINS="${CPA_DATA_DIR}/plugins"
CPA_AUTH_DIR="${CPA_DATA_DIR}/auth"
IMAGE_PLUGINS="/opt/cpa-stack/plugins"

OMC_RUNTIME_DIR="/tmp/oh-my-cpa"
OMC_DATA_DIR="${OMC_RUNTIME_DIR}/data"
OMC_SNAPSHOT="${DATA_ROOT}/omc/data.snapshot.sqlite"

CPA_HEALTH="http://127.0.0.1:8317/healthz"
OMC_HEALTH="http://127.0.0.1:18901${OMC_BASE_PATH:-/}api/healthz"
CADDY_HEALTH="http://127.0.0.1:7860/healthz"

require_secret() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    printf '%s must be configured as a ModelScope Studio Secret.\n' "${name}" >&2
    exit 1
  fi
}

# ModelScope Studio Secret 单值上限 4096 字符（实测报错：
# "value exceeds maximum length of 4096 characters"），因此大 payload
# 必须拆成多个分块 Secret。本函数先取单块 BASE 变量，否则按
# BASE_PART1..PARTN 顺序拼接，两种形态都兼容。
assemble_b64() {
  local base="$1" acc="" idx=1 part
  if [[ -n "${!base:-}" ]]; then
    printf '%s' "${!base}"
    return 0
  fi
  while true; do
    part="${base}_PART${idx}"
    if [[ -z "${!part:-}" ]]; then
      break
    fi
    acc+="${!part}"
    idx=$((idx + 1))
  done
  if [[ -z "${acc}" ]]; then
    printf 'neither %s nor %s_PART<N> is configured.\n' "${base}" "${base}" >&2
    exit 1
  fi
  printf '%s' "${acc}"
}

# 两种运行模式（按 PGSTORE_DSN 是否存在自动判定）：
#   PGStore 模式：配置与 OAuth 凭据的唯一事实源是在线 PostgreSQL。
#     Studio Secret 只需 CPA_MANAGEMENT_KEY + OMCPA_MASTER_KEY + PGSTORE_DSN。
#   本地模式：配置与凭据经 base64 Secret 灌入持久盘（可分块）。
PGSTORE_MODE=0
if [[ -n "${PGSTORE_DSN:-}" ]]; then
  PGSTORE_MODE=1
  # 本地 spool（库的镜像工作区）放持久盘，跨重启保留
  export PGSTORE_LOCAL_PATH="${PGSTORE_LOCAL_PATH:-${DATA_ROOT}}"
fi

require_secret CPA_MANAGEMENT_KEY
require_secret OMCPA_MASTER_KEY

CPA_CONFIG_B64=""
CPA_AUTHS_B64=""
if [[ "${PGSTORE_MODE}" == "0" ]]; then
  CPA_CONFIG_B64="$(assemble_b64 CPA_CONFIG_B64)"
  CPA_AUTHS_B64="$(assemble_b64 CPA_AUTHS_B64)"
fi

mkdir -p "${CPA_DATA_DIR}" "${CPA_AUTH_DIR}" "${CPA_PLUGINS}/linux/amd64" \
         "${OMC_RUNTIME_DIR}" "${OMC_DATA_DIR}" "${DATA_ROOT}/omc"

# ---------- 一次性初始化（新数据根只做一次，之后尊重运行期改动） ----------
if [[ "${PGSTORE_MODE}" == "1" ]]; then
  # CPA 启动时从库引导 config.yaml、并 RemoveAll 后按库重建 auth 目录，
  # 此处只做提示；数据由迁移脚本预灌在库里。
  printf 'PGStore mode: online PostgreSQL is the source of truth (spool: %s/pgstore).\n' "${PGSTORE_LOCAL_PATH}"
else
  if [[ ! -s "${CPA_CONFIG}" ]]; then
    printf '%s' "${CPA_CONFIG_B64}" | base64 -d >"${CPA_CONFIG}"
    chmod 0600 "${CPA_CONFIG}"
    printf 'Initialized CPA configuration from Studio Secret.\n'
  fi

  if [[ -z "$(ls -A "${CPA_AUTH_DIR}" 2>/dev/null)" ]]; then
    printf '%s' "${CPA_AUTHS_B64}" | base64 -d | tar xzf - -C "${CPA_AUTH_DIR}"
    chmod 0600 "${CPA_AUTH_DIR}"/*.json 2>/dev/null || true
    printf 'Unpacked %d OAuth credential files.\n' "$(ls -1 "${CPA_AUTH_DIR}"/*.json 2>/dev/null | wc -l)"
  fi
fi

PLUGIN_SO="${CPA_PLUGINS}/linux/amd64/codexcomp-v0.1.7.so"
if [[ ! -s "${PLUGIN_SO}" ]]; then
  cp -a "${IMAGE_PLUGINS}/linux/amd64/." "${CPA_PLUGINS}/linux/amd64/"
  printf 'Installed plugins from image into the persistent plugin directory.\n'
fi

# ---------- OMC 数据库：恢复 / 快照 ----------
restore_omc_db() {
  local check
  [[ -s "${OMC_SNAPSHOT}" ]] || return 0
  check="$(sqlite3 "${OMC_SNAPSHOT}" 'PRAGMA quick_check;' 2>/dev/null || true)"
  if [[ "${check}" == "ok" ]]; then
    install -m 0600 "${OMC_SNAPSHOT}" "${OMC_DATA_DIR}/oh-my-cpa.db"
    printf 'Restored the latest verified OMC snapshot.\n'
  else
    printf 'Skipped an invalid OMC snapshot; starting with a fresh database.\n' >&2
  fi
}

snapshot_omc_db() {
  local db="${OMC_DATA_DIR}/oh-my-cpa.db"
  local tmp="${OMC_RUNTIME_DIR}/snapshot.tmp"
  local check
  [[ -s "${db}" ]] || return 0
  rm -f "${tmp}"
  if ! sqlite3 "${db}" ".timeout 5000" ".backup '${tmp}'" 2>/dev/null; then
    rm -f "${tmp}"
    return 0
  fi
  check="$(sqlite3 "${tmp}" 'PRAGMA quick_check;' 2>/dev/null || true)"
  if [[ "${check}" != "ok" ]]; then
    rm -f "${tmp}"
    return 0
  fi
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${OMC_SNAPSHOT}.new"
  mv -f "${OMC_SNAPSHOT}.new" "${OMC_SNAPSHOT}"
}

snapshot_loop() {
  while sleep 60; do
    snapshot_omc_db || true
  done
}

wait_for_service() {
  local name="$1" url="$2" pid="$3" attempts="$4"
  local _
  for _ in $(seq 1 "${attempts}"); do
    if curl -fsS --max-time 3 "${url}" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      printf '%s exited before becoming healthy.\n' "${name}" >&2
      return 1
    fi
    sleep 1
  done
  printf '%s did not become healthy in time.\n' "${name}" >&2
  return 1
}

restore_omc_db

# ---------- 启动 CPA ----------
# 管理口令由 config.yaml 的 bcrypt secret-key 承担；此处显式置位以便
# 远程管理在容器内按本地凭据放行，启动后随即从环境移除。
export MANAGEMENT_PASSWORD="${CPA_MANAGEMENT_KEY}"

cpa_pid=""
omc_pid=""
caddy_pid=""
snapshot_pid=""

cleanup() {
  local pid
  if [[ -n "${snapshot_pid}" ]]; then
    kill "${snapshot_pid}" 2>/dev/null || true
    wait "${snapshot_pid}" 2>/dev/null || true
  fi
  snapshot_omc_db || true
  for pid in "${caddy_pid}" "${omc_pid}" "${cpa_pid}"; do
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

/app/cli-proxy-api --config "${CPA_CONFIG}" &
cpa_pid=$!
unset MANAGEMENT_PASSWORD
wait_for_service "CLIProxyAPI" "${CPA_HEALTH}" "${cpa_pid}" 300

# ---------- 启动 Oh My CPA ----------
# 8080 在 ModelScope 创空间里被平台自带的 dashboard 占用（无论绑
# 0.0.0.0 还是 127.0.0.1 都报 "address already in use"），因此 OMC
# 改用 18901；公网访问由 Caddy 在 7860 转发。
export OMCPA_LISTEN_ADDR="127.0.0.1:18901"
export OMCPA_CPA_BASE_URL="http://127.0.0.1:8317"
export OMCPA_CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY}"
export OMCPA_MASTER_KEY
export OMCPA_DATA_DIR="${OMC_DATA_DIR}"
# 面板挂在根路径，访问 https://<domain>/ 即是控制台，无需 /omc 后缀。
# Caddy 已把 /v1 /v0 /healthz 等 API 路径分流给 CPA，其余全部给 OMC。
export OMCPA_BASE_PATH="${OMCPA_BASE_PATH:-/}"
export OMCPA_PUBLIC_URL="${OMCPA_PUBLIC_URL:-https://cpa.007666.xyz}"
export OMCPA_USAGE_INGEST_MODE="auto"
export TZ="${TZ:-Asia/Shanghai}"

/app/oh-my-cpa &
omc_pid=$!
wait_for_service "Oh My CPA" "${OMC_HEALTH}" "${omc_pid}" 90

# ---------- 启动 Caddy（对外入口） ----------
caddy run --config /app/Caddyfile --adapter caddyfile &
caddy_pid=$!
wait_for_service "public gateway" "${CADDY_HEALTH}" "${caddy_pid}" 30

snapshot_loop &
snapshot_pid=$!

unset CPA_CONFIG_B64 CPA_AUTHS_B64
unset "${!CPA_CONFIG_B64@}" "${!CPA_AUTHS_B64@}" 2>/dev/null || true
printf 'CLIProxyAPI, Oh My CPA and the public gateway are ready.\n'
wait -n "${cpa_pid}" "${omc_pid}" "${caddy_pid}"
