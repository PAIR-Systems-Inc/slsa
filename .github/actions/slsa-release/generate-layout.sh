#!/usr/bin/env bash
set -euo pipefail

# Generates the SLSA attestation layout file from artifacts in dist/.
# Expects SLSA_OUTPUTS_ARTIFACTS_FILE to be set to the output path.

if [ -z "${SLSA_OUTPUTS_ARTIFACTS_FILE:-}" ]; then
  echo "Error: SLSA_OUTPUTS_ARTIFACTS_FILE is not set"
  exit 1
fi

echo '{"version": 1, "attestations": [' > "$SLSA_OUTPUTS_ARTIFACTS_FILE"

FIRST=true
for artifact in dist/*; do
  if [ -f "$artifact" ]; then
    NAME=$(basename "$artifact")
    SHA256=$(sha256sum "$artifact" | cut -d' ' -f1)

    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo "," >> "$SLSA_OUTPUTS_ARTIFACTS_FILE"
    fi

    echo "  {\"name\": \"$NAME\", \"subjects\": [{\"name\": \"$NAME\", \"digest\": {\"sha256\": \"$SHA256\"}}]}" >> "$SLSA_OUTPUTS_ARTIFACTS_FILE"
    echo "Artifact: $NAME -> sha256:$SHA256"
  fi
done

echo "]}" >> "$SLSA_OUTPUTS_ARTIFACTS_FILE"

echo "Layout file contents:"
cat "$SLSA_OUTPUTS_ARTIFACTS_FILE"
