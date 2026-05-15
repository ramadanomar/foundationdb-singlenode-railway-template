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

mkdir -p "$FDB_DATA_DIR" "$FDB_LOG_DIR"
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
    echo "[entrypoint] ERROR: could not determine container IPv4 address" >&2
    exit 1
fi

COORD_ADDR="${CURRENT_IP}:${FDB_PORT}"
echo "[entrypoint] server cluster file uses IP: $COORD_ADDR"
if [[ -n "$FDB_COORDINATOR_HOSTNAME" ]]; then
    echo "[entrypoint] FDB_COORDINATOR_HOSTNAME=$FDB_COORDINATOR_HOSTNAME is exported for clients only"
fi

CLUSTER_STRING="${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@${COORD_ADDR}"
echo "$CLUSTER_STRING" > "$FDB_CLUSTER_FILE"
echo "[entrypoint] cluster file ${FDB_CLUSTER_FILE}: ${CLUSTER_STRING}"

PUBLIC_ADDR="${CURRENT_IP}:${FDB_PORT}"
echo "[entrypoint] starting fdbserver listen=0.0.0.0:${FDB_PORT} public=${PUBLIC_ADDR}"

fdbserver \
    --listen-address "0.0.0.0:${FDB_PORT}" \
    --public-address "${PUBLIC_ADDR}" \
    --datadir "${FDB_DATA_DIR}" \
    --logdir "${FDB_LOG_DIR}" \
    --locality-zoneid "$(hostname)" \
    --locality-machineid "$(hostname)" \
    --class "${FDB_PROCESS_CLASS}" \
    --cluster-file "${FDB_CLUSTER_FILE}" \
    --knob_disable_posix_kernel_aio=1 2>&1 &

FDB_PID=$!
sleep 2
if ! kill -0 "${FDB_PID}" 2>/dev/null; then
    echo "[entrypoint] ERROR: fdbserver exited immediately (pid ${FDB_PID})" >&2
    echo "[entrypoint] dumping fdbserver log files from ${FDB_LOG_DIR}:" >&2
    ls -la "${FDB_LOG_DIR}" >&2 || true
    for f in "${FDB_LOG_DIR}"/*; do
        [[ -f "$f" ]] && { echo "----- $f -----" >&2; tail -n 200 "$f" >&2; }
    done
    exit 1
fi
echo "[entrypoint] fdbserver pid=${FDB_PID} is alive after 2s"

term() {
    echo "[entrypoint] caught signal, stopping fdbserver (pid ${FDB_PID})"
    kill -TERM "${FDB_PID}" 2>/dev/null || true
    wait "${FDB_PID}" || true
}
trap term TERM INT

BOOTSTRAP_MARKER="${FDB_DATA_DIR}/.fdb-bootstrapped"
if [[ ! -f "$BOOTSTRAP_MARKER" ]]; then
    echo "[entrypoint] no bootstrap marker; waiting for fdbserver to accept connections"
    STATUS_OUT=""
    for _ in $(seq 1 60); do
        sleep 1
        STATUS_OUT="$(fdbcli -C "$FDB_CLUSTER_FILE" --exec "status minimal" --timeout 3 2>&1 || true)"
        if echo "$STATUS_OUT" | grep -qE "(The database is available|The database is unavailable|new database)"; then
            break
        fi
    done

    if echo "$STATUS_OUT" | grep -q "The database is available"; then
        echo "[entrypoint] database already configured on this volume; marking bootstrapped"
        touch "$BOOTSTRAP_MARKER"
    else
        echo "[entrypoint] configuring new single ${FDB_STORAGE_ENGINE} database"
        if fdbcli -C "$FDB_CLUSTER_FILE" --exec "configure new single ${FDB_STORAGE_ENGINE}" --timeout 30; then
            touch "$BOOTSTRAP_MARKER"
            echo "[entrypoint] bootstrap complete"
        else
            echo "[entrypoint] WARNING: configure new failed; will retry on next boot" >&2
        fi
    fi
else
    echo "[entrypoint] bootstrap marker present; skipping configure"
fi

wait "${FDB_PID}"
