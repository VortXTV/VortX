#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FIXTURES="$ROOT/app/Tests"
OUTPUT="$ROOT/app/build/aether-engine-picker"
mkdir -p "$OUTPUT"
python3 - "$ROOT" "$FIXTURES/AetherEnginePickerRowsTests.swift" "$OUTPUT/fixture.swift" <<'PY'
from pathlib import Path
import sys,re,json,hashlib
root,template,output=map(Path,sys.argv[1:])
mac=(root/'app/Sources/PlayerScreen.swift').read_text()
tv=(root/'app/SourcesTV/TVPlayerView.swift').read_text()
def declaration(source, anchor):
    start=source.index(anchor); opening=source.index('{',start); depth=1; index=opening+1
    while depth:
        if source[index]=='{': depth+=1
        elif source[index]=='}': depth-=1
        index+=1
    return source[start:index].replace('private ','',1)
def admission(source, anchor):
    method=declaration(source,anchor)
    return declaration(method,'        if toAether {')
def latches(source):
    start=source.index('        aetherLatch = toAether\n')
    end=source.index('        avEngineFailed = false',start)
    return source[start:end]
start=mac.index('        case .engine:\n            #if os(iOS) || os(macOS)')+len('        case .engine:\n')
end=mac.index('\n        }\n    }\n\n    /// Group tracks',start)
macrows='    func engineRows() -> [Row] {\n'+mac[start:end]+'\n    }'
values={'macUncommitted':declaration(mac,'    private var hasUncommittedIssuedMedia:'),
        'tvUncommitted':declaration(tv,'    private var hasUncommittedIssuedMedia:'),
        'macAvailability':declaration(mac,'    private var canUseAetherEngine:'),
        'macReady':declaration(mac,'    private var aetherEngineSwitchReady:'), 'macRows':macrows,
        'macAdmission':admission(mac,'    private func switchPlayerEngine(\n'), 'macLatches':latches(mac),
        'tvAvailability':declaration(tv,'    private var canUseAetherEngine:'),
        'tvReady':declaration(tv,'    private var aetherEngineSwitchReady:'),
        'tvRows':declaration(tv,'    private func engineRows()'),
        'tvAdmission':admission(tv,'    private func switchPlayerEngine(toAVPlayer:'), 'tvLatches':latches(tv)}
s=template.read_text()
row_bindings=[]
for name,value in values.items():
    if name in ('macRows','tvRows'):
        # Production rows belong to value-type Views. The mutable model is a reference
        # host, so make the same receiver explicit without changing any action or guard.
        original=value
        value,count=re.subn(r'(?m)^(\s+)switchPlayerEngine\(',r'\1self.switchPlayerEngine(',value)
        assert count==3 and value.replace('self.switchPlayerEngine(', 'switchPlayerEngine(')==original
        row_bindings.append({'member':name,'qualifiedReceivers':count,
            'sourceSHA256':hashlib.sha256(original.encode()).hexdigest()})
    marker='// @source:'+name
    assert s.count(marker)==1,name
    s=s.replace(marker,value)
output.write_text(s)
(output.parent/'row-source-conservation.json').write_text(json.dumps(row_bindings,indent=2)+'\n')
PY
nice -n 15 swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 -parse-as-library -D VORTX_AETHER_ENGINE "$OUTPUT/fixture.swift" -o "$OUTPUT/feature-on"
"$OUTPUT/feature-on"
nice -n 15 swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 -parse-as-library "$OUTPUT/fixture.swift" -o "$OUTPUT/feature-off"
"$OUTPUT/feature-off"

set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FIXTURES="$ROOT/app/Tests"
OUTPUT="$ROOT/app/build/aether-engine-picker-handoff"
mkdir -p "$OUTPUT"
python3 - "$ROOT" "$FIXTURES/AetherEnginePickerHandoffTests.swift" "$OUTPUT/fixture.swift" <<'PY'
from pathlib import Path
import sys
root,template,output=map(Path,sys.argv[1:])
def declaration(source, anchor):
    start=source.index(anchor); opening=source.index('{',start); depth=1; index=opening+1
    while depth:
        if source[index]=='{': depth+=1
        elif source[index]=='}': depth-=1
        index+=1
    return source[start:index]
s=template.read_text()
for kind,path in [('mac','app/Sources/PlayerScreen.swift'),('tv','app/SourcesTV/TVPlayerView.swift')]:
    source=(root/path).read_text()
    for name,anchor in [('Handoff','    private func switchAVPlayerToAether()'),
                        ('Mount','    private func awaitReplacementAetherMount(')]:
        marker='// @source:'+kind+name
        assert s.count(marker)==1
        s=s.replace(marker,declaration(source,anchor))
policy=(root/'app/Sources/Player/VortXPreparedRemuxPolicy.swift').read_text()
s=s.replace('// @source:handoffPolicy',declaration(policy,'enum VortXRemuxHandoffPolicy {'))
output.write_text(s)
PY
nice -n 15 swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 -parse-as-library -D VORTX_AETHER_ENGINE "$OUTPUT/fixture.swift" -o "$OUTPUT/handoff"
"$OUTPUT/handoff"
