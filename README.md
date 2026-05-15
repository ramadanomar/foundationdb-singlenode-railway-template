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

1. Discovers its current container IPv4 address.
2. Writes a fresh `fdb.cluster` file at `${FDB_CLUSTER_FILE}` pointing at the
   service's Railway private hostname (`${RAILWAY_PRIVATE_DOMAIN}:4500`), so
   clients can resolve the coordinator via internal DNS.
3. Starts `fdbserver` listening on `0.0.0.0:4500`, public address set to the
   current container IP.
4. On the very first boot only (detected via a `.fdb-bootstrapped` marker on the
   volume), runs `configure new single ssd-2` to initialise the database.

The bootstrap marker lives on the persistent volume, so subsequent restarts —
or even container replacements — never re-run `configure new` and never wipe
your data.

### Why deploy FoundationDB on Railway?

Railway gives you a one-click deploy with a persistent volume, private
networking, and an optional TCP proxy in front of the database — without you
needing to write Compose files, manage volumes by hand, or expose the port
yourself.

## Variables

| Variable | Default | What it does |
| --- | --- | --- |
| `FDB_PORT` | `4500` | Port `fdbserver` listens on |
| `FDB_CLUSTER_DESCRIPTION` | _generated_ | Cluster name in the connection string. Stable for the life of the service. |
| `FDB_CLUSTER_ID` | _generated_ | Cluster identifier in the connection string. Stable for the life of the service. |
| `FDB_STORAGE_ENGINE` | `ssd-2` | FDB storage engine used at `configure new`. Only takes effect on first boot. |
| `FDB_PROCESS_CLASS` | `unset` | FDB process class (`unset` is correct for a single-process node). |
| `FDB_COORDINATOR_HOSTNAME` | `${{RAILWAY_PRIVATE_DOMAIN}}` | Hostname exported to clients so they can reach the coordinator over private DNS. Not used by the server itself. |
| `RAILWAY_RUN_UID` | `0` | Required so the persistent volume (mounted as root) is writable. |
| `FDB_CONNECTION_STRING` | _computed_ | Full cluster string clients should use as `FDB_CLUSTER_FILE_CONTENTS`. |
| `FDB_BOOTSTRAP_WAIT_SECS` | `8` | How long the entrypoint waits for `fdbserver` to settle before running `configure new` on a fresh volume. |
| `FDB_FORCE_INIT` | `0` | Set to `1` to wipe `/var/fdb/data` and bootstrap a fresh database on the next boot. **Data is destroyed.** |

## Why the cluster file uses an IP, not a hostname

`fdbserver` only recognises itself as a coordinator when the address in its
cluster file matches its `--public-address`. Railway gives each container a
fresh IPv4 on every boot, so the entrypoint rewrites the cluster file with the
current IP on each start. Clients in the same project don't read that file —
they get `FDB_CONNECTION_STRING` (which uses the private DNS hostname) as a
Railway reference variable and resolve it themselves.

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

Enable a TCP proxy on the service:

1. Open the service in the Railway dashboard.
2. Settings → Networking → TCP Proxy → set port `4500`.
3. Railway gives you a public proxy host and port (e.g. `shuttle.proxy.rlwy.net:30123`).
4. Construct a cluster string for clients: `${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@<proxy-host>:<proxy-port>`.

## Resources

- 1 vCPU and ≥ 2 GB RAM is fine for small workloads. FoundationDB does best with
  ≥ 4 GB RAM under real load; size the service plan accordingly.
- The volume can be live-resized from the Railway UI without downtime.
