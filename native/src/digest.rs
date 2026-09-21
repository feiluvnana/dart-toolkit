//! Digests, checksums and MACs — the hashing a scripting toolkit needs.
//!
//! Digest codes are the Dart `Hash` enum's order: 0 md5, 1 sha1, 2 sha224, 3 sha256, 4 sha384,
//! 5 sha512, 6 sha512/256, 7 sha3-224, 8 sha3-256, 9 sha3-384, 10 sha3-512, 11 keccak256,
//! 12 blake2s, 13 blake2b, 14 blake3, 15 ripemd160, 16 crc32, 17 crc32c, 18 xxh64, 19 xxh3.
//!
//! Every function that writes into a caller buffer takes its capacity and refuses to
//! overrun it, and every entry point runs inside `guard` so a panic cannot cross the ABI.

use crate::{bytes, bytes_mut, guard, Handle};
use digest::{Digest, DynDigest};
use hmac::{Hmac, Mac};

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
    if h.is_null() {
        return;
    }
    // Guarded like the rest: a panic unwinding across `extern "C"` is undefined behaviour.
    let _ = guard(|| {
        (*(h as *mut Running)).update(bytes(ptr, len));
        Ok(0)
    });
}

/// Finishes the digest into `out`, frees the handle, and returns the length written.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_final(h: Handle, out: *mut u8, cap: usize) -> i32 {
    if h.is_null() {
        crate::set_error("digest handle is null");
        return -1;
    }
    guard(|| {
        let result = Box::from_raw(h as *mut Running).finish();
        put(out, cap, &result)
    })
}

/// One-shot digest of `data` into `out`; returns the length written.
#[no_mangle]
pub unsafe extern "C" fn tk_digest(alg: u32, data: *const u8, len: usize, out: *mut u8, cap: usize) -> i32 {
    guard(|| {
        let mut d = Running::new(alg)?;
        d.update(bytes(data, len));
        put(out, cap, &d.finish())
    })
}

// ---- MACs

macro_rules! no_mac {
    ($t:ty) => {
        Err("HMAC over BLAKE2 is not supported; BLAKE2 has its own keyed mode".to_string())
    };
}

/// Copies `data` into `out`, refusing rather than overrunning when `cap` is too small.
fn put(out: *mut u8, cap: usize, data: &[u8]) -> Result<i32, String> {
    if data.len() > cap {
        return Err(format!("output buffer holds {} bytes, needs {}", cap, data.len()));
    }
    unsafe { bytes_mut(out, data.len()) }.copy_from_slice(data);
    Ok(data.len() as i32)
}

#[no_mangle]
pub unsafe extern "C" fn tk_hmac(
    alg: u32,
    key: *const u8,
    klen: usize,
    data: *const u8,
    dlen: usize,
    out: *mut u8,
    cap: usize,
) -> i32 {
    guard(|| {
        let (key, data) = (bytes(key, klen), bytes(data, dlen));
        macro_rules! run {
            ($t:ty) => {{
                let mut m = <Hmac<$t> as Mac>::new_from_slice(key).map_err(|e| e.to_string())?;
                Mac::update(&mut m, data);
                put(out, cap, &m.finalize().into_bytes())
            }};
        }
        with_digest!(alg, run, no_mac)
    })
}
