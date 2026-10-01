//! Legacy charsets for HTTP bodies (Shift_JIS, GBK, Big5, EUC-KR, KOI8, …): the WHATWG
//! Encoding Standard via `encoding_rs`. Decode only; UTF-8 and windows-1252 stay in Dart.


use crate::{bytes, give, guard, text};
use std::slice;

/// Decodes `len` bytes in the charset `label` names (any WHATWG label, case-insensitive) into
/// UTF-16 code units, native byte order, handed back as a Rust allocation freed with `tk_free`.
/// A label the standard does not know reads as UTF-8. Malformed bytes become U+FFFD, and a BOM
/// is not looked for: the caller has already decided the encoding.
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
        let mut units = vec![0u16; cap];
        let (_, _, written, _) = decoder.decode_to_utf16(input, &mut units, true);
        let raw = unsafe { slice::from_raw_parts(units.as_ptr() as *const u8, written * 2) }.to_vec();
        Ok(give(raw, out, out_len))
    })
}
