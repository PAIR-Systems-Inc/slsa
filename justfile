# Tasks for the SLSA release pipeline. CI calls these; keep workflow YAML thin.

origin := justfile_directory() / "release-verify" / "upgrade-origin.sh"
cli_asset := "goodmem-linux-amd64.tar.gz"

_default:
    @just --list --unsorted

# Prove this release can be upgraded away from; reads dist/ and provenance/
[group('release-verify')]
forward-upgrade-gate release next profile image readyz:
    #!/usr/bin/env bash
    # No `set -e`: each command's status is checked explicitly so the failure
    # message names the assertion. Anything added here needs its own check.
    set -uo pipefail

    release={{ quote(release) }}
    next={{ quote(next) }}
    profile={{ quote(profile) }}
    image={{ quote(image) }}
    readyz={{ quote(readyz) }}
    origin={{ quote(origin) }}

    tarball="dist/{{ cli_asset }}"
    bundle="$(find provenance -name '{{ cli_asset }}.build.slsa' -print -quit)"
    [ -n "$bundle" ] || { echo "::error::no provenance bundle for {{ cli_asset }}"; exit 1; }
    [ -n "$release" ] && [ -n "$next" ] || { echo "::error::release and next must both be set"; exit 1; }

    # Upgrade in a directory this user owns. /usr/local/bin is root-owned on the
    # runners, and the CLI silently falls back to staging a copy in /tmp when it
    # cannot write its own location — which would skip the in-place swap, backup
    # and rollback code this gate exists to exercise.
    gate_bin="${HOME}/.goodmem-forward-gate/bin"
    mkdir -p "$gate_bin"
    install -m0755 "$(command -v goodmem)" "$gate_bin/goodmem" || {
        echo "::error::could not stage the CLI into a writable directory"; exit 1; }
    export PATH="$gate_bin:$PATH"

    if ! "$origin" start "$next" "$tarball" "$bundle"; then
        echo "::error::could not start the local upgrade origin; refusing to test against the real one"
        exit 1
    fi
    trap '"$origin" stop || true' EXIT

    current="${release#server-}"; current="${current#v}"
    newer="${next#server-}";      newer="${newer#v}"

    echo "::group::CLI recognises $newer"
    out="$(goodmem upgrade --check 2>&1)"; rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -ne 1 ]; then
        echo "::error::this release cannot upgrade to $newer: 'goodmem upgrade --check' exited $rc, expected 1 (update available)"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -qF -- "$current -> $newer" \
    && ! printf '%s' "$out" | grep -qF -- "$current → $newer"; then
        echo "::error::'goodmem upgrade --check' did not report $current -> $newer"
        exit 1
    fi
    echo "::endgroup::"

    echo "::group::system upgrade points the user at the CLI upgrade"
    out="$(goodmem system upgrade --profile-name "$profile" --image "$image" 2>&1)"; rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -eq 0 ]; then
        echo "::error::system upgrade ignored the CLI-outdated gate"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -qi "run 'goodmem upgrade' first"; then
        echo "::error::system upgrade failed without telling the user to upgrade the CLI first"
        exit 1
    fi
    echo "::endgroup::"

    echo "::group::CLI installs $newer"
    before="$(sha256sum "$gate_bin/goodmem" | cut -d' ' -f1)"
    out="$(goodmem upgrade --yes 2>&1)"; rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
        echo "::error::'goodmem upgrade --yes' exited $rc; users on this release would be stuck"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -q "SLSA provenance verified"; then
        echo "::error::forward upgrade installed without verifying provenance"
        exit 1
    fi
    # The CLI reports success for a staged copy it could not install; that leaves
    # the user on the old binary, so treat it as a failure here.
    if printf '%s' "$out" | grep -qiE "not writable|staged"; then
        echo "::error::upgrade only staged a copy instead of installing it"
        exit 1
    fi
    after="$(sha256sum "$gate_bin/goodmem" | cut -d' ' -f1)"
    [ "$before" = "$after" ] && echo "note: binary unchanged (the advertised release serves this build's own artifact)"
    goodmem version || { echo "::error::the upgraded binary does not run"; exit 1; }
    echo "::endgroup::"

    echo "::group::system upgrade passes the CLI version check"
    "$origin" advertise "$release" || { echo "::error::could not re-advertise $release"; exit 1; }
    goodmem system upgrade --profile-name "$profile" --image "$image" || {
        echo "::error::server upgrade failed with the CLI version check enabled"
        exit 1
    }
    curl -fsS --max-time 120 --retry 60 --retry-delay 2 --retry-connrefused "$readyz" \
        || { echo "::error::server did not become ready after the upgrade"; exit 1; }
    echo "::endgroup::"

    echo "forward-upgrade gate passed"
