//! Node identity: an ed25519 keypair. ed25519 is in Apple CryptoKit, WebCrypto / Cloudflare Workers
//! `crypto.subtle`, and the Go stdlib, so every surface can verify a node's signature with fixed
//! 64-byte signatures and zero ceremony. The secret key is NEVER serialized.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

use crate::HiveError;

/// base64url (no pad) of a 32-byte ed25519 public key.
pub type SignerPubkey = String;
/// base64url (no pad) of `SHA-256(pubkey)[..16]`: a short, collision-safe node identifier.
pub type NodeId = String;

/// A node's ed25519 signing identity. One per node, generated on first run; the secret stays in the
/// device keychain (app) or node config (server) and is never written to a fact, manifest, or sync blob.
pub struct NodeIdentity {
    signing_key: SigningKey,
}

impl NodeIdentity {
    /// Generate a fresh identity from OS randomness. Any 32 bytes is a valid ed25519 seed, so this is
    /// infallible apart from the RNG.
    pub fn generate() -> Result<Self, HiveError> {
        let mut seed = [0u8; 32];
        getrandom::getrandom(&mut seed).map_err(|_| HiveError::Key)?;
        Ok(Self {
            signing_key: SigningKey::from_bytes(&seed),
        })
    }

    /// Reconstruct an identity from its 32-byte secret seed (e.g. loaded from the keychain).
    pub fn from_secret_bytes(seed: &[u8; 32]) -> Self {
        Self {
            signing_key: SigningKey::from_bytes(seed),
        }
    }

    /// The base64url public key embedded in facts/manifests as `signer_pubkey`.
    pub fn public_b64url(&self) -> SignerPubkey {
        URL_SAFE_NO_PAD.encode(self.signing_key.verifying_key().to_bytes())
    }

    /// This node's short id, `base64url(SHA-256(pubkey)[..16])`.
    pub fn node_id(&self) -> NodeId {
        node_id_from_pubkey_bytes(&self.signing_key.verifying_key().to_bytes())
    }

    /// Sign a message, returning the detached 64-byte signature as base64url.
    pub fn sign(&self, msg: &[u8]) -> String {
        URL_SAFE_NO_PAD.encode(self.signing_key.sign(msg).to_bytes())
    }
}

/// Derive a [`NodeId`] from raw 32-byte public-key bytes.
pub fn node_id_from_pubkey_bytes(pubkey: &[u8]) -> NodeId {
    let digest = Sha256::digest(pubkey);
    URL_SAFE_NO_PAD.encode(&digest[..16])
}

/// Derive a [`NodeId`] from a base64url public key (as carried in facts/manifests).
pub fn node_id_from_pubkey_b64(pubkey_b64: &str) -> Result<NodeId, HiveError> {
    let bytes = URL_SAFE_NO_PAD
        .decode(pubkey_b64)
        .map_err(|_| HiveError::Base64)?;
    Ok(node_id_from_pubkey_bytes(&bytes))
}

/// Verify a detached signature (base64url) over `msg` against a base64url ed25519 public key.
/// Uses strict verification (rejects the small-order / malleable edge cases).
pub fn verify(pubkey_b64: &str, msg: &[u8], sig_b64: &str) -> Result<(), HiveError> {
    let pk_bytes = URL_SAFE_NO_PAD
        .decode(pubkey_b64)
        .map_err(|_| HiveError::Base64)?;
    let pk_arr: [u8; 32] = pk_bytes.as_slice().try_into().map_err(|_| HiveError::Key)?;
    let vk = VerifyingKey::from_bytes(&pk_arr).map_err(|_| HiveError::Key)?;

    let sig_bytes = URL_SAFE_NO_PAD
        .decode(sig_b64)
        .map_err(|_| HiveError::Base64)?;
    let sig_arr: [u8; 64] = sig_bytes
        .as_slice()
        .try_into()
        .map_err(|_| HiveError::BadSignature)?;
    let sig = Signature::from_bytes(&sig_arr);

    vk.verify_strict(msg, &sig)
        .map_err(|_| HiveError::BadSignature)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_verify_round_trip() {
        let id = NodeIdentity::generate().unwrap();
        let msg = b"vortx-test-message";
        let sig = id.sign(msg);
        assert!(verify(&id.public_b64url(), msg, &sig).is_ok());
    }

    #[test]
    fn tampered_msg_fails_verify() {
        let id = NodeIdentity::generate().unwrap();
        let sig = id.sign(b"original");
        assert!(verify(&id.public_b64url(), b"tampered", &sig).is_err());
    }

    #[test]
    fn wrong_key_fails_verify() {
        let signer = NodeIdentity::generate().unwrap();
        let other = NodeIdentity::generate().unwrap();
        let msg = b"hello";
        let sig = signer.sign(msg);
        assert!(verify(&other.public_b64url(), msg, &sig).is_err());
    }

    #[test]
    fn node_id_decodes_to_16_bytes() {
        let id = NodeIdentity::generate().unwrap();
        let raw = URL_SAFE_NO_PAD.decode(id.node_id()).unwrap();
        assert_eq!(raw.len(), 16);
    }

    #[test]
    fn node_id_is_deterministic_from_pubkey() {
        let id = NodeIdentity::generate().unwrap();
        // Same pubkey -> same node id, via both the identity method and the free function.
        assert_eq!(
            id.node_id(),
            node_id_from_pubkey_b64(&id.public_b64url()).unwrap()
        );
    }

    #[test]
    fn from_secret_bytes_is_stable() {
        let seed = [7u8; 32];
        let a = NodeIdentity::from_secret_bytes(&seed);
        let b = NodeIdentity::from_secret_bytes(&seed);
        assert_eq!(a.public_b64url(), b.public_b64url());
        let sig = a.sign(b"x");
        assert!(verify(&b.public_b64url(), b"x", &sig).is_ok());
    }
}
