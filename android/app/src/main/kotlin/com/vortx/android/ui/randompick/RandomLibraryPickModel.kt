package com.vortx.android.ui.randompick

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.random.Random

/** The full profile value binds Kids/PIN edits as well as profile identity to each local read. */
internal data class RandomLibraryPickProfile(val profile: UserProfile, val selectionReady: Boolean)

internal enum class RandomLibraryPickNotice { EMPTY, PROFILE_LOCKED, LOAD_ERROR, PICK_UNAVAILABLE }

internal data class RandomLibraryPickState(
    val filter: RandomLibraryFilter = RandomLibraryFilter.ALL,
    val preview: MetaItem? = null,
    val loading: Boolean = false,
    val message: RandomLibraryPickNotice? = null,
)

/**
 * Session-only Random pick state. Both selection and explicit Open/Play read the admitted local
 * Library; neither operation saves a title, changes watched state, nor resolves/starts a source.
 * Callers run this model on the UI scope, matching ProfileStore's main-thread projection contract.
 */
internal class RandomLibraryPickModel(
    private val scope: CoroutineScope,
    private val captureOwner: () -> ContinueWatchingOwner,
    private val captureProfile: () -> RandomLibraryPickProfile?,
    private val readLibrary: suspend () -> Result<LibraryResult>,
    private val nextInt: (Int) -> Int = { Random.nextInt(it) },
) {
    private data class Admission(
        val owner: ContinueWatchingOwner,
        val profile: RandomLibraryPickProfile,
    )

    private val _state = MutableStateFlow(RandomLibraryPickState())
    val state: StateFlow<RandomLibraryPickState> = _state.asStateFlow()
    private var selectionRequest: Any? = null
    private var actionRequest: Any? = null
    private var pickJob: Job? = null
    private var actionJob: Job? = null
    private var previewAdmission: Admission? = null

    fun pick(filter: RandomLibraryFilter = _state.value.filter) {
        val previous = _state.value.preview
        val previousAdmission = previewAdmission
        retire(filter)
        val admission = captureAdmission() ?: run {
            _state.value = _state.value.copy(message = RandomLibraryPickNotice.PROFILE_LOCKED)
            return
        }
        val previousKey = previous?.takeIf { previousAdmission == admission }?.let(::libraryPickKey)
        val request = Any()
        selectionRequest = request
        _state.value = RandomLibraryPickState(filter = filter, loading = true)
        pickJob = scope.launch {
            try {
                val library = readLibrary().getOrThrow()
                currentCoroutineContext().ensureActive()
                if (!selectionIsCurrent(request, admission)) return@launch
                val candidates = RandomPickPolicy.libraryCandidates(library.items, filter)
                val picked = RandomPickPolicy.pick(candidates, previousKey, ::libraryPickKey, nextInt)
                previewAdmission = admission.takeIf { picked != null }
                _state.value = RandomLibraryPickState(
                    filter = filter,
                    preview = picked,
                    message = RandomLibraryPickNotice.EMPTY.takeIf { picked == null },
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                if (selectionIsCurrent(request, admission)) {
                    previewAdmission = null
                    _state.value = RandomLibraryPickState(filter = filter, message = RandomLibraryPickNotice.LOAD_ERROR)
                }
            } finally {
                if (selectionRequest === request) {
                    if (captureAdmission() != admission) retire(filter, RandomLibraryPickNotice.PROFILE_LOCKED)
                    else if (_state.value.loading) _state.value = _state.value.copy(loading = false)
                }
            }
        }
    }

    /** Invalidates before cancellation, including requests suspended in NonCancellable code. */
    fun clear() = retire(_state.value.filter)

    /**
     * Re-read on an explicit Open/Play: local Library membership can change without owner revision.
     * Navigation is accepted only after the same preview, filter, profile and request still own it.
     */
    fun openPreview(onAccepted: (MetaItem) -> Unit) {
        val preview = _state.value.preview ?: return
        val expected = previewAdmission ?: return
        val selection = selectionRequest ?: return
        if (captureAdmission() != expected) {
            retire(_state.value.filter, RandomLibraryPickNotice.PROFILE_LOCKED)
            return
        }
        val filter = _state.value.filter
        val key = libraryPickKey(preview)
        val request = Any()
        val previousJob = actionJob
        actionRequest = request
        _state.value = _state.value.copy(loading = true, message = null)
        previousJob?.cancel()
        actionJob = scope.launch {
            var accepted: MetaItem? = null
            try {
                val library = readLibrary().getOrThrow()
                currentCoroutineContext().ensureActive()
                if (!actionIsCurrent(request, selection, expected, filter, key)) return@launch
                accepted = RandomPickPolicy.libraryCandidates(library.items, filter)
                    .firstOrNull { libraryPickKey(it) == key }
                if (accepted == null) {
                    previewAdmission = null
                    _state.value = RandomLibraryPickState(filter = filter, message = RandomLibraryPickNotice.PICK_UNAVAILABLE)
                } else {
                    _state.value = _state.value.copy(preview = accepted, loading = false)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                if (actionIsCurrent(request, selection, expected, filter, key)) {
                    previewAdmission = null
                    _state.value = RandomLibraryPickState(filter = filter, message = RandomLibraryPickNotice.LOAD_ERROR)
                }
            } finally {
                if (actionRequest === request && selectionRequest === selection) {
                    if (captureAdmission() != expected) retire(filter, RandomLibraryPickNotice.PROFILE_LOCKED)
                    else if (_state.value.loading) _state.value = _state.value.copy(loading = false)
                }
            }
            accepted?.takeIf { actionIsCurrent(request, selection, expected, filter, key) }?.let { item ->
                // Consume this explicit action before navigation can dispose/re-enter the screen.
                actionRequest = null
                actionJob = null
                onAccepted(item)
            }
        }
    }

    private fun captureAdmission(): Admission? {
        val owner = captureOwner()
        val profile = captureProfile() ?: return null
        if (!profile.selectionReady || profile.profile.id.isBlank() || profile.profile.id != owner.profileId) return null
        if (captureOwner() != owner || captureProfile() != profile) return null
        return Admission(owner, profile)
    }

    private fun selectionIsCurrent(request: Any, expected: Admission): Boolean =
        selectionRequest === request && captureAdmission() == expected

    private fun actionIsCurrent(
        request: Any,
        selection: Any,
        expected: Admission,
        filter: RandomLibraryFilter,
        key: String,
    ): Boolean = actionRequest === request && selectionRequest === selection &&
        previewAdmission == expected && captureAdmission() == expected &&
        _state.value.filter == filter && _state.value.preview?.let(::libraryPickKey) == key

    private fun retire(filter: RandomLibraryFilter, notice: RandomLibraryPickNotice? = null) {
        val oldPick = pickJob
        val oldAction = actionJob
        selectionRequest = null
        actionRequest = null
        previewAdmission = null
        pickJob = null
        actionJob = null
        _state.value = RandomLibraryPickState(filter = filter, message = notice)
        oldPick?.cancel()
        oldAction?.cancel()
    }
}

private fun libraryPickKey(item: MetaItem): String = "${item.type.id}:${item.id}"
