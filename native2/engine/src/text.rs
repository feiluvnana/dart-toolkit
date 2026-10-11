//! Legacy charsets for HTTP bodies, rewritten: the WHATWG Encoding Standard via
//! `encoding_rs`. Decode only; UTF-8 and windows-1252 stay in Dart.

use crate::handover::{own, OWNED};
use crate::{bytes, guard, text};
use std::slice;

/// Decodes `len` bytes in the charset `label` names (any WHATWG label, case-insensitive)
/// into UTF-16 code units in native byte order, handed over whole: `out` is the units'
/// address, freed with `tk_release`, and `out_len` their length in bytes. An unknown label
/// reads as UTF-8. Malformed bytes become U+FFFD; no BOM sniffing — the caller already
/// decided the encoding.
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
        let encoding =
            encoding_rs::Encoding::for_label(text(label, llen)?.trim().as_bytes()).unwrap_or(encoding_rs::UTF_8);
        let input = bytes(data, len);
        let mut decoder = encoding.new_decoder_without_bom_handling();
        let cap = decoder.max_utf16_buffer_length(input.len()).ok_or("body too large to decode")?;
        // Decoded straight into the handed-over buffer: no second copy of the units.
        let mut buf = vec![0u8; OWNED + cap * 2];
        let start = buf.as_mut_ptr().add(OWNED);
        if start as usize % 2 != 0 {
            return Err("unaligned buffer".into());
        }
        let units = slice::from_raw_parts_mut(start as *mut u16, cap);
        let (_, _, written, _) = decoder.decode_to_utf16(input, units, true);
        buf.truncate(OWNED + written * 2);
        // `buf` already carries its OWNED header from creation: hand it over directly.
        let (ptr, n) = own(buf);
        *out = ptr;
        *out_len = n;
        Ok(0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(label: &str, data: &[u8]) -> Vec<u8> {
        let (mut ptr, mut len) = (std::ptr::null_mut(), 0usize);
        let rc = unsafe {
            tk_decode_text(label.as_ptr(), label.len(), data.as_ptr(), data.len(), &mut ptr, &mut len)
        };
        assert_eq!(rc, 0);
        let out = unsafe { std::slice::from_raw_parts(ptr, len).to_vec() };
        unsafe { crate::handover::tk_release(ptr) };
        out
    }

    fn units(bytes: &[u8]) -> Vec<u16> {
        bytes.chunks_exact(2).map(|c| u16::from_ne_bytes([c[0], c[1]])).collect()
    }

    #[test]
    fn shift_jis_and_unknown_labels() {
        // あ in Shift_JIS.
        assert_eq!(units(&decode("shift_jis", &[0x82, 0xA0])), [0x3042]);
        // Unknown label reads as UTF-8.
        assert_eq!(units(&decode("never-a-charset", "hé".as_bytes())), ['h' as u16, 0xE9]);
        // Malformed bytes become U+FFFD.
        assert_eq!(units(&decode("shift_jis", &[0xFF])), [0xFFFD]);
    }
}
