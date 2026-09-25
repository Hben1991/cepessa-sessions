#!/bin/zsh
set -euo pipefail
setopt null_glob

app_name='Sessions Dev'
bundle_id='me.cepessa.sessions-dev'
url_scheme='cepessa-sessions-dev'
binary_name='CepessaSessions'
capture_helper='CepessaMicrophoneCaptureHelper'
resource_bundle_name='CepessaSessions_CepessaSessions.bundle'

script_dir="${0:A:h}"
package_root="$script_dir/Desktop"
build_root="$script_dir/build"
output_app="$build_root/$app_name.app"
install_app="/Applications/$app_name.app"
scratch_path='/private/tmp/codex-derived-data/cepessa-sessions-reliability'
runtime_tmp='/private/tmp/cepessa-sessions-dev-runtime'
test_root="$build_root/dev-data"
jobs=4
env_file=''
sign_identity="${SESSIONS_DEV_SIGN_IDENTITY:--}"
should_install=false
should_launch=false
dry_run=false
production=false
build_configuration='debug'

usage() {
  cat <<'USAGE'
Usage: ./run.sh [options]

Builds a local-only Sessions Dev app. The default action packages the app at
desktop/build/Sessions Dev.app without launching or installing it.

Options:
  --launch                 Launch the packaged app after a successful build.
  --install                Install to /Applications/<app>. Default: Sessions Dev.app.
  --production             Package and install as Sessions.app (me.cepessa.sessions).
                           Replaces /Applications/Sessions.app. No isolated test-root.
  --test-root <path>       Use an absolute isolated Sessions data root.
                           Default: desktop/build/dev-data
  --env-file <path>        Explicitly package one local environment file.
                           No backend URL or credentials are added by default.
  --scratch-path <path>    Override the deterministic SwiftPM scratch path.
  --sign-identity <value>  Code-signing identity. Default: ad hoc (`-`).
  --jobs <1-4>             SwiftPM parallel jobs. Default: 4.
  --dry-run                Print the resolved build contract and exit.
  -h, --help               Show this help.

This script never stops or replaces Sessions.app, starts a backend or tunnel,
or connects the app to a production endpoint by default.
USAGE
}

require_value() {
  if (( $# < 2 )) || [[ -z "$2" ]]; then
    print -u2 "Missing value for $1"
    exit 2
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --launch)
      should_launch=true
      shift
      ;;
    --install)
      should_install=true
      shift
      ;;
    --production)
      production=true
      build_configuration='release'
      app_name='Sessions'
      bundle_id='me.cepessa.sessions'
      url_scheme='cepessa-sessions'
      install_app="/Applications/Sessions.app"
      output_app="$build_root/Sessions.app"
      runtime_tmp='/private/tmp/cepessa-sessions-runtime'
      should_install=true
      shift
      ;;
    --test-root)
      require_value "$@"
      test_root="$2"
      shift 2
      ;;
    --env-file)
      require_value "$@"
      env_file="$2"
      shift 2
      ;;
    --scratch-path)
      require_value "$@"
      scratch_path="$2"
      shift 2
      ;;
    --sign-identity)
      require_value "$@"
      sign_identity="$2"
      shift 2
      ;;
    --jobs)
      require_value "$@"
      jobs="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$test_root" != /* ]]; then
  print -u2 "--test-root must be an absolute path: $test_root"
  exit 2
fi
production_data_root="$HOME/Library/Application Support/Cepessa"
if [[ "$test_root" == "$production_data_root" || "$test_root" == "$production_data_root"/* ]]; then
  print -u2 "Refusing to use the production Sessions data root: $test_root"
  exit 2
fi
if [[ "$scratch_path" != /* ]]; then
  print -u2 "--scratch-path must be an absolute path: $scratch_path"
  exit 2
fi
if [[ ! "$jobs" =~ '^[1-4]$' ]]; then
  print -u2 "--jobs must be between 1 and 4"
  exit 2
fi
if [[ -n "$env_file" && ! -f "$env_file" ]]; then
  print -u2 "Environment file not found: $env_file"
  exit 2
fi

active_app="$output_app"
if [[ "$should_install" == true ]]; then
  active_app="$install_app"
fi

print_contract() {
  print "App:          $app_name"
  print "Bundle ID:    $bundle_id"
  print "URL scheme:   $url_scheme"
  print "Package:      $package_root"
  print "Scratch:      $scratch_path"
  print "Build:        $build_configuration"
  print "Jobs:         $jobs"
  print "Data root:    $test_root"
  print "Output:       $output_app"
  print "Install:      $should_install"
  print "Launch:       $should_launch"
  print "Environment:  ${env_file:-none}"
}

if [[ "$dry_run" == true ]]; then
  print_contract
  exit 0
fi

mkdir -p "$build_root" "$scratch_path" "$runtime_tmp" "$test_root"

if [[ "$production" == true && "$sign_identity" == '-' ]]; then
  sign_identity='Apple Development: hben16@gmail.com (ZLXT7X45FJ)'
fi

print "Building $app_name..."
print_contract
xcrun swift build \
  --package-path "$package_root" \
  --scratch-path "$scratch_path" \
  --configuration "$build_configuration" \
  --force-resolved-versions \
  --jobs "$jobs"

bin_root="$(xcrun swift build \
  --package-path "$package_root" \
  --scratch-path "$scratch_path" \
  --configuration "$build_configuration" \
  --show-bin-path)"

for required_product in "$binary_name" "$capture_helper"; do
  if [[ ! -x "$bin_root/$required_product" ]]; then
    print -u2 "Missing built executable: $bin_root/$required_product"
    exit 1
  fi
done

stage_root="$(mktemp -d "$build_root/.sessions-dev-stage.XXXXXX")"
stage_app="$stage_root/$app_name.app"
cleanup_stage() {
  [[ -e "$stage_root" ]] && find "$stage_root" -depth -delete
}
trap cleanup_stage EXIT

mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Helpers" \
  "$stage_app/Contents/Resources" "$stage_app/Contents/Frameworks"
ditto --norsrc --noextattr --noqtn --noacl \
  "$bin_root/$binary_name" "$stage_app/Contents/MacOS/$binary_name"

ditto --norsrc --noextattr --noqtn --noacl \
  "$bin_root/$capture_helper" "$stage_app/Contents/Helpers/$capture_helper"

for framework in "$bin_root"/*.framework; do
  ditto --norsrc --noextattr --noqtn --noacl \
    "$framework" "$stage_app/Contents/Frameworks/${framework:t}"
done
for bundle in "$bin_root"/*.bundle; do
  ditto --norsrc --noextattr --noqtn --noacl \
    "$bundle" "$stage_app/Contents/Resources/${bundle:t}"
done

if [[ ! -d "$stage_app/Contents/Resources/$resource_bundle_name" ]]; then
  print -u2 "Missing SwiftPM app resource bundle: $resource_bundle_name"
  exit 1
fi

whisper_resources="$package_root/Vendor/whisper.spm/Sources/whisper"
for shader in ggml-metal.metal ggml-common.h; do
  if [[ ! -f "$whisper_resources/$shader" ]]; then
    print -u2 "Missing vendored whisper Metal resource: $shader"
    exit 1
  fi
  ditto --norsrc --noextattr --noqtn --noacl \
    "$whisper_resources/$shader" "$stage_app/Contents/Resources/$shader"
done

ditto --norsrc --noextattr --noqtn --noacl \
  "$package_root/Info.plist" "$stage_app/Contents/Info.plist"
ditto --norsrc --noextattr --noqtn --noacl \
  "$package_root/Branding/AppIcon.icns" "$stage_app/Contents/Resources/AppIcon.icns"

plist="$stage_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $binary_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 26.0' "$plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes array' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0 dict' "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $url_scheme" "$plist"
/usr/libexec/PlistBuddy -c 'Delete :LSEnvironment' "$plist" 2>/dev/null || true
if [[ "$production" != true ]]; then
  /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$plist"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CEPESSA_SESSIONS_TEST_ROOT string $test_root" "$plist"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:TMPDIR string $runtime_tmp/" "$plist"
  if [[ -n "${CEPESSA_INSIGHTS_USE_FIXTURE:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CEPESSA_INSIGHTS_USE_FIXTURE string $CEPESSA_INSIGHTS_USE_FIXTURE" "$plist"
  fi
fi

if [[ -n "$env_file" ]]; then
  ditto --norsrc --noextattr --noqtn --noacl \
    "$env_file" "$stage_app/Contents/Resources/.env"
fi
print -n 'APPL????' > "$stage_app/Contents/PkgInfo"

chmod -R u+w "$stage_app"
xattr -cr "$stage_app"
sign_options=(--force --sign "$sign_identity")
if [[ "$sign_identity" != '-' ]]; then
  sign_options+=(--options runtime)
fi
for framework in "$stage_app/Contents/Frameworks"/*.framework; do
  codesign $sign_options "$framework"
done
capture_helper_path="$stage_app/Contents/Helpers/$capture_helper"
[[ -x "$capture_helper_path" ]] && codesign $sign_options "$capture_helper_path"
if [[ "$sign_identity" == '-' ]]; then
  codesign $sign_options "$stage_app"
elif [[ "$production" == true && -f "$package_root/Cepessa-Release.entitlements" ]]; then
  codesign $sign_options --entitlements "$package_root/Cepessa-Release.entitlements" "$stage_app"
else
  codesign $sign_options --entitlements "$package_root/Cepessa-Dev.entitlements" "$stage_app"
fi
codesign --verify --deep --strict --verbose=2 "$stage_app"
plutil -lint "$plist"

if [[ -e "$output_app" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$output_app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != "$bundle_id" ]]; then
    print -u2 "Refusing to replace app with unexpected identity: $output_app ($existing_id)"
    exit 1
  fi
  find "$output_app" -depth -delete
fi
mv "$stage_app" "$output_app"
rmdir "$stage_root"
trap - EXIT

if [[ "$should_install" == true ]]; then
  if [[ "$production" == true ]]; then
    osascript -e 'tell application "Sessions" to quit' >/dev/null 2>&1 || true
    sleep 1
  fi
  if [[ -e "$install_app" ]]; then
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$install_app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$installed_id" != "$bundle_id" ]]; then
      print -u2 "Refusing to replace unexpected /Applications bundle: $installed_id"
      exit 1
    fi
    find "$install_app" -depth -delete
  fi
  ditto --norsrc --noextattr --noqtn --noacl "$output_app" "$install_app"
  active_app="$install_app"
fi

print "Built: $output_app"
if [[ "$should_install" == true ]]; then
  print "Installed: $install_app"
fi
if [[ "$should_launch" == true ]]; then
  open "$active_app"
  print "Launched: $active_app"
fi
