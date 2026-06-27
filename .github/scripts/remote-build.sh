#!/usr/bin/env bash
# remote-build.sh — `snapcraft remote-build` for the given archs, fetching the
# artifacts with retry so a TRANSIENT network failure during the download does
# not fail an otherwise-green build.
#
# Why: the Launchpad build can SUCCEED while snapcraft's download of the artifact
# breaks mid-stream ("Connection broken: IncompleteRead"). That leaves a
# truncated .snap on disk which later fails to unsquash at upload — a passing
# build turned red by a network blip. We validate every fetched snap, drop any
# that are truncated/corrupt, and retry with a FRESH `snapcraft remote-build`
# until every requested arch has a VALID snap or the attempts are exhausted.
#
# We do NOT use `--recover`: snapcraft deletes the temporary Launchpad repo after
# each run, so `--recover` finds nothing ("Could not find repository") and re-
# fetches nothing — a proven no-op (see PR #213's log). The truncation is
# intermittent ACROSS runs, so a fresh remote-build is what actually clears it.
# A retry therefore costs a full rebuild; the default cap is one retry.
#
# A genuine single-arch BUILD failure stays tolerated: we keep whatever valid
# snaps exist and let the caller's completeness gate decide. So this never makes
# a previously-passing build fail; it only rescues transient download breakage.
#
# Usage:  remote-build.sh <comma-separated-archs>        # e.g. amd64,arm64,armhf
# Env:    MAX_ATTEMPTS (default 2 = one retry), RETRY_DELAY seconds (default 15)
#         GITHUB_OUTPUT (optional) — receives "snaps=<valid-count>"
# Exit:   0 always (partial-tolerant).
set -uo pipefail

ARCHS="${1:?usage: remote-build.sh <archs>, e.g. amd64,arm64,armhf}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
RETRY_DELAY="${RETRY_DELAY:-15}"

IFS=',' read -ra WANT <<< "$ARCHS"
want="${#WANT[@]}"

# 0 iff $1 is a complete, readable squashfs. `unsquashfs -l` reads the inode and
# directory tables (near the END of the archive), so a truncated download fails
# here — unlike a superblock-only check, which a tail-truncated file would pass.
snap_ok() { unsquashfs -l "$1" >/dev/null 2>&1; }

# Drop truncated/corrupt artifacts so the next attempt re-fetches them and a bad
# file never reaches `snapcraft upload`.
prune_corrupt() {
    local f
    for f in ./*.snap; do
        [ -e "$f" ] || continue
        if ! snap_ok "$f"; then
            echo "discarding corrupt/truncated artifact: $f"
            rm -f "$f"
        fi
    done
}

valid_count() {                # number of *.snap files in the current directory
    local n=0 f
    for f in ./*.snap; do [ -e "$f" ] && n=$((n + 1)); done
    printf '%s\n' "$n"
}

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    echo "::group::remote-build attempt ${attempt}/${MAX_ATTEMPTS} (${ARCHS})"
    # A FRESH build every attempt (no `--recover`: it's a no-op — see the header).
    # `|| true`: a partial-arch failure must not abort, and a transient fetch
    # error is handled by the validate+retry below.
    snapcraft remote-build -v --launchpad-accept-public-upload --build-for="$ARCHS" || true
    echo "::endgroup::"

    prune_corrupt
    count="$(valid_count)"
    echo "valid snaps after attempt ${attempt}: ${count}/${want}"
    [ "$count" -ge "$want" ] && break

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        echo "incomplete (${count}/${want}) — rebuilding in ${RETRY_DELAY}s"
        sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
done

count="$(valid_count)"
ls -1 ./*.snap 2>/dev/null || echo "(no .snap files produced)"
echo "snaps=${count}"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "snaps=${count}" >> "$GITHUB_OUTPUT"
exit 0
