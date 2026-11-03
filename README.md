# Longhorn V2 random-data stress (native Pods and PVCs)

This chart implements the **five workload parameters** from
[`harvester-csi-stress`](https://github.com/WebberHuang1118/harvester-csi-stress):

```yaml
parallel: 12
iterations: 100
dataVolumeCount: 1
dataVolumeSizeGiB: 200
dataSizeGiB: 30
```

| Option in reference repo | Helm value | Meaning |
|---|---|---|
| `--parallel 12` | `parallel: 12` | 12 Pod workers run concurrently |
| `--iterations 100` | `iterations: 100` | Each worker completes 100 write + verify rounds, sequentially |
| `--data-volume-count 1` | `dataVolumeCount: 1` | Each worker attaches 1 independent data PVC |
| `--data-volume-size-gib 200` | `dataVolumeSizeGiB: 200` | Each data PVC requests `200Gi` |
| `--data-size-gib 30` | `dataSizeGiB: 30` | Each PVC gets **30GiB per iteration** |

Each mounted PVC receives **one buffered `dd` process** by default (`write.workers: 1`),
writing **30GiB of `/dev/urandom`** to one file with `bs=1M conv=fsync status=none`.
Each writer calls `sync` before computing its SHA-256 digest, matching the reference
script's data-disk write order. There is no direct I/O or periodic chunk flush.
`write.workers > 1` remains available as an extension, but changes the workload from
the reference's single writer per disk.
The script waits for all `dd` processes, calls `sync`, then runs `sha256sum -c` **after every volume write in every iteration**. A verified round is recorded with a persistent completion marker.
A non-divisible size is split between workers to preserve the total byte count. Any `dd` error, initial checksum error, or post-write `sha256sum -c` mismatch exits **non-zero**. With `restartPolicy: Never`, this produces a **Failed** Pod. After every round passes, the container exits **0**, producing a **Completed** Pod.

**Important differences from the reference repository:** This chart uses ordinary Kubernetes
Pods and PVCs, **not** Harvester VMs or backup/restore. Each Pod's iterations **reuse the same
PVC(s)** and **overwrite the same payload files**, instead of destroying/recreating a VM and
its storage each iteration. It performs write + checksum verification, but no snapshot/restore.
`iterations` does not increase the number of active volumes. It is *sequential write/verify
rounds* on the same existing volumes.

By default:
- Live resources: **12 Pods + 12 PVCs (200Gi each)**.
- Per round: **12 × 1 × 30GiB = 360GiB** written, plus checksum reads.
- Across 100 rounds: **36000GiB logical writes** (data files overwritten in place).
- Final payload kept: **30GiB per PVC**; completion state persists on the PVC.
- Source is random bytes, but file offsets are written sequentially. It is not random I/O.

## Deploy

An existing StorageClass named `longhorn-v2-replicated` must use `dataEngine: "v2"`.

```bash
helm template stress . | kubectl apply -f -
kubectl get pod,pvc -l app=io-stress
kubectl logs -f io-stress-w0
kubectl get pods -l app=io-stress -w
kubectl logs io-stress-w0  # includes checksum verification results
```

Or install using Helm release management:

```bash
helm install stress .
# After collecting results (destructive: PVCs will be removed):
helm uninstall stress
```

## Rerun and cleanup

After all rounds, Pods **exit 0** and display `Completed`. If any write or checksum verification fails, the Pod **exits 1** and displays `Error` / `Failed`. With `restartPolicy: Never`, it does **not** CrashLoopBackOff or automatically retry. Logs can still be inspected with `kubectl logs`; `kubectl exec` does not work after completion. A persisted
`/data/vol-N/random-stress/.last-completed-iteration` prevents repeating completed rounds
if the Pod is recreated; on resume, the previously written payload is **still re-verified**.
**Use new PVCs (e.g. a new `namePrefix`) to start a clean run.** If you change
sizes or worker counts, use new PVCs to avoid validating stale payload files.

To remove template-applied resources:

```bash
helm template stress . | kubectl delete -f -
```

**Destructive:** Deleting PVCs can delete their Longhorn volumes and payload data if
`reclaimPolicy: Delete`. Ensure outputs are backed up before cleanup. If an older chart
created `random-v2-*` resources, they are independent and require separate cleanup.

## Notes

- Kubernetes may schedule multiple Pods on one Node; Pod creation is concurrent, but
  start times are not exactly synchronized.
- `/dev/urandom`, SHA-256 and page-cache I/O use CPU, so this is not an isolated IOPS
  benchmark. Both writes and SHA-256 reads use buffered I/O, like the reference.
- Failure in one Pod does **not** stop other Pods (unlike reference script's cross-worker
  fail-fast coordination), because this uses standalone Pods, not a controller.

## Memory pressure and OOMKilled

The default container memory request and limit are both `4Gi`, configurable through
`resources`. This follows the reference README's **example** `--memory 4Gi` and its
VM configuration with equal memory requests and limits. Upstream requires an explicit
`--memory`; it has no default memory size. A Pod container and a VM guest have different
memory accounting, so equal quantities do not make the environments equivalent.

**12 Pods request 48Gi in total**, in addition to Longhorn and other node services.
If nodes lack allocatable memory, some Pods will remain Pending. Choose memory sizing
based on available cluster capacity and measured usage. The reference comparison is
pinned to [commit 76b454d](https://github.com/WebberHuang1118/harvester-csi-stress/blob/76b454d58be5836619957fcef25b63fce2934e3a/scripts/harvester-csi-stress-test)
(`write_guest_payload`, sequential data-disk loop, and VM resources).

The earlier chart used 6 writers per Pod with a `2Gi` memory limit. `OOMKilled` alone
does not prove whether it hit that limit or encountered node-wide OOM. Buffered page
cache is included in cgroup memory accounting
([kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html));
clean cache can be reclaimed. Neither a large payload nor buffered I/O alone proves
an OOM cause. One writer and a larger memory budget may reduce pressure, but do not
guarantee that node or container OOM cannot occur.

Collect evidence before deleting an OOMKilled Pod:

```bash
kubectl describe pod io-stress-w7
kubectl logs io-stress-w7 > io-stress-w7.log
kubectl get pod io-stress-w7 -o wide
kubectl top pods --containers
kubectl top nodes
# Inspect the affected node's kernel OOM logs to distinguish node OOM from
# a container memory-limit OOM; metrics-server is needed for kubectl top.
```

Existing standalone Pods cannot receive changed scripts through `helm upgrade`.
To test the new defaults on fresh PVCs, install with a new release and name prefix
(this starts an additional workload; account for other workers still running):

```bash
helm install stress-oomfix . --set namePrefix=io-stress-oomfix
```

To resume only worker 7 on its existing PVC, preserve its logs, render only its
new Pod definition, then recreate that failed Pod. The example uses Mike Farah's
`yq` v4. Use the same original workload values, including volume count, sizes,
and worker count. The command below preserves `write.workers=6` for the existing run; switching
it to one writer requires fresh PVCs. It does not delete PVCs or change the other running Pods:

```bash
helm template stress . --set write.workers=6 | yq 'select(.kind == "Pod" and .metadata.name == "io-stress-w7")' > /tmp/io-stress-w7.yaml
# Check that the rendered file contains the intended Pod before deleting it.
kubectl delete pod io-stress-w7
kubectl create -f /tmp/io-stress-w7.yaml
```

Completed rounds are rechecked and skipped; the interrupted round is rewritten.
Changing only resource requests/limits does not change the payload layout. Switching
from the previous six-writer layout to the reference-style one-writer layout requires
a fresh name prefix/PVCs; do not resume old six-file payloads with one writer.

## Pod status and troubleshooting

```bash
kubectl get pods -l app=io-stress
# Every successful worker eventually displays STATUS=Completed
kubectl logs io-stress-w0
kubectl get pod io-stress-w0 -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
```

- Exit code `0`: all configured iterations passed write and SHA-256 verification.
- Exit code `1` (or another nonzero code): write/checksum failed, Pod is Failed; see logs.
- Pods are standalone and do not retry automatically. Other Pods keep running if one fails.
- `helm upgrade` cannot modify an existing Pod's immutable `command`/`args` in place.
  For a fresh benchmark, use a new `namePrefix` and
  a new Helm release. Never `helm upgrade` a previous release solely to change Pod scripts: Helm
  may delete old named PVCs when they disappear from a release.
  **Do not uninstall the old release until you have saved any data you need** because
  uninstalling can also delete its PVCs and Longhorn volumes.

**Integrity scope:** like the reference repo, the script computes a SHA-256 digest
*after* writing each file, and then re-reads files to verify that digest. This catches
changes between hashing and verification, but does not independently prove that the
bytes persisted match their original random source. The read may be served from the
Linux page cache; `fsync`/`sync` ensures writes are requested to persistent storage.
