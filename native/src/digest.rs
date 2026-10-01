//! Digests, checksums and MACs — the hashing a scripting toolkit needs.
//!
//! Digest codes are the Dart `Hash` enum's order: 0 md5, 1 sha1, 2 sha224, 3 sha256, 4 sha384,
//! 5 sha512, 6 sha512/256, 7 sha3-224, 8 sha3-256, 9 sha3-384, 10 sha3-512, 11 keccak256,
//! 12 blake2s, 13 blake2b, 14 blake3, 15 ripemd160, 16 crc32, 17 crc32c, 18 xxh64, 19 xxh3.
//!
//! A MAC is a digest with a key, and runs through the same handle: `tk_mac_new` makes one,
//! `tk_digest_file` and `tk_digest_final` feed and finish either. HMAC is
//! the construction for everything but the BLAKE family, which is specified with a keyed mode
//! of its own and uses it: BLAKE2 takes a key of up to its block size, BLAKE3 exactly 32 bytes.
//!
//! Every function that writes into a caller buffer takes its capacity and refuses to
//! overrun it, and every entry point runs inside `guard` so a panic cannot cross the ABI.

use crate::{bytes, bytes_mut, guard, text, Handle, Msg};
use digest::{Digest, DynDigest, KeyInit};
use hmac::{Hmac, Mac};
use rayon::prelude::*;
use std::io::Read;

/// Expands `$f!(DigestType)` for the cryptographic digest with code `$alg`; BLAKE2 buffers
/// lazily and cannot feed `Hmac`, so MAC contexts pass `$b` for those two codes.
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

/// A keyed digest behind one type, so a MAC rides in the same handle as a hash.
trait DynMac {
    fn update(&mut self, data: &[u8]);
    fn finish(self: Box<Self>) -> Vec<u8>;
}

impl<M: Mac + 'static> DynMac for M {
    fn update(&mut self, data: &[u8]) {
        Mac::update(self, data)
    }

    fn finish(self: Box<Self>) -> Vec<u8> {
        (*self).finalize().into_bytes().to_vec()
    }
}

// ---- Digests and checksums, streaming

enum Running {
    Dyn(Box<dyn DynDigest>),
    Mac(Box<dyn DynMac>),
    Blake3(Box<blake3::Hasher>),
    Crc32(crc32fast::Hasher),
    Crc32c(u32),
    Xxh64(xxhash_rust::xxh64::Xxh64),
    Xxh3(Box<xxhash_rust::xxh3::Xxh3>),
}

const BLAKE3: u32 = 14;

impl Running {
    fn new(alg: u32) -> Result<Running, String> {
        macro_rules! boxed {
            ($t:ty) => {
                Ok(Running::Dyn(Box::new(<$t>::new())))
            };
        }
        match alg {
            BLAKE3 => Ok(Running::Blake3(Box::new(blake3::Hasher::new()))),
            16 => Ok(Running::Crc32(crc32fast::Hasher::new())),
            17 => Ok(Running::Crc32c(0)),
            18 => Ok(Running::Xxh64(xxhash_rust::xxh64::Xxh64::new(0))),
            19 => Ok(Running::Xxh3(Box::new(xxhash_rust::xxh3::Xxh3::new()))),
            _ => with_digest!(alg, boxed),
        }
    }

    /// A MAC under `key`: HMAC, or the algorithm's own keyed mode where it has one.
    fn keyed(alg: u32, key: &[u8]) -> Result<Running, String> {
        macro_rules! hmac {
            ($t:ty) => {
                Ok(Running::Mac(Box::new(<Hmac<$t> as KeyInit>::new_from_slice(key).msg()?)))
            };
        }
        macro_rules! keyed_blake2 {
            ($t:ty) => {
                unreachable!()
            };
        }
        match alg {
            12 => <blake2::Blake2sMac256 as KeyInit>::new_from_slice(key)
                .map(|m| Running::Mac(Box::new(m)))
                .map_err(|_| format!("the key must be at most 32 bytes, not {}", key.len())),
            13 => <blake2::Blake2bMac512 as KeyInit>::new_from_slice(key)
                .map(|m| Running::Mac(Box::new(m)))
                .map_err(|_| format!("the key must be at most 64 bytes, not {}", key.len())),
            BLAKE3 => {
                let k: &[u8; 32] =
                    key.try_into().map_err(|_| format!("the key must be exactly 32 bytes, not {}", key.len()))?;
                Ok(Running::Blake3(Box::new(blake3::Hasher::new_keyed(k))))
            }
            16..=19 => Err("a checksum takes no key".into()),
            _ => with_digest!(alg, hmac, keyed_blake2),
        }
    }

    fn update(&mut self, data: &[u8]) {
        match self {
            Running::Dyn(d) => d.update(data),
            Running::Mac(m) => m.update(data),
            Running::Blake3(b) => {
                b.update(data);
            }
            Running::Crc32(c) => c.update(data),
            Running::Crc32c(c) => *c = crc32c::crc32c_append(*c, data),
            Running::Xxh64(x) => x.update(data),
            Running::Xxh3(x) => x.update(data),
        }
    }

    /// Feeds the file at `path` in; BLAKE3 maps it and hashes on every core.
    fn file(&mut self, path: &str) -> Result<(), String> {
        let err = |e: std::io::Error| format!("{}: {}", path, e);
        if let Running::Blake3(b) = self {
            b.update_mmap_rayon(path).map_err(err)?;
            return Ok(());
        }
        let mut f = std::fs::File::open(path).map_err(err)?;
        // A buffer the size of the file, up to 1 MiB: most files hashed in bulk are small.
        let len = f.metadata().map_or(1 << 20, |m| m.len()).clamp(1, 1 << 20);
        let mut buf = vec![0u8; len as usize];
        loop {
            let n = f.read(&mut buf).map_err(err)?;
            if n == 0 {
                return Ok(());
            }
            self.update(&buf[..n]);
        }
    }

    fn finish(self) -> Vec<u8> {
        match self {
            Running::Dyn(d) => d.finalize().to_vec(),
            Running::Mac(m) => m.finish(),
            Running::Blake3(b) => b.finalize().as_bytes().to_vec(),
            Running::Crc32(c) => c.finalize().to_be_bytes().to_vec(),
            Running::Crc32c(c) => c.to_be_bytes().to_vec(),
            Running::Xxh64(x) => x.digest().to_be_bytes().to_vec(),
            Running::Xxh3(x) => x.digest().to_be_bytes().to_vec(),
        }
    }
}

fn handle(r: Result<Running, String>) -> Handle {
    match r {
        Ok(d) => Box::into_raw(Box::new(d)) as Handle,
        Err(m) => {
            crate::set_error(&m);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn tk_digest_new(alg: u32) -> Handle {
    handle(Running::new(alg))
}

/// A MAC under `key`, fed and finished like a digest; null with an error when the key does
/// not suit the algorithm.
#[no_mangle]
pub unsafe extern "C" fn tk_mac_new(alg: u32, key: *const u8, klen: usize) -> Handle {
    let mut out = std::ptr::null_mut();
    let code = guard(|| {
        out = handle(Running::keyed(alg, bytes(key, klen)));
        Ok(0)
    });
    if code < 0 {
        return std::ptr::null_mut();
    }
    out
}

/// Feeds the file at `path` into the digest or MAC. The handle survives a failure, and
/// `tk_digest_final` still releases it.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_file(h: Handle, path: *const u8, plen: usize) -> i32 {
    if h.is_null() {
        crate::set_error("digest handle is null");
        return -1;
    }
    guard(|| {
        (*(h as *mut Running)).file(text(path, plen)?)?;
        Ok(0)
    })
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

/// The digests of many files at once, on every core: `paths` is their UTF-8 names joined by
/// NUL, and the digests land in `out` back to back in the same order. Returns how many.
/// One file that cannot be read fails the call, naming it — an empty name too, which is a file
/// that does not exist and not one to skip: skipping it moved every later digest up a place.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_files(alg: u32, paths: *const u8, plen: usize, out: *mut u8, cap: usize) -> i32 {
    guard(|| {
        let joined = text(paths, plen)?;
        let names: Vec<&str> = if joined.is_empty() { Vec::new() } else { joined.split('\0').collect() };
        Running::new(alg)?;
        let digests = names
            .par_iter()
            .map(|p| {
                let mut d = Running::new(alg)?;
                d.file(p)?;
                Ok(d.finish())
            })
            .collect::<Result<Vec<Vec<u8>>, String>>()?;
        let joined: Vec<u8> = digests.concat();
        put(out, cap, &joined)?;
        Ok(names.len() as i32)
    })
}

// ---- MACs

/// Copies `data` into `out`, refusing rather than overrunning when `cap` is too small.
fn put(out: *mut u8, cap: usize, data: &[u8]) -> Result<i32, String> {
    if data.len() > cap {
        return Err(format!("output buffer holds {} bytes, needs {}", cap, data.len()));
    }
    unsafe { bytes_mut(out, data.len()) }.copy_from_slice(data);
    Ok(data.len() as i32)
}

/// One-shot MAC of `data` under `key` into `out`; see `tk_mac_new` for which construction.
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
        let mut m = Running::keyed(alg, bytes(key, klen))?;
        m.update(bytes(data, dlen));
        put(out, cap, &m.finish())
    })
}
