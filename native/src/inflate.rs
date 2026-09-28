//! Streaming decompression for HTTP `content-encoding`.
//!
//! A response body arrives in pieces and is decoded in pieces: one handle per body, fed the
//! bytes as they come off the socket and drained of whatever they decoded to. That is the
//! whole difference between this and `tk_decompress`, whose two ends are files — a body is
//! neither a file nor something that has to fit in memory before it can be read.
//!
//! **Output is bounded per call.** A 16 KiB zstd body can decode to half a gigabyte, and a
//! decoder that emits everything a push produces hands that half gigabyte over in one
//! allocation. Every call here writes at most its capacity and keeps the rest of its input
//! pending; a call that fills its capacity is followed by another with no input, until one
//! returns less.
//!
//! **An early end is an error.** A body cut off mid-stream decodes to a prefix that looks like
//! any other; `tk_inflate_finish` asks the decoder whether its stream actually ended.
//!
//! Codec codes are the Dart `_Encoding` enum's: 1 gzip, 3 brotli, 4 zstd. (2 was a `deflate`
//! nothing asked for, and whose end cannot be told from a truncation.)

use crate::{bytes, bytes_mut, guard, set_error, Handle, Msg};
use brotli::writer::StandardAlloc;
use brotli::{BrotliDecompressStream, BrotliResult, BrotliState};
use std::cell::RefCell;
use std::io::Write;
use std::rc::Rc;
use zstd::stream::raw::{InBuffer, Operation, OutBuffer};

const GZIP: u32 = 1;
const BROTLI: u32 = 3;
const ZSTD: u32 = 4;

/// What flate2's write-side decoders emit into, and what a call drains from.
///
/// Those decoders produce at most their 32 KiB internal buffer per `write`, so feeding them
/// one `write` at a time and stopping when the caller's capacity is reached bounds what sits
/// here to that capacity plus one buffer.
#[derive(Clone, Default)]
struct Sink(Rc<RefCell<(Vec<u8>, usize)>>);

impl Write for Sink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.borrow_mut().0.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Sink {
    /// Moves what is buffered into `out`; returns how much.
    fn drain_into(&self, out: &mut [u8]) -> usize {
        let mut s = self.0.borrow_mut();
        let (buf, off) = &mut *s;
        let n = (buf.len() - *off).min(out.len());
        out[..n].copy_from_slice(&buf[*off..*off + n]);
        *off += n;
        if *off == buf.len() {
            buf.clear();
            *off = 0;
        }
        n
    }
}

enum Codec {
    Flate { decoder: Box<flate2::write::MultiGzDecoder<Sink>>, sink: Sink, flushed: bool },
    Brotli { state: Box<BrotliState<StandardAlloc, StandardAlloc, StandardAlloc>>, done: bool },
    /// `hint` is the decoder's last answer: 0 once a frame is decoded and flushed.
    Zstd { decoder: Box<zstd::stream::raw::Decoder<'static>>, hint: usize },
}

struct Inflater {
    codec: Codec,
    input: Vec<u8>,
    pos: usize,
    /// Whether any input arrived: an empty body has nothing to be truncated.
    fed: bool,
}

impl Inflater {
    fn new(codec: u32) -> Result<Self, String> {
        let sink = Sink::default();
        let codec = match codec {
            GZIP => Codec::Flate { decoder: Box::new(flate2::write::MultiGzDecoder::new(sink.clone())), sink, flushed: true },
            BROTLI => Codec::Brotli {
                state: Box::new(BrotliState::new(StandardAlloc::default(), StandardAlloc::default(), StandardAlloc::default())),
                done: false,
            },
            ZSTD => Codec::Zstd { decoder: Box::new(zstd::stream::raw::Decoder::new().msg()?), hint: 0 },
            _ => return Err(format!("unknown content-encoding codec {}", codec)),
        };
        Ok(Inflater { codec, input: Vec::new(), pos: 0, fed: false })
    }

    fn feed(&mut self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        if self.pos > 0 {
            self.input.drain(..self.pos);
            self.pos = 0;
        }
        self.input.extend_from_slice(data);
        self.fed = true;
        if let Codec::Flate { flushed, .. } = &mut self.codec {
            *flushed = false;
        }
    }

    /// Decodes pending input into `out`, at most its length; returns how much was written.
    fn fill(&mut self, out: &mut [u8]) -> Result<usize, String> {
        let mut written = 0;
        match &mut self.codec {
            Codec::Flate { decoder, sink, flushed } => loop {
                written += sink.drain_into(&mut out[written..]);
                if written == out.len() {
                    break;
                }
                if self.pos < self.input.len() {
                    let n = decoder.write(&self.input[self.pos..]).msg()?;
                    if n == 0 {
                        return Err("data after the end of the compressed stream".into());
                    }
                    self.pos += n;
                } else if !*flushed {
                    decoder.flush().msg()?;
                    *flushed = true;
                } else {
                    break;
                }
            },
            Codec::Zstd { decoder, hint } => {
                while written < out.len() {
                    let mut inb = InBuffer::around(&self.input[self.pos..]);
                    let mut outb = OutBuffer::around(&mut out[written..]);
                    *hint = decoder.run(&mut inb, &mut outb).map_err(|e| format!("zstd: {}", e))?;
                    let (consumed, produced) = (inb.pos(), outb.pos());
                    self.pos += consumed;
                    written += produced;
                    // Out of input with room to spare means the decoder has nothing left.
                    if consumed == 0 && produced == 0 || self.pos == self.input.len() && written < out.len() {
                        break;
                    }
                }
            }
            Codec::Brotli { state, done } => {
                while !*done && written < out.len() {
                    let mut avail_in = self.input.len() - self.pos;
                    let mut in_off = self.pos;
                    let mut avail_out = out.len() - written;
                    let mut out_off = written;
                    let mut total = 0;
                    let r = BrotliDecompressStream(
                        &mut avail_in,
                        &mut in_off,
                        &self.input,
                        &mut avail_out,
                        &mut out_off,
                        out,
                        &mut total,
                        state,
                    );
                    self.pos = in_off;
                    written = out_off;
                    match r {
                        BrotliResult::ResultFailure => return Err("brotli: corrupt stream".into()),
                        BrotliResult::NeedsMoreInput => break,
                        BrotliResult::NeedsMoreOutput => continue,
                        BrotliResult::ResultSuccess => {
                            *done = true;
                            self.pos = self.input.len();
                        }
                    }
                }
            }
        }
        Ok(written)
    }

    /// Whether the stream ended where the body did, once every byte of it has been drained.
    fn finish(&mut self) -> Result<(), String> {
        if !self.fed {
            return Ok(());
        }
        let (complete, name) = match &mut self.codec {
            // It checks the trailer's CRC and length, so a cut anywhere is caught.
            Codec::Flate { decoder, .. } => (decoder.try_finish().is_ok(), "gzip"),
            Codec::Brotli { done, .. } => (*done, "brotli"),
            Codec::Zstd { hint, .. } => (*hint == 0, "zstd"),
        };
        if complete {
            Ok(())
        } else {
            Err(format!("the body ended before its {} stream did", name))
        }
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

/// Pushes `len` bytes and decodes into the caller's `out`, at most `cap`; returns how many
/// bytes were written. Nothing is allocated per call: the caller keeps one input and one
/// output buffer for the life of the handle. A return of exactly `cap` means more is
/// pending: call again with no bytes until it is less.
#[no_mangle]
pub unsafe extern "C" fn tk_inflate_into(h: Handle, ptr: *const u8, len: usize, out: *mut u8, cap: usize) -> i32 {
    if h.is_null() {
        set_error("inflate handle is null");
        return -1;
    }
    guard(|| {
        let inflater = &mut *(h as *mut Inflater);
        inflater.feed(bytes(ptr, len));
        let cap = cap.min(i32::MAX as usize);
        Ok(inflater.fill(bytes_mut(out, cap))? as i32)
    })
}

/// Returns 0 when the stream the handle was fed ended properly, or -1 when the body stopped
/// short of it. Called once, after the last `tk_inflate_into` has drained everything.
#[no_mangle]
pub unsafe extern "C" fn tk_inflate_finish(h: Handle) -> i32 {
    if h.is_null() {
        set_error("inflate handle is null");
        return -1;
    }
    guard(|| {
        (*(h as *mut Inflater)).finish()?;
        Ok(0)
    })
}

/// Releases the handle. A decoder emits everything it has as it goes, so there is no tail to
/// ask for first; whether the stream was whole is `tk_inflate_finish`'s question.
#[no_mangle]
pub unsafe extern "C" fn tk_inflate_free(h: Handle) {
    if !h.is_null() {
        drop(Box::from_raw(h as *mut Inflater));
    }
}
