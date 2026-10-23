# Discover hero observation boundary

Discover retains its `FeaturedHeroModel` through a private, non-forwarding
`DiscoverHeroOwner` StateObject. The hero leaf still observes the actual model.
Hero output publications no longer select that model as the parent observation
subject. Catalog, filter, navigation and theme inputs retain their existing
observation paths; hero seed, interaction and stop callbacks are unchanged.
Home and Library are outside this change.

## Focused source-unit evidence

On 18 October 2026, the original source produced the expected typed ownership
failure on its first hero assignment, after working leaf, direct and intentional
forwarding controls. After only the owner/accessor production change, the same
fixture passed all nine assignments: three outputs (`hero`, `pageCount`, `page`)
each receiving values `[1, 1, 2]`. Equal-value publication, repeated-access model
identity, distinct owners, retention and final release are checked.

The fixture uses real Combine publishers and exact extracted production owner,
binding/accessor and observation-subject code. Its model outputs are deterministic
collaborators and StateObject becomes an ordinary retained field in the probe.
Those seams are deliberate; it is not a mounted SwiftUI or real-model lifecycle
test. Complete owning source, normalized Discover body, actual model and leaf
bytes are pinned by the preparer; captured/generated inputs are independently
checked by the bounded execution gate.

Both successful behavioral lanes used the same corrected fixture and strict
Swift 6 concurrency/warnings-as-errors, one compiler job/thread and fresh caches.
An earlier fixture compilation failure was retained separately and contributed
no behavioral negative evidence. No compiler flag or observation assertion was
weakened to obtain the result.

## Limits

This establishes a source-selected publisher graph, not measured performance.
SwiftUI StateObject lazy initialization, remount identity, body/redraw counts,
actual leaf rendering, hidden-tab behavior and navigation/filter/theme integration
still need their platform checks. The real model's asynchronous lifecycle and
app/SDK compilation are not exercised here. No app was launched, no account or
preferences were changed, and no device smoothness, frame-rate or power claim
follows from these nine assignments.
