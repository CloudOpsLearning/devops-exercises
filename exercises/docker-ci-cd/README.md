# Kestrel Freight — Settlement API
## Containerisation & Delivery Exam

> **Format:** practical, open book, two parts. Part One is the image. Part Two is the pipeline that builds and publishes it to Docker Hub.
> **You will not be given a Dockerfile, a Compose file, or a pipeline.** Those are the exam.
> **You may not change the application source.** Its behaviour is the terrain.

---

# 🎯 DELIVERABLES

Everything below is required. A missing item is a missing mark — there is no partial
credit for "it worked on my machine".

### Part One — the image

| # | File | What it must do |
|---|------|-----------------|
| **D1** | `Dockerfile` | Multi-stage, named stages, at minimum a `development` target and a `production` target. Builds the Maven **multi-module** project. Runs as a non-root user. Exec-form `ENTRYPOINT`. Pinned base images. Accepts exactly two build args: `BUILD_REVISION`, `BUILD_VERSION`. |
| **D2** | `.dockerignore` | Keeps `target/`, `.git`, `.env` and local noise out of the build context. |
| **D3** | `compose.yaml` | Services named **`db`**, **`migrator`**, **`api`**. The database publishes nothing. The API publishes `8080` only. Read-only root filesystem, explicit memory limit, healthchecks, dependency ordering. `.env` supplies every credential. |
| **D4** | `.env` | Real values, gitignored, never committed. |

### Part Two — the pipeline

| # | File | What it must do |
|---|------|-----------------|
| **D5** | `.github/workflows/*.yml` **or** `.gitlab-ci.yml` | Build → unit test → **integration test (needs a container runtime)** → build image for `linux/amd64` **and** `linux/arm64` → scan → publish to Docker Hub. Conditional publishing, immutable tags, cached layers, credentials from the secret store. |
| **D6** | A real Docker Hub repository | At least one published tag, multi-architecture, non-root, OCI-labelled with the commit it was built from. |
| **D7** | `EVIDENCE.md` | Links the pipeline run, records the image reference **and its digest**, pastes the multi-arch and scan output, and answers the six questions in §8. Copy `EVIDENCE.template.md` to start. |

### Definition of done

```bash
cd exercises/docker-ci-cd
chmod +x scripts/acceptance/*.sh
IMAGE_REF=docker.io/<you>/settlement-api:<tag> ./scripts/acceptance/run-all.sh
```

All six stages green, `EVIDENCE.md` complete, and none of the automatic fails in §9
triggered.

---

## 1. The scenario

Kestrel Freight runs 4,000 owner-driver vehicles across six countries. Every trip, fee,
fine and bonus lands in one append-only table, and on the 1st of every month the finance
team exports it and pays 4,000 people. The service that owns that table is
`settlement-api`.

It has never been containerised. Here is the last quarter, from the incident channel:

| When | What happened |
|------|---------------|
| **Mar 3** | A release is cut as `settlement-api-2.3-FINAL-v2.jar`, built on the tech lead's laptop and copied to the VM with `scp`. Nobody can say which commit it came from. |
| **Mar 14** | A payout webhook is retried by the provider. 212 drivers are paid twice. The unique index that prevents it exists in the code, but the migration that creates it was never applied to production — the deploy script runs the JAR, and the JAR does not migrate. |
| **Apr 2** | Month-end. The reconciliation export dies. The container was given 512Mi; the JVM helpfully took 25% of that as its heap ceiling and OOMed at 128Mi. Somebody bumps the limit to 4Gi "to be safe" and moves on. |
| **Apr 19** | The new hire builds the first image on an M3 laptop and pushes it. Production is amd64. `exec format error`. The rollback takes 40 minutes because nobody knows which tag was previously good. |
| **May 7** | A CI job pushes `:latest` from a feature branch. The 03:00 autoscaler pulls it into production. |
| **May 21** | An engineer re-tags `1.4.2` to fix "one small thing". The audit trail now says the artifact finance signed off on is a different artifact from the one running. External auditors escalate. |
| **Jun 4** | Someone notices the Docker Hub repository is public and `docker history` on the published image shows `--build-arg DB_PASSWORD=...`. The password is rotated at 02:00 on a Sunday. |
| **Jun 11** | A deploy interrupts a settlement run mid-flight. The payout provider moved the money; no ledger row exists on our side. Two people spend a weekend reconciling by hand. |
| **Jun 30** | Security signs off on containers **on conditions**: non-root, read-only root filesystem, no credentials in image layers, an SBOM per release, and no HIGH/CRITICAL vulnerabilities shipped knowingly. |

**Your job:** make containers the answer to all nine rows. Every one of them is
reproducible in this repository, and every one of them is fixed in configuration and
pipeline code — never in the application.

---

## 2. What you have been handed

```
docker-ci-cd/
├── pom.xml                     parent POM. Two modules. This matters more than it looks.
├── settlement-core/            domain module: entities, repository, no web layer
├── settlement-api/             Spring Boot application
│   ├── src/main/java/…         API, readiness indicators, migration entrypoint
│   ├── src/main/resources/
│   │   ├── application.yml     every credential comes from the environment
│   │   └── db/migration/       V1, V2, V3 — the schema contract
│   └── src/test/java/…         unit tests + one integration suite
├── scripts/acceptance/         the grading suite. Read it; it is not a black box.
├── .env.example                every variable the application reads
├── EVIDENCE.template.md        copy to EVIDENCE.md
└── README.md                   this brief
```

**Java 21, Spring Boot 3.3, Maven, PostgreSQL 16, Flyway.** There is no Maven wrapper in
the repository — deciding where Maven comes from is part of Part One.

### Three things about this application

**It is one artifact with two jobs.** `java -jar app.jar --migrate` applies the schema
and exits. Without that flag the same jar serves HTTP and never touches the schema.
Twelve replicas booting at once must not each try to own the database.

**It refuses to lie about itself.** With no `SETTLEMENT_ENVIRONMENT` it will not start.
Without a real `BUILD_REVISION` baked in, it starts but reports itself **out of service** —
the readiness group includes a build-provenance check. An artifact finance cannot trace
to a commit is not allowed to take traffic.

**Its tests are not all the same.** `*Test` classes are pure unit tests. `SettlementApiIT`
starts a real PostgreSQL with Testcontainers, applies the real migrations, and exercises
the real unique index. It needs a container runtime to talk to. Where that suite runs is
one of the decisions this exam is about.

---

## 3. Rules of engagement

**You may not modify** anything under `settlement-core/src`, `settlement-api/src`, the
`pom.xml` files, or `scripts/acceptance/`. If the application does something
inconvenient, that is the exam, not a bug.

**You may create** Dockerfiles, Compose files, `.env`, `.dockerignore`, entrypoint
scripts, pipeline definitions, Maven `settings.xml`, and any documentation.

**You may set** any environment variable or JVM flag the application reads. Picking the
numbers is the work; you will be asked to defend them.

---

## 4. Part One — the image

### Hard constraints

1. **The build context problem is yours to solve.** This is a multi-module Maven build:
   `settlement-api` cannot compile without the parent POM and `settlement-core`.
2. **The test phase must not run inside `docker build`.** The integration suite needs a
   container runtime; a builder does not have one. Do not "fix" that by disabling tests
   in the pipeline.
3. **A one-line source change must not re-download the internet.** The suite measures a
   cold build, touches one `.java` file, rebuilds, and compares.
4. **Ship the application unpacked, not as one 60MB fat jar.** Spring Boot can list and
   extract its own layers; find out how. The suite counts jar files inside the image.
5. **`≤ 450MiB`** for the runtime image, and no Maven, no source, no `.m2` inside it.
6. **Non-root**, exec-form `ENTRYPOINT`, base images pinned to a tag or digest.
7. **Both architectures.** `docker buildx build --platform linux/amd64,linux/arm64` must
   succeed. A base image or a downloaded JDK that only exists for x86_64 fails this.
8. **Build interface, exactly two arguments:** `BUILD_REVISION` (full git sha) and
   `BUILD_VERSION` (semver). They must end up in **both** the OCI labels and the running
   application's `/api/v1/runtime`. No secret may ever be a build argument.
9. **The migration job runs the same image.** `docker run <image> --migrate` must work,
   and Compose must run it as a one-shot before the API starts.
10. **Read-only root filesystem** with a writable temp directory — Tomcat needs one.
11. **Memory:** an explicit container limit, and a JVM heap ceiling sized against it. The
    default is 25%; the suite requires between 50% and 90% and a `192MiB` report to
    complete without an `OutOfMemoryError`.
12. **Graceful shutdown:** a settlement run already in flight must finish. `docker stop`
    must return within 12s, and the log must contain `graceful shutdown complete`.
13. **Private management port.** The API publishes `8080`; actuator lives on `9090` and
    must not be published or reachable on `8080`.
14. **The database publishes nothing.** Not even to `127.0.0.1`.

### Checklist

**Image construction**
- [ ] Multi-stage, named stages; `development` and `production` targets
- [ ] Dependency resolution in its own cached layer, invalidated only by POM changes
- [ ] Layered application extraction (dependencies, loader, snapshot, application)
- [ ] Production stage contains a JRE and the application — nothing else
- [ ] Non-root user with a deliberate uid/gid; exec-form entrypoint
- [ ] Pinned bases; `.dockerignore` that keeps the context small
- [ ] OCI labels: `revision`, `version`, `source`, `title`, `created`

**Runtime**
- [ ] Read-only root filesystem plus a tmpfs for temp files
- [ ] Memory limit set, and the JVM told about it
- [ ] Container healthcheck that uses **readiness**, not "is the port open"
- [ ] `db` healthcheck; `migrator` waits for it; `api` waits for the migration to
      **complete successfully** — three different conditions, used correctly
- [ ] The migrator does not restart in a loop
- [ ] Credentials from `.env`/secrets, never in an image or a committed file

---

## 5. Part Two — the pipeline

Build and publish `settlement-api` to **Docker Hub**. GitHub Actions or GitLab CI; the
suite grades either.

### Hard constraints

1. **Tests run in the pipeline, both kinds.** Unit tests and the Testcontainers suite.
   The runner needs a Docker daemon for the second one.
2. **Multi-architecture publish:** one tag that resolves to a manifest list containing
   `linux/amd64` and `linux/arm64`.
3. **What you scan is what you publish.** The vulnerability scan must run against the
   **same digest** that reaches Docker Hub — not a convenient single-arch rebuild. Work
   out how to do that with buildx; there is more than one correct answer.
4. **The scan can fail the build.** A scan whose result nobody acts on is decoration.
5. **Tags are immutable.** The pipeline must refuse to publish over an existing tag.
   `1.4.2` must mean one artifact forever.
6. **Every image is addressable by commit,** and the commit is baked in via
   `BUILD_REVISION`.
7. **`latest` is a release decision.** It may never be published from a feature branch.
8. **Pull requests build and test but do not publish.**
9. **Credentials come from the CI secret store**, are never echoed, never appear on a
   command line, and are never a build argument. Docker Hub access tokens — not your
   account password.
10. **Layer cache between runs**, and a cached Maven repository.
11. **An SBOM per published image**, kept as an artifact.
12. **Least privilege and bounded jobs**: explicit permissions, concurrency control,
    timeouts.

### Checklist

- [ ] Triggers: PR → build + test only; main → publish sha-addressed tags; version tag → publish semver (+ `latest`)
- [ ] `buildx` with QEMU or native multi-arch builders, cache wired to the CI cache backend
- [ ] Build args `BUILD_REVISION` and `BUILD_VERSION` plumbed from the CI context
- [ ] Digest captured as a job output and reused by every later step
- [ ] Scan gate on HIGH/CRITICAL with a documented, deliberate ignore policy
- [ ] Tag-existence check before publish
- [ ] SBOM generated and uploaded
- [ ] The published digest written into the job summary/log so a human can find it later
- [ ] No step can succeed while shipping an untested, unscanned, or unlabelled artifact

---

## 6. Contracts

### Build arguments

| Argument | Meaning |
|---|---|
| `BUILD_REVISION` | Full git commit sha. Ends up in `org.opencontainers.image.revision` **and** in the running app. |
| `BUILD_VERSION` | Semantic version of the release. Ends up in `org.opencontainers.image.version` **and** in the running app. |

Stage `10-image.sh` builds the image itself and passes `BUILD_REVISION=$(git rev-parse HEAD)`.
Stage `20-runtime.sh` builds through **your** Compose file and then checks that the running
service reports that same commit — so whatever mechanism you use to get the revision into a
`compose build` has to produce the current `git rev-parse HEAD` at the moment the suite runs.
A value pasted into `.env` by hand will be stale by your next commit.

### Environment (read by the application)

| Variable | Notes |
|---|---|
| `SETTLEMENT_DB_URL`, `SETTLEMENT_DB_USER`, `SETTLEMENT_DB_PASSWORD` | Required. Also required by the `--migrate` job. |
| `SETTLEMENT_ENVIRONMENT` | Required, no default. Boot fails without it. |
| `SETTLEMENT_BUILD_REVISION`, `SETTLEMENT_BUILD_VERSION` | Provenance as seen by the process. Defaults are `unknown`/`0.0.0-dev`, and `unknown` keeps the service out of service. |
| `SETTLEMENT_EXPECTED_SCHEMA_VERSION` | Default `3` — the version `db/migration` produces. |
| `SETTLEMENT_HTTP_PORT` / `SETTLEMENT_MANAGEMENT_PORT` | Default `8080` / `9090`. |
| `SETTLEMENT_REPORT_MB`, `SETTLEMENT_REPORT_MAX_MB` | Month-end report sizing. |
| `SETTLEMENT_DB_POOL_SIZE`, `SETTLEMENT_LOG_LEVEL` | Tuning. |

### HTTP surface

| Method | Path | Port | Purpose |
|---|---|---|---|
| `POST` | `/api/v1/entries` | 8080 | Write an entry. `201` created, `200` idempotent replay. |
| `GET` | `/api/v1/entries` | 8080 | Recent entries. |
| `GET` | `/api/v1/accounts/{id}/balance` | 8080 | Computed balance in minor units. |
| `GET` | `/api/v1/batches/{batchId}/count` | 8080 | Entries written for a batch. |
| `POST` | `/api/v1/reports/monthly` | 8080 | Month-end reconciliation. Memory-heavy on purpose. |
| `POST` | `/api/v1/settlements/run` | 8080 | Holds a request open for `seconds`, then writes. The shutdown test. |
| `GET` | `/api/v1/runtime` | 8080 | Heap ceiling, JVM args, pid, provenance, whether `/` is writable. **Read this first.** |
| `GET` | `/actuator/health/liveness` | 9090 | Liveness. |
| `GET` | `/actuator/health/readiness` | 9090 | Readiness: database + schema contract + build provenance. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Clean exit (including a handled `SIGTERM` on some JVM/entrypoint combinations) |
| `1` | Boot failed — usually missing required configuration or an unreachable database |
| `64` | `--migrate` was asked to run with no database configuration |
| `70` | `--migrate` could not connect, and does not retry by design |
| `72` | A migration failed |
| `137` | `SIGKILL`: the kernel OOM-killed it, or a stop timeout ran out |
| `143` | The JVM terminated on a handled `SIGTERM` |

---

## 7. The acceptance suite

```bash
cd exercises/docker-ci-cd
cp .env.example .env && cp EVIDENCE.template.md EVIDENCE.md   # then fill both in
chmod +x scripts/acceptance/*.sh
./scripts/acceptance/run-all.sh
```

| Stage | What it does |
|---|---|
| `00-preflight.sh` | Static: deliverables exist, Dockerfile structure, pinned bases, no credentials, `.dockerignore` content, compose topology, management port unpublished. |
| `10-image.sh` | Builds cold, then rebuilds after touching one source file. Grades size, user, entrypoint, labels, `docker history`, image contents via `docker export`, fat-jar detection, `--migrate` wiring, layer reuse, and a real `linux/amd64,linux/arm64` build. |
| `20-runtime.sh` | `compose down -v` then `up`. Grades migration-as-a-job (same image, exit 0), zero API restarts, readiness contents, actuator not public, non-root process, read-only rootfs with writable temp, provenance matching the commit, and correct ledger behaviour including idempotent replay. |
| `30-resilience.sh` | Heap-to-limit ratio, a `192MiB` report without OOM, then a settlement run interrupted by `docker stop`: the in-flight request must return `200`, the stop must be under 12s, and the row must be in the ledger afterwards. |
| `40-pipeline.sh` | Reads your pipeline: both test kinds, buildx, both platforms, cache, provenance args, secret handling, tag discipline, immutability check, scan gate, digest reuse, SBOM, hygiene. |
| `50-registry.sh` | With `IMAGE_REF` set: inspects Docker Hub for a multi-arch manifest list, non-root config, OCI labels, digest matching `EVIDENCE.md`, and what `:latest` points at. Also grades `EVIDENCE.md` itself. |

Useful knobs: `API_URL`, `IMAGE`, `IMAGE_MAX_MB`, `REPORT_MB`, `BUILD_VERSION`, `IMAGE_REF`.

The suite pulls a small `curl` image to probe the private management port from inside the
container network, because your application image is not required to contain a shell.

---

## 8. EVIDENCE.md — the six questions

Copy `EVIDENCE.template.md`, keep its headings, and answer these in it:

1. **Nine rows, nine fixes.** For each row of the §1 timeline: the mechanism, the
   configuration or pipeline code that fixes it, and the alternative you rejected.
2. **The memory arithmetic.** Write the relationship between the container limit, the JVM
   heap ceiling, non-heap memory, and the `192MiB` report — with your numbers substituted
   in. Explain the headroom.
3. **Scan-then-publish.** Explain exactly how the digest you scanned is the digest you
   published, with the commands or actions that make it true.
4. **Ordering.** Explain the three dependency conditions you used in Compose and why each
   edge got the one it did. Then: what breaks if the migration job fails halfway?
5. **Tag strategy.** What tags exist, which are immutable, what `latest` means in your
   scheme, and how the pipeline enforces it.
6. **What you would not ship.** One thing in your own solution that is fine for this exam
   and not fine in production, and what you would do instead.

---

## 9. Scoring

| Weight | Dimension |
|---|---|
| 30% | Stages `00`–`30`: the image and the running system |
| 25% | Stages `40`–`50`: the pipeline and what actually reached Docker Hub |
| 25% | Dockerfile and Compose quality: staging, caching, layer discipline, resource and dependency modelling |
| 20% | `EVIDENCE.md`: the reasoning, not the result |

**Automatic fails, whatever the suite says:** a credential in any committed file, image
layer, or `docker history`; a published Postgres port; a container running as root; a
single-architecture published image; `latest` publishable from a branch; tests skipped or
deleted to make the pipeline green; any edit to application source or to the acceptance
suite; `:latest` base images; a runtime `chown -R`/`chmod 777` used to dodge the
read-only filesystem.

### Known failure signatures

Symptoms only. The diagnosis is the exam.

| What you will see |
|---|
| `Could not find artifact com.kestrel.settlement:settlement-core:pom:1.4.2` during `docker build` |
| `Cannot invoke "…DockerClient"` / `Could not find a valid Docker environment` in a build stage |
| Every rebuild prints hundreds of `Downloading from central:` lines |
| `exec format error` when production pulls your image |
| `Caused by: java.lang.IllegalStateException: Failed to bind properties under 'settlement.environment'` |
| Readiness returns `503` with `"buildProvenance":{"status":"OUT_OF_SERVICE"}` |
| Readiness returns `503` with `"appliedVersion":0` |
| `java.lang.OutOfMemoryError: Java heap space` during the month-end report, with `maxHeapMb` at exactly a quarter of the container limit |
| The container exits `137` and `OOMKilled=true` |
| The container exits `137` exactly 10 seconds after `docker stop`, `OOMKilled=false` |
| `Unable to create tempDir. java.io.tmpdir is set to /tmp` … `Read-only file system` |
| `docker history` shows a password in a `--build-arg` |
| `denied: requested access to the resource is denied` from your pipeline's push step |
| The pipeline pushes, and `docker buildx imagetools inspect` shows exactly one platform |

---

## 10. Platform notes

- Docker with buildx, `docker compose` v2, `bash`, `curl`, `git`. No `jq`, no local Java
  or Maven required — the build happens in containers.
- Apple Silicon or amd64 both work for development. That asymmetry is the point of §5.2.
- A free Docker Hub account and an **access token** (not your password) are required for
  Part Two.
- `docker compose down -v` between attempts. The cold-start path is graded.
- If host port 8080 is taken, publish elsewhere and tell the suite:
  `API_URL=http://localhost:18080 ./scripts/acceptance/run-all.sh`.

Read the logs before you read anything else. `GET /api/v1/runtime` answers most of the
memory questions on its own.
