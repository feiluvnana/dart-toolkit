//! Streaming decompression for HTTP `content-encoding`.
//!
//! A response body arrives in pieces and is decoded in pieces: one handle per body, fed the
//! bytes as they come off the socket and drained of whatever they decoded to. That is the
//! whole difference between this and `tk_decompress`, whose two ends are files — a body is
//! neither a file nor something that has to fit in memory before it can be read.
//!
//! Codec codes are the Dart `_Encoding` enum's order: 1 gzip, 2 deflate, 3 brotli, 4 zstd.

use crate::{bytes, give, guard, set_error, Handle};
use std::cell::RefCell;
use std::io::Write;
use std::rc::Rc;

const GZIP: u32 = 1;
const DEFLATE: u32 = 2;
const BROTLI: u32 = 3;
const ZSTD: u32 = 4;

/// The buffer every decoder writes into, shared with the handle that drains it.
///
/// Each decoder crate has its own way of handing back the writer it wraps, and one of them
/// hands it back only by consuming itself. Giving all four the same shared buffer instead
/// means the handle never has to ask a decoder for anything but `write`.
#[derive(Clone, Default)]
struct Sink(Rc<RefCell<Vec<u8>>>);

impl Write for Sink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.borrow_mut().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

struct Inflater {
    out: Sink,
    decoder: Box<dyn Write>,
}

impl Inflater {
    fn new(codec: u32) -> Result<Self, String> {
        let out = Sink::default();
        let decoder: Box<dyn Write> = match codec {
            GZIP => Box::new(flate2::write::MultiGzDecoder::new(out.clone())),
            DEFLATE => Box::new(flate2::write::ZlibDecoder::new(out.clone())),
            BROTLI => Box::new(brotli::DecompressorWriter::new(out.clone(), 8192)),
            ZSTD => Box::new(zstd::stream::write::Decoder::new(out.clone()).map_err(|e| e.to_string())?),
            _ => return Err(format!("unknown content-encoding codec {}", codec)),
        };
        Ok(Inflater { out, decoder })
    }

    /// Feeds `data` in and takes out whatever it decoded to, which may be nothing.
    fn push(&mut self, data: &[u8]) -> Result<Vec<u8>, String> {
        if !data.is_empty() {
            self.decoder.write_all(data).map_err(|e| e.to_string())?;
        }
        self.decoder.flush().map_err(|e| e.to_string())?;
        Ok(std::mem::take(&mut *self.out.0.borrow_mut()))
    }
}

#[no_mangle]
pub extern "C" fn tk_inflate_new(codec: u32) -> Handle {
    match Inflater::new(codec) {
        Ok(inflater) => Box::into_raw(Box::new(inflater)) as Handle,
        Err(message) => {
            set_error(&message);
            std::ptr::null_mut()
        }
    }
}

/// Pushes `len` bytes and writes the decoded run into a Rust allocation the caller frees with
/// `tk_free`; returns its length, which is often zero while a decoder fills its window.
#[no_mangle]
pub unsafe extern "C" fn tk_inflate_push(
    h: Handle,
    ptr: *const u8,
    len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if h.is_null() {
        set_error("inflate handle is null");
        return -1;
    }
    guard(|| {
        let decoded = (*(h as *mut Inflater)).push(bytes(ptr, len))?;
        Ok(give(decoded, out, out_len))
    })
}

/// Releases the handle. A decoder emits everything it has as it goes, so there is no tail to
/// ask for first — an early end is a truncated body, not a lost one.
#[no_mangle]
pub unsafe extern "C" fn tk_inflate_free(h: Handle) {
    if !h.is_null() {
        drop(Box::from_raw(h as *mut Inflater));
    }
}
