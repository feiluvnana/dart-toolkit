//! Legacy charsets for HTTP bodies (Shift_JIS, GBK, Big5, EUC-KR, KOI8, …): the WHATWG
//! Encoding Standard via `encoding_rs`. Decode only; UTF-8 and windows-1252 stay in Dart.


use crate::archive::{own, OWNED};
use crate::{bytes, guard, text};
use std::slice;

/// Decodes `len` bytes in the charset `label` names (any WHATWG label, case-insensitive) into
/// UTF-16 code units, native byte order, handed over as `own` hands a buffer: `out` is the
/// units' address, freed with `tk_release`, and `out_len` their length in bytes. A label the
/// standard does not know reads as UTF-8. Malformed bytes become U+FFFD, and a BOM is not looked
/// for: the caller has already decided the encoding.
#[no_mangle]
pub unsafe extern "C" fn tk_decode_text(
    label: *const u8,
    llen: usize,
    data: *const u8,
    len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let encoding = encoding_rs::Encoding::for_label(text(label, llen)?.trim().as_bytes()).unwrap_or(encoding_rs::UTF_8);
        let input = bytes(data, len);
        let mut decoder = encoding.new_decoder_without_bom_handling();
        let cap = decoder.max_utf16_buffer_length(input.len()).ok_or("body too large to decode")?;
        // Decoded straight into the buffer handed over: no second copy of the units.
        let mut buf = vec![0u8; OWNED + cap * 2];
        let start = buf.as_mut_ptr().add(OWNED);
        if start as usize % 2 != 0 {
            return Err("unaligned buffer".into());
        }
        let units = slice::from_raw_parts_mut(start as *mut u16, cap);
        let (_, _, written, _) = decoder.decode_to_utf16(input, units, true);
        buf.truncate(OWNED + written * 2);
        let (ptr, n) = own(buf);
        *out = ptr;
        *out_len = n;
        Ok(0)
    })
}
