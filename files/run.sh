#!/bin/sh
set -eu

# Alpine BusyBox supplies dd, sha256sum and sync.
# A non-zero exit makes this Pod Failed (restartPolicy: Never).
: "${ITERATIONS:?}"
: "${DATA_VOLUME_COUNT:?}"
: "${DATA_SIZE_MIB:?}"
: "${WRITE_WORKERS:?}"
DATA_ROOT="${DATA_ROOT:-/data}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

verify_data() {
  dir="$1"
  echo "[verify] $dir"
  # -- Check exit status, including missing/corrupt data files.
  (cd "$dir" && sha256sum -c SHA256SUMS) || fail "SHA-256 mismatch or missing file in $dir"
}

iteration=1
while [ "$iteration" -le "$ITERATIONS" ]; do
  echo "=== iteration $iteration/$ITERATIONS ==="
  volume=0
  while [ "$volume" -lt "$DATA_VOLUME_COUNT" ]; do
    dir="$DATA_ROOT/vol-$volume/random-stress"
    mkdir -p "$dir"
    marker="$dir/.last-completed-iteration"
    last=0
    if [ -f "$marker" ]; then
      last="$(cat "$marker")"
      case "$last" in
        ''|*[!0-9]*) fail "Invalid completion marker in $dir" ;;
      esac
    fi

    # A recreated Pod may resume completed rounds, but must still verify
    # the payload and checksum rather than silently trusting the marker.
    if [ "$last" -ge "$iteration" ]; then
      echo "[vol-$volume] iteration $iteration already completed; rechecking SHA-256"
      verify_data "$dir"
      volume=$((volume + 1))
      continue
    fi

    echo "[vol-$volume] writing $DATA_SIZE_MIB MiB with $WRITE_WORKERS concurrent dd processes"
    rm -f "$dir"/payload-*.sha256 "$dir"/SHA256SUMS.tmp
    base=$((DATA_SIZE_MIB / WRITE_WORKERS))
    remainder=$((DATA_SIZE_MIB % WRITE_WORKERS))
    pids=""
    worker=0
    while [ "$worker" -lt "$WRITE_WORKERS" ]; do
      count=$base
      if [ "$worker" -lt "$remainder" ]; then
        count=$((count + 1))
      fi
      (
        set -e
        file="payload-$worker.bin"
        echo "[vol-$volume dd-$worker] writing $count MiB"
        dd if=/dev/urandom of="$dir/$file" bs=1M count="$count" conv=fsync status=none
        (cd "$dir" && sha256sum "$file") > "$dir/payload-$worker.sha256"
        echo "[vol-$volume dd-$worker] write + checksum finished"
      ) &
      pids="$pids $!"
      worker=$((worker + 1))
    done

    failures=0
    for pid in $pids; do
      if ! wait "$pid"; then
        failures=1
      fi
    done
    [ "$failures" -eq 0 ] || fail "dd or initial checksum failed on vol-$volume, iteration $iteration"

    # Finish all background writes before verifying; fsync was also issued
    # by each dd worker.
    sync
    cat "$dir"/payload-*.sha256 > "$dir/SHA256SUMS.tmp" || fail "Failed to build checksum list"
    mv "$dir/SHA256SUMS.tmp" "$dir/SHA256SUMS"
    rm -f "$dir"/payload-*.sha256
    verify_data "$dir"

    # Only mark a round complete after all checks succeed.
    printf '%s\n' "$iteration" > "$marker.tmp"
    mv "$marker.tmp" "$marker"
    sync
    echo "[vol-$volume] iteration $iteration/$ITERATIONS PASSED"
    volume=$((volume + 1))
  done
  iteration=$((iteration + 1))
done

echo "SUCCESS: all $ITERATIONS iterations completed and SHA-256 verified"
# Exit 0 -> Kubernetes Pod phase Succeeded / kubectl STATUS Completed.
exit 0
