//! Archives and compressed streams, by file path: the file system is the transport.

use crate::{create_file, give, guard, opt_text, pump, read_file, text};
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

#[derive(serde::Serialize)]
struct Entry {
    name: String,
    size: u64,
    compressed: u64,
    dir: bool,
    encrypted: bool,
    modified: Option<i64>,
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

fn tar_reader(path: &str, kind: &str) -> Result<Box<dyn Read>, String> {
    let f = BufReader::new(read_file(path)?);
    Ok(match kind {
        "tar" => Box::new(f),
        "tar.gz" => Box::new(flate2::read::MultiGzDecoder::new(f)),
        "tar.xz" => Box::new(xz2::read::XzDecoder::new_multi_decoder(f)),
        "tar.zst" => Box::new(zstd::stream::read::Decoder::new(f).map_err(|e| e.to_string())?),
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
        TAR_ZST => Box::new(zstd::stream::write::Encoder::new(f, if level < 0 { 3 } else { level }).map_err(|e| e.to_string())?.auto_finish()),
        TAR_BZ2 => Box::new(bzip2::write::BzEncoder::new(f, bzip2::Compression::new(lvl(9)))),
        _ => unreachable!(),
    })
}

// ---------------------------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------------------------

fn list(path: &str, password: Option<&str>) -> Result<Vec<Entry>, String> {
    let kind = detect(path)?;
    let mut out = Vec::new();
    match kind {
        "zip" => {
            let mut z = zip::ZipArchive::new(read_file(path)?).map_err(|e| e.to_string())?;
            for i in 0..z.len() {
                let f = z.by_index_raw(i).map_err(|e| e.to_string())?;
                out.push(Entry {
                    name: f.name().to_string(),
                    size: f.size(),
                    compressed: f.compressed_size(),
                    dir: f.is_dir(),
                    encrypted: f.encrypted(),
                    modified: f.last_modified().and_then(|d| time::OffsetDateTime::try_from(d).ok()).map(|t| t.unix_timestamp()),
                });
            }
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            let reader = sevenz_rust2::SevenZReader::open(path, pw).map_err(|e| e.to_string())?;
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
            let a = match password {
                Some(pw) => unrar::Archive::with_password(path, pw),
                None => unrar::Archive::new(path),
            };
            let mut a = a.open_for_listing().map_err(|e| e.to_string())?;
            while let Some(h) = a.read_header().map_err(|e| e.to_string())? {
                let e = h.entry();
                out.push(Entry {
                    name: e.filename.to_string_lossy().to_string(),
                    size: e.unpacked_size,
                    compressed: e.unpacked_size,
                    dir: e.is_directory(),
                    encrypted: e.is_encrypted(),
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
        Ok(give(serde_json::to_vec(&entries).map_err(|e| e.to_string())?, out, out_len))
    })
}

// ---------------------------------------------------------------------------------------------
// extract
// ---------------------------------------------------------------------------------------------

fn set_mtime(path: &Path, secs: Option<i64>) {
    if let Some(s) = secs {
        let t = std::time::UNIX_EPOCH + std::time::Duration::from_secs(s.max(0) as u64);
        let _ = filetime_set(path, t);
    }
}

fn filetime_set(path: &Path, t: std::time::SystemTime) -> std::io::Result<()> {
    let f = File::options().write(true).open(path)?;
    f.set_modified(t)
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: Option<u32>) {
    use std::os::unix::fs::PermissionsExt;
    if let Some(m) = mode {
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(m & 0o7777));
    }
}
#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: Option<u32>) {}

fn extract(path: &str, dest: &str, password: Option<&str>) -> Result<i32, String> {
    let kind = detect(path)?;
    let root = Path::new(dest);
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let mut count = 0;
    match kind {
        "zip" => {
            let mut z = zip::ZipArchive::new(read_file(path)?).map_err(|e| e.to_string())?;
            for i in 0..z.len() {
                let mut f = match password {
                    Some(pw) => z.by_index_decrypt(i, pw.as_bytes()).map_err(|e| e.to_string())?,
                    None => z.by_index(i).map_err(|e| e.to_string())?,
                };
                let target = inside(root, f.name())?;
                if f.is_dir() {
                    std::fs::create_dir_all(&target).map_err(|e| e.to_string())?;
                    continue;
                }
                let mode = f.unix_mode();
                let mtime = f.last_modified().and_then(|d| time::OffsetDateTime::try_from(d).ok()).map(|t| t.unix_timestamp());
                pump(&mut f, BufWriter::new(create_file(target.to_str().ok_or("bad path")?)?))?;
                set_mode(&target, mode);
                set_mtime(&target, mtime);
                count += 1;
            }
        }
        "7z" => {
            let pw = sevenz_rust2::Password::from(password.unwrap_or(""));
            sevenz_rust2::decompress_file_with_password(path, dest, pw).map_err(|e| e.to_string())?;
            count = list(path, password)?.iter().filter(|e| !e.dir).count() as i32;
        }
        "rar" => {
            let a = match password {
                Some(pw) => unrar::Archive::with_password(path, pw),
                None => unrar::Archive::new(path),
            };
            let mut a = a.open_for_processing().map_err(|e| e.to_string())?;
            while let Some(h) = a.read_header().map_err(|e| e.to_string())? {
                inside(root, &h.entry().filename.to_string_lossy())?;
                let is_file = h.entry().is_file();
                a = h.extract_with_base(dest).map_err(|e| e.to_string())?;
                if is_file {
                    count += 1;
                }
            }
        }
        _ => {
            let mut t = tar::Archive::new(tar_reader(path, kind)?);
            t.set_preserve_permissions(true);
            t.set_preserve_mtime(true);
            for e in t.entries().map_err(|e| e.to_string())? {
                let mut e = e.map_err(|e| e.to_string())?;
                let name = e.path().map_err(|e| e.to_string())?.to_string_lossy().to_string();
                inside(root, &name)?;
                if e.unpack_in(root).map_err(|e| e.to_string())? && e.header().entry_type().is_file() {
                    count += 1;
                }
            }
        }
    }
    Ok(count)
}

/// Extracts the archive at `path` into `dest`; returns the number of files written.
#[no_mangle]
pub unsafe extern "C" fn tk_archive_extract(path: *const u8, plen: usize, dest: *const u8, dlen: usize, pw: *const u8, pwlen: usize) -> i32 {
    guard(|| extract(text(path, plen)?, text(dest, dlen)?, opt_text(pw, pwlen)?))
}

// ---------------------------------------------------------------------------------------------
// create
// ---------------------------------------------------------------------------------------------

/// Files under `src` (or `src` itself) as (relative name, path), sorted.
fn walk(src: &Path) -> Result<Vec<(String, PathBuf, bool)>, String> {
    let mut out = Vec::new();
    if src.is_file() {
        out.push((src.file_name().unwrap().to_string_lossy().to_string(), src.to_path_buf(), false));
        return Ok(out);
    }
    for entry in walkdir::WalkDir::new(src).min_depth(1).follow_links(false).sort_by_file_name() {
        let entry = entry.map_err(|e| e.to_string())?;
        let rel = entry.path().strip_prefix(src).map_err(|e| e.to_string())?.to_string_lossy().replace('\\', "/");
        let is_dir = entry.file_type().is_dir();
        if entry.file_type().is_symlink() {
            continue;
        }
        out.push((rel, entry.path().to_path_buf(), is_dir));
    }
    Ok(out)
}

fn create(format: u32, src: &str, dest: &str, password: Option<&str>, level: i32) -> Result<i32, String> {
    let src_path = Path::new(src);
    let items = walk(src_path)?;
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
                    if let Ok(m) = meta.modified() {
                        if let Ok(t) = time::OffsetDateTime::from(m).try_into() {
                            opts = opts.last_modified_time(t);
                        }
                    }
                }
                if let Some(pw) = password {
                    opts = opts.with_aes_encryption(zip::AesMode::Aes256, pw);
                }
                if *is_dir {
                    w.add_directory(name, opts).map_err(|e| e.to_string())?;
                } else {
                    w.start_file(name, opts).map_err(|e| e.to_string())?;
                    pump(BufReader::new(read_file(path.to_str().ok_or("bad path")?)?), &mut w)?;
                }
            }
            w.finish().map_err(|e| e.to_string())?;
        }
        SEVENZ => {
            let dest_path = Path::new(dest);
            if let Some(p) = dest_path.parent() {
                std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
            }
            match password {
                Some(pw) => sevenz_rust2::compress_to_path_encrypted(src_path, dest_path, sevenz_rust2::Password::from(pw)).map_err(|e| e.to_string())?,
                None => sevenz_rust2::compress_to_path(src_path, dest_path).map_err(|e| e.to_string())?,
            }
        }
        TAR | TAR_GZ | TAR_XZ | TAR_ZST | TAR_BZ2 => {
            if password.is_some() {
                return Err("tar has no encryption; use zip or 7z".into());
            }
            let mut b = tar::Builder::new(tar_writer(dest, format, level)?);
            b.follow_symlinks(false);
            for (name, path, is_dir) in &items {
                if *is_dir {
                    b.append_dir(name, path).map_err(|e| e.to_string())?;
                } else {
                    b.append_path_with_name(path, name).map_err(|e| e.to_string())?;
                }
            }
            let mut inner = b.into_inner().map_err(|e| e.to_string())?;
            inner.flush().map_err(|e| e.to_string())?;
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
            ZSTD => pump(input, zstd::stream::write::Encoder::new(out, if level < 0 { 3 } else { level }).map_err(|e| e.to_string())?.auto_finish())?,
            BZIP2 => pump(input, bzip2::write::BzEncoder::new(out, bzip2::Compression::new(lvl(9))))?,
            _ => return Err(format!("unknown codec {}", codec)),
        }
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_decompress(codec: u32, src: *const u8, slen: usize, dest: *const u8, dlen: usize) -> i32 {
    guard(|| {
        let input = BufReader::new(read_file(text(src, slen)?)?);
        let out = BufWriter::new(create_file(text(dest, dlen)?)?);
        match codec {
            GZIP => pump(flate2::read::MultiGzDecoder::new(input), out)?,
            XZ => pump(xz2::read::XzDecoder::new_multi_decoder(input), out)?,
            ZSTD => pump(zstd::stream::read::Decoder::new(input).map_err(|e| e.to_string())?, out)?,
            BZIP2 => pump(bzip2::read::MultiBzDecoder::new(input), out)?,
            _ => return Err(format!("unknown codec {}", codec)),
        }
        Ok(0)
    })
}
