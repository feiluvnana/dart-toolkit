//! Digests, checksums, MACs, KDFs, password hashes, ciphers, key agreement and signatures.
//!
//! Digest codes are the Dart `Hash` enum's order: 0 md5, 1 sha1, 2 sha224, 3 sha256, 4 sha384,
//! 5 sha512, 6 sha512/256, 7 sha3-224, 8 sha3-256, 9 sha3-384, 10 sha3-512, 11 keccak256,
//! 12 blake2s, 13 blake2b, 14 blake3, 15 ripemd160, 16 crc32, 17 crc32c, 18 xxh64, 19 xxh3.

use crate::{bytes, bytes_mut, give, guard, text, Handle};
use digest::{Digest, DynDigest};
use hmac::{Hmac, Mac};
use password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use rand_core::OsRng;

/// Expands `$f!(DigestType)` for the cryptographic digest with code `$alg`; BLAKE2 buffers
/// lazily and cannot feed `Hmac`, so MAC contexts pass `no_mac` as `$b`.
macro_rules! with_digest {
    ($alg:expr, $f:ident) => {
        with_digest!($alg, $f, $f)
    };
    ($alg:expr, $f:ident, $b:ident) => {
        match $alg {
            0 => $f!(md5::Md5),
            1 => $f!(sha1::Sha1),
            2 => $f!(sha2::Sha224),
            3 => $f!(sha2::Sha256),
            4 => $f!(sha2::Sha384),
            5 => $f!(sha2::Sha512),
            6 => $f!(sha2::Sha512_256),
            7 => $f!(sha3::Sha3_224),
            8 => $f!(sha3::Sha3_256),
            9 => $f!(sha3::Sha3_384),
            10 => $f!(sha3::Sha3_512),
            11 => $f!(sha3::Keccak256),
            12 => $b!(blake2::Blake2s256),
            13 => $b!(blake2::Blake2b512),
            15 => $f!(ripemd::Ripemd160),
            other => Err(format!("digest {} is not a cryptographic hash here", other)),
        }
    };
}

/// SHA-2 only, for RSA.
macro_rules! with_sha2 {
    ($alg:expr, $f:ident) => {
        match $alg {
            3 => $f!(sha2::Sha256),
            4 => $f!(sha2::Sha384),
            5 => $f!(sha2::Sha512),
            other => Err(format!("rsa: digest {} is not SHA-2", other)),
        }
    };
}

// ---- Digests and checksums, streaming

enum Running {
    Dyn(Box<dyn DynDigest>),
    Blake3(blake3::Hasher),
    Crc32(crc32fast::Hasher),
    Crc32c(u32),
    Xxh64(xxhash_rust::xxh64::Xxh64),
    Xxh3(xxhash_rust::xxh3::Xxh3),
}

impl Running {
    fn new(alg: u32) -> Result<Running, String> {
        macro_rules! boxed {
            ($t:ty) => {
                Ok(Running::Dyn(Box::new(<$t>::new())))
            };
        }
        match alg {
            14 => Ok(Running::Blake3(blake3::Hasher::new())),
            16 => Ok(Running::Crc32(crc32fast::Hasher::new())),
            17 => Ok(Running::Crc32c(0)),
            18 => Ok(Running::Xxh64(xxhash_rust::xxh64::Xxh64::new(0))),
            19 => Ok(Running::Xxh3(xxhash_rust::xxh3::Xxh3::new())),
            _ => with_digest!(alg, boxed),
        }
    }

    fn update(&mut self, data: &[u8]) {
        match self {
            Running::Dyn(d) => d.update(data),
            Running::Blake3(b) => {
                b.update(data);
            }
            Running::Crc32(c) => c.update(data),
            Running::Crc32c(c) => *c = crc32c::crc32c_append(*c, data),
            Running::Xxh64(x) => x.update(data),
            Running::Xxh3(x) => x.update(data),
        }
    }

    fn finish(self) -> Vec<u8> {
        match self {
            Running::Dyn(d) => d.finalize().to_vec(),
            Running::Blake3(b) => b.finalize().as_bytes().to_vec(),
            Running::Crc32(c) => c.finalize().to_be_bytes().to_vec(),
            Running::Crc32c(c) => c.to_be_bytes().to_vec(),
            Running::Xxh64(x) => x.digest().to_be_bytes().to_vec(),
            Running::Xxh3(x) => x.digest().to_be_bytes().to_vec(),
        }
    }
}

#[no_mangle]
pub extern "C" fn tk_digest_new(alg: u32) -> Handle {
    match Running::new(alg) {
        Ok(d) => Box::into_raw(Box::new(d)) as Handle,
        Err(m) => {
            crate::set_error(&m);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tk_digest_update(h: Handle, ptr: *const u8, len: usize) {
    if !h.is_null() {
        (*(h as *mut Running)).update(bytes(ptr, len));
    }
}

/// Finishes the digest into `out` (at least 64 bytes) and frees the handle; returns the length.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_final(h: Handle, out: *mut u8) -> i32 {
    if h.is_null() {
        return -1;
    }
    let result = Box::from_raw(h as *mut Running).finish();
    bytes_mut(out, result.len()).copy_from_slice(&result);
    result.len() as i32
}

/// One-shot digest of `data` into `out` (at least 64 bytes); returns the length.
#[no_mangle]
pub unsafe extern "C" fn tk_digest(alg: u32, data: *const u8, len: usize, out: *mut u8) -> i32 {
    guard(|| {
        let mut d = Running::new(alg)?;
        d.update(bytes(data, len));
        let result = d.finish();
        bytes_mut(out, result.len()).copy_from_slice(&result);
        Ok(result.len() as i32)
    })
}

// ---- MACs and KDFs

macro_rules! no_mac {
    ($t:ty) => {
        Err("HMAC over BLAKE2 is not supported; BLAKE2 has its own keyed mode".to_string())
    };
}

fn put(out: *mut u8, data: &[u8]) -> Result<i32, String> {
    unsafe { bytes_mut(out, data.len()) }.copy_from_slice(data);
    Ok(data.len() as i32)
}

#[no_mangle]
pub unsafe extern "C" fn tk_hmac(alg: u32, key: *const u8, klen: usize, data: *const u8, dlen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let (key, data) = (bytes(key, klen), bytes(data, dlen));
        macro_rules! run {
            ($t:ty) => {{
                let mut m = <Hmac<$t> as Mac>::new_from_slice(key).map_err(|e| e.to_string())?;
                Mac::update(&mut m, data);
                put(out, &m.finalize().into_bytes())
            }};
        }
        with_digest!(alg, run, no_mac)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_pbkdf2(alg: u32, pw: *const u8, plen: usize, salt: *const u8, slen: usize, iters: u32, out: *mut u8, olen: usize) -> i32 {
    guard(|| {
        let (pw, salt, out) = (bytes(pw, plen), bytes(salt, slen), bytes_mut(out, olen));
        macro_rules! run {
            ($t:ty) => {
                pbkdf2::pbkdf2::<Hmac<$t>>(pw, salt, iters, out).map(|_| olen as i32).map_err(|e| e.to_string())
            };
        }
        with_digest!(alg, run, no_mac)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_hkdf(alg: u32, ikm: *const u8, ilen: usize, salt: *const u8, slen: usize, info: *const u8, nlen: usize, out: *mut u8, olen: usize) -> i32 {
    guard(|| {
        let (ikm, info, out) = (bytes(ikm, ilen), bytes(info, nlen), bytes_mut(out, olen));
        let salt = if slen == 0 { None } else { Some(bytes(salt, slen)) };
        macro_rules! run {
            ($t:ty) => {
                hkdf::Hkdf::<$t>::new(salt, ikm).expand(info, out).map(|_| olen as i32).map_err(|e| e.to_string())
            };
        }
        with_digest!(alg, run, no_mac)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_argon2id(pw: *const u8, plen: usize, salt: *const u8, slen: usize, mem_kib: u32, iters: u32, par: u32, out: *mut u8, olen: usize) -> i32 {
    guard(|| {
        let params = argon2::Params::new(mem_kib, iters, par, Some(olen)).map_err(|e| e.to_string())?;
        argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params)
            .hash_password_into(bytes(pw, plen), bytes(salt, slen), bytes_mut(out, olen))
            .map_err(|e| e.to_string())?;
        Ok(olen as i32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_scrypt(pw: *const u8, plen: usize, salt: *const u8, slen: usize, log_n: u32, r: u32, p: u32, out: *mut u8, olen: usize) -> i32 {
    guard(|| {
        let params = scrypt::Params::new(log_n as u8, r, p, olen).map_err(|e| e.to_string())?;
        scrypt::scrypt(bytes(pw, plen), bytes(salt, slen), &params, bytes_mut(out, olen)).map_err(|e| e.to_string())?;
        Ok(olen as i32)
    })
}

// ---- Password hashes in their standard string forms

/// `alg`: 0 argon2id (a=memory KiB, b=iterations, c=parallelism), 1 bcrypt (a=cost),
/// 2 scrypt (a=log2 N, b=r, c=p), 3 pbkdf2 (a=iterations, b=3 for SHA-256 or 5 for SHA-512). Writes the PHC or MCF string.
#[no_mangle]
pub unsafe extern "C" fn tk_password_hash(alg: u32, a: u32, b: u32, c: u32, pw: *const u8, plen: usize, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let pw = bytes(pw, plen);
        let salt = SaltString::generate(&mut OsRng);
        let s = match alg {
            0 => {
                let params = argon2::Params::new(a, b, c, None).map_err(|e| e.to_string())?;
                argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params)
                    .hash_password(pw, &salt)
                    .map_err(|e| e.to_string())?
                    .to_string()
            }
            1 => bcrypt::hash(pw, a).map_err(|e| e.to_string())?,
            2 => {
                let params = scrypt::Params::new(a as u8, b, c, 32).map_err(|e| e.to_string())?;
                scrypt::Scrypt.hash_password_customized(pw, None, None, params, &salt).map_err(|e| e.to_string())?.to_string()
            }
            3 => {
                let params = pbkdf2::Params { rounds: a, output_length: 32 };
                let ident = if b == 5 { pbkdf2::Algorithm::Pbkdf2Sha512 } else { pbkdf2::Algorithm::Pbkdf2Sha256 }.ident();
                pbkdf2::Pbkdf2
                    .hash_password_customized(pw, Some(ident), None, params, &salt)
                    .map_err(|e| e.to_string())?
                    .to_string()
            }
            _ => return Err(format!("unknown password hash {}", alg)),
        };
        Ok(give(s.into_bytes(), out_ptr, out_len))
    })
}

/// 1 when `pw` produced `hash` (bcrypt `$2*$`, or PHC argon2/scrypt/pbkdf2), 0 when not, -1 when malformed.
#[no_mangle]
pub unsafe extern "C" fn tk_password_verify(pw: *const u8, plen: usize, hash: *const u8, hlen: usize) -> i32 {
    guard(|| {
        let (pw, hash) = (bytes(pw, plen), text(hash, hlen)?);
        if hash.starts_with("$2") {
            return Ok(bcrypt::verify(pw, hash).map_err(|e| e.to_string())? as i32);
        }
        let parsed = PasswordHash::new(hash).map_err(|e| e.to_string())?;
        let ok = match parsed.algorithm.as_str() {
            "argon2id" | "argon2i" | "argon2d" => argon2::Argon2::default().verify_password(pw, &parsed),
            "scrypt" => scrypt::Scrypt.verify_password(pw, &parsed),
            a if a.starts_with("pbkdf2") => pbkdf2::Pbkdf2.verify_password(pw, &parsed),
            other => return Err(format!("unknown password hash {}", other)),
        };
        Ok(ok.is_ok() as i32)
    })
}

// ---- Ciphers: 0 AES-GCM (key 16/32, nonce 12), 1 ChaCha20-Poly1305 (key 32, nonce 12),
//      2 XChaCha20-Poly1305 (key 32, nonce 24), 3 AES-CBC/PKCS#7 (key 16/32, iv 16, no aad, no tag).

use aes_gcm::aead::{self, Aead, KeyInit as AeadKeyInit, Payload};

const NOT_AUTHENTIC: &str = "authentication failed";

fn aead<C: Aead + AeadKeyInit>(key: &[u8], nonce: &[u8], payload: Payload, seal: bool) -> Result<Vec<u8>, String> {
    let c = C::new_from_slice(key).map_err(|_| "wrong key length".to_string())?;
    let n = aead::Nonce::<C>::from_slice(nonce);
    if seal { c.encrypt(n, payload) } else { c.decrypt(n, payload) }.map_err(|_| if seal { "seal failed".into() } else { NOT_AUTHENTIC.into() })
}

fn cbc(key: &[u8], iv: &[u8], input: &[u8], seal: bool) -> Result<Vec<u8>, String> {
    use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
    macro_rules! run {
        ($t:ty) => {
            if seal {
                Ok(cbc::Encryptor::<$t>::new_from_slices(key, iv).map_err(|e| e.to_string())?.encrypt_padded_vec_mut::<Pkcs7>(input))
            } else {
                cbc::Decryptor::<$t>::new_from_slices(key, iv).map_err(|e| e.to_string())?.decrypt_padded_vec_mut::<Pkcs7>(input).map_err(|_| NOT_AUTHENTIC.to_string())
            }
        };
    }
    match key.len() {
        16 => run!(aes::Aes128),
        32 => run!(aes::Aes256),
        _ => Err("AES key must be 16 or 32 bytes".into()),
    }
}

fn cipher_op(alg: u32, key: &[u8], nonce: &[u8], aad: &[u8], input: &[u8], seal: bool) -> Result<Vec<u8>, String> {
    let want = match alg {
        2 => 24,
        3 => 16,
        _ => 12,
    };
    if nonce.len() != want {
        return Err(format!("nonce must be {} bytes", want));
    }
    let payload = Payload { msg: input, aad };
    match (alg, key.len()) {
        (0, 32) => aead::<aes_gcm::Aes256Gcm>(key, nonce, payload, seal),
        (0, 16) => aead::<aes_gcm::Aes128Gcm>(key, nonce, payload, seal),
        (0, _) => Err("AES-GCM key must be 16 or 32 bytes".into()),
        (1, _) => aead::<chacha20poly1305::ChaCha20Poly1305>(key, nonce, payload, seal),
        (2, _) => aead::<chacha20poly1305::XChaCha20Poly1305>(key, nonce, payload, seal),
        (3, _) if aad.is_empty() => cbc(key, nonce, input, seal),
        (3, _) => Err("AES-CBC cannot authenticate aad; use AES-GCM".into()),
        _ => Err(format!("unknown cipher {}", alg)),
    }
}

/// Encrypts `plain` into `out` (capacity plen + 16); returns the length written.
#[no_mangle]
pub unsafe extern "C" fn tk_seal(alg: u32, key: *const u8, klen: usize, nonce: *const u8, nlen: usize, aad: *const u8, alen: usize, plain: *const u8, plen: usize, out: *mut u8) -> i32 {
    guard(|| put(out, &cipher_op(alg, bytes(key, klen), bytes(nonce, nlen), bytes(aad, alen), bytes(plain, plen), true)?))
}

/// Decrypts `sealed` into `out` (capacity slen); returns the length, or -3 when authentication fails.
#[no_mangle]
pub unsafe extern "C" fn tk_open(alg: u32, key: *const u8, klen: usize, nonce: *const u8, nlen: usize, aad: *const u8, alen: usize, sealed: *const u8, slen: usize, out: *mut u8) -> i32 {
    guard(|| match cipher_op(alg, bytes(key, klen), bytes(nonce, nlen), bytes(aad, alen), bytes(sealed, slen), false) {
        Ok(pt) => put(out, &pt),
        Err(m) if m == NOT_AUTHENTIC => Ok(-3),
        Err(m) => Err(m),
    })
}

// ---- Key agreement

#[no_mangle]
pub unsafe extern "C" fn tk_x25519_public(sk: *const u8, out: *mut u8) -> i32 {
    guard(|| {
        let secret = x25519_dalek::StaticSecret::from(<[u8; 32]>::try_from(bytes(sk, 32)).map_err(|_| "key must be 32 bytes")?);
        put(out, x25519_dalek::PublicKey::from(&secret).as_bytes())
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_x25519_agree(sk: *const u8, pk: *const u8, out: *mut u8) -> i32 {
    guard(|| {
        let secret = x25519_dalek::StaticSecret::from(<[u8; 32]>::try_from(bytes(sk, 32)).map_err(|_| "key must be 32 bytes")?);
        let public = x25519_dalek::PublicKey::from(<[u8; 32]>::try_from(bytes(pk, 32)).map_err(|_| "public key must be 32 bytes")?);
        let shared = secret.diffie_hellman(&public);
        if !shared.was_contributory() {
            return Err("low-order public key".into());
        }
        put(out, shared.as_bytes())
    })
}

/// ECDH over P-256: the shared x coordinate (32 bytes).
#[no_mangle]
pub unsafe extern "C" fn tk_p256_agree(sk: *const u8, pk: *const u8, pklen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let secret = p256::SecretKey::from_slice(bytes(sk, 32)).map_err(|e| e.to_string())?;
        let public = p256::PublicKey::from_sec1_bytes(bytes(pk, pklen)).map_err(|e| e.to_string())?;
        let shared = p256::ecdh::diffie_hellman(secret.to_nonzero_scalar(), public.as_affine());
        put(out, shared.raw_secret_bytes())
    })
}

// ---- Signatures

use signature::{RandomizedSigner, Signer, Verifier};

fn ed25519_key(seed: &[u8]) -> Result<ed25519_dalek::SigningKey, String> {
    Ok(ed25519_dalek::SigningKey::from_bytes(seed.try_into().map_err(|_| "seed must be 32 bytes")?))
}

#[no_mangle]
pub unsafe extern "C" fn tk_ed25519_public(seed: *const u8, out: *mut u8) -> i32 {
    guard(|| put(out, ed25519_key(bytes(seed, 32))?.verifying_key().as_bytes()))
}

#[no_mangle]
pub unsafe extern "C" fn tk_ed25519_sign(seed: *const u8, msg: *const u8, mlen: usize, out: *mut u8) -> i32 {
    guard(|| put(out, &ed25519_key(bytes(seed, 32))?.sign(bytes(msg, mlen)).to_bytes()))
}

#[no_mangle]
pub unsafe extern "C" fn tk_ed25519_verify(pk: *const u8, msg: *const u8, mlen: usize, sig: *const u8) -> i32 {
    guard(|| {
        let vk = ed25519_dalek::VerifyingKey::from_bytes(bytes(pk, 32).try_into().map_err(|_| "public key must be 32 bytes")?).map_err(|e| e.to_string())?;
        let sig = ed25519_dalek::Signature::from_bytes(bytes(sig, 64).try_into().map_err(|_| "signature must be 64 bytes")?);
        Ok(vk.verify(bytes(msg, mlen), &sig).is_ok() as i32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_p256_public(sk: *const u8, out: *mut u8) -> i32 {
    guard(|| {
        let k = p256::ecdsa::SigningKey::from_slice(bytes(sk, 32)).map_err(|e| e.to_string())?;
        put(out, k.verifying_key().to_encoded_point(false).as_bytes())
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_p256_sign(sk: *const u8, msg: *const u8, mlen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let k = p256::ecdsa::SigningKey::from_slice(bytes(sk, 32)).map_err(|e| e.to_string())?;
        let sig: p256::ecdsa::Signature = k.sign(bytes(msg, mlen));
        put(out, &sig.to_bytes())
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_p256_verify(pk: *const u8, pklen: usize, msg: *const u8, mlen: usize, sig: *const u8) -> i32 {
    guard(|| {
        let vk = p256::ecdsa::VerifyingKey::from_sec1_bytes(bytes(pk, pklen)).map_err(|e| e.to_string())?;
        let sig = p256::ecdsa::Signature::from_slice(bytes(sig, 64)).map_err(|e| e.to_string())?;
        Ok(vk.verify(bytes(msg, mlen), &sig).is_ok() as i32)
    })
}

// ---- PEM for Ed25519 (kind 0) and P-256 (kind 1): PKCS#8 private keys, SPKI public keys.

use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey, EncodePublicKey, LineEnding};

/// The PKCS#8 PEM of the private key, or with `public` the SPKI PEM of its public key.
#[no_mangle]
pub unsafe extern "C" fn tk_key_to_pem(kind: u32, key: *const u8, public: i32, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let key = bytes(key, 32);
        let pem = match (kind, public != 0) {
            (0, false) => ed25519_key(key)?.to_pkcs8_pem(LineEnding::LF).map_err(|e| e.to_string())?.to_string(),
            (0, true) => ed25519_key(key)?.verifying_key().to_public_key_pem(LineEnding::LF).map_err(|e| e.to_string())?,
            (1, false) => p256::SecretKey::from_slice(key).map_err(|e| e.to_string())?.to_pkcs8_pem(LineEnding::LF).map_err(|e| e.to_string())?.to_string(),
            (1, true) => p256::SecretKey::from_slice(key).map_err(|e| e.to_string())?.public_key().to_public_key_pem(LineEnding::LF).map_err(|e| e.to_string())?,
            _ => return Err(format!("unknown key kind {}", kind)),
        };
        Ok(give(pem.into_bytes(), out_ptr, out_len))
    })
}

/// The 32-byte private key (seed or scalar) inside a PKCS#8 or SEC1 PEM.
#[no_mangle]
pub unsafe extern "C" fn tk_private_from_pem(kind: u32, pem: *const u8, plen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let pem = text(pem, plen)?;
        match kind {
            0 => put(out, ed25519_dalek::SigningKey::from_pkcs8_pem(pem).map_err(|e| e.to_string())?.as_bytes()),
            1 => {
                let k = p256::SecretKey::from_pkcs8_pem(pem).or_else(|_| p256::SecretKey::from_sec1_pem(pem)).map_err(|e| e.to_string())?;
                put(out, &k.to_bytes())
            }
            _ => Err(format!("unknown key kind {}", kind)),
        }
    })
}

/// The public key inside an SPKI PEM: 32 bytes for Ed25519, 65 (uncompressed SEC1) for P-256.
#[no_mangle]
pub unsafe extern "C" fn tk_public_from_pem(kind: u32, pem: *const u8, plen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let pem = text(pem, plen)?;
        match kind {
            0 => put(out, ed25519_dalek::VerifyingKey::from_public_key_pem(pem).map_err(|e| e.to_string())?.as_bytes()),
            1 => put(out, p256::PublicKey::from_public_key_pem(pem).map_err(|e| e.to_string())?.to_encoded_point(false).as_bytes()),
            _ => Err(format!("unknown key kind {}", kind)),
        }
    })
}

// ---- RSA: PKCS#1 v1.5 and PSS signatures, OAEP encryption; keys as PEM.

use rsa::pkcs1::{DecodeRsaPrivateKey, DecodeRsaPublicKey};

fn rsa_private(pem: &str) -> Result<rsa::RsaPrivateKey, String> {
    rsa::RsaPrivateKey::from_pkcs8_pem(pem).or_else(|_| rsa::RsaPrivateKey::from_pkcs1_pem(pem)).map_err(|e| e.to_string())
}

/// A public key from an SPKI or PKCS#1 public PEM, or the public half of a private PEM.
fn rsa_public(pem: &str) -> Result<rsa::RsaPublicKey, String> {
    rsa::RsaPublicKey::from_public_key_pem(pem)
        .or_else(|_| rsa::RsaPublicKey::from_pkcs1_pem(pem))
        .or_else(|_| rsa_private(pem).map(|k| k.to_public_key()))
        .map_err(|e| e.to_string())
}

/// A fresh private key of `bits` as PKCS#8 PEM.
#[no_mangle]
pub unsafe extern "C" fn tk_rsa_generate(bits: u32, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let key = rsa::RsaPrivateKey::new(&mut OsRng, bits as usize).map_err(|e| e.to_string())?;
        let pem = key.to_pkcs8_pem(LineEnding::LF).map_err(|e| e.to_string())?.to_string();
        Ok(give(pem.into_bytes(), out_ptr, out_len))
    })
}

/// The SPKI PEM of the public key in `pem` (a private or public key).
#[no_mangle]
pub unsafe extern "C" fn tk_rsa_public_pem(pem: *const u8, plen: usize, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let pem = rsa_public(text(pem, plen)?)?.to_public_key_pem(LineEnding::LF).map_err(|e| e.to_string())?;
        Ok(give(pem.into_bytes(), out_ptr, out_len))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_rsa_sign(pem: *const u8, plen: usize, alg: u32, pss: i32, msg: *const u8, mlen: usize, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let key = rsa_private(text(pem, plen)?)?;
        let msg = bytes(msg, mlen);
        macro_rules! run {
            ($t:ty) => {
                Ok(if pss != 0 {
                    Box::<[u8]>::from(rsa::pss::SigningKey::<$t>::new(key).sign_with_rng(&mut OsRng, msg)).into_vec()
                } else {
                    Box::<[u8]>::from(rsa::pkcs1v15::SigningKey::<$t>::new(key).sign(msg)).into_vec()
                })
            };
        }
        let sig: Vec<u8> = with_sha2!(alg, run)?;
        Ok(give(sig, out_ptr, out_len))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_rsa_verify(pem: *const u8, plen: usize, alg: u32, pss: i32, msg: *const u8, mlen: usize, sig: *const u8, slen: usize) -> i32 {
    guard(|| {
        let key = rsa_public(text(pem, plen)?)?;
        let (msg, sig) = (bytes(msg, mlen), bytes(sig, slen));
        macro_rules! run {
            ($t:ty) => {
                Ok(if pss != 0 {
                    rsa::pss::Signature::try_from(sig).map(|s| rsa::pss::VerifyingKey::<$t>::new(key).verify(msg, &s).is_ok()).unwrap_or(false)
                } else {
                    rsa::pkcs1v15::Signature::try_from(sig).map(|s| rsa::pkcs1v15::VerifyingKey::<$t>::new(key).verify(msg, &s).is_ok()).unwrap_or(false)
                })
            };
        }
        let ok: bool = with_sha2!(alg, run)?;
        Ok(ok as i32)
    })
}

/// RSA-OAEP with the SHA-2 digest `alg`.
#[no_mangle]
pub unsafe extern "C" fn tk_rsa_encrypt(pem: *const u8, plen: usize, alg: u32, msg: *const u8, mlen: usize, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let key = rsa_public(text(pem, plen)?)?;
        macro_rules! run {
            ($t:ty) => {
                key.encrypt(&mut OsRng, rsa::Oaep::new::<$t>(), bytes(msg, mlen)).map_err(|e| e.to_string())
            };
        }
        let ct: Vec<u8> = with_sha2!(alg, run)?;
        Ok(give(ct, out_ptr, out_len))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_rsa_decrypt(pem: *const u8, plen: usize, alg: u32, ct: *const u8, clen: usize, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let key = rsa_private(text(pem, plen)?)?;
        macro_rules! run {
            ($t:ty) => {
                key.decrypt(rsa::Oaep::new::<$t>(), bytes(ct, clen)).map_err(|_| NOT_AUTHENTIC.to_string())
            };
        }
        let pt: Vec<u8> = with_sha2!(alg, run)?;
        Ok(give(pt, out_ptr, out_len))
    })
}
