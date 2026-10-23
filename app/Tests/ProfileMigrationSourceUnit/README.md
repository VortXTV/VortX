# Profile migration source unit

This standalone Swift source unit exercises the G3 migration attempt-slot lifetime. It is not an Xcode app target member. Four fixture regions retain literal production declarations, the complete migration helper, the transition reset, and the direct-edit witness clear. Other types, target/session state and async save are disposable collaborators; they do not implement Combine, credentials, storage, CoreBridge authority or native SDK integration. Passing this unit does not establish whole ProfileStore isolation, final-store correctness, cancellation of an entered save or causal RED for the former production helper.

The frozen `run()` source enumerates 25 scenarios across six families. Internal retries and save releases are phases within those scenarios.

| Family | Scenarios |
| --- | ---: |
| Suspended A and successor B, both completion orders | 2 |
| Queued stale A and direct clear before entry | 2 |
| Equal-payload witness reinstall with retained or successor attempt | 2 |
| Replacement-payload and retained-witness authority boundaries | 6 |
| Healthy true/false results, preserved/default window, and direct clear during save | 6 |
| Ineligible calls and an occupied attempt | 7 |

Queued setup happens in one MainActor turn before awaiting. Explicit continuations acknowledge save entry and release each held save. A task-local lifetime receipt observes termination without changing or replacing the production `Task`. Its canary must remain unfinished while save is held and finish after release; queued no-save rejection must also finish. No collaborator creates another Task that could inherit and retain that receipt. A missing signal or external gate deadline expiry is failure, not phase proof. New witness payload variants are rejected by the earlier UUID comparison; retained-witness variants independently reach active-profile, target-currentness and stored-session checks.

The scoped unit gate accepts no arguments and runs only the default `Entry.swift` path. Retained PureCleanup flags are outside that gate and are not accepted or executed by it. `PureCleanup.swift` is preserved as an unchanged source dependency, not a production Task negative receipt. The Swift files retain their historical author-time `UNCOMPILED / UNRUN` comments byte for byte; current gate status belongs in root's separately dated execution receipt, not a rewritten historical claim here.

From the repository root, the only guard invocation is:

```text
node test/profile-migration-source-correspondence.mjs
```

The guard accepts no arguments. It reads only `app/SourcesShared/Profiles.swift` and `app/Tests/ProfileMigrationSourceUnit/Fixture.swift`, extracts the four full fragments between the frozen marker lines, and requires each entire byte fragment—including whitespace—to occur exactly once in actual source. Missing/duplicate markers, empty/duplicate fragments, changed span lengths and body drift fail. It does not compile, evaluate either source, execute artifacts, launch children or write files. Its result establishes only finite exact source correspondence; the unit execution receipt remains separate.
