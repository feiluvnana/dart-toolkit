//! Archives and compressed streams, rewritten for native2.
//!
//! Fresh implementation of the archive interface: same FFI names, signatures, codes and
//! record layout as legacy, differential-tested against it. By file path — the filesystem
//! is the transport. Handles zip/7z/rar/tar/tar.gz/tar.xz/tar.zst/tar.bz2 plus the gzip,
//! xz, zstd and bzip2 streams, with passwords, glob filtering, sandbox policies, progress
//! and stop bytes. Adds the streaming stepper (`tk_archive_open/next/entry_read/free`)
//! and the in-memory packer (`tk_archive_pack_create/add/finish`) behind the same surface.

use crate::handover::{OWNED, own};
use crate::{bytes, bytes_mut, create_file, give, guard, live, opt_text, pump, read_file, stopped, text, watch, Handle, Watched};
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

/// Container formats for `tk_archive_create` / `tk_archive_pack_create`.
const ZIP: u32 = 0;
const SEVENZ: u32 = 1;
const TAR: u32 = 2;
const TAR_GZ: u32 = 3;
const TAR_XZ: u32 = 4;
const TAR_ZST: u32 = 5;
const TAR_BZ2: u32 = 6;
/// Read-only; creation refuses it by name.
const RAR: u32 = 7;

/// Stream codecs for `tk_compress` / `tk_decompress`.
const GZIP: u32 = 0;
const XZ: u32 = 1;
const ZSTD: u32 = 2;
const BZIP2: u32 = 3;
/// `tk_decompress` codec meaning "read the file's magic number".
const DETECT: u32 = u32::MAX;

/// Flags for `extract` / `read` / `contents` / `decompress`.
const TRUSTED: u32 = 1;
const FOLD_CASE: u32 = 2;

/// An untrusted archive may write at most this many times its size...
const RATIO: u64 = 200;
/// ...and at least this much.
const FLOOR: u64 = 1 << 30;

pub type ProgressCb = Option<unsafe extern "C" fn(
    completed: u64,
    total: u64,
    bytes: u64,
    bytes_total: u64,
    name: *const u8,
    name_len: usize,
)>;

pub type ContentsCb = Option<unsafe extern "C" fn(code: i32, head: *mut u8, head_len: usize, data: *mut u8, data_len: usize)>;

/// Tells `cb` how far the call is, then fails once the caller has stopped it.
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
/// `\\?\UNC\srv\share\x` is `\\srv\share\x`.
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

/// Canonicalizes, tolerating missing trailing components: ascends to the first existing
/// ancestor, canonicalizes that, and re-appends the missing suffix.
fn canonicalize_safe(p: &Path) -> std::io::Result<PathBuf> {
    match std::fs::canonicalize(p) {
        Ok(c) => Ok(strip_unc(&c)),
        Err(_) => {
            let mut missing = Vec::new();
            let mut at = p;
            loop {
                match std::fs::canonicalize(at) {
                    Ok(c) => {
                        let mut out = strip_unc(&c);
                        for part in missing.iter().rev() {
                            out.push(part);
                        }
                        return Ok(out);
                    }
                    Err(_) => match at.parent() {
                        Some(parent) if parent != at => {
                            if let Some(name) = at.file_name() {
                                missing.push(name.to_os_string());
                            }
                            at = parent;
                        }
                        _ => return Ok(strip_unc(p)),
                    },
                }
            }
        }
    }
}

fn path_starts_with(child: &Path, parent: &Path) -> bool {
    let (Ok(c), Ok(p)) = (canonicalize_safe(child), canonicalize_safe(parent)) else {
        return false;
    };
    #[cfg(windows)]
    {
        // By component on lowercased forms, so `C:\out-evil` is not inside `C:\out`.
        let lower = |p: PathBuf| p.to_string_lossy().to_lowercase();
        let (c, p) = (lower(c), lower(p));
        c == p || c.starts_with(&format!("{}\\", p.trim_end_matches('\\')))
    }
    #[cfg(not(windows))]
    {
        c.starts_with(p)
    }
}

/// Joins `name` under `root`, refusing absolute members, `..` escapes and prefixes.
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

/// An entry name as the caller writes it: `/`-separated, no leading `./`.
fn plain(name: &str) -> String {
    name.replace('\\', "/").trim_start_matches("./").to_string()
}

/// The sandbox policy of one call: budget, glob, link tracking.
struct Policy {
    trusted: bool,
    limit: u64,
    budget: u64,
    only: Option<String>,
    fold: bool,
    root: PathBuf,
    links: Vec<PathBuf>,
    checked: std::collections::HashSet<PathBuf>,
}

impl Policy {
    fn new(path: &str, root: &Path, only: Option<&str>, flags: u32) -> Result<Policy, String> {
        let trusted = flags & TRUSTED != 0;
        let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
        let limit = if trusted { u64::MAX } else { FLOOR.max(size.saturating_mul(RATIO)) };
        let root = canonicalize_safe(root).map_err(|e| format!("{}: {}", root.display(), e))?;
        Ok(Policy {
            trusted,
            limit,
            budget: limit,
            only: only.map(str::to_string),
            fold: flags & FOLD_CASE != 0,
            root,
            links: Vec::new(),
            checked: std::collections::HashSet::new(),
        })
    }

    /// Charges `size` bytes against the budget.
    fn charge(&mut self, size: u64, name: &str) -> Result<(), String> {
        if size > self.budget {
            return Err(format!(
                "{}: extracting it would write more than {} bytes, 200× the archive and at least 1 GiB; unarchive with unsafe: true if that is expected",
                name, self.limit
            ));
        }
        self.budget -= size;
        Ok(())
    }

    /// Whether `name` passes the `only` glob (or there is none).
    fn wants(&self, name: &str) -> bool {
        let Some(pattern) = self.only.as_deref() else {
            return true;
        };
        let mut name = name.replace('\\', "/");
        while let Some(rest) = name.strip_prefix("./") {
            name = rest.to_string();
        }
        name = name.trim_end_matches('/').to_string();
        match_glob(pattern, &name, self.fold)
    }

    /// Whether `dir` is safe to create under: inside the root, through no escaping link.
    /// Asked of every parent directory, so a pre-planted link is caught.
    fn contains(&mut self, dir: &Path) -> Result<(), String> {
        if self.trusted || self.checked.contains(dir) {
            return Ok(());
        }
        match resolve_link(dir, 0) {
            Some(real) if path_starts_with(&real, &self.root) => {
                self.checked.insert(dir.to_path_buf());
                Ok(())
            }
            _ => Err(format!("{}: reached through a link that leaves the destination", dir.display())),
        }
    }

    /// Records a symlink at `at` pointing at `target`, refused when it escapes.
    fn link(&mut self, at: &Path, name: &str, target: &str) -> Result<(), String> {
        if !self.trusted {
            escapes(name, target)?;
        }
        if let Some(parent) = at.parent() {
            self.contains(parent)?;
        }
        if at.symlink_metadata().is_ok() {
            std::fs::remove_file(at).map_err(|e| format!("{}: {}", at.display(), e))?;
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(target, at).map_err(|e| format!("{}: {}", at.display(), e))?;
        #[cfg(not(unix))]
        std::fs::write(at, target).map_err(|e| format!("{}: {}", at.display(), e))?;
        self.links.push(at.to_path_buf());
        self.checked.clear();
        Ok(())
    }

    /// After the pass: every recorded link must still resolve inside the root. Catches
    /// `b/..` time-of-check tricks and dangling links (followed as far as they go).
    fn finish(&mut self) -> Result<(), String> {
        if self.trusted {
            return Ok(());
        }
        for link in std::mem::take(&mut self.links) {
            match resolve_link(&link, 0) {
                Some(real) if path_starts_with(&real, &self.root) => {}
                _ => {
                    let _ = std::fs::remove_file(&link);
                    return Err(format!("{}: link leads out of the destination", link.display()));
                }
            }
        }
        Ok(())
    }
}

/// Follows `path` as far as it goes (dangling-aware, unlike `canonicalize`); `None` on a loop.
fn resolve_link(path: &Path, hops: u32) -> Option<PathBuf> {
    if hops >= 40 {
        return None;
    }
    let abs = if path.is_absolute() { path.to_path_buf() } else {
        std::env::current_dir().ok()?.join(path)
    };
    let mut out = PathBuf::new();
    for part in abs.components() {
        match part {
            std::path::Component::Prefix(p) => out.push(p.as_os_str()),
            std::path::Component::RootDir => out.push(part.as_os_str()),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::Normal(_) => {
                out.push(part.as_os_str());
                if let Ok(meta) = std::fs::symlink_metadata(&out) {
                    if meta.file_type().is_symlink() {
                        let target = std::fs::read_link(&out).ok()?;
                        out.pop();
                        let base = out.clone();
                        for tpart in Path::new(&target).components() {
                            match tpart {
                                std::path::Component::Prefix(p) => {
                                    out = PathBuf::from(p.as_os_str());
                                }
                                std::path::Component::RootDir => {
                                    out = PathBuf::from(tpart.as_os_str());
                                }
                                std::path::Component::CurDir => {}
                                std::path::Component::ParentDir => {
                                    out.pop();
                                }
                                std::path::Component::Normal(_) => out.push(tpart.as_os_str()),
                            }
                        }
                        // A relative link target resolves against its own directory.
                        let _ = base;
                        if hops + 1 >= 40 {
                            return None;
                        }
                        return resolve_link(&out, hops + 1);
                    }
                }
            }
        }
    }
    Some(out)
}

/// Whether the link `name -> target` escapes: absolute targets and `..` past the member's
/// own directory are refused.
fn escapes(name: &str, target: &str) -> Result<(), String> {
    let refuse = || format!("{}: link to {} leads out of the destination", name, target);
    if target.starts_with('/') || target.starts_with('\\') || Path::new(target).is_absolute() {
        return Err(refuse());
    }
    let depth = Path::new(name).parent().map(|p| p.components().filter(|c| matches!(c, std::path::Component::Normal(_))).count()).unwrap_or(0) as i64;
    let mut at = depth;
    for part in Path::new(target).components() {
        match part {
            std::path::Component::Normal(_) => at += 1,
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                at -= 1;
                if at < 0 {
                    return Err(refuse());
                }
            }
            _ => return Err(refuse()),
        }
    }
    Ok(())
}

/// The `only` glob: `*`/`?` within one segment, `**` across segments (`**/` = zero or more
/// folders), `[...]` classes (never spanning `/`), `{a,b}` alternates, `\` escapes.
fn match_glob(pattern: &str, name: &str, fold: bool) -> bool {
    fn fold_char(c: char, fold: bool) -> char {
        if fold { c.to_ascii_lowercase() } else { c }
    }
    fn run(p: &[char], n: &[char], fold: bool) -> bool {
        if p.is_empty() {
            return n.is_empty();
        }
        match p[0] {
            '*' if p.get(1) == Some(&'*') => {
                // `**/` spans zero or more folders; bare `**` spans anything.
                let rest = if p.get(2) == Some(&'/') { &p[3..] } else { &p[2..] };
                if run(rest, n, fold) {
                    return true;
                }
                let mut i = 0;
                while i < n.len() {
                    if p.get(2) == Some(&'/') {
                        // Must consume whole segments.
                        while i < n.len() && n[i] != '/' {
                            i += 1;
                        }
                        if i < n.len() {
                            i += 1;
                        } else {
                            break;
                        }
                    } else {
                        i += 1;
                    }
                    if run(rest, &n[i..], fold) {
                        return true;
                    }
                }
                false
            }
            '*' => {
                let mut i = 0;
                loop {
                    if run(&p[1..], &n[i..], fold) {
                        return true;
                    }
                    if i >= n.len() || n[i] == '/' {
                        return false;
                    }
                    i += 1;
                }
            }
            '?' => !n.is_empty() && n[0] != '/' && run(&p[1..], &n[1..], fold),
            '\\' if p.len() > 1 => !n.is_empty() && fold_char(p[1], fold) == fold_char(n[0], fold) && run(&p[2..], &n[1..], fold),
            '[' => {
                let mut i = 1;
                let mut negated = false;
                if p.get(i) == Some(&'!') || p.get(i) == Some(&'^') {
                    negated = true;
                    i += 1;
                }
                // A `]` first is a literal member of the set.
                let mut set = Vec::new();
                if p.get(i) == Some(&']') {
                    set.push(']');
                    i += 1;
                }
                let mut closed = false;
                while i < p.len() {
                    if p[i] == ']' {
                        closed = true;
                        i += 1;
                        break;
                    }
                    if p[i] == '\\' && i + 1 < p.len() {
                        set.push(p[i + 1]);
                        i += 2;
                        continue;
                    }
                    if i + 2 < p.len() && p[i + 1] == '-' && p[i + 2] != ']' {
                        let (mut a, mut b) = (p[i] as u32, p[i + 2] as u32);
                        if a > b {
                            std::mem::swap(&mut a, &mut b);
                        }
                        for c in a..=b {
                            set.push(char::from_u32(c).unwrap_or('?'));
                        }
                        i += 3;
                        continue;
                    }
                    set.push(p[i]);
                    i += 1;
                }
                if !closed || n.is_empty() || n[0] == '/' {
                    return false;
                }
                let hit = set.iter().any(|&c| fold_char(c, fold) == fold_char(n[0], fold));
                (hit != negated) && run(&p[i..], &n[1..], fold)
            }
            '{' => {
                // Find the closing brace honoring nesting; a lone `{` is literal.
                let mut depth = 0;
                let mut end = None;
                let mut comma = false;
                let mut i = 0;
                while i < p.len() {
                    match p[i] {
                        '\\' => i += 1,
                        '{' => depth += 1,
                        ',' if depth == 1 => comma = true,
                        '}' => {
                            depth -= 1;
                            if depth == 0 {
                                end = Some(i);
                                break;
                            }
                        }
                        _ => {}
                    }
                    i += 1;
                }
                let Some(end) = end.filter(|_| comma) else {
                    return !n.is_empty() && fold_char('{', fold) == fold_char(n[0], fold) && run(&p[1..], &n[1..], fold);
                };
                // Split the inside at depth-1 commas; each alternative replaces the group.
                let mut alts = Vec::new();
                let (mut d, mut start) = (0, 1);
                let mut i = 1;
                while i <= end {
                    match p[i] {
                        '\\' => i += 1,
                        '{' => d += 1,
                        ',' if d == 0 => {
                            alts.push(&p[start..i]);
                            start = i + 1;
                        }
                        '}' if d == 0 => {
                            alts.push(&p[start..i]);
                            break;
                        }
                        '}' => d -= 1,
                        _ => {}
                    }
                    i += 1;
                }
                alts.iter().any(|alt| {
                    let mut joined = alt.to_vec();
                    joined.extend_from_slice(&p[end + 1..]);
                    run(&joined, n, fold)
                })
            }
            c => !n.is_empty() && fold_char(c, fold) == fold_char(n[0], fold) && run(&p[1..], &n[1..], fold),
        }
    }
    let p: Vec<char> = pattern.chars().collect();
    let n: Vec<char> = name.chars().collect();
    run(&p, &n, fold)
}

/// One archive member's metadata.
struct Entry {
    name: String,
    size: u64,
    compressed: u64,
    dir: bool,
    encrypted: bool,
    link: bool,
    modified: Option<i64>,
}

/// One entry as the caller reads it: size, compressed size and modified time (`i64::MIN`
/// for none) as little-endian 64-bit numbers, a flag byte (1 encrypted, 2 folder), the
/// name length as little-endian u32, then the name.
fn record(e: &Entry, out: &mut Vec<u8>) {
    out.extend_from_slice(&e.size.to_le_bytes());
    out.extend_from_slice(&e.compressed.to_le_bytes());
    out.extend_from_slice(&e.modified.unwrap_or(i64::MIN).to_le_bytes());
    out.push(u8::from(e.encrypted) | (u8::from(e.dir) << 1) | (u8::from(e.link) << 2));
    out.extend_from_slice(&(e.name.len() as u32).to_le_bytes());
    out.extend_from_slice(e.name.as_bytes());
}

// ---- detection

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

/// The format `path`'s name says.
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

/// The format of `path`, read from its content, else from its name: 1 zip, 2 7z, 3 tar,
/// 4 tar.gz, 5 tar.xz, 6 tar.zst, 7 tar.bz2, 8 rar, 9 gzip, 10 xz, 11 zstd, 12 bzip2, 0 none. A
/// compressed stream's first 512 bytes are decoded to look for a tar's `ustar` magic, so a
/// misnamed tarball needs no listing to tell.
fn format_code(path: &str) -> i32 {
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
        let Ok(file) = File::open(path) else {
            return single;
        };
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
        return if block.len() >= 262 && &block[257..262] == b"ustar" {
            4 + codec as i32
        } else {
            single
        };
    }
    detect(path).map_or(0, by_name)
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

/// [format] of the file at `src`.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_format(src: *const u8, slen: usize) -> i32 {
    guard(|| Ok(format_code(text(src, slen)?)))
}

// ---- open helpers

fn zip_open(path: &str) -> Result<zip::ZipArchive<Watched<File>>, String> {
    zip::ZipArchive::new(Watched(read_file(path)?)).map_err(|e| e.to_string())
}

/// A zip entry's name: its raw bytes as UTF-8 when they are UTF-8 (flagged or not,
/// as Info-ZIP, 7-Zip and many Windows and Linux tools write UTF-8 without the flag),
/// else decoded as CP437, the zip standard's charset.
fn zip_name(f: &zip::read::ZipFile) -> String {
    let raw = f.name_raw();
    if let Ok(s) = std::str::from_utf8(raw) {
        return s.to_string();
    }
    raw.iter().map(|&b| cp437(b)).collect()
}

/// One byte as CP437 (the zip filename charset) to its Unicode character.
fn cp437(b: u8) -> char {
    const TABLE: [char; 128] = [
        'Ç', 'ü', 'é', 'â', 'ä', 'à', 'å', 'ç', 'ê', 'ë', 'è', 'ï', 'î', 'ì', 'Ä', 'Å',
        'É', 'æ', 'Æ', 'ô', 'ö', 'ò', 'û', 'ù', 'ÿ', 'Ö', 'Ü', '¢', '£', '¥', '₧', 'ƒ',
        'á', 'í', 'ó', 'ú', 'ñ', 'Ñ', 'ª', 'º', '¿', '⌐', '¬', '½', '¼', '¡', '«', '»',
        '░', '▒', '▓', '│', '┤', '╡', '╢', '╖', '╕', '╣', '║', '╗', '╝', '╜', '╛', '┐',
        '└', '┴', '┬', '├', '─', '┼', '╞', '╟', '╚', '╔', '╩', '╦', '╠', '═', '╬', '╧',
        '╨', '╤', '╥', '╙', '╘', '╒', '╓', '╫', '╪', '┘', '┌', '█', '▄', '▌', '▐', '▀',
        'α', 'ß', 'Γ', 'π', 'Σ', 'σ', 'µ', 'τ', 'Φ', 'Θ', 'Ω', 'δ', '∞', 'φ', 'ε', '∩',
        '≡', '±', '≥', '≤', '⌠', '⌡', '÷', '≈', '°', '∙', '·', '√', 'ⁿ', '²', '■', ' ',
    ];
    if b < 0x80 {
        b as char
    } else {
        TABLE[(b - 0x80) as usize]
    }
}

/// A zip `DateTime` as Unix seconds in wall-clock time.
fn zip_mtime(f: &zip::read::ZipFile) -> Option<i64> {
    let dt = f.last_modified()?;
    time::OffsetDateTime::from_unix_timestamp(0).ok()?;
    // Rebuilt as UTC wall-clock: the stamp carries no zone.
    let date = time::Date::from_calendar_date(dt.year() as i32, time::Month::try_from(dt.month()).ok()?, dt.day()).ok()?;
    let time = time::Time::from_hms(dt.hour(), dt.minute(), dt.second()).ok()?;
    Some(time::PrimitiveDateTime::new(date, time).assume_utc().unix_timestamp())
}

fn unix_to_zip(secs: i64) -> Option<zip::DateTime> {
    let dt = time::OffsetDateTime::from_unix_timestamp(secs).ok()?;
    zip::DateTime::from_date_and_time(dt.year() as u16, dt.month() as u8, dt.day(), dt.hour(), dt.minute(), dt.second()).ok()
}

/// sevenz errors as messages; generic so `map_err` fits String errors too.
fn seven_err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// String errors as sevenz errors, for inside `for_each_entries` closures.
fn seven_other(m: String) -> sevenz_rust2::Error {
    sevenz_rust2::Error::Other(m.into())
}

fn sevenz_link(e: &sevenz_rust2::SevenZArchiveEntry) -> bool {
    e.has_windows_attributes && e.windows_attributes & 0x8000 != 0 && (e.windows_attributes >> 16) & 0o170000 == 0o120000
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

fn rar<'a>(path: &'a str, password: Option<&'a str>) -> unrar::Archive<'a> {
    match password {
        Some(pw) => unrar::Archive::with_password(path, pw),
        None => unrar::Archive::new(path),
    }
}

/// The tar stream at `path` of container `kind`: plain or decoded.
fn tar_reader(path: &str, kind: &str) -> Result<Box<dyn Read>, String> {
    let f = read_file(path)?;
    Ok(match kind {
        "tar" => Box::new(f),
        "tar.gz" => Box::new(flate2::read::MultiGzDecoder::new(f)),
        "tar.xz" => Box::new(xz2::read::XzDecoder::new_multi_decoder(f)),
        "tar.zst" => Box::new(zstd::stream::read::Decoder::new(f).map_err(|e| e.to_string())?),
        _ => Box::new(bzip2::read::MultiBzDecoder::new(f)),
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
                let f = z.by_index_raw(i).map_err(|e| e.to_string())?;
                out.push(Entry {
                    name: zip_name(&f),
                    size: f.size(),
                    compressed: f.compressed_size(),
                    dir: f.is_dir(),
                    encrypted: f.encrypted(),
                    link: zip_link(&f),
                    modified: zip_mtime(&f),
                });
            }
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            let reader = sevenz_rust2::SevenZReader::open(path, pw).map_err(seven_err)?;
            let archive = reader.archive();
            for (i, f) in archive.files.iter().enumerate() {
                out.push(Entry {
                    name: f.name().to_string(),
                    size: f.size(),
                    compressed: f.compressed_size,
                    dir: f.is_directory(),
                    encrypted: sevenz_encrypted(archive, i),
                    link: sevenz_link(f),
                    modified: f.has_last_modified_date.then(|| f.last_modified_date().to_unix_time_secs()),
                });
            }
        }
        "rar" => {
            let mut a = rar(path, password).open_for_listing().map_err(|e| e.to_string())?;
            while let Some(h) = a.read_header().map_err(|e| e.to_string())? {
                let e = h.entry();
                out.push(Entry {
                    name: e.filename.to_string_lossy().to_string(),
                    size: e.unpacked_size,
                    // unrar's listing header exposes no packed size: repeat unpacked.
                    compressed: e.unpacked_size,
                    dir: e.is_directory(),
                    encrypted: e.is_encrypted(),
                    // unrar exposes no symlink flag: rar links surface through unpack-time
                    // resolution, as in legacy.
                    link: false,
                    modified: None,
                });
                a = h.skip().map_err(|e| e.to_string())?;
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            for e in t.entries().map_err(|e| e.to_string())? {
                let e = e.map_err(|e| e.to_string())?;
                let h = e.header();
                out.push(Entry {
                    name: e.path().map_err(|e| e.to_string())?.to_string_lossy().to_string(),
                    size: h.size().unwrap_or(0),
                    compressed: h.size().unwrap_or(0),
                    dir: h.entry_type().is_dir(),
                    encrypted: false,
                    // Hardlinks resolve against the archive's own layout, so unpack treats
                    // both link kinds as links.
                    link: h.entry_type().is_symlink() || h.entry_type().is_hard_link(),
                    modified: h.mtime().ok().map(|m| m as i64),
                });
            }
        }
    }
    Ok(out)
}

/// Writes the entries of the archive at `path` as [record]s back to back; freed with `tk_free`.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_list(
    path: *const u8,
    plen: usize,
    pw: *const u8,
    pwlen: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let mut buf = Vec::new();
        for e in list(text(path, plen)?, opt_text(pw, pwlen)?)? {
            record(&e, &mut buf);
        }
        Ok(give(buf, out, out_len))
    })
}

// ---- extract

fn unix_time(secs: i64) -> std::time::SystemTime {
    std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs.max(0) as u64)
}

/// Copies at most `max` bytes, failing when the stream holds more: a bomb lying about size.
fn copy_capped(from: &mut dyn Read, to: &mut Vec<u8>, max: u64, name: &str) -> Result<(), String> {
    let mut limited = from.take(max + 1);
    let n = std::io::copy(&mut limited, to).map_err(|e| e.to_string())? as u64;
    if n > max {
        return Err(format!("{}: larger than its header says ({} bytes)", name, max));
    }
    Ok(())
}

/// Writes one file entry: charged, contained, fresh (never through a link), then mode/mtime.
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
        // Made, not just checked: solid-block readers skip directory entries, so the
        // parent may never have been visited.
        pol.contains(parent)?;
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {}", parent.display(), e))?;
    }
    if target.symlink_metadata().is_ok() {
        std::fs::remove_file(target).map_err(|e| format!("{}: {}", target.display(), e))?;
    }
    let mut to = std::fs::OpenOptions::new().write(true).create_new(true).open(target).map_err(|e| format!("{}: {}", target.display(), e))?;
    let mut buf = Vec::new();
    copy_capped(from, &mut buf, size, name)?;
    to.write_all(&buf).map_err(|e| format!("{}: {}", target.display(), e))?;
    set_mode(target, mode, pol.trusted);
    if let Some(s) = mtime {
        let _ = to.set_modified(unix_time(s));
    }
    Ok(())
}

/// Applies `mode` to a finished file or folder: full bits when trusted, `0o777` else.
fn set_mode(path: &Path, mode: Option<u32>, trusted: bool) {
    let Some(mode) = mode else {
        return;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let bits = if trusted { mode & 0o7777 } else { mode & 0o777 };
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(bits));
    }
    #[cfg(not(unix))]
    {
        let _ = (path, trusted);
        if mode & 0o200 == 0 {
            if let Ok(meta) = std::fs::metadata(path) {
                let mut perms = meta.permissions();
                perms.set_readonly(true);
                let _ = std::fs::set_permissions(path, perms);
            }
        }
    }
}

/// Clears setuid/setgid/sticky on an untrusted file.
fn strip_setid(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = std::fs::metadata(path) {
            let bits = meta.permissions().mode() & !0o7000;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(bits));
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
}

fn extract(path: &str, dest: &str, password: Option<&str>, only: Option<&str>, flags: u32, progress: ProgressCb) -> Result<i32, String> {
    let kind = detect_read(path)?;
    let root = Path::new(dest);
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let mut pol = Policy::new(path, root, only, flags)?;
    let mut count = 0;
    let mut dirs: Vec<(PathBuf, Option<u32>, Option<i64>)> = Vec::new();
    // Kept past the match, so the last report still says how many bytes there were.
    let (mut bytes_done, mut total_bytes) = (0u64, 0u64);
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            let total = z.len() as u64;
            // Raw, so an encrypted entry counts without its password; only extracted counts.
            for i in 0..z.len() {
                if let Ok(f) = z.by_index_raw(i) {
                    if !f.is_dir() && pol.wants(&zip_name(&f)) {
                        total_bytes = total_bytes.saturating_add(f.size());
                    }
                }
            }
            unsafe {
                report_progress(progress, 0, total, 0, total_bytes, "")?;
            }
            for i in 0..z.len() {
                // Raw first: an entry not wanted is never opened, so never decrypted.
                let name = zip_name(&z.by_index_raw(i).map_err(|e| e.to_string())?).to_string();
                let target = inside(root, &name)?;
                if !pol.wants(&name) {
                    continue;
                }
                unsafe {
                    report_progress(progress, i as u64, total, bytes_done, total_bytes, &name)?;
                }
                let mut f = match password {
                    Some(pw) => z.by_index_decrypt(i, pw.as_bytes()).map_err(|e| e.to_string())?,
                    None => z.by_index(i).map_err(|e| e.to_string())?,
                };
                if f.is_dir() {
                    pol.contains(&target)?;
                    std::fs::create_dir_all(&target).map_err(|e| e.to_string())?;
                    dirs.push((target.clone(), f.unix_mode(), zip_mtime(&f)));
                    continue;
                }
                if f.is_symlink() {
                    let mut link = String::new();
                    (&mut f).take(4096).read_to_string(&mut link).map_err(|e| e.to_string())?;
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
            let mut reader = sevenz_rust2::SevenZReader::open(path, pw).map_err(seven_err)?;
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
                        report_progress(progress, idx, total, bytes_done, total_bytes, &name).map_err(seven_other)?;
                    }
                    if !pol.wants(&name) {
                        // A solid block is one stream: an entry not wanted is still read past.
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        idx += 1;
                        return Ok(true);
                    }
                    let target = inside(root, &name).map_err(seven_other)?;
                    let mtime = e.has_last_modified_date.then(|| e.last_modified_date().to_unix_time_secs());
                    let mode = Some(e.windows_attributes >> 16).filter(|&m| e.has_windows_attributes && m != 0);
                    if e.is_directory() {
                        pol.contains(&target).map_err(seven_other)?;
                        std::fs::create_dir_all(&target).map_err(sevenz_rust2::Error::io)?;
                        dirs.push((target.clone(), mode, mtime));
                        idx += 1;
                        return Ok(true);
                    }
                    if sevenz_link(e) {
                        let mut link = String::new();
                        Read::take(&mut *r, 4096).read_to_string(&mut link).map_err(sevenz_rust2::Error::io)?;
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        pol.link(&target, &name, &link).map_err(seven_other)?;
                        idx += 1;
                        return Ok(true);
                    }
                    write_file(&mut pol, &target, r, e.size(), &name, mtime, mode).map_err(seven_other)?;
                    bytes_done += e.size();
                    count += 1;
                    idx += 1;
                    unsafe {
                        report_progress(progress, idx, total, bytes_done, total_bytes, &name).map_err(seven_other)?;
                    }
                    Ok(true)
                })
                .map_err(seven_err)?;
        }
        "rar" => {
            let mut a = rar(path, password).open_for_processing().map_err(|e| e.to_string())?;
            let mut idx = 0u64;
            unsafe {
                report_progress(progress, 0, 0, 0, 0, "")?;
            }
            while let Some(h) = a.read_header().map_err(|e| e.to_string())? {
                let name = h.entry().filename.to_string_lossy().to_string();
                let target = inside(root, &name)?;
                unsafe {
                    report_progress(progress, idx, 0, bytes_done, 0, &name)?;
                }
                if !pol.wants(&name) {
                    a = h.skip().map_err(|e| e.to_string())?;
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
                        std::fs::remove_file(&target).map_err(|e| e.to_string())?;
                    }
                }
                a = h.extract_with_base(dest).map_err(|e| e.to_string())?;
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
            for e in t.entries().map_err(|e| e.to_string())? {
                let mut e = e.map_err(|e| e.to_string())?;
                let name = e.path().map_err(|e| e.to_string())?.to_string_lossy().to_string();
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
                    let link = e.link_name().map_err(|e| e.to_string())?.map(|l| l.to_string_lossy().to_string());
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
                if e.unpack_in(root).map_err(|e| e.to_string())? && kind.is_file() {
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
        if let Some(s) = mtime {
            #[cfg(unix)]
            if let Ok(f) = std::fs::File::open(&dir) {
                let _ = f.set_modified(unix_time(s));
            }
            #[cfg(not(unix))]
            let _ = s;
        }
        set_mode(&dir, mode, pol.trusted);
    }
    unsafe {
        report_progress(progress, count as u64, count as u64, bytes_done, total_bytes, "")?;
    }
    Ok(count)
}

/// Extracts the archive at `path` into `dest`; answers the number of files written.
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

// ---- read (single entry)

// ---- read (single entry)

/// Whether a zip entry is a symlink: its Unix mode says S_IFLNK.
fn zip_link(f: &zip::read::ZipFile) -> bool {
    f.unix_mode().is_some_and(|m| (m >> 12) & 0xF == 0xA)
}

/// The entry `name`'s bytes after [OWNED] free ones, as [own] hands them over.
fn read_entry(path: &str, name: &str, password: Option<&str>, flags: u32) -> Result<Vec<u8>, String> {
    let kind = detect_read(path)?;
    let mut pol = Policy::new(path, Path::new("."), None, flags)?;
    let want = plain(name);
    let missing = || format!("{}: no entry {}", path, name);
    // Sized up front from the header, so a large entry is never copied as the vector grows.
    let sized = |size: u64| {
        let mut out = Vec::with_capacity(OWNED + size.min(1 << 30) as usize);
        out.resize(OWNED, 0);
        out
    };
    let mut out = Vec::new();
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            // By the name `list` gives, which the zip crate's own lookup does not read.
            let index = (0..z.len())
                .find(|&i| z.by_index_raw(i).is_ok_and(|f| zip_name(&f) == want))
                .ok_or_else(missing)?;
            let mut f = match password {
                Some(pw) => z.by_index_decrypt(index, pw.as_bytes()).map_err(|e| e.to_string())?,
                None => z.by_index(index).map_err(|e| e.to_string())?,
            };
            pol.charge(f.size(), name)?;
            let size = f.size();
            out = sized(size);
            copy_capped(&mut f, &mut out, size, name)?;
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            let mut reader = sevenz_rust2::SevenZReader::open(path, pw).map_err(seven_err)?;
            let mut found = false;
            reader
                .for_each_entries(|e, r| {
                    if plain(e.name()) != want {
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        return Ok(true);
                    }
                    found = true;
                    pol.charge(e.size(), name).map_err(seven_other)?;
                    out = sized(e.size());
                    copy_capped(r, &mut out, e.size(), name).map_err(seven_other)?;
                    Ok(false)
                })
                .map_err(seven_err)?;
            if !found {
                return Err(missing());
            }
        }
        "rar" => {
            let mut a = rar(path, password).open_for_processing().map_err(|e| e.to_string())?;
            let mut found = false;
            while let Some(h) = a.read_header().map_err(|e| e.to_string())? {
                let ename = h.entry().filename.to_string_lossy().to_string();
                if plain(&ename) != want {
                    a = h.skip().map_err(|e| e.to_string())?;
                    continue;
                }
                found = true;
                pol.charge(h.entry().unpacked_size, name).map_err(|e| e.to_string())?;
                out = sized(h.entry().unpacked_size);
                let (bytes, _) = h.read().map_err(|e| e.to_string())?;
                out.extend_from_slice(&bytes);
                break;
            }
            if !found {
                return Err(missing());
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            let mut found = false;
            for e in t.entries().map_err(|e| e.to_string())? {
                let mut e = e.map_err(|e| e.to_string())?;
                let ename = e.path().map_err(|e| e.to_string())?.to_string_lossy().to_string();
                if plain(&ename) != want {
                    continue;
                }
                found = true;
                let size = e.size();
                out = take(&mut pol, &mut e, size, name)?;
                break;
            }
            if !found {
                return Err(missing());
            }
        }
    }
    Ok(out)
}

/// Reads up to `max` bytes into an [OWNED]-headed buffer, charging the policy first.
fn take(pol: &mut Policy, from: &mut dyn Read, size: u64, name: &str) -> Result<Vec<u8>, String> {
    pol.charge(size, name)?;
    let mut out = Vec::with_capacity(OWNED + size.min(1 << 30) as usize);
    out.resize(OWNED, 0);
    copy_capped(from, &mut out, size, name)?;
    Ok(out)
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
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
        let (ptr, n) = own(read_entry(text(path, plen)?, text(name, nlen)?, opt_text(pw, pwlen)?, flags)?);
        *out = ptr;
        *out_len = n;
        Ok(0)
    })
}

// ---- contents (every file, one pass)

/// Walks the archive calling `emit` per file entry (folders and links omitted); `false`
/// stops the walk. `emit` receives the [record] metadata and the [OWNED]-headed bytes.
fn contents(
    path: &str,
    password: Option<&str>,
    only: Option<&str>,
    flags: u32,
    emit: &mut dyn FnMut(Entry, Vec<u8>) -> bool,
) -> Result<(), String> {
    let kind = detect_read(path)?;
    let mut pol = Policy::new(path, Path::new("."), only, flags)?;
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            for i in 0..z.len() {
                let name = zip_name(&z.by_index_raw(i).map_err(|e| e.to_string())?).to_string();
                let probe = z.by_index_raw(i).map_err(|e| e.to_string())?;
                let (dir, link, size) = (probe.is_dir(), zip_link(&probe), probe.size());
                drop(probe);
                if dir || link || !pol.wants(&name) {
                    continue;
                }
                let mut f = match password {
                    Some(pw) => z.by_index_decrypt(i, pw.as_bytes()).map_err(|e| e.to_string())?,
                    None => z.by_index(i).map_err(|e| e.to_string())?,
                };
                let entry = Entry { name: name.clone(), size, compressed: f.compressed_size(), dir: false, encrypted: f.encrypted(), link: false, modified: zip_mtime(&f) };
                let data = take(&mut pol, &mut f, size, &name)?;
                if !emit(entry, data) {
                    return Ok(());
                }
            }
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            let mut reader = sevenz_rust2::SevenZReader::open(path, pw).map_err(seven_err)?;
            // Encrypted flags up front: the streaming walk below cannot index back into them.
            let mut encrypted = std::collections::HashMap::new();
            for (i, f) in reader.archive().files.iter().enumerate() {
                encrypted.insert(f.name().to_string(), sevenz_encrypted(reader.archive(), i));
            }
            reader
                .for_each_entries(|e, r| {
                    let name = e.name().to_string();
                    if e.is_directory() || sevenz_link(e) || !pol.wants(&name) {
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        return Ok(true);
                    }
                    let entry = Entry {
                        name: name.clone(),
                        size: e.size(),
                        compressed: e.compressed_size,
                        dir: false,
                        encrypted: encrypted.get(&name).copied().unwrap_or(false),
                        link: false,
                        modified: e.has_last_modified_date.then(|| e.last_modified_date().to_unix_time_secs()),
                    };
                    let mut data = Vec::with_capacity(OWNED + (e.size().min(1 << 30) as usize));
                    data.resize(OWNED, 0);
                    pol.charge(e.size(), &name).map_err(seven_other)?;
                    copy_capped(r, &mut data, e.size(), &name).map_err(seven_other)?;
                    Ok(emit(entry, data))
                })
                .map_err(seven_err)?;
        }
        "rar" => {
            let mut a = rar(path, password).open_for_processing().map_err(|e| e.to_string())?;
            while let Some(h) = a.read_header().map_err(|e| e.to_string())? {
                let e = h.entry();
                let name = e.filename.to_string_lossy().to_string();
                if !e.is_file() || !pol.wants(&name) {
                    a = h.skip().map_err(|e| e.to_string())?;
                    continue;
                }
                pol.charge(e.unpacked_size, &name)?;
                let entry = Entry {
                    size: e.unpacked_size,
                    // As `list` says: unrar's header has no packed size.
                    compressed: e.unpacked_size,
                    dir: false,
                    encrypted: e.is_encrypted(),
                    link: false,
                    modified: None,
                    name,
                };
                let (bytes, next) = h.read().map_err(|e| e.to_string())?;
                a = next;
                let mut data = Vec::with_capacity(OWNED + bytes.len());
                data.resize(OWNED, 0);
                data.extend_from_slice(&bytes);
                if !emit(entry, data) {
                    return Ok(());
                }
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            for e in t.entries().map_err(|e| e.to_string())? {
                let mut e = e.map_err(|e| e.to_string())?;
                let name = e.path().map_err(|e| e.to_string())?.to_string_lossy().to_string();
                if !e.header().entry_type().is_file() || !pol.wants(&name) {
                    continue;
                }
                let entry = Entry {
                    size: e.size(),
                    compressed: e.size(),
                    dir: false,
                    encrypted: false,
                    link: false,
                    modified: e.header().mtime().ok().map(|m| m as i64),
                    name,
                };
                let size = entry.size;
                let data = take(&mut pol, &mut e, size, &entry.name)?;
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

/// The pass `tk_archive_contents` hands back: the channel one `()` per awaited file.
struct Contents {
    more: std::sync::mpsc::Sender<()>,
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
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
    let mut pass: *mut std::ffi::c_void = std::ptr::null_mut();
    let code = guard(|| {
        let (path, password, only) = (
            text(path, plen)?.to_string(),
            opt_text(pw, pwlen)?.map(str::to_string),
            opt_text(only, olen)?.map(str::to_string),
        );
        let cb = listener.ok_or("a pass needs a listener")?;
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let worker = std::thread::spawn(move || {
            // One record + optional bytes per file; the head frees with `tk_free`, data with
            // `tk_release`. Defined in the thread: the listener outlives the call.
            let tell = |code: i32, head: Vec<u8>, data: Option<Vec<u8>>| {
                let mut h = std::ptr::null_mut();
                let mut hl = 0usize;
                if !head.is_empty() {
                    let boxed = head.into_boxed_slice();
                    hl = boxed.len();
                    h = Box::into_raw(boxed) as *mut u8;
                }
                let (mut d, mut dl) = (std::ptr::null_mut(), 0usize);
                if let Some(data) = data {
                    let (ptr, n) = own(data);
                    d = ptr;
                    dl = n;
                }
                cb(code, h, hl, d, dl);
            };
            // Read-ahead by one: each file waits until the caller asks for it.
            let mut emit = |entry: Entry, data: Vec<u8>| {
                if rx.recv().is_err() {
                    return false;
                }
                let mut head = Vec::new();
                record(&entry, &mut head);
                tell(1, head, Some(data));
                true
            };
            match contents_caught(&path, password.as_deref(), only.as_deref(), flags, &mut emit) {
                Ok(()) => tell(0, Vec::new(), None),
                Err(m) => tell(-1, m.into_bytes(), None),
            }
        });
        // Detached: `free` stops it at the next file; the listener still gets its `0`.
        std::mem::forget(worker);
        pass = Box::into_raw(Box::new(Contents { more: tx })) as *mut _;
        Ok(0)
    });
    if code < 0 {
        return std::ptr::null_mut();
    }
    pass
}

#[no_mangle]
pub unsafe extern "C" fn tk_archive_contents_more(pass: *mut std::ffi::c_void) {
    if pass.is_null() {
        return;
    }
    if let Ok(contents) = live::<Contents>(pass as Handle) {
        let _ = contents.more.send(());
    }
}

#[no_mangle]
pub unsafe extern "C" fn tk_archive_contents_free(pass: *mut std::ffi::c_void) {
    if !pass.is_null() {
        drop(Box::from_raw(pass as *mut Contents));
    }
}

// ---- create

/// What the walk found: display name, disk path, kind.
enum ItemKind {
    Dir,
    File,
    Symlink(PathBuf),
}

/// Validates a stream `level`: -1 is the default; out-of-range is an error naming the codec.
fn validate_codec_level(codec: u32, level: i32) -> Result<(), String> {
    if level < -1 && codec != ZSTD {
        return Err("compression level cannot be negative".into());
    }
    match codec {
        GZIP if level > 9 => Err("gzip/zip level is 0..=9".into()),
        XZ if level > 9 => Err("xz level is 0..=9".into()),
        BZIP2 if level == 0 || level > 9 => Err("bzip2 level is 1..=9".into()),
        ZSTD if level > 22 => Err("zstd level is up to 22".into()),
        GZIP | XZ | ZSTD | BZIP2 | DETECT => Ok(()),
        _ => Err(format!("unknown codec {}", codec)),
    }
}

fn validate_archive_level(format: u32, level: i32) -> Result<(), String> {
    match format {
        SEVENZ if level > 9 => Err("7z level is 0..=9".into()),
        ZIP | TAR_GZ => validate_codec_level(GZIP, level),
        TAR_XZ => validate_codec_level(XZ, level),
        TAR_ZST => validate_codec_level(ZSTD, level),
        TAR_BZ2 => validate_codec_level(BZIP2, level),
        TAR => validate_codec_level(DETECT, level),
        _ => Ok(()),
    }
}

/// Workers for a `size`-byte stream: 0 (single-threaded) under 32 MiB.
fn workers(size: u64) -> usize {
    if size < (32 << 20) {
        return 0;
    }
    std::thread::available_parallelism().map(|n| n.get().min(4)).unwrap_or(0)
}

fn xz_threads(level: u32, size: u64) -> usize {
    match workers(size) {
        0 => 0,
        n => {
            let _ = level;
            n
        }
    }
}

fn xz_encoder<W: Write>(out: W, level: u32, size: u64) -> Result<xz2::write::XzEncoder<W>, String> {
    match xz_threads(level, size) {
        0 => Ok(xz2::write::XzEncoder::new(out, level)),
        n => {
            let stream = xz2::stream::MtStreamBuilder::new()
                .threads(n as u32)
                .preset(level)
                .check(xz2::stream::Check::Crc64)
                // Bounded blocks: the default scales with the dict (tens of MB at high
                // levels), so one write could block for a whole archive with no stop
                // check inside. 1 MiB blocks keep every blocking segment to seconds.
                .block_size(1 << 20)
                .encoder()
                .map_err(|e| e.to_string())?;
            Ok(xz2::write::XzEncoder::new_stream(out, stream))
        }
    }
}

fn zstd_encoder<W: Write>(out: W, level: i32, size: u64) -> Result<zstd::stream::write::Encoder<'static, W>, String> {
    let mut enc = zstd::stream::write::Encoder::new(out, level).map_err(|e| e.to_string())?;
    if let n @ 1.. = workers(size) {
        enc.multithread(n as u32).map_err(|e| e.to_string())?;
    }
    Ok(enc)
}

/// The encoded writer over `out`, or `out` itself for `None`; `size` is the input's, and
/// `level` -1 is the codec's default.
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
            Encoder::Plain(w) => w.write(buf),
            Encoder::Gz(w) => w.write(buf),
            Encoder::Xz(w) => w.write(buf),
            Encoder::Zst(w) => w.write(buf),
            Encoder::Bz2(w) => w.write(buf),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Encoder::Plain(w) => w.flush(),
            Encoder::Gz(w) => w.flush(),
            Encoder::Xz(w) => w.flush(),
            Encoder::Zst(w) => w.flush(),
            Encoder::Bz2(w) => w.flush(),
        }
    }
}

impl<W: Write> Encoder<W> {
    fn finish(self) -> std::io::Result<W> {
        match self {
            Encoder::Plain(w) => Ok(w),
            Encoder::Gz(w) => w.finish(),
            Encoder::Xz(w) => w.finish(),
            Encoder::Zst(w) => w.finish(),
            Encoder::Bz2(w) => w.finish(),
        }
    }
}

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

/// Walks `src` into `(name, path, kind)`: one file as itself, a folder recursively —
/// links never followed, entries sorted, the destination skipped when under the source,
/// and `names` (NUL-joined, null for all) selecting members.
fn walk(src: &Path, dest: &Path, names: Option<&str>) -> Result<Vec<(String, PathBuf, ItemKind)>, String> {
    // The caller lists platform paths (`\` on Windows); members compare with `/`.
    let wanted: Option<std::collections::HashSet<String>> = names.map(|n| {
        n.split('\0').filter(|s| !s.is_empty()).map(|s| s.replace('\\', "/")).collect()
    });
    let mut items = Vec::new();
    let meta = std::fs::symlink_metadata(src).map_err(|e| e.to_string())?;
    if meta.file_type().is_file() {
        let name = src.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if wanted.as_ref().is_some_and(|w| !w.contains(&name)) {
            return Ok(Vec::new());
        }
        return Ok(vec![(name, src.to_path_buf(), ItemKind::File)]);
    }
    if !meta.file_type().is_dir() {
        return Err(format!("{}: not a file or folder", src.display()));
    }
    let dest_inside = dest.starts_with(src);
    let mut entries: Vec<_> = walkdir::WalkDir::new(src).follow_links(false).min_depth(1).into_iter().filter_map(|e| e.ok()).collect();
    entries.sort_by(|a, b| a.path().cmp(b.path()));
    for e in entries {
        let path = e.path().to_path_buf();
        if dest_inside && path.starts_with(dest) {
            continue;
        }
        let rel = path.strip_prefix(src).map_err(|e| e.to_string())?.to_string_lossy().replace('\\', "/");
        let kind = if e.file_type().is_symlink() {
            ItemKind::Symlink(std::fs::read_link(&path).map_err(|e| e.to_string())?)
        } else if e.file_type().is_dir() {
            ItemKind::Dir
        } else {
            ItemKind::File
        };
        if let Some(w) = wanted.as_ref() {
            let hit = w.contains(&rel) || matches!(kind, ItemKind::Dir) && w.iter().any(|m| m.starts_with(&format!("{}/", rel)));
            if !hit {
                continue;
            }
        }
        items.push((rel, path, kind));
    }
    Ok(items)
}

#[allow(clippy::too_many_arguments)]
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
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
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
                let method = if level == 0 { zip::CompressionMethod::Stored } else { zip::CompressionMethod::Deflated };
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
                        w.add_directory(name, opts).map_err(|e| e.to_string())?;
                    }
                    ItemKind::Symlink(target) => {
                        w.add_symlink(name, target.to_string_lossy(), opts).map_err(|e| e.to_string())?;
                    }
                    ItemKind::File => {
                        w.start_file(name, opts).map_err(|e| e.to_string())?;
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
            w.finish().map_err(|e| e.to_string())?.flush().map_err(|e| e.to_string())?;
        }
        SEVENZ => {
            // Our own walk, as for zip and tar: the crate's runs after the destination exists
            // and would archive it into itself.
            let mut z = sevenz_rust2::SevenZWriter::new(create_file(out)?).map_err(seven_err)?;
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
                if let ItemKind::Symlink(target) = kind {
                    // A file holding its target, marked S_IFLNK, as p7zip writes a link.
                    let mut entry = sevenz_rust2::SevenZArchiveEntry::new_file(name);
                    entry.has_windows_attributes = true;
                    entry.windows_attributes = 0x8000 | (0o120777 << 16);
                    let text = target.to_string_lossy().into_owned().into_bytes();
                    z.push_archive_entry(entry, Some(std::io::Cursor::new(text))).map_err(seven_err)?;
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
                let flen = if matches!(kind, ItemKind::File) { path.metadata().map_or(0, |m| m.len()) } else { 0 };
                let reader = if matches!(kind, ItemKind::Dir) {
                    None
                } else {
                    Some(Watched(BufReader::new(read_file(path.to_str().ok_or("bad path")?)?)))
                };
                z.push_archive_entry(entry, reader).map_err(seven_err)?;
                bytes_done += flen;
                completed += 1;
                unsafe {
                    report_progress(progress, completed, total_items, bytes_done, total_bytes, name)?;
                }
            }
            z.finish().map_err(seven_err)?;
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
                let flen = if matches!(kind, ItemKind::File) { path.metadata().map_or(0, |m| m.len()) } else { 0 };
                match kind {
                    ItemKind::Dir => {
                        b.append_dir(name, path).map_err(|e| e.to_string())?;
                    }
                    // Read through a watch, so one large file stops part way.
                    ItemKind::File => {
                        let file = read_file(path.to_str().ok_or("bad path")?)?;
                        let mut header = tar::Header::new_gnu();
                        header.set_metadata(&file.metadata().map_err(|e| e.to_string())?);
                        b.append_data(&mut header, name, Watched(BufReader::new(file))).map_err(|e| e.to_string())?;
                    }
                    ItemKind::Symlink(_) => {
                        b.append_path_with_name(path, name).map_err(|e| e.to_string())?;
                    }
                }
                bytes_done += flen;
                completed += 1;
                unsafe {
                    report_progress(progress, completed, total_items, bytes_done, total_bytes, name)?;
                }
            }
            b.into_inner().map_err(|e| e.to_string())?.finish().map_err(|e| e.to_string())?.flush().map_err(|e| e.to_string())?;
        }
        _ => unreachable!(),
    }
    Ok(files)
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
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
        create(
            format,
            text(src, slen)?,
            text(dest, dlen)?,
            text(out, olen)?,
            opt_text(pw, pwlen)?,
            opt_text(names, nlen)?,
            level,
            progress,
        )
    })
}

// ---- compressed streams

/// Encodes the file at `src` with `codec` into `dest`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
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
        let (src, dest) = (text(src, slen)?, text(dest, dlen)?);
        validate_codec_level(codec, level)?;
        let size = std::fs::metadata(src).map(|m| m.len()).unwrap_or(0);
        let tell = |done: u64| -> Result<(), String> {
            if let Some(cb) = progress {
                unsafe { cb(0, 1, done, size, std::ptr::null(), 0) };
            }
            stopped()
        };
        let mut from = Watched(BufReader::new(read_file(src)?));
        let mut enc = encoder(Some(codec), BufWriter::new(create_file(dest)?), level, size)?;
        let mut buf = vec![0u8; 1 << 20];
        let mut done = 0u64;
        tell(0)?;
        loop {
            let n = from.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            enc.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            done += n as u64;
            tell(done)?;
        }
        enc.finish().map_err(|e| e.to_string())?.flush().map_err(|e| e.to_string())?;
        Ok(0)
    })
}

/// Decodes the stream at `src` into `dest`; `codec` is one of the codec codes or DETECT
/// (read the magic). Untrusted output is capped like an extraction; a breach removes `dest`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
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
    guard(|| {
        let (src, dest) = (text(src, slen)?, text(dest, dlen)?);
        let codec = if codec == DETECT {
            sniff_codec(src).ok_or_else(|| format!("{}: not a gzip, xz, zstd or bzip2 stream", src))?
        } else {
            match codec {
                GZIP | XZ | ZSTD | BZIP2 => codec,
                c => return Err(format!("unknown codec {}", c)),
            }
        };
        let size = std::fs::metadata(src).map(|m| m.len()).unwrap_or(0);
        let limit = if flags & TRUSTED != 0 { u64::MAX } else { FLOOR.max(size.saturating_mul(RATIO)) };
        let result = (|| {
            let f = read_file(src)?;
            let mut decoder: Box<dyn Read> = match codec {
                GZIP => Box::new(flate2::read::GzDecoder::new(f)),
                XZ => Box::new(xz2::read::XzDecoder::new(f)),
                ZSTD => Box::new(zstd::stream::read::Decoder::new(f).map_err(|e| e.to_string())?),
                _ => Box::new(bzip2::read::BzDecoder::new(f)),
            };
            let mut to = BufWriter::new(create_file(dest)?);
            let mut buf = vec![0u8; 1 << 20];
            let mut done = 0u64;
            loop {
                let n = decoder.read(&mut buf).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                done += n as u64;
                if done > limit {
                    return Err(format!(
                        "{}: decompresses to more than {} bytes, 200× the file and at least 1 GiB; unarchive with unsafe: true if that is expected",
                        src, limit
                    ));
                }
                to.write_all(&buf[..n]).map_err(|e| e.to_string())?;
                if let Some(cb) = progress {
                    unsafe { cb(0, 1, done, size, std::ptr::null(), 0) };
                }
                stopped()?;
            }
            to.flush().map_err(|e| e.to_string())?;
            Ok(0)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(dest);
        }
        result
    })
}

// ---- streaming stepper (new in native2)
//
// Entry-by-entry walk without materializing the archive: `open` positions before the
// first entry, `next` advances and reports the entry's name/size/kind, `entry_read`
// streams the current entry's bytes in caller-sized chunks. Tar kinds stream truly
// (the decoder stays positioned in the flow); zip/7z/rar scan metadata at open and
// extract one member at a time.

/// One stepped member's metadata.
struct Meta {
    name: String,
    size: u64,
    dir: bool,
}

enum Stepper {
    Indexed {
        kind: String,
        path: String,
        password: Option<String>,
        budget: u64,
        limit: u64,
        metas: Vec<Meta>,
        pos: usize,
        buf: Vec<u8>,
        at: usize,
    },
    TarLive {
        reader: Box<dyn Read>,
        remaining: u64,
        pad: u64,
        ended: bool,
        pending_name: Option<String>,
    },
}

/// Opens `path` for stepping; `flags` carries TRUSTED/FOLD_CASE for the read budget.
/// Passworded entries need `pw` when their bytes are read.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_open(
    path: *const u8,
    plen: usize,
    pw: *const u8,
    pwlen: usize,
    flags: u32,
) -> Handle {
    let mut out = std::ptr::null_mut();
    let code = guard(|| {
        let (path, password) = (text(path, plen)?.to_string(), opt_text(pw, pwlen)?.map(str::to_string));
        let kind = detect_read(&path)?.to_string();
        let trusted = flags & TRUSTED != 0;
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        let limit = if trusted { u64::MAX } else { FLOOR.max(size.saturating_mul(RATIO)) };
        let stepper = match kind.as_str() {
            "tar" | "tar.gz" | "tar.xz" | "tar.zst" | "tar.bz2" => Stepper::TarLive {
                reader: tar_reader(&path, &kind)?,
                remaining: 0,
                pad: 0,
                ended: false,
                pending_name: None,
            },
            _ => Stepper::Indexed {
                kind,
                path,
                password,
                budget: limit,
                limit,
                metas: Vec::new(),
                pos: 0,
                buf: Vec::new(),
                at: 0,
            },
        };
        out = Box::into_raw(Box::new(stepper)) as Handle;
        // Indexed kinds scan metadata now; tar kinds stream on demand.
        if let Stepper::Indexed { kind, path, metas, .. } = &mut * (out as *mut Stepper) {
            scan_metas(kind, path, metas)?;
        }
        Ok(0)
    });
    if code < 0 {
        return std::ptr::null_mut();
    }
    out
}

/// Scans indexed-kind metadata: names, sizes, folder flags. No data is read.
fn scan_metas(kind: &str, path: &str, metas: &mut Vec<Meta>) -> Result<(), String> {
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            for i in 0..z.len() {
                let f = z.by_index_raw(i).map_err(|e| e.to_string())?;
                metas.push(Meta { name: zip_name(&f), size: f.size(), dir: f.is_dir() });
            }
        }
        "7z" => {
            let reader = sevenz_rust2::SevenZReader::open(path, sevenz_rust2::Password::from("")).map_err(seven_err)?;
            for f in &reader.archive().files {
                metas.push(Meta { name: f.name().to_string(), size: f.size(), dir: f.is_directory() });
            }
        }
        "rar" => {
            let mut a = rar(path, None).open_for_listing().map_err(|e| e.to_string())?;
            while let Some(h) = a.read_header().map_err(|e| e.to_string())? {
                let e = h.entry();
                metas.push(Meta {
                    name: e.filename.to_string_lossy().to_string(),
                    size: e.unpacked_size,
                    dir: e.is_directory(),
                });
                a = h.skip().map_err(|e| e.to_string())?;
            }
        }
        other => return Err(format!("{}: cannot step a {} stream", path, other)),
    }
    Ok(())
}

/// Extracts the indexed current member's bytes, charging the budget.
fn indexed_bytes(session: &mut Stepper, index: usize) -> Result<Vec<u8>, String> {
    let Stepper::Indexed { kind, path, password, budget, limit, metas, .. } = session else {
        unreachable!()
    };
    let meta = &metas[index];
    let mut charge = |size: u64| -> Result<(), String> {
        if size > *budget {
            return Err(format!(
                "{}: extracting it would write more than {} bytes, 200× the archive and at least 1 GiB; unarchive with unsafe: true if that is expected",
                meta.name, *limit
            ));
        }
        *budget -= size;
        Ok(())
    };
    charge(meta.size)?;
    let mut out = vec![0u8; meta.size.min(1 << 30) as usize];
    // Sized exactly; large members grow as they are read.
    out.clear();
    match kind.as_str() {
        "zip" => {
            let mut z = zip_open(path)?;
            let at = (0..z.len())
                .find(|&i| z.by_index_raw(i).is_ok_and(|f| zip_name(&f) == meta.name))
                .ok_or_else(|| format!("{}: no entry {}", path, meta.name))?;
            let mut f = match password {
                Some(pw) => z.by_index_decrypt(at, pw.as_bytes()).map_err(|e| e.to_string())?,
                None => z.by_index(at).map_err(|e| e.to_string())?,
            };
            copy_capped(&mut f, &mut out, meta.size, &meta.name)?;
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.as_deref().unwrap_or(""));
            let mut reader = sevenz_rust2::SevenZReader::open(path.as_str(), pw).map_err(seven_err)?;
            let mut found = false;
            reader
                .for_each_entries(|e, r| {
                    if e.name() != meta.name {
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        return Ok(true);
                    }
                    found = true;
                    copy_capped(r, &mut out, meta.size, &meta.name).map_err(seven_other)?;
                    Ok(false)
                })
                .map_err(seven_err)?;
            if !found {
                return Err(format!("{}: no entry {}", path, meta.name));
            }
        }
        _ => {
            let mut a = rar(path, password.as_deref()).open_for_processing().map_err(|e| e.to_string())?;
            let mut found = false;
            while let Some(h) = a.read_header().map_err(|e| e.to_string())? {
                let ename = h.entry().filename.to_string_lossy().to_string();
                if ename != meta.name {
                    a = h.skip().map_err(|e| e.to_string())?;
                    continue;
                }
                found = true;
                let (bytes, _) = h.read().map_err(|e| e.to_string())?;
                if bytes.len() as u64 > meta.size {
                    return Err(format!("{}: larger than its header says ({} bytes)", meta.name, meta.size));
                }
                out.extend_from_slice(&bytes);
                break;
            }
            if !found {
                return Err(format!("{}: no entry {}", path, meta.name));
            }
        }
    }
    Ok(out)
}

/// Reads exactly `buf.len()` bytes or fails (tar headers and pax records are fixed-shape).
fn read_exact(reader: &mut Box<dyn Read>, mut buf: &mut [u8]) -> Result<(), String> {
    while !buf.is_empty() {
        match reader.read(buf).map_err(|e| e.to_string())? {
            0 => return Err("truncated tar stream".into()),
            n => {
                buf = &mut buf[n..];
            }
        }
    }
    Ok(())
}

fn octal(field: &[u8]) -> Result<u64, String> {
    let text = std::str::from_utf8(field)
        .map_err(|_| "tar header is not ASCII".to_string())?
        .trim_matches(|c| c == '\0' || c == ' ');
    if text.is_empty() {
        return Ok(0);
    }
    u64::from_str_radix(text.trim_start_matches('0').max("0"), 8).map_err(|_| format!("bad tar number {:?}", text))
}

fn nul_str(field: &[u8]) -> String {
    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
    String::from_utf8_lossy(&field[..end]).to_string()
}

/// Advances `next` (0) past the previous entry's remainder.
fn discard(reader: &mut Box<dyn Read>, mut n: u64) -> Result<(), String> {
    let mut buf = vec![0u8; 64 << 10];
    while n > 0 {
        let take = (n as usize).min(buf.len());
        let k = reader.read(&mut buf[..take]).map_err(|e| e.to_string())?;
        if k == 0 {
            return Err("truncated tar stream".into());
        }
        n -= k as u64;
    }
    Ok(())
}

/// Steps the tar walker to the next member; reports it through the out-params.
#[allow(clippy::too_many_arguments)]
fn tar_next(
    reader: &mut Box<dyn Read>,
    remaining: &mut u64,
    pad: &mut u64,
    ended: &mut bool,
    pending_name: &mut Option<String>,
    name_out: *mut u8,
    name_cap: usize,
    name_len: *mut usize,
    size_out: *mut u64,
    dir_out: *mut u8,
) -> Result<i32, String> {
    if *remaining + *pad > 0 {
        discard(reader, *remaining + *pad)?;
        *remaining = 0;
        *pad = 0;
    }
    loop {
        let mut head = [0u8; 512];
        match reader.read(&mut head).map_err(|e| e.to_string())? {
            0 => {
                *ended = true;
                return Ok(0);
            }
            n if n < 512 => {
                let mut rest = &mut head[n..];
                while !rest.is_empty() {
                    match reader.read(rest).map_err(|e| e.to_string())? {
                        0 => return Err("truncated tar stream".into()),
                        k => rest = &mut rest[k..],
                    }
                }
            }
            _ => {}
        }
        if head.iter().all(|&b| b == 0) {
            *ended = true;
            return Ok(0);
        }
        let mut name = nul_str(&head[..100]);
        if &head[257..262] == b"ustar" {
            let prefix = nul_str(&head[345..500]);
            if !prefix.is_empty() {
                name = format!("{}/{}", prefix, name);
            }
        }
        let size = octal(&head[124..136])?;
        let flag = head[156];
        // GNU long name / pax extended header: the data names the next entry.
        if flag == b'L' || flag == b'K' || flag == b'x' || flag == b'g' {
            let mut data = vec![0u8; size as usize];
            read_exact(reader, &mut data)?;
            let skip = (512 - size % 512) % 512;
            if skip > 0 {
                discard(reader, skip)?;
            }
            if flag == b'L' || flag == b'K' {
                *pending_name = Some(nul_str(&data));
            } else {
                // Pax records: `len key=value\n`; `path=` renames the next entry.
                for line in String::from_utf8_lossy(&data).split('\n') {
                    if let Some((_, kv)) = line.split_once(' ') {
                        if let Some(path) = kv.strip_prefix("path=") {
                            *pending_name = Some(path.to_string());
                        }
                    }
                }
            }
            continue;
        }
        if let Some(next) = pending_name.take() {
            name = next;
        }
        let dir = flag == b'5' || name.ends_with('/');
        *remaining = if dir || flag == b'1' || flag == b'2' { 0 } else { size };
        *pad = if *remaining == 0 { 0 } else { (512 - size % 512) % 512 };
        let bytes = name.as_bytes();
        if bytes.len() > name_cap {
            return Err(format!("entry name needs {} bytes, buffer holds {}", bytes.len(), name_cap));
        }
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), name_out, bytes.len());
            *name_len = bytes.len();
            *size_out = size;
            *dir_out = u8::from(dir);
        }
        return Ok(1);
    }
}

/// Advances to the next entry: 1 with the entry reported, 0 at the end.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_next(
    h: Handle,
    name_out: *mut u8,
    name_cap: usize,
    name_len: *mut usize,
    size_out: *mut u64,
    dir_out: *mut u8,
) -> i32 {
    guard(|| {
        let session = live::<Stepper>(h)?;
        if matches!(session, Stepper::Indexed { .. }) {
            let (mname, msize, mdir, idx) = match session {
                Stepper::Indexed { metas, pos, .. } => {
                    if *pos >= metas.len() {
                        return Ok(0);
                    }
                    let meta = &metas[*pos];
                    (meta.name.clone(), meta.size, meta.dir, *pos)
                }
                _ => unreachable!(),
            };
            let bytes = indexed_bytes(session, idx)?;
            let name = mname.as_bytes();
            if name.len() > name_cap {
                return Err(format!("entry name needs {} bytes, buffer holds {}", name.len(), name_cap));
            }
            unsafe {
                std::ptr::copy_nonoverlapping(name.as_ptr(), name_out, name.len());
                *name_len = name.len();
                *size_out = msize;
                *dir_out = u8::from(mdir);
            }
            match session {
                Stepper::Indexed { buf, at, pos, .. } => {
                    *buf = bytes;
                    *at = 0;
                    *pos = idx + 1;
                }
                _ => unreachable!(),
            }
            Ok(1)
        } else {
            let Stepper::TarLive { reader, remaining, pad, ended, pending_name, .. } = session else {
                unreachable!()
            };
            if *ended {
                return Ok(0);
            }
            tar_next(reader, remaining, pad, ended, pending_name, name_out, name_cap, name_len, size_out, dir_out)
        }
    })
}

/// Streams the current entry's bytes into `buf` (at most `cap`); 0 at the entry's end.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_entry_read(h: Handle, buf: *mut u8, cap: usize) -> i32 {
    guard(|| {
        let session = live::<Stepper>(h)?;
        let cap = cap.min(i32::MAX as usize);
        let out = bytes_mut(buf, cap);
        match session {
            Stepper::Indexed { buf, at, .. } => {
                let left = buf.len() - *at;
                let n = left.min(cap);
                out[..n].copy_from_slice(&buf[*at..*at + n]);
                *at += n;
                Ok(n as i32)
            }
            Stepper::TarLive { reader, remaining, .. } => {
                if *remaining == 0 {
                    return Ok(0);
                }
                let n = (*remaining as usize).min(cap);
                let mut got = 0;
                while got < n {
                    match reader.read(&mut out[got..n]).map_err(|e| e.to_string())? {
                        0 => return Err("truncated tar stream".into()),
                        k => got += k,
                    }
                }
                *remaining -= got as u64;
                Ok(got as i32)
            }
        }
    })
}

/// Releases the stepper.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_free(h: Handle) {
    if !h.is_null() {
        drop(Box::from_raw(h as *mut Stepper));
    }
}

// ---- in-memory packer (new in native2)

/// An in-memory archive under construction.
struct Packer {
    format: u32,
    level: i32,
    entries: Vec<(String, Vec<u8>)>,
}

/// Starts an in-memory `format` archive (`ZIP`, `TAR`, `TAR_GZ`); `level` as in `create`.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_pack_create(format: u32, level: i32) -> Handle {
    let mut out = std::ptr::null_mut();
    let code = guard(|| {
        match format {
            ZIP | TAR | TAR_GZ => {}
            _ => return Err(format!("packer writes zip, tar or tar.gz, not format {}", format)),
        }
        validate_archive_level(format, level)?;
        out = Box::into_raw(Box::new(Packer { format, level, entries: Vec::new() })) as Handle;
        Ok(0)
    });
    if code < 0 {
        return std::ptr::null_mut();
    }
    out
}

/// Adds `name` with `data` to the packer. Names are stored verbatim — even empty,
/// absolute, NUL-holding or escaping ones, which exist to be refused at unpack, never at pack.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_pack_add(h: Handle, name: *const u8, nlen: usize, data: *const u8, len: usize) -> i32 {
    guard(|| {
        let packer = live::<Packer>(h)?;
        packer.entries.push((text(name, nlen)?.to_string(), bytes(data, len).to_vec()));
        Ok(0)
    })
}

/// Releases an unfinished packer. A finished one is already gone: `pack_finish` consumes it.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_pack_free(h: Handle) {
    if !h.is_null() {
        drop(Box::from_raw(h as *mut Packer));
    }
}

/// Finishes the archive into `out` (freed with `tk_free`) and releases the packer.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_pack_finish(h: Handle, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        live::<Packer>(h)?;
        let packer = *Box::from_raw(h as *mut Packer);
        let mut buf = Vec::new();
        match packer.format {
            ZIP => {
                let mut w = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
                for (name, data) in &packer.entries {
                    let method = if packer.level == 0 { zip::CompressionMethod::Stored } else { zip::CompressionMethod::Deflated };
                    let opts = zip::write::SimpleFileOptions::default()
                        .compression_method(method)
                        .compression_level(if packer.level <= 0 { None } else { Some(packer.level as i64) })
                        .large_file(true);
                    w.start_file(name, opts).map_err(|e| e.to_string())?;
                    w.write_all(data).map_err(|e| e.to_string())?;
                }
                w.finish().map_err(|e| e.to_string())?;
            }
            _ => {
                let codec = if packer.format == TAR_GZ { Some(GZIP) } else { None };
                let mut b = tar::Builder::new(encoder(codec, &mut buf, packer.level, 0)?);
                for (name, data) in &packer.entries {
                    let mut header = tar::Header::new_gnu();
                    header.set_size(data.len() as u64);
                    header.set_mode(0o644);
                    header.set_cksum();
                    b.append_data(&mut header, name, &data[..]).map_err(|e| e.to_string())?;
                }
                b.into_inner().map_err(|e| e.to_string())?;
            }
        }
        Ok(give(buf, out, out_len))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 64 MiB tar.xz create must abort promptly once the stop byte is set.
    #[test]
    fn stop_byte_aborts_a_big_create() {
        let dir = std::env::temp_dir().join(format!("n2_stop_{}", std::process::id()));
        std::fs::create_dir_all(dir.join("src")).unwrap();
        let chunk = vec![7u8; 1 << 20];
        for i in 0..4 {
            std::fs::write(dir.join(format!("src/f{}.bin", i)), &chunk).unwrap();
        }
        let (src, out) = (dir.join("src"), dir.join("b.tar.xz"));
        let flag: &'static std::sync::atomic::AtomicU8 =
            Box::leak(Box::new(std::sync::atomic::AtomicU8::new(0)));
        let stopper = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(500));
            flag.store(1, std::sync::atomic::Ordering::Relaxed);
        });
        let start = std::time::Instant::now();
        let rc = unsafe {
            tk_archive_create(
                TAR_XZ,
                src.as_os_str().as_encoded_bytes().as_ptr(),
                src.as_os_str().len(),
                out.as_os_str().as_encoded_bytes().as_ptr(),
                out.as_os_str().len(),
                out.as_os_str().as_encoded_bytes().as_ptr(),
                out.as_os_str().len(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                9,
                None,
                &flag as *const _ as *const u8,
            )
        };
        let _ = stopper.join();
        eprintln!("stopped create rc={} after {:?}", rc, start.elapsed());
        assert!(rc < 0, "create ignored the stop byte");
        assert!(start.elapsed() < std::time::Duration::from_secs(25));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn glob_wants() {
        let yes = |p: &str, n: &str| assert!(match_glob(p, n, false), "{} should match {}", p, n);
        let no = |p: &str, n: &str| assert!(!match_glob(p, n, false), "{} should not match {}", p, n);
        yes("**/*.dart", "a/b/c.dart");
        yes("**/*.dart", "c.dart");
        yes("a/*.dart", "a/x.dart");
        no("a/*.dart", "a/b/x.dart");
        no("*.dart", "a/x.dart");
        yes("a/?.dart", "a/x.dart");
        yes("a/[x-z].dart", "a/x.dart");
        no("a/[x-z].dart", "a/w.dart");
        yes("**/*.{dart,txt}", "a/b.txt");
        yes("src/**", "src/a/b/c");
        no("src/**", "other/a");
        assert!(match_glob("A/*.DART", "a/x.dart", true));
        assert!(!match_glob("A/*.DART", "a/x.dart", false));
    }

    #[test]
    fn sandbox_refusals() {
        let root = Path::new("/tmp/root");
        assert!(inside(root, "a/b.txt").is_ok());
        assert!(inside(root, "../out").is_err());
        assert!(inside(root, "/abs").is_err());
        assert!(inside(root, "a/../../out").is_err());
        assert!(escapes("a/b", "/abs").is_err());
        assert!(escapes("a/b", "../out").is_ok());
        assert!(escapes("a/b", "../../out").is_err());
        assert!(escapes("b", "../out").is_err());
        assert!(escapes("a/b", "c").is_ok());
        assert!(escapes("a/b", "../a/c").is_ok());
    }

    #[test]
    fn record_layout_round_trip() {
        let e = Entry { name: "sub/b.bin".to_string(), size: 50000, compressed: 1234, dir: false, encrypted: true, link: true, modified: Some(1700000000) };
        let mut buf = Vec::new();
        record(&e, &mut buf);
        assert_eq!(buf.len(), 29 + 9);
        assert_eq!(u64::from_le_bytes(buf[0..8].try_into().unwrap()), 50000);
        assert_eq!(u64::from_le_bytes(buf[8..16].try_into().unwrap()), 1234);
        assert_eq!(i64::from_le_bytes(buf[16..24].try_into().unwrap()), 1700000000);
        assert_eq!(buf[24], 1 | 4);
        assert_eq!(u32::from_le_bytes(buf[25..29].try_into().unwrap()), 9);
        assert_eq!(&buf[29..], b"sub/b.bin");
    }

    #[test]
    fn stepper_walks_a_packed_tar_gz() {
        let dir = std::env::temp_dir().join(format!("n2_step_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("b.tar.gz").to_string_lossy().to_string();
        // Pack two members in memory, then write the bytes out for the stepper.
        let h = unsafe { tk_archive_pack_create(TAR_GZ, 6) };
        assert!(!h.is_null());
        let (n1, d1) = ("a.txt", b"hello archive".as_slice());
        let (n2, d2) = ("sub/b.bin", &[7u8; 1000]);
        assert_eq!(unsafe { tk_archive_pack_add(h, n1.as_ptr(), n1.len(), d1.as_ptr(), d1.len()) }, 0);
        assert_eq!(unsafe { tk_archive_pack_add(h, n2.as_ptr(), n2.len(), d2.as_ptr(), d2.len()) }, 0);
        let (mut ptr, mut len) = (std::ptr::null_mut(), 0usize);
        assert_eq!(unsafe { tk_archive_pack_finish(h, &mut ptr, &mut len) }, 0);
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len).to_vec() };
        unsafe { tk_common::free(ptr, len) };
        std::fs::write(&path, &bytes).unwrap();
        // Step it: names, sizes, then streamed bytes.
        let s = unsafe { tk_archive_open(path.as_ptr(), path.len(), std::ptr::null(), 0, 0) };
        assert!(!s.is_null());
        let mut names = Vec::new();
        let mut total = Vec::new();
        loop {
            let mut name = vec![0u8; 256];
            let (mut nlen, mut size, mut dir) = (0usize, 0u64, 0u8);
            let rc = unsafe { tk_archive_next(s, name.as_mut_ptr(), name.len(), &mut nlen, &mut size, &mut dir) };
            assert!(rc >= 0);
            if rc == 0 {
                break;
            }
            names.push(String::from_utf8_lossy(&name[..nlen]).to_string());
            let mut data = Vec::new();
            loop {
                let mut chunk = vec![0u8; 100];
                let n = unsafe { tk_archive_entry_read(s, chunk.as_mut_ptr(), chunk.len()) };
                assert!(n >= 0);
                if n == 0 {
                    break;
                }
                data.extend_from_slice(&chunk[..n as usize]);
            }
            total.push(data);
        }
        unsafe { tk_archive_free(s) };
        assert_eq!(names, ["a.txt", "sub/b.bin"]);
        assert_eq!(total[0], b"hello archive");
        assert_eq!(total[1], vec![7u8; 1000]);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}


// __PART6__
