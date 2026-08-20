package com.vortx.android.pairing

import com.vortx.android.pairing.AddonPairingProtocol.DeliveryReference
import com.vortx.android.pairing.AddonPairingProtocol.WireAcknowledgement

/// Install outcome for one delivered manifest, mirroring Apple's `AddonInstallOutcome` retryability split.
enum class PairingInstallOutcome(val wireStatus: String, val retryable: Boolean) {
    INSTALLED("installed", false),
    ALREADY_INSTALLED("already-installed", false),
    /// Permanent rejection (bad/needs-configuration manifest): never retried, acked non-retryable so the
    /// phone-side page can show it failed rather than spinning forever.
    REJECTED("failed", false),
    /// Transient failure (network/unconfirmed): retried up to [AddonPairingReducer.MAX_INSTALL_ATTEMPTS],
    /// acked retryable until the cap so a flaky moment does not permanently drop a delivery.
    RETRYABLE("failed", true),
}

/// Pure decision core for the Install-by-QR poll loop (Apple `AddonPairingReducer`, condensed to the
/// durable happy path plus the idempotency the relay requires): which polled deliveries are NEW work,
/// deterministic mutation ids so a transport retry of the same batch is idempotent, whether a delivery is
/// done, and how an install outcome maps to a wire acknowledgement. Kept pure + side-effect-free so the
/// ViewModel owns all IO and this stays unit-testable.
object AddonPairingReducer {
    /// A transient install may be retried this many times across poll ticks before it is acked as a
    /// permanent failure, so a flaky endpoint cannot loop a delivery forever.
    const val MAX_INSTALL_ATTEMPTS = 3

    /// Deliveries in [polled] that are NEW work relative to [handledRevisionById]: never seen, or seen at
    /// a lower revision (the relay bumps a delivery's revision when its manifest changes). Deliveries whose
    /// revision is already fully handled are skipped (dedupe), matching Apple's revision-keyed delivery set.
    fun freshDeliveries(
        polled: List<PairingDelivery>,
        handledRevisionById: Map<String, Int>,
    ): List<PairingDelivery> = polled.filter { delivery ->
        val handledRevision = handledRevisionById[delivery.deliveryId]
        handledRevision == null || delivery.deliveryRevision > handledRevision
    }

    /// A deterministic mutation id for a batch, so a transport-failed retry of the IDENTICAL batch reuses
    /// the same nonce and the relay burns it once (Apple's "ambiguous retry reuses the same pair"). Derived
    /// from the sorted (id, revision) pairs; ASCII/opaque so it satisfies [AddonPairingProtocol.isMutationId].
    fun mutationId(prefix: String, refs: List<DeliveryReference>): String {
        val canonical = refs
            .sortedWith(compareBy({ it.deliveryId }, { it.deliveryRevision }))
            .joinToString("|") { "${it.deliveryId}@${it.deliveryRevision}" }
        val hash = (prefix + ":" + canonical).hashCode().toLong() and 0xFFFFFFFFL
        return "$prefix-${hash.toString(16)}-${refs.size}"
    }

    fun deliveryReference(delivery: PairingDelivery): DeliveryReference =
        DeliveryReference(deliveryId = delivery.deliveryId, deliveryRevision = delivery.deliveryRevision)

    /// The wire acknowledgement for one delivery's install [outcome] on its [attempt]th try.
    fun acknowledgement(delivery: PairingDelivery, outcome: PairingInstallOutcome, attempt: Int): WireAcknowledgement =
        WireAcknowledgement(
            deliveryId = delivery.deliveryId,
            status = outcome.wireStatus,
            attempt = attempt,
            deliveryRevision = delivery.deliveryRevision,
            retryable = outcome.retryable,
        )

    /// Whether a delivery is fully resolved (won't be retried): any non-retryable outcome, or a retryable
    /// one that has exhausted [MAX_INSTALL_ATTEMPTS].
    fun isTerminal(outcome: PairingInstallOutcome, attempt: Int): Boolean =
        !outcome.retryable || attempt >= MAX_INSTALL_ATTEMPTS
}
