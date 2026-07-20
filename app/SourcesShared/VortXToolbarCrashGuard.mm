//
//  VortXToolbarCrashGuard.mm
//
//  macOS 26 (Tahoe) SwiftUI regression guard.
//
//  On macOS 26.5 SwiftUI's ToolbarBridge (`AppKitToolbarStrategy.updateExpandedItems`)
//  throws an NSException while inserting an item into the shared window NSToolbar,
//  under a burst of preference changes — e.g. an off-main model republishing while a
//  detail screen sits at the top of the shared-window NavigationStack. AppKit turns
//  that uncaught ObjC exception into a fatal SIGTRAP via
//  +[NSApplication _crashOnException:], force-quitting the whole app.
//
//  Live-repro'd on VortX 0.3.11 b154 / macOS 26.5.1 (crash 0629BAE4-...): play a
//  title, then open a movie detail whose source list is still being assembled and
//  ranked off the main thread (SourceListModel.rebuild -> StreamRanking). Thread 0
//  crashes in the toolbar insert while thread 20 is mid-rank. Every app-authored
//  `.toolbar` / `.navigationTitle` / `.searchable` / principal item is ALREADY
//  `#if os(iOS)`-gated, so this is not app toolbar content: it is SwiftUI's own
//  NavigationStack chrome being reconciled into the (hidden) shared window toolbar.
//
//  SCOPE — `method_setImplementation` swizzles NSToolbar at the CLASS level, so this
//  guards EVERY NSToolbar instance in the process, on every thread, silently absorbing
//  any NSToolbar insert exception (not only the one hidden shared-window toolbar). That
//  is acceptable ONLY because this app ships no functional/visible toolbars at all: the
//  one window toolbar is hidden and unused, VortXiOSApp sets
//  `.windowStyle(.hiddenTitleBar)` + `.toolbar(.hidden, for: .windowToolbar)`, and the
//  traffic lights are restored WITHOUT attaching a toolbar (MacWindowChrome). So a
//  skipped insert has no visible effect anywhere: the invisible item is simply not added
//  and SwiftUI reconciles again on the next pass. If a real, user-facing NSToolbar is
//  ever added to this app, revisit this guard so it does not mask genuine toolbar bugs.
//
//  WHICH METHODS — the crash report symbolicated the throwing IMP to the nearest
//  EXPORTED symbol (`-[NSToolbar _insertNewItemWithItemIdentifier:atIndex:
//  propertyListRepresentation:notifyFlags:]`), which does not exist as a real
//  selector on macOS 26.5 (verified at runtime; frame 2 of the same trace,
//  `-[NSCalendarDate initWithCoder:]`, is likewise a nearest-symbol artifact). The
//  real outer insertion entries on NSToolbar are the public
//  `insertItemWithItemIdentifier:atIndex:` and the SPI
//  `_userInsertItemWithItemIdentifier:atIndex:` (both share the (id,SEL,NSString*,
//  NSInteger) signature). Guarding those OUTER entries catches an exception thrown
//  anywhere below them (delegate item creation, the private `_insertItem:...` core)
//  as it unwinds through the guarded frame.
//
//  RE-ENTRANCY — a thread-local depth counter means only the OUTERMOST guarded frame
//  installs the try/catch; a guarded method calling another guarded method just
//  forwards to the original, so we never swallow mid-way and leave the outer AppKit
//  frame reading half-inserted state. The whole insert is abandoned atomically.
//
//  WHY OBJECTIVE-C++ AND `catch (...)`, NOT `@catch` — the VortXMac binary already
//  links three unwind personality routines (LuaJIT `_lj_err_unwind_dwarf`, Rust
//  `_rust_eh_personality`, C++ `___gxx_personality_v0` from libmpv/Libdovi). ld's
//  compact-unwind encoder caps a single image at three, so an Objective-C
//  `@try/@catch` — which pulls in a fourth, `___objc_personality_v0` — fails to link
//  ("Too many personality routines"). On the Apple 64-bit runtime ObjC exceptions
//  ride the same Itanium/zero-cost ABI as C++, so a C++ `catch (...)` catches the
//  thrown NSException while reusing the already-present C++ personality, keeping the
//  count at three.
//
//  Degrades safely: if a future OS renames these selectors, the guard for the
//  missing one is skipped, never crashing. On success the original is invoked with
//  identical arguments, so behaviour is unchanged whenever the insert would not throw.
//

#import <Foundation/Foundation.h>

#if TARGET_OS_OSX

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <atomic>

// The two OUTER insertion entries share this signature: -(void)…ItemIdentifier:atIndex:.
typedef void (*VXInsertIMP)(id, SEL, id, NSInteger);
// The private CORE insert has a wider signature: -(void)_insertItem:atIndex:notify…:notify…:notify…:.
typedef void (*VXCoreInsertIMP)(id, SEL, id, NSInteger, BOOL, BOOL, BOOL);

static VXInsertIMP vortx_orig_insert_public = nullptr;   // insertItemWithItemIdentifier:atIndex:
static VXInsertIMP vortx_orig_insert_user   = nullptr;   // _userInsertItemWithItemIdentifier:atIndex:
static VXCoreInsertIMP vortx_orig_insert_core = nullptr; // _insertItem:atIndex:notify…
static SEL vortx_sel_public = nullptr;
static SEL vortx_sel_user   = nullptr;
static std::atomic<long> vortx_swallow_count{0};

// Only the OUTERMOST guarded insert on a given thread wraps in try/catch; nested
// guarded calls (e.g. the public entry calling the private core, or the core being
// reached from an outer entry) forward straight through so the exception is caught
// exactly once, at the top, and the whole insert is abandoned atomically. The depth
// counter is SHARED across all three wrappers so any nesting between them is safe.
static thread_local int vortx_guard_depth = 0;

// RAII balance for the depth counter: increment on construction, decrement on scope
// exit (normal OR unwinding). The decrement is correct even though our own catch(...)
// already consumes the throw; RAII keeps it balanced if a future edit adds code after
// the try/catch that itself throws.
struct VXDepthGuard {
    VXDepthGuard() { ++vortx_guard_depth; }
    ~VXDepthGuard() { --vortx_guard_depth; }
};

static void vortx_log_swallow(id detail) {
    long n = vortx_swallow_count.fetch_add(1) + 1;
    if (n <= 5 || (n % 100) == 0) {
        NSLog(@"[VortX] guarded NSToolbar insert throw #%ld (%@)", n, detail);
    }
}

// Wrapper for the two outer entries (dispatch to the right original by _cmd).
static void vortx_insert_guarded(id self, SEL _cmd, id identifier, NSInteger index) {
    VXInsertIMP orig = (_cmd == vortx_sel_user) ? vortx_orig_insert_user
                                                : vortx_orig_insert_public;
    if (vortx_guard_depth > 0) {                 // nested: let the outer frame catch
        if (orig) orig(self, _cmd, identifier, index);
        return;
    }
    VXDepthGuard depth;
    try {
        if (orig) orig(self, _cmd, identifier, index);
    } catch (...) {
        vortx_log_swallow(identifier);
    }
}

// Wrapper for the private core insert. Catches a throw only when it is the outermost
// guarded frame (SwiftUI reaching the core directly); otherwise forwards so the outer
// entry's catch handles it.
static void vortx_core_insert_guarded(id self, SEL _cmd, id item, NSInteger index,
                                      BOOL notifyDelegate, BOOL notifyView, BOOL notifyFamily) {
    if (vortx_guard_depth > 0) {
        if (vortx_orig_insert_core)
            vortx_orig_insert_core(self, _cmd, item, index, notifyDelegate, notifyView, notifyFamily);
        return;
    }
    VXDepthGuard depth;
    try {
        if (vortx_orig_insert_core)
            vortx_orig_insert_core(self, _cmd, item, index, notifyDelegate, notifyView, notifyFamily);
    } catch (...) {
        vortx_log_swallow(item);
    }
}

static bool vortx_install(SEL sel, IMP replacement, void *origSlot) {
    Method m = class_getInstanceMethod([NSToolbar class], sel);
    if (m == nullptr) return false;
    IMP original = method_getImplementation(m);
    // Guard against a future OS aliasing two of our target selectors to the SAME Method:
    // installing twice would then store our own replacement as the "original", and a call
    // would recurse into the guard forever (stack overflow). If it is already our IMP, skip.
    if (original == replacement) return false;
    *(IMP *)origSlot = original;
    method_setImplementation(m, replacement);
    return true;
}

extern "C" void VortXInstallToolbarCrashGuard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vortx_sel_public = NSSelectorFromString(@"insertItemWithItemIdentifier:atIndex:");
        vortx_sel_user   = NSSelectorFromString(@"_userInsertItemWithItemIdentifier:atIndex:");
        SEL selCore = NSSelectorFromString(
            @"_insertItem:atIndex:notifyDelegate:notifyView:notifyFamilyAndUpdateDefaults:");
        bool pub  = vortx_install(vortx_sel_public, (IMP)vortx_insert_guarded,      &vortx_orig_insert_public);
        bool user = vortx_install(vortx_sel_user,   (IMP)vortx_insert_guarded,      &vortx_orig_insert_user);
        bool core = vortx_install(selCore,          (IMP)vortx_core_insert_guarded, &vortx_orig_insert_core);
        NSLog(@"[VortX] toolbar crash guard installed (public=%d, user=%d, core=%d).", pub, user, core);
    });
}

#else

// Non-macOS targets (tvOS, iOS) compile this to an empty no-op so the shared
// bridging-header declaration links everywhere without a platform ifdef at the
// (macOS-only) call site.
extern "C" void VortXInstallToolbarCrashGuard(void) { }

#endif
