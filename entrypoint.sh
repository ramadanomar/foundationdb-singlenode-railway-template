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

log() { echo "[entrypoint] $*"; }

mkdir -p "$FDB_DATA_DIR" "$FDB_LOG_DIR"

if [[ "$FDB_FORCE_INIT" == "1" ]]; then
    log "FDB_FORCE_INIT=1; wiping ${FDB_DATA_DIR} before start"
    find "$FDB_DATA_DIR" -mindepth 1 -delete || true
    mkdir -p "$FDB_LOG_DIR"
fi

chmod 700 "$FDB_DATA_DIR"

log "data dir contents at start:"
ls -la "$FDB_DATA_DIR" | sed 's/^/[ls] /'

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

COORD_ADDR="${CURRENT_IP}:${FDB_PORT}"
PUBLIC_ADDR="${CURRENT_IP}:${FDB_PORT}"
log "server cluster file uses IP: $COORD_ADDR"
if [[ -n "$FDB_COORDINATOR_HOSTNAME" ]]; then
    log "FDB_COORDINATOR_HOSTNAME=$FDB_COORDINATOR_HOSTNAME (exported for clients only)"
fi

CLUSTER_STRING="${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@${COORD_ADDR}"
echo "$CLUSTER_STRING" > "$FDB_CLUSTER_FILE"
log "cluster file ${FDB_CLUSTER_FILE}: ${CLUSTER_STRING}"

# Some container networks (including Railway's wireguard mesh) do not route
# packets from inside the container to the container's own assigned IP via the
# kernel loopback. fdbcli would then time out trying to reach fdbserver via the
# IP in $FDB_CLUSTER_FILE. We work around that by giving local fdbcli calls a
# second cluster file pointing at 127.0.0.1 — same cluster_id, so the handshake
# with fdbserver still succeeds.
LOCAL_CLUSTER_FILE=/tmp/fdb-local.cluster
LOCAL_CLUSTER_STRING="${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@127.0.0.1:${FDB_PORT}"
echo "$LOCAL_CLUSTER_STRING" > "$LOCAL_CLUSTER_FILE"
log "local cluster file ${LOCAL_CLUSTER_FILE}: ${LOCAL_CLUSTER_STRING}"

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

has_storage_files() {
    find "$FDB_DATA_DIR" -maxdepth 2 -type f -name 'storage-*.sqlite' 2>/dev/null \
        | head -n1 | grep -q .
}

bootstrap_watchdog() {
    local marker="${FDB_DATA_DIR}/.fdb-bootstrapped"

    log "[bootstrap] sleeping 8s to let fdbserver finish initialisation"
    sleep 8

    if ! kill -0 "$FDB_PID" 2>/dev/null; then
        log "[bootstrap] ABORT: fdbserver died"
        return 1
    fi

    log "[bootstrap] diagnostics:"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>&1 | sed 's/^/[ss] /'
    fi
    if command -v nc >/dev/null 2>&1; then
        log "[bootstrap] nc -zv 127.0.0.1 ${FDB_PORT}:"
        nc -zv -w 3 127.0.0.1 "${FDB_PORT}" 2>&1 | sed 's/^/[nc-lo] /' || true
        log "[bootstrap] nc -zv ${CURRENT_IP} ${FDB_PORT}:"
        nc -zv -w 3 "${CURRENT_IP}" "${FDB_PORT}" 2>&1 | sed 's/^/[nc-ip] /' || true
    fi

    log "[bootstrap] one-shot fdbcli status (long timeout) via local cluster file:"
    fdbcli -C "$LOCAL_CLUSTER_FILE" --exec 'status minimal' --timeout 30 2>&1 | sed 's/^/[fdbcli A] /' || true

    log "[bootstrap] one-shot fdbcli status (long timeout) via canonical cluster file:"
    fdbcli -C "$FDB_CLUSTER_FILE" --exec 'status minimal' --timeout 30 2>&1 | sed 's/^/[fdbcli B] /' || true

    if has_storage_files; then
        log "[bootstrap] storage files exist on volume; treating as initialised"
        touch "$marker"
        return 0
    fi

    log "[bootstrap] no storage files; running configure new single ${FDB_STORAGE_ENGINE} (via local cluster file)"
    if fdbcli -C "$LOCAL_CLUSTER_FILE" --exec "configure new single ${FDB_STORAGE_ENGINE}" --timeout 120 2>&1 \
            | sed 's/^/[fdbcli configure] /'; then
        touch "$marker"
        log "[bootstrap] complete"
    else
        log "[bootstrap] WARNING: configure new failed via local; trying canonical cluster file"
        if fdbcli -C "$FDB_CLUSTER_FILE" --exec "configure new single ${FDB_STORAGE_ENGINE}" --timeout 120 2>&1 \
                | sed 's/^/[fdbcli configure B] /'; then
            touch "$marker"
            log "[bootstrap] complete via canonical cluster file"
        else
            log "[bootstrap] FAILED: both bootstrap attempts failed"
        fi
    fi

    log "[bootstrap] final status:"
    fdbcli -C "$LOCAL_CLUSTER_FILE" --exec 'status' --timeout 15 2>&1 | sed 's/^/[fdbcli final] /' || true
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
