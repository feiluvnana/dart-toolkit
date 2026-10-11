//! Streaming decompression for HTTP `content-encoding`, rewritten.
//!
//! One handle per body, fed bytes as they arrive off the socket and drained of what they
//! decoded to. Output is bounded per call: a small body can decode to gigabytes, so a call
//! writes at most its capacity and keeps the rest pending; a call that fills it is followed
//! by another with no input, until one returns less. An early end is an error: finish asks
//! the decoder whether its stream ended. Codec codes are the Dart `_Encoding` enum's:
//! 1 gzip, 3 brotli, 4 zstd.

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

/// What flate2's write-side decoders emit into and a call drains from. They produce at most
/// 32 KiB per `write`, so this holds at most the caller's capacity plus that.
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
    /// Moves what is buffered into `out`; answers how much.
    fn drain_into(&self, out: &mut [u8]) -> usize {
        let mut held = self.0.borrow_mut();
        let (buf, off) = &mut *held;
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
            GZIP => Codec::Flate {
                decoder: Box::new(flate2::write::MultiGzDecoder::new(sink.clone())),
                sink,
                flushed: true,
            },
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
        if self.pos == self.input.len() {
            self.input.clear();
            self.pos = 0;
        } else if self.pos > 32768 && self.pos >= self.input.len() / 2 {
            self.input.drain(..self.pos);
            self.pos = 0;
        }
        self.input.extend_from_slice(data);
        self.fed = true;
        if let Codec::Flate { flushed, .. } = &mut self.codec {
            *flushed = false;
        }
    }

    /// Decodes pending input into `out`, at most its length; answers how much was written.
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
                    // A completed frame stays completed: running the decoder again would turn
                    // it toward a following concatenated frame and lose the completion.
                    if self.pos == self.input.len() && *hint == 0 {
                        break;
                    }
                    let mut incoming = InBuffer::around(&self.input[self.pos..]);
                    let mut outgoing = OutBuffer::around(&mut out[written..]);
                    *hint = decoder.run(&mut incoming, &mut outgoing).map_err(|e| format!("zstd: {}", e))?;
                    let (consumed, produced) = (incoming.pos(), outgoing.pos());
                    self.pos += consumed;
                    written += produced;
                    // Out of input with room to spare: the decoder has nothing left.
                    if consumed == 0 && produced == 0 || self.pos == self.input.len() && written < out.len() {
                        break;
                    }
                }
            },
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
            },
        }
        Ok(written)
    }

    /// Whether the stream ended where the body did, once every byte has been drained.
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

/// Pushes `len` bytes and decodes into `out`, at most `cap`; answers how many were written.
/// Exactly `cap` means more is pending: call again with no bytes until it is less.
#[no_mangle]
pub unsafe extern "C" fn tk_inflate_into(h: Handle, ptr: *const u8, len: usize, out: *mut u8, cap: usize) -> i32 {
    guard(|| {
        let inflater = crate::live::<Inflater>(h)?;
        inflater.feed(bytes(ptr, len));
        let cap = cap.min(i32::MAX as usize);
        Ok(inflater.fill(bytes_mut(out, cap))? as i32)
    })
}

/// Answers 0 when the fed stream ended properly, -1 when the body stopped short of it.
/// Called once, after the last `tk_inflate_into` has drained everything.
#[no_mangle]
pub unsafe extern "C" fn tk_inflate_finish(h: Handle) -> i32 {
    guard(|| {
        crate::live::<Inflater>(h)?.finish()?;
        Ok(0)
    })
}

/// Releases the handle; whether the stream was whole is `tk_inflate_finish`'s question.
#[no_mangle]
pub unsafe extern "C" fn tk_inflate_free(h: Handle) {
    if !h.is_null() {
        drop(Box::from_raw(h as *mut Inflater));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn err() -> String {
        let mut buf = vec![0u8; 1024];
        let n = unsafe { tk_common::last_error(buf.as_mut_ptr(), buf.len()) };
        String::from_utf8_lossy(&buf[..n.max(0) as usize]).to_string()
    }

    fn round_trip(codec: u32, data: &[u8]) -> Vec<u8> {
        let h = tk_inflate_new(codec);
        assert!(!h.is_null(), "new: {}", err());
        let mut collected = Vec::new();
        let mut out = vec![0u8; 65536];
        for chunk in data.chunks(7) {
            let n = unsafe { tk_inflate_into(h, chunk.as_ptr(), chunk.len(), out.as_mut_ptr(), out.len()) };
            if n < 0 {
                eprintln!("codec {} into failed: {}", codec, err());
            }
            assert!(n >= 0);
            collected.extend_from_slice(&out[..n as usize]);
        }
        // Drain anything pending with no input.
        loop {
            let n = unsafe { tk_inflate_into(h, std::ptr::null(), 0, out.as_mut_ptr(), out.len()) };
            if n < 0 {
                eprintln!("codec {} drain failed: {}", codec, err());
            }
            assert!(n >= 0);
            if n == 0 {
                break;
            }
            collected.extend_from_slice(&out[..n as usize]);
        }
        let fin = unsafe { tk_inflate_finish(h) };
        if fin != 0 {
            eprintln!("codec {} finish failed: {}", codec, err());
        }
        assert_eq!(fin, 0);
        unsafe { tk_inflate_free(h) };
        collected
    }

    #[test]
    fn gzip_and_zstd_round_trip() {
        let data: Vec<u8> = (0..10000u32).map(|i| (i % 251) as u8).collect();
        let mut gz = Vec::new();
        {
            let mut enc = flate2::write::GzEncoder::new(&mut gz, flate2::Compression::default());
            enc.write_all(&data).unwrap();
            enc.finish().unwrap();
        }
        let got = round_trip(GZIP, &gz);
        eprintln!("gzip: in={} gz={} out={}", data.len(), gz.len(), got.len());
        if got != data {
            let at = got.iter().zip(data.iter()).position(|(a, b)| a != b).unwrap_or(got.len().min(data.len()));
            eprintln!("first diff at {}: got={:?} want={:?}", at, &got[at.saturating_sub(8)..(at + 8).min(got.len())], &data[at.saturating_sub(8)..(at + 8).min(data.len())]);
        }
        assert_eq!(got, data);
        let zst = zstd::stream::encode_all(&data[..], 3).unwrap();
        // Control: the reference decoder must read the test frame.
        {
            use std::io::Read;
            let mut dec = zstd::stream::read::Decoder::new(&zst[..]).unwrap();
            let mut ref_out = Vec::new();
            dec.read_to_end(&mut ref_out).unwrap();
            assert_eq!(ref_out, data);
        }
        let got = round_trip(ZSTD, &zst);
        eprintln!("zstd: in={} zst={} out={}", data.len(), zst.len(), got.len());
        assert_eq!(got, data);
    }

    #[test]
    fn truncated_body_fails_finish() {
        let data = b"hello world, hello world";
        let mut gz = Vec::new();
        {
            let mut enc = flate2::write::GzEncoder::new(&mut gz, flate2::Compression::default());
            enc.write_all(&data[..]).unwrap();
            enc.finish().unwrap();
        }
        let h = tk_inflate_new(GZIP);
        let mut out = vec![0u8; 1024];
        let n = unsafe { tk_inflate_into(h, gz.as_ptr(), gz.len() / 2, out.as_mut_ptr(), out.len()) };
        assert!(n >= 0);
        assert_eq!(unsafe { tk_inflate_finish(h) }, -1);
        unsafe { tk_inflate_free(h) };
    }
}
