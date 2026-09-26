#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
desktop_dir="${script_dir:h}"
run_script="$desktop_dir/run.sh"
manifest="$desktop_dir/Desktop/Package.swift"
vendor="$desktop_dir/Desktop/Vendor/whisper.spm"

fail() {
  print -u2 "run.sh safety check failed: $1"
  exit 1
}

dry_run="$(zsh "$run_script" --dry-run)"
[[ "$dry_run" == *'App:          Sessions Dev'* ]] || fail 'wrong app name'
[[ "$dry_run" == *'Bundle ID:    me.cepessa.sessions-dev'* ]] || fail 'wrong bundle ID'
[[ "$dry_run" == *'URL scheme:   cepessa-sessions-dev'* ]] || fail 'wrong URL scheme'
[[ "$dry_run" == *'/private/tmp/codex-derived-data/cepessa-sessions-reliability'* ]] \
  || fail 'wrong default scratch path'
[[ "$dry_run" == *'/desktop/build/dev-data'* ]] || fail 'default data root is not isolated'
[[ "$dry_run" == *'Install:      false'* ]] || fail 'default unexpectedly installs'
[[ "$dry_run" == *'Launch:       false'* ]] || fail 'default unexpectedly launches'
[[ "$dry_run" == *'Environment:  none'* ]] || fail 'default unexpectedly packages an environment'

if zsh "$run_script" --dry-run \
  --test-root "$HOME/Library/Application Support/Cepessa" >/dev/null 2>&1; then
  fail 'production Sessions data root was accepted'
fi

# The production app may be named only inside the explicit --production mode.
production_mentions="$(grep -c -F '/Applications/Sessions.app' "$run_script" || true)"
production_block="$(awk '/--production\)/,/;;/' "$run_script" | grep -c -F '/Applications/Sessions.app' || true)"
usage_mentions="$(grep -c -F 'Replaces /Applications/Sessions.app' "$run_script" || true)"
(( production_mentions == production_block + usage_mentions )) \
  || fail 'production install path appears outside the --production mode'
production_dry_run="$(zsh "$run_script" --dry-run --production)"
[[ "$production_dry_run" == *'Bundle ID:    me.cepessa.sessions'* ]] || fail 'wrong production bundle ID'
[[ "$production_dry_run" == *'Build:        release'* ]] || fail 'production is not a release build'
[[ "$dry_run" == *'Build:        debug'* ]] || fail 'dev build is not a debug build'

for forbidden in \
  'pkill' \
  'rm -rf' \
  'a.run.app' \
  'trycloudflare.com'; do
  if grep -Fq -- "$forbidden" "$run_script"; then
    fail "forbidden production or broad-cleanup token: $forbidden"
  fi
done

grep -Fq '.package(path: "Vendor/whisper.spm")' "$manifest" \
  || fail 'whisper dependency is not vendored'
grep -Fq 'exact: "0.18.0"' "$manifest" || fail 'argmax dependency is not exact'
if grep -Fq 'llama.swift' "$manifest"; then
  fail 'the removed local model runner dependency came back'
fi
grep -Fq 'name: "CepessaMicrophoneCaptureHelper"' "$manifest" \
  || fail 'microphone capture helper target is missing'
grep -Fq 'Contents/Helpers/$capture_helper' "$run_script" \
  || fail 'microphone capture helper is not packaged under Contents/Helpers'

for required in \
  LICENSE \
  Package.swift \
  Sources/whisper/ggml-metal.m \
  Sources/whisper/ggml-metal.metal \
  Sources/whisper/ggml-common.h; do
  [[ -f "$vendor/$required" ]] || fail "missing vendored file: $required"
done
if find "$vendor" -type f -name '*.bin' -print -quit | grep -q .; then
  fail 'vendored package contains a model binary'
fi

print 'run.sh safety checks passed'
