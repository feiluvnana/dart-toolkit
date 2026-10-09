use crate::{give, guard, text, Msg};

/// How many consecutive pieces one task reads: it keeps the file it last opened, so a run of
/// pieces in one file opens it once, and no more files are open at once than there are tasks.
const RUN: usize = 16;

/// The file one task holds open, by index.
type Open = Option<(usize, std::fs::File)>;

/// The files of a torrent read as one stream, each opened as a piece reaches it: never all at
/// once, which a folder of thousands would run out of descriptors for.
struct Stream<'a> {
    /// Each file's path; empty for a BEP 47 padding file, all zeros.
    paths: &'a [String],
    /// The size each file must have; a file on disk shorter than that fails.
    sizes: &'a [u64],
    /// Where each file starts in the stream.
    starts: Vec<u64>,
    total: u64,
}

impl<'a> Stream<'a> {
    fn new(paths: &'a [String], sizes: &'a [u64]) -> Self {
        let mut starts = Vec::with_capacity(sizes.len());
        let mut total = 0u64;
        for size in sizes {
            starts.push(total);
            total += size;
        }
        Stream { paths, sizes, starts, total }
    }

    /// Bytes `from..to` of the stream into [buf], through [open], the file this task holds.
    fn read(&self, from: u64, to: u64, buf: &mut [u8], open: &mut Open) -> Result<(), String> {
        let mut at = from;
        // The first file that holds byte [from]; empty files before it are passed over.
        let mut k = self.starts.partition_point(|&s| s <= from).saturating_sub(1);
        while at < to {
            let end = self.starts.get(k + 1).copied().unwrap_or(self.total);
            let n = (end.min(to) - at) as usize;
            let into = &mut buf[(at - from) as usize..][..n];
            if n > 0 && self.paths[k].is_empty() {
                into.fill(0);
            } else if n > 0 {
                let path = &self.paths[k];
                if open.as_ref().map(|(i, _)| *i) != Some(k) {
                    let file = std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?;
                    let len = file.metadata().map_err(|e| format!("{path}: {e}"))?.len();
                    if len < self.sizes[k] {
                        return Err(format!("{path}: shorter than {} bytes", self.sizes[k]));
                    }
                    *open = Some((k, file));
                }
                if let Some((_, file)) = open.as_ref() {
                    read_at(file, into, at - self.starts[k]).map_err(|e| format!("{path}: {e}"))?;
                }
            }
            at += n as u64;
            k += 1;
        }
        Ok(())
    }

    /// The SHA-1 of piece [i] of [piece] bytes, the last one shorter; `None` past the end.
    fn hash(&self, i: u64, piece: u64, open: &mut Open) -> Result<Option<[u8; 20]>, String> {
        use sha1::{Digest, Sha1};
        let from = i * piece;
        if from >= self.total {
            return Ok(None);
        }
        let to = (from + piece).min(self.total);
        let mut buf = vec![0u8; (to - from) as usize];
        self.read(from, to, &mut buf, open)?;
        Ok(Some(Sha1::digest(&buf).into()))
    }
}

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
    guard(|| {
        let paths: Vec<String> = serde_json::from_str(text(paths, plen)?).msg()?;
        if piece == 0 {
            return Err("piece length is 0".into());
        }
        let sizes = paths
            .iter()
            .map(|p| std::fs::metadata(p).map(|m| m.len()).map_err(|e| format!("{p}: {e}")))
            .collect::<Result<Vec<_>, _>>()?;
        let stream = Stream::new(&paths, &sizes);
        let last = (first + count).min(stream.total.div_ceil(piece)).max(first);
        let ids: Vec<u64> = (first..last).collect();
        let runs = ids
            .par_chunks(RUN)
            .map(|run| {
                let mut open = None;
                run.iter()
                    .map(|&i| stream.hash(i, piece, &mut open).map(Option::unwrap_or_default))
                    .collect::<Result<Vec<_>, String>>()
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(give(runs.concat().concat(), out_ptr, out_len))
    })
}

/// Checks pieces `first..first + count` of the files in `files` (a JSON list of `[path, size]`,
/// in torrent order, read as one stream) against `hashes` (20 bytes per piece), in parallel: one
/// byte per piece into `out`, 1 when it matches. A file that is missing, shorter than its size
/// or unreadable fails the pieces it is in, and so does a piece past the end of the files or
/// without a hash; nothing throws. An empty path is a BEP 47 padding file: that many zero bytes,
/// never on disk.
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
    guard(|| {
        let files: Vec<(String, u64)> = serde_json::from_str(text(files, flen)?).msg()?;
        if piece == 0 {
            return Err("piece length is 0".into());
        }
        let hashes = crate::bytes(hashes, hlen);
        let (paths, sizes): (Vec<String>, Vec<u64>) = files.into_iter().unzip();
        let stream = Stream::new(&paths, &sizes);
        let results = std::slice::from_raw_parts_mut(out, count as usize);
        results.par_chunks_mut(RUN).enumerate().for_each(|(c, run)| {
            let mut open = None;
            for (j, slot) in run.iter_mut().enumerate() {
                let i = first + (c * RUN + j) as u64;
                let want = hashes.get((i * 20) as usize..(i * 20 + 20) as usize);
                *slot = match (stream.hash(i, piece, &mut open), want) {
                    (Ok(Some(got)), Some(want)) => u8::from(got.as_slice() == want),
                    _ => 0,
                };
            }
        });
        Ok(0)
    })
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
