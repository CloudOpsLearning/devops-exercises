# Settlement API — delivery evidence

Copy this file to `EVIDENCE.md` and fill it in. Keep the headings: stage `50-registry.sh`
reads them. Remove every `TODO` — the suite fails while any placeholder remains.

## Image

- Docker Hub repository: TODO
- Published tags: TODO
- Immutable reference (tag@digest): TODO
- Digest: `sha256:TODO`
- Base image (pinned): TODO
- Final image size: TODO

## Pipeline run

- Pipeline definition: TODO (path in this repo)
- Successful run that produced the image above: TODO (full URL)
- Duration, and where the time goes: TODO
- What the pipeline does on a pull request, on a merge to the main branch, and on a
  version tag: TODO

## Multi-architecture proof

Paste the output of `docker buildx imagetools inspect <tag>`:

```
TODO
```

## Vulnerability scan

- Scanner and version: TODO
- Gate: which severities fail the build, and what is ignored on purpose: TODO
- Result for the published digest (summary):

```
TODO
```

- **How the digest that was scanned is the digest that was published:** TODO

## Tag strategy and immutability

- Tags produced, and by which trigger: TODO
- What `latest` means here, and what prevents it being published from a branch: TODO
- How the pipeline refuses to overwrite an existing tag: TODO

## The nine failures

One row per incident from the README timeline: mechanism, the fix, the rejected
alternative.

| Incident | Mechanism | Fix (file + setting) | Rejected alternative |
|---|---|---|---|
| Mar 3 untraceable jar | TODO | TODO | TODO |
| Mar 14 double payout | TODO | TODO | TODO |
| Apr 2 month-end OOM | TODO | TODO | TODO |
| Apr 19 exec format error | TODO | TODO | TODO |
| May 7 latest from a branch | TODO | TODO | TODO |
| May 21 re-tagged release | TODO | TODO | TODO |
| Jun 4 password in layers | TODO | TODO | TODO |
| Jun 11 interrupted settlement | TODO | TODO | TODO |
| Jun 30 security conditions | TODO | TODO | TODO |

## Memory arithmetic

- Container limit: TODO
- JVM heap ceiling, and the flag that sets it: TODO
- Non-heap allowance (metaspace, code cache, thread stacks, direct buffers): TODO
- Report size the service must survive: TODO
- The inequality, with numbers: TODO
- Headroom left, and why that much: TODO

## Ordering

- The dependency conditions used between `db`, `migrator` and `api`, and why each edge got
  the one it did: TODO
- What happens if the migration job fails halfway through: TODO

## What I would not ship

- Acceptable here, not acceptable in production: TODO
- What I would do instead: TODO
