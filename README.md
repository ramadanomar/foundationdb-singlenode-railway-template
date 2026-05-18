# Deploy and Host FoundationDB with Railway

FoundationDB is Apple's open-source, distributed, ordered key-value store with strict
serializable ACID transactions. This template runs a single-node FoundationDB
instance on Railway from the official upstream Docker image, with a persistent
volume so your data survives redeploys.

## About hosting FoundationDB

FoundationDB is normally deployed as a multi-process cluster across several
machines, with a quorum of coordinators and replicated storage. For development,
small workloads, and embedded use inside a single Railway project, a single-node
instance is the practical choice — one process, one data directory, one
persistent volume. This template uses the official `foundationdb/foundationdb`
image (no compilation), wraps it with a small entrypoint that idempotently
bootstraps the database on first boot, and exposes the FDB port `4500` over
Railway's private network so other services in the same project can connect.

## Common use cases

- Key-value storage backing for a Railway-hosted app
- Local-feeling development against a real FoundationDB
- Hosting metadata for systems built on FDB (e.g. layers, Stalwart, JanusGraph)
- Hobby projects that want ACID guarantees without operating a cluster

## Dependencies for FoundationDB hosting

- Persistent volume mounted at `/var/fdb/data` (the template provisions this)
- A Railway service hostname over private networking so clients can resolve the coordinator
- Optional: TCP proxy if you need to connect from outside Railway

### Deployment dependencies

- Upstream image: <https://hub.docker.com/r/foundationdb/foundationdb>
- FoundationDB docs: <https://apple.github.io/foundationdb/>
- Source: <https://github.com/apple/foundationdb>

### Implementation details

The container runs a single `fdbserver` process and uses an SSD storage engine
(`ssd-2`). On every boot the entrypoint:

1. Determines `FDB_MODE` (`internal` or `external`, see below).
2. Resolves the public address to an IP and writes a fresh `fdb.cluster` file
   at `${FDB_CLUSTER_FILE}` whose coordinator address matches the value passed
   to `fdbserver --public-address`.
3. Starts `fdbserver` listening on `0.0.0.0:${FDB_PORT}` with the chosen
   public address.
4. In external mode, starts a loopback `socat` bridge so the in-container
   `fdbcli` can dial the same canonical port the server advertises (FDB's
   wire-level handshake compares ports verbatim).
5. On the very first boot only (detected by the presence of
   `storage-*.sqlite` files on the volume), runs `configure new single ssd-2`
   to initialise the database.

The bootstrap marker lives on the persistent volume, so subsequent restarts —
or even container replacements — never re-run `configure new` and never wipe
your data.

### Why deploy FoundationDB on Railway?

Railway gives you a one-click deploy with a persistent volume, private
networking, and an optional TCP proxy in front of the database — without you
needing to write Compose files, manage volumes by hand, or expose the port
yourself.

## Modes: `internal` vs `external`

FoundationDB embeds a single canonical address (host + port) in every
wire-level handshake packet. Clients refuse the session when the port they
dialed does not match the canonical port the server advertised. Railway's TCP
proxy translates ports (`external:11333 → container:4500`), so the server's
`--public-address` has to match the side you actually want clients to use.
You cannot satisfy both internal *and* external clients from a single
`fdbserver` process; pick one.

The entrypoint chooses a mode automatically:

- If `RAILWAY_TCP_PROXY_DOMAIN` and `RAILWAY_TCP_PROXY_PORT` are set
  (i.e. the Railway TCP proxy is enabled on this service), `FDB_MODE=external`.
- Otherwise, `FDB_MODE=internal`.

Set `FDB_MODE` explicitly to override the auto-detection. The active value is
exported to the container's environment and printed in the boot logs, so
`printenv FDB_MODE` inside the container always tells you which mode is live.

| Mode | `--public-address` | Cluster string clients use | Who can connect |
| --- | --- | --- | --- |
| `internal` | container-IP:`FDB_PORT` | `…@${{RAILWAY_PRIVATE_DOMAIN}}:${{FDB_PORT}}` | Railway services in the same project only |
| `external` | proxy-IP:`RAILWAY_TCP_PROXY_PORT` | `…@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}` | Anyone with the cluster string (internal services connect via the proxy) |

External mode is the right default for templates because it works for both
external clients and internal clients (the latter hairpin through the proxy,
which adds latency and counts as egress bandwidth). Switch to `internal` if
all your clients live in the same Railway project and you want direct,
in-network traffic.

## Variables

| Variable | Default | What it does |
| --- | --- | --- |
| `FDB_MODE` | _auto_ | `external` if Railway TCP proxy is on, else `internal`. Set explicitly to override. |
| `FDB_PUBLIC_HOST` | _auto_ | Host advertised to clients. In external mode defaults to `${{RAILWAY_TCP_PROXY_DOMAIN}}`. |
| `FDB_PUBLIC_PORT` | _auto_ | Port advertised to clients. In external mode defaults to `${{RAILWAY_TCP_PROXY_PORT}}`. |
| `FDB_PORT` | `4500` | Port `fdbserver` actually listens on inside the container. |
| `FDB_CLUSTER_DESCRIPTION` | _generated_ | Cluster name in the connection string. Stable for the life of the service. |
| `FDB_CLUSTER_ID` | _generated_ | Cluster identifier in the connection string. Stable for the life of the service. |
| `FDB_STORAGE_ENGINE` | `ssd-2` | FDB storage engine used at `configure new`. Only takes effect on first boot. |
| `FDB_PROCESS_CLASS` | `unset` | FDB process class (`unset` is correct for a single-process node). |
| `FDB_COORDINATOR_HOSTNAME` | `${{RAILWAY_PRIVATE_DOMAIN}}` | Informational only; exported for clients that prefer the private name. |
| `RAILWAY_RUN_UID` | `0` | Required so the persistent volume (mounted as root) is writable. |
| `FDB_CONNECTION_STRING` | _computed_ | Full cluster string clients should use as `FDB_CLUSTER_FILE_CONTENTS`. |
| `FDB_BOOTSTRAP_WAIT_SECS` | `8` | How long the entrypoint waits for `fdbserver` to settle before running `configure new` on a fresh volume. |
| `FDB_FORCE_INIT` | `0` | Set to `1` to wipe `/var/fdb/data` and bootstrap a fresh database on the next boot. **Data is destroyed.** |

## Connecting from another Railway service

In the client service, set this variable (replace `FoundationDB` with the
service name if you renamed it):

```
FDB_CLUSTER_FILE_CONTENTS=${{FoundationDB.FDB_CONNECTION_STRING}}
```

In your client startup code, write that env var to a file and point the FDB
client at it. For example, in Python:

```python
import os
import foundationdb as fdb

cf_path = "/tmp/fdb.cluster"
with open(cf_path, "w") as f:
    f.write(os.environ["FDB_CLUSTER_FILE_CONTENTS"])

fdb.api_version(730)
db = fdb.open(cf_path)
```

Node.js (`foundationdb` npm package), Go (`fdb-go`), Rust (`foundationdb-rs`),
Java — all use the same cluster-file mechanism.

## Connecting from outside Railway

Requires `FDB_MODE=external` (the default when the Railway TCP proxy is
enabled on the service):

1. Open the service in the Railway dashboard.
2. Settings → Networking → TCP Proxy → set target port `4500`.
3. Railway gives you a public proxy host and port
   (e.g. `shuttle.proxy.rlwy.net:30123`).
4. Construct a cluster string for clients:
   `${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@<proxy-host>:<proxy-port>`.

If you change the Railway TCP proxy port after first boot, redeploy the
service so the entrypoint re-reads it and re-writes the cluster file.

## Resources

- 1 vCPU and ≥ 2 GB RAM is fine for small workloads. FoundationDB does best with
  ≥ 4 GB RAM under real load; size the service plan accordingly.
- The volume can be live-resized from the Railway UI without downtime.
