package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.engine.AddonConfiguration
import com.vortx.android.pairing.AddonPairingClient
import com.vortx.android.pairing.AddonPairingProtocol.Authority
import com.vortx.android.pairing.AddonPairingReducer
import com.vortx.android.pairing.PairingDelivery
import com.vortx.android.pairing.PairingInstallOutcome
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.net.URI
import java.util.UUID

/// Install-by-QR pairing driver (Apple `AddonPairingView` + `AddonPairingReducer` + `AddonPairingClient`).
/// This device shows a QR of the relay page URL; a phone opens that page and pastes add-on manifest URLs;
/// this device polls the relay, claims each pending delivery, installs it through the SAME hardened install
/// path a pasted URL uses (so it syncs to the account + official apps), and acknowledges the outcome. The
/// phone is just a browser on the relay's page -- there is no phone-side app surface to build here.
class AddonPairingViewModel(
    private val repo: CatalogRepository,
    private val client: AddonPairingClient = AddonPairingClient(),
) : ViewModel() {
    sealed interface UiState {
        /// Minting the session (before the QR can be shown).
        data object Starting : UiState

        /// The QR is up; [items] are the manifests delivered so far and their install progress.
        data class Active(val pageUrl: String, val items: List<PairingItem>) : UiState

        /// The session could not start (or a fatal error). [canRetry] offers a Try-again.
        data class Failed(val message: String, val canRetry: Boolean) : UiState

        /// The relay closed / expired / released the session. [items] preserved so the user sees the result.
        data class Ended(val items: List<PairingItem>) : UiState
    }

    data class PairingItem(
        val deliveryId: String,
        val url: String,
        val label: String,
        val status: PairingItemStatus,
    )

    enum class PairingItemStatus { INSTALLING, INSTALLED, FAILED }

    private val _state = MutableStateFlow<UiState>(UiState.Starting)
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var token: String? = null
    private var authority: Authority? = null
    private var pageUrl: String = ""
    private var pollJob: Job? = null

    /// Highest delivery revision fully resolved per delivery id (the dedupe key), and per-delivery attempt
    /// counts so a transient failure retries a bounded number of times.
    private val handledRevisionById = mutableMapOf<String, Int>()
    private val attemptById = mutableMapOf<String, Int>()

    /// Ordered UI items keyed by delivery id (insertion order preserved for a stable list).
    private val items = linkedMapOf<String, PairingItem>()

    init {
        start()
    }

    fun start() {
        pollJob?.cancel()
        handledRevisionById.clear()
        attemptById.clear()
        items.clear()
        token = null
        authority = null
        _state.value = UiState.Starting
        viewModelScope.launch {
            val session = client.createSession()
            if (session == null) {
                _state.value = UiState.Failed("Couldn't start pairing. Check your connection and try again.", canRetry = true)
                return@launch
            }
            token = session.token
            authority = session.authority
            pageUrl = session.pageUrl
            _state.value = UiState.Active(pageUrl = pageUrl, items = emptyList())
            pollJob = viewModelScope.launch { pollLoop() }
        }
    }

    private suspend fun pollLoop() {
        while (viewModelScope.isActive) {
            val currentToken = token ?: return
            val poll = client.poll(currentToken, authority)
            if (poll != null) {
                poll.authority?.let { authority = it }
                if (poll.closed || poll.terminal || poll.released) {
                    _state.value = UiState.Ended(items.values.toList())
                    return
                }
                processDeliveries(poll.deliveries)
            }
            delay(POLL_INTERVAL_MS)
        }
    }

    private suspend fun processDeliveries(deliveries: List<PairingDelivery>) {
        val currentToken = token ?: return
        val currentAuthority = authority ?: return
        val fresh = AddonPairingReducer.freshDeliveries(deliveries, handledRevisionById)
        if (fresh.isEmpty()) return

        // Reflect the new deliveries as Installing before the network work, so the QR screen shows progress.
        fresh.forEach { delivery ->
            items[delivery.deliveryId] = PairingItem(
                deliveryId = delivery.deliveryId,
                url = delivery.url,
                label = labelFor(delivery.url),
                status = PairingItemStatus.INSTALLING,
            )
        }
        publishItems()

        val refs = fresh.map(AddonPairingReducer::deliveryReference)
        val claim = client.claim(currentToken, currentAuthority, refs, AddonPairingReducer.mutationId("claim", refs))
        // A dropped claim retries next tick; a stale claim means the authority moved on, so re-poll first.
        if (claim == null || claim.stale) return

        val acknowledgements = fresh.map { delivery ->
            val attempt = (attemptById[delivery.deliveryId] ?: 0) + 1
            attemptById[delivery.deliveryId] = attempt
            val outcome = install(delivery.url)
            items[delivery.deliveryId] = items.getValue(delivery.deliveryId).copy(status = outcome.toItemStatus())
            if (AddonPairingReducer.isTerminal(outcome, attempt)) {
                handledRevisionById[delivery.deliveryId] = delivery.deliveryRevision
            }
            AddonPairingReducer.acknowledgement(delivery, outcome, attempt)
        }
        publishItems()

        client.ack(currentToken, currentAuthority, acknowledgements, AddonPairingReducer.mutationId("ack", refs))
    }

    private suspend fun install(url: String): PairingInstallOutcome {
        val result = repo.installAddon(url)
        if (result.isSuccess) return PairingInstallOutcome.INSTALLED
        val message = result.exceptionOrNull()?.message.orEmpty()
        // A needs-configuration link is a permanent rejection; anything else may be transient (retry).
        return if (message == AddonConfiguration.NEEDS_CONFIGURATION_MESSAGE) {
            PairingInstallOutcome.REJECTED
        } else {
            PairingInstallOutcome.RETRYABLE
        }
    }

    private fun publishItems() {
        val current = _state.value
        if (current is UiState.Active) {
            _state.value = current.copy(items = items.values.toList())
        }
    }

    private fun PairingInstallOutcome.toItemStatus(): PairingItemStatus = when (this) {
        PairingInstallOutcome.INSTALLED, PairingInstallOutcome.ALREADY_INSTALLED -> PairingItemStatus.INSTALLED
        PairingInstallOutcome.REJECTED, PairingInstallOutcome.RETRYABLE -> PairingItemStatus.FAILED
    }

    private fun labelFor(url: String): String =
        runCatching { URI(url).host ?: url }.getOrDefault(url)

    override fun onCleared() {
        super.onCleared()
        pollJob?.cancel()
        // Best-effort release so the relay retires the token promptly (Apple releases on sheet dismiss).
        // viewModelScope is already cancelling here, so run the single release on a short-lived detached
        // scope that completes on its own; if it never lands the token simply expires.
        val currentToken = token ?: return
        val currentAuthority = authority ?: return
        val releaseScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        releaseScope.launch {
            try {
                client.release(currentToken, currentAuthority, "release-" + UUID.randomUUID().toString().take(12).replace("-", ""))
            } finally {
                releaseScope.cancel()
            }
        }
    }

    private companion object {
        const val POLL_INTERVAL_MS = 2_000L
    }
}
