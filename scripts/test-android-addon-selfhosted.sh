#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Actual-source JVM checks only: no Gradle, APK, engine or device. Run this lane separately from Apple checks.
kotlin_lib="${VORTX_KOTLIN_LIB:?Existing Kotlin compiler/runtime jar directory required}"
deps="${VORTX_ANDROID_AUDIT_DEPS:?Existing public OkHttp/Okio/JSON/JUnit jar directory required}"
java_bin="${VORTX_TEST_JAVA:-java}"
stdlib="$kotlin_lib/kotlin-stdlib-2.0.20.jar"
test_cp="$stdlib:$kotlin_lib/kotlinx-coroutines-core-jvm-1.6.4.jar:$deps/kotlinx-coroutines-test-jvm-1.6.4.jar:$deps/okhttp-4.12.0.jar:$deps/okio-jvm-3.6.0.jar:$deps/json-20240303.jar:$deps/junit-4.13.2.jar:$deps/hamcrest-core-1.3.jar"
mkdir -p android/app/build
run_dir=$(mktemp -d "$PWD/android/app/build/addon-selfhosted.XXXXXX")
node --input-type=module - "$run_dir" <<'NODE'
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
const root = 'android/app/src/main/kotlin/com/vortx/android/';
const sync = readFileSync(root + 'sync/VortXSyncDoc.kt', 'utf8');
const legacy = readFileSync(root + 'engine/NativeLegacyMaterial.kt', 'utf8');
function block(source, marker) {
  const start = source.indexOf(marker);
  assert(start >= 0, marker);
  let end = source.indexOf('{', start) + 1, depth = 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0);
  return source.slice(start, end);
}
const start = sync.indexOf('    data class AddonDescriptor(');
assert(start >= 0);
const descriptor = sync.slice(start, sync.indexOf('\n\n', start));
assert.equal((legacy.match(/requireAddonHost\(uri!!\.host\)/g) ?? []).length, 2,
             'descriptor and tombstone consumers use the same endpoint admission');
// Compile actual changed guards with JSON and the real address policy. This does not replace full migration tests.
writeFileSync(`${process.argv[2]}/RestorationAddonAdmission.kt`, `package com.vortx.android.sync
import org.json.JSONObject
import java.net.URI
import com.vortx.android.engine.PublicAddressPolicy
object VortXSyncDoc {
${descriptor}
${block(sync, 'internal fun addonDescriptor(')}
${block(legacy, 'private fun requireAddonHost(')}
private fun fail(message: String): Nothing = throw IllegalArgumentException(message)
fun acceptsLegacyHost(host: String): Boolean = runCatching { requireAddonHost(host) }.isSuccess
}
class LegacyAddonAdmissionTest {
  @org.junit.Test fun selectedPrivateHostsRemainRepresentable() {
    for (host in listOf("192.168.50.20", "100.64.1.2", "[fd7a:115c:a1e0::1]"))
      org.junit.Assert.assertTrue(VortXSyncDoc.acceptsLegacyHost(host))
    for (host in listOf("169.254.169.254", "100.100.100.200", "[fd00:ec2::254]"))
      org.junit.Assert.assertFalse(VortXSyncDoc.acceptsLegacyHost(host))
  }
}
`);
NODE
"$java_bin" -XX:ActiveProcessorCount=1 -Xmx768m -cp "$kotlin_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -Werror -jvm-target 17 -classpath "$test_cp" \
  android/app/src/main/kotlin/com/vortx/android/engine/AddonManifestFetcher.kt \
  android/app/src/main/kotlin/com/vortx/android/engine/AddonHealthStore.kt \
  "$run_dir/RestorationAddonAdmission.kt" \
  android/app/src/test/kotlin/com/vortx/android/engine/AddonManifestFetcherTest.kt \
  android/app/src/test/kotlin/com/vortx/android/engine/AddonSelfHostedPolicyTest.kt \
  android/app/src/test/kotlin/com/vortx/android/engine/AddonHealthStoreTest.kt \
  android/app/src/test/kotlin/com/vortx/android/engine/OkHttpAddonHealthProbeTest.kt -d "$run_dir/classes"
"$java_bin" -XX:ActiveProcessorCount=1 -Xmx256m -cp "$run_dir/classes:$test_cp" org.junit.runner.JUnitCore \
  com.vortx.android.engine.AddonManifestFetcherTest com.vortx.android.engine.AddonSelfHostedPolicyTest \
  com.vortx.android.engine.AddonHealthStoreTest com.vortx.android.engine.OkHttpAddonHealthProbeTest \
  com.vortx.android.sync.LegacyAddonAdmissionTest
printf 'Retained Android add-on checks: %s\n' "$run_dir"
