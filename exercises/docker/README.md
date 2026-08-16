# Helios Asset Pipeline — Containerisation Exam

> **Format:** practical, open book, no time limit enforced by the repo.
> **What you submit:** three `Dockerfile`s, one Compose file, a `.env`, a `.dockerignore`, and a written incident review.
> **What you must not submit:** changes to the application source.

---

## 1. The scenario

Helios is the asset ingestion pipeline behind a photo marketplace. Three Node.js
services and two datastores. It has run on a hand-built VM for two years, started
by a `systemd` unit that nobody has read since the person who wrote it left.

Last Thursday it went down for six hours. The post-incident timeline:

| Time  | Event |
|-------|-------|
| 09:14 | The VM is rebuilt. The schema job and both services start at the same time. |
| 09:14 | `api-gateway` and `image-processor` crash on boot with `UnhandledPromiseRejection`. |
| 09:21 | Someone restarts them by hand. They come up, because by then the schema exists. |
| 11:02 | A batch of 40-megapixel TIFFs arrives. `image-processor` disappears. No stack trace, no log line, exit code 137. |
| 11:40 | It is restarted with more memory. It disappears again at a different point. |
| 13:30 | A deploy is attempted. Every `restart` takes 10 seconds per container and drops in-flight jobs. Postgres accumulates orphaned sessions until it refuses new connections. |
| 14:55 | The on-call engineer tries to clear the scratch directory to free disk. Every file is owned by `root`. They do not have `sudo` on that host. |
| 15:10 | Someone points `psql` at the box from their laptop, because port 5432 has been open to the office network the entire time. |

The company has decided the answer is containers. **You are the engineer who has
to make that true.** The application team has handed you the repository below and
made it clear they are not changing their code for you.

Every one of those seven failures is reproducible in this repo. Your Compose
stack and your Dockerfiles are the only place they can be fixed.

---

## 2. What you have been handed

```
docker/
├── api-gateway/            HTTP entry point. Express. Publishes the only public port.
│   ├── package.json
│   └── src/
├── image-processor/        Background worker. BullMQ over Redis. Writes artifacts.
│   ├── package.json
│   └── src/
├── db-migrator/            One-shot schema job. Runs, applies SQL, exits.
│   ├── package.json
│   ├── sql/                001, 002, 003 — the schema contract
│   └── src/
├── shared-scratch/         Empty. The only place the gateway and the worker meet.
├── scripts/acceptance/     The grading suite. Read it. It is not a black box.
├── .env.example            Every variable the code reads. No defaults for secrets.
└── README.md               This brief.
```

There is **no** `Dockerfile`, **no** Compose file, and **no** `.env`. That is the exam.

### Services in one line each

- **api-gateway** — accepts ingest requests, writes a row, enqueues a job, exposes
  `/healthz` and `/readyz`, and reads the worker's artifacts back off the shared volume.
- **image-processor** — consumes the queue, derives metadata, writes JSON artifacts
  into `shared-scratch/processed/`, records what it did in Postgres. Some jobs are
  memory-heavy on purpose. Every job shells out to a legacy sidecar.
- **db-migrator** — takes an advisory lock, applies `sql/*.sql` in order, records
  versions in `platform_meta`, exits 0. It is slow by design and it does not retry
  its database connection.

---

## 3. Rules of engagement

**You may not modify anything under `*/src/`, `*/package.json`, or `db-migrator/sql/`.**
The behaviours you find irritating are the exam. If a service refuses to start, the
answer is always in your configuration, never in a patch to theirs.

You **may** create: `Dockerfile`s, Compose files, `.env`, `.dockerignore`, secrets
files, entrypoint scripts, and anything else that is deployment configuration.

You **may** set any environment variable the code reads, including the tuning knobs.
Choosing a number is part of the answer; you will be asked to defend it.

Deleting the acceptance suite is not a passing strategy — you are graded on a fresh
checkout of it.

---

## 4. Deliverables

| File | Requirement |
|------|-------------|
| `api-gateway/Dockerfile` | Multi-stage, named stages, at minimum a `development` target and a `production` target |
| `image-processor/Dockerfile` | Same |
| `db-migrator/Dockerfile` | Multi-stage; the runtime stage must contain everything the job needs to run and nothing else |
| `compose.yaml` (or `docker-compose.yml`) | The whole stack |
| `.env` | Real values. Never committed. |
| `.dockerignore` | At the root or per service |
| `INCIDENT-REVIEW.md` | Your write-up (§9) |

**Service names are a contract.** The acceptance suite looks for exactly these:

```
gateway    worker    migrator    db    cache
```

The gateway must be reachable at `http://localhost:8080` from the host.

---

## 5. Hard constraints

1. **The datastores are private.** `db` and `cache` must not publish a single port
   to the host. Nothing may listen on `127.0.0.1:5432` or `127.0.0.1:6379`.
   The gateway is the only service with a published port.
2. **No hardcoded credentials.** No password literal may appear in any Dockerfile,
   Compose file, or committed file. `.env` must be gitignored. Well-known passwords
   (`postgres`, `changeme`, `password`, …) are rejected by the applications
   themselves when `NODE_ENV=production`.
3. **Shutdown is under two seconds.** `docker stop` on `gateway` or `worker` must
   return in under 2s, with exit code 0, having written a shutdown marker to
   `shared-scratch/shutdown/`. A container that has to be killed has failed, no
   matter how quickly it dies.
4. **Cold boot works on the first attempt.** `docker compose down -v && docker
   compose up -d` must reach a ready state with zero restarts of `gateway` and
   `worker`. "It works the second time" is the exact failure you are here to fix.
5. **Nothing runs as root.** All three application containers run as an unprivileged
   user. The applications verify this themselves and exit non-zero if you get it wrong.
6. **The host operator can clean up.** A user without `sudo` must be able to delete
   everything the containers wrote to the shared scratch area.
7. **Artifact permissions are fixed by the app**: directories `2750`, files `0640`.
   The gateway must still be able to read them. Solve that with identity, not with
   `chmod 777` and not by running both services as the same root-ish user.
8. **Memory is bounded.** Every application container declares an explicit memory
   limit. An unbounded worker is an automatic fail even if the tests pass.
9. **The worker survives `SPIKE_MB` of live heap.** Exit code 137 or a V8
   `JavaScript heap out of memory` abort is a fail.
10. **Production images carry no dev dependencies** and run with `NODE_ENV=production`.
11. **One image per service, two targets.** The development target must be usable
    for live-reload work; the production target must be what the acceptance suite runs.
12. **The migrator runs to completion exactly once per boot** and does not restart
    in a loop. Consumers must not connect before it has finished.

---

## 6. Architecture checklist

Your Dockerfiles and Compose file must demonstrably achieve all of the following.
This list is the grading rubric for design; §8 is the grading rubric for behaviour.

**Image construction**
- [ ] Multi-stage builds with meaningful stage names
- [ ] A dependency layer that is not invalidated by a source-file edit
- [ ] `npm run build` executed in a build stage; the runtime stage runs the built output
- [ ] Production runtime installs production dependencies only
- [ ] A `.dockerignore` that keeps `node_modules`, `.env`, `.git`, and `shared-scratch` out of the build context
- [ ] A non-root user created in the image, with a deliberate uid and gid
- [ ] Pinned base image (a digest or at least a specific minor version — `:latest` is a fail)

**Process model**
- [ ] PID 1 forwards `SIGTERM`/`SIGINT` to the application
- [ ] PID 1 reaps orphaned children (the worker's sidecar backgrounds its own work and detaches)
- [ ] The container's stop signal and grace period are set deliberately, not left to chance
- [ ] The application's own drain budget and the orchestrator's grace period are consistent with each other

**Dependency ordering**
- [ ] `db` and `cache` have real healthchecks, not `sleep`
- [ ] `migrator` starts only once `db` is genuinely accepting connections
- [ ] `gateway` and `worker` start only once `migrator` has **completed successfully**
- [ ] The distinction between "container started", "container healthy", and "container
      completed successfully" is used correctly for each edge

**Health**
- [ ] `gateway` healthcheck uses readiness, not just liveness — and you can explain
      why the container probe and the load-balancer probe are not the same thing
- [ ] `worker` has a healthcheck even though it serves no HTTP
- [ ] Healthcheck `start_period`, `interval`, `timeout`, and `retries` are chosen,
      not copy-pasted

**Resources**
- [ ] Explicit memory limit per application container
- [ ] The V8 heap ceiling is set in relation to that limit, not left to the default
- [ ] The relationship between `SPIKE_MB`, `WORKER_CONCURRENCY`, the heap ceiling,
      and the container limit is one you can write down as an inequality

**Storage and identity**
- [ ] `shared-scratch` is provisioned so both services can use it under the
      permissions the application enforces
- [ ] uid/gid are consistent between the image, the Compose file, and `APP_UID`/`APP_GID`
- [ ] Nothing anywhere runs `chmod -R 777` or `chown -R` at container start to paper over it

**Secrets and networking**
- [ ] Credentials come from `.env`, an env file, or Compose secrets — never a literal
- [ ] Datastores sit on a network the host cannot reach
- [ ] Only the gateway is published

---

## 7. Service contracts

### Environment variables

Read by all three services unless noted. Missing → exit `64`. Any variable
`X` may instead be supplied as `X_FILE` pointing at a file (that is not an accident).

| Variable | Notes |
|---|---|
| `NODE_ENV` | `production` enables the weak-credential check |
| `LOG_LEVEL` | `debug`\|`info`\|`warn`\|`error` |
| `PORT` | gateway only |
| `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | |
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` | password optional |
| `QUEUE_NAME` | must match between gateway and worker |
| `SCRATCH_DIR`, `PROCESSED_SUBDIR` | shared volume paths |
| `APP_UID`, `APP_GID` | gateway + worker; asserted against the real uid/gid at boot |
| `EXPECTED_SCHEMA_VERSION` | default `3` — the version `db-migrator` produces |
| `SHUTDOWN_DRAIN_MS`, `SHUTDOWN_HARD_TIMEOUT_MS` | drain budget |
| `WORKER_CONCURRENCY`, `SPIKE_MB`, `SPIKE_HOLD_MS` | worker only |
| `HEARTBEAT_INTERVAL_MS`, `HEARTBEAT_STALE_MS`, `ZOMBIE_THRESHOLD` | worker health inputs |
| `SIDECAR_ENABLED`, `SIDECAR_LINGER_SECONDS` | worker only; disabling the sidecar is not a fix, it is an admission |
| `MIGRATIONS_DIR`, `MIGRATION_DELAY_MS`, `MIGRATION_LOCK_ID` | migrator only |

### Gateway HTTP surface

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/healthz` | Liveness. Touches no dependency. |
| `GET` | `/readyz` | Readiness: Postgres + schema version, Redis, scratch readability. `503` when degraded. |
| `POST` | `/ingest` | `{assetId, sourceBytes, contentType}` → `202` |
| `POST` | `/ingest/spike` | `{assetId, megabytes?}` → `202`, enqueues a memory-heavy job |
| `GET` | `/assets` | Recent rows joined with what is actually on the shared volume |
| `GET` | `/queue/stats` | BullMQ counters |
| `GET` | `/debug/runtime` | uid, gid, groups, pid, ppid, `execArgv`, V8 heap limit, memory usage |

`/debug/runtime` is the single most useful endpoint in this exam. Use it early.

### Exit codes

| Code | Meaning |
|---|---|
| `64` | Required environment variable missing |
| `65` | Well-known credential rejected in production |
| `66` | Migration SQL not present in the runtime image |
| `70` | Migrator could not reach Postgres on its single connection attempt |
| `71` | A migration's content changed after it was applied |
| `72` | A migration failed and was rolled back |
| `77` | Shared scratch is not writable by this uid/gid |
| `78` | Process is running as root |
| `79` | Effective uid/gid does not match `APP_UID`/`APP_GID` |
| `1` | Unhandled rejection during boot — usually the schema contract |
| `134` | V8 aborted: heap allocation failure |
| `137` | The kernel OOM-killed the container, or it was `SIGKILL`ed after a stop timeout |

Note that `137` has two causes. Distinguishing them is part of the exam.

---

## 8. The acceptance test

```bash
cd exercises/docker
cp .env.example .env         # then fill it in
chmod +x scripts/acceptance/*.sh
./scripts/acceptance/run-all.sh
```

Stages run in order; each is independently runnable.

### `00-preflight.sh` — static
Deliverables exist. Compose parses. All five services declared. No literal
credentials. `.env` gitignored. `db`/`cache` publish nothing. Named build stages
and a `USER` instruction in every Dockerfile.

### `10-cold-boot.sh` — the race
```bash
docker compose down --volumes --remove-orphans
docker compose up -d --build
```
Asserts: gateway ready; migrator `exited 0`; `gateway` and `worker` restart count is
**zero**; no `SchemaNotReadyError` or `platform_meta ... does not exist` anywhere in
their logs; `/healthz` and `/readyz` both `200`; worker container reports `healthy`.

Restart-until-it-works is detectable and does not pass.

### `20-load.sh` — sustained ingest
```bash
REQUESTS=600 CONCURRENCY=24 ./scripts/acceptance/20-load.sh
```
600 ingests at concurrency 24. Asserts: every request accepted; the queue drains to
zero; neither service restarted; **the worker's PID namespace contains no more than
5 zombie processes**; the worker is still `healthy`; the gateway can read the
artifacts the worker wrote.

The zombie count is not decoration. Look at what the sidecar does, then look at
what your PID 1 is.

### `30-memory.sh` — the spike
```bash
SPIKES=6 ./scripts/acceptance/30-memory.sh
```
Six memory-heavy jobs. Asserts: the worker declares a memory limit; restart count
unchanged; `OOMKilled` is false; no `JavaScript heap out of memory` in the logs;
exit code is not `137`; zero failed jobs; spike artifacts landed on the volume.

Raising the limit until it stops crashing is one of two things you must do, and on
its own it will not get you through this stage.

### `40-restart.sh` — signals
```bash
BUDGET_SECONDS=2 ./scripts/acceptance/40-restart.sh
```
`docker stop --time 30` on each long-lived service — a deliberately generous grace
period, because needing it is the failure. Asserts: stop returns in **< 2s**; exit
code `0`; `graceful shutdown complete` in the logs; a shutdown marker JSON exists on
the shared volume for **both** services; a full `docker compose restart` does not
wait out a kill timeout.

### `50-ownership.sh` — the boundary
Asserts: no container runs as root; the migrator declares a non-root user; artifacts
are `0640`; the gateway can read the worker's directory; the host directory is not
root-owned; **a probe file created inside the container can be deleted from the host
without `sudo`**; `APP_UID` matches the real uid in each container.

### `60-isolation.sh` — blast radius
Asserts: `db` and `cache` publish nothing; host ports 5432 and 6379 are closed; the
gateway publishes a port; runtime images contain no `nodemon`/`esbuild`;
`NODE_ENV=production` in the running containers; both `development` and `production`
stages exist; all four long-lived services have container healthchecks; restart
policies are set, and the migrator's is not `always`.

---

## 9. The write-up

`INCIDENT-REVIEW.md`, one to two pages. Passing the suite without this is a fail —
the point of the exam is the reasoning, and the suite only measures its shadow.

1. **Seven failures, seven fixes.** Take each row of the §1 timeline. Name the
   mechanism, name the configuration that fixes it, and name the alternative you
   rejected.
2. **The memory inequality.** Write down the actual relationship between `SPIKE_MB`,
   `WORKER_CONCURRENCY`, the V8 heap ceiling, and the container memory limit, with
   your chosen numbers substituted in. Explain the headroom you left and why.
3. **The two 137s.** Explain how you would tell an OOM kill apart from a stop-timeout
   kill from the outside, with the commands you would run.
4. **Ordering.** Explain the difference between the three dependency conditions you
   used and why each edge got the one it did. Then explain what still breaks if the
   migrator fails halfway through on a Tuesday afternoon.
5. **Identity.** Explain your uid/gid choice and what changes about it when this
   moves from a developer laptop to a shared CI runner to Kubernetes.
6. **What you would not ship.** One thing in your own solution that is acceptable for
   this exam and not acceptable in production, and what you would do instead.

---

## 10. Known failure signatures

Symptoms only. The diagnosis is the exam.

| What you will see | |
|---|---|
| `sh: esbuild: not found` during `docker build` | |
| `UnhandledPromiseRejection ... SchemaNotReadyError` seconds after `up` | |
| `relation "platform_meta" does not exist` | |
| Container exits `137` with `OOMKilled=true` | |
| Container exits `137` after exactly 10 seconds, `OOMKilled=false` | |
| `FATAL ERROR: Reached heap limit Allocation failed` | |
| `docker stop` returns in 10.0s every single time | |
| No `graceful shutdown complete` line, no shutdown marker | |
| `ps` inside the worker shows a growing column of `<defunct>` | |
| `/assets` returns `"readable": false` with `"error": "EACCES"` | |
| `rm: cannot remove ...: Permission denied` on the host | |
| Application exits `78` before printing anything else | |
| Application exits `79` with `uid contract violated` | |
| Migrator exits `70` immediately on a cold `up` | |
| Migrator exits `66` in production but works with a bind mount | |

---

## 11. Scoring

| Weight | Dimension |
|---|---|
| 35% | Acceptance suite (all seven stages green on a cold machine) |
| 25% | Dockerfile quality — staging, caching, layer discipline, base image choice, no dev deps in production |
| 20% | Compose design — dependency conditions, healthchecks, networks, resources, restart policy, secret handling |
| 20% | `INCIDENT-REVIEW.md` — the reasoning, not the result |

Automatic fails, regardless of suite output: any container running as root; a
published Postgres or Redis port; a credential literal in a committed file; any
edit to application source; `:latest` base images; `chmod -R 777` or a runtime
`chown -R` used to solve the permissions problem.

---

## 12. Platform notes

- **Linux** is the reference platform. Every check is meaningful there.
- **Docker Desktop (macOS/Windows)** virtualises the bind-mount ownership layer, so
  the host-side half of `50-ownership.sh` is weaker. The in-container half still
  applies, and you are still graded on the uid/gid design. If you develop on macOS,
  say so in your write-up and describe what would change on a Linux host.
- The suite needs `bash`, `curl`, `docker`, and `docker compose` v2. No `jq`.
- `docker compose down --volumes` between attempts. Cold boot is the whole point.
- If host port 8080 is already taken on your machine, publish elsewhere and tell the
  suite: `GATEWAY_URL=http://localhost:18080 ./scripts/acceptance/run-all.sh`. The
  service names are not negotiable; the port is.
- The suite reads a handful of knobs from the environment:
  `REQUESTS`, `CONCURRENCY` (stage 20), `SPIKES` (stage 30), `BUDGET_SECONDS` (stage 40).

Good luck. Read the logs before you read anything else.
