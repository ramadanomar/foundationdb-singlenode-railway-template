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
: "${FDB_MODE:=}"
: "${FDB_PUBLIC_HOST:=}"
: "${FDB_PUBLIC_PORT:=}"

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

resolve_to_ipv4() {
    local target="$1"
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$target"
        return 0
    fi
    getent ahostsv4 "$target" 2>/dev/null | awk '{print $1; exit}'
}

CURRENT_IP="$(get_ipv4)"
if [[ -z "$CURRENT_IP" ]]; then
    log "ERROR: could not determine container IPv4 address"
    exit 1
fi

# Mode selection. Honour an explicit FDB_MODE; otherwise default to external
# whenever Railway's TCP proxy is configured for this service.
if [[ -z "$FDB_MODE" ]]; then
    if [[ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" && -n "${RAILWAY_TCP_PROXY_PORT:-}" ]]; then
        FDB_MODE=external
    else
        FDB_MODE=internal
    fi
fi

case "$FDB_MODE" in
    external)
        : "${FDB_PUBLIC_HOST:=${RAILWAY_TCP_PROXY_DOMAIN:-}}"
        : "${FDB_PUBLIC_PORT:=${RAILWAY_TCP_PROXY_PORT:-}}"
        if [[ -z "$FDB_PUBLIC_HOST" || -z "$FDB_PUBLIC_PORT" ]]; then
            log "ERROR: FDB_MODE=external requires FDB_PUBLIC_HOST and FDB_PUBLIC_PORT"
            log "       (or RAILWAY_TCP_PROXY_DOMAIN and RAILWAY_TCP_PROXY_PORT)"
            exit 1
        fi
        ;;
    internal)
        FDB_PUBLIC_HOST="$CURRENT_IP"
        FDB_PUBLIC_PORT="$FDB_PORT"
        ;;
    *)
        log "ERROR: FDB_MODE must be 'internal' or 'external' (got: $FDB_MODE)"
        exit 1
        ;;
esac

# fdbserver compares its --public-address verbatim to the address in its
# cluster file to recognise itself as a coordinator, and the wire-level
# handshake encodes the canonical port. The host is best expressed as an IP
# because some FDB code paths still expect literal addresses.
PUBLIC_IP="$(resolve_to_ipv4 "$FDB_PUBLIC_HOST")"
if [[ -z "$PUBLIC_IP" ]]; then
    log "ERROR: could not resolve FDB_PUBLIC_HOST=$FDB_PUBLIC_HOST to an IPv4 address"
    exit 1
fi

export FDB_MODE FDB_PUBLIC_HOST FDB_PUBLIC_PORT

log "================================================================"
log "  FDB_MODE                = $FDB_MODE"
log "  FDB_PUBLIC_HOST         = $FDB_PUBLIC_HOST"
log "  FDB_PUBLIC_PORT         = $FDB_PUBLIC_PORT"
log "  public IP (resolved)    = $PUBLIC_IP"
log "  fdbserver --listen-addr = 0.0.0.0:$FDB_PORT"
log "================================================================"

CLUSTER_STRING="${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@${PUBLIC_IP}:${FDB_PUBLIC_PORT}"
echo "$CLUSTER_STRING" > "$FDB_CLUSTER_FILE"
log "cluster file ${FDB_CLUSTER_FILE}: ${CLUSTER_STRING}"

LOCAL_CLUSTER_FILE=/tmp/fdb-local.cluster
echo "${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@127.0.0.1:${FDB_PUBLIC_PORT}" > "$LOCAL_CLUSTER_FILE"

SOCAT_PID=""
if [[ "$FDB_MODE" == "external" && "$FDB_PUBLIC_PORT" != "$FDB_PORT" ]]; then
    # fdbserver listens on $FDB_PORT but advertises the proxy port as its
    # canonical port. Local fdbcli has to dial the canonical port or FDB's
    # handshake assertion fires. Bridge it with socat on loopback.
    log "starting socat bridge: 127.0.0.1:${FDB_PUBLIC_PORT} -> 127.0.0.1:${FDB_PORT}"
    socat "TCP-LISTEN:${FDB_PUBLIC_PORT},bind=127.0.0.1,fork,reuseaddr" \
          "TCP:127.0.0.1:${FDB_PORT}" \
          > >(stdbuf -oL sed 's/^/[socat] /') 2>&1 &
    SOCAT_PID=$!
    log "socat pid=${SOCAT_PID}"
fi

if [[ -n "$FDB_COORDINATOR_HOSTNAME" ]]; then
    log "FDB_COORDINATOR_HOSTNAME=$FDB_COORDINATOR_HOSTNAME (exported for clients only)"
fi

log "starting fdbserver listen=0.0.0.0:${FDB_PORT} public=${PUBLIC_IP}:${FDB_PUBLIC_PORT}"

fdbserver \
    --listen-address "0.0.0.0:${FDB_PORT}" \
    --public-address "${PUBLIC_IP}:${FDB_PUBLIC_PORT}" \
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
    [[ -n "${SOCAT_PID}" ]] && kill -TERM "${SOCAT_PID}" 2>/dev/null || true
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
