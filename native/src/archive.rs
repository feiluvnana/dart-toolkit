//! Archives and compressed streams, by file path: the file system is the transport.

use crate::{create_file, give, guard, opt_text, pump, read_file, text, Msg};
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

/// Stream codecs for `tk_compress` / `tk_decompress`.
const GZIP: u32 = 0;
const XZ: u32 = 1;
const ZSTD: u32 = 2;
const BZIP2: u32 = 3;
/// `tk_decompress` codec meaning "read the file's magic number".
const DETECT: u32 = u32::MAX;

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
    let mut buf = vec![0u8; n];
    match File::open(path) {
        Ok(f) => {
            let mut r = BufReader::new(f);
            let mut filled = 0;
            while filled < n {
                match r.read(&mut buf[filled..]) {
                    Ok(0) | Err(_) => break,
                    Ok(k) => filled += k,
                }
            }
            buf.truncate(filled);
            buf
        }
        Err(_) => Vec::new(),
    }
}

/// The container format of the bytes themselves, when they say so without ambiguity.
///
/// A magic number outranks the file name: an archive keeps its format when it is renamed,
/// downloaded without an extension or saved as `.bin`. The single-stream codecs are not
/// here because they are ambiguous — a gzip member holds a tar or any other single file —
/// and are resolved by `detect_read` after the extension has had its say.
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

fn zip_open(path: &str) -> Result<zip::ZipArchive<File>, String> {
    zip::ZipArchive::new(read_file(path)?).msg()
}

fn tar_reader(path: &str, kind: &str) -> Result<Box<dyn Read>, String> {
    let f = BufReader::new(read_file(path)?);
    Ok(match kind {
        "tar" => Box::new(f),
        "tar.gz" => Box::new(flate2::read::MultiGzDecoder::new(f)),
        "tar.xz" => Box::new(xz2::read::XzDecoder::new_multi_decoder(f)),
        "tar.zst" => Box::new(zstd::stream::read::Decoder::new(f).msg()?),
        "tar.bz2" => Box::new(bzip2::read::MultiBzDecoder::new(f)),
        _ => unreachable!(),
    })
}

fn tar_writer(path: &str, format: u32, level: i32) -> Result<Box<dyn Write>, String> {
    let f = BufWriter::new(create_file(path)?);
    let lvl = |d: u32| if level < 0 { d } else { level as u32 };
    Ok(match format {
        TAR => Box::new(f),
        TAR_GZ => Box::new(flate2::write::GzEncoder::new(f, flate2::Compression::new(lvl(6)))),
        TAR_XZ => Box::new(xz2::write::XzEncoder::new(f, lvl(6))),
        TAR_ZST => Box::new(zstd::stream::write::Encoder::new(f, if level < 0 { 3 } else { level }).msg()?.auto_finish()),
        TAR_BZ2 => Box::new(bzip2::write::BzEncoder::new(f, bzip2::Compression::new(lvl(9)))),
        _ => unreachable!(),
    })
}

// ---------------------------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------------------------

fn list(path: &str, password: Option<&str>) -> Result<Vec<Entry>, String> {
    let kind = detect_read(path)?;
    let mut out = Vec::new();
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            for i in 0..z.len() {
                let f = z.by_index_raw(i).msg()?;
                out.push(Entry {
                    name: f.name().to_string(),
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
            for f in &reader.archive().files {
                out.push(Entry {
                    name: f.name().to_string(),
                    size: f.size(),
                    compressed: f.compressed_size,
                    dir: f.is_directory(),
                    encrypted: false,
                    modified: if f.has_last_modified_date { Some(f.last_modified_date().to_unix_time_secs()) } else { None },
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

/// Writes the entries of the archive at `path` as a JSON array; the caller frees with `tk_free`.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_list(path: *const u8, plen: usize, pw: *const u8, pwlen: usize, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let entries = list(text(path, plen)?, opt_text(pw, pwlen)?)?;
        Ok(give(serde_json::to_vec(&entries).msg()?, out, out_len))
    })
}

// ---------------------------------------------------------------------------------------------
// extract
// ---------------------------------------------------------------------------------------------

/// `flags` bit: the archive is trusted — no size cap, setuid/setgid kept, links may point anywhere.
const TRUSTED: u32 = 1;
/// `flags` bit: `only` matches without regard to case, as the platform's own paths do.
const FOLD_CASE: u32 = 2;

/// What an untrusted archive may write: 200 times its own size, and never less than 1 GiB.
///
/// A ratio rather than a fixed number, because a fixed number is either too small for a large
/// legitimate archive or too large to stop a small bomb; the floor keeps a tiny archive of a
/// compressible file from tripping it. Source trees, logs and dumps compress 5–50×.
const RATIO: u64 = 200;
const FLOOR: u64 = 1 << 30;

/// How an extraction is allowed to go: what it may write, which entries it wants, and the
/// links it made, which are checked again once everything they could point at exists.
struct Policy {
    trusted: bool,
    budget: u64,
    limit: u64,
    only: Option<Vec<char>>,
    fold: bool,
    root: PathBuf,
    links: Vec<PathBuf>,
    /// Directories already found to be inside `root`. A directory stays one — `link` never
    /// replaces a directory — so a hit needs no second look until a link is made.
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
            root: root.canonicalize().map_err(|e| format!("{}: {}", root.display(), e))?,
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
                 extract with trusted: true if that is expected",
                name, self.limit, RATIO
            ));
        }
        self.budget -= size;
        Ok(())
    }

    /// `dir` is inside the destination once links are resolved. Asked of every directory an
    /// entry lands in, not only once this extraction has made a link: a link already in the
    /// destination — left by an earlier archive — leads out just as well.
    fn contains(&mut self, dir: &Path) -> Result<(), String> {
        if self.trusted || self.checked.contains(dir) {
            return Ok(());
        }
        match resolve(dir, 0) {
            Some(real) if real.starts_with(&self.root) => {
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

    /// Checks every link again now that everything it could point through exists: a link to
    /// `b/..` is inside by its text and outside once `b` turns out to be a link to `.`. A
    /// link whose target does not exist is followed as far as it goes, since whatever is
    /// written through it later lands where it points.
    fn finish(&self) -> Result<(), String> {
        if self.trusted {
            return Ok(());
        }
        let mut first_err = None;
        for link in &self.links {
            if !resolve(link, 0).is_some_and(|real| real.starts_with(&self.root)) {
                let _ = std::fs::remove_file(link);
                if first_err.is_none() {
                    first_err = Some(format!("{}: link leads out of the destination", link.display()));
                }
            }
        }
        if let Some(err) = first_err {
            return Err(err);
        }
        Ok(())
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
    copy_capped(from, &mut w, size, name)?;
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

/// A zip entry's time as a Unix time. A zip stores the wall-clock time where it was made, with
/// no zone, and every tool from `unzip` to Explorer reads it as local time; read as UTC it came
/// out hours off, and only this library's own archives round-tripped.
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

// Windows has no prebuilt yet; there the stamp is read and written as UTC, as it was before.
#[cfg(not(unix))]
fn zip_to_unix(d: zip::DateTime) -> Option<i64> {
    time::OffsetDateTime::try_from(d).ok().map(|t| t.unix_timestamp())
}
#[cfg(not(unix))]
fn unix_to_zip(secs: i64) -> Option<zip::DateTime> {
    time::OffsetDateTime::from_unix_timestamp(secs).ok()?.try_into().ok()
}

fn seven_err(m: String) -> sevenz_rust2::Error {
    sevenz_rust2::Error::other(m)
}

fn extract(path: &str, dest: &str, password: Option<&str>, only: Option<&str>, flags: u32) -> Result<i32, String> {
    let kind = detect_read(path)?;
    let root = Path::new(dest);
    std::fs::create_dir_all(root).msg()?;
    let mut pol = Policy::new(path, root, only, flags)?;
    let mut count = 0;
    match kind {
        "zip" => {
            let mut z = zip_open(path)?;
            for i in 0..z.len() {
                let mut f = match password {
                    Some(pw) => z.by_index_decrypt(i, pw.as_bytes()).msg()?,
                    None => z.by_index(i).msg()?,
                };
                let name = f.name().to_string();
                let target = inside(root, &name)?;
                if !pol.wants(&name) {
                    continue;
                }
                if f.is_dir() {
                    pol.contains(&target)?;
                    std::fs::create_dir_all(&target).msg()?;
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
                count += 1;
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
            reader
                .for_each_entries(|e, r| {
                    let name = e.name().to_string();
                    if !pol.wants(&name) {
                        // A solid block is one stream: an entry not wanted is still read past.
                        std::io::copy(r, &mut std::io::sink()).map_err(sevenz_rust2::Error::io)?;
                        return Ok(true);
                    }
                    let target = inside(root, &name).map_err(seven_err)?;
                    if e.is_directory() {
                        pol.contains(&target).map_err(seven_err)?;
                        std::fs::create_dir_all(&target).map_err(sevenz_rust2::Error::io)?;
                        return Ok(true);
                    }
                    let mtime = if e.has_last_modified_date { Some(e.last_modified_date().to_unix_time_secs()) } else { None };
                    write_file(&mut pol, &target, r, e.size(), &name, mtime, None).map_err(seven_err)?;
                    count += 1;
                    Ok(true)
                })
                .msg()?;
        }
        "rar" => {
            let mut a = rar(path, password).open_for_processing().msg()?;
            while let Some(h) = a.read_header().msg()? {
                let name = h.entry().filename.to_string_lossy().to_string();
                let target = inside(root, &name)?;
                if !pol.wants(&name) {
                    a = h.skip().msg()?;
                    continue;
                }
                let is_file = h.entry().is_file();
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
                    count += 1;
                }
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            // Without it the crate keeps the permission bits and drops setuid, setgid, sticky.
            t.set_preserve_permissions(pol.trusted);
            t.set_preserve_mtime(true);
            for e in t.entries().msg()? {
                let mut e = e.msg()?;
                let name = e.path().msg()?.to_string_lossy().to_string();
                let target = inside(root, &name)?;
                if !pol.wants(&name) {
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
                if e.unpack_in(root).msg()? && kind.is_file() {
                    count += 1;
                }
            }
        }
    }
    pol.finish()?;
    Ok(count)
}

/// Extracts the archive at `path` into `dest`; returns the number of files written.
///
/// `only`, when not null, is a glob the entry names must match. `flags` is `TRUSTED` and
/// `FOLD_CASE`. An untrusted archive may write at most `RATIO` times its size (at least
/// `FLOOR`), loses setuid, setgid and sticky, and may not make a link that leads out.
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
) -> i32 {
    guard(|| extract(text(path, plen)?, text(dest, dlen)?, opt_text(pw, pwlen)?, opt_text(only, olen)?, flags))
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
            let mut f = match password {
                Some(pw) => z.by_name_decrypt(&want, pw.as_bytes()),
                None => z.by_name(&want),
            }
            .map_err(|e| match e {
                zip::result::ZipError::FileNotFound => missing(),
                e => e.to_string(),
            })?;
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
) -> i32 {
    guard(|| {
        let data = read_entry(text(path, plen)?, text(name, nlen)?, opt_text(pw, pwlen)?, flags)?;
        Ok(give(data, out, out_len))
    })
}

// ---------------------------------------------------------------------------------------------
// create
// ---------------------------------------------------------------------------------------------

/// Files under `src` (or `src` itself) as (relative name, path, is_dir), sorted, without
/// `dest`: an archive written inside the tree it archives would otherwise contain itself.
fn walk(src: &Path, dest: &Path) -> Result<Vec<(String, PathBuf, bool)>, String> {
    let mut out = Vec::new();
    if src.is_file() {
        out.push((src.file_name().unwrap().to_string_lossy().to_string(), src.to_path_buf(), false));
        return Ok(out);
    }
    // The destination's name relative to the source, when it lands inside it.
    let own = match (src.canonicalize(), dest.parent().and_then(|p| p.canonicalize().ok())) {
        (Ok(s), Some(d)) => dest.file_name().and_then(|n| d.join(n).strip_prefix(&s).ok().map(|r| r.to_path_buf())),
        _ => None,
    };
    for entry in walkdir::WalkDir::new(src).min_depth(1).follow_links(false).sort_by_file_name() {
        let entry = entry.msg()?;
        let relative = entry.path().strip_prefix(src).msg()?;
        if own.as_deref() == Some(relative) {
            continue;
        }
        let rel = relative.to_string_lossy().replace('\\', "/");
        let is_dir = entry.file_type().is_dir();
        // Symlinks are skipped on purpose: an archive may be extracted anywhere, and a
        // link pointing out of the tree is the same hazard `inside` exists to stop.
        if entry.file_type().is_symlink() {
            continue;
        }
        out.push((rel, entry.path().to_path_buf(), is_dir));
    }
    Ok(out)
}

fn create(format: u32, src: &str, dest: &str, password: Option<&str>, level: i32) -> Result<i32, String> {
    let src_path = Path::new(src);
    if let Some(p) = Path::new(dest).parent() {
        std::fs::create_dir_all(p).msg()?;
    }
    let items = walk(src_path, Path::new(dest))?;
    let files = items.iter().filter(|i| !i.2).count() as i32;
    match format {
        ZIP => {
            let mut w = zip::ZipWriter::new(BufWriter::new(create_file(dest)?));
            for (name, path, is_dir) in &items {
                let mut opts = zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Deflated)
                    .compression_level(if level < 0 { None } else { Some(level as i64) })
                    .large_file(true);
                if let Ok(meta) = std::fs::metadata(path) {
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
                if *is_dir {
                    w.add_directory(name, opts).msg()?;
                } else {
                    w.start_file(name, opts).msg()?;
                    pump(BufReader::new(read_file(path.to_str().ok_or("bad path")?)?), &mut w)?;
                }
            }
            w.finish().msg()?;
        }
        SEVENZ => {
            // From the same walk as zip and tar: the crate's own directory walk runs after the
            // destination exists, and archived a truncated copy of it into itself.
            let mut z = sevenz_rust2::SevenZWriter::new(create_file(dest)?).msg()?;
            if let Some(pw) = password {
                z.set_content_methods(vec![
                    sevenz_rust2::AesEncoderOptions::new(sevenz_rust2::Password::from(pw)).into(),
                    sevenz_rust2::SevenZMethod::LZMA2.into(),
                ]);
            }
            for (name, path, is_dir) in &items {
                let entry = sevenz_rust2::SevenZArchiveEntry::from_path(path, name.clone());
                let reader = if *is_dir { None } else { Some(BufReader::new(read_file(path.to_str().ok_or("bad path")?)?)) };
                z.push_archive_entry(entry, reader).msg()?;
            }
            z.finish().msg()?;
        }
        TAR | TAR_GZ | TAR_XZ | TAR_ZST | TAR_BZ2 => {
            if password.is_some() {
                return Err("tar has no encryption; use zip or 7z".into());
            }
            let mut b = tar::Builder::new(tar_writer(dest, format, level)?);
            b.follow_symlinks(false);
            for (name, path, is_dir) in &items {
                if *is_dir {
                    b.append_dir(name, path).msg()?;
                } else {
                    b.append_path_with_name(path, name).msg()?;
                }
            }
            let mut inner = b.into_inner().msg()?;
            inner.flush().msg()?;
        }
        _ => return Err(format!("unknown archive format {}", format)),
    }
    Ok(files)
}

/// Archives `src` (a file or directory) into `dest`; returns the number of files added.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_create(format: u32, src: *const u8, slen: usize, dest: *const u8, dlen: usize, pw: *const u8, pwlen: usize, level: i32) -> i32 {
    guard(|| create(format, text(src, slen)?, text(dest, dlen)?, opt_text(pw, pwlen)?, level))
}

// ---------------------------------------------------------------------------------------------
// single streams
// ---------------------------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn tk_compress(codec: u32, src: *const u8, slen: usize, dest: *const u8, dlen: usize, level: i32) -> i32 {
    guard(|| {
        let input = BufReader::new(read_file(text(src, slen)?)?);
        let out = BufWriter::new(create_file(text(dest, dlen)?)?);
        let lvl = |d: u32| if level < 0 { d } else { level as u32 };
        match codec {
            GZIP => pump(input, flate2::write::GzEncoder::new(out, flate2::Compression::new(lvl(6))))?,
            XZ => pump(input, xz2::write::XzEncoder::new(out, lvl(6)))?,
            ZSTD => pump(input, zstd::stream::write::Encoder::new(out, if level < 0 { 3 } else { level }).msg()?.auto_finish())?,
            BZIP2 => pump(input, bzip2::write::BzEncoder::new(out, bzip2::Compression::new(lvl(9))))?,
            _ => return Err(format!("unknown codec {}", codec)),
        }
        Ok(0)
    })
}

fn decompress(codec: u32, path: &str, dest: &str, flags: u32) -> Result<i32, String> {
    let codec = if codec == DETECT {
        sniff_codec(path).ok_or_else(|| format!("{}: not a gzip, xz, zstd or bzip2 stream", path))?
    } else {
        codec
    };
    let pol = Policy::new(path, Path::new("."), None, flags)?;
    let input = BufReader::new(read_file(path)?);
    let mut decoder: Box<dyn Read> = match codec {
        GZIP => Box::new(flate2::read::MultiGzDecoder::new(input)),
        XZ => Box::new(xz2::read::XzDecoder::new_multi_decoder(input)),
        ZSTD => Box::new(zstd::stream::read::Decoder::new(input).msg()?),
        BZIP2 => Box::new(bzip2::read::MultiBzDecoder::new(input)),
        _ => return Err(format!("unknown codec {}", codec)),
    };
    let mut out = BufWriter::new(create_file(dest)?);
    let copied = std::io::copy(&mut (&mut decoder).take(pol.limit.saturating_add(1)), &mut out)
        .and_then(|n| out.flush().map(|_| n))
        .msg();
    let result = match copied {
        Ok(n) if n > pol.limit => Err(format!(
            "{}: decompresses to more than {} bytes, {}× the file and at least 1 GiB; decompress with trusted: true if that is expected",
            path, pol.limit, RATIO
        )),
        Ok(_) => Ok(0),
        Err(e) => Err(e),
    };
    if result.is_err() {
        drop(out);
        let _ = std::fs::remove_file(dest);
    }
    result
}

/// Decompresses the single stream at `src` into `dest`; `codec` `DETECT` reads the magic
/// number. `flags` is `TRUSTED`; otherwise the output is capped as `tk_archive_extract`'s is,
/// and a stream that passes the cap leaves no file behind.
#[no_mangle]
pub unsafe extern "C" fn tk_decompress(codec: u32, src: *const u8, slen: usize, dest: *const u8, dlen: usize, flags: u32) -> i32 {
    guard(|| decompress(codec, text(src, slen)?, text(dest, dlen)?, flags))
}
