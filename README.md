# Longhorn V2 random-data stress (native Pods and PVCs)

This chart implements the **five workload parameters** from
[`harvester-csi-stress`](https://github.com/WebberHuang1118/harvester-csi-stress):

```yaml
parallel: 12
iterations: 3
dataVolumeCount: 1
dataVolumeSizeGiB: 100
dataSizeGiB: 30
```

| Option in reference repo | Helm value | Meaning |
|---|---|---|
| `--parallel 12` | `parallel: 12` | 12 Pod workers run concurrently |
| `--iterations 3` | `iterations: 3` | Each worker completes 3 write + verify rounds, sequentially |
| `--data-volume-count 1` | `dataVolumeCount: 1` | Each worker attaches 1 independent data PVC |
| `--data-volume-size-gib 100` | `dataVolumeSizeGiB: 100` | Each data PVC requests `100Gi` |
| `--data-size-gib 30` | `dataSizeGiB: 30` | Each PVC gets **30GiB per iteration** |

Each mounted PVC receives **6 parallel `dd` processes** by default (`write.workers: 6`), each
writing **5GiB of `/dev/urandom`** to its own file with `bs=1M conv=fsync`.
The script waits for all `dd` processes, calls `sync`, then runs `sha256sum -c` **after every volume write in every iteration**. A verified round is recorded with a persistent completion marker.
A non-divisible size is split between workers to preserve the total byte count. Any `dd` error, initial checksum error, or post-write `sha256sum -c` mismatch exits **non-zero**. With `restartPolicy: Never`, this produces a **Failed** Pod. After every round passes, the container exits **0**, producing a **Completed** Pod.

**Important differences from the reference repository:** This chart uses ordinary Kubernetes
Pods and PVCs, **not** Harvester VMs or backup/restore. Each Pod's iterations **reuse the same
PVC(s)** and **overwrite the same payload files**, instead of destroying/recreating a VM and
its storage each iteration. It performs write + checksum verification, but no snapshot/restore.
`iterations` does not increase the number of active volumes. It is *sequential write/verify
rounds* on the same existing volumes.

By default:
- Live resources: **12 Pods + 12 PVCs (100Gi each)**.
- Per round: **12 × 1 × 30GiB = 360GiB** written, plus checksum reads.
- Across 3 rounds: **1080GiB logical writes** (data files overwritten in place).
- Final payload kept: **30GiB per PVC**; completion state persists on the PVC.
- Source is random bytes, but file offsets are written sequentially. It is not random I/O.

## Deploy

An existing StorageClass named `longhorn-v2-fio` must use `dataEngine: "v2"`.

```bash
helm template random-stress-v3 ./longhorn-v2-random-write-chart-v3 | kubectl apply -f -
kubectl get pod,pvc -l app=random-stress-v3
kubectl logs -f random-stress-v3-w0
kubectl get pods -l app=random-stress-v3 -w
kubectl logs random-stress-v3-w0  # includes checksum verification results
```

Or install using Helm release management:

```bash
helm install random-stress-v3 ./longhorn-v2-random-write-chart-v3
# After collecting results (destructive: PVCs will be removed):
helm uninstall random-stress-v3
```

## Rerun and cleanup

After all rounds, Pods **exit 0** and display `Completed`. If any write or checksum verification fails, the Pod **exits 1** and displays `Error` / `Failed`. With `restartPolicy: Never`, it does **not** CrashLoopBackOff or automatically retry. Logs can still be inspected with `kubectl logs`; `kubectl exec` does not work after completion. A persisted
`/data/vol-N/random-stress/.last-completed-iteration` prevents repeating completed rounds
if the Pod is recreated; on resume, the previously written payload is **still re-verified**.
**Use new PVCs (e.g. a new `namePrefix`) to start a clean run.** If you change
sizes or worker counts, use new PVCs to avoid validating stale payload files.

To remove template-applied resources:

```bash
helm template random-stress-v3 ./longhorn-v2-random-write-chart-v3 | kubectl delete -f -
```

**Destructive:** Deleting PVCs can delete their Longhorn volumes and payload data if
`reclaimPolicy: Delete`. Ensure outputs are backed up before cleanup. If an older chart
created `random-v2-*` resources, they are independent and require separate cleanup.

## Notes

- Kubernetes may schedule multiple Pods on one Node; Pod creation is concurrent, but
  start times are not exactly synchronized.
- `/dev/urandom`, SHA-256 and page-cache I/O use CPU, so this is not an isolated IOPS
  benchmark. The write path is buffered I/O, not FIO direct I/O.
- Failure in one Pod does **not** stop other Pods (unlike reference script's cross-worker
  fail-fast coordination), because this uses standalone Pods, not a controller.

## Pod status and troubleshooting

```bash
kubectl get pods -l app=random-stress-v3
# Every successful worker eventually displays STATUS=Completed
kubectl logs random-stress-v3-w0
kubectl get pod random-stress-v3-w0 -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
```

- Exit code `0`: all configured iterations passed write and SHA-256 verification.
- Exit code `1` (or another nonzero code): write/checksum failed, Pod is Failed; see logs.
- Pods are standalone and do not retry automatically. Other Pods keep running if one fails.
- `helm upgrade` cannot modify an existing Pod's immutable `command`/`args` in place.
  For a fresh benchmark, use this chart's new default `namePrefix: random-stress-v3` and
  a new Helm release. Never `helm upgrade` a previous release solely to change Pod scripts: Helm
  may delete old named PVCs when they disappear from a release.
  **Do not uninstall the old release until you have saved any data you need** because
  uninstalling can also delete its PVCs and Longhorn volumes.

**Integrity scope:** like the reference repo, the script computes a SHA-256 digest
*after* writing each file, and then re-reads files to verify that digest. This catches
changes between hashing and verification, but does not independently prove that the
bytes persisted match their original random source. The read may be served from the
Linux page cache; `fsync`/`sync` ensures writes are requested to persistent storage.
