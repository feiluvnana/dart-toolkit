//! Archives and compressed streams, by file path: the file system is the transport.

use crate::{create_file, give, guard, live, opt_text, pump, read_file, stopped, text, watch, Msg, Watched};
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

/// Container formats for `tk_archive_create`.
const ZIP: u32 = 0;
const SEVENZ: u32 = 1;
const TAR: u32 = 2;
const TAR_GZ: u32 = 3;
const TAR_XZ: u32 = 4;
const TAR_ZST: u32 = 5;
const TAR_BZ2: u32 = 6;
/// Read-only; `tk_archive_create` refuses it by name.
const RAR: u32 = 7;

/// Stream codecs for `tk_compress` / `tk_decompress`.
const GZIP: u32 = 0;
const XZ: u32 = 1;
const ZSTD: u32 = 2;
const BZIP2: u32 = 3;
/// `tk_decompress` codec meaning "read the file's magic number".
const DETECT: u32 = u32::MAX;

pub type ProgressCb = Option<unsafe extern "C" fn(
    completed: u64,
    total: u64,
    bytes: u64,
    bytes_total: u64,
    name: *const u8,
    name_len: usize,
)>;

/// Tells `cb` how far the call is, then fails with `STOPPED` once the caller has stopped it.
#[inline]
unsafe fn report_progress(
    cb: ProgressCb,
    completed: u64,
    total: u64,
    bytes: u64,
    bytes_total: u64,
    name: &str,
) -> Result<(), String> {
    if let Some(f) = cb {
        f(completed, total, bytes, bytes_total, name.as_ptr(), name.len());
    }
    stopped()
}

/// A verbatim path as Windows' own tools spell it: `\\?\C:\x` is `C:\x`, and
/// `\\?\UNC\srv\share\x` is `\\srv\share\x` (not `UNC\srv\share\x`).
#[cfg_attr(not(windows), allow(dead_code))]
fn unverbatim(s: &str) -> Option<String> {
    if let Some(share) = s.strip_prefix(r"\\?\UNC\") {
        return Some(format!(r"\\{share}"));
    }
    s.strip_prefix(r"\\?\").map(str::to_owned)
}

fn strip_unc(p: &Path) -> PathBuf {
    #[cfg(windows)]
    if let Some(s) = p.to_str().and_then(unverbatim) {
        return PathBuf::from(s);
    }
    p.to_path_buf()
}

fn canonicalize_safe(p: &Path) -> std::io::Result<PathBuf> {
    if let Ok(c) = p.canonicalize() {
        return Ok(strip_unc(&c));
    }
    let mut non_existing = Vec::new();
    let mut current = p;
    while !current.exists() {
        if let Some(name) = current.file_name() {
            non_existing.push(name);
        }
        if let Some(parent) = current.parent() {
            current = parent;
        } else {
            break;
        }
    }
    if let Ok(c) = current.canonicalize() {
        let mut canon = strip_unc(&c);
        for part in non_existing.into_iter().rev() {
            canon.push(part);
        }
        return Ok(canon);
    }
    Ok(strip_unc(p))
}

fn path_starts_with(child: &Path, parent: &Path) -> bool {
    let c = canonicalize_safe(child).unwrap_or_else(|_| strip_unc(child));
    let p = canonicalize_safe(parent).unwrap_or_else(|_| strip_unc(parent));
    #[cfg(windows)]
    {
        // By component, case-insensitively: C:\out-evil is not inside C:\out.
        let c_str = c.to_string_lossy().to_lowercase();
        let p_str = p.to_string_lossy().to_lowercase();
        Path::new(&c_str).starts_with(Path::new(&p_str))
    }
    #[cfg(not(windows))]
    {
        c.starts_with(&p)
    }
}

#[derive(serde::Serialize)]
struct Entry {
    name: String,
    size: u64,
    compressed: u64,
    dir: bool,
    encrypted: bool,
    modified: Option<i64>,
}

/// The first `n` bytes of `path`, or fewer at end of file.
fn head(path: &str, n: usize) -> Vec<u8> {
    let mut buf = Vec::with_capacity(n);
    if let Ok(f) = File::open(path) {
        // On a read error `buf` keeps what was read before it.
        let _ = f.take(n as u64).read_to_end(&mut buf);
    }
    buf
}

/// The container format by magic number, which outranks the file name. Single-stream codecs
/// are ambiguous (a gzip holds a tar or any one file), so `detect_read` asks the name first.
fn sniff(path: &str) -> Option<&'static str> {
    let b = head(path, 512);
    if b.len() >= 4 && &b[0..2] == b"PK" && matches!(b[2], 3 | 5 | 7) {
        return Some("zip");
    }
    if b.len() >= 6 && &b[0..6] == b"7z\xbc\xaf\x27\x1c" {
        return Some("7z");
    }
    if b.len() >= 7 && &b[0..6] == b"Rar!\x1a\x07" {
        return Some("rar");
    }
    // A tar's `ustar` magic sits at offset 257, not at the front.
    if b.len() >= 265 && &b[257..262] == b"ustar" {
        return Some("tar");
    }
    None
}

/// The codec of a single compressed stream, by magic number.
fn sniff_codec(path: &str) -> Option<u32> {
    let b = head(path, 8);
    if b.len() >= 2 && &b[0..2] == b"\x1f\x8b" {
        return Some(GZIP);
    }
    if b.len() >= 6 && &b[0..6] == b"\xfd7zXZ\x00" {
        return Some(XZ);
    }
    if b.len() >= 4 && &b[0..4] == b"\x28\xb5\x2f\xfd" {
        return Some(ZSTD);
    }
    if b.len() >= 3 && &b[0..3] == b"BZh" {
        return Some(BZIP2);
    }
    None
}

/// The format of `path`, read from its content, else from its name: 1 zip, 2 7z, 3 tar,
/// 4 tar.gz, 5 tar.xz, 6 tar.zst, 7 tar.bz2, 8 rar, 9 gzip, 10 xz, 11 zstd, 12 bzip2, 0 none. A
/// compressed stream's first 512 bytes are decoded to look for a tar's `ustar` magic, so a
/// misnamed tarball needs no listing to tell.
fn format(path: &str) -> i32 {
    let by_name = |kind: &str| match kind {
        "zip" => 1,
        "7z" => 2,
        "tar" => 3,
        "tar.gz" => 4,
        "tar.xz" => 5,
        "tar.zst" => 6,
        "tar.bz2" => 7,
        "rar" => 8,
        _ => 0,
    };
    if let Some(kind) = sniff(path) {
        return by_name(kind);
    }
    if let Some(codec) = sniff_codec(path) {
        let single = 9 + codec as i32;
        let Ok(file) = File::open(path) else { return single };
        let input = BufReader::new(file);
        let mut decoder: Box<dyn Read> = match codec {
            GZIP => Box::new(flate2::read::MultiGzDecoder::new(input)),
            XZ => Box::new(xz2::read::XzDecoder::new_multi_decoder(input)),
            ZSTD => match zstd::stream::read::Decoder::new(input) {
                Ok(d) => Box::new(d),
                Err(_) => return single,
            },
            _ => Box::new(bzip2::read::MultiBzDecoder::new(input)),
        };
        let mut block = Vec::with_capacity(512);
        let _ = decoder.by_ref().take(512).read_to_end(&mut block);
        return if block.len() >= 262 && &block[257..262] == b"ustar" { 4 + codec as i32 } else { single };
    }
    detect(path).map_or(0, by_name)
}

/// [format] of the file at `src`.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_format(src: *const u8, slen: usize) -> i32 {
    guard(|| Ok(format(text(src, slen)?)))
}

/// The format to read `path` as: an unambiguous magic number first, then the file name,
/// then a compressed stream taken to hold a tar.
fn detect_read(path: &str) -> Result<&'static str, String> {
    if let Some(kind) = sniff(path) {
        return Ok(kind);
    }
    if let Ok(kind) = detect(path) {
        return Ok(kind);
    }
    match sniff_codec(path) {
        Some(GZIP) => Ok("tar.gz"),
        Some(XZ) => Ok("tar.xz"),
        Some(ZSTD) => Ok("tar.zst"),
        Some(BZIP2) => Ok("tar.bz2"),
        _ => Err(format!("{}: not an archive, and its name does not say what it is", path)),
    }
}

fn detect(path: &str) -> Result<&'static str, String> {
    let lower = path.to_ascii_lowercase();
    Ok(if lower.ends_with(".zip") || lower.ends_with(".jar") {
        "zip"
    } else if lower.ends_with(".7z") {
        "7z"
    } else if lower.ends_with(".rar") {
        "rar"
    } else if lower.ends_with(".tar.gz") || lower.ends_with(".tgz") {
        "tar.gz"
    } else if lower.ends_with(".tar.xz") || lower.ends_with(".txz") {
        "tar.xz"
    } else if lower.ends_with(".tar.zst") || lower.ends_with(".tzst") {
        "tar.zst"
    } else if lower.ends_with(".tar.bz2") || lower.ends_with(".tbz2") {
        "tar.bz2"
    } else if lower.ends_with(".tar") {
        "tar"
    } else {
        return Err(format!("{}: unknown archive extension", path));
    })
}

fn inside(root: &Path, name: &str) -> Result<PathBuf, String> {
    let mut out = root.to_path_buf();
    for part in Path::new(name).components() {
        match part {
            std::path::Component::Normal(p) => out.push(p),
            std::path::Component::CurDir => {}
            _ => return Err(format!("archive entry escapes destination: {}", name)),
        }
    }
    Ok(out)
}

fn rar<'a>(path: &'a str, password: Option<&'a str>) -> unrar::Archive<'a> {
    match password {
        Some(pw) => unrar::Archive::with_password(path, pw),
        None => unrar::Archive::new(path),
    }
}

fn zip_open(path: &str) -> Result<zip::ZipArchive<Watched<File>>, String> {
    zip::ZipArchive::new(Watched(read_file(path)?)).msg()
}

/// A zip entry's name: its bytes as UTF-8 when they are UTF-8, flagged or not (Info-ZIP,
/// 7-Zip and many Windows and Linux tools write UTF-8 without the flag), else the zip
/// crate's reading (CP437, or the Unicode path extra field).
fn zip_name<'a>(f: &'a zip::read::ZipFile<'_>) -> &'a str {
    std::str::from_utf8(f.name_raw()).unwrap_or(f.name())
}

fn tar_reader(path: &str, kind: &str) -> Result<Box<dyn Read>, String> {
    let f = BufReader::new(Watched(read_file(path)?));
    Ok(match kind {
        "tar" => Box::new(f),
        "tar.gz" => Box::new(flate2::read::MultiGzDecoder::new(f)),
        "tar.xz" => Box::new(xz2::read::XzDecoder::new_multi_decoder(f)),
        "tar.zst" => Box::new(zstd::stream::read::Decoder::new(f).msg()?),
        "tar.bz2" => Box::new(bzip2::read::MultiBzDecoder::new(f)),
        _ => unreachable!(),
    })
}

fn validate_archive_level(format: u32, level: i32) -> Result<(), String> {
    match format {
        SEVENZ if level > 9 => Err("7z level is 0..=9".into()),
        ZIP | TAR_GZ => validate_codec_level(GZIP, level),
        TAR_XZ => validate_codec_level(XZ, level),
        TAR_ZST => validate_codec_level(ZSTD, level),
        TAR_BZ2 => validate_codec_level(BZIP2, level),
        _ => validate_codec_level(DETECT, level),
    }
}

/// `level` against the codec's range; -1 is its default, and only zstd goes below it.
fn validate_codec_level(codec: u32, level: i32) -> Result<(), String> {
    let err = match codec {
        _ if level < -1 && codec != ZSTD => "compression level cannot be negative",
        GZIP if level > 9 => "gzip/zip level is 0..=9",
        XZ if level > 9 => "xz level is 0..=9",
        BZIP2 if level == 0 || level > 9 => "bzip2 level is 1..=9",
        ZSTD if level > 22 => "zstd level is up to 22",
        _ => return Ok(()),
    };
    Err(err.into())
}

enum Encoder<W: Write> {
    Plain(W),
    Gz(flate2::write::GzEncoder<W>),
    Xz(xz2::write::XzEncoder<W>),
    Zst(zstd::stream::write::Encoder<'static, W>),
    Bz2(bzip2::write::BzEncoder<W>),
}

impl<W: Write> Write for Encoder<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Self::Plain(w) => w.write(buf),
            Self::Gz(w) => w.write(buf),
            Self::Xz(w) => w.write(buf),
            Self::Zst(w) => w.write(buf),
            Self::Bz2(w) => w.write(buf),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Self::Plain(w) => w.flush(),
            Self::Gz(w) => w.flush(),
            Self::Xz(w) => w.flush(),
            Self::Zst(w) => w.flush(),
            Self::Bz2(w) => w.flush(),
        }
    }
}

impl<W: Write> Encoder<W> {
    fn finish(self) -> std::io::Result<W> {
        match self {
            Self::Plain(mut w) => {
                w.flush()?;
                Ok(w)
            }
            Self::Gz(w) => w.finish(),
            Self::Xz(w) => w.finish(),
            Self::Zst(w) => w.finish(),
            Self::Bz2(w) => w.finish(),
        }
    }
}

/// Input at least this large is compressed on every core by zstd and xz; below it the threads
/// cost more than they win, and xz's 24 MiB blocks would leave all but one idle.

const PARALLEL: u64 = 32 << 20;

/// The worker threads for `size` bytes of input: 0 (single-threaded) below `PARALLEL`.
fn workers(size: u64) -> u32 {
    if size < PARALLEL {
        return 0;
    }
    std::thread::available_parallelism().map_or(1, |n| n.get() as u32)
}

/// xz(1)'s compression memory (MiB) and dictionary (KiB) per preset 0..=9.
const XZ_PRESETS: [(u64, u64); 10] =
    [(3, 256), (9, 1024), (17, 2048), (32, 4096), (48, 4096), (94, 8192), (94, 8192), (186, 16384), (370, 32768), (674, 65536)];

/// xz's threads for `size` bytes at `level`: no more than the cores, the 3-dictionary blocks
/// the input fills, or what a quarter of RAM (2 GiB when unknown) holds at a preset's memory
/// plus an input and output block per thread. One thread is the single-threaded encoder.
fn xz_threads(level: u32, size: u64) -> u32 {
    let (mem, dict) = XZ_PRESETS[level.min(9) as usize];
    let block = (3 * dict << 10).max(1 << 20);
    let per_thread = (mem << 20) + 2 * block;
    let budget = ram().map_or(2 << 30, |r| r / 4);
    let n = (workers(size) as u64).min(size.div_ceil(block)).min(budget / per_thread);
    if n > 1 {
        n as u32
    } else {
        0
    }
}

/// Physical memory in bytes, where the OS says.
#[cfg(unix)]
fn ram() -> Option<u64> {
    // SAFETY: `sysconf` only reads configuration.
    let (pages, page) = unsafe { (libc::sysconf(libc::_SC_PHYS_PAGES), libc::sysconf(libc::_SC_PAGESIZE)) };
    (pages > 0 && page > 0).then(|| pages as u64 * page as u64)
}
#[cfg(not(unix))]
fn ram() -> Option<u64> {
    None
}

fn xz_encoder<W: Write>(out: W, level: u32, size: u64) -> Result<xz2::write::XzEncoder<W>, String> {
    match xz_threads(level, size) {
        0 => Ok(xz2::write::XzEncoder::new(out, level)),
        n => {
            let stream = xz2::stream::MtStreamBuilder::new()
                .threads(n)
                .preset(level)
                .check(xz2::stream::Check::Crc64)
                .encoder()
                .msg()?;
            Ok(xz2::write::XzEncoder::new_stream(out, stream))
        }
    }
}

fn zstd_encoder<W: Write>(out: W, level: i32, size: u64) -> Result<zstd::stream::write::Encoder<'static, W>, String> {
    let mut enc = zstd::stream::write::Encoder::new(out, level).msg()?;
    if let n @ 1.. = workers(size) {
        enc.multithread(n).msg()?;
    }
    Ok(enc)
}

/// The `codec` writer over `out`, or `out` itself for `None`; `size` is the input's, and
/// `level` -1 is the codec's default.
fn encoder<W: Write>(codec: Option<u32>, out: W, level: i32, size: u64) -> Result<Encoder<W>, String> {
    let lvl = |d: u32| if level < 0 { d } else { level as u32 };
    Ok(match codec {
        None => Encoder::Plain(out),
        Some(GZIP) => Encoder::Gz(flate2::write::GzEncoder::new(out, flate2::Compression::new(lvl(6)))),
        Some(XZ) => Encoder::Xz(xz_encoder(out, lvl(6), size)?),
        Some(ZSTD) => Encoder::Zst(zstd_encoder(out, if level == -1 { 3 } else { level }, size)?),
        Some(BZIP2) => Encoder::Bz2(bzip2::write::BzEncoder::new(out, bzip2::Compression::new(lvl(9)))),
        Some(c) => return Err(format!("unknown codec {}", c)),
    })
}

// ---- list

fn list(path: &str, password: Option<&str>) -> Result<Vec<Entry>, String> {
    let kind = detect_read(path)?;
    let mut out = Vec::new();
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            for i in 0..z.len() {
                let f = z.by_index_raw(i).msg()?;
                out.push(Entry {
                    name: zip_name(&f).to_string(),
                    size: f.size(),
                    compressed: f.compressed_size(),
                    dir: f.is_dir(),
                    encrypted: f.encrypted(),
                    modified: f.last_modified().and_then(zip_to_unix),
                });
            }
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            let reader = sevenz_rust2::SevenZReader::open(path, pw).msg()?;
            let archive = reader.archive();
            for (i, f) in archive.files.iter().enumerate() {
                out.push(Entry {
                    name: f.name().to_string(),
                    size: f.size(),
                    compressed: f.compressed_size,
                    dir: f.is_directory(),
                    encrypted: sevenz_encrypted(archive, i),
                    modified: f.has_last_modified_date.then(|| f.last_modified_date().to_unix_time_secs()),
                });
            }
        }
        "rar" => {
            let mut a = rar(path, password).open_for_listing().msg()?;
            while let Some(h) = a.read_header().msg()? {
                let e = h.entry();
                out.push(Entry {
                    name: e.filename.to_string_lossy().to_string(),
                    size: e.unpacked_size,
                    // unrar's listing header exposes no packed size, so this repeats the
                    // unpacked one rather than inventing a number.
                    compressed: e.unpacked_size,
                    dir: e.is_directory(),
                    encrypted: e.is_encrypted(),
                    modified: None,
                });
                a = h.skip().msg()?;
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            for e in t.entries().msg()? {
                let e = e.msg()?;
                let h = e.header();
                out.push(Entry {
                    name: e.path().msg()?.to_string_lossy().to_string(),
                    size: h.size().unwrap_or(0),
                    compressed: h.size().unwrap_or(0),
                    dir: h.entry_type().is_dir(),
                    encrypted: false,
                    modified: h.mtime().ok().map(|m| m as i64),
                });
            }
        }
    }
    Ok(out)
}

/// Whether the 7z file at index `i` sits in an AES-encrypted folder.
fn sevenz_encrypted(archive: &sevenz_rust2::Archive, i: usize) -> bool {
    archive
        .stream_map
        .file_folder_index
        .get(i)
        .copied()
        .flatten()
        .and_then(|fi| archive.folders.get(fi))
        .is_some_and(|folder| {
            folder.coders.iter().any(|c| c.decompression_method_id() == sevenz_rust2::SevenZMethod::ID_AES256SHA256)
        })
}

/// Writes the entries of the archive at `path` as a JSON array; the caller frees with `tk_free`.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_list(path: *const u8, plen: usize, pw: *const u8, pwlen: usize, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let entries = list(text(path, plen)?, opt_text(pw, pwlen)?)?;
        Ok(give(serde_json::to_vec(&entries).msg()?, out, out_len))
    })
}

// ---- extract

/// `flags` bit: the archive is trusted — no size cap, setuid/setgid kept, links may point anywhere.
const TRUSTED: u32 = 1;
/// `flags` bit: `only` matches without regard to case, as the platform's own paths do.
const FOLD_CASE: u32 = 2;

/// What an untrusted archive may write: 200 times its own size, and never less than 1 GiB.
/// A fixed cap is too small for a large archive or too large to stop a small bomb; source
/// trees, logs and dumps compress 5–50×.
const RATIO: u64 = 200;
const FLOOR: u64 = 1 << 30;

/// What an extraction may write, which entries it wants, and the links it made, which are
/// checked again once everything they could point at exists.
struct Policy {
    trusted: bool,
    budget: u64,
    limit: u64,
    only: Option<Vec<char>>,
    fold: bool,
    root: PathBuf,
    links: Vec<PathBuf>,
    /// Directories already found inside `root`; cleared whenever a link is made.
    checked: std::collections::HashSet<PathBuf>,
}

impl Policy {
    fn new(path: &str, root: &Path, only: Option<&str>, flags: u32) -> Result<Policy, String> {
        let trusted = flags & TRUSTED != 0;
        let size = std::fs::metadata(path).map_err(|e| format!("{}: {}", path, e))?.len();
        let limit = if trusted { u64::MAX } else { FLOOR.max(size.saturating_mul(RATIO)) };
        Ok(Policy {
            trusted,
            budget: limit,
            limit,
            only: only.map(|p| p.replace('\\', "/").chars().collect()),
            fold: flags & FOLD_CASE != 0,
            root: canonicalize_safe(root).map_err(|e| format!("{}: {}", root.display(), e))?,
            links: Vec::new(),
            checked: std::collections::HashSet::new(),
        })
    }

    /// Whether `name` is one of the entries asked for.
    fn wants(&self, name: &str) -> bool {
        match &self.only {
            None => true,
            Some(p) => {
                let n: Vec<char> = name.replace('\\', "/").trim_end_matches('/').trim_start_matches("./").chars().collect();
                glob(p, &n, self.fold)
            }
        }
    }

    /// Takes `size` bytes off what is left to write, or refuses naming the cap.
    fn charge(&mut self, size: u64, name: &str) -> Result<(), String> {
        if size > self.budget {
            return Err(format!(
                "{}: extracting it would write more than {} bytes, {}× the archive and at least 1 GiB; \
                 unarchive with unsafe: true if that is expected",
                name, self.limit, RATIO
            ));
        }
        self.budget -= size;
        Ok(())
    }

    /// `dir` is inside the destination once links are resolved. Asked of every directory an
    /// entry lands in: a link left by an earlier archive leads out just as well.
    fn contains(&mut self, dir: &Path) -> Result<(), String> {
        if self.trusted || self.checked.contains(dir) {
            return Ok(());
        }
        match resolve(dir, 0) {
            Some(real) if path_starts_with(&real, &self.root) => {
                self.checked.insert(dir.to_path_buf());
                Ok(())
            }
            _ => Err(format!("{}: reached through a link that leaves the destination", dir.display())),
        }
    }

    /// Creates the link `at` → `target`, for the entry `name`, unless it would lead out.
    fn link(&mut self, at: &Path, name: &str, target: &str) -> Result<(), String> {
        if !self.trusted {
            escapes(name, target)?;
        }
        if let Some(parent) = at.parent() {
            self.contains(parent)?;
            std::fs::create_dir_all(parent).msg()?;
        }
        let _ = std::fs::remove_file(at);
        self.checked.clear();
        #[cfg(unix)]
        std::os::unix::fs::symlink(target, at).map_err(|e| format!("{}: {}", at.display(), e))?;
        // Windows needs a privilege for a symlink; the link's text is what the entry holds.
        #[cfg(not(unix))]
        std::fs::write(at, target).map_err(|e| format!("{}: {}", at.display(), e))?;
        self.links.push(at.to_path_buf());
        Ok(())
    }

    /// Checks every link again now that everything it could point through exists: `b/..` is
    /// inside by its text and outside once `b` is a link to `.`. A dangling link is followed
    /// as far as it goes.
    fn finish(&self) -> Result<(), String> {
        if self.trusted {
            return Ok(());
        }
        let mut result = Ok(());
        for link in &self.links {
            if !resolve(link, 0).is_some_and(|real| path_starts_with(&real, &self.root)) {
                let _ = std::fs::remove_file(link);
                if result.is_ok() {
                    result = Err(format!("{}: link leads out of the destination", link.display()));
                }
            }
        }
        result
    }
}

/// Where `path` leads once every link on the way is followed, whether or not its end exists —
/// `canonicalize` for a path that may dangle. `None` for a loop.
fn resolve(path: &Path, hops: u32) -> Option<PathBuf> {
    let absolute = if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir().ok()?.join(path) };
    let mut out = PathBuf::new();
    for part in absolute.components() {
        match part {
            std::path::Component::Prefix(_) | std::path::Component::RootDir => out.push(part.as_os_str()),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::Normal(name) => {
                out.push(name);
                if let Ok(meta) = out.symlink_metadata() {
                    if meta.file_type().is_symlink() {
                        if hops >= 40 {
                            return None;
                        }
                        let target = std::fs::read_link(&out).ok()?;
                        out.pop();
                        out = resolve(&out.join(target), hops + 1)?;
                    }
                }
            }
        }
    }
    Some(out)
}

/// Whether a link at entry `name` pointing at `target` leaves the archive's own tree, by text.
fn escapes(name: &str, target: &str) -> Result<(), String> {
    let refuse = || Err(format!("{}: link to {} leads out of the destination", name, target));
    let t = Path::new(target);
    if target.starts_with('/') || target.starts_with('\\') || t.is_absolute() {
        return refuse();
    }
    let mut depth = Path::new(name).parent().map_or(0, |p| {
        p.components().filter(|c| matches!(c, std::path::Component::Normal(_))).count() as i64
    });
    for c in t.components() {
        match c {
            std::path::Component::Normal(_) => depth += 1,
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                depth -= 1;
                if depth < 0 {
                    return refuse();
                }
            }
            _ => return refuse(),
        }
    }
    Ok(())
}

/// `*`, `?` and `**` over `/`-separated names, as `Path.glob` means them: `*` and `?` stop at
/// a `/`, `**/` is any number of whole directories, and a bare `**` anything at all.
fn glob(p: &[char], s: &[char], fold: bool) -> bool {
    let eq = |a: char, b: char| if fold { a.to_lowercase().eq(b.to_lowercase()) } else { a == b };
    match p {
        [] => s.is_empty(),
        ['*', '*', '/', rest @ ..] => {
            glob(rest, s, fold) || (1..s.len()).any(|i| s[i] == '/' && glob(rest, &s[i + 1..], fold))
        }
        ['*', '*', rest @ ..] => (0..=s.len()).any(|i| glob(rest, &s[i..], fold)),
        ['*', rest @ ..] => {
            let mut i = 0;
            loop {
                if glob(rest, &s[i..], fold) {
                    return true;
                }
                if i == s.len() || s[i] == '/' {
                    return false;
                }
                i += 1;
            }
        }
        ['?', rest @ ..] => !s.is_empty() && s[0] != '/' && glob(rest, &s[1..], fold),
        ['[', rest @ ..] => {
            // A `]` first in the set, after any `!` or `^`, is one of it rather than its end.
            let lead = usize::from(matches!(rest.first(), Some('!' | '^')));
            let from = if rest.get(lead) == Some(&']') { lead + 1 } else { lead };
            if let Some(end) = rest[from..].iter().position(|&c| c == ']').map(|e| e + from) {
                if !s.is_empty() && s[0] != '/' {
                    let class = &rest[..end];
                    let after = &rest[end + 1..];
                    let (negated, spec) = if class.starts_with(&['!']) || class.starts_with(&['^']) {
                        (true, &class[1..])
                    } else {
                        (false, class)
                    };
                    let mut matched = false;
                    let mut i = 0;
                    while i < spec.len() {
                        if i + 2 < spec.len() && spec[i + 1] == '-' {
                            let (c_s, c_f, sc) = if fold {
                                (spec[i].to_ascii_lowercase(), spec[i + 2].to_ascii_lowercase(), s[0].to_ascii_lowercase())
                            } else {
                                (spec[i], spec[i + 2], s[0])
                            };
                            if sc >= c_s && sc <= c_f {
                                matched = true;
                                break;
                            }
                            i += 3;
                        } else {
                            if eq(spec[i], s[0]) {
                                matched = true;
                                break;
                            }
                            i += 1;
                        }
                    }
                    if (matched != negated) && glob(after, &s[1..], fold) {
                        return true;
                    }
                }
                return false;
            }
            !s.is_empty() && eq('[', s[0]) && glob(rest, &s[1..], fold)
        }
        ['{', rest @ ..] => {
            let mut depth = 0;
            let mut close = None;
            for (idx, &c) in rest.iter().enumerate() {
                if c == '{' {
                    depth += 1;
                } else if c == '}' {
                    if depth == 0 {
                        close = Some(idx);
                        break;
                    } else {
                        depth -= 1;
                    }
                }
            }
            if let Some(end) = close {
                let inside = &rest[..end];
                let after = &rest[end + 1..];
                let mut d = 0;
                let mut start = 0;
                let mut alts = Vec::new();
                for (i, &c) in inside.iter().enumerate() {
                    if c == '{' {
                        d += 1;
                    } else if c == '}' {
                        d -= 1;
                    } else if c == ',' && d == 0 {
                        alts.push(&inside[start..i]);
                        start = i + 1;
                    }
                }
                alts.push(&inside[start..]);
                // One alternative is no choice: `b{1}.txt` names itself.
                if alts.len() > 1 {
                    for alt in alts {
                        let mut combined = Vec::with_capacity(alt.len() + after.len());
                        combined.extend_from_slice(alt);
                        combined.extend_from_slice(after);
                        if glob(&combined, s, fold) {
                            return true;
                        }
                    }
                    return false;
                }
            }
            !s.is_empty() && eq('{', s[0]) && glob(rest, &s[1..], fold)
        }
        [c, rest @ ..] => !s.is_empty() && eq(*c, s[0]) && glob(rest, &s[1..], fold),
    }
}

/// Copies at most `max` bytes; one more is an entry larger than its header said, which is how
/// a bomb that lies about its size would get past the budget.
fn copy_capped(from: &mut dyn Read, to: &mut dyn Write, max: u64, name: &str) -> Result<u64, String> {
    let n = std::io::copy(&mut from.take(max.saturating_add(1)), to).map_err(|e| format!("{}: {}", name, e))?;
    if n > max {
        return Err(format!("{}: larger than its header says ({} bytes)", name, max));
    }
    Ok(n)
}

fn unix_time(secs: i64) -> std::time::SystemTime {
    std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs.max(0) as u64)
}

/// Writes one file of `size` bytes from `from`, stamping `mtime` before the mode, because a
/// read-only mode set first would refuse the time.
fn write_file(
    pol: &mut Policy,
    target: &Path,
    from: &mut dyn Read,
    size: u64,
    name: &str,
    mtime: Option<i64>,
    mode: Option<u32>,
) -> Result<(), String> {
    pol.charge(size, name)?;
    if let Some(parent) = target.parent() {
        pol.contains(parent)?;
    }
    let mut w = BufWriter::new(fresh(target)?);
    copy_capped(&mut Watched(from), &mut w, size, name)?;
    let file = w.into_inner().msg()?;
    if let Some(s) = mtime {
        let _ = file.set_modified(unix_time(s));
    }
    drop(file);
    set_mode(target, mode, pol.trusted);
    Ok(())
}

/// A new file at `target`, replacing whatever is there without writing through it: a link
/// left at that name by an earlier archive would otherwise carry the bytes wherever it points.
fn fresh(target: &Path) -> Result<File, String> {
    let err = |e: std::io::Error| format!("{}: {}", target.display(), e);
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(err)?;
    }
    if target.symlink_metadata().is_ok_and(|m| !m.is_dir()) {
        std::fs::remove_file(target).map_err(err)?;
    }
    // `create_new` is O_EXCL, which refuses a link as well as a file that appeared since.
    std::fs::OpenOptions::new().write(true).create_new(true).open(target).map_err(err)
}

/// The permission bits, without setuid, setgid and sticky unless the archive is trusted: a
/// downloaded archive has no business handing out a setuid binary.
#[cfg(unix)]
fn set_mode(path: &Path, mode: Option<u32>, trusted: bool) {
    use std::os::unix::fs::PermissionsExt;
    if let Some(m) = mode {
        let bits = if trusted { m & 0o7777 } else { m & 0o777 };
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(bits));
    }
}
#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: Option<u32>, _trusted: bool) {}

/// Clears setuid, setgid and sticky on a file another library wrote.
#[cfg(unix)]
fn strip_setid(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        let m = meta.permissions().mode();
        if meta.is_file() && m & 0o7000 != 0 {
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(m & 0o777));
        }
    }
}
#[cfg(not(unix))]
fn strip_setid(_path: &Path) {}

fn zip_mtime(f: &zip::read::ZipFile) -> Option<i64> {
    f.last_modified().and_then(zip_to_unix)
}

/// A zip entry's time as a Unix time. A zip stores zoneless wall-clock time, and every tool
/// from `unzip` to Explorer reads it as local time.
#[cfg(unix)]
fn zip_to_unix(d: zip::DateTime) -> Option<i64> {
    // SAFETY: `tm` is plain data, and `mktime` only reads and normalises it.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = d.year() as i32 - 1900;
    tm.tm_mon = d.month() as i32 - 1;
    tm.tm_mday = d.day() as i32;
    tm.tm_hour = d.hour() as i32;
    tm.tm_min = d.minute() as i32;
    tm.tm_sec = d.second() as i32;
    tm.tm_isdst = -1;
    match unsafe { libc::mktime(&mut tm) } {
        -1 => None,
        t => Some(t as i64),
    }
}

/// The zip time for a Unix time, in local time for the same reason.
#[cfg(unix)]
fn unix_to_zip(secs: i64) -> Option<zip::DateTime> {
    let t = secs as libc::time_t;
    // SAFETY: `localtime_r` writes only into `tm`, and reports failure by returning null.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&t, &mut tm) }.is_null() {
        return None;
    }
    zip::DateTime::from_date_and_time(
        (tm.tm_year + 1900).try_into().ok()?,
        (tm.tm_mon + 1) as u8,
        tm.tm_mday as u8,
        tm.tm_hour as u8,
        tm.tm_min as u8,
        tm.tm_sec as u8,
    )
    .ok()
}

#[cfg(windows)]
#[allow(non_snake_case)]
#[repr(C)]
struct SYSTEMTIME {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
}

#[cfg(windows)]
#[allow(non_snake_case)]
#[repr(C)]
struct FILETIME {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
}

#[cfg(windows)]
extern "system" {
    fn TzSpecificLocalTimeToSystemTime(
        lpTimeZoneInformation: *const std::ffi::c_void,
        lpLocalTime: *const SYSTEMTIME,
        lpUniversalTime: *mut SYSTEMTIME,
    ) -> i32;
    fn SystemTimeToTzSpecificLocalTime(
        lpTimeZoneInformation: *const std::ffi::c_void,
        lpUniversalTime: *const SYSTEMTIME,
        lpLocalTime: *mut SYSTEMTIME,
    ) -> i32;
    fn SystemTimeToFileTime(
        lpSystemTime: *const SYSTEMTIME,
        lpFileTime: *mut FILETIME,
    ) -> i32;
    fn FileTimeToSystemTime(
        lpFileTime: *const FILETIME,
        lpSystemTime: *mut SYSTEMTIME,
    ) -> i32;
}

#[cfg(windows)]
fn zip_to_unix(d: zip::DateTime) -> Option<i64> {
    let local_st = SYSTEMTIME {
        wYear: d.year(),
        wMonth: d.month() as u16,
        wDayOfWeek: 0,
        wDay: d.day() as u16,
        wHour: d.hour() as u16,
        wMinute: d.minute() as u16,
        wSecond: d.second() as u16,
        wMilliseconds: 0,
    };
    let mut utc_st: SYSTEMTIME = unsafe { std::mem::zeroed() };
    if unsafe { TzSpecificLocalTimeToSystemTime(std::ptr::null(), &local_st, &mut utc_st) } == 0 {
        return None;
    }
    let mut ft: FILETIME = unsafe { std::mem::zeroed() };
    if unsafe { SystemTimeToFileTime(&utc_st, &mut ft) } == 0 {
        return None;
    }
    let intervals = ((ft.dwHighDateTime as u64) << 32) | (ft.dwLowDateTime as u64);
    let unix_secs = (intervals.checked_sub(116444736000000000)? / 10_000_000) as i64;
    Some(unix_secs)
}

#[cfg(windows)]
fn unix_to_zip(secs: i64) -> Option<zip::DateTime> {
    if secs < 0 {
        return None;
    }
    let intervals = (secs as u64).checked_mul(10_000_000)?.checked_add(116444736000000000)?;
    let ft = FILETIME {
        dwLowDateTime: intervals as u32,
        dwHighDateTime: (intervals >> 32) as u32,
    };
    let mut utc_st: SYSTEMTIME = unsafe { std::mem::zeroed() };
    if unsafe { FileTimeToSystemTime(&ft, &mut utc_st) } == 0 {
        return None;
    }
    let mut local_st: SYSTEMTIME = unsafe { std::mem::zeroed() };
    if unsafe { SystemTimeToTzSpecificLocalTime(std::ptr::null(), &utc_st, &mut local_st) } == 0 {
        return None;
    }
    zip::DateTime::from_date_and_time(
        local_st.wYear,
        local_st.wMonth as u8,
        local_st.wDay as u8,
        local_st.wHour as u8,
        local_st.wMinute as u8,
        local_st.wSecond as u8,
    )
    .ok()
}

#[cfg(not(any(unix, windows)))]
fn zip_to_unix(d: zip::DateTime) -> Option<i64> {
    time::OffsetDateTime::try_from(d).ok().map(|t| t.unix_timestamp())
}
#[cfg(not(any(unix, windows)))]
fn unix_to_zip(secs: i64) -> Option<zip::DateTime> {
    time::OffsetDateTime::from_unix_timestamp(secs).ok()?.try_into().ok()
}

fn seven_err(m: String) -> sevenz_rust2::Error {
    sevenz_rust2::Error::other(m)
}

fn extract(path: &str, dest: &str, password: Option<&str>, only: Option<&str>, flags: u32, progress: ProgressCb) -> Result<i32, String> {
    let kind = detect_read(path)?;
    let root = Path::new(dest);
    std::fs::create_dir_all(root).msg()?;
    let mut pol = Policy::new(path, root, only, flags)?;
    let mut count = 0;
    let mut dirs: Vec<(PathBuf, Option<u32>, Option<i64>)> = Vec::new();
    // Kept past the match, so the last report still says how many bytes there were.
    let (mut bytes_done, mut total_bytes) = (0u64, 0u64);
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            let total = z.len() as u64;
            // Raw, so an encrypted entry counts without its password; only what is extracted counts.
            for i in 0..z.len() {
                if let Ok(f) = z.by_index_raw(i) {
                    if !f.is_dir() && pol.wants(zip_name(&f)) {
                        total_bytes = total_bytes.saturating_add(f.size());
                    }
                }
            }
            unsafe {
                report_progress(progress, 0, total, 0, total_bytes, "")?;
            }
            for i in 0..z.len() {
                let mut f = match password {
                    Some(pw) => z.by_index_decrypt(i, pw.as_bytes()).msg()?,
                    None => z.by_index(i).msg()?,
                };
                let name = zip_name(&f).to_string();
                unsafe {
                    report_progress(progress, i as u64, total, bytes_done, total_bytes, &name)?;
                }
                let target = inside(root, &name)?;
                if !pol.wants(&name) {
                    continue;
                }
                if f.is_dir() {
                    pol.contains(&target)?;
                    std::fs::create_dir_all(&target).msg()?;
                    dirs.push((target.clone(), f.unix_mode(), zip_mtime(&f)));
                    continue;
                }
                if f.is_symlink() {
                    let mut link = String::new();
                    (&mut f).take(4096).read_to_string(&mut link).msg()?;
                    pol.link(&target, &name, &link)?;
                    continue;
                }
                let (size, mtime, mode) = (f.size(), zip_mtime(&f), f.unix_mode());
                write_file(&mut pol, &target, &mut f, size, &name, mtime, mode)?;
                bytes_done += size;
                count += 1;
                unsafe {
                    report_progress(progress, (i + 1) as u64, total, bytes_done, total_bytes, &name)?;
                }
            }
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            let mut reader = sevenz_rust2::SevenZReader::open(path, pw).msg()?;
            // Every name is checked, and every size charged, before anything is written.
            let mut wanted = 0u64;
            for e in &reader.archive().files {
                inside(root, e.name())?;
                if pol.wants(e.name()) && !e.is_directory() {
                    wanted = wanted.saturating_add(e.size());
                }
            }
            pol.charge(wanted, path)?;
            pol.budget = u64::MAX;
            let total = reader.archive().files.len() as u64;
            total_bytes = wanted;
            let mut idx = 0u64;
            unsafe {
                report_progress(progress, 0, total, 0, total_bytes, "")?;
            }
            reader
                .for_each_entries(|e, r| {
                    let name = e.name().to_string();
                    unsafe {
                        report_progress(progress, idx, total, bytes_done, total_bytes, &name).map_err(seven_err)?;
                    }
                    if !pol.wants(&name) {
                        // A solid block is one stream: an entry not wanted is still read past.
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        idx += 1;
                        return Ok(true);
                    }
                    let target = inside(root, &name).map_err(seven_err)?;
                    let mtime = e.has_last_modified_date.then(|| e.last_modified_date().to_unix_time_secs());
                    let mode = Some(e.windows_attributes >> 16).filter(|&m| e.has_windows_attributes && m != 0);
                    if e.is_directory() {
                        pol.contains(&target).map_err(seven_err)?;
                        std::fs::create_dir_all(&target).map_err(sevenz_rust2::Error::io)?;
                        dirs.push((target.clone(), mode, mtime));
                        idx += 1;
                        return Ok(true);
                    }
                    write_file(&mut pol, &target, r, e.size(), &name, mtime, mode).map_err(seven_err)?;
                    bytes_done += e.size();
                    count += 1;
                    idx += 1;
                    unsafe {
                        report_progress(progress, idx, total, bytes_done, total_bytes, &name).map_err(seven_err)?;
                    }
                    Ok(true)
                })
                .msg()?;
        }
        "rar" => {
            let mut a = rar(path, password).open_for_processing().msg()?;
            let mut idx = 0u64;
            unsafe {
                report_progress(progress, 0, 0, 0, 0, "")?;
            }
            while let Some(h) = a.read_header().msg()? {
                let name = h.entry().filename.to_string_lossy().to_string();
                let target = inside(root, &name)?;
                unsafe {
                    report_progress(progress, idx, 0, bytes_done, 0, &name)?;
                }
                if !pol.wants(&name) {
                    a = h.skip().msg()?;
                    idx += 1;
                    continue;
                }
                let is_file = h.entry().is_file();
                let fsize = if is_file { h.entry().unpacked_size } else { 0 };
                if is_file {
                    pol.charge(h.entry().unpacked_size, &name)?;
                }
                // unrar writes the file itself, so what it could be steered through is
                // checked first: the directory it lands in, and a link already at its name.
                if !pol.trusted {
                    if let Some(parent) = target.parent() {
                        pol.contains(parent)?;
                    }
                    if target.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()) {
                        std::fs::remove_file(&target).msg()?;
                    }
                }
                a = h.extract_with_base(dest).msg()?;
                if target.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()) {
                    pol.links.push(target.clone());
                    pol.checked.clear();
                }
                if is_file {
                    if !pol.trusted {
                        strip_setid(&target);
                    }
                    bytes_done += fsize;
                    count += 1;
                }
                idx += 1;
                unsafe {
                    report_progress(progress, idx, 0, bytes_done, 0, &name)?;
                }
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            // Without it the crate keeps the permission bits and drops setuid, setgid, sticky.
            t.set_preserve_permissions(pol.trusted);
            t.set_preserve_mtime(true);
            let mut idx = 0u64;
            unsafe {
                report_progress(progress, 0, 0, 0, 0, "")?;
            }
            for e in t.entries().msg()? {
                let mut e = e.msg()?;
                let name = e.path().msg()?.to_string_lossy().to_string();
                let target = inside(root, &name)?;
                unsafe {
                    report_progress(progress, idx, 0, bytes_done, 0, &name)?;
                }
                if !pol.wants(&name) {
                    idx += 1;
                    continue;
                }
                let kind = e.header().entry_type();
                if kind.is_symlink() {
                    let link = e.link_name().msg()?.map(|l| l.to_string_lossy().to_string());
                    if !pol.trusted {
                        escapes(&name, link.as_deref().unwrap_or(""))?;
                    }
                    if let Some(parent) = target.parent() {
                        pol.contains(parent)?;
                    }
                    pol.links.push(target.clone());
                    pol.checked.clear();
                } else {
                    pol.charge(e.size(), &name)?;
                }
                // Made here and given its mode last, with the others: `unpack_in` sets a
                // read-only mode at once, and the directory's own entries are then refused.
                if kind.is_dir() {
                    pol.contains(&target)?;
                    std::fs::create_dir_all(&target).map_err(|e| format!("{}: {}", target.display(), e))?;
                    let mtime = e.header().mtime().ok().map(|m| m as i64);
                    dirs.push((target, e.header().mode().ok(), mtime));
                    idx += 1;
                    continue;
                }
                let fsize = e.size();
                if e.unpack_in(root).msg()? && kind.is_file() {
                    bytes_done += fsize;
                    count += 1;
                }
                idx += 1;
                unsafe {
                    report_progress(progress, idx, 0, bytes_done, 0, &name)?;
                }
            }
        }
    }
    pol.finish()?;
    for (dir, mode, mtime) in dirs.into_iter().rev() {
        if let Some(_s) = mtime {
            #[cfg(unix)]
            if let Ok(f) = std::fs::File::open(&dir) {
                let _ = f.set_modified(unix_time(_s));
            }
        }
        set_mode(&dir, mode, pol.trusted);
    }
    unsafe {
        report_progress(progress, count as u64, count as u64, bytes_done, total_bytes, "")?;
    }
    Ok(count)
}

/// Extracts the archive at `path` into `dest`; returns the number of files written.
///
/// `only`, when not null, is a glob the entry names must match. `flags` is `TRUSTED` and
/// `FOLD_CASE`. An untrusted archive may write at most `RATIO` times its size (at least
/// `FLOOR`), loses setuid, setgid and sticky, and may not make a link that leads out.
/// `progress`, when not null, hears each entry; `stop`, when not null, is a byte that stops the
/// call once set.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_extract(
    path: *const u8,
    plen: usize,
    dest: *const u8,
    dlen: usize,
    pw: *const u8,
    pwlen: usize,
    only: *const u8,
    olen: usize,
    flags: u32,
    progress: ProgressCb,
    stop: *const u8,
) -> i32 {
    let _watch = watch(stop);
    guard(|| extract(text(path, plen)?, text(dest, dlen)?, opt_text(pw, pwlen)?, opt_text(only, olen)?, flags, progress))
}

/// An entry name as the caller would write it: `/`-separated, no leading `./`.
fn plain(name: &str) -> String {
    name.replace('\\', "/").trim_start_matches("./").to_string()
}

fn read_entry(path: &str, name: &str, password: Option<&str>, flags: u32) -> Result<Vec<u8>, String> {
    let kind = detect_read(path)?;
    let mut pol = Policy::new(path, Path::new("."), None, flags)?;
    let want = plain(name);
    let missing = || format!("{}: no entry {}", path, name);
    let mut out = Vec::new();
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            // By the name `list` gives, which the zip crate's own lookup does not read.
            let index = (0..z.len())
                .find(|&i| z.by_index_raw(i).is_ok_and(|f| zip_name(&f) == want))
                .ok_or_else(missing)?;
            let mut f = match password {
                Some(pw) => z.by_index_decrypt(index, pw.as_bytes()),
                None => z.by_index(index),
            }
            .msg()?;
            pol.charge(f.size(), name)?;
            let size = f.size();
            copy_capped(&mut f, &mut out, size, name)?;
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            let mut reader = sevenz_rust2::SevenZReader::open(path, pw).msg()?;
            let mut found = false;
            reader
                .for_each_entries(|e, r| {
                    if plain(e.name()) != want {
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        return Ok(true);
                    }
                    found = true;
                    pol.charge(e.size(), name).map_err(seven_err)?;
                    copy_capped(r, &mut out, e.size(), name).map_err(seven_err)?;
                    Ok(false)
                })
                .msg()?;
            if !found {
                return Err(missing());
            }
        }
        "rar" => {
            let mut a = rar(path, password).open_for_processing().msg()?;
            loop {
                let Some(h) = a.read_header().msg()? else { return Err(missing()) };
                if plain(&h.entry().filename.to_string_lossy()) == want && h.entry().is_file() {
                    pol.charge(h.entry().unpacked_size, name)?;
                    out = h.read().msg()?.0;
                    break;
                }
                a = h.skip().msg()?;
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            let mut found = false;
            for e in t.entries().msg()? {
                let mut e = e.msg()?;
                let n = plain(&e.path().msg()?.to_string_lossy());
                if n == want && e.header().entry_type().is_file() {
                    pol.charge(e.size(), name)?;
                    let size = e.size();
                    copy_capped(&mut e, &mut out, size, name)?;
                    found = true;
                    break;
                }
            }
            if !found {
                return Err(missing());
            }
        }
    }
    Ok(out)
}

/// Reads the one entry `name` of the archive at `path` into a Rust allocation the caller frees
/// with `tk_free`. `flags` is `TRUSTED`, which lifts the size cap as for `tk_archive_extract`.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_read(
    path: *const u8,
    plen: usize,
    name: *const u8,
    nlen: usize,
    pw: *const u8,
    pwlen: usize,
    flags: u32,
    out: *mut *mut u8,
    out_len: *mut usize,
    stop: *const u8,
) -> i32 {
    let _watch = watch(stop);
    guard(|| {
        let data = read_entry(text(path, plen)?, text(name, nlen)?, opt_text(pw, pwlen)?, flags)?;
        Ok(give(data, out, out_len))
    })
}

// ---- contents

/// Reads every file of the archive at `path` that `only` wants, in archive order, and hands
/// each to `emit` whole; stops when `emit` answers false. One pass, so a solid block or a
/// compressed tar is decoded once. Folders and links are left out; the size cap is
/// `tk_archive_extract`'s, over the whole pass.
fn contents(
    path: &str,
    password: Option<&str>,
    only: Option<&str>,
    flags: u32,
    emit: &mut dyn FnMut(Entry, Vec<u8>) -> bool,
) -> Result<(), String> {
    let kind = detect_read(path)?;
    let mut pol = Policy::new(path, Path::new("."), only, flags)?;
    fn take(pol: &mut Policy, from: &mut dyn Read, size: u64, name: &str) -> Result<Vec<u8>, String> {
        pol.charge(size, name)?;
        let mut out = Vec::with_capacity(size.min(1 << 30) as usize);
        copy_capped(from, &mut out, size, name)?;
        Ok(out)
    }
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            for i in 0..z.len() {
                // Raw first: an entry not wanted needs no password.
                let name = {
                    let f = z.by_index_raw(i).msg()?;
                    if f.is_dir() || f.is_symlink() || !pol.wants(zip_name(&f)) {
                        continue;
                    }
                    zip_name(&f).to_string()
                };
                let mut f = match password {
                    Some(pw) => z.by_index_decrypt(i, pw.as_bytes()),
                    None => z.by_index(i),
                }
                .msg()?;
                let entry = Entry {
                    size: f.size(),
                    compressed: f.compressed_size(),
                    dir: false,
                    encrypted: f.encrypted(),
                    modified: zip_mtime(&f),
                    name,
                };
                let data = take(&mut pol, &mut f, entry.size, &entry.name)?;
                if !emit(entry, data) {
                    return Ok(());
                }
            }
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            let mut reader = sevenz_rust2::SevenZReader::open(path, pw).msg()?;
            let archive = reader.archive();
            let encrypted: Vec<bool> = (0..archive.files.len()).map(|i| sevenz_encrypted(archive, i)).collect();
            // The entries handed over are the archive's own, so their place says their index.
            let base = archive.files.as_ptr() as usize;
            let width = std::mem::size_of::<sevenz_rust2::SevenZArchiveEntry>();
            reader
                .for_each_entries(|e, r| {
                    if e.is_directory() || !pol.wants(e.name()) {
                        // A solid block is one stream: an entry not wanted is still read past.
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        return Ok(true);
                    }
                    let index = (e as *const _ as usize).wrapping_sub(base) / width;
                    let entry = Entry {
                        name: e.name().to_string(),
                        size: e.size(),
                        compressed: e.compressed_size,
                        dir: false,
                        encrypted: encrypted.get(index).copied().unwrap_or(false),
                        modified: e.has_last_modified_date.then(|| e.last_modified_date().to_unix_time_secs()),
                    };
                    let data = take(&mut pol, r, e.size(), e.name()).map_err(seven_err)?;
                    Ok(emit(entry, data))
                })
                .msg()?;
        }
        "rar" => {
            let mut a = rar(path, password).open_for_processing().msg()?;
            while let Some(h) = a.read_header().msg()? {
                let e = h.entry();
                let name = e.filename.to_string_lossy().to_string();
                if !e.is_file() || !pol.wants(&name) {
                    a = h.skip().msg()?;
                    continue;
                }
                pol.charge(e.unpacked_size, &name)?;
                let entry = Entry {
                    size: e.unpacked_size,
                    // As `list` says: unrar's header has no packed size.
                    compressed: e.unpacked_size,
                    dir: false,
                    encrypted: e.is_encrypted(),
                    modified: None,
                    name,
                };
                let (data, next) = h.read().msg()?;
                a = next;
                if !emit(entry, data) {
                    return Ok(());
                }
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            for e in t.entries().msg()? {
                let mut e = e.msg()?;
                let name = e.path().msg()?.to_string_lossy().to_string();
                if !e.header().entry_type().is_file() || !pol.wants(&name) {
                    continue;
                }
                let entry = Entry {
                    size: e.size(),
                    compressed: e.size(),
                    dir: false,
                    encrypted: false,
                    modified: e.header().mtime().ok().map(|m| m as i64),
                    name,
                };
                let data = take(&mut pol, &mut e, entry.size, &entry.name)?;
                if !emit(entry, data) {
                    return Ok(());
                }
            }
        }
    }
    Ok(())
}

/// [contents] with a panic told as an error, so the pass always ends with a word.
fn contents_caught(
    path: &str,
    password: Option<&str>,
    only: Option<&str>,
    flags: u32,
    emit: &mut dyn FnMut(Entry, Vec<u8>) -> bool,
) -> Result<(), String> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| contents(path, password, only, flags, emit))).unwrap_or_else(
        |p| {
            Err(match (p.downcast_ref::<&str>(), p.downcast_ref::<String>()) {
                (Some(s), _) => s.to_string(),
                (_, Some(s)) => s.clone(),
                _ => "native panic".to_string(),
            })
        },
    )
}

/// A file's header as the caller reads it: size, compressed size and modified time (`i64::MIN`
/// for none) as little-endian 64-bit numbers, a byte that is 1 when encrypted, then the name.
fn header(e: &Entry) -> Vec<u8> {
    let mut h = Vec::with_capacity(25 + e.name.len());
    h.extend_from_slice(&e.size.to_le_bytes());
    h.extend_from_slice(&e.compressed.to_le_bytes());
    h.extend_from_slice(&e.modified.unwrap_or(i64::MIN).to_le_bytes());
    h.push(u8::from(e.encrypted));
    h.extend_from_slice(e.name.as_bytes());
    h
}

/// Hears a pass: `code` 1 is a file (`head` and `data`), 0 the end, -1 a failure (`head` its
/// message). Each buffer is the caller's, freed with `tk_free`; nothing calls after 0 or -1.
pub type ContentsCb = Option<unsafe extern "C" fn(code: i32, head: *mut u8, head_len: usize, data: *mut u8, data_len: usize)>;

/// A pass over an archive's files on a thread of its own, one file ahead of the caller.
struct Contents {
    /// Pulled by `tk_archive_contents_next`; `None` when a listener hears the pass.
    files: Option<std::sync::mpsc::Receiver<Result<(Entry, Vec<u8>), String>>>,
    /// For a listener: one `()` per file the caller is ready for. Dropped, it stops the pass.
    more: Option<std::sync::mpsc::Sender<()>>,
}

/// Hands `head` and `data` to `cb` as allocations it owns.
unsafe fn tell(cb: unsafe extern "C" fn(i32, *mut u8, usize, *mut u8, usize), code: i32, head: Vec<u8>, data: Vec<u8>) {
    let (mut h, mut hl, mut d, mut dl) = (std::ptr::null_mut(), 0, std::ptr::null_mut(), 0);
    give(head, &mut h, &mut hl);
    give(data, &mut d, &mut dl);
    cb(code, h, hl, d, dl);
}

/// Starts reading the files of the archive at `path` (as `contents` does) on a thread of its
/// own, and returns the pass, or null with `tk_last_error` set. Without `listener` the caller
/// pulls each file with `tk_archive_contents_next`; with one, it asks for each with
/// `tk_archive_contents_more` and hears it there. `tk_archive_contents_free` ends the pass at
/// any time; a listener still hears its 0 after that.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_contents(
    path: *const u8,
    plen: usize,
    pw: *const u8,
    pwlen: usize,
    only: *const u8,
    olen: usize,
    flags: u32,
    listener: ContentsCb,
) -> *mut std::ffi::c_void {
    let mut out = std::ptr::null_mut();
    guard(|| {
        let path = text(path, plen)?.to_string();
        let password = opt_text(pw, pwlen)?.map(str::to_string);
        let only = opt_text(only, olen)?.map(str::to_string);
        let pass = match listener {
            None => {
                let (tx, rx) = std::sync::mpsc::sync_channel(1);
                std::thread::spawn(move || {
                    let mut emit = |e: Entry, d: Vec<u8>| tx.send(Ok((e, d))).is_ok();
                    if let Err(m) = contents_caught(&path, password.as_deref(), only.as_deref(), flags, &mut emit) {
                        let _ = tx.send(Err(m));
                    }
                });
                Contents { files: Some(rx), more: None }
            }
            Some(cb) => {
                let (more, asked) = std::sync::mpsc::channel::<()>();
                std::thread::spawn(move || {
                    let mut emit = |e: Entry, d: Vec<u8>| {
                        // Read ahead by one: this file waits here until the caller asks for it.
                        if asked.recv().is_err() {
                            return false;
                        }
                        unsafe { tell(cb, 1, header(&e), d) };
                        true
                    };
                    match contents_caught(&path, password.as_deref(), only.as_deref(), flags, &mut emit) {
                        Ok(()) => unsafe { tell(cb, 0, Vec::new(), Vec::new()) },
                        Err(m) => unsafe { tell(cb, -1, m.into_bytes(), Vec::new()) },
                    }
                });
                Contents { files: None, more: Some(more) }
            }
        };
        out = Box::into_raw(Box::new(pass)) as *mut std::ffi::c_void;
        Ok(0)
    });
    out
}

/// The next file of a pass `tk_archive_contents` started without a listener: 1 with its header
/// and bytes in `head` and `data` (the caller's, freed with `tk_free`), 0 at the end, -1 failed.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_contents_next(
    pass: *mut std::ffi::c_void,
    head: *mut *mut u8,
    head_len: *mut usize,
    data: *mut *mut u8,
    data_len: *mut usize,
) -> i32 {
    guard(|| {
        let files = live::<Contents>(pass)?.files.as_ref().ok_or("a pass with a listener is not pulled")?;
        match files.recv() {
            Ok(Ok((e, d))) => {
                give(header(&e), head, head_len);
                give(d, data, data_len);
                Ok(1)
            }
            Ok(Err(m)) => Err(m),
            Err(_) => Ok(0),
        }
    })
}

/// Asks a listener's pass for one more file.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_contents_more(pass: *mut std::ffi::c_void) {
    if let Ok(Contents { more: Some(more), .. }) = live::<Contents>(pass) {
        let _ = more.send(());
    }
}

/// Ends a pass and frees it: its thread stops at the next file.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_contents_free(pass: *mut std::ffi::c_void) {
    if !pass.is_null() {
        drop(Box::from_raw(pass as *mut Contents));
    }
}

// ---- create

enum ItemKind {
    File,
    Dir,
    Symlink(PathBuf),
}

/// What a walk keeps of an entry: a regular file, a directory or a link. A FIFO, socket or
/// device is `None`, as opening one would block or read a stream that never ends.
fn item_kind(ft: std::fs::FileType, path: &Path) -> Option<ItemKind> {
    if ft.is_dir() {
        Some(ItemKind::Dir)
    } else if ft.is_symlink() {
        std::fs::read_link(path).ok().map(ItemKind::Symlink)
    } else if ft.is_file() {
        Some(ItemKind::File)
    } else {
        None
    }
}

/// Files under `src` (or `src` itself) as (relative name, path, kind), sorted, without
/// `dest`: an archive written inside the tree it archives would otherwise contain itself.
/// `names`, NUL-separated and relative to `src` (empty ones skipped), are the entries to take
/// instead of everything below it: the caller's `only` and `ignore` already applied.
fn walk(src: &Path, dest: &Path, names: Option<&str>) -> Result<Vec<(String, PathBuf, ItemKind)>, String> {
    let mut out = Vec::new();
    // Followed: a link to a file is archived as that file, under the link's name.
    if let Ok(meta) = src.metadata() {
        if meta.is_file() {
            out.push((src.file_name().unwrap().to_string_lossy().to_string(), src.to_path_buf(), ItemKind::File));
            return Ok(out);
        }
    }
    // The destination's name relative to the source, when it lands inside it.
    // A bare file name's parent is "", which `canonicalize` refuses: it is the working directory.
    let parent = dest.parent().map(|p| if p.as_os_str().is_empty() { Path::new(".") } else { p });
    let own = match (canonicalize_safe(src), parent.and_then(|p| canonicalize_safe(p).ok())) {
        (Ok(s), Some(d)) => dest.file_name().and_then(|n| d.join(n).strip_prefix(&s).ok().map(|r| r.to_path_buf())),
        _ => None,
    };
    if let Some(names) = names {
        let mut picked: Vec<String> = names.split('\0').filter(|n| !n.is_empty()).map(|n| n.replace('\\', "/")).collect();
        // Sorted, so a folder comes before what is in it, as in the walk below.
        picked.sort_unstable();
        picked.dedup();
        for rel in picked {
            let path = src.join(&rel);
            if own.as_deref() == Some(Path::new(&rel)) {
                continue;
            }
            let Some(kind) = path.symlink_metadata().ok().and_then(|m| item_kind(m.file_type(), &path)) else {
                continue;
            };
            out.push((rel, path, kind));
        }
        return Ok(out);
    }
    for entry in walkdir::WalkDir::new(src).min_depth(1).follow_links(false).sort_by_file_name() {
        let entry = entry.msg()?;
        let relative = entry.path().strip_prefix(src).msg()?;
        if own.as_deref() == Some(relative) {
            continue;
        }
        let rel = relative.to_string_lossy().replace('\\', "/");
        let Some(kind) = item_kind(entry.file_type(), entry.path()) else { continue };
        out.push((rel, entry.path().to_path_buf(), kind));
    }
    Ok(out)
}

fn create(
    format: u32,
    src: &str,
    dest: &str,
    out: &str,
    password: Option<&str>,
    names: Option<&str>,
    level: i32,
    progress: ProgressCb,
) -> Result<i32, String> {
    // Refused before anything is touched: the destination's folder is not created for nothing.
    match format {
        RAR => return Err(format!("{}: rar can only be read; write .zip or .7z instead", dest)),
        TAR..=TAR_BZ2 if password.is_some() => {
            return Err(format!("{}: tar has no encryption; write .zip or .7z for a password", dest))
        }
        ZIP | SEVENZ | TAR..=TAR_BZ2 => {}
        _ => return Err(format!("unknown archive format {}", format)),
    }
    validate_archive_level(format, level)?;
    let src_path = Path::new(src);
    if let Some(p) = Path::new(out).parent() {
        std::fs::create_dir_all(p).msg()?;
    }
    let items = walk(src_path, Path::new(dest), names)?;
    let files = items.iter().filter(|i| !matches!(i.2, ItemKind::Dir)).count() as i32;
    let total_items = items.len() as u64;
    let total_bytes: u64 = items
        .iter()
        .filter(|i| matches!(i.2, ItemKind::File))
        .filter_map(|i| i.1.metadata().ok())
        .map(|m| m.len())
        .sum();

    unsafe {
        report_progress(progress, 0, total_items, 0, total_bytes, "")?;
    }

    let mut completed: u64 = 0;
    let mut bytes_done: u64 = 0;

    match format {
        ZIP => {
            let mut w = zip::ZipWriter::new(BufWriter::new(create_file(out)?));
            for (name, path, kind) in &items {
                let method = if level == 0 {
                    zip::CompressionMethod::Stored
                } else {
                    zip::CompressionMethod::Deflated
                };
                let mut opts = zip::write::SimpleFileOptions::default()
                    .compression_method(method)
                    .compression_level(if level <= 0 { None } else { Some(level as i64) })
                    .large_file(true);
                if let Ok(meta) = path.symlink_metadata() {
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        opts = opts.unix_permissions(meta.permissions().mode());
                    }
                    let secs = meta.modified().ok().and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok());
                    if let Some(t) = secs.and_then(|d| unix_to_zip(d.as_secs() as i64)) {
                        opts = opts.last_modified_time(t);
                    }
                }
                if let Some(pw) = password {
                    opts = opts.with_aes_encryption(zip::AesMode::Aes256, pw);
                }
                unsafe {
                    report_progress(progress, completed, total_items, bytes_done, total_bytes, name)?;
                }
                match kind {
                    ItemKind::Dir => {
                        w.add_directory(name, opts).msg()?;
                    }
                    ItemKind::Symlink(target) => {
                        w.add_symlink(name, target.to_string_lossy(), opts).msg()?;
                    }
                    ItemKind::File => {
                        w.start_file(name, opts).msg()?;
                        let file = read_file(path.to_str().ok_or("bad path")?)?;
                        let flen = file.metadata().map_or(0, |m| m.len());
                        pump(Watched(BufReader::new(file)), &mut w)?;
                        bytes_done += flen;
                    }
                }
                completed += 1;
                unsafe {
                    report_progress(progress, completed, total_items, bytes_done, total_bytes, name)?;
                }
            }
            // The central directory is still buffered; dropping the writer would swallow its error.
            w.finish().msg()?.flush().msg()?;
        }
        SEVENZ => {
            // Our own walk, as for zip and tar: the crate's runs after the destination exists
            // and would archive it into itself.
            let mut z = sevenz_rust2::SevenZWriter::new(create_file(out)?).msg()?;
            let lvl = if level < 0 { 6 } else { level as u32 };
            let lzma2_cfg: sevenz_rust2::SevenZMethodConfiguration =
                sevenz_rust2::SevenZMethodConfiguration::new(sevenz_rust2::SevenZMethod::LZMA2)
                    .with_options(sevenz_rust2::MethodOptions::LZMA2(sevenz_rust2::lzma::LZMA2Options::with_preset(lvl)));
            if let Some(pw) = password {
                z.set_content_methods(vec![
                    sevenz_rust2::AesEncoderOptions::new(sevenz_rust2::Password::from(pw)).into(),
                    lzma2_cfg,
                ]);
            } else {
                z.set_content_methods(vec![lzma2_cfg]);
            }
            for (name, path, kind) in &items {
                if matches!(kind, ItemKind::Symlink(_)) {
                    completed += 1;
                    continue;
                }
                unsafe {
                    report_progress(progress, completed, total_items, bytes_done, total_bytes, name)?;
                }
                #[allow(unused_mut)]
                let mut entry = sevenz_rust2::SevenZArchiveEntry::from_path(path, name.clone());
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    if let Ok(meta) = path.symlink_metadata() {
                        let mode = meta.permissions().mode();
                        entry.has_windows_attributes = true;
                        entry.windows_attributes = 0x8000 | (mode << 16);
                    }
                }
                let flen = if matches!(kind, ItemKind::File) {
                    path.metadata().map_or(0, |m| m.len())
                } else {
                    0
                };
                let reader = if matches!(kind, ItemKind::Dir) {
                    None
                } else {
                    Some(Watched(BufReader::new(read_file(path.to_str().ok_or("bad path")?)?)))
                };
                z.push_archive_entry(entry, reader).msg()?;
                bytes_done += flen;
                completed += 1;
                unsafe {
                    report_progress(progress, completed, total_items, bytes_done, total_bytes, name)?;
                }
            }
            z.finish().msg()?;
        }
        TAR | TAR_GZ | TAR_XZ | TAR_ZST | TAR_BZ2 => {
            let size = total_bytes;
            let codec = match format {
                TAR_GZ => Some(GZIP),
                TAR_XZ => Some(XZ),
                TAR_ZST => Some(ZSTD),
                TAR_BZ2 => Some(BZIP2),
                _ => None,
            };
            let mut b = tar::Builder::new(encoder(codec, BufWriter::new(create_file(out)?), level, size)?);
            b.follow_symlinks(false);
            for (name, path, kind) in &items {
                unsafe {
                    report_progress(progress, completed, total_items, bytes_done, total_bytes, name)?;
                }
                let flen = if matches!(kind, ItemKind::File) {
                    path.metadata().map_or(0, |m| m.len())
                } else {
                    0
                };
                match kind {
                    ItemKind::Dir => {
                        b.append_dir(name, path).msg()?;
                    }
                    // Read through a watch, so one large file stops part way.
                    ItemKind::File => {
                        let file = read_file(path.to_str().ok_or("bad path")?)?;
                        let mut header = tar::Header::new_gnu();
                        header.set_metadata(&file.metadata().msg()?);
                        b.append_data(&mut header, name, Watched(BufReader::new(file))).msg()?;
                    }
                    ItemKind::Symlink(_) => {
                        b.append_path_with_name(path, name).msg()?;
                    }
                }
                bytes_done += flen;
                completed += 1;
                unsafe {
                    report_progress(progress, completed, total_items, bytes_done, total_bytes, name)?;
                }
            }
            b.into_inner().msg()?.finish().msg()?.flush().msg()?;
        }
        _ => unreachable!(),
    }
    unsafe {
        report_progress(progress, total_items, total_items, total_bytes, total_bytes, "")?;
    }
    Ok(files)
}

/// Archives `src` (a file or directory) for `dest`, written to `out` (a file beside it the
/// caller renames over it, so `dest` is never cut short); returns the number of files added.
/// `dest` is left out of the archive when it is inside `src`. `names`, when not null, are the
/// entries under `src` to take, NUL-separated, as `walk` reads them. `progress` may be null;
/// `stop`, when not null, is a byte that stops the call once set.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_create(
    format: u32,
    src: *const u8,
    slen: usize,
    dest: *const u8,
    dlen: usize,
    out: *const u8,
    olen: usize,
    pw: *const u8,
    pwlen: usize,
    names: *const u8,
    nlen: usize,
    level: i32,
    progress: ProgressCb,
    stop: *const u8,
) -> i32 {
    let _watch = watch(stop);
    guard(|| {
        let names = opt_text(names, nlen)?;
        let (dest, out) = (text(dest, dlen)?, text(out, olen)?);
        create(format, text(src, slen)?, dest, out, opt_text(pw, pwlen)?, names, level, progress)
    })
}

// ---- single streams

/// Compresses the file at `src` into `dest` as one `codec` stream. `progress` may be null;
/// `stop`, when not null, is a byte that stops the call once set.
#[no_mangle]
pub unsafe extern "C" fn tk_compress(
    codec: u32,
    src: *const u8,
    slen: usize,
    dest: *const u8,
    dlen: usize,
    level: i32,
    progress: ProgressCb,
    stop: *const u8,
) -> i32 {
    let _watch = watch(stop);
    guard(|| {
        validate_codec_level(codec, level)?;
        let src_str = text(src, slen)?;
        let file = read_file(src_str)?;
        let total_size = file.metadata().map_or(0, |m| m.len());
        report_progress(progress, 0, 1, 0, total_size, src_str)?;
        let mut input = BufReader::new(Watched(file));
        let out = BufWriter::new(create_file(text(dest, dlen)?)?);
        let mut enc = encoder(Some(codec), out, level, total_size)?;
        let mut done = 0u64;
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = input.read(&mut buf).msg()?;
            if n == 0 {
                break;
            }
            enc.write_all(&buf[..n]).msg()?;
            done += n as u64;
            report_progress(progress, 0, 1, done, total_size, src_str)?;
        }
        enc.finish().msg()?.flush().msg()?;
        report_progress(progress, 1, 1, total_size, total_size, src_str)?;
        Ok(0)
    })
}

fn decompress(codec: u32, path: &str, dest: &str, flags: u32, progress: ProgressCb) -> Result<i32, String> {
    let codec = if codec == DETECT {
        sniff_codec(path).ok_or_else(|| format!("{}: not a gzip, xz, zstd or bzip2 stream", path))?
    } else {
        codec
    };
    let total_size = std::fs::metadata(path).map_or(0, |m| m.len());
    unsafe { report_progress(progress, 0, 1, 0, total_size, path)?; }
    let pol = Policy::new(path, Path::new("."), None, flags)?;
    // Progress is in compressed bytes read, the unit the file's size is in.
    let read = std::rc::Rc::new(std::cell::Cell::new(0u64));
    let input = BufReader::new(Counted { inner: Watched(read_file(path)?), read: read.clone() });
    let mut decoder: Box<dyn Read> = match codec {
        GZIP => Box::new(flate2::read::MultiGzDecoder::new(input)),
        XZ => Box::new(xz2::read::XzDecoder::new_multi_decoder(input)),
        ZSTD => Box::new(zstd::stream::read::Decoder::new(input).msg()?),
        BZIP2 => Box::new(bzip2::read::MultiBzDecoder::new(input)),
        _ => return Err(format!("unknown codec {}", codec)),
    };
    let mut out = BufWriter::new(create_file(dest)?);
    let mut done = 0u64;
    let mut buf = [0u8; 64 * 1024];
    let limit = pol.limit.saturating_add(1);
    let mut err = None;
    loop {
        let max_read = (limit.saturating_sub(done)).min(buf.len() as u64) as usize;
        if max_read == 0 {
            err = Some(format!(
                "{}: decompresses to more than {} bytes, {}× the file and at least 1 GiB; unarchive with unsafe: true if that is expected",
                path, pol.limit, RATIO
            ));
            break;
        }
        let n = match decoder.read(&mut buf[..max_read]) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                err = Some(e.to_string());
                break;
            }
        };
        if let Err(e) = out.write_all(&buf[..n]) {
            err = Some(e.to_string());
            break;
        }
        done += n as u64;
        if let Err(e) = unsafe { report_progress(progress, 0, 1, read.get(), total_size, path) } {
            err = Some(e);
            break;
        }
    }
    if err.is_none() {
        if let Err(e) = out.flush() {
            err = Some(e.to_string());
        }
    }
    if let Some(e) = err {
        drop(out);
        let _ = std::fs::remove_file(dest);
        return Err(e);
    }
    unsafe { report_progress(progress, 1, 1, total_size, total_size, path)?; }
    Ok(0)
}

/// A reader that counts the bytes read through it into `read`.
struct Counted<R> {
    inner: R,
    read: std::rc::Rc<std::cell::Cell<u64>>,
}

impl<R: Read> Read for Counted<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.read.set(self.read.get() + n as u64);
        Ok(n)
    }
}

/// Decompresses the single stream at `src` into `dest`; `codec` `DETECT` reads the magic
/// number. `flags` is `TRUSTED`; otherwise the output is capped as `tk_archive_extract`'s is,
/// and a stream that passes the cap leaves no file behind. `progress` may be null; `stop`, when
/// not null, is a byte that stops the call once set.
#[no_mangle]
pub unsafe extern "C" fn tk_decompress(
    codec: u32,
    src: *const u8,
    slen: usize,
    dest: *const u8,
    dlen: usize,
    flags: u32,
    progress: ProgressCb,
    stop: *const u8,
) -> i32 {
    let _watch = watch(stop);
    guard(|| decompress(codec, text(src, slen)?, text(dest, dlen)?, flags, progress))
}

#[cfg(test)]
mod tests {
    use super::unverbatim;

    #[test]
    fn a_verbatim_path_reads_as_windows_spells_it() {
        assert_eq!(unverbatim(r"\\?\C:\a\b").as_deref(), Some(r"C:\a\b"));
        assert_eq!(unverbatim(r"\\?\UNC\srv\share\x").as_deref(), Some(r"\\srv\share\x"));
        assert_eq!(unverbatim(r"C:\a"), None);
        assert_eq!(unverbatim(r"\\srv\share"), None);
    }
}
