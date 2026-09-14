# Tasks for the SLSA release pipeline. CI calls these; keep workflow YAML thin.

set shell := ["bash", "-euo", "pipefail", "-c"]

origin := justfile_directory() / "release-verify" / "upgrade-origin.sh"
cli_asset := "goodmem-linux-amd64.tar.gz"

_default:
    @just --list --unsorted

# Prove this release can be upgraded away from; reads dist/ and provenance/
[group('release-verify')]
forward-upgrade-gate release next profile image readyz:
    #!/usr/bin/env bash
    set -uo pipefail

    tarball="dist/{{ cli_asset }}"
    bundle="$(find provenance -name '{{ cli_asset }}.build.slsa' -print -quit)"
    [ -n "$bundle" ] || { echo "::error::no provenance bundle for {{ cli_asset }}"; exit 1; }

    if ! "{{ origin }}" start "{{ next }}" "$tarball" "$bundle"; then
        echo "::error::could not start the local upgrade origin; refusing to test against the real one"
        exit 1
    fi
    trap '"{{ origin }}" stop || true' EXIT

    current="{{ release }}"; current="${current#server-}"; current="${current#v}"
    newer="{{ next }}";      newer="${newer#server-}";     newer="${newer#v}"

    echo "::group::CLI recognises $newer"
    out="$(goodmem upgrade --check 2>&1)"; rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -ne 1 ]; then
        echo "::error::this release cannot upgrade to $newer: 'goodmem upgrade --check' exited $rc, expected 1 (update available)"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -qF "$current" || ! printf '%s' "$out" | grep -qF "$newer"; then
        echo "::error::'goodmem upgrade --check' did not report $current -> $newer"
        exit 1
    fi
    echo "::endgroup::"

    echo "::group::system upgrade points the user at the CLI upgrade"
    out="$(goodmem system upgrade --profile-name "{{ profile }}" --image "{{ image }}" 2>&1)"; rc=$?
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
    goodmem version
    echo "::endgroup::"

    echo "::group::server upgrades with the CLI check live"
    "{{ origin }}" advertise "{{ release }}"
    goodmem system upgrade --profile-name "{{ profile }}" --image "{{ image }}" || {
        echo "::error::server upgrade failed with the CLI version check enabled"
        exit 1
    }
    curl -fsS --retry 60 --retry-delay 2 --retry-connrefused "{{ readyz }}"
    echo "::endgroup::"

    echo "forward-upgrade gate passed"
