#!/usr/bin/env bash
# Xcode build phase for the Apple apps (iPhone and iPad, Mac, Apple TV): embed AetherEngine's FFmpeg frameworks.
#
# VortXAetherKit links the package's dynamic AetherLib* frameworks, but Xcode only embeds a package's
# binary frameworks into a target that depends on the package directly, and the apps must not (that
# would link AetherEngine a second time next to MPVKit's static FFmpeg). Without these VortXAetherKit fails
# to load with "Library not loaded". The list is the dependency closure of VortXAetherKit
# (otool -L); keep it in step with the outputFiles of the build phases in app/project.yml.
#
# Like Xcode's own embed step, headers and modules are dropped. Signed builds re-sign with the app's
# identity; unsigned builds drop the vendor's _CodeSignature folder, as Xcode's embed does for the MPVKit
# frameworks, because a release IPA must carry no signature folders for the sideload signer to replace (the
# Mac app is signed as a whole when it is packaged). A macOS framework keeps its contents under Versions/,
# with top-level symlinks into it; both go, so no symlink is left pointing at a removed folder.
set -euo pipefail

frameworks=(AetherLibavcodec AetherLibavfilter AetherLibavformat AetherLibavutil AetherLibdav1d
            AetherLibswresample AetherLibswscale AetherLibzimg AetherLibzvbi)
destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "$destination"
for name in "${frameworks[@]}"; do
  source="${BUILT_PRODUCTS_DIR}/${name}.framework"
  test -d "$source" || { echo "error: ${name}.framework is missing from the build products" >&2; exit 1; }
  framework="${destination}/${name}.framework"
  rm -rf "${destination:?}/${name}.framework"
  ditto "$source" "$framework"
  # SwiftPM's binary artifacts may be read-only (0555 executables, 0444 resources).
  # Keep their execution/other permission bits, and never follow framework symlinks.
  # Normalize only this new embedded copy, before stripping and code signing, so
  # the installed app's owner can update file metadata such as quarantine xattrs.
  find -P "$framework" \( -type d -o -type f \) -exec chmod u+w {} +
  rm -rf "${framework}/Headers" "${framework}/Modules" "${framework}"/Versions/*/Headers "${framework}"/Versions/*/Modules
  if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier "$framework"
  else
    rm -rf "${framework}/_CodeSignature" "${framework}"/Versions/*/_CodeSignature
  fi
done
