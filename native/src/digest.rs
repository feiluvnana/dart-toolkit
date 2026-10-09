//! Digests, checksums and MACs — the hashing a scripting toolkit needs.
//!
//! Digest codes are the Dart `Hash` enum's order: 0 md5, 1 sha1, 2 sha224, 3 sha256, 4 sha384,
//! 5 sha512, 6 sha512/256, 7 sha3-224, 8 sha3-256, 9 sha3-384, 10 sha3-512, 11 keccak256,
//! 12 blake2s, 13 blake2b, 14 blake3, 15 ripemd160, 16 crc32, 17 crc32c, 18 xxh64, 19 xxh3.
//!
//! A MAC runs through the same handle as a digest (`tk_mac_new`, then `tk_digest_file` and
//! `tk_digest_final`). It is HMAC except for BLAKE, which uses its own keyed mode: BLAKE2 a
//! key up to its block size, BLAKE3 exactly 32 bytes.
//!
//! Caller buffers carry their capacity, and every entry point runs inside `guard`.

use crate::archive::ProgressCb;
use crate::{bytes, bytes_mut, guard, stopped, text, watch, Handle, Msg};
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
            other => Err(format!("digest {} is not a valid algorithm code", other)),
        }
    };
}

/// The `$b` for a MAC's `with_digest!`: its caller handles the BLAKE2 codes first.
macro_rules! unreachable_blake2 {
    ($t:ty) => {
        unreachable!()
    };
}

/// A BLAKE2 MAC under `key`, which may be at most `max` bytes.
fn blake2_mac<M: KeyInit>(key: &[u8], max: usize) -> Result<M, String> {
    M::new_from_slice(key).map_err(|_| format!("the key must be at most {} bytes, not {}", max, key.len()))
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
        match alg {
            12 => Ok(Running::Mac(Box::new(blake2_mac::<blake2::Blake2sMac256>(key, 32)?))),
            13 => Ok(Running::Mac(Box::new(blake2_mac::<blake2::Blake2bMac512>(key, 64)?))),
            BLAKE3 => {
                let k: &[u8; 32] =
                    key.try_into().map_err(|_| format!("the key must be exactly 32 bytes, not {}", key.len()))?;
                Ok(Running::Blake3(Box::new(blake3::Hasher::new_keyed(k))))
            }
            16..=19 => Err("a checksum takes no key".into()),
            _ => with_digest!(alg, hmac, unreachable_blake2),
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

    /// Feeds the file at `path` in; with `wide`, BLAKE3 hashes a large one on every core, two
    /// 16 MiB buffers at a time (never a map, which a file truncated meanwhile turns into a
    /// SIGBUS); otherwise one 1 MiB buffer, for a caller that already runs a file per core. Every
    /// `STEP` bytes it tells `progress` how far it is and stops if the caller asked.
    fn file(&mut self, path: &str, progress: ProgressCb, wide: bool) -> Result<(), String> {
        const STEP: usize = 32 << 20;
        let err = |e: std::io::Error| format!("{}: {}", path, e);
        let mut f = std::fs::File::open(path).map_err(err)?;
        let total = f.metadata().map_or(0, |m| if m.is_file() { m.len() } else { 0 });
        let tell = |done: u64| -> Result<(), String> {
            if let Some(cb) = progress {
                unsafe { cb(0, 1, done, total, std::ptr::null(), 0) };
            }
            stopped()
        };
        // Filled whole where it can be: a short read would hand BLAKE3 a small slice.
        fn fill(f: &mut std::fs::File, buf: &mut [u8]) -> std::io::Result<usize> {
            let mut n = 0;
            while n < buf.len() {
                match f.read(&mut buf[n..])? {
                    0 => break,
                    k => n += k,
                }
            }
            Ok(n)
        }
        let mut done = 0u64;
        if let (Running::Blake3(b), true) = (&mut *self, wide && total >= STEP as u64) {
            // Two buffers: the next is read on its own thread while every core hashes this one.
            const BUF: usize = 16 << 20;
            let (mut this, mut next) = (vec![0u8; BUF], vec![0u8; BUF]);
            let mut n = fill(&mut f, &mut this).map_err(err)?;
            while n > 0 {
                let read = std::thread::scope(|scope| {
                    let reader = scope.spawn(|| fill(&mut f, &mut next));
                    b.update_rayon(&this[..n]);
                    reader.join().unwrap_or_else(|_| Err(std::io::Error::other("read panicked")))
                });
                done += n as u64;
                tell(done)?;
                n = read.map_err(err)?;
                std::mem::swap(&mut this, &mut next);
            }
            return Ok(());
        }
        let mut buf = vec![0u8; 1 << 20];
        let mut told = 0u64;
        loop {
            let n = fill(&mut f, &mut buf).map_err(err)?;
            if n == 0 {
                return Ok(());
            }
            self.update(&buf[..n]);
            done += n as u64;
            if done - told >= STEP as u64 {
                told = done;
                tell(done)?;
            }
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
/// `tk_digest_final` still releases it. `progress`, when not null, hears the bytes read as
/// (0, 1, bytes, size, null, 0); `stop`, when not null, is a byte that stops the call once set.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_file(h: Handle, path: *const u8, plen: usize, progress: ProgressCb, stop: *const u8) -> i32 {
    let _watch = watch(stop);
    guard(|| {
        crate::live::<Running>(h)?.file(text(path, plen)?, progress, true)?;
        Ok(0)
    })
}

/// Feeds `len` bytes at `data` into the digest or MAC: one chunk of a stream.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_update(h: Handle, data: *const u8, len: usize) -> i32 {
    guard(|| {
        crate::live::<Running>(h)?.update(bytes(data, len));
        Ok(0)
    })
}

/// Finishes the digest into `out`, frees the handle, and returns the length written.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_final(h: Handle, out: *mut u8, cap: usize) -> i32 {
    guard(|| {
        crate::live::<Running>(h)?;
        let result = Box::from_raw(h as *mut Running).finish();
        put(out, cap, &result)
    })
}

/// One-shot digest of `data` into `out`; returns the length written.
#[no_mangle]
pub unsafe extern "C" fn tk_digest(alg: u32, data: *const u8, len: usize, out: *mut u8, cap: usize) -> i32 {
    guard(|| {
        let input = bytes(data, len);
        macro_rules! compute {
            ($t:ty) => {
                put(out, cap, &<$t as Digest>::digest(input))
            };
        }
        match alg {
            BLAKE3 => put(out, cap, blake3::hash(input).as_bytes()),
            16 => put(out, cap, &crc32fast::hash(input).to_be_bytes()),
            17 => put(out, cap, &crc32c::crc32c(input).to_be_bytes()),
            18 => put(out, cap, &xxhash_rust::xxh64::xxh64(input, 0).to_be_bytes()),
            19 => put(out, cap, &xxhash_rust::xxh3::xxh3_64(input).to_be_bytes()),
            _ => with_digest!(alg, compute),
        }
    })
}

/// The digests of many files at once, on every core: `paths` is their UTF-8 names joined by
/// NUL, and the digests land in `out` back to back in the same order. Returns how many. One
/// unreadable file fails the call, an empty name included: skipping it would shift every
/// later digest.
/// `stop`, when not null, is a byte that stops the call once set, checked before each file.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_files(alg: u32, paths: *const u8, plen: usize, out: *mut u8, cap: usize, stop: *const u8) -> i32 {
    // An address, so the workers may share it; the caller keeps the byte alive for the call.
    let stop = stop as usize;
    guard(|| {
        let joined = text(paths, plen)?;
        let names: Vec<&str> = if joined.is_empty() { Vec::new() } else { joined.split('\0').collect() };
        let dlen = Running::new(alg)?.finish().len();
        let needed = names.len().checked_mul(dlen).ok_or("size overflow")?;
        if needed > cap {
            return Err(format!("output buffer holds {} bytes, needs {}", cap, needed));
        }
        let out_slice = bytes_mut(out, needed);
        out_slice
            .par_chunks_exact_mut(dlen)
            .zip(names.par_iter())
            .try_for_each(|(slot, p)| {
                // SAFETY: see above; a null address is no stop byte.
                if stop != 0 && unsafe { (*(stop as *const std::sync::atomic::AtomicU8)).load(std::sync::atomic::Ordering::Relaxed) } != 0 {
                    return Err(tk_common::STOPPED.to_string());
                }
                // One buffer per file: the files are already spread over every core.
                let mut d = Running::new(alg)?;
                d.file(p, None, false)?;
                let res = d.finish();
                slot.copy_from_slice(&res);
                Ok::<(), String>(())
            })?;
        Ok(names.len() as i32)
    })
}

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
        let k = bytes(key, klen);
        let d = bytes(data, dlen);
        macro_rules! hmac {
            ($t:ty) => {
                mac_put(<Hmac<$t> as KeyInit>::new_from_slice(k).msg()?, d, out, cap)
            };
        }
        match alg {
            12 => mac_put(blake2_mac::<blake2::Blake2sMac256>(k, 32)?, d, out, cap),
            13 => mac_put(blake2_mac::<blake2::Blake2bMac512>(k, 64)?, d, out, cap),
            BLAKE3 => {
                let key_arr: &[u8; 32] =
                    k.try_into().map_err(|_| format!("the key must be exactly 32 bytes, not {}", k.len()))?;
                put(out, cap, blake3::keyed_hash(key_arr, d).as_bytes())
            }
            16..=19 => Err("a checksum takes no key".into()),
            _ => with_digest!(alg, hmac, unreachable_blake2),
        }
    })
}

/// Feeds `data` to `mac` and puts the tag into `out`.
fn mac_put<M: Mac>(mut mac: M, data: &[u8], out: *mut u8, cap: usize) -> Result<i32, String> {
    Mac::update(&mut mac, data);
    put(out, cap, &mac.finalize().into_bytes())
}
