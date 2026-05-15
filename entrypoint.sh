#!/usr/bin/env bash
set -euo pipefail

: "${FDB_PORT:=4500}"
: "${FDB_DATA_DIR:=/var/fdb/data}"
: "${FDB_LOG_DIR:=/var/fdb/data/logs}"
: "${FDB_CLUSTER_FILE:=/var/fdb/data/fdb.cluster}"
: "${FDB_CLUSTER_DESCRIPTION:=fdb}"
: "${FDB_CLUSTER_ID:=railway}"
: "${FDB_STORAGE_ENGINE:=ssd-2}"
: "${FDB_PROCESS_CLASS:=unset}"
: "${FDB_COORDINATOR_HOSTNAME:=}"
: "${FDB_FORCE_INIT:=0}"
: "${FDB_BOOTSTRAP_WAIT_SECS:=8}"

log() { echo "[entrypoint] $*"; }

mkdir -p "$FDB_DATA_DIR" "$FDB_LOG_DIR"

if [[ "$FDB_FORCE_INIT" == "1" ]]; then
    log "FDB_FORCE_INIT=1 set — wiping $FDB_DATA_DIR (DATA WILL BE LOST)"
    find "$FDB_DATA_DIR" -mindepth 1 -delete || true
    mkdir -p "$FDB_LOG_DIR"
fi
chmod 700 "$FDB_DATA_DIR"

get_ipv4() {
    local ip
    ip="$(hostname -I 2>/dev/null \
        | tr ' ' '\n' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | grep -v '^127\.' \
        | head -n1 || true)"
    if [[ -z "$ip" ]]; then
        ip="$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '{print $4}' \
            | cut -d/ -f1 \
            | head -n1 || true)"
    fi
    echo "$ip"
}

CURRENT_IP="$(get_ipv4)"
if [[ -z "$CURRENT_IP" ]]; then
    log "ERROR: could not determine container IPv4 address"
    exit 1
fi

# fdbserver's cluster file must list the same address as --public-address so
# fdbserver recognises itself as the coordinator. Other Railway services
# reach this container via the private DNS hostname, but inside this container
# we use 127.0.0.1 for fdbcli — the cluster_id is the same in both files, so
# the handshake works.
CLUSTER_STRING="${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@${CURRENT_IP}:${FDB_PORT}"
echo "$CLUSTER_STRING" > "$FDB_CLUSTER_FILE"
log "cluster file ${FDB_CLUSTER_FILE}: ${CLUSTER_STRING}"

LOCAL_CLUSTER_FILE=/tmp/fdb-local.cluster
echo "${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@127.0.0.1:${FDB_PORT}" > "$LOCAL_CLUSTER_FILE"

if [[ -n "$FDB_COORDINATOR_HOSTNAME" ]]; then
    log "FDB_COORDINATOR_HOSTNAME=$FDB_COORDINATOR_HOSTNAME (exported for clients only)"
fi

PUBLIC_ADDR="${CURRENT_IP}:${FDB_PORT}"
log "starting fdbserver listen=0.0.0.0:${FDB_PORT} public=${PUBLIC_ADDR}"

fdbserver \
    --listen-address "0.0.0.0:${FDB_PORT}" \
    --public-address "${PUBLIC_ADDR}" \
    --datadir "${FDB_DATA_DIR}" \
    --logdir "${FDB_LOG_DIR}" \
    --locality-zoneid "$(hostname)" \
    --locality-machineid "$(hostname)" \
    --class "${FDB_PROCESS_CLASS}" \
    --cluster-file "${FDB_CLUSTER_FILE}" \
    --knob_disable_posix_kernel_aio=1 \
    > >(stdbuf -oL sed 's/^/[fdbserver] /') 2>&1 &

FDB_PID=$!
log "fdbserver pid=${FDB_PID}"

term() {
    log "caught signal, stopping fdbserver (pid ${FDB_PID})"
    kill -TERM "${FDB_PID}" 2>/dev/null || true
    wait "${FDB_PID}" 2>/dev/null || true
    exit 0
}
trap term TERM INT

# Storage files only appear after a successful 'configure new'. Their presence
# is the authoritative signal that this volume already has a database on it.
has_storage_files() {
    find "$FDB_DATA_DIR" -maxdepth 2 -type f -name 'storage-*.sqlite' 2>/dev/null \
        | head -n1 | grep -q .
}

bootstrap_watchdog() {
    local marker="${FDB_DATA_DIR}/.fdb-bootstrapped"

    log "[bootstrap] giving fdbserver ${FDB_BOOTSTRAP_WAIT_SECS}s to settle"
    sleep "$FDB_BOOTSTRAP_WAIT_SECS"

    if ! kill -0 "$FDB_PID" 2>/dev/null; then
        log "[bootstrap] ABORT: fdbserver died during startup"
        return 1
    fi

    if has_storage_files; then
        log "[bootstrap] storage files present — database already initialised on this volume"
        touch "$marker"
        return 0
    fi

    log "[bootstrap] fresh volume — running: configure new single ${FDB_STORAGE_ENGINE}"
    if fdbcli -C "$LOCAL_CLUSTER_FILE" \
            --exec "configure new single ${FDB_STORAGE_ENGINE}" \
            --timeout 180 2>&1 | sed 's/^/[fdbcli configure] /'; then
        touch "$marker"
        log "[bootstrap] complete"
    else
        log "[bootstrap] WARNING: configure new failed; will retry on next boot"
        return 1
    fi
}

bootstrap_watchdog &

set +e
wait "${FDB_PID}"
FDB_RC=$?
set -e

log "fdbserver exited with status ${FDB_RC}"
if [[ "${FDB_RC}" -ne 0 ]]; then
    log "fdbserver log dir contents:"
    ls -la "${FDB_LOG_DIR}" 2>/dev/null | sed 's/^/[ls] /' || true
    for f in "${FDB_LOG_DIR}"/*.xml "${FDB_LOG_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        echo "----- $f -----"
        tail -n 80 "$f"
    done
fi
exit "${FDB_RC}"
