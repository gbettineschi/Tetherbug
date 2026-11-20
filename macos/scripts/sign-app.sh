#!/usr/bin/env bash
# Signing-only: never execute the candidate or fall back to another identity.
set -euo pipefail
app=${1:?Pass the staged app bundle}
identity=${TETHERBUG_CODESIGN_IDENTITY:?An exact project certificate is required}
keychain=${TETHERBUG_CODESIGN_KEYCHAIN:?An explicit temporary keychain is required}
[[ "$identity" =~ ^[[:xdigit:]]{40}$ && -f "$keychain" && ! -L "$keychain" ]] || exit 2
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$app"
codesign --verify --deep --strict --test-requirement "=identifier \"ie.xav.tetherbug\" and certificate leaf = H\"$identity\"" "$app"
requirement=$(codesign --display -r- "$app" 2>&1 | sed -n -E 's/^designated => //p')
fingerprint=$(printf '%s' "$identity" | tr '[:upper:]' '[:lower:]')
[[ "$requirement" == "identifier \"ie.xav.tetherbug\" and certificate leaf = H\"$fingerprint\"" ]] || {
  echo 'The project identity is missing, changed or too broad.' >&2
  exit 2
}
