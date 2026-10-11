//! Images, rewritten for native2.
//!
//! Fresh implementation of the image interface: same FFI names, signatures and format
//! codes, differential-tested against legacy. Decodes JPEG/PNG/WebP/GIF/BMP/TIFF/QOI,
//! transforms in memory, encodes JPEG/PNG/WebP/BMP/TIFF, scores with SSIMULACRA2.
//! Handles are borrowed, never consumed: every op returns a new owned handle.

use crate::{bytes, give, guard, text};
use image::codecs::bmp::BmpEncoder;
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use image::codecs::tiff::TiffEncoder;
use image::{DynamicImage, ImageEncoder, ImageFormat, ImageReader, Rgba, RgbaImage};
use libwebp_sys as webp;
use rayon::prelude::*;
use std::borrow::Cow;
use std::ffi::c_void;
use std::io::Cursor;

const FONT_8X16: &[u8; 4096] = include_bytes!("font8x16.bin");

/// How much of a file the header gives its size in: the first 128 KiB, for every format.
const HEADER_BYTES: usize = 128 * 1024;

/// oxipng's effort: 2 is its default, a few hundred milliseconds for a 2 MP image.
const PNG_PRESET: u8 = 2;

/// The longest side compression scores at: a larger picture is compared as a screen shows
/// it, which also bounds the metric's memory.
const SCORE_SIDE: u32 = 2048;

/// One SSIMULACRA2 at a time in the process: each holds about 14 float planes of the
/// picture. The encodes around it still run side by side.
static SCORING: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// `f` while no other score is computed.
fn scoring<T>(f: impl FnOnce() -> T) -> T {
    let _one = SCORING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    f()
}

pub struct NativeImage {
    pub inner: DynamicImage,
}

impl NativeImage {
    pub fn new(inner: DynamicImage) -> Self {
        Self { inner }
    }
}

unsafe fn img<'a>(h: *mut c_void) -> Result<&'a NativeImage, String> {
    if h.is_null() {
        return Err("Invalid null image handle".to_string());
    }
    Ok(&*(h as *mut NativeImage))
}

fn made(f: impl FnOnce() -> Result<NativeImage, String>) -> *mut c_void {
    let mut out: *mut c_void = std::ptr::null_mut();
    guard(|| {
        out = Box::into_raw(Box::new(f()?)) as *mut c_void;
        Ok(0)
    });
    out
}

unsafe fn op(h: *mut c_void, f: impl FnOnce(&NativeImage) -> Result<NativeImage, String>) -> *mut c_void {
    made(|| f(img(h)?))
}

fn code_to_format(code: u32) -> Option<ImageFormat> {
    match code {
        1 => Some(ImageFormat::Jpeg),
        2 => Some(ImageFormat::Png),
        3 => Some(ImageFormat::WebP),
        4 => Some(ImageFormat::Gif),
        5 => Some(ImageFormat::Bmp),
        6 => Some(ImageFormat::Tiff),
        _ => None,
    }
}

fn read_exif_orientation(data: &[u8]) -> u32 {
    let reader = exif::Reader::new();
    let mut cursor = Cursor::new(data);
    if let Ok(exif) = reader.read_from_container(&mut cursor) {
        if let Some(field) = exif.get_field(exif::Tag::Orientation, exif::In::PRIMARY) {
            if let Some(val) = field.value.get_uint(0) {
                return val;
            }
        }
    }
    1
}

fn read_exif_orientation_from_file(path: &str) -> u32 {
    if let Ok(mut file) = std::fs::File::open(path) {
        let mut buf = Vec::new();
        use std::io::Read;
        let _ = (&mut file).take((128 * 1024) as u64).read_to_end(&mut buf);
        read_exif_orientation(&buf)
    } else {
        1
    }
}

/// The [w]×[h] plane [buf] of [channels]-byte pixels mirrored in place.
fn flip_plane(buf: &mut [u8], w: usize, h: usize, channels: usize, horizontal: bool, vertical: bool) {
    let row = w * channels;
    if vertical {
        for y in 0..h / 2 {
            let (top, bottom) = buf.split_at_mut((h - 1 - y) * row);
            top[y * row..(y + 1) * row].swap_with_slice(&mut bottom[..row]);
        }
    }
    if horizontal {
        use rayon::prelude::*;
        buf.par_chunks_mut(row).for_each(|line| {
            line.reverse();
            line.chunks_exact_mut(channels).for_each(<[u8]>::reverse);
        });
    }
}

/// [img] turned upright by the EXIF [orientation] (1–8; anything else leaves it).
fn upright(img: DynamicImage, orientation: u32) -> DynamicImage {
    let (turned, horizontal, vertical) = match orientation {
        2 => (None, true, false),
        3 => (None, true, true),
        4 => (None, false, true),
        5 => (Some(img.rotate90()), true, false),
        6 => (Some(img.rotate90()), false, false),
        7 => (Some(img.rotate270()), true, false),
        8 => (Some(img.rotate270()), false, false),
        _ => return img,
    };
    let mut out = turned.unwrap_or(img);
    if horizontal || vertical {
        let (w, h) = (out.width() as usize, out.height() as usize);
        let channels = out.color().bytes_per_pixel() as usize;
        match &mut out {
            DynamicImage::ImageLuma8(b) => flip_plane(b, w, h, channels, horizontal, vertical),
            DynamicImage::ImageLumaA8(b) => flip_plane(b, w, h, channels, horizontal, vertical),
            DynamicImage::ImageRgb8(b) => flip_plane(b, w, h, channels, horizontal, vertical),
            DynamicImage::ImageRgba8(b) => flip_plane(b, w, h, channels, horizontal, vertical),
            other => other.apply_orientation(match (horizontal, vertical) {
                (true, true) => image::metadata::Orientation::Rotate180,
                (true, false) => image::metadata::Orientation::FlipHorizontal,
                _ => image::metadata::Orientation::FlipVertical,
            }),
        }
    }
    out
}

/// The 8-bit RGB plane of [img]: borrowed when it is one, so an encoder never copies a photo.
fn rgb8(img: &DynamicImage) -> Cow<'_, image::RgbImage> {
    match img {
        DynamicImage::ImageRgb8(b) => Cow::Borrowed(b),
        other => Cow::Owned(other.to_rgb8()),
    }
}

/// The 8-bit RGBA plane of [img], borrowed when it is one.
fn rgba8(img: &DynamicImage) -> Cow<'_, RgbaImage> {
    match img {
        DynamicImage::ImageRgba8(b) => Cow::Borrowed(b),
        other => Cow::Owned(other.to_rgba8()),
    }
}

/// `calculate_fit` target dimensions for `fit_mode`: 0 cover, 1 contain, 2 fill, 3 inside.
fn calculate_fit(src_w: u32, src_h: u32, target_w: u32, target_h: u32, fit_mode: u32) -> (u32, u32) {
    let round = |v: f64| v.round() as u32;
    if target_h == 0 {
        let h = round(target_w as f64 * src_h as f64 / src_w as f64);
        return (target_w.max(1), h.max(1));
    }
    if target_w == 0 {
        let w = round(target_h as f64 * src_w as f64 / src_h as f64);
        return (w.max(1), target_h.max(1));
    }
    match fit_mode {
        0 => {
            let s = (target_w as f64 / src_w as f64).max(target_h as f64 / src_h as f64);
            (round(src_w as f64 * s).max(1), round(src_h as f64 * s).max(1))
        }
        1 => {
            let s = (target_w as f64 / src_w as f64).min(target_h as f64 / src_h as f64);
            (round(src_w as f64 * s).max(1), round(src_h as f64 * s).max(1))
        }
        3 if src_w <= target_w && src_h <= target_h => (src_w, src_h),
        3 => {
            let s = (target_w as f64 / src_w as f64).min(target_h as f64 / src_h as f64);
            (round(src_w as f64 * s).max(1), round(src_h as f64 * s).max(1))
        }
        _ => (target_w, target_h),
    }
}

fn alg_of(code: u32) -> fast_image_resize::ResizeAlg {
    use fast_image_resize::{FilterType, ResizeAlg};
    match code {
        1 => ResizeAlg::Convolution(FilterType::Bilinear),
        2 => ResizeAlg::Nearest,
        _ => ResizeAlg::Convolution(FilterType::Lanczos3),
    }
}

/// Downsamples `src` (row-major, `channels` bytes per pixel) to `dw`×`dh` by area averaging.
fn area_shrink(src: &[u8], sw: usize, sh: usize, channels: usize, dw: usize, dh: usize) -> Vec<u8> {
    use rayon::prelude::*;
    let row = sw * channels;
    let band = ((1 << 20) / (dw * channels).max(1)).max(1);
    (0..dh)
        .collect::<Vec<_>>()
        .par_chunks(band)
        .flat_map(|rows| {
            let mut out = Vec::with_capacity(rows.len() * dw * channels);
            for &y in rows {
                for x in 0..dw {
                    let x0 = x * sw / dw;
                    let x1 = ((x + 1) * sw).div_ceil(dw).clamp(x0 + 1, sw);
                    let y0 = y * sh / dh;
                    let y1 = ((y + 1) * sh).div_ceil(dh).clamp(y0 + 1, sh);
                    if channels == 4 {
                        let (mut ar, mut ag, mut ab, mut aa) = (0u64, 0u64, 0u64, 0u64);
                        for sy in y0..y1 {
                            for sx in x0..x1 {
                                let p = &src[sy * row + sx * 4..];
                                let a = p[3] as u64;
                                ar += p[0] as u64 * a;
                                ag += p[1] as u64 * a;
                                ab += p[2] as u64 * a;
                                aa += a;
                            }
                        }
                        let n = ((x1 - x0) * (y1 - y0)) as u64;
                        if aa == 0 {
                            out.extend_from_slice(&[0, 0, 0, 0]);
                        } else {
                            out.extend_from_slice(&[
                                ((ar + aa / 2) / aa) as u8,
                                ((ag + aa / 2) / aa) as u8,
                                ((ab + aa / 2) / aa) as u8,
                                ((aa + n / 2) / n) as u8,
                            ]);
                        }
                    } else {
                        let (mut ar, mut ag, mut ab) = (0u64, 0u64, 0u64);
                        for sy in y0..y1 {
                            for sx in x0..x1 {
                                let p = &src[sy * row + sx * 3..];
                                ar += p[0] as u64;
                                ag += p[1] as u64;
                                ab += p[2] as u64;
                            }
                        }
                        let n = ((x1 - x0) * (y1 - y0)) as u64;
                        out.extend_from_slice(&[
                            ((ar + n / 2) / n) as u8,
                            ((ag + n / 2) / n) as u8,
                            ((ab + n / 2) / n) as u8,
                        ]);
                    }
                }
            }
            out
        })
        .collect()
}

fn expand_rgb_to_rgba(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len() / 3 * 4);
    for px in src.chunks_exact(3) {
        out.extend_from_slice(&[px[0], px[1], px[2], 255]);
    }
    out
}

/// Resamples `src` to cover/contain/fill `target_w`×`target_h` (see `calculate_fit`).
fn resized(src: &DynamicImage, target_w: u32, target_h: u32, fit_mode: u32, filter_code: u32) -> Result<DynamicImage, String> {
    use fast_image_resize::{images::{Image as FrImage, ImageRef}, PixelType, ResizeOptions, Resizer};
    let (mut dw, mut dh) = calculate_fit(src.width(), src.height(), target_w, target_h, fit_mode);
    dw = dw.max(1);
    dh = dh.max(1);
    let has_alpha = src.color().has_alpha();
    let (plane, channels) = if has_alpha {
        (rgba8(src).into_owned().into_raw(), 4)
    } else {
        (rgb8(src).into_owned().into_raw(), 3)
    };
    let (sw, sh) = (src.width() as usize, src.height() as usize);
    let (work, work_w, work_h) = if dw as usize * 2 <= sw && dh as usize * 2 <= sh {
        let shrunk = area_shrink(&plane, sw, sh, channels, dw as usize * 2, dh as usize * 2);
        (shrunk, dw as usize * 2, dh as usize * 2)
    } else {
        (plane, sw, sh)
    };
    let pixel = if channels == 4 { PixelType::U8x4 } else { PixelType::U8x3 };
    let src_ref = ImageRef::new(work_w as u32, work_h as u32, &work, pixel).map_err(|e| e.to_string())?;
    let mut dst = FrImage::new(dw, dh, pixel);
    Resizer::new()
        .resize(&src_ref, &mut dst, &ResizeOptions::new().resize_alg(alg_of(filter_code)))
        .map_err(|e| e.to_string())?;
    let mut out = dst.into_vec();
    if channels == 3 {
        out = expand_rgb_to_rgba(&out);
    }
    let mut rgba = RgbaImage::from_raw(dw, dh, out).ok_or("resample produced no pixels")?;
    // Cover center-crops to the exact target.
    if fit_mode == 0 && target_w > 0 && target_h > 0 && (dw > target_w || dh > target_h) {
        let cx = (dw - target_w) / 2;
        let cy = (dh - target_h) / 2;
        rgba = image::imageops::crop_imm(&rgba, cx, cy, target_w, target_h).to_image();
    }
    Ok(DynamicImage::ImageRgba8(rgba))
}

/// [img] with no side longer than [max_side] (0: as it is).
fn fit(img: DynamicImage, max_side: u32) -> Result<DynamicImage, String> {
    if max_side == 0 || img.width().max(img.height()) <= max_side {
        return Ok(img);
    }
    resized(&img, max_side, max_side, 1, 0)
}

/// A JPEG whose long side passes [max_side], decoded by mozjpeg at the smallest DCT scale
/// (n/8) that keeps that side at least [max_side]: the whole-size pixels are never made, and
/// most of the inverse DCT is skipped. `None` for anything else — not a JPEG, CMYK, already
/// small enough, or one mozjpeg refuses — which the general decoder then reads.
fn jpeg_scaled(data: &[u8], max_side: u32) -> Option<DynamicImage> {
    if max_side == 0 || !data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return None;
    }
    let want = max_side as usize;
    // libjpeg reports a failure by unwinding.
    let decoded = std::panic::catch_unwind(|| -> std::io::Result<Option<DynamicImage>> {
        let mut d = mozjpeg::Decompress::new_mem(data)?;
        let long = d.width().max(d.height());
        if long <= want {
            return Ok(None);
        }
        let gray = match d.color_space() {
            mozjpeg::ColorSpace::JCS_GRAYSCALE => true,
            mozjpeg::ColorSpace::JCS_YCbCr | mozjpeg::ColorSpace::JCS_RGB => false,
            _ => return Ok(None),
        };
        // A side scaled by n/8 is rounded up.
        let n = (1..8).find(|&n| (long * n).div_ceil(8) >= want).unwrap_or(8);
        d.scale(n as u8);
        let mut s = if gray { d.grayscale()? } else { d.rgb()? };
        let (w, h) = (s.width() as u32, s.height() as u32);
        let px: Vec<u8> = s.read_scanlines()?;
        s.finish()?;
        Ok(if gray {
            image::GrayImage::from_raw(w, h, px).map(DynamicImage::ImageLuma8)
        } else {
            image::RgbImage::from_raw(w, h, px).map(DynamicImage::ImageRgb8)
        })
    });
    decoded.ok()?.ok()?
}

/// [data] decoded at no more than [max_side] a side (0: whole); `format_code` 0 sniffs it.
fn decode(data: &[u8], format_code: u32, max_side: u32) -> Result<DynamicImage, String> {
    if format_code == 0 || code_to_format(format_code) == Some(ImageFormat::Jpeg) {
        if let Some(img) = jpeg_scaled(data, max_side) {
            return fit(img, max_side);
        }
    }
    let mut reader = ImageReader::new(Cursor::new(data));
    match code_to_format(format_code) {
        Some(fmt) => reader.set_format(fmt),
        None => reader = reader.with_guessed_format().map_err(|e| e.to_string())?,
    }
    fit(reader.decode().map_err(|e| e.to_string())?, max_side)
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_load_file(path: *const u8, plen: usize, max_side: u32) -> *mut c_void {
    made(|| {
        let p = text(path, plen)?;
        let orient = read_exif_orientation_from_file(p);
        if max_side > 0 {
            // Whole bytes, so a JPEG can be decoded at its scaled size.
            let data = std::fs::read(p).map_err(|e| e.to_string())?;
            return Ok(NativeImage::new(upright(decode(&data, 0, max_side)?, orient)));
        }
        // By content: a PNG saved as `.jpg` still opens.
        let img = ImageReader::open(p)
            .map_err(|e| e.to_string())?
            .with_guessed_format()
            .map_err(|e| e.to_string())?
            .decode()
            .map_err(|e| e.to_string())?;
        Ok(NativeImage::new(upright(img, orient)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_load_memory(data: *const u8, dlen: usize, format_code: u32, max_side: u32) -> *mut c_void {
    made(|| {
        let slice = bytes(data, dlen);
        let orient = read_exif_orientation(slice);
        Ok(NativeImage::new(upright(decode(slice, format_code, max_side)?, orient)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_create_blank(width: u32, height: u32, r: u8, g: u8, b: u8, a: u8) -> *mut c_void {
    made(|| {
        if width == 0 || height == 0 {
            return Err("Image dimensions must be greater than 0".to_string());
        }
        let rgba = RgbaImage::from_pixel(width, height, Rgba([r, g, b, a]));
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_free(handle: *mut c_void) {
    if !handle.is_null() {
        drop(Box::from_raw(handle as *mut NativeImage));
    }
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_dimensions(handle: *mut c_void, out_width: *mut u32, out_height: *mut u32) -> i32 {
    guard(|| {
        let native = img(handle)?;
        *out_width = native.inner.width();
        *out_height = native.inner.height();
        Ok(0)
    })
}

// ---- probing

/// The Dart `ImageFormat.code` of a header's format, or 0 when it is none of them.
fn probe_format(head: &[u8]) -> usize {
    match imagesize::image_type(head) {
        Ok(imagesize::ImageType::Jpeg) => 1,
        Ok(imagesize::ImageType::Png) => 2,
        Ok(imagesize::ImageType::Webp) => 3,
        Ok(imagesize::ImageType::Gif) => 4,
        Ok(imagesize::ImageType::Bmp) => 5,
        Ok(imagesize::ImageType::Tiff) => 6,
        _ => 0,
    }
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_probe_file(
    path: *const u8,
    plen: usize,
    out_width: *mut usize,
    out_height: *mut usize,
    out_format: *mut usize,
) -> i32 {
    guard(|| {
        let p = text(path, plen)?;
        // One open, one read: the frame header is in the first bytes of every format written.
        let mut header = vec![0u8; HEADER_BYTES];
        let mut f = std::fs::File::open(p).map_err(|e| e.to_string())?;
        use std::io::Read;
        let n = f.read(&mut header).unwrap_or(0);
        drop(f);
        let head = &header[..n];
        let size = match imagesize::blob_size(head) {
            Ok(s) => s,
            // A frame header past the prefix: the walking reader still finds the dimensions.
            Err(_) => imagesize::size(p).map_err(|e| e.to_string())?,
        };
        *out_width = size.width;
        *out_height = size.height;
        *out_format = probe_format(head);
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_probe_memory(
    data: *const u8,
    dlen: usize,
    out_width: *mut usize,
    out_height: *mut usize,
    out_format: *mut usize,
) -> i32 {
    guard(|| {
        let slice = bytes(data, dlen);
        let size = imagesize::blob_size(slice).map_err(|e| e.to_string())?;
        *out_width = size.width;
        *out_height = size.height;
        *out_format = probe_format(slice);
        Ok(0)
    })
}

// ---- transforms

#[no_mangle]
pub unsafe extern "C" fn tk_image_resize(handle: *mut c_void, target_w: u32, target_h: u32, fit_mode: u32, filter_code: u32) -> *mut c_void {
    op(handle, |n| resized(&n.inner, target_w, target_h, fit_mode, filter_code).map(NativeImage::new))
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_crop(handle: *mut c_void, x: u32, y: u32, width: u32, height: u32) -> *mut c_void {
    op(handle, |n| {
        Ok(NativeImage::new(DynamicImage::ImageRgba8(image::imageops::crop_imm(&n.inner.to_rgba8(), x, y, width, height).to_image())))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_crop_aspect(handle: *mut c_void, target_aspect: f64, align_x: f32, align_y: f32) -> *mut c_void {
    op(handle, |n| {
        if target_aspect <= 0.0 {
            return Err("Aspect ratio must be positive".to_string());
        }
        let (w, h) = (n.inner.width(), n.inner.height());
        let cur = w as f64 / h as f64;
        let (mut crop_w, mut crop_h) = if cur > target_aspect {
            ((((h as f64 * target_aspect).round() as u32).min(w)), h)
        } else {
            (w, (((w as f64 / target_aspect).round() as u32).min(h)))
        };
        crop_w = crop_w.max(1);
        crop_h = crop_h.max(1);
        let rem_x = w.saturating_sub(crop_w);
        let rem_y = h.saturating_sub(crop_h);
        let ax = align_x.clamp(0.0, 1.0);
        let ay = align_y.clamp(0.0, 1.0);
        let x = (rem_x as f32 * ax).round() as u32;
        let y = (rem_y as f32 * ay).round() as u32;
        Ok(NativeImage::new(DynamicImage::ImageRgba8(
            image::imageops::crop_imm(&n.inner.to_rgba8(), x, y, crop_w, crop_h).to_image(),
        )))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_rotate(handle: *mut c_void, degrees: i32) -> *mut c_void {
    op(handle, |n| {
        let normalized = ((degrees % 360) + 360) % 360;
        Ok(NativeImage::new(match normalized {
            90 => n.inner.rotate90(),
            180 => n.inner.rotate180(),
            270 => n.inner.rotate270(),
            0 => n.inner.clone(),
            _ => return Err("Only rotations by 90, 180, or 270 degrees are supported".to_string()),
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_flip(handle: *mut c_void, horizontal: bool, vertical: bool) -> *mut c_void {
    op(handle, |n| {
        Ok(NativeImage::new(match (horizontal, vertical) {
            (true, false) => n.inner.fliph(),
            (false, true) => n.inner.flipv(),
            (true, true) => n.inner.rotate180(),
            _ => n.inner.clone(),
        }))
    })
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tk_image_pad(
    handle: *mut c_void,
    top: u32,
    right: u32,
    bottom: u32,
    left: u32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> *mut c_void {
    op(handle, |n| {
        let (w, h) = (n.inner.width(), n.inner.height());
        let (new_w, new_h) = (w + left + right, h + top + bottom);
        let mut canvas = RgbaImage::from_pixel(new_w, new_h, Rgba([r, g, b, a]));
        image::imageops::overlay(&mut canvas, &n.inner.to_rgba8(), left as i64, top as i64);
        Ok(NativeImage::new(DynamicImage::ImageRgba8(canvas)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_trim(handle: *mut c_void, threshold: u8) -> *mut c_void {
    op(handle, |n| {
        let rgba = n.inner.to_rgba8();
        let (w, h) = (rgba.width(), rgba.height());
        let bg = *rgba.get_pixel(0, 0);
        let diff = |p: &Rgba<u8>| {
            (p[0] as i16 - bg[0] as i16).unsigned_abs() > threshold as u16
                || (p[1] as i16 - bg[1] as i16).unsigned_abs() > threshold as u16
                || (p[2] as i16 - bg[2] as i16).unsigned_abs() > threshold as u16
                || (p[3] as i16 - bg[3] as i16).unsigned_abs() > threshold as u16
        };
        let (mut min_x, mut min_y, mut max_x, mut max_y) = (w, h, 0u32, 0u32);
        for y in 0..h {
            for x in 0..w {
                if diff(rgba.get_pixel(x, y)) {
                    min_x = min_x.min(x);
                    min_y = min_y.min(y);
                    max_x = max_x.max(x);
                    max_y = max_y.max(y);
                }
            }
        }
        if max_x < min_x || max_y < min_y {
            return Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)));
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(
            image::imageops::crop_imm(&rgba, min_x, min_y, max_x - min_x + 1, max_y - min_y + 1).to_image(),
        )))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_adjust(
    handle: *mut c_void,
    brightness: f32,
    contrast: f32,
    saturation: f32,
    gamma: f32,
    temperature: f32,
    tint: f32,
) -> *mut c_void {
    op(handle, |n| {
        use rayon::prelude::*;
        let mut rgba = n.inner.to_rgba8();
        let b_offset = brightness * 255.0;
        let inv_gamma = if gamma > 0.0 { 1.0 / gamma } else { 1.0 };
        let temp_offset = temperature * 30.0;
        let tint_offset = tint * 30.0;
        let stride = rgba.width() as usize * 4;
        rgba
            .as_mut()
            .par_chunks_mut(stride)
            .for_each(|line| {
                for px in line.chunks_exact_mut(4) {
                    let mut c = [px[0] as f32, px[1] as f32, px[2] as f32];
                    if brightness != 0.0 {
                        c[0] += b_offset;
                        c[1] += b_offset;
                        c[2] += b_offset;
                    }
                    if contrast != 1.0 {
                        c[0] = (c[0] - 128.0) * contrast + 128.0;
                        c[1] = (c[1] - 128.0) * contrast + 128.0;
                        c[2] = (c[2] - 128.0) * contrast + 128.0;
                    }
                    if saturation != 1.0 {
                        let lum = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
                        c[0] = lum + saturation * (c[0] - lum);
                        c[1] = lum + saturation * (c[1] - lum);
                        c[2] = lum + saturation * (c[2] - lum);
                    }
                    if temperature != 0.0 {
                        c[0] += temp_offset;
                        c[2] -= temp_offset;
                    }
                    if tint != 0.0 {
                        c[1] -= tint_offset;
                        c[0] += tint_offset * 0.5;
                        c[2] += tint_offset * 0.5;
                    }
                    if gamma != 1.0 && gamma > 0.0 {
                        for v in &mut c {
                            let norm = (*v / 255.0).clamp(0.0, 1.0);
                            *v = norm.powf(inv_gamma) * 255.0;
                        }
                    }
                    for (i, v) in c.iter().enumerate() {
                        px[i] = v.clamp(0.0, 255.0).round() as u8;
                    }
                }
            });
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_grayscale(handle: *mut c_void) -> *mut c_void {
    op(handle, |n| Ok(NativeImage::new(n.inner.grayscale())))
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_invert(handle: *mut c_void) -> *mut c_void {
    op(handle, |n| {
        let mut rgba = n.inner.to_rgba8();
        for px in rgba.pixels_mut() {
            px[0] = 255 - px[0];
            px[1] = 255 - px[1];
            px[2] = 255 - px[2];
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_sepia(handle: *mut c_void) -> *mut c_void {
    op(handle, |n| {
        let mut rgba = n.inner.to_rgba8();
        for px in rgba.pixels_mut() {
            let (r, g, b) = (px[0] as f32, px[1] as f32, px[2] as f32);
            px[0] = (0.393 * r + 0.769 * g + 0.189 * b).clamp(0.0, 255.0).round() as u8;
            px[1] = (0.349 * r + 0.686 * g + 0.168 * b).clamp(0.0, 255.0).round() as u8;
            px[2] = (0.272 * r + 0.534 * g + 0.131 * b).clamp(0.0, 255.0).round() as u8;
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_blur(handle: *mut c_void, sigma: f32) -> *mut c_void {
    op(handle, |n| Ok(NativeImage::new(n.inner.blur(sigma))))
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_sharpen(handle: *mut c_void, amount: f32, sigma: f32) -> *mut c_void {
    op(handle, |n| {
        use rayon::prelude::*;
        let rgba = n.inner.to_rgba8();
        let blurred = image::imageops::blur(&rgba, sigma);
        let mut out = rgba.clone();
        let stride = n.inner.width() as usize * 4;
        out.as_mut()
            .par_chunks_mut(stride.max(1))
            .zip(blurred.as_raw().par_chunks(stride.max(1)))
            .for_each(|(line, soft)| {
                for (px, q) in line.chunks_exact_mut(4).zip(soft.chunks_exact(4)) {
                    for c in 0..3 {
                        let v = px[c] as f32 + amount * (px[c] as f32 - q[c] as f32);
                        px[c] = v.round().clamp(0.0, 255.0) as u8;
                    }
                }
            });
        Ok(NativeImage::new(DynamicImage::ImageRgba8(out)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_denoise(handle: *mut c_void, radius: u32) -> *mut c_void {
    op(handle, |n| {
        let sigma = (radius as f32 * 0.5).max(0.5);
        Ok(NativeImage::new(n.inner.blur(sigma)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_vignette(handle: *mut c_void, amount: f32) -> *mut c_void {
    op(handle, |n| {
        use rayon::prelude::*;
        let mut rgba = n.inner.to_rgba8();
        let (w, h) = (rgba.width() as f32, rgba.height() as f32);
        let (cx, cy) = (w / 2.0, h / 2.0);
        let max_dist = (cx * cx + cy * cy).sqrt();
        let amt = amount.clamp(0.0, 1.0);
        let stride = rgba.width() as usize * 4;
        rgba
            .as_mut()
            .par_chunks_mut(stride)
            .enumerate()
            .for_each(|(y, line)| {
                for (x, px) in line.chunks_exact_mut(4).enumerate() {
                    let dist = (((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt()) / max_dist;
                    let factor = (1.0 - amt * dist * dist).clamp(0.0, 1.0);
                    for c in 0..3 {
                        px[c] = (px[c] as f32 * factor).round().clamp(0.0, 255.0) as u8;
                    }
                }
            });
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

fn blend_pixels(dst: &mut Rgba<u8>, src: &Rgba<u8>, opacity: f32, blend_mode: u32) {
    let src_a = (src[3] as f32 / 255.0) * opacity;
    if src_a <= 0.0 {
        return;
    }
    let dst_a = dst[3] as f32 / 255.0;
    let (s_r, s_g, s_b) = (src[0] as f32 / 255.0, src[1] as f32 / 255.0, src[2] as f32 / 255.0);
    let (d_r, d_g, d_b) = (dst[0] as f32 / 255.0, dst[1] as f32 / 255.0, dst[2] as f32 / 255.0);
    let (blended_r, blended_g, blended_b) = match blend_mode {
        1 => (d_r * s_r, d_g * s_g, d_b * s_b),
        2 => (
            1.0 - (1.0 - d_r) * (1.0 - s_r),
            1.0 - (1.0 - d_g) * (1.0 - s_g),
            1.0 - (1.0 - d_b) * (1.0 - s_b),
        ),
        3 => {
            let overlay = |d: f32, s: f32| -> f32 {
                if d < 0.5 {
                    2.0 * d * s
                } else {
                    1.0 - 2.0 * (1.0 - d) * (1.0 - s)
                }
            };
            (overlay(d_r, s_r), overlay(d_g, s_g), overlay(d_b, s_b))
        }
        4 => (d_r.min(s_r), d_g.min(s_g), d_b.min(s_b)),
        5 => (d_r.max(s_r), d_g.max(s_g), d_b.max(s_b)),
        _ => (s_r, s_g, s_b),
    };
    // W3C compositing: where the backdrop is transparent the source shows as it is.
    let blended_r = (1.0 - dst_a) * s_r + dst_a * blended_r;
    let blended_g = (1.0 - dst_a) * s_g + dst_a * blended_g;
    let blended_b = (1.0 - dst_a) * s_b + dst_a * blended_b;
    let out_a = src_a + dst_a * (1.0 - src_a);
    if out_a > 0.0 {
        let out_r = (blended_r * src_a + d_r * dst_a * (1.0 - src_a)) / out_a;
        let out_g = (blended_g * src_a + d_g * dst_a * (1.0 - src_a)) / out_a;
        let out_b = (blended_b * src_a + d_b * dst_a * (1.0 - src_a)) / out_a;
        dst[0] = (out_r * 255.0).clamp(0.0, 255.0).round() as u8;
        dst[1] = (out_g * 255.0).clamp(0.0, 255.0).round() as u8;
        dst[2] = (out_b * 255.0).clamp(0.0, 255.0).round() as u8;
        dst[3] = (out_a * 255.0).clamp(0.0, 255.0).round() as u8;
    }
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_composite(
    bg_handle: *mut c_void,
    ov_handle: *mut c_void,
    pos_x: i64,
    pos_y: i64,
    opacity: f32,
    blend_mode: u32,
) -> *mut c_void {
    made(|| {
        let bg = img(bg_handle)?;
        let ov = img(ov_handle)?;
        let mut base = bg.inner.to_rgba8();
        let overlay = ov.inner.to_rgba8();
        let (base_w, base_h) = (base.width() as i64, base.height() as i64);
        let (ov_w, ov_h) = (overlay.width() as i64, overlay.height() as i64);
        for oy in 0..ov_h {
            let by = pos_y + oy;
            if by < 0 || by >= base_h {
                continue;
            }
            for ox in 0..ov_w {
                let bx = pos_x + ox;
                if bx < 0 || bx >= base_w {
                    continue;
                }
                let src_p = overlay.get_pixel(ox as u32, oy as u32);
                let dst_p = base.get_pixel_mut(bx as u32, by as u32);
                blend_pixels(dst_p, src_p, opacity, blend_mode);
            }
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(base)))
    })
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tk_image_watermark(
    bg_handle: *mut c_void,
    wm_handle: *mut c_void,
    align_x: f32,
    align_y: f32,
    opacity: f32,
    scale: f32,
    margin: i32,
    blend_mode: u32,
) -> *mut c_void {
    made(|| {
        let bg = img(bg_handle)?;
        let wm = img(wm_handle)?;
        let (bg_w, bg_h) = (bg.inner.width(), bg.inner.height());
        let scaled_wm = if scale > 0.0 {
            let target_w = ((bg_w as f32 * scale).round() as u32).max(1);
            let target_h = (((target_w as f64 * wm.inner.height() as f64) / wm.inner.width() as f64).round() as u32).max(1);
            wm.inner.resize_exact(target_w, target_h, image::imageops::FilterType::Lanczos3)
        } else {
            wm.inner.clone()
        };
        let (wm_w, wm_h) = (scaled_wm.width() as i32, scaled_wm.height() as i32);
        let (bg_wi, bg_hi) = (bg_w as i32, bg_h as i32);
        // 0 sits `margin` from the near edge, 1 from the far edge, 0.5 centres.
        let place = |a: f32, bg: i32, wm: i32| (margin as f32 + a * (bg - wm - 2 * margin) as f32) as i32;
        let (x, y) = (place(align_x, bg_wi, wm_w), place(align_y, bg_hi, wm_h));
        let mut base = bg.inner.to_rgba8();
        let ov = scaled_wm.to_rgba8();
        for oy in 0..wm_h {
            let by = y + oy;
            if by < 0 || by >= bg_hi {
                continue;
            }
            for ox in 0..wm_w {
                let bx = x + ox;
                if bx < 0 || bx >= bg_wi {
                    continue;
                }
                let src_p = ov.get_pixel(ox as u32, oy as u32);
                let dst_p = base.get_pixel_mut(bx as u32, by as u32);
                blend_pixels(dst_p, src_p, opacity, blend_mode);
            }
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(base)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_mask(handle: *mut c_void, mask_handle: *mut c_void) -> *mut c_void {
    op(handle, |n| {
        let other = img(mask_handle)?;
        let mut base = n.inner.to_rgba8();
        let mask = other.inner.to_luma8();
        let (w, h) = (base.width().min(mask.width()), base.height().min(mask.height()));
        for y in 0..h {
            for x in 0..w {
                let m = mask.get_pixel(x, y)[0] as f32 / 255.0;
                let px = base.get_pixel_mut(x, y);
                px[3] = (px[3] as f32 * m).round().clamp(0.0, 255.0) as u8;
            }
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(base)))
    })
}

fn draw_char(canvas: &mut RgbaImage, c: char, x: i32, y: i32, scale: u32, color: Rgba<u8>) {
    let glyph = &FONT_8X16[(c as usize).min(255) * 16..][..16];
    let (w, h) = (canvas.width() as i32, canvas.height() as i32);
    for (row, byte) in glyph.iter().enumerate() {
        for col in 0..8 {
            if byte & (0x80 >> col) == 0 {
                continue;
            }
            for dy in 0..scale as i32 {
                for dx in 0..scale as i32 {
                    let (px, py) = (x + col as i32 * scale as i32 + dx, y + row as i32 * scale as i32 + dy);
                    if px >= 0 && py >= 0 && px < w && py < h {
                        let dst = canvas.get_pixel_mut(px as u32, py as u32);
                        blend_pixels(dst, &color, 1.0, 0);
                    }
                }
            }
        }
    }
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tk_image_draw_text(
    handle: *mut c_void,
    text_ptr: *const u8,
    text_len: usize,
    x: i32,
    y: i32,
    font_size: u32,
    color_rgba: u32,
    shadow_rgba: u32,
    has_shadow: bool,
) -> *mut c_void {
    op(handle, |n| {
        let mut base = n.inner.to_rgba8();
        let scale = (font_size / 16).max(1);
        let rgba = |v: u32| Rgba([(v >> 24) as u8, (v >> 16) as u8, (v >> 8) as u8, v as u8]);
        let (fg, shadow) = (rgba(color_rgba), rgba(shadow_rgba));
        let s = std::str::from_utf8(bytes(text_ptr, text_len)).map_err(|_| "text is not UTF-8".to_string())?;
        let char_w = 8 * scale as i32;
        if has_shadow {
            let off = scale as i32;
            let mut cur = x + off;
            for ch in s.chars() {
                draw_char(&mut base, ch, cur, y + off, scale, shadow);
                cur += char_w;
            }
        }
        let mut cur = x;
        for ch in s.chars() {
            draw_char(&mut base, ch, cur, y, scale, fg);
            cur += char_w;
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(base)))
    })
}

// ---- encoding, scoring, analysis, RGBA bridge

/// WebP through libwebp: the `image` crate only writes WebP losslessly, and a lossless
/// 60 MP frame is larger than the JPEG it came from. Lossy pictures import straight into
/// the YUV planes; only the lossless coder needs the 4-byte ARGB plane.
fn encode_webp(img: &DynamicImage, quality: u8, lossless: bool) -> Result<Vec<u8>, String> {
    let (w, h) = (img.width() as i32, img.height() as i32);
    if w <= 0 || h <= 0 || w as u32 > webp::WEBP_MAX_DIMENSION || h as u32 > webp::WEBP_MAX_DIMENSION {
        return Err(format!("WebP cannot hold {}x{}", w, h));
    }
    let has_alpha = img.color().has_alpha();
    let quality = quality.clamp(1, 100) as f32;
    let abi = webp::WEBP_ENCODER_ABI_VERSION as i32;
    unsafe {
        let mut config: webp::WebPConfig = std::mem::zeroed();
        if webp::WebPConfigInitInternal(&mut config, webp::WebPPreset::WEBP_PRESET_PHOTO, quality, abi) != 1 {
            return Err("libwebp refused the encoder configuration".to_string());
        }
        config.lossless = i32::from(lossless);
        config.quality = quality;
        // Method 2, not libwebp's default 4: the slower search buys little for batch work.
        config.method = 2;
        config.thread_level = 1;
        config.exact = i32::from(has_alpha);
        let mut picture: webp::WebPPicture = std::mem::zeroed();
        if webp::WebPPictureInitInternal(&mut picture, abi) != 1 {
            return Err("libwebp refused the picture".to_string());
        }
        picture.use_argb = i32::from(lossless);
        picture.width = w;
        picture.height = h;
        let imported = if has_alpha {
            let rgba = rgba8(img);
            webp::WebPPictureImportRGBA(&mut picture, rgba.as_ptr(), w * 4)
        } else {
            let rgb = rgb8(img);
            webp::WebPPictureImportRGB(&mut picture, rgb.as_ptr(), w * 3)
        };
        if imported != 1 {
            webp::WebPPictureFree(&mut picture);
            return Err("libwebp could not take this image".to_string());
        }
        let mut writer: webp::WebPMemoryWriter = std::mem::zeroed();
        webp::WebPMemoryWriterInit(&mut writer);
        picture.writer = Some(webp::WebPMemoryWrite);
        picture.custom_ptr = &mut writer as *mut webp::WebPMemoryWriter as *mut c_void;
        let encoded = webp::WebPEncode(&config, &mut picture);
        let out = if encoded == 1 && writer.size > 0 {
            Ok(std::slice::from_raw_parts(writer.mem, writer.size).to_vec())
        } else {
            Err("libwebp could not encode this image".to_string())
        };
        webp::WebPPictureFree(&mut picture);
        webp::WebPMemoryWriterClear(&mut writer);
        out
    }
}

/// [img] as a JPEG at [quality] through mozjpeg (trellis quantization, optimized Huffman
/// tables), chroma halved below 90 and kept whole from 90 up, where colour edges start to show.
/// [scans] also searches progressive scan scripts: about 2% smaller for twice the time, so a
/// quality search leaves it to the final encode, and scores that encode again.
fn encode_jpeg(img: &DynamicImage, quality: u8, scans: bool) -> Result<Vec<u8>, String> {
    let rgb = rgb8(img);
    let mut comp = mozjpeg::Compress::new(mozjpeg::ColorSpace::JCS_RGB);
    comp.set_size(rgb.width() as usize, rgb.height() as usize);
    comp.set_quality(quality.clamp(1, 100) as f32);
    if scans {
        comp.set_progressive_mode();
    }
    comp.set_optimize_scans(scans);
    comp.set_optimize_coding(true);
    let s = if quality >= 90 { 1 } else { 2 };
    comp.set_chroma_sampling_pixel_sizes((s, s), (s, s));
    let mut started = comp.start_compress(Vec::new()).map_err(|e| e.to_string())?;
    started.write_scanlines(rgb.as_raw()).map_err(|e| e.to_string())?;
    started.finish().map_err(|e| e.to_string())
}

/// [img] as a PNG, then recompressed by oxipng: the same pixels in fewer bytes.
fn encode_png(img: &DynamicImage) -> Result<Vec<u8>, String> {
    let rgba = rgba8(img);
    let mut raw = Vec::new();
    PngEncoder::new(&mut raw)
        .write_image(rgba.as_raw(), rgba.width(), rgba.height(), image::ExtendedColorType::Rgba8)
        .map_err(|e| e.to_string())?;
    oxipng::optimize_from_memory(&raw, &oxipng::Options::from_preset(PNG_PRESET)).map_err(|e| e.to_string())
}

fn encode_image(img: &DynamicImage, format: ImageFormat, quality: u8, lossless: bool) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    match format {
        ImageFormat::Jpeg => {
            let rgb = rgb8(img);
            JpegEncoder::new_with_quality(&mut buf, quality.clamp(1, 100))
                .write_image(rgb.as_raw(), rgb.width(), rgb.height(), image::ExtendedColorType::Rgb8)
                .map_err(|e| e.to_string())?;
        }
        ImageFormat::Png => {
            let rgba = rgba8(img);
            PngEncoder::new(&mut buf)
                .write_image(rgba.as_raw(), rgba.width(), rgba.height(), image::ExtendedColorType::Rgba8)
                .map_err(|e| e.to_string())?;
        }
        ImageFormat::WebP => return encode_webp(img, quality, lossless),
        ImageFormat::Bmp => {
            let rgb = rgb8(img);
            BmpEncoder::new(&mut buf)
                .write_image(rgb.as_raw(), rgb.width(), rgb.height(), image::ExtendedColorType::Rgb8)
                .map_err(|e| e.to_string())?;
        }
        ImageFormat::Tiff => {
            let rgba = rgba8(img);
            let mut cursor = Cursor::new(&mut buf);
            TiffEncoder::new(&mut cursor)
                .write_image(rgba.as_raw(), rgba.width(), rgba.height(), image::ExtendedColorType::Rgba8)
                .map_err(|e| e.to_string())?;
        }
        _ => {
            let mut cursor = Cursor::new(&mut buf);
            img.write_to(&mut cursor, format).map_err(|e| e.to_string())?;
        }
    }
    Ok(buf)
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_encode_memory(
    handle: *mut c_void,
    format_code: u32,
    quality: u8,
    lossless: bool,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let native = img(handle)?;
        let format = code_to_format(format_code).unwrap_or(ImageFormat::Jpeg);
        let buf = encode_image(&native.inner, format, quality, lossless)?;
        Ok(give(buf, out_ptr, out_len))
    })
}

/// Whether any pixel of [img] is less than opaque: a JPEG, which has no alpha, would drop it.
fn translucent(img: &DynamicImage) -> bool {
    match img {
        DynamicImage::ImageRgba8(b) => b.pixels().any(|p| p[3] != 255),
        other if other.color().has_alpha() => other.to_rgba8().pixels().any(|p| p[3] != 255),
        _ => false,
    }
}

/// [img] in linear light, as SSIMULACRA2 compares.
fn linear(img: &DynamicImage) -> Result<ssimulacra2::LinearRgb, String> {
    let px: Vec<[f32; 3]> = rgb8(img)
        .pixels()
        .map(|p| [p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0])
        .collect();
    let rgb = ssimulacra2::Rgb::new(
        px,
        img.width() as usize,
        img.height() as usize,
        ssimulacra2::TransferCharacteristic::SRGB,
        ssimulacra2::ColorPrimaries::BT709,
    )
    .map_err(|e| e.to_string())?;
    ssimulacra2::LinearRgb::try_from(rgb).map_err(|e| e.to_string())
}

/// SSIMULACRA2 of [b] against [a]: 100 is identical, 90 very high, 70 medium.
fn similarity(a: &ssimulacra2::LinearRgb, b: &DynamicImage) -> Result<f64, String> {
    scoring(|| ssimulacra2::compute_frame_ssimulacra2(a.clone(), linear(b)?).map_err(|e| e.to_string()))
}

/// [img] as compression scores it: shrunk to fit [SCORE_SIDE] when larger.
fn viewed(img: &DynamicImage) -> Result<Cow<'_, DynamicImage>, String> {
    if img.width().max(img.height()) <= SCORE_SIDE {
        Ok(Cow::Borrowed(img))
    } else {
        resized(img, SCORE_SIDE, SCORE_SIDE, 1, 0).map(Cow::Owned)
    }
}

/// The encoding [data] in [format] as [viewed] shows it; the whole-size decode is dropped
/// before it is scored.
fn seen(data: &[u8], format: ImageFormat) -> Result<DynamicImage, String> {
    let whole = image::load_from_memory_with_format(data, format).map_err(|e| e.to_string())?;
    let small = match viewed(&whole)? {
        Cow::Owned(small) => Some(small),
        Cow::Borrowed(_) => None,
    };
    Ok(small.unwrap_or(whole))
}

/// The quality range compression searches: a binary search over it takes at most 6 encodes.
const SEARCH_LOW: u8 = 40;
const SEARCH_HIGH: u8 = 100;

/// The smallest lossy encoding of [img] in [format] that still scores [target] against it,
/// within [max_bytes] when that is above 0; at a fixed [quality] above 0, that encoding.
/// Returns the bytes, the quality used, and the score (NaN when not measured); `None` when
/// no encoding fits [max_bytes].
fn compress(
    img: &DynamicImage,
    format: ImageFormat,
    quality: u8,
    target: f64,
    max_bytes: usize,
) -> Result<Option<(Vec<u8>, u8, f64)>, String> {
    let fits = |b: &Vec<u8>| max_bytes == 0 || b.len() <= max_bytes;
    if format == ImageFormat::Png {
        let out = encode_png(img)?;
        return Ok(fits(&out).then_some((out, 100, 100.0)));
    }
    if format != ImageFormat::Jpeg && format != ImageFormat::WebP {
        return Err("compress writes jpeg, webp or png".into());
    }
    // The search encodes fast; the one it keeps is encoded again with every byte-saving pass.
    let encode = |im: &DynamicImage, q: u8, last: bool| match format {
        ImageFormat::Jpeg => encode_jpeg(im, q, last),
        _ => encode_webp(im, q, false),
    };
    if quality > 0 {
        let out = encode(img, quality, true)?;
        return Ok(fits(&out).then_some((out, quality, f64::NAN)));
    }
    // A budget with no score asked: only the size counts, so nothing is scored, and the
    // highest quality goes first since it usually fits.
    let scoring = target <= 100.0;
    let mut scaled = Cow::Borrowed(img);
    for _ in 0..=5 {
        let found = if scoring {
            scored_search(&scaled, format, &encode, &fits, target)?
        } else {
            largest_fitting(&scaled, &encode, &fits)?.map(|(out, q)| {
                // The thorough pass, kept when it is smaller and still fits.
                match encode(&scaled, q, true) {
                    Ok(last) if last.len() < out.len() && fits(&last) => (last, q, f64::NAN),
                    _ => (out, q, f64::NAN),
                }
            })
        };
        if found.is_some() {
            return Ok(found);
        }
        // Even the lowest quality is over budget: a smaller picture, then search again.
        let (w, h) = (scaled.width() * 9 / 10, scaled.height() * 9 / 10);
        if w < 8 || h < 8 {
            break;
        }
        scaled = Cow::Owned(resized(&scaled, w, h, 2, 0)?);
    }
    Ok(None)
}

/// The lowest quality whose encoding of [img] scores [target] and [fits], else the highest
/// that fits: the bytes, the quality and the score; `None` when even the lowest is over.
fn scored_search(
    img: &DynamicImage,
    format: ImageFormat,
    encode: &impl Fn(&DynamicImage, u8, bool) -> Result<Vec<u8>, String>,
    fits: &impl Fn(&Vec<u8>) -> bool,
    target: f64,
) -> Result<Option<(Vec<u8>, u8, f64)>, String> {
    let source = linear(&*viewed(img)?)?;
    let (mut lo, mut hi) = (SEARCH_LOW as i32, SEARCH_HIGH as i32);
    let mut best: Option<(Vec<u8>, u8, f64)> = None;
    let mut fitting: Option<(Vec<u8>, u8, f64)> = None;
    while lo <= hi {
        let mid = (lo + (hi - lo) / 2) as u8;
        let out = encode(img, mid, false)?;
        if !fits(&out) {
            // Over budget: never scored.
            hi = mid as i32 - 1;
            continue;
        }
        let score = similarity(&source, &seen(&out, format)?)?;
        let replace = match &fitting {
            None => true,
            Some((_, q, _)) => mid > *q,
        };
        if replace {
            fitting = Some((out.clone(), mid, score));
        }
        if score >= target {
            best = Some((out, mid, score));
            hi = mid as i32 - 1;
        } else {
            lo = mid as i32 + 1;
        }
    }
    // The thorough pass, kept when it is smaller and still fits.
    if let Some((out, q, score)) = best {
        return Ok(Some(match encode(img, q, true) {
            Ok(last) if last.len() < out.len() && fits(&last) => {
                let rescore = similarity(&source, &seen(&last, format)?)?;
                if rescore >= target {
                    (last, q, rescore)
                } else {
                    (out, q, score)
                }
            }
            _ => (out, q, score),
        }));
    }
    if let Some((out, q, score)) = fitting {
        return Ok(Some(match encode(img, q, true) {
            Ok(last) if last.len() < out.len() && fits(&last) => {
                let rescore = similarity(&source, &seen(&last, format)?)?;
                if rescore >= score {
                    (last, q, rescore)
                } else {
                    (out, q, score)
                }
            }
            _ => (out, q, score),
        }));
    }
    Ok(None)
}

/// The highest quality whose encoding of [img] [fits]: the bytes and the quality; `None`
/// when even the lowest is over. Quality 100 goes first since it usually fits.
fn largest_fitting(
    img: &DynamicImage,
    encode: &impl Fn(&DynamicImage, u8, bool) -> Result<Vec<u8>, String>,
    fits: &impl Fn(&Vec<u8>) -> bool,
) -> Result<Option<(Vec<u8>, u8)>, String> {
    let top = encode(img, SEARCH_HIGH, false)?;
    if fits(&top) {
        return Ok(Some((top, SEARCH_HIGH)));
    }
    let (mut lo, mut hi) = (SEARCH_LOW as i32, SEARCH_HIGH as i32 - 1);
    let mut best: Option<(Vec<u8>, u8)> = None;
    while lo <= hi {
        let mid = (lo + (hi - lo) / 2) as u8;
        let out = encode(img, mid, false)?;
        if fits(&out) {
            best = Some((out, mid));
            lo = mid as i32 + 1;
        } else {
            hi = mid as i32 - 1;
        }
    }
    Ok(best)
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tk_image_compress(
    handle: *mut c_void,
    format_code: u32,
    quality: u8,
    target: f64,
    max_bytes: u64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    out_quality: *mut u32,
    out_score: *mut f64,
) -> i32 {
    guard(|| {
        let native = img(handle)?;
        let format = code_to_format(format_code).ok_or("Unknown image format code")?;
        if format == ImageFormat::Jpeg && translucent(&native.inner) {
            give(Vec::new(), out_ptr, out_len);
            return Ok(2);
        }
        let found = compress(&native.inner, format, quality, target, max_bytes as usize)?;
        let Some((buf, q, score)) = found else {
            give(Vec::new(), out_ptr, out_len);
            return Ok(1);
        };
        *out_quality = q as u32;
        *out_score = score;
        give(buf, out_ptr, out_len);
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_png(data: *const u8, len: usize, strip: bool, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let data = bytes(data, len);
        let mut opts = oxipng::Options::from_preset(PNG_PRESET);
        opts.strip = match (strip, read_exif_orientation(data)) {
            (false, _) => oxipng::StripChunks::None,
            (true, 2..=8) => oxipng::StripChunks::Keep({
                let mut keep = oxipng::IndexSet::default();
                for chunk in ["cICP", "iCCP", "sRGB", "pHYs", "acTL", "fcTL", "fdAT", "eXIf"] {
                    keep.insert(chunk.as_bytes().try_into().unwrap());
                }
                keep
            }),
            (true, _) => oxipng::StripChunks::Safe,
        };
        let out = oxipng::optimize_from_memory(data, &opts).map_err(|e| e.to_string())?;
        Ok(give(out, out_ptr, out_len))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_hash(handle: *mut c_void, algo: u32) -> u64 {
    let mut result: u64 = 0;
    guard(|| {
        let native = img(handle)?;
        let config = match algo {
            1 => image_hasher::HasherConfig::new().hash_alg(image_hasher::HashAlg::Gradient),
            2 => image_hasher::HasherConfig::new().hash_alg(image_hasher::HashAlg::Mean),
            // pHash: the mean of the low DCT frequencies.
            _ => image_hasher::HasherConfig::new().hash_alg(image_hasher::HashAlg::Mean).preproc_dct(),
        };
        let hasher = config.hash_size(8, 8).to_hasher();
        let h = hasher.hash_image(&native.inner);
        let hash_bytes = h.as_bytes();
        if hash_bytes.len() >= 8 {
            let mut arr = [0u8; 8];
            arr.copy_from_slice(&hash_bytes[..8]);
            result = u64::from_be_bytes(arr);
        }
        Ok(0)
    });
    result
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_dominant_color(handle: *mut c_void) -> u32 {
    let mut color: u32 = 0;
    guard(|| {
        let native = img(handle)?;
        let thumb = native.inner.thumbnail_exact(16, 16);
        let rgba = thumb.to_rgba8();
        let (mut sum_r, mut sum_g, mut sum_b) = (0u64, 0u64, 0u64);
        let mut count = 0u64;
        for p in rgba.pixels() {
            if p[3] > 32 {
                sum_r += p[0] as u64;
                sum_g += p[1] as u64;
                sum_b += p[2] as u64;
                count += 1;
            }
        }
        if count > 0 {
            let avg_r = (sum_r / count) as u32;
            let avg_g = (sum_g / count) as u32;
            let avg_b = (sum_b / count) as u32;
            color = (avg_r << 24) | (avg_g << 16) | (avg_b << 8) | 0xff;
        } else {
            color = 0;
        }
        Ok(0)
    });
    color
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_similarity(a: *mut c_void, b: *mut c_void, out: *mut f64) -> i32 {
    guard(|| {
        let (a, b) = (img(a)?, img(b)?);
        let score = scoring(|| ssimulacra2::compute_frame_ssimulacra2(linear(&a.inner)?, linear(&b.inner)?).map_err(|e| e.to_string()))?;
        unsafe { *out = score };
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_deblock(handle: *mut c_void, strength: f32) -> *mut c_void {
    op(handle, |n| {
        let mut rgba = n.inner.to_rgba8();
        deblock_rgba(&mut rgba, strength);
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

/// One seam p1 p0 | q0 q1 (byte offsets of four pixels): where the step across it is small
/// enough to be an encoder's and both sides are flat, the step is spread over the four pixels.
fn deblock_rgba(rgba: &mut RgbaImage, strength: f32) {
    let (w, h) = (rgba.width() as usize, rgba.height() as usize);
    if w < 10 || h < 10 || strength <= 0.0 {
        return;
    }
    let (alpha, beta, tc) = (24.0 * strength, 6.0 * strength, 6.0 * strength);
    let stride = w * 4;
    // Vertical seams at x = 8, 16, ... while x + 1 < w.
    {
        let mut x = 8usize;
        while x + 1 < w {
            for y in 0..h {
                let at = |dx: isize| y * stride + ((x as isize + dx) * 4) as usize;
                for c in 0..3 {
                    let (a, b, q0, d) = (
                        rgba.as_raw()[at(-2) + c] as f32,
                        rgba.as_raw()[at(-1) + c] as f32,
                        rgba.as_raw()[at(0) + c] as f32,
                        rgba.as_raw()[at(1) + c] as f32,
                    );
                    if (b - q0).abs() >= alpha || (a - b).abs() >= beta || (d - q0).abs() >= beta {
                        continue;
                    }
                    let delta = (((q0 - b) * 4.0 + (a - d)) / 8.0).clamp(-tc, tc);
                    let raw = rgba.as_mut();
                    raw[at(-1) + c] = (b + delta).round().clamp(0.0, 255.0) as u8;
                    raw[at(0) + c] = (q0 - delta).round().clamp(0.0, 255.0) as u8;
                    raw[at(-2) + c] = (a + delta / 2.0).round().clamp(0.0, 255.0) as u8;
                    raw[at(1) + c] = (d - delta / 2.0).round().clamp(0.0, 255.0) as u8;
                }
            }
            x += 8;
        }
    }
    // Horizontal seams: bands of 8 rows, the seam at local row 4.
    let buf = rgba.as_mut();
    if buf.len() >= 4 * stride {
        buf[4 * stride..]
            .par_chunks_mut(8 * stride)
            .for_each(|band| {
                if band.len() < 6 * stride {
                    return;
                }
                for x in 0..w {
                    let at = |r: usize| r * stride + x * 4;
                    for c in 0..3 {
                        let (a, b, q0, d) =
                            (band[at(2) + c] as f32, band[at(3) + c] as f32, band[at(4) + c] as f32, band[at(5) + c] as f32);
                        if (b - q0).abs() >= alpha || (a - b).abs() >= beta || (d - q0).abs() >= beta {
                            continue;
                        }
                        let delta = (((q0 - b) * 4.0 + (a - d)) / 8.0).clamp(-tc, tc);
                        band[at(3) + c] = (b + delta).round().clamp(0.0, 255.0) as u8;
                        band[at(4) + c] = (q0 - delta).round().clamp(0.0, 255.0) as u8;
                        band[at(2) + c] = (a + delta / 2.0).round().clamp(0.0, 255.0) as u8;
                        band[at(5) + c] = (d - delta / 2.0).round().clamp(0.0, 255.0) as u8;
                    }
                }
            });
    }
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_auto_levels(handle: *mut c_void, clip: f32, white_balance: bool) -> *mut c_void {
    op(handle, |n| {
        let mut rgba = n.inner.to_rgba8();
        let (w, h) = (rgba.width() as usize, rgba.height() as usize);
        let mut hist = [[0u64; 256]; 3];
        for px in rgba.as_raw().chunks_exact(4) {
            hist[0][px[0] as usize] += 1;
            hist[1][px[1] as usize] += 1;
            hist[2][px[2] as usize] += 1;
        }
        let n_px = (w * h).max(1) as u64;
        let cut = (n_px as f64 * clip.clamp(0.0, 0.2) as f64) as u64;
        fn bounds(hist: &[u64; 256], cut: u64) -> (u8, u8) {
            let (mut lo, mut seen) = (0u32, 0u64);
            while lo < 255 && seen + hist[lo as usize] <= cut {
                seen += hist[lo as usize];
                lo += 1;
            }
            let (mut hi, mut seen) = (255u32, 0u64);
            while hi > 0 && seen + hist[hi as usize] <= cut {
                seen += hist[hi as usize];
                hi -= 1;
            }
            (lo as u8, hi as u8)
        }
        let mut ends: [(u8, u8); 3] = [bounds(&hist[0], cut), bounds(&hist[1], cut), bounds(&hist[2], cut)];
        if !white_balance {
            let shared = (ends.iter().map(|e| e.0).min().unwrap(), ends.iter().map(|e| e.1).max().unwrap());
            ends = [shared; 3];
        }
        let mut lut = [[0u8; 256]; 3];
        for c in 0..3 {
            let (lo, hi) = ends[c];
            for v in 0..256 {
                lut[c][v] = if hi <= lo.saturating_add(16) {
                    v as u8
                } else {
                    (((v as i32 - lo as i32) * 255 / (hi as i32 - lo as i32)).clamp(0, 255)) as u8
                };
            }
        }
        if white_balance {
            let mut means = [0.0f64; 3];
            for c in 0..3 {
                let mut sum = 0u64;
                for v in 0..256 {
                    sum += hist[c][v] * lut[c][v] as u64;
                }
                means[c] = sum as f64 / n_px as f64;
            }
            let gray = (means[0] + means[1] + means[2]) / 3.0;
            for c in 0..3 {
                let gain = if means[c] > 1.0 { (gray / means[c]).clamp(0.9, 1.1) } else { 1.0 };
                for v in 0..256 {
                    lut[c][v] = ((lut[c][v] as f64 * gain).round().clamp(0.0, 255.0)) as u8;
                }
            }
        }
        for px in rgba.as_mut().chunks_exact_mut(4) {
            px[0] = lut[0][px[0] as usize];
            px[1] = lut[1][px[1] as usize];
            px[2] = lut[2][px[2] as usize];
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_sharpness(handle: *mut c_void) -> f64 {
    let mut out = -1.0;
    guard(|| {
        let native = img(handle)?;
        out = sharpness_of(&native.inner);
        Ok(0)
    });
    out
}

/// Luma variance of the 4-neighbour Laplacian: higher is sharper.
fn sharpness_of(img: &DynamicImage) -> f64 {
    use rayon::prelude::*;
    let small: Cow<DynamicImage>;
    let rgb = if img.width().max(img.height()) > 1024 {
        small = Cow::Owned(resized(img, 1024, 1024, 3, 1).unwrap_or_else(|_| img.clone()));
        rgb8(&small)
    } else {
        rgb8(img)
    };
    let (w, h) = (rgb.width() as usize, rgb.height() as usize);
    if w < 3 || h < 3 {
        return 0.0;
    }
    let luma: Vec<f32> = rgb.pixels().map(|p| 0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32).collect();
    let rows: Vec<(f64, f64)> = (1..h - 1)
        .collect::<Vec<_>>()
        .par_iter()
        .map(|&y| {
            let (mut sum, mut sq) = (0.0f64, 0.0f64);
            for x in 1..w - 1 {
                let l = luma[y * w + x - 1] + luma[y * w + x + 1] + luma[(y - 1) * w + x] + luma[(y + 1) * w + x]
                    - 4.0 * luma[y * w + x];
                sum += l as f64;
                sq += (l * l) as f64;
            }
            (sum, sq)
        })
        .collect();
    let (sum, sq) = rows.into_iter().fold((0.0, 0.0), |(a, b), (s, q)| (a + s, b + q));
    let n = ((w - 2) * (h - 2)) as f64;
    sq / n - (sum / n) * (sum / n)
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_phash_files(paths: *const u8, plen: usize, out: *mut u64, ok: *mut u8, cap: usize) -> i32 {
    guard(|| {
        let joined = text(paths, plen)?;
        let names: Vec<&str> = if joined.is_empty() { Vec::new() } else { joined.split('\0').collect() };
        if names.len() > cap {
            return Err(format!("output holds {} hashes, needs {}", cap, names.len()));
        }
        const PHASH_SIDE: u32 = 256;
        const WHOLE_AT_ONCE: usize = 4;
        fn phash_of(path: &str) -> Result<u64, String> {
            let data = std::fs::read(path).map_err(|e| e.to_string())?;
            let img = decode(&data, 0, PHASH_SIDE)?;
            let up = upright(img, read_exif_orientation(&data));
            let hasher = image_hasher::HasherConfig::new()
                .hash_alg(image_hasher::HashAlg::Mean)
                .preproc_dct()
                .hash_size(8, 8)
                .to_hasher();
            let h = hasher.hash_image(&up);
            let hash_bytes = h.as_bytes();
            if hash_bytes.len() < 8 {
                return Err("phasher gave no bytes".into());
            }
            let mut arr = [0u8; 8];
            arr.copy_from_slice(&hash_bytes[..8]);
            Ok(u64::from_be_bytes(arr))
        }
        let out = unsafe { std::slice::from_raw_parts_mut(out, names.len()) };
        let ok = unsafe { std::slice::from_raw_parts_mut(ok, names.len()) };
        // In trailing batches, so one slow file never blocks the rest.
        use rayon::prelude::*;
        let run = |items: &[(usize, &str)]| {
            items.par_iter().map(|&(i, p)| (i, phash_of(p))).collect::<Vec<_>>()
        };
        let mut order: Vec<(usize, &str)> = names.iter().enumerate().map(|(i, p)| (i, *p)).collect();
        while !order.is_empty() {
            let take = WHOLE_AT_ONCE.min(order.len());
            let batch: Vec<(usize, &str)> = order.split_off(order.len() - take);
            for (i, r) in run(&batch) {
                match r {
                    Ok(h) => {
                        out[i] = h;
                        ok[i] = 1;
                    }
                    Err(_) => {
                        ok[i] = 0;
                    }
                }
            }
        }
        Ok(names.len() as i32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_grid(
    handles: *const *mut c_void,
    count: usize,
    columns: u32,
    cell: u32,
    gap: u32,
    background: u32,
) -> *mut c_void {
    made(|| {
        if count == 0 || columns == 0 || cell == 0 {
            return Err("A grid needs at least one image, one column and a cell of 1 px".to_string());
        }
        let hs = unsafe { std::slice::from_raw_parts(handles, count) };
        let mut thumbs = Vec::with_capacity(count);
        for &h in hs {
            let native = img(h)?;
            let t = resized(&native.inner, cell, cell, 1, 0)?;
            thumbs.push(t.to_rgba8());
        }
        let cols = (columns as usize).min(count);
        let rows = count.div_ceil(cols);
        let (width, height) = (cols as u32 * cell + (cols as u32 + 1) * gap, rows as u32 * cell + (rows as u32 + 1) * gap);
        let bg = background.to_be_bytes();
        let mut canvas = RgbaImage::from_pixel(width, height, Rgba([bg[0], bg[1], bg[2], bg[3]]));
        for (i, t) in thumbs.iter().enumerate() {
            let (c, r) = (i % cols, i / cols);
            let x = gap + c as u32 * (cell + gap) + (cell - t.width()) / 2;
            let y = gap + r as u32 * (cell + gap) + (cell - t.height()) / 2;
            image::imageops::overlay(&mut canvas, t, x as i64, y as i64);
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(canvas)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_crop_smart(handle: *mut c_void, aspect: f64) -> *mut c_void {
    op(handle, |n| {
        if aspect <= 0.0 {
            return Err("Aspect ratio must be positive".to_string());
        }
        let (w, h) = (n.inner.width(), n.inner.height());
        let (cw, ch) = if w as f64 / h as f64 > aspect {
            ((((h as f64 * aspect).round() as u32).min(w)), h)
        } else {
            (w, (((w as f64 / aspect).round() as u32).min(h)))
        };
        let (cw, ch) = (cw.max(1), ch.max(1));
        if cw == w && ch == h {
            return Ok(NativeImage::new(n.inner.clone()));
        }
        let small: Cow<DynamicImage>;
        let work = if w.max(h) > 256 {
            small = Cow::Owned(resized(&n.inner, 256, 256, 3, 1)?);
            &small
        } else {
            &n.inner
        };
        let rgb = work.to_rgb8();
        let (sw, sh) = (rgb.width() as usize, rgb.height() as usize);
        let lum = |x: usize, y: usize| {
            let p = rgb.get_pixel(x as u32, y as u32);
            0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32
        };
        let skin = |x: usize, y: usize| {
            let p = rgb.get_pixel(x as u32, y as u32);
            let (r, g, b) = (p[0] as f32, p[1] as f32, p[2] as f32);
            let cb = 128.0 - 0.168736 * r - 0.331264 * g + 0.5 * b;
            let cr = 128.0 + 0.5 * r - 0.418688 * g - 0.081312 * b;
            (77.0..=127.0).contains(&cb) && (133.0..=173.0).contains(&cr)
        };
        let mut energy = vec![0.0f32; sw * sh];
        let mut max_edge = 1.0f32;
        for y in 1..sh - 1 {
            for x in 1..sw - 1 {
                let gx = lum(x + 1, y - 1) + 2.0 * lum(x + 1, y) + lum(x + 1, y + 1)
                    - lum(x - 1, y - 1)
                    - 2.0 * lum(x - 1, y)
                    - lum(x - 1, y + 1);
                let gy = lum(x - 1, y + 1) + 2.0 * lum(x, y + 1) + lum(x + 1, y + 1)
                    - lum(x - 1, y - 1)
                    - 2.0 * lum(x, y - 1)
                    - lum(x + 1, y - 1);
                let edge = gx.abs() + gy.abs();
                max_edge = max_edge.max(edge);
                energy[y * sw + x] = edge + if skin(x, y) { 0.5 * max_edge } else { 0.0 };
            }
        }
        // Normalize edge by the max (approximating the reference order).
        for v in energy.iter_mut() {
            *v /= max_edge;
        }
        let horizontal = (cw as f64) < (w as f64);
        let (len, span) = if horizontal { (sw, sh) } else { (sh, sw) };
        let mut line = vec![0.0f32; len];
        for i in 0..len {
            let mut sum = 0.0;
            for j in 0..span {
                sum += if horizontal { energy[j * sw + i] } else { energy[i * sw + j] };
            }
            line[i] = sum;
        }
        let frac = if horizontal { cw as f64 / w as f64 } else { ch as f64 / h as f64 };
        let win = ((frac * len as f64).round() as usize).clamp(1, len);
        let (mut best_at, mut best) = (0usize, f32::MIN);
        let mut window_sum: f32 = line.iter().take(win).sum();
        for at in 0..=len - win {
            if at > 0 {
                window_sum += line[at + win - 1] - line[at - 1];
            }
            let d = ((at + win / 2) as f32 - len as f32 / 2.0) / (len as f32 / 2.0);
            let score = window_sum * (1.0 - 0.3 * d * d);
            if score > best {
                best = score;
                best_at = at;
            }
        }
        let (x, y) = if horizontal {
            (((best_at as f64 / len as f64) * w as f64).round() as u32, 0)
        } else {
            (0, ((best_at as f64 / len as f64) * h as f64).round() as u32)
        };
        let (x, y) = (x.min(w - cw), y.min(h - ch));
        Ok(NativeImage::new(DynamicImage::ImageRgba8(
            image::imageops::crop_imm(&n.inner.to_rgba8(), x, y, cw, ch).to_image(),
        )))
    })
}

// ---- RGBA bridge (new in native2)
//
// lib2 owns RGBA pixels in Dart. These two calls move them across: `from_rgba` wraps
// pixels as a handle for encoding/transforms, `to_rgba` reads decoded pixels back.

/// Wraps `w*h*4` RGBA bytes as an image handle; anything else is an error.
#[no_mangle]
pub unsafe extern "C" fn tk_image_from_rgba(data: *const u8, len: usize, w: u32, h: u32) -> *mut c_void {
    made(|| {
        let want = w as usize * h as usize * 4;
        if len != want {
            return Err(format!("RGBA needs {} bytes for {}x{}, not {}", want, w, h, len));
        }
        let rgba = RgbaImage::from_raw(w, h, bytes(data, len).to_vec())
            .ok_or("RGBA buffer gave no image".to_string())?;
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

/// Writes the image's RGBA bytes into `out`; `cap` must hold `w*h*4`. Answers the length.
#[no_mangle]
pub unsafe extern "C" fn tk_image_to_rgba(handle: *mut c_void, out: *mut u8, cap: usize) -> i32 {
    guard(|| {
        let native = img(handle)?;
        let rgba = native.inner.to_rgba8();
        let (w, h) = (rgba.width() as usize, rgba.height() as usize);
        let need = w * h * 4;
        if cap < need {
            return Err(format!("RGBA buffer holds {} bytes, needs {}", cap, need));
        }
        unsafe { std::ptr::copy_nonoverlapping(rgba.as_ptr(), out, need) };
        Ok(need as i32)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blank(w: u32, h: u32, px: [u8; 4]) -> *mut c_void {
        let hdl = unsafe { tk_image_create_blank(w, h, px[0], px[1], px[2], px[3]) };
        assert!(!hdl.is_null());
        hdl
    }

    fn rgba_of(h: *mut c_void) -> (u32, u32, Vec<u8>) {
        let (mut w, mut hgt) = (0u32, 0u32);
        assert_eq!(unsafe { tk_image_dimensions(h, &mut w, &mut hgt) }, 0);
        let mut buf = vec![0u8; w as usize * hgt as usize * 4];
        let n = unsafe { tk_image_to_rgba(h, buf.as_mut_ptr(), buf.len()) };
        assert_eq!(n as usize, buf.len());
        (w, hgt, buf)
    }

    #[test]
    fn rgba_bridge_round_trip() {
        let h = blank(17, 9, [0x44, 0x55, 0x66, 0xFF]);
        let (w, hh, px) = rgba_of(h);
        assert_eq!((w, hh), (17, 9));
        assert!(px.chunks_exact(4).all(|p| p == [0x44, 0x55, 0x66, 0xFF]));
        // And back through from_rgba.
        let h2 = unsafe { tk_image_from_rgba(px.as_ptr(), px.len(), w, hh) };
        assert!(!h2.is_null());
        let (_, _, px2) = rgba_of(h2);
        assert_eq!(px, px2);
        unsafe {
            tk_image_free(h);
            tk_image_free(h2);
        }
        // Wrong length is refused.
        assert!(unsafe { tk_image_from_rgba(px.as_ptr(), px.len() - 1, w, hh) }.is_null());
    }

    #[test]
    fn resize_cover_and_probe() {
        let h = blank(192, 108, [0x11, 0x22, 0x33, 0xFF]);
        let fit = unsafe { tk_image_resize(h, 48, 32, 0, 0) };
        assert!(!fit.is_null());
        let (w, hh, _) = rgba_of(fit);
        assert_eq!((w, hh), (48, 32));
        // Encode PNG through the FFI, probe the bytes, decode them back.
        let (mut ptr, mut len) = (std::ptr::null_mut(), 0usize);
        assert_eq!(unsafe { tk_image_encode_memory(h, 2, 0, false, &mut ptr, &mut len) }, 0);
        let png = unsafe { std::slice::from_raw_parts(ptr, len).to_vec() };
        unsafe { tk_common::free(ptr, len) };
        let (mut pw, mut ph, mut pf) = (0usize, 0usize, 0usize);
        assert_eq!(unsafe { tk_image_probe_memory(png.as_ptr(), png.len(), &mut pw, &mut ph, &mut pf) }, 0);
        assert_eq!((pw, ph, pf), (192, 108, 2));
        let back = unsafe { tk_image_load_memory(png.as_ptr(), png.len(), 0, 0) };
        assert!(!back.is_null());
        let (w, hh, px) = rgba_of(back);
        assert_eq!((w, hh), (192, 108));
        assert!(px.chunks_exact(4).all(|p| p == [0x11, 0x22, 0x33, 0xFF]));
        unsafe {
            tk_image_free(h);
            tk_image_free(fit);
            tk_image_free(back);
        }
    }

    #[test]
    fn ops_keep_dims_and_solid_stays_solid() {
        let h = blank(16, 16, [0x10, 0x20, 0x30, 0xFF]);
        let blurred = unsafe { tk_image_blur(h, 2.0) };
        let (_, _, px) = rgba_of(blurred);
        assert!(px.chunks_exact(4).all(|p| p == [0x10, 0x20, 0x30, 0xFF]));
        let gray = unsafe { tk_image_grayscale(h) };
        let (_, _, gpx) = rgba_of(gray);
        assert!(gpx.chunks_exact(4).all(|p| p[0] == p[1] && p[1] == p[2] && p[3] == 0xFF));
        unsafe {
            tk_image_free(h);
            tk_image_free(blurred);
            tk_image_free(gray);
        }
    }
}

