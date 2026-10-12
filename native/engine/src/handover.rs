//! Zero-copy buffer handover: `own()` lends a Rust allocation to the caller, `tk_release`
//! takes it back. Fresh implementation of the native handover contract.
//!
//! Layout: the caller receives the data address and length. `OWNED` bytes ahead of the
//! data hold the allocation's length and capacity (u64 LE each), so `tk_release` can
//! rebuild the `Vec` without any side table.

use crate::{bytes_mut, guard};

/// Free bytes reserved ahead of handed-over data: length + capacity, u64 LE each.
pub(crate) const OWNED: usize = 16;

/// Hands `data` over whole: returns (data address, data length). `data` must start with
/// [`OWNED`] free bytes (reserve them when building the buffer). The caller frees it
/// with [`tk_release`], never `tk_free`.
pub(crate) fn own(mut data: Vec<u8>) -> (*mut u8, usize) {
    let (len, cap) = (data.len(), data.capacity());
    data[..8].copy_from_slice(&(len as u64).to_le_bytes());
    data[8..16].copy_from_slice(&(cap as u64).to_le_bytes());
    let base = data.as_mut_ptr();
    std::mem::forget(data);
    // SAFETY: `base` has `OWNED` header bytes; the data starts after them.
    unsafe { (base.add(OWNED), len - OWNED) }
}

/// Releases what [`own`] handed out. Null-safe; anything else must be an `own` buffer.
#[no_mangle]
pub unsafe extern "C" fn tk_release(data: *mut u8) {
    guard(|| {
        if data.is_null() {
            return Ok(0);
        }
        // SAFETY: by contract this is an `own` buffer with its header intact.
        let base = data.sub(OWNED);
        let len = u64::from_le_bytes(bytes_mut(base, 8).try_into().unwrap()) as usize;
        let cap = u64::from_le_bytes(bytes_mut(base.add(8), 8).try_into().unwrap()) as usize;
        drop(Vec::from_raw_parts(base, len, cap));
        Ok(0)
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_through_release() {
        let mut buf = vec![0u8; OWNED];
        buf.extend_from_slice(b"hello");
        let (ptr, len) = own(buf);
        assert_eq!(len, 5);
        assert_eq!(unsafe { std::slice::from_raw_parts(ptr, len) }, b"hello");
        unsafe { tk_release(ptr) };
        unsafe { tk_release(std::ptr::null_mut()) };
    }
}
