//! Digests, MACs, KDFs, AEAD and signatures.

use crate::{bytes, bytes_mut, guard, text, Handle};
use digest::{Digest, DynDigest};
use hmac::{Hmac, Mac};

/// A running digest; blake3 has its own type, the rest share `DynDigest`.
enum Running {
    Dyn(Box<dyn DynDigest>),
    Blake3(blake3::Hasher),
}

impl Running {
    fn new(alg: u32) -> Result<Running, String> {
        Ok(Running::Dyn(match alg {
            0 => Box::new(md5::Md5::new()),
            1 => Box::new(sha1::Sha1::new()),
            2 => Box::new(sha2::Sha224::new()),
            3 => Box::new(sha2::Sha256::new()),
            4 => Box::new(sha2::Sha384::new()),
            5 => Box::new(sha2::Sha512::new()),
            6 => Box::new(sha3::Sha3_256::new()),
            7 => Box::new(sha3::Sha3_512::new()),
            8 => Box::new(blake2::Blake2b512::new()),
            9 => return Ok(Running::Blake3(blake3::Hasher::new())),
            _ => return Err(format!("unknown digest {}", alg)),
        }))
    }
}

#[no_mangle]
pub extern "C" fn tk_digest_new(alg: u32) -> Handle {
    match Running::new(alg) {
        Ok(d) => Box::into_raw(Box::new(d)) as Handle,
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tk_digest_update(h: Handle, ptr: *const u8, len: usize) {
    if h.is_null() {
        return;
    }
    match &mut *(h as *mut Running) {
        Running::Dyn(d) => d.update(bytes(ptr, len)),
        Running::Blake3(b) => {
            b.update(bytes(ptr, len));
        }
    }
}

/// Finishes the digest into `out` (at least 64 bytes) and frees the handle; returns the length.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_final(h: Handle, out: *mut u8) -> i32 {
    if h.is_null() {
        return -1;
    }
    let result: Vec<u8> = match *Box::from_raw(h as *mut Running) {
        Running::Dyn(d) => d.finalize().to_vec(),
        Running::Blake3(b) => b.finalize().as_bytes().to_vec(),
    };
    bytes_mut(out, result.len()).copy_from_slice(&result);
    result.len() as i32
}

macro_rules! hmac_with {
    ($t:ty, $key:expr, $data:expr, $out:expr) => {{
        let mut m = <Hmac<$t> as Mac>::new_from_slice($key).map_err(|e| e.to_string())?;
        Mac::update(&mut m, $data);
        let r = m.finalize().into_bytes();
        bytes_mut($out, r.len()).copy_from_slice(&r);
        Ok(r.len() as i32)
    }};
}

#[no_mangle]
pub unsafe extern "C" fn tk_hmac(alg: u32, key: *const u8, klen: usize, data: *const u8, dlen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let (key, data) = (bytes(key, klen), bytes(data, dlen));
        match alg {
            0 => hmac_with!(md5::Md5, key, data, out),
            1 => hmac_with!(sha1::Sha1, key, data, out),
            2 => hmac_with!(sha2::Sha224, key, data, out),
            3 => hmac_with!(sha2::Sha256, key, data, out),
            4 => hmac_with!(sha2::Sha384, key, data, out),
            5 => hmac_with!(sha2::Sha512, key, data, out),
            6 => hmac_with!(sha3::Sha3_256, key, data, out),
            7 => hmac_with!(sha3::Sha3_512, key, data, out),
            _ => Err(format!("hmac: unsupported digest {}", alg)),
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_pbkdf2(alg: u32, pw: *const u8, plen: usize, salt: *const u8, slen: usize, iters: u32, out: *mut u8, olen: usize) -> i32 {
    guard(|| {
        let (pw, salt, out) = (bytes(pw, plen), bytes(salt, slen), bytes_mut(out, olen));
        match alg {
            1 => pbkdf2::pbkdf2::<Hmac<sha1::Sha1>>(pw, salt, iters, out),
            3 => pbkdf2::pbkdf2::<Hmac<sha2::Sha256>>(pw, salt, iters, out),
            5 => pbkdf2::pbkdf2::<Hmac<sha2::Sha512>>(pw, salt, iters, out),
            _ => return Err(format!("pbkdf2: unsupported digest {}", alg)),
        }
        .map_err(|e| e.to_string())?;
        Ok(olen as i32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_hkdf(alg: u32, ikm: *const u8, ilen: usize, salt: *const u8, slen: usize, info: *const u8, nlen: usize, out: *mut u8, olen: usize) -> i32 {
    guard(|| {
        let (ikm, info, out) = (bytes(ikm, ilen), bytes(info, nlen), bytes_mut(out, olen));
        let salt = if slen == 0 { None } else { Some(bytes(salt, slen)) };
        match alg {
            3 => hkdf::Hkdf::<sha2::Sha256>::new(salt, ikm).expand(info, out),
            5 => hkdf::Hkdf::<sha2::Sha512>::new(salt, ikm).expand(info, out),
            _ => return Err(format!("hkdf: unsupported digest {}", alg)),
        }
        .map_err(|e| e.to_string())?;
        Ok(olen as i32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_argon2id(pw: *const u8, plen: usize, salt: *const u8, slen: usize, mem_kib: u32, iters: u32, par: u32, out: *mut u8, olen: usize) -> i32 {
    guard(|| {
        let params = argon2::Params::new(mem_kib, iters, par, Some(olen)).map_err(|e| e.to_string())?;
        let a = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
        a.hash_password_into(bytes(pw, plen), bytes(salt, slen), bytes_mut(out, olen)).map_err(|e| e.to_string())?;
        Ok(olen as i32)
    })
}

// ---- AEAD: 0 = AES-GCM (key 16 or 32), 1 = ChaCha20-Poly1305 (key 32). Nonce 12 bytes.

use aes_gcm::aead;
use aead::{Aead, Payload};
use aead::KeyInit as AeadKeyInit;

fn aead_op(alg: u32, key: &[u8], nonce: &[u8], aad: &[u8], input: &[u8], seal: bool) -> Result<Vec<u8>, String> {
    if nonce.len() != 12 {
        return Err("nonce must be 12 bytes".into());
    }
    let n = aead::Nonce::<aes_gcm::Aes256Gcm>::from_slice(nonce);
    let payload = Payload { msg: input, aad };
    let r = match (alg, key.len()) {
        (0, 32) => {
            let c = <aes_gcm::Aes256Gcm as AeadKeyInit>::new_from_slice(key).map_err(|e| e.to_string())?;
            if seal { c.encrypt(n, payload) } else { c.decrypt(n, payload) }
        }
        (0, 16) => {
            let c = <aes_gcm::Aes128Gcm as AeadKeyInit>::new_from_slice(key).map_err(|e| e.to_string())?;
            if seal { c.encrypt(n, payload) } else { c.decrypt(n, payload) }
        }
        (1, 32) => {
            let c = <chacha20poly1305::ChaCha20Poly1305 as AeadKeyInit>::new_from_slice(key).map_err(|e| e.to_string())?;
            let n = chacha20poly1305::Nonce::from_slice(nonce);
            if seal { c.encrypt(n, payload) } else { c.decrypt(n, payload) }
        }
        (0, _) => return Err("AES-GCM key must be 16 or 32 bytes".into()),
        (1, _) => return Err("ChaCha20-Poly1305 key must be 32 bytes".into()),
        _ => return Err(format!("unknown AEAD {}", alg)),
    };
    r.map_err(|_| if seal { "seal failed".to_string() } else { "authentication failed".to_string() })
}

/// Encrypts `plain` into `out` (capacity plen + 16); returns the length written.
#[no_mangle]
pub unsafe extern "C" fn tk_seal(alg: u32, key: *const u8, klen: usize, nonce: *const u8, nlen: usize, aad: *const u8, alen: usize, plain: *const u8, plen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let ct = aead_op(alg, bytes(key, klen), bytes(nonce, nlen), bytes(aad, alen), bytes(plain, plen), true)?;
        bytes_mut(out, ct.len()).copy_from_slice(&ct);
        Ok(ct.len() as i32)
    })
}

/// Decrypts `sealed` into `out` (capacity slen); returns the length, or -3 when authentication fails.
#[no_mangle]
pub unsafe extern "C" fn tk_open(alg: u32, key: *const u8, klen: usize, nonce: *const u8, nlen: usize, aad: *const u8, alen: usize, sealed: *const u8, slen: usize, out: *mut u8) -> i32 {
    guard(|| match aead_op(alg, bytes(key, klen), bytes(nonce, nlen), bytes(aad, alen), bytes(sealed, slen), false) {
        Ok(pt) => {
            bytes_mut(out, pt.len()).copy_from_slice(&pt);
            Ok(pt.len() as i32)
        }
        Err(m) if m == "authentication failed" => Ok(-3),
        Err(m) => Err(m),
    })
}

// ---- Signatures

use signature::{Signer, Verifier};

#[no_mangle]
pub unsafe extern "C" fn tk_ed25519_public(seed: *const u8, out: *mut u8) -> i32 {
    guard(|| {
        let sk = ed25519_dalek::SigningKey::from_bytes(bytes(seed, 32).try_into().map_err(|_| "seed must be 32 bytes")?);
        bytes_mut(out, 32).copy_from_slice(sk.verifying_key().as_bytes());
        Ok(32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_ed25519_sign(seed: *const u8, msg: *const u8, mlen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let sk = ed25519_dalek::SigningKey::from_bytes(bytes(seed, 32).try_into().map_err(|_| "seed must be 32 bytes")?);
        let sig = sk.sign(bytes(msg, mlen));
        bytes_mut(out, 64).copy_from_slice(&sig.to_bytes());
        Ok(64)
    })
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
        let point = k.verifying_key().to_encoded_point(false);
        bytes_mut(out, 65).copy_from_slice(point.as_bytes());
        Ok(65)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_p256_sign(sk: *const u8, msg: *const u8, mlen: usize, out: *mut u8) -> i32 {
    guard(|| {
        let k = p256::ecdsa::SigningKey::from_slice(bytes(sk, 32)).map_err(|e| e.to_string())?;
        let sig: p256::ecdsa::Signature = k.sign(bytes(msg, mlen));
        bytes_mut(out, 64).copy_from_slice(&sig.to_bytes());
        Ok(64)
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

/// RSA PKCS#1 v1.5 verification with SHA-256 (alg 3) or SHA-512 (alg 5); `pem` is SPKI or PKCS#1.
#[no_mangle]
pub unsafe extern "C" fn tk_rsa_verify(pem: *const u8, plen: usize, alg: u32, msg: *const u8, mlen: usize, sig: *const u8, slen: usize) -> i32 {
    guard(|| {
        use rsa::pkcs1::DecodeRsaPublicKey;
        use rsa::pkcs8::DecodePublicKey;
        let pem = text(pem, plen)?;
        let key = rsa::RsaPublicKey::from_public_key_pem(pem)
            .or_else(|_| rsa::RsaPublicKey::from_pkcs1_pem(pem))
            .map_err(|e| e.to_string())?;
        let ok = match alg {
            3 => rsa::pkcs1v15::VerifyingKey::<sha2::Sha256>::new(key).verify(bytes(msg, mlen), &rsa::pkcs1v15::Signature::try_from(bytes(sig, slen)).map_err(|e| e.to_string())?).is_ok(),
            5 => rsa::pkcs1v15::VerifyingKey::<sha2::Sha512>::new(key).verify(bytes(msg, mlen), &rsa::pkcs1v15::Signature::try_from(bytes(sig, slen)).map_err(|e| e.to_string())?).is_ok(),
            _ => return Err(format!("rsa: unsupported digest {}", alg)),
        };
        Ok(ok as i32)
    })
}

/// CRC-32 (IEEE) of `data`, continuing from `seed` (0 to start).
#[no_mangle]
pub unsafe extern "C" fn tk_crc32(seed: u32, data: *const u8, len: usize) -> u32 {
    let mut h = crc32fast::Hasher::new_with_initial(seed);
    h.update(bytes(data, len));
    h.finalize()
}
