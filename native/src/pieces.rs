use crate::{give, guard, text, Msg};

/// The SHA-1 of pieces `first..first + count` (each [piece] bytes, the last one shorter) of the
/// files in [paths] (a JSON list, in torrent order) read as one stream, concatenated; pieces are
/// hashed in parallel. A range lets the caller report progress and stop between calls.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_hash(
    paths: *const u8,
    plen: usize,
    piece: u64,
    first: u64,
    count: u64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    use rayon::prelude::*;
    use sha1::{Digest, Sha1};
    guard(|| {
        let paths: Vec<String> = serde_json::from_str(text(paths, plen)?).msg()?;
        if piece == 0 {
            return Err("piece length is 0".into());
        }
        let files = paths
            .iter()
            .map(|p| std::fs::File::open(p).map_err(|e| format!("{p}: {e}")))
            .collect::<Result<Vec<_>, _>>()?;
        // Where each file starts in the stream.
        let mut starts = Vec::with_capacity(files.len());
        let mut total = 0u64;
        for f in &files {
            starts.push(total);
            total += f.metadata().msg()?.len();
        }
        let all = total.div_ceil(piece);
        let last = (first + count).min(all);
        let hashes = (first..last)
            .into_par_iter()
            .map(|i| -> Result<[u8; 20], String> {
                let (from, to) = (i * piece, ((i + 1) * piece).min(total));
                let mut buf = vec![0u8; (to - from) as usize];
                let mut at = from;
                // The first file that holds byte [from].
                let mut k = starts.partition_point(|&s| s <= from) - 1;
                while at < to {
                    let end = starts.get(k + 1).copied().unwrap_or(total);
                    let n = (end.min(to) - at) as usize;
                    let into = &mut buf[(at - from) as usize..][..n];
                    read_at(&files[k], into, at - starts[k])
                        .map_err(|e| format!("{}: {e}", paths[k]))?;
                    at += n as u64;
                    k += 1;
                }
                Ok(Sha1::digest(&buf).into())
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(give(hashes.concat(), out_ptr, out_len))
    })
}

/// Checks pieces `first..first + count` of the files in `files` (a JSON list of `[path, size]`,
/// in torrent order, read as one stream) against `hashes` (20 bytes per piece, every piece of the
/// torrent), in parallel: one byte per piece into `out`, 1 when it matches. A file that is
/// missing, shorter than its size or unreadable fails the pieces it is in; nothing throws. An
/// empty path is a BEP 47 padding file: that many zero bytes, never on disk.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_verify(
    files: *const u8,
    flen: usize,
    piece: u64,
    hashes: *const u8,
    hlen: usize,
    first: u64,
    count: u64,
    out: *mut u8,
) -> i32 {
    use rayon::prelude::*;
    use sha1::{Digest, Sha1};
    guard(|| {
        let files: Vec<(String, u64)> = serde_json::from_str(text(files, flen)?).msg()?;
        if piece == 0 {
            return Err("piece length is 0".into());
        }
        let hashes = crate::bytes(hashes, hlen);
        let open: Vec<Option<Part>> = files
            .iter()
            .map(|(p, size)| {
                if p.is_empty() {
                    return Some(Part::Zeros);
                }
                std::fs::File::open(p)
                    .ok()
                    .filter(|f| f.metadata().is_ok_and(|m| m.len() >= *size))
                    .map(Part::File)
            })
            .collect();
        let mut starts = Vec::with_capacity(files.len());
        let mut total = 0u64;
        for (_, size) in &files {
            starts.push(total);
            total += size;
        }
        let results = std::slice::from_raw_parts_mut(out, count as usize);
        results.par_iter_mut().enumerate().for_each(|(j, slot)| {
            let i = first + j as u64;
            let (from, to) = (i * piece, ((i + 1) * piece).min(total));
            let want = &hashes[(i * 20) as usize..][..20];
            let mut buf = vec![0u8; (to - from) as usize];
            let mut at = from;
            let mut k = starts.partition_point(|&s| s <= from).saturating_sub(1);
            while at < to {
                let end = starts.get(k + 1).copied().unwrap_or(total);
                let n = (end.min(to) - at) as usize;
                let into = &mut buf[(at - from) as usize..][..n];
                match &open[k] {
                    Some(Part::File(file)) if read_at(file, into, at - starts[k]).is_ok() => {}
                    Some(Part::Zeros) => into.fill(0),
                    _ => {
                        *slot = 0;
                        return;
                    }
                }
                at += n as u64;
                k += 1;
            }
            *slot = u8::from(Sha1::digest(&buf).as_slice() == want);
        });
        Ok(0)
    })
}

/// One file of a torrent being checked: on disk, or a padding file of zeros.
enum Part {
    File(std::fs::File),
    Zeros,
}

/// Fills [buf] from [file] at [offset], whatever the platform's positional read.
fn read_at(file: &std::fs::File, buf: &mut [u8], offset: u64) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::FileExt::read_exact_at(file, buf, offset)
    }
    #[cfg(windows)]
    {
        let (mut done, mut buf) = (0u64, buf);
        while !buf.is_empty() {
            match std::os::windows::fs::FileExt::seek_read(file, buf, offset + done)? {
                0 => return Err(std::io::ErrorKind::UnexpectedEof.into()),
                n => {
                    done += n as u64;
                    buf = &mut buf[n..];
                }
            }
        }
        Ok(())
    }
}
