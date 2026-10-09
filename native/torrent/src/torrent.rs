//! BitTorrent client sessions through librqbit: one tokio runtime for the library, one session
//! per `tk_torrent_session_new`; options, stats and file lists cross as JSON.
//!
//! The calls that wait on the network (adding a magnet, waiting for completion, reading a
//! stream) take a callback: they return a ticket at once, and the callback gets the result from
//! a runtime thread (a Dart `NativeCallable.listener`); `tk_torrent_cancel(ticket)` stops one.
//! Stats and controls return at once.

use tk_common::{bytes, give, guard, text, Msg};
use librqbit::{
    api::TorrentIdOrHash, limits::LimitsConfig, AddTorrent, AddTorrentOptions, AddTorrentResponse,
    ConnectionOptions, ListenerMode, ListenerOptions, ManagedTorrent, Session, SessionOptions,
    SessionPersistenceConfig,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::c_void;
use std::future::Future;
use std::net::SocketAddr;
use std::num::NonZeroU32;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeek, AsyncSeekExt};

/// The runtime every session and stream runs on; built on first use, never torn down.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("tk-torrent")
            .build()
            .expect("tokio runtime")
    })
}

/// Where a result goes: the code (a count or an id; negative is an error), and bytes the caller
/// frees with `tk_free`: the data, or the error message.
type Done = extern "C" fn(code: i64, data: *mut u8, len: usize);

/// The calls still running, by ticket. Whoever takes a ticket out, the task finishing or
/// `tk_torrent_cancel`, decides: the callback runs exactly when the task took it.
fn pending() -> &'static Mutex<HashMap<u64, tokio::task::AbortHandle>> {
    static P: OnceLock<Mutex<HashMap<u64, tokio::task::AbortHandle>>> = OnceLock::new();
    P.get_or_init(Default::default)
}

/// [work]: with no [done], run here and returned (its bytes through [out]); else spawned under
/// a fresh ticket, which is returned, and its result handed to [done] unless cancelled first.
fn run(
    done: Option<Done>,
    out: Option<(*mut *mut u8, *mut usize)>,
    work: impl Future<Output = Result<(i64, Vec<u8>), String>> + Send + 'static,
) -> Result<i64, String> {
    let Some(done) = done else {
        let (code, data) = runtime().block_on(work)?;
        if let Some((p, l)) = out {
            give(data, p, l);
        }
        return Ok(code);
    };
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let ticket = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut table = pending().lock().unwrap();
    let task = runtime().spawn(async move {
        let result = work.await;
        if pending().lock().unwrap().remove(&ticket).is_none() {
            return; // cancelled: the caller stopped listening
        }
        let (code, data) = match result {
            Ok(ok) => ok,
            Err(m) => (-1, m.into_bytes()),
        };
        let (mut p, mut l) = (std::ptr::null_mut(), 0usize);
        give(data, &mut p, &mut l);
        done(code, p, l);
    });
    table.insert(ticket, task.abort_handle());
    Ok(ticket as i64)
}

/// Stops the call behind [ticket]: 1 when it will never call back, 0 when its result is
/// already on the way.
#[no_mangle]
pub extern "C" fn tk_torrent_cancel(ticket: u64) -> i32 {
    match pending().lock().unwrap().remove(&ticket) {
        Some(task) => {
            task.abort();
            1
        }
        None => 0,
    }
}

/// anyhow's error with its whole context chain: `adding torrent: tracker refused: …`.
fn chain(e: anyhow::Error) -> String {
    format!("{e:#}")
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SessionOpts {
    folder: String,
    port: Option<u16>,
    dht: bool,
    upnp: bool,
    lsd: bool,
    utp: bool,
    trackers: Vec<String>,
    download_bps: Option<u32>,
    upload_bps: Option<u32>,
    state: Option<String>,
    proxy: Option<String>,
    blocklist: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct AddOpts {
    folder: Option<String>,
    files: Option<Vec<usize>>,
    paused: bool,
    peers: Option<Vec<SocketAddr>>,
    trackers: Option<Vec<String>>,
    max_peers: Option<usize>,
}

fn limits(down: Option<u32>, up: Option<u32>) -> LimitsConfig {
    LimitsConfig {
        download_bps: down.and_then(NonZeroU32::new),
        upload_bps: up.and_then(NonZeroU32::new),
    }
}

unsafe fn session<'a>(h: *mut c_void) -> Result<&'a Arc<Session>, String> {
    (h as *const Arc<Session>)
        .as_ref()
        .ok_or_else(|| "torrent session is closed".to_string())
}

/// The engine's index of file [index] when the BEP 47 padding files are not counted, as the
/// caller counts them: the engine counts every file, [padding] says which are padding.
fn engine_index(padding: &[bool], index: usize) -> Result<usize, String> {
    padding
        .iter()
        .enumerate()
        .filter(|(_, p)| !**p)
        .nth(index)
        .map(|(i, _)| i)
        .ok_or_else(|| format!("no file {index} in this torrent"))
}

/// [engine_index] for a torrent whose metadata is in.
fn engine_file(t: &ManagedTorrent, index: usize) -> Result<usize, String> {
    let padding: Vec<bool> = t
        .with_metadata(|m| m.file_infos.iter().map(|f| f.attrs.padding).collect())
        .map_err(chain)?;
    engine_index(&padding, index)
}

fn torrent(s: &Session, id: u64) -> Result<Arc<ManagedTorrent>, String> {
    s.get(TorrentIdOrHash::Id(id as usize))
        .ok_or_else(|| format!("no torrent {id} in this session"))
}

#[no_mangle]
pub unsafe extern "C" fn tk_torrent_session_new(opts: *const u8, len: usize) -> *mut c_void {
    let mut out: *mut c_void = std::ptr::null_mut();
    guard(|| {
        let _in = runtime().enter();
        let o: SessionOpts = serde_json::from_str(text(opts, len)?).msg()?;
        let state = o.state.map(PathBuf::from);
        let options = SessionOptions {
            dht: o.dht.then(Default::default),
            disable_trackers: false,
            fastresume: state.is_some(),
            persistence: state.map(|folder| SessionPersistenceConfig::Json {
                folder: Some(folder),
            }),
            listen: Some(ListenerOptions {
                mode: if o.utp {
                    ListenerMode::TcpAndUtp
                } else {
                    ListenerMode::TcpOnly
                },
                listen_addr: (std::net::Ipv6Addr::UNSPECIFIED, o.port.unwrap_or(0)).into(),
                enable_upnp_port_forwarding: o.upnp,
                ..Default::default()
            }),
            connect: Some(ConnectionOptions {
                proxy_url: o.proxy,
                ..Default::default()
            }),
            ratelimits: limits(o.download_bps, o.upload_bps),
            blocklist_url: o.blocklist,
            trackers: o.trackers.iter().filter_map(|t| t.parse().ok()).collect(),
            disable_local_service_discovery: !o.lsd,
            ..Default::default()
        };
        let s = runtime()
            .block_on(Session::new_with_opts(PathBuf::from(o.folder), options))
            .map_err(chain)?;
        out = Box::into_raw(Box::new(s)) as *mut c_void;
        Ok(0)
    });
    out
}

/// Stops the session's torrents and tasks and frees it. `Session::stop` pauses each torrent
/// (without recording the pause, so a restored one runs) and cancels the tasks in its first
/// poll, then sleeps a second for them; the zero timeout polls it once and skips the sleep.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_session_free(h: *mut c_void) {
    if h.is_null() {
        return;
    }
    guard(|| {
        // In the runtime, where the session's last reference is dropped too.
        let _in = runtime().enter();
        let s = Box::from_raw(h as *mut Arc<Session>);
        let _ = runtime().block_on(tokio::time::timeout(std::time::Duration::ZERO, s.stop()));
        Ok(0)
    });
}

/// The ids of the session's torrents, restored ones included, as a JSON list.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_list(
    h: *mut c_void,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        let ids: Vec<usize> = session(h)?.with_torrents(|all| all.map(|(id, _)| id).collect());
        Ok(give(serde_json::to_vec(&ids).msg()?, out_ptr, out_len))
    })
}

/// The TCP port the session listens on, or 0.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_port(h: *mut c_void) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        Ok(session(h)?.listen_addr().map_or(0, |a| a.port() as i32))
    })
}

/// Adds a torrent: [source] is a `.torrent`'s bytes when [is_file] is 1, else a magnet or
/// URL. Its id comes once a magnet's metadata has arrived (see [`run`]).
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_add(
    h: *mut c_void,
    source: *const u8,
    slen: usize,
    is_file: u32,
    opts: *const u8,
    olen: usize,
    done: Option<Done>,
) -> i64 {
    let mut id = -1i64;
    guard(|| {
        let _in = runtime().enter();
        let s = session(h)?.clone();
        let o: AddOpts = serde_json::from_str(text(opts, olen)?).msg()?;
        let add = if is_file == 1 {
            AddTorrent::from_bytes(bytes(source, slen).to_vec())
        } else {
            AddTorrent::from_url(text(source, slen)?.to_string())
        };
        id = run(done, None, async move {
            let mut peers = o.peers.unwrap_or_default();
            let mut only = o.files;
            let mut add = add;
            let mut folder = None;
            if let Some(to) = o.folder {
                // The metadata first, a magnet's from peers: a torrent of several files goes into
                // `to/<name>`, as into the client's own folder.
                let listed = AddTorrentOptions {
                    list_only: true,
                    initial_peers: Some(peers.clone()),
                    trackers: o.trackers.clone(),
                    ..Default::default()
                };
                match s.add_torrent(add, Some(listed)).await.map_err(chain)? {
                    AddTorrentResponse::AlreadyManaged(id, _) => {
                        return Ok((id as i64, Vec::new()))
                    }
                    AddTorrentResponse::ListOnly(l) => {
                        let padding: Vec<bool> =
                            l.info.iter_file_details().map(|f| f.attrs().padding).collect();
                        if let Some(files) = only.take() {
                            only = Some(
                                files
                                    .into_iter()
                                    .map(|i| engine_index(&padding, i))
                                    .collect::<Result<_, _>>()?,
                            );
                        }
                        let several = padding.iter().filter(|p| !**p).nth(1).is_some();
                        let name = l.info.name().map(|n| n.to_string()).filter(|n| {
                            !n.is_empty()
                                && Path::new(n)
                                    .components()
                                    .all(|c| matches!(c, Component::Normal(_)))
                        });
                        folder = Some(match (several, name) {
                            (true, Some(n)) => Path::new(&to).join(n),
                            _ => PathBuf::from(&to),
                        });
                        add = AddTorrent::from_bytes(l.torrent_bytes);
                        // The peers that sent a magnet's metadata, so the add asks no one twice.
                        peers.extend(l.seen_peers);
                    }
                    AddTorrentResponse::Added(..) => {
                        return Err("the torrent started while being listed".into())
                    }
                }
            }
            let options = AddTorrentOptions {
                paused: o.paused,
                only_files: only,
                overwrite: true,
                output_folder: folder.map(|f| f.to_string_lossy().into_owned()),
                initial_peers: Some(peers),
                trackers: o.trackers,
                peer_limit: o.max_peers,
                ..Default::default()
            };
            let res = s.add_torrent(add, Some(options)).await.map_err(chain)?;
            let handle = res.into_handle().ok_or("the torrent was only listed")?;
            Ok((handle.id() as i64, Vec::new()))
        })?;
        Ok(0)
    });
    id
}

#[derive(Serialize)]
struct Info<'a> {
    name: Option<String>,
    info_hash: String,
    folder: &'a std::path::Path,
    files: Vec<(String, u64)>,
}

/// The torrent's name, info hash, output folder and files (`[path, size]`, padding files left
/// out), as JSON.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_info(
    h: *mut c_void,
    id: u64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        let t = torrent(session(h)?, id)?;
        let files = t
            .with_metadata(|m| {
                m.file_infos
                    .iter()
                    .filter(|f| !f.attrs.padding)
                    .map(|f| {
                        (
                            f.relative_filename.to_string_lossy().replace('\\', "/"),
                            f.len,
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        let info = Info {
            name: t.name(),
            info_hash: t.info_hash().as_string(),
            folder: t.output_folder(),
            files,
        };
        Ok(give(serde_json::to_vec(&info).msg()?, out_ptr, out_len))
    })
}

/// The torrent's `.torrent` bytes, as it was added or as its metadata came from peers: what
/// keeps its info hash.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_metainfo(
    h: *mut c_void,
    id: u64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        let t = torrent(session(h)?, id)?;
        let data = t.with_metadata(|m| m.torrent_bytes.to_vec()).map_err(chain)?;
        Ok(give(data, out_ptr, out_len))
    })
}

/// The torrent's live statistics (librqbit's `TorrentStats`), as JSON.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_stats(
    h: *mut c_void,
    id: u64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        let t = torrent(session(h)?, id)?;
        Ok(give(
            serde_json::to_vec(&t.stats()).msg()?,
            out_ptr,
            out_len,
        ))
    })
}

/// 0 pauses, 1 resumes, 2 removes the torrent, 3 removes it and deletes its files.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_control(h: *mut c_void, id: u64, op: u32) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        let s = session(h)?;
        let t = torrent(s, id)?;
        runtime()
            .block_on(async {
                match op {
                    0 => s.pause(&t).await,
                    1 => s.unpause(&t).await,
                    2 | 3 => s.delete(TorrentIdOrHash::Id(id as usize), op == 3).await,
                    _ => Err(anyhow::anyhow!("unknown torrent control {op}")),
                }
            })
            .map_err(chain)?;
        Ok(0)
    })
}

/// Downloads only the files whose indices [files] (a JSON list, padding files not counted) holds.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_select(
    h: *mut c_void,
    id: u64,
    files: *const u8,
    len: usize,
) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        let s = session(h)?;
        let t = torrent(s, id)?;
        let wanted: Vec<usize> = serde_json::from_str(text(files, len)?).msg()?;
        let only = wanted
            .into_iter()
            .map(|i| engine_file(&t, i))
            .collect::<Result<std::collections::HashSet<usize>, _>>()?;
        runtime()
            .block_on(s.update_only_files(&t, &only))
            .map_err(chain)?;
        Ok(0)
    })
}

/// Sets the session's download and upload limits in bytes per second; 0 is none.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_limits(h: *mut c_void, down: u32, up: u32) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        let s = session(h)?;
        s.ratelimits.set_download_bps(NonZeroU32::new(down));
        s.ratelimits.set_upload_bps(NonZeroU32::new(up));
        Ok(0)
    })
}

/// Until every selected file of the torrent is downloaded and checked (see [`run`]).
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_wait(h: *mut c_void, id: u64, done: Option<Done>) -> i64 {
    let mut code = -1i64;
    guard(|| {
        let _in = runtime().enter();
        let t = torrent(session(h)?, id)?;
        code = run(done, None, async move {
            t.wait_until_completed().await.map_err(chain)?;
            Ok((0, Vec::new()))
        })?;
        Ok(0)
    });
    code
}

/// What librqbit's file stream is, which it does not export by name.
trait Source: AsyncRead + AsyncSeek + Unpin + Send {}
impl<T: AsyncRead + AsyncSeek + Unpin + Send> Source for T {}

/// A reader over one file of a torrent, fetching the pieces it reaches first. Shared with the
/// read in flight, so freeing it while one runs is safe.
type Reader = Arc<tokio::sync::Mutex<Box<dyn Source>>>;

#[no_mangle]
pub unsafe extern "C" fn tk_torrent_stream_open(h: *mut c_void, id: u64, file: u64) -> *mut c_void {
    let mut out: *mut c_void = std::ptr::null_mut();
    guard(|| {
        let _in = runtime().enter();
        let t = torrent(session(h)?, id)?;
        let file = engine_file(&t, file as usize)?;
        let stream = runtime().block_on(t.stream(file)).map_err(chain)?;
        let reader: Reader = Arc::new(tokio::sync::Mutex::new(Box::new(stream)));
        out = Box::into_raw(Box::new(reader)) as *mut c_void;
        Ok(0)
    });
    out
}

unsafe fn reader(r: *mut c_void) -> Result<Reader, String> {
    (r as *const Reader)
        .as_ref()
        .cloned()
        .ok_or_else(|| "stream is closed".to_string())
}

/// Up to [cap] bytes from the reader's position: the count, and the bytes (see [`run`]); 0
/// at the end of the file.
#[no_mangle]
pub unsafe extern "C" fn tk_torrent_stream_read(
    r: *mut c_void,
    cap: usize,
    done: Option<Done>,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i64 {
    let mut n = -1i64;
    guard(|| {
        let _in = runtime().enter();
        let r = reader(r)?;
        n = run(done, Some((out_ptr, out_len)), async move {
            let mut buf = vec![0u8; cap];
            let got = r.lock().await.read(&mut buf).await.msg()?;
            buf.truncate(got);
            Ok((got as i64, buf))
        })?;
        Ok(0)
    });
    n
}

#[no_mangle]
pub unsafe extern "C" fn tk_torrent_stream_seek(r: *mut c_void, at: u64) -> i32 {
    guard(|| {
        let _in = runtime().enter();
        let r = reader(r)?;
        runtime()
            .block_on(async { r.lock().await.seek(std::io::SeekFrom::Start(at)).await })
            .msg()?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_torrent_stream_free(r: *mut c_void) {
    if !r.is_null() {
        let _in = runtime().enter();
        drop(Box::from_raw(r as *mut Reader));
    }
}
