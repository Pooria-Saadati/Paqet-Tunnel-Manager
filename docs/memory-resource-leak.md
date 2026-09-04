# Paqet memory/resource accumulation investigation

## Observed failure mode

On a long-running client with an unstable remote path, repeated reconnects were followed by large growth in process resources:

- PACKET sockets
- ~8 MiB mappings associated with those packet sockets
- file descriptors
- polling threads
- RSS/PSS

A real reproduction showed the following progression:

| State | RSS | Threads | FDs | PACKET sockets | ~8 MiB mappings |
| --- | ---: | ---: | ---: | ---: | ---: |
| Immediately after service restart | ~77 MiB | 12 | 23 | low/baseline | low/baseline |
| After 26 reconnects | ~151 MiB | 20 | 39 | 16 | 16 |
| Before host memory pressure | ~1.09 GiB | 147 | 269 | 128 | 128 |

The 128 mappings accounted for roughly 1,029,120 KiB of resident mapped memory (about 8,040 KiB each).

This is different from a typical Go heap-only leak: most of the abnormal resident memory was file-backed packet mapping memory rather than `RssAnon`.

### Important refinement: accumulation is not strictly monotonic

Live guard validation on 2026-09-04 showed that some packet resources can be released later rather than remaining permanently leaked.

Two samples five seconds apart showed:

| Metric | Sample A | Sample B | Delta |
| --- | ---: | ---: | ---: |
| PACKET sockets | 20 | 19 | -1 |
| ~8 MiB mappings | 20 | 19 | -1 |
| mapped RSS | 160,800 KiB | 152,760 KiB | -8,040 KiB |
| FDs | 47 | 45 | -2 |
| RSS | 183,868 KiB | 175,828 KiB | about -8,040 KiB |

This means the safest current description is **packet-resource cleanup backlog/accumulation under reconnect churn**, not a claim that every created resource is permanently leaked.

The working hypothesis is that reconnect/error paths can create new packet resources faster than old resources are closed/unmapped. Under sustained churn, the outstanding resource count can grow to a host-impacting level. This is consistent with the earlier 128 PACKET sockets / 128 mappings / ~1 GiB state, while also explaining why an individual socket/mapping can disappear later.

A separate live sample also demonstrated the growth event directly:

```text
PACKET sockets: 18 -> 19
~8 MiB mappings: 18 -> 19
mapped RSS: 144,720 KiB -> 152,760 KiB
FDs: 43 -> 45
RSS: 167,640 KiB -> 175,680 KiB
```

That single event added one PACKET socket, one ~8,040 KiB mapping, two FDs and ~8,040 KiB process RSS.

## Three-tunnel control comparison

The Iran host runs three Paqet clients with the same custom core. Report-only guard samples taken within the same minute produced:

| Tunnel | Reconnects | PACKET sockets | ~8 MiB mappings | mapped RSS | FDs | Threads | RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Finland | 61 | 22 | 22 | 176,880 KiB | 51 | 27 | 200,572 KiB |
| Germany | 0 | 8 | 8 | 64,320 KiB | 23 | 12 | 83,088 KiB |
| Italy | 0 | 8 | 8 | 64,320 KiB | 23 | 13 | 80,928 KiB |

Germany and Italy independently establish an empirical healthy baseline of 8 PACKET sockets, 8 packet mappings and 23 FDs for the current configuration/build.

Compared with that baseline, Finland had:

```text
+14 PACKET sockets
+14 ~8 MiB mappings
+112,560 KiB mapped RSS  (14 * 8,040 KiB)
+28 FDs                  (2 per extra packet resource)
+14 to +15 threads
~117 to ~120 MiB additional process RSS
```

This is strong evidence that the Finland reconnect path is associated with outstanding packet resources. It does **not** prove that every reconnect permanently leaks a resource; earlier samples show delayed cleanup can reduce the outstanding count. The relevant failure condition is sustained net accumulation/backlog.

The baseline count of 8 is also consistent with the configured connection count of 4 and a send/receive packet-handle pair per connection, but the guard does not depend on that implementation assumption.

## Reconnect correlation

The affected optimized build logged repeated successful reconnects while the guard observed elevated outstanding PACKET sockets/mappings. Recent journal data repeatedly showed the sequence:

```text
health check failed (1/4)
health check failed (2/4)
health check failed (3/4)
health check failed (4/4)
exceeded health-check failures, reconnecting
reconnected successfully
```

Some failures changed from `strm ping read failed: timeout` to `io: read/write on closed pipe` before reconnect.

The guard records `reconnects=` alongside process resource metrics so this relationship can be measured without modifying Paqet itself.

## Host impact

On a small VPS with no swap, the accumulation eventually pushed the host into memory pressure. Historical `sar` and journal data showed:

- `systemd-journald: Under memory pressure, flushing caches`
- very low available memory
- aggressive page scanning/reclaim
- disk utilization above 90%
- very high disk await
- iowait around 75-80%
- Docker/containerd health-check timeouts
- SSH broken pipes
- Paqet health-check timeouts and reconnects

This can create a feedback loop: resource accumulation increases host latency, which causes more tunnel health-check failures, which can cause more reconnect activity.

## Related upstream history

The upstream Paqet project has had previous reports of memory growth when the remote connection is lost under load. Newer upstream releases also changed buffer allocation and packet-connection lifecycle management.

For this fork, the current custom `v2.2.0-optimized-Behzad` binary must not be treated as a trusted default until it has source provenance and the accumulation behavior is proven fixed. The preferred migration target for testing is the official upstream `v1.0.0-alpha.21` release, with both ends upgraded together when protocol compatibility requires it.

## Resource guard

`scripts/paqet-resource-guard.sh` is a mitigation and diagnostics tool. It is not a core fix.

It measures:

- process RSS
- thread count
- FD count
- PACKET socket count (`ss -0ap`)
- count and RSS of ~8 MiB mappings (`pmap -x`)
- successful reconnect count since service activation

When a threshold is breached it writes a diagnostic snapshot under:

```text
/var/log/paqet-resource-guard/
```

The script defaults to report-only mode when run manually. The supplied systemd template explicitly opts into restart mode.

Default restart thresholds:

```text
PACKET sockets >= 32
RSS >= 512 MiB
Threads >= 64
FDs >= 128
Cooldown = 10 minutes
```

With the observed healthy PACKET baseline of 8, a threshold of 32 allows transient cleanup backlog while still acting far below the previously observed 128-socket / ~1 GiB failure state.

## Install the guard for one existing service

Example target:

```text
paqet-finland01-1331-6000.service
```

Install files:

```bash
sudo install -D -m 0755 scripts/paqet-resource-guard.sh \
  /usr/local/libexec/paqet-resource-guard

sudo install -D -m 0644 systemd/paqet-resource-guard@.service \
  /etc/systemd/system/paqet-resource-guard@.service

sudo install -D -m 0644 systemd/paqet-resource-guard@.timer \
  /etc/systemd/system/paqet-resource-guard@.timer

sudo systemctl daemon-reload
```

Run one non-destructive report first:

```bash
sudo PAQET_GUARD_ACTION=report \
  /usr/local/libexec/paqet-resource-guard \
  paqet-finland01-1331-6000.service
```

The systemd template instance is the target unit name **without** the `.service` suffix. Enable the five-minute guard timer only for Finland with:

```bash
sudo systemctl enable --now \
  paqet-resource-guard@paqet-finland01-1331-6000.timer
```

The guard service then invokes the target `paqet-finland01-1331-6000.service`.

Inspect it with:

```bash
systemctl status \
  paqet-resource-guard@paqet-finland01-1331-6000.timer

journalctl -u \
  paqet-resource-guard@paqet-finland01-1331-6000.service \
  --no-pager

journalctl -t paqet-resource-guard --since today

ls -lh /var/log/paqet-resource-guard/
```

Disable it with:

```bash
sudo systemctl disable --now \
  paqet-resource-guard@paqet-finland01-1331-6000.timer
```

Do not enable the timer for Germany or Italy during the Finland A/B test. They are useful control tunnels.

## A/B validation for a new core

The most important acceptance criterion is bounded resources even during reconnects.

A candidate core passes this regression test when reconnect count can rise while the following remain bounded and return toward baseline after transient reconnect bursts:

```text
PACKET sockets
~8 MiB mappings
FDs
Threads
RSS/PSS
```

The test should be performed first on the problematic Finland tunnel, with the same connection count and MTU where possible, so the core version is the primary changed variable. Germany and Italy should remain unchanged as controls during the test.
