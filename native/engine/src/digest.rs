//! Digests, checksums and MACs, rewritten for native.
//!
//! Fresh implementation of the digest interface. Algorithm codes match the Dart `Hash`
//! binding and the legacy interface exactly, so parity tests compare old and new byte for
//! byte: 0 md5, 1 sha1, 2 sha224, 3 sha256, 4 sha384, 5 sha512, 6 sha512/256, 7 sha3-224,
//! 8 sha3-256, 9 sha3-384, 10 sha3-512, 11 keccak256, 12 blake2s, 13 blake2b, 14 blake3,
//! 15 ripemd160, 16 crc32, 17 crc32c, 18 xxh64, 19 xxh3.
//!
//! A MAC runs through the same session as a digest (`tk_mac_new`, then `tk_digest_file` /
//! `tk_digest_update` / `tk_digest_final`). It is HMAC except for BLAKE, which uses its own
//! keyed mode (BLAKE2 a key up to its block size, BLAKE3 exactly 32 bytes). Checksums take
//! no key. Caller buffers carry their capacity; every entry point runs inside `guard`.

use crate::{bytes, bytes_mut, guard, live, stopped, text, watch, Handle, Msg};
use digest::{Digest, DynDigest, KeyInit};
use hmac::{Hmac, Mac};
use rayon::prelude::*;
use std::io::Read;

/// A long native call's progress callback: (completed, total, bytes, bytesTotal, name, nameLen).
pub type ProgressCb = Option<unsafe extern "C" fn(u64, u64, u64, u64, *const u8, usize)>;

/// Expands `$run!(DigestType)` for the plain digest with code `$alg`. BLAKE2 digests are
/// constructed through the second macro: a MAC caller handles those codes before reaching it.
macro_rules! dispatch {
    ($alg:expr, $run:ident) => {
        dispatch!($alg, $run, $run)
    };
    ($alg:expr, $run:ident, $keyed:ident) => {
        match $alg {
            0 => $run!(md5::Md5),
            1 => $run!(sha1::Sha1),
            2 => $run!(sha2::Sha224),
            3 => $run!(sha2::Sha256),
            4 => $run!(sha2::Sha384),
            5 => $run!(sha2::Sha512),
            6 => $run!(sha2::Sha512_256),
            7 => $run!(sha3::Sha3_224),
            8 => $run!(sha3::Sha3_256),
            9 => $run!(sha3::Sha3_384),
            10 => $run!(sha3::Sha3_512),
            11 => $run!(sha3::Keccak256),
            12 => $keyed!(blake2::Blake2s256),
            13 => $keyed!(blake2::Blake2b512),
            15 => $run!(ripemd::Ripemd160),
            other => Err(format!("digest {} is not a valid algorithm code", other)),
        }
    };
}

/// The `$keyed` arm of [`dispatch!`] for MAC construction: unreachable, because keyed
/// BLAKE2 sessions are built before dispatching.
macro_rules! no_blake2_keyed {
    ($t:ty) => {
        unreachable!()
    };
}

/// A BLAKE2 keyed MAC under `key` (at most `max` bytes).
fn blake2_keyed<M: KeyInit>(key: &[u8], max: usize) -> Result<M, String> {
    M::new_from_slice(key)
        .map_err(|_| format!("the key must be at most {} bytes, not {}", max, key.len()))
}

/// A keyed digest behind one type, so a MAC rides in the same session as a hash.
trait Keyed {
    fn ingest(&mut self, data: &[u8]);
    fn tag(self: Box<Self>) -> Vec<u8>;
}

impl<M: Mac + 'static> Keyed for M {
    fn ingest(&mut self, data: &[u8]) {
        Mac::update(self, data)
    }

    fn tag(self: Box<Self>) -> Vec<u8> {
        (*self).finalize().into_bytes().to_vec()
    }
}

/// One open digest or MAC: fed with [`Session::ingest`], finished once with
/// [`Session::seal`]. A finished session is freed; feeding after sealing is impossible
/// because sealing consumes the handle.
enum Session {
    Digest(Box<dyn DynDigest>),
    Keyed(Box<dyn Keyed>),
    Blake3(Box<blake3::Hasher>),
    Crc32(crc32fast::Hasher),
    Crc32c(u32),
    Xxh64(xxhash_rust::xxh64::Xxh64),
    Xxh3(Box<xxhash_rust::xxh3::Xxh3>),
}

const BLAKE3: u32 = 14;

impl Session {
    fn open(alg: u32) -> Result<Session, String> {
        macro_rules! plain {
            ($t:ty) => {
                Ok(Session::Digest(Box::new(<$t>::new())))
            };
        }
        match alg {
            BLAKE3 => Ok(Session::Blake3(Box::new(blake3::Hasher::new()))),
            16 => Ok(Session::Crc32(crc32fast::Hasher::new())),
            17 => Ok(Session::Crc32c(0)),
            18 => Ok(Session::Xxh64(xxhash_rust::xxh64::Xxh64::new(0))),
            19 => Ok(Session::Xxh3(Box::new(xxhash_rust::xxh3::Xxh3::new()))),
            _ => dispatch!(alg, plain),
        }
    }

    /// A MAC under `key`: HMAC, or the algorithm's own keyed mode where it has one.
    fn keyed(alg: u32, key: &[u8]) -> Result<Session, String> {
        macro_rules! wrapped {
            ($t:ty) => {
                Ok(Session::Keyed(Box::new(<Hmac<$t> as KeyInit>::new_from_slice(key).msg()?)))
            };
        }
        match alg {
            12 => Ok(Session::Keyed(Box::new(blake2_keyed::<blake2::Blake2sMac256>(key, 32)?))),
            13 => Ok(Session::Keyed(Box::new(blake2_keyed::<blake2::Blake2bMac512>(key, 64)?))),
            BLAKE3 => {
                let fixed: &[u8; 32] = key
                    .try_into()
                    .map_err(|_| format!("the key must be exactly 32 bytes, not {}", key.len()))?;
                Ok(Session::Blake3(Box::new(blake3::Hasher::new_keyed(fixed))))
            }
            16..=19 => Err("a checksum takes no key".into()),
            _ => dispatch!(alg, wrapped, no_blake2_keyed),
        }
    }

    fn ingest(&mut self, data: &[u8]) {
        match self {
            Session::Digest(d) => d.update(data),
            Session::Keyed(m) => m.ingest(data),
            Session::Blake3(b) => {
                b.update(data);
            }
            Session::Crc32(c) => c.update(data),
            Session::Crc32c(c) => *c = crc32c::crc32c_append(*c, data),
            Session::Xxh64(x) => x.update(data),
            Session::Xxh3(x) => x.update(data),
        }
    }

    /// Feeds the file at `path` in 1 MiB buffers. Every 32 MiB it reports progress and
    /// honours the stop flag, so a cancel ends a large hash promptly.
    fn ingest_file(&mut self, path: &str, progress: ProgressCb) -> Result<(), String> {
        const STEP: usize = 32 << 20;
        let mut file = crate::read_file(path)?;
        let total = file.metadata().map_or(0, |m| if m.is_file() { m.len() } else { 0 });
        let tell = |done: u64| -> Result<(), String> {
            if let Some(report) = progress {
                unsafe { report(0, 1, done, total, std::ptr::null(), 0) };
            }
            stopped()
        };
        // Filled whole where possible: a short read hands the hasher a small slice.
        fn fill(file: &mut std::fs::File, buf: &mut [u8]) -> std::io::Result<usize> {
            let mut n = 0;
            while n < buf.len() {
                match file.read(&mut buf[n..])? {
                    0 => break,
                    k => n += k,
                }
            }
            Ok(n)
        }
        let mut buf = vec![0u8; 1 << 20];
        let mut done = 0u64;
        let mut told = 0u64;
        loop {
            let n = fill(&mut file, &mut buf).map_err(|e| format!("{}: {}", path, e))?;
            if n == 0 {
                return Ok(());
            }
            self.ingest(&buf[..n]);
            done += n as u64;
            if done - told >= STEP as u64 {
                told = done;
                tell(done)?;
            }
        }
    }

    fn seal(self) -> Vec<u8> {
        match self {
            Session::Digest(d) => d.finalize().to_vec(),
            Session::Keyed(m) => m.tag(),
            Session::Blake3(b) => b.finalize().as_bytes().to_vec(),
            Session::Crc32(c) => c.finalize().to_be_bytes().to_vec(),
            Session::Crc32c(c) => c.to_be_bytes().to_vec(),
            Session::Xxh64(x) => x.digest().to_be_bytes().to_vec(),
            Session::Xxh3(x) => x.digest().to_be_bytes().to_vec(),
        }
    }
}

/// Boxes a session as a handle; a failed open leaves the error and hands null.
fn session_handle(result: Result<Session, String>) -> Handle {
    match result {
        Ok(session) => Box::into_raw(Box::new(session)) as Handle,
        Err(message) => {
            crate::set_error(&message);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn tk_digest_new(alg: u32) -> Handle {
    session_handle(Session::open(alg))
}

/// A MAC under `key`, fed and finished like a digest; null with an error when the key
/// does not suit the algorithm.
#[no_mangle]
pub unsafe extern "C" fn tk_mac_new(alg: u32, key: *const u8, klen: usize) -> Handle {
    let mut out = std::ptr::null_mut();
    let code = guard(|| {
        out = session_handle(Session::keyed(alg, bytes(key, klen)));
        Ok(0)
    });
    if code < 0 {
        return std::ptr::null_mut();
    }
    out
}

/// Feeds the file at `path` into the digest or MAC. The session survives a failure, and
/// `tk_digest_final` still releases it. `progress`, when not null, hears the bytes read as
/// (0, 1, bytes, size, null, 0); `stop`, when not null, is a byte stopping the call once set.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_file(
    h: Handle,
    path: *const u8,
    plen: usize,
    progress: ProgressCb,
    stop: *const u8,
) -> i32 {
    let _watch = watch(stop);
    guard(|| {
        live::<Session>(h)?.ingest_file(text(path, plen)?, progress)?;
        Ok(0)
    })
}

/// Feeds `len` bytes at `data` into the digest or MAC: one chunk of a stream.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_update(h: Handle, data: *const u8, len: usize) -> i32 {
    guard(|| {
        live::<Session>(h)?.ingest(bytes(data, len));
        Ok(0)
    })
}

/// Finishes the digest into `out`, frees the session, and answers the length written.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_final(h: Handle, out: *mut u8, cap: usize) -> i32 {
    guard(|| {
        live::<Session>(h)?;
        let sum = Box::from_raw(h as *mut Session).seal();
        put(out, cap, &sum)
    })
}

/// One-shot digest of `data` into `out`; answers the length written.
#[no_mangle]
pub unsafe extern "C" fn tk_digest(alg: u32, data: *const u8, len: usize, out: *mut u8, cap: usize) -> i32 {
    guard(|| {
        let input = bytes(data, len);
        macro_rules! once {
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
            _ => dispatch!(alg, once),
        }
    })
}

/// The digests of many files at once, on every core: `paths` holds their UTF-8 names
/// joined by NUL, and the digests land in `out` back to back in the same order. Answers
/// how many. One unreadable file fails the call — skipping it would shift every later
/// digest. `stop`, when not null, is a byte stopping the call once set, checked per file.
#[no_mangle]
pub unsafe extern "C" fn tk_digest_files(
    alg: u32,
    paths: *const u8,
    plen: usize,
    out: *mut u8,
    cap: usize,
    stop: *const u8,
) -> i32 {
    // An address, so workers may share it; the caller keeps the byte alive for the call.
    let stop = stop as usize;
    guard(|| {
        let joined = text(paths, plen)?;
        let names: Vec<&str> = if joined.is_empty() { Vec::new() } else { joined.split('\0').collect() };
        let width = Session::open(alg)?.seal().len();
        let needed = names.len().checked_mul(width).ok_or("size overflow")?;
        if needed > cap {
            return Err(format!("output buffer holds {} bytes, needs {}", cap, needed));
        }
        let out = bytes_mut(out, needed);
        out.par_chunks_exact_mut(width)
            .zip(names.par_iter())
            .try_for_each(|(slot, path)| {
                // SAFETY: shared address documented above; a null address is no stop byte.
                if stop != 0
                    && unsafe { (*(stop as *const std::sync::atomic::AtomicU8)).load(std::sync::atomic::Ordering::Relaxed) }
                        != 0
                {
                    return Err(crate::stopped().unwrap_err());
                }
                // One buffer per file: the files already spread over every core.
                let mut session = Session::open(alg)?;
                session.ingest_file(path, None)?;
                slot.copy_from_slice(&session.seal());
                Ok::<(), String>(())
            })?;
        Ok(names.len() as i32)
    })
}

/// One-shot MAC of `data` under `key` into `out`; see `tk_mac_new` for the construction.
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
        let (k, d) = (bytes(key, klen), bytes(data, dlen));
        macro_rules! tag {
            ($t:ty) => {
                finish_mac(<Hmac<$t> as KeyInit>::new_from_slice(k).msg()?, d, out, cap)
            };
        }
        match alg {
            12 => finish_mac(blake2_keyed::<blake2::Blake2sMac256>(k, 32)?, d, out, cap),
            13 => finish_mac(blake2_keyed::<blake2::Blake2bMac512>(k, 64)?, d, out, cap),
            BLAKE3 => {
                let fixed: &[u8; 32] =
                    k.try_into().map_err(|_| format!("the key must be exactly 32 bytes, not {}", k.len()))?;
                put(out, cap, blake3::keyed_hash(fixed, d).as_bytes())
            }
            16..=19 => Err("a checksum takes no key".into()),
            _ => dispatch!(alg, tag, no_blake2_keyed),
        }
    })
}

/// Feeds `data` to `mac` and puts the tag into `out`.
fn finish_mac<M: Mac>(mut mac: M, data: &[u8], out: *mut u8, cap: usize) -> Result<i32, String> {
    Mac::update(&mut mac, data);
    put(out, cap, &mac.finalize().into_bytes())
}

/// Copies `data` into `out`, refusing rather than overrunning when `cap` is too small.
fn put(out: *mut u8, cap: usize, data: &[u8]) -> Result<i32, String> {
    if data.len() > cap {
        return Err(format!("output buffer holds {} bytes, needs {}", cap, data.len()));
    }
    unsafe { bytes_mut(out, data.len()) }.copy_from_slice(data);
    Ok(data.len() as i32)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(data: &[u8]) -> String {
        data.iter().map(|b| format!("{:02x}", b)).collect()
    }

    /// Drives a full open → feed → seal cycle through raw pointers, like Dart does.
    fn cycle(alg: u32, chunks: &[&[u8]]) -> Vec<u8> {
        let h = tk_digest_new(alg);
        assert!(!h.is_null());
        for chunk in chunks {
            assert_eq!(unsafe { tk_digest_update(h, chunk.as_ptr(), chunk.len()) }, 0);
        }
        let mut out = vec![0u8; 64];
        let n = unsafe { tk_digest_final(h, out.as_mut_ptr(), out.len()) };
        assert!(n > 0);
        out.truncate(n as usize);
        out
    }

    fn once(alg: u32, data: &[u8]) -> Vec<u8> {
        let mut out = vec![0u8; 64];
        let n = unsafe { tk_digest(alg, data.as_ptr(), data.len(), out.as_mut_ptr(), out.len()) };
        assert!(n > 0);
        out.truncate(n as usize);
        out
    }

    #[test]
    fn known_answers() {
        let abc = b"abc";
        assert_eq!(hex(&once(0, abc)), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(hex(&once(3, abc)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(hex(&once(3, b"")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(hex(&once(14, abc)), "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85");
        assert_eq!(hex(&once(16, abc)), "352441c2");
        assert_eq!(hex(&once(18, abc)), "44bc2cf5ad770999");
        assert_eq!(hex(&once(19, abc)), "78af5f94892f3950");
        assert_eq!(hex(&once(19, b"")), "2d06800538d394c2");
    }

    #[test]
    fn chunked_feeding_matches_one_shot() {
        let data: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
        for alg in [0u32, 3, 5, 14, 16, 18, 19] {
            let whole = once(alg, &data);
            let pieces: Vec<&[u8]> = data.chunks(137).collect();
            assert_eq!(cycle(alg, &pieces), whole, "alg {}", alg);
        }
    }

    #[test]
    fn hmac_case_2_matches_rfc_4231() {
        let mut out = vec![0u8; 64];
        let key = b"Jefe";
        let data = b"what do ya want for nothing?";
        let n = unsafe {
            tk_hmac(3, key.as_ptr(), key.len(), data.as_ptr(), data.len(), out.as_mut_ptr(), out.len())
        };
        assert!(n > 0);
        assert_eq!(
            hex(&out[..n as usize]),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn bad_codes_and_keyed_checksums_fail() {
        assert!(tk_digest_new(99).is_null());
        unsafe {
            assert!(tk_mac_new(16, b"k".as_ptr(), 1).is_null());
            assert!(tk_mac_new(19, b"k".as_ptr(), 1).is_null());
            let key32 = [7u8; 32];
            assert!(!tk_mac_new(14, key32.as_ptr(), 32).is_null());
            assert!(tk_mac_new(14, b"short".as_ptr(), 5).is_null());
        }
    }
}
