//! Native manifest signature verification. A native `vortx-source/1` manifest carries a detached ed25519
//! signature over the CANONICAL bytes of the manifest WITH the `signature` field excluded, so a present
//! signature never changes its own signing input and reformatting the JSON can never invalidate it. The
//! `keyId` is the base64url ed25519 public key (the operator's signing key). Byte-frozen to the Singularity
//! Worker's `manifestSigningBytes`; ed25519 via `vortx-hive` (CryptoKit / WebCrypto / Go compatible), so
//! every surface verifies the same bytes.

use serde::{Deserialize, Serialize};

use crate::canonical::canonicalize;
use crate::manifest::VortxAddonManifest;

/// The trust status of a native manifest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ManifestVerification {
    /// A valid ed25519 signature over the canonical (signature-excluded) bytes.
    Valid,
    /// No signature attached. The default: a source is usable but UNTRUSTED (the host applies its policy).
    Unsigned,
    /// A signature is present but does not verify (tampered, wrong key, non-ed25519 alg, or malformed).
    Invalid,
}

/// The canonical bytes a manifest signature covers: the manifest canonicalized with the `signature` field
/// cleared. Signing (signature absent) and verifying (signature present, cleared here) therefore canonicalize
/// the IDENTICAL bytes. The Worker reproduces these byte-for-byte as `manifestSigningBytes`.
pub fn manifest_signing_bytes(manifest: &VortxAddonManifest) -> Result<Vec<u8>, serde_json::Error> {
    if manifest.signature.is_none() {
        return canonicalize(manifest);
    }
    let mut bare = manifest.clone();
    bare.signature = None;
    canonicalize(&bare)
}

/// Verify a native manifest's detached ed25519 signature over its canonical signing bytes. No signature
/// yields [`ManifestVerification::Unsigned`]; a non-ed25519 alg, a canonicalization failure, or a signature
/// that does not verify (tampered / wrong key / malformed) all yield [`ManifestVerification::Invalid`].
/// Pure and total: never panics.
pub fn verify_manifest(manifest: &VortxAddonManifest) -> ManifestVerification {
    let Some(sig) = manifest.signature.as_ref() else {
        return ManifestVerification::Unsigned;
    };
    if sig.alg != "ed25519" {
        return ManifestVerification::Invalid;
    }
    let Ok(bytes) = manifest_signing_bytes(manifest) else {
        return ManifestVerification::Invalid;
    };
    match vortx_hive::verify(&sig.key_id, &bytes, &sig.sig) {
        Ok(()) => ManifestVerification::Valid,
        Err(_) => ManifestVerification::Invalid,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{ManifestSignature, VortxAddonManifest, VortxTransport};
    use crate::request::ResourceKind;
    use vortx_hive::NodeIdentity;

    fn manifest() -> VortxAddonManifest {
        let mut m = VortxAddonManifest::native(
            "tv.vortx.x",
            "1.0.0",
            "X",
            VortxTransport::StremioHttp {
                manifest_url: "https://x/manifest.vortx.json".into(),
            },
        );
        m.capabilities = vec![ResourceKind::Stream];
        m
    }

    fn signed(m: &VortxAddonManifest, id: &NodeIdentity) -> ManifestSignature {
        let bytes = manifest_signing_bytes(m).unwrap();
        ManifestSignature {
            alg: "ed25519".into(),
            key_id: id.public_b64url(),
            sig: id.sign(&bytes),
        }
    }

    #[test]
    fn an_unsigned_manifest_is_unsigned() {
        assert_eq!(verify_manifest(&manifest()), ManifestVerification::Unsigned);
    }

    #[test]
    fn a_valid_signature_verifies() {
        let id = NodeIdentity::from_secret_bytes(&[7u8; 32]);
        let mut m = manifest();
        m.signature = Some(signed(&m, &id));
        assert_eq!(verify_manifest(&m), ManifestVerification::Valid);
    }

    #[test]
    fn a_tampered_manifest_is_invalid() {
        let id = NodeIdentity::from_secret_bytes(&[7u8; 32]);
        let mut m = manifest();
        m.signature = Some(signed(&m, &id));
        m.name = "Tampered".into(); // mutate a covered field after signing
        assert_eq!(verify_manifest(&m), ManifestVerification::Invalid);
    }

    #[test]
    fn a_wrong_key_is_invalid() {
        let signer = NodeIdentity::from_secret_bytes(&[7u8; 32]);
        let other = NodeIdentity::from_secret_bytes(&[9u8; 32]);
        let mut m = manifest();
        let mut s = signed(&m, &signer);
        s.key_id = other.public_b64url(); // claim a different signer than actually signed
        m.signature = Some(s);
        assert_eq!(verify_manifest(&m), ManifestVerification::Invalid);
    }

    #[test]
    fn a_non_ed25519_alg_is_invalid() {
        let id = NodeIdentity::from_secret_bytes(&[7u8; 32]);
        let mut m = manifest();
        let mut s = signed(&m, &id);
        s.alg = "rsa".into();
        m.signature = Some(s);
        assert_eq!(verify_manifest(&m), ManifestVerification::Invalid);
    }

    #[test]
    fn signing_bytes_exclude_the_signature_field() {
        let id = NodeIdentity::from_secret_bytes(&[7u8; 32]);
        let mut m = manifest();
        let bare = manifest_signing_bytes(&m).unwrap();
        m.signature = Some(signed(&m, &id));
        let with_sig = manifest_signing_bytes(&m).unwrap();
        // The signature field never changes its own signing input: this is what makes sign == verify.
        assert_eq!(bare, with_sig);
    }
}
