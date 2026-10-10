#!/usr/bin/env bash
set -euo pipefail
# Compile only the touched Compose/search sources; no native builds, packaging, accounts or playback.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
transform_root="${VORTX_ANDROID_TRANSFORMS:-/Users/daksh/.gradle/caches/8.11.1/transforms}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Point to retained actual Android app classes.jar}"
android_jar="${VORTX_ANDROID_JAR:-/Users/daksh/Library/Android/sdk/platforms/android-36/android.jar}"
test -f "$app_classes"
jar() { rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
compiler_cp="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10):$stdlib:$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10):$annotations:$coroutines"
compose_plugin="$(jar org.jetbrains.kotlin kotlin-compose-compiler-plugin-embeddable 2.2.10)"
android_deps="${VORTX_UI_COMPILE_CLASSPATH:-$(rg --files --hidden --no-ignore "$transform_root" | rg '/transformed/[^/]+(-api|-runtime)\.jar$|/jars/classes.jar$' | paste -sd: -)}"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/native-search-ui.XXXXXX")"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android/ui"
"$java_bin" -Xmx1400m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$app_classes" -Xplugin="$compose_plugin" \
    -classpath "$app_classes:$android_deps:$stdlib:$annotations:$coroutines:$android_jar" \
    "$source_dir/search/SearchCollections.kt" "$source_dir/screens/SearchResultRails.kt" \
    "$source_dir/screens/OtherScreens.kt" "$source_dir/screens/MergedDiscoverSearchScreen.kt" \
    "$source_dir/components/CollectionsHub.kt" "$source_dir/tv/TvCollectionsHub.kt" \
    "$source_dir/tv/TvSearchScreen.kt" "$source_dir/tv/TvSearchResultRails.kt" \
    -d "$test_dir/classes"
printf 'Compiled search touch, merged Discover, collections and TV Compose sources: %s\n' "$test_dir/classes"
