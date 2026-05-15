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

log() { echo "[entrypoint] $*"; }

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
    log "ERROR: could not determine container IPv4 address"
    exit 1
fi

COORD_ADDR="${CURRENT_IP}:${FDB_PORT}"
log "server cluster file uses IP: $COORD_ADDR"
if [[ -n "$FDB_COORDINATOR_HOSTNAME" ]]; then
    log "FDB_COORDINATOR_HOSTNAME=$FDB_COORDINATOR_HOSTNAME is exported for clients only"
fi

CLUSTER_STRING="${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@${COORD_ADDR}"
echo "$CLUSTER_STRING" > "$FDB_CLUSTER_FILE"
log "cluster file ${FDB_CLUSTER_FILE}: ${CLUSTER_STRING}"

# Detect a previously initialised database via the FDB storage engine files
# the server leaves on the volume. This is a safety net independent of our
# bootstrap marker so we never run "configure new" on top of real data.
db_already_initialised() {
    local found
    found=$(find "$FDB_DATA_DIR" -maxdepth 2 -type f \( \
        -name 'storage-*.sqlite' -o \
        -name 'storage-*.fdb-c' -o \
        -name 'coordination-*.sqlite' -o \
        -name 'log-*.sqlite' -o \
        -name 'logqueue-*.fdb-c' \
    \) 2>/dev/null | head -n1)
    [[ -n "$found" ]]
}

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

# Background bootstrap watchdog: when fdbserver is reachable, configure the DB
# if it has never been initialised on this volume, then exit. Runs in the
# background so we can hand off PID 1 to `wait` on fdbserver.
bootstrap_watchdog() {
    local marker="${FDB_DATA_DIR}/.fdb-bootstrapped"

    if db_already_initialised; then
        log "[bootstrap] storage files exist on volume; treating database as initialised"
        touch "$marker"
        return 0
    fi
    if [[ -f "$marker" ]]; then
        log "[bootstrap] marker present; nothing to do"
        return 0
    fi

    log "[bootstrap] waiting for fdbserver to accept fdbcli connections"
    local out=""
    local i
    for i in $(seq 1 60); do
        sleep 1
        if ! kill -0 "$FDB_PID" 2>/dev/null; then
            log "[bootstrap] ABORT: fdbserver died (pid ${FDB_PID} gone)"
            return 1
        fi
        out="$(fdbcli -C "$FDB_CLUSTER_FILE" --exec 'status minimal' --timeout 5 2>&1 || true)"
        case "$out" in
            *"The database is available"*|*"Database is available"*)
                log "[bootstrap] DB already available (poll $i); marking bootstrapped"
                touch "$marker"
                return 0
                ;;
            *"The database is unavailable"*|*"Database is unavailable"*|*"unconfigured"*|*"not yet configured"*|*"new database"*)
                log "[bootstrap] DB reachable but unconfigured (poll $i); proceeding to configure"
                break
                ;;
        esac
        if (( i % 5 == 0 )); then
            log "[bootstrap] poll $i fdbcli output: ${out//$'\n'/ | }"
        fi
    done

    log "[bootstrap] running: configure new single ${FDB_STORAGE_ENGINE}"
    if fdbcli -C "$FDB_CLUSTER_FILE" --exec "configure new single ${FDB_STORAGE_ENGINE}" --timeout 60 2>&1 \
            | sed 's/^/[fdbcli] /'; then
        touch "$marker"
        log "[bootstrap] complete"
    else
        log "[bootstrap] WARNING: configure new failed; will retry on next boot"
    fi

    log "[bootstrap] final status:"
    fdbcli -C "$FDB_CLUSTER_FILE" --exec 'status' --timeout 10 2>&1 | sed 's/^/[fdbcli] /' || true
}

bootstrap_watchdog &

# Wait for fdbserver to exit, then propagate its status as our own.
set +e
wait "${FDB_PID}"
FDB_RC=$?
set -e

log "fdbserver exited with status ${FDB_RC}"
if [[ "${FDB_RC}" -ne 0 ]]; then
    log "dumping recent fdbserver log files from ${FDB_LOG_DIR}:"
    ls -la "${FDB_LOG_DIR}" 2>/dev/null || true
    for f in "${FDB_LOG_DIR}"/*.xml "${FDB_LOG_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        echo "----- $f -----"
        tail -n 100 "$f"
    done
fi
exit "${FDB_RC}"
