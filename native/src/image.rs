use std::borrow::Cow;
use std::ffi::c_void;
use std::fs::File;
use std::io::{Cursor, Read};

use fast_image_resize as fr;
use image::{
    codecs::bmp::BmpEncoder, codecs::jpeg::JpegEncoder, codecs::png::PngEncoder,
    codecs::tiff::TiffEncoder, DynamicImage, ImageEncoder, ImageFormat, ImageReader, Rgba,
    RgbaImage,
};
use image_hasher::{HashAlg, HasherConfig};
use libwebp_sys as webp;
use rayon::prelude::*;

use crate::{bytes, give, guard, text, Msg};

/// How much of a file the header readers look at before they walk the whole thing. 128 KiB
/// covers a JPEG's EXIF, thumbnail and ICC profile; a photo whose frame header sits past that
/// falls back to the walking reader, so the fast path never costs correctness.
const HEADER_BYTES: usize = 128 * 1024;

/// An image as it is seen: decoding turns it upright by its EXIF orientation, so no transform
/// works in the camera's sensor space.
pub struct NativeImage {
    pub inner: DynamicImage,
}

impl NativeImage {
    pub fn new(inner: DynamicImage) -> Self {
        Self { inner }
    }
}

/// The image behind `h`, or an error naming the null handle.
unsafe fn img<'a>(h: *mut c_void) -> Result<&'a NativeImage, String> {
    if h.is_null() {
        return Err("Invalid null image handle".to_string());
    }
    Ok(&*(h as *mut NativeImage))
}

/// Runs `f` under `guard` and hands its image back as a handle, or null when it failed.
fn made(f: impl FnOnce() -> Result<NativeImage, String>) -> *mut c_void {
    let mut out: *mut c_void = std::ptr::null_mut();
    guard(|| {
        out = Box::into_raw(Box::new(f()?)) as *mut c_void;
        Ok(0)
    });
    out
}

/// [`made`] for a transform of the image behind `h`.
unsafe fn op(h: *mut c_void, f: impl FnOnce(&NativeImage) -> Result<NativeImage, String>) -> *mut c_void {
    made(|| f(img(h)?))
}

fn read_exif_orientation_from_bytes(data: &[u8]) -> u32 {
    let mut cursor = Cursor::new(data);
    let exifreader = exif::Reader::new();
    if let Ok(exif) = exifreader.read_from_container(&mut cursor) {
        if let Some(field) = exif.get_field(exif::Tag::Orientation, exif::In::PRIMARY) {
            if let Some(val) = field.value.get_uint(0) {
                return val;
            }
        }
    }
    1
}

fn read_exif_orientation_from_file(path: &str) -> u32 {
    if let Ok(mut file) = File::open(path) {
        let mut buf = Vec::new();
        let _ = (&mut file).take(128 * 1024).read_to_end(&mut buf);
        read_exif_orientation_from_bytes(&buf)
    } else {
        1
    }
}

/// [img] turned upright by the EXIF [orientation] (1–8; anything else leaves it).
fn upright(img: DynamicImage, orientation: u32) -> DynamicImage {
    match orientation {
        2 => img.fliph(),
        3 => img.rotate180(),
        4 => img.flipv(),
        5 => img.rotate90().fliph(),
        6 => img.rotate90(),
        7 => img.rotate270().fliph(),
        8 => img.rotate270(),
        _ => img,
    }
}

/// [img] with no side longer than [max_side] (0: as it is), shrunk to fit as `tk_image_resize`
/// does.
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
        None => reader = reader.with_guessed_format().msg()?,
    }
    fit(reader.decode().msg()?, max_side)
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_load_file(path: *const u8, plen: usize, max_side: u32) -> *mut c_void {
    made(|| {
        let p = text(path, plen)?;
        let orient = read_exif_orientation_from_file(p);
        if max_side > 0 {
            // Whole, so a JPEG can be decoded at its scaled size.
            return Ok(NativeImage::new(upright(decode(&std::fs::read(p).msg()?, 0, max_side)?, orient)));
        }
        // By content: a PNG saved as `.jpg` still opens.
        let img = ImageReader::open(p).msg()?.with_guessed_format().msg()?.decode().msg()?;
        Ok(NativeImage::new(upright(img, orient)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_load_memory(
    data: *const u8,
    dlen: usize,
    format_code: u32,
    max_side: u32,
) -> *mut c_void {
    made(|| {
        let slice = bytes(data, dlen);
        let orient = read_exif_orientation_from_bytes(slice);
        Ok(NativeImage::new(upright(decode(slice, format_code, max_side)?, orient)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_create_blank(
    width: u32,
    height: u32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> *mut c_void {
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
pub unsafe extern "C" fn tk_image_dimensions(
    handle: *mut c_void,
    out_width: *mut u32,
    out_height: *mut u32,
) -> i32 {
    guard(|| {
        let native = img(handle)?;
        *out_width = native.inner.width();
        *out_height = native.inner.height();
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// Probing & Verification
// ---------------------------------------------------------------------------

/// The Dart `ImageFormat.code` of a header's format, or 0 when it is none of them.
fn format_code(fmt: imagesize::ImageResult<imagesize::ImageType>) -> usize {
    match fmt {
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
        // One open, one read: the frame header is in the first bytes of every format this
        // library writes, and opening the file twice doubled the syscall cost of a scan.
        let mut header = vec![0u8; HEADER_BYTES];
        let mut f = File::open(p).msg()?;
        let n = f.read(&mut header).unwrap_or(0);
        drop(f);
        let head = &header[..n];

        let size = match imagesize::blob_size(head) {
            Ok(s) => s,
            // A frame header past the prefix: the walking reader still finds the dimensions.
            Err(_) => imagesize::size(p).msg()?,
        };

        *out_width = size.width;
        *out_height = size.height;
        *out_format = format_code(imagesize::image_type(head));
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
        let size = imagesize::blob_size(slice).msg()?;
        *out_width = size.width;
        *out_height = size.height;
        *out_format = format_code(imagesize::image_type(slice));
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// Geometric Transformations
// ---------------------------------------------------------------------------

fn calculate_fit(
    src_w: u32,
    src_h: u32,
    target_w: u32,
    target_h: u32,
    fit_mode: u32,
) -> (u32, u32) {
    if target_h == 0 {
        let h = ((target_w as f64 * src_h as f64) / src_w as f64).round() as u32;
        return (target_w.max(1), h.max(1));
    }
    if target_w == 0 {
        let w = ((target_h as f64 * src_w as f64) / src_h as f64).round() as u32;
        return (w.max(1), target_h.max(1));
    }

    match fit_mode {
        // 0: cover
        0 => {
            let scale_w = target_w as f64 / src_w as f64;
            let scale_h = target_h as f64 / src_h as f64;
            let scale = scale_w.max(scale_h);
            (
                (src_w as f64 * scale).round() as u32,
                (src_h as f64 * scale).round() as u32,
            )
        }
        // 1: contain
        1 => {
            let scale_w = target_w as f64 / src_w as f64;
            let scale_h = target_h as f64 / src_h as f64;
            let scale = scale_w.min(scale_h);
            (
                (src_w as f64 * scale).round() as u32,
                (src_h as f64 * scale).round() as u32,
            )
        }
        // 2: fill
        2 => (target_w, target_h),
        // 3: inside
        3 => {
            if src_w <= target_w && src_h <= target_h {
                (src_w, src_h)
            } else {
                let scale_w = target_w as f64 / src_w as f64;
                let scale_h = target_h as f64 / src_h as f64;
                let scale = scale_w.min(scale_h);
                (
                    (src_w as f64 * scale).round() as u32,
                    (src_h as f64 * scale).round() as u32,
                )
            }
        }
        _ => (target_w, target_h),
    }
}

/// The interleaved 8-bit plane the resampler reads: RGB unless the image carries alpha, which
/// is a third less memory to walk on every 60 MP photo a camera produces.
fn resample_plane(img: &DynamicImage) -> (Cow<'_, [u8]>, usize) {
    if img.color().has_alpha() {
        match img {
            DynamicImage::ImageRgba8(buf) => (Cow::Borrowed(buf.as_raw()), 4),
            other => (Cow::Owned(other.to_rgba8().into_raw()), 4),
        }
    } else {
        match img {
            DynamicImage::ImageRgb8(buf) => (Cow::Borrowed(buf.as_raw()), 3),
            other => (Cow::Owned(other.to_rgb8().into_raw()), 3),
        }
    }
}

/// Area-average shrink, one task per band of destination rows.
///
/// This is the shrink-on-load step a big downscale needs: Lanczos over 60 MP reads and weights
/// 60 million pixels, while averaging to twice the target reads them once and hands the kernel
/// an image small enough that the kernel is no longer the cost.
fn area_shrink(src: &[u8], sw: usize, sh: usize, channels: usize, dw: usize, dh: usize) -> Vec<u8> {
    let mut out = vec![0u8; dw * dh * channels];
    let row_bytes = dw * channels;
    let band = ((1 << 20) / row_bytes).max(1);

    out.par_chunks_mut(row_bytes * band)
        .enumerate()
        .for_each(|(task, chunk)| {
            let first_row = task * band;
            for (i, dst_row) in chunk.chunks_mut(row_bytes).enumerate() {
                let y = first_row + i;
                let y0 = y * sh / dh;
                let y1 = (((y + 1) * sh).div_ceil(dh)).clamp(y0 + 1, sh);
                for x in 0..dw {
                    let x0 = x * sw / dw;
                    let x1 = (((x + 1) * sw).div_ceil(dw)).clamp(x0 + 1, sw);
                    // u64: a block of a tiny target can hold tens of millions of pixels.
                    let mut acc = [0u64; 4];
                    let mut count = 0u64;
                    for sy in y0..y1 {
                        let line = &src[(sy * sw + x0) * channels..(sy * sw + x1) * channels];
                        if channels == 4 {
                            // Colour weighted by alpha, as the resampler does: a transparent
                            // pixel's hidden RGB must not darken the edge it averages into.
                            for px in line.chunks_exact(4) {
                                let a = px[3] as u64;
                                acc[0] += px[0] as u64 * a;
                                acc[1] += px[1] as u64 * a;
                                acc[2] += px[2] as u64 * a;
                                acc[3] += a;
                            }
                        } else {
                            for px in line.chunks_exact(channels) {
                                for (sum, &v) in acc.iter_mut().zip(px) {
                                    *sum += v as u64;
                                }
                            }
                        }
                        count += (x1 - x0) as u64;
                    }
                    let base = x * channels;
                    if channels == 4 {
                        let alpha = acc[3];
                        for c in 0..3 {
                            dst_row[base + c] = if alpha == 0 { 0 } else { ((acc[c] + alpha / 2) / alpha) as u8 };
                        }
                        dst_row[base + 3] = ((alpha + count / 2) / count) as u8;
                    } else {
                        for c in 0..channels {
                            dst_row[base + c] = ((acc[c] + count / 2) / count) as u8;
                        }
                    }
                }
            }
        });

    out
}

fn expand_rgb_to_rgba(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len() / 3 * 4);
    for px in src.chunks_exact(3) {
        out.extend_from_slice(&[px[0], px[1], px[2], 255]);
    }
    out
}

/// [src] resized as `tk_image_resize` does: [fit_mode] and [filter_code] are `ImageFit` and
/// `ImageFilter` indexes.
fn resized(src: &DynamicImage, target_w: u32, target_h: u32, fit_mode: u32, filter_code: u32) -> Result<DynamicImage, String> {
    let src_w = src.width();
    let src_h = src.height();

    let (mut dw, mut dh) = calculate_fit(src_w, src_h, target_w, target_h, fit_mode);
    dw = dw.max(1);
    dh = dh.max(1);

    let (plane, channels) = resample_plane(src);
    // The kernel reads the plane where it lies, RGB staying three bytes a pixel; only the
    // smaller destination is widened to RGBA.
    let shrunk;
    let (work_w, work_h, work_plane): (u32, u32, &[u8]) = if dw * 2 <= src_w && dh * 2 <= src_h {
        let pw = (dw * 2) as usize;
        let ph = (dh * 2) as usize;
        shrunk = area_shrink(&plane, src_w as usize, src_h as usize, channels, pw, ph);
        (pw as u32, ph as u32, &shrunk)
    } else {
        (src_w, src_h, &plane)
    };
    let pixel = if channels == 4 { fr::PixelType::U8x4 } else { fr::PixelType::U8x3 };

    let src_view = fr::images::ImageRef::new(work_w, work_h, work_plane, pixel).msg()?;

    let mut dst_view = fr::images::Image::new(dw, dh, pixel);
    let mut resizer = fr::Resizer::new();

    let filter = match filter_code {
        1 => fr::ResizeAlg::Convolution(fr::FilterType::Bilinear),
        2 => fr::ResizeAlg::Nearest,
        _ => fr::ResizeAlg::Convolution(fr::FilterType::Lanczos3),
    };

    resizer
        .resize(
            &src_view,
            &mut dst_view,
            &fr::ResizeOptions::new().resize_alg(filter),
        )
        .msg()?;

    let out = dst_view.into_vec();
    let out = if channels == 4 { out } else { expand_rgb_to_rgba(&out) };
    let rgba = RgbaImage::from_raw(dw, dh, out).ok_or("Failed to build image")?;

    let final_img = if fit_mode == 0 && target_w > 0 && target_h > 0 && (dw > target_w || dh > target_h) {
        let cx = (dw.saturating_sub(target_w)) / 2;
        let cy = (dh.saturating_sub(target_h)) / 2;
        let sub = image::imageops::crop_imm(&rgba, cx, cy, target_w, target_h).to_image();
        DynamicImage::ImageRgba8(sub)
    } else {
        DynamicImage::ImageRgba8(rgba)
    };

    Ok(final_img)
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_resize(
    handle: *mut c_void,
    target_w: u32,
    target_h: u32,
    fit_mode: u32,
    filter_code: u32,
) -> *mut c_void {
    op(handle, |native| {
        let out = resized(&native.inner, target_w, target_h, fit_mode, filter_code)?;
        Ok(NativeImage::new(out))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_crop(
    handle: *mut c_void,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) -> *mut c_void {
    op(handle, |native| {
        let cropped = native.inner.crop_imm(x, y, width, height);
        Ok(NativeImage::new(cropped))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_crop_aspect(
    handle: *mut c_void,
    target_aspect: f64,
    align_x: f32,
    align_y: f32,
) -> *mut c_void {
    made(|| {
        let native = img(handle)?;
        if target_aspect <= 0.0 {
            return Err("Aspect ratio must be positive".to_string());
        }
        let w = native.inner.width() as f64;
        let h = native.inner.height() as f64;
        let current_aspect = w / h;

        let (crop_w, crop_h) = if current_aspect > target_aspect {
            let new_w = (h * target_aspect).round().min(w);
            (new_w, h)
        } else {
            let new_h = (w / target_aspect).round().min(h);
            (w, new_h)
        };

        let crop_w = (crop_w as u32).max(1);
        let crop_h = (crop_h as u32).max(1);

        let rem_x = native.inner.width().saturating_sub(crop_w);
        let rem_y = native.inner.height().saturating_sub(crop_h);

        let ax = align_x.clamp(0.0, 1.0);
        let ay = align_y.clamp(0.0, 1.0);

        let x = (rem_x as f32 * ax).round() as u32;
        let y = (rem_y as f32 * ay).round() as u32;

        let cropped = native.inner.crop_imm(x, y, crop_w, crop_h);
        Ok(NativeImage::new(cropped))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_rotate(handle: *mut c_void, degrees: i32) -> *mut c_void {
    op(handle, |native| {
        let normalized = ((degrees % 360) + 360) % 360;
        let rotated = match normalized {
            90 => native.inner.rotate90(),
            180 => native.inner.rotate180(),
            270 => native.inner.rotate270(),
            0 => native.inner.clone(),
            _ => return Err("Only rotations by 90, 180, or 270 degrees are supported".to_string()),
        };
        Ok(NativeImage::new(rotated))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_flip(
    handle: *mut c_void,
    horizontal: bool,
    vertical: bool,
) -> *mut c_void {
    op(handle, |native| {
        // One copy: each flip makes its own, so cloning first made two.
        let img = match (horizontal, vertical) {
            (true, false) => native.inner.fliph(),
            (false, true) => native.inner.flipv(),
            (true, true) => native.inner.rotate180(),
            _ => native.inner.clone(),
        };
        Ok(NativeImage::new(img))
    })
}

#[no_mangle]
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
    op(handle, |native| {
        let new_w = native.inner.width() + left + right;
        let new_h = native.inner.height() + top + bottom;

        let mut canvas = RgbaImage::from_pixel(new_w, new_h, Rgba([r, g, b, a]));
        image::imageops::overlay(&mut canvas, &native.inner.to_rgba8(), left as i64, top as i64);

        Ok(NativeImage::new(DynamicImage::ImageRgba8(canvas)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_trim(handle: *mut c_void, threshold: u8) -> *mut c_void {
    op(handle, |native| {
        let rgba = native.inner.to_rgba8();
        let w = rgba.width();
        let h = rgba.height();

        if w == 0 || h == 0 {
            return Ok(NativeImage::new(native.inner.clone()));
        }

        let bg = rgba.get_pixel(0, 0);

        let diff = |p: &Rgba<u8>| -> bool {
            let dr = (p[0] as i16 - bg[0] as i16).abs() as u8;
            let dg = (p[1] as i16 - bg[1] as i16).abs() as u8;
            let db = (p[2] as i16 - bg[2] as i16).abs() as u8;
            let da = (p[3] as i16 - bg[3] as i16).abs() as u8;
            dr > threshold || dg > threshold || db > threshold || da > threshold
        };

        let mut min_x = w;
        let mut min_y = h;
        let mut max_x = 0;
        let mut max_y = 0;
        let mut found = false;

        for y in 0..h {
            for x in 0..w {
                if diff(rgba.get_pixel(x, y)) {
                    found = true;
                    if x < min_x { min_x = x; }
                    if x > max_x { max_x = x; }
                    if y < min_y { min_y = y; }
                    if y > max_y { max_y = y; }
                }
            }
        }

        let trimmed = if found && min_x <= max_x && min_y <= max_y {
            let crop_w = (max_x - min_x + 1).min(w);
            let crop_h = (max_y - min_y + 1).min(h);
            native.inner.crop_imm(min_x, min_y, crop_w, crop_h)
        } else {
            native.inner.clone()
        };

        Ok(NativeImage::new(trimmed))
    })
}

// ---------------------------------------------------------------------------
// Color & Filters
// ---------------------------------------------------------------------------

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
    op(handle, |native| {
        let mut rgba = native.inner.to_rgba8();

        let b_offset = brightness * 255.0;
        let inv_gamma = if gamma > 0.0 { 1.0 / gamma } else { 1.0 };
        let temp_offset = temperature * 30.0;
        let tint_offset = tint * 30.0;

        // Rows are independent, and 60 MP is 60 million of these.
        let stride = rgba.width() as usize * 4;
        rgba.as_mut()
            .par_chunks_mut(stride)
            .for_each(|line| {
                for pixel in line.chunks_exact_mut(4) {
                let mut r = pixel[0] as f32;
                let mut g = pixel[1] as f32;
                let mut b = pixel[2] as f32;

                if brightness != 0.0 {
                    r += b_offset;
                    g += b_offset;
                    b += b_offset;
                }

                if contrast != 1.0 {
                    r = (r - 128.0) * contrast + 128.0;
                    g = (g - 128.0) * contrast + 128.0;
                    b = (b - 128.0) * contrast + 128.0;
                }

                if saturation != 1.0 {
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b;
                    r = lum + saturation * (r - lum);
                    g = lum + saturation * (g - lum);
                    b = lum + saturation * (b - lum);
                }

                if temperature != 0.0 {
                    r += temp_offset;
                    b -= temp_offset;
                }
                if tint != 0.0 {
                    g -= tint_offset;
                    r += tint_offset * 0.5;
                    b += tint_offset * 0.5;
                }

                if gamma != 1.0 && gamma > 0.0 {
                    let norm_r = (r / 255.0).clamp(0.0, 1.0);
                    let norm_g = (g / 255.0).clamp(0.0, 1.0);
                    let norm_b = (b / 255.0).clamp(0.0, 1.0);
                    r = norm_r.powf(inv_gamma) * 255.0;
                    g = norm_g.powf(inv_gamma) * 255.0;
                    b = norm_b.powf(inv_gamma) * 255.0;
                }

                pixel[0] = r.clamp(0.0, 255.0).round() as u8;
                pixel[1] = g.clamp(0.0, 255.0).round() as u8;
                pixel[2] = b.clamp(0.0, 255.0).round() as u8;
            }
        });

        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_grayscale(handle: *mut c_void) -> *mut c_void {
    op(handle, |native| {
        let gray = native.inner.grayscale();
        Ok(NativeImage::new(gray))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_invert(handle: *mut c_void) -> *mut c_void {
    op(handle, |native| {
        let mut rgba = native.inner.to_rgba8();
        image::imageops::invert(&mut rgba);
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_sepia(handle: *mut c_void) -> *mut c_void {
    op(handle, |native| {
        let mut rgba = native.inner.to_rgba8();
        let stride = rgba.width() as usize * 4;
        rgba.as_mut().par_chunks_mut(stride).for_each(|line| {
            for p in line.chunks_exact_mut(4) {
                let r = p[0] as f32;
                let g = p[1] as f32;
                let b = p[2] as f32;

                let tr = 0.393 * r + 0.769 * g + 0.189 * b;
                let tg = 0.349 * r + 0.686 * g + 0.168 * b;
                let tb = 0.272 * r + 0.534 * g + 0.131 * b;

                p[0] = tr.min(255.0).round() as u8;
                p[1] = tg.min(255.0).round() as u8;
                p[2] = tb.min(255.0).round() as u8;
            }
        });
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_blur(handle: *mut c_void, sigma: f32) -> *mut c_void {
    op(handle, |native| {
        let blurred = native.inner.blur(sigma);
        Ok(NativeImage::new(blurred))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_sharpen(
    handle: *mut c_void,
    amount: f32,
    sigma: f32,
) -> *mut c_void {
    op(handle, |native| {
        // Unsharp mask: each colour moves away from its blurred self by [amount]. image's own
        // `unsharpen` takes a threshold, not a strength.
        let mut rgba = native.inner.to_rgba8();
        let blurred = image::imageops::blur(&rgba, sigma);
        let stride = rgba.width() as usize * 4;
        rgba.as_mut()
            .par_chunks_mut(stride.max(1))
            .zip(blurred.as_raw().par_chunks(stride.max(1)))
            .for_each(|(line, soft)| {
                for (p, b) in line.chunks_exact_mut(4).zip(soft.chunks_exact(4)) {
                    for c in 0..3 {
                        let v = p[c] as f32 + amount * (p[c] as f32 - b[c] as f32);
                        p[c] = v.round().clamp(0.0, 255.0) as u8;
                    }
                }
            });
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_denoise(handle: *mut c_void, radius: u32) -> *mut c_void {
    op(handle, |native| {
        let sigma = (radius as f32 * 0.5).max(0.5);
        let denoised = native.inner.blur(sigma);
        Ok(NativeImage::new(denoised))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_vignette(handle: *mut c_void, amount: f32) -> *mut c_void {
    op(handle, |native| {
        let mut rgba = native.inner.to_rgba8();
        let w = rgba.width() as f32;
        let h = rgba.height() as f32;
        let cx = w / 2.0;
        let cy = h / 2.0;
        let max_dist = (cx * cx + cy * cy).sqrt();
        let amt = amount.clamp(0.0, 1.0);

        let stride = rgba.width() as usize * 4;
        rgba.as_mut().par_chunks_mut(stride).enumerate().for_each(|(y, line)| {
            for (x, pixel) in line.chunks_exact_mut(4).enumerate() {
                let dx = x as f32 - cx;
                let dy = y as f32 - cy;
                let dist = (dx * dx + dy * dy).sqrt() / max_dist;
                let factor = (1.0 - amt * dist * dist).clamp(0.0, 1.0);

                pixel[0] = (pixel[0] as f32 * factor).round() as u8;
                pixel[1] = (pixel[1] as f32 * factor).round() as u8;
                pixel[2] = (pixel[2] as f32 * factor).round() as u8;
            }
        });

        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

// ---------------------------------------------------------------------------
// Watermark & Compositing
// ---------------------------------------------------------------------------

fn blend_pixels(
    dst: &mut Rgba<u8>,
    src: &Rgba<u8>,
    opacity: f32,
    blend_mode: u32,
) {
    let src_a = (src[3] as f32 / 255.0) * opacity;
    if src_a <= 0.0 {
        return;
    }
    let dst_a = dst[3] as f32 / 255.0;

    let s_r = src[0] as f32 / 255.0;
    let s_g = src[1] as f32 / 255.0;
    let s_b = src[2] as f32 / 255.0;

    let d_r = dst[0] as f32 / 255.0;
    let d_g = dst[1] as f32 / 255.0;
    let d_b = dst[2] as f32 / 255.0;

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
    // W3C compositing: where the backdrop is transparent the mode has nothing to mix with, so
    // the source shows as it is: Cs' = (1 - αb)·Cs + αb·B(Cb, Cs).
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

        let base_w = base.width() as i64;
        let base_h = base.height() as i64;
        let ov_w = overlay.width() as i64;
        let ov_h = overlay.height() as i64;

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

        let bg_w = bg.inner.width();
        let bg_h = bg.inner.height();

        let scaled_wm = if scale > 0.0 {
            let target_w = (bg_w as f32 * scale).round() as u32;
            let target_w = target_w.max(1);
            let target_h = ((target_w as f64 * wm.inner.height() as f64) / wm.inner.width() as f64).round() as u32;
            wm.inner.resize_exact(target_w, target_h.max(1), image::imageops::FilterType::Lanczos3)
        } else {
            wm.inner.clone()
        };

        let wm_w = scaled_wm.width() as i32;
        let wm_h = scaled_wm.height() as i32;
        let bg_wi = bg_w as i32;
        let bg_hi = bg_h as i32;

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
pub unsafe extern "C" fn tk_image_mask(
    handle: *mut c_void,
    mask_handle: *mut c_void,
) -> *mut c_void {
    made(|| {
        let native = img(handle)?;
        let mask = img(mask_handle)?;

        let mut base = native.inner.to_rgba8();
        let mask_gray = mask.inner.to_luma8();

        let w = base.width().min(mask_gray.width());
        let h = base.height().min(mask_gray.height());

        for y in 0..h {
            for x in 0..w {
                let m_val = mask_gray.get_pixel(x, y)[0] as f32 / 255.0;
                let p = base.get_pixel_mut(x, y);
                p[3] = ((p[3] as f32) * m_val).round() as u8;
            }
        }

        Ok(NativeImage::new(DynamicImage::ImageRgba8(base)))
    })
}

static FONT_8X16: &[u8; 4096] = include_bytes!("font8x16.bin");

fn draw_char_8x16(
    img: &mut RgbaImage,
    c: char,
    x: i32,
    y: i32,
    scale: u32,
    color: Rgba<u8>,
) {
    let ascii = (c as usize).min(255);
    let offset = ascii * 16;
    let glyph = &FONT_8X16[offset..offset + 16];

    for (row, &byte) in glyph.iter().enumerate() {
        for col in 0..8 {
            if (byte & (0x80 >> col)) != 0 {
                let px = x + (col as i32 * scale as i32);
                let py = y + (row as i32 * scale as i32);
                for dy in 0..scale as i32 {
                    for dx in 0..scale as i32 {
                        let fx = px + dx;
                        let fy = py + dy;
                        if fx >= 0 && fx < img.width() as i32 && fy >= 0 && fy < img.height() as i32 {
                            let dst = img.get_pixel_mut(fx as u32, fy as u32);
                            blend_pixels(dst, &color, 1.0, 0);
                        }
                    }
                }
            }
        }
    }
}

#[no_mangle]
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
    op(handle, |native| {
        let s = text(text_ptr, text_len)?;

        let mut base = native.inner.to_rgba8();
        let scale = (font_size / 16).max(1);

        let c_r = ((color_rgba >> 24) & 0xff) as u8;
        let c_g = ((color_rgba >> 16) & 0xff) as u8;
        let c_b = ((color_rgba >> 8) & 0xff) as u8;
        let c_a = (color_rgba & 0xff) as u8;
        let fg = Rgba([c_r, c_g, c_b, c_a]);

        let s_r = ((shadow_rgba >> 24) & 0xff) as u8;
        let s_g = ((shadow_rgba >> 16) & 0xff) as u8;
        let s_b = ((shadow_rgba >> 8) & 0xff) as u8;
        let s_a = (shadow_rgba & 0xff) as u8;
        let shadow = Rgba([s_r, s_g, s_b, s_a]);

        let char_w = 8 * scale as i32;

        if has_shadow {
            let shadow_offset = scale as i32;
            let mut cur_x = x + shadow_offset;
            for ch in s.chars() {
                draw_char_8x16(&mut base, ch, cur_x, y + shadow_offset, scale, shadow);
                cur_x += char_w;
            }
        }

        let mut cur_x = x;
        for ch in s.chars() {
            draw_char_8x16(&mut base, ch, cur_x, y, scale, fg);
            cur_x += char_w;
        }

        Ok(NativeImage::new(DynamicImage::ImageRgba8(base)))
    })
}

// ---------------------------------------------------------------------------
// Encoders, Save & Analysis
// ---------------------------------------------------------------------------

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

/// WebP through libwebp, because the `image` crate only writes WebP losslessly and a lossless
/// 60 MP frame is larger than the JPEG it came from.
///
/// The advanced entry point takes one `0xAARRGGBB` plane and splits the rows across threads
/// itself; the convenience encoders are single-threaded, which on a 60 MP photo is minutes.
fn encode_webp(img: &DynamicImage, quality: u8, lossless: bool) -> Result<Vec<u8>, String> {
    let (w, h) = (img.width() as i32, img.height() as i32);
    if w <= 0 || h <= 0 || w as u32 > webp::WEBP_MAX_DIMENSION || h as u32 > webp::WEBP_MAX_DIMENSION {
        return Err(format!("WebP cannot hold {}x{}", w, h));
    }
    let has_alpha = img.color().has_alpha();
    let mut plane: Vec<u32> = match img {
        DynamicImage::ImageRgba8(buf) => buf
            .as_raw()
            .chunks_exact(4)
            .map(|p| u32::from_le_bytes([p[2], p[1], p[0], p[3]]))
            .collect(),
        DynamicImage::ImageRgb8(buf) => buf
            .as_raw()
            .chunks_exact(3)
            .map(|p| 0xff00_0000 | ((p[0] as u32) << 16) | ((p[1] as u32) << 8) | p[2] as u32)
            .collect(),
        other if has_alpha => other
            .to_rgba8()
            .as_raw()
            .chunks_exact(4)
            .map(|p| u32::from_le_bytes([p[2], p[1], p[0], p[3]]))
            .collect(),
        other => other
            .to_rgb8()
            .as_raw()
            .chunks_exact(3)
            .map(|p| 0xff00_0000 | ((p[0] as u32) << 16) | ((p[1] as u32) << 8) | p[2] as u32)
            .collect(),
    };

    let quality = quality.clamp(1, 100) as f32;
    let abi = webp::WEBP_ENCODER_ABI_VERSION as i32;

    unsafe {
        let mut config: webp::WebPConfig = std::mem::zeroed();
        if webp::WebPConfigInitInternal(&mut config, webp::WebPPreset::WEBP_PRESET_PHOTO, quality, abi) != 1 {
            return Err("libwebp refused the encoder configuration".to_string());
        }
        config.lossless = i32::from(lossless);
        config.quality = quality;
        // Method 2 rather than libwebp's default 4: on 60 MP photos the slower search returns
        // 0-25% smaller files for 4-10x the time, which is the wrong trade for batch
        // conversion. Method 1 is cheaper again, but its bitstream buffer overflows above
        // q89 on very large images, and libwebp reports that as a failed encode.
        config.method = 2;
        config.thread_level = 1;
        config.exact = i32::from(has_alpha);

        let mut picture: webp::WebPPicture = std::mem::zeroed();
        if webp::WebPPictureInitInternal(&mut picture, abi) != 1 {
            return Err("libwebp refused the picture".to_string());
        }
        picture.use_argb = 0;
        picture.width = w;
        picture.height = h;
        picture.colorspace = if has_alpha {
            webp::WebPEncCSP::WEBP_YUV420A
        } else {
            webp::WebPEncCSP::WEBP_YUV420
        };
        picture.argb = plane.as_mut_ptr();
        picture.argb_stride = w;

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
    let rgb = img.to_rgb8();
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
    let mut started = comp.start_compress(Vec::new()).msg()?;
    started.write_scanlines(rgb.as_raw()).msg()?;
    started.finish().msg()
}

/// [img] as a PNG, then recompressed by oxipng: the same pixels in fewer bytes.
fn encode_png(img: &DynamicImage) -> Result<Vec<u8>, String> {
    let rgba = img.to_rgba8();
    let mut raw = Vec::new();
    PngEncoder::new(&mut raw)
        .write_image(
            rgba.as_raw(),
            rgba.width(),
            rgba.height(),
            image::ExtendedColorType::Rgba8,
        )
        .msg()?;
    oxipng::optimize_from_memory(&raw, &oxipng::Options::from_preset(PNG_PRESET)).msg()
}

/// oxipng's effort: 2 is its default, a few hundred milliseconds for a 2 MP image.
const PNG_PRESET: u8 = 2;

fn encode_image(
    img: &DynamicImage,
    format: ImageFormat,
    quality: u8,
    lossless: bool,
) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    match format {
        ImageFormat::Jpeg => {
            let rgb = img.to_rgb8();
            let encoder = JpegEncoder::new_with_quality(&mut buf, quality.clamp(1, 100));
            encoder
                .write_image(
                    rgb.as_raw(),
                    rgb.width(),
                    rgb.height(),
                    image::ExtendedColorType::Rgb8,
                )
                .msg()?;
        }
        ImageFormat::Png => {
            let rgba = img.to_rgba8();
            let encoder = PngEncoder::new(&mut buf);
            encoder
                .write_image(
                    rgba.as_raw(),
                    rgba.width(),
                    rgba.height(),
                    image::ExtendedColorType::Rgba8,
                )
                .msg()?;
        }
        ImageFormat::WebP => return encode_webp(img, quality, lossless),
        ImageFormat::Bmp => {
            let rgb = img.to_rgb8();
            let encoder = BmpEncoder::new(&mut buf);
            encoder
                .write_image(
                    rgb.as_raw(),
                    rgb.width(),
                    rgb.height(),
                    image::ExtendedColorType::Rgb8,
                )
                .msg()?;
        }
        ImageFormat::Tiff => {
            let rgba = img.to_rgba8();
            let mut cursor = Cursor::new(&mut buf);
            let encoder = TiffEncoder::new(&mut cursor);
            encoder
                .write_image(
                    rgba.as_raw(),
                    rgba.width(),
                    rgba.height(),
                    image::ExtendedColorType::Rgba8,
                )
                .msg()?;
        }
        _ => {
            let mut cursor = Cursor::new(&mut buf);
            img.write_to(&mut cursor, format).msg()?;
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
        give(buf, out_ptr, out_len);
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_hash(handle: *mut c_void, algo: u32) -> u64 {
    let mut result: u64 = 0;
    guard(|| {
        let native = img(handle)?;
        let config = match algo {
            1 => HasherConfig::new().hash_alg(HashAlg::Gradient),
            2 => HasherConfig::new().hash_alg(HashAlg::Mean),
            // pHash: the mean of the low DCT frequencies.
            _ => HasherConfig::new().hash_alg(HashAlg::Mean).preproc_dct(),
        };
        let hasher = config.hash_size(8, 8).to_hasher();
        let h = hasher.hash_image(&native.inner);
        let bytes = h.as_bytes();
        if bytes.len() >= 8 {
            let mut arr = [0u8; 8];
            arr.copy_from_slice(&bytes[..8]);
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

        let mut sum_r = 0u64;
        let mut sum_g = 0u64;
        let mut sum_b = 0u64;
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

/// The longest side compression scores at: a larger picture is compared as a screen shows it,
/// which also bounds the metric's memory (about 700 MB at this size).
const SCORE_SIDE: u32 = 2560;

/// [img] as compression scores it: shrunk to fit [SCORE_SIDE] when larger.
fn viewed(img: &DynamicImage) -> Cow<'_, DynamicImage> {
    if img.width().max(img.height()) <= SCORE_SIDE {
        Cow::Borrowed(img)
    } else {
        Cow::Owned(img.resize(
            SCORE_SIDE,
            SCORE_SIDE,
            image::imageops::FilterType::Triangle,
        ))
    }
}

/// [img] in linear light, as SSIMULACRA2 compares.
fn linear(img: &DynamicImage) -> Result<ssimulacra2::LinearRgb, String> {
    let px: Vec<[f32; 3]> = img
        .to_rgb8()
        .pixels()
        .map(|p| {
            [
                p[0] as f32 / 255.0,
                p[1] as f32 / 255.0,
                p[2] as f32 / 255.0,
            ]
        })
        .collect();
    let rgb = ssimulacra2::Rgb::new(
        px,
        img.width() as usize,
        img.height() as usize,
        ssimulacra2::TransferCharacteristic::SRGB,
        ssimulacra2::ColorPrimaries::BT709,
    )
    .msg()?;
    ssimulacra2::LinearRgb::try_from(rgb).msg()
}

/// SSIMULACRA2 of [b] against [a]: 100 is identical, 90 very high, 70 medium.
fn similarity(a: &ssimulacra2::LinearRgb, b: &DynamicImage) -> Result<f64, String> {
    ssimulacra2::compute_frame_ssimulacra2(a.clone(), linear(b)?).msg()
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_similarity(a: *mut c_void, b: *mut c_void, out: *mut f64) -> i32 {
    guard(|| {
        let (a, b) = (img(a)?, img(b)?);
        let score = similarity(&linear(&a.inner)?, &b.inner)?;
        unsafe { *out = score };
        Ok(0)
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

/// The quality range compression searches: a binary search over it takes at most 6 encodes. A
/// target no quality reaches comes back as the highest, with its score.
const SEARCH_LOW: u8 = 40;
const SEARCH_HIGH: u8 = 100;

/// The smallest lossy encoding of [img] in [format] that still scores [target] against it,
/// within [max_bytes] when that is above 0; at a fixed [quality] above 0, that encoding.
/// Returns the bytes, the quality used, and the score (NaN when not measured); `None` when no
/// encoding fits [max_bytes].
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
    // A budget with no score asked: only the size counts, so nothing is scored, and the highest
    // quality goes first since it usually fits.
    let scoring = target <= 100.0;
    let mut scaled = Cow::Borrowed(img);
    for _ in 0..=5 {
        let found = if scoring {
            scored_search(&scaled, &encode, &fits, target)?
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
        scaled = Cow::Owned(scaled.resize(w, h, image::imageops::FilterType::Lanczos3));
    }
    Ok(None)
}

/// The lowest quality whose encoding of [img] scores [target] and [fits], else the highest that
/// fits: the bytes, the quality and the score; `None` when even the lowest is over.
fn scored_search(
    img: &DynamicImage,
    encode: &impl Fn(&DynamicImage, u8, bool) -> Result<Vec<u8>, String>,
    fits: &impl Fn(&Vec<u8>) -> bool,
    target: f64,
) -> Result<Option<(Vec<u8>, u8, f64)>, String> {
    let source = linear(&viewed(img))?;
    // Quality only raises both the score and the size: the lowest one that scores [target] is
    // also the smallest, and over budget the highest one that fits is the best left.
    let (mut lo, mut hi) = (SEARCH_LOW, SEARCH_HIGH);
    let (mut good, mut fitting): (Option<(Vec<u8>, u8, f64)>, Option<(Vec<u8>, u8, f64)>) = (None, None);
    while lo <= hi {
        let q = lo + (hi - lo) / 2;
        let out = encode(img, q, false)?;
        // Over budget is too high whatever it scores: not scored.
        if !fits(&out) {
            hi = q - 1;
            continue;
        }
        let score = similarity(&source, &viewed(&image::load_from_memory(&out).msg()?))?;
        if score >= target {
            good = Some((out, q, score));
            hi = q - 1;
        } else {
            fitting = Some((out, q, score));
            lo = q + 1;
        }
    }
    let met = good.is_some();
    let Some((out, q, score)) = good.or(fitting) else {
        return Ok(None);
    };
    // The thorough pass can move a few pixels: it is kept only if it still scores what the
    // search found and is no larger.
    let last = encode(img, q, true)?;
    if last.len() < out.len() {
        let again = similarity(&source, &viewed(&image::load_from_memory(&last).msg()?))?;
        if again >= if met { target } else { score } {
            return Ok(Some((last, q, again)));
        }
    }
    Ok(Some((out, q, score)))
}

/// The highest quality in the search range whose fast encoding [fits], with it: the top one
/// first, then a binary search below it; `None` when even the lowest is over.
fn largest_fitting(
    img: &DynamicImage,
    encode: &impl Fn(&DynamicImage, u8, bool) -> Result<Vec<u8>, String>,
    fits: &impl Fn(&Vec<u8>) -> bool,
) -> Result<Option<(Vec<u8>, u8)>, String> {
    let top = encode(img, SEARCH_HIGH, false)?;
    if fits(&top) {
        return Ok(Some((top, SEARCH_HIGH)));
    }
    let (mut lo, mut hi, mut best) = (SEARCH_LOW, SEARCH_HIGH - 1, None);
    while lo <= hi {
        let q = lo + (hi - lo) / 2;
        let out = encode(img, q, false)?;
        if fits(&out) {
            best = Some((out, q));
            lo = q + 1;
        } else {
            hi = q - 1;
        }
    }
    Ok(best)
}

#[no_mangle]
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
        // 2: a JPEG would drop transparency the image has; the buffer is empty.
        if format == ImageFormat::Jpeg && translucent(&native.inner) {
            give(Vec::new(), out_ptr, out_len);
            return Ok(2);
        }
        // 1: nothing fits [max_bytes]; the buffer is empty.
        let Some((buf, q, score)) =
            compress(&native.inner, format, quality, target, max_bytes as usize)?
        else {
            give(Vec::new(), out_ptr, out_len);
            return Ok(1);
        };
        unsafe {
            *out_quality = q as u32;
            *out_score = score;
        }
        give(buf, out_ptr, out_len);
        Ok(0)
    })
}

/// The PNG file [data] recompressed by oxipng: every pixel, bit depth, palette and frame kept.
/// With [strip] the chunks that do not change the picture (text, EXIF, timestamps) go too,
/// except the EXIF of a picture that is turned, since its orientation lives there; without it
/// every chunk stays.
#[no_mangle]
pub unsafe extern "C" fn tk_image_png(
    data: *const u8,
    len: usize,
    strip: bool,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let data = unsafe { bytes(data, len) };
        let mut opts = oxipng::Options::from_preset(PNG_PRESET);
        opts.strip = match (strip, read_exif_orientation_from_bytes(data)) {
            (false, _) => oxipng::StripChunks::None,
            // oxipng's `Safe` set, which it does not export, and the EXIF.
            (true, 2..=8) => oxipng::StripChunks::Keep(
                [*b"cICP", *b"iCCP", *b"sRGB", *b"pHYs", *b"acTL", *b"fcTL", *b"fdAT", *b"eXIf"]
                    .into_iter()
                    .collect(),
            ),
            (true, _) => oxipng::StripChunks::Safe,
        };
        let out = oxipng::optimize_from_memory(data, &opts).msg()?;
        give(out, out_ptr, out_len);
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// Enhance, analysis and layout
// ---------------------------------------------------------------------------

/// One seam p1 p0 | q0 q1 (byte offsets of four pixels): where the step across it is small
/// enough to be an encoder's and both sides are flat, the step is spread over the four pixels;
/// a real edge fails the test and is left alone.
#[inline]
fn deblock_seam(buf: &mut [u8], at: [usize; 4], alpha: f32, beta: f32, tc: f32) {
    let [p1, p0, q0, q1] = at;
    for c in 0..3 {
        let (a, b, x, d) = (buf[p1 + c] as f32, buf[p0 + c] as f32, buf[q0 + c] as f32, buf[q1 + c] as f32);
        if (b - x).abs() >= alpha || (a - b).abs() >= beta || (d - x).abs() >= beta {
            continue;
        }
        let delta = (((x - b) * 4.0 + (a - d)) / 8.0).clamp(-tc, tc);
        let px = |v: f32| v.round().clamp(0.0, 255.0) as u8;
        buf[p0 + c] = px(b + delta);
        buf[q0 + c] = px(x - delta);
        buf[p1 + c] = px(a + delta / 2.0);
        buf[q1 + c] = px(d - delta / 2.0);
    }
}

/// Smooths the 8×8 block seams of a decoded JPEG: vertical seams row by row, then horizontal
/// seams in 8-row bands centred on each seam, so every band is independent.
fn deblock_rgba(rgba: &mut RgbaImage, strength: f32) {
    let (w, h) = (rgba.width() as usize, rgba.height() as usize);
    if w < 10 || h < 10 || strength <= 0.0 {
        return;
    }
    let (alpha, beta, tc) = (24.0 * strength, 6.0 * strength, 6.0 * strength);
    let stride = w * 4;
    let buf: &mut [u8] = rgba.as_mut();
    buf.par_chunks_mut(stride).for_each(|row| {
        let mut x = 8;
        while x + 1 < w {
            deblock_seam(row, [(x - 2) * 4, (x - 1) * 4, x * 4, (x + 1) * 4], alpha, beta, tc);
            x += 8;
        }
    });
    // Band j holds rows 4 + 8j .. 12 + 8j; its seam (row 8 + 8j) is local row 4.
    buf[4 * stride..].par_chunks_mut(8 * stride).for_each(|band| {
        if band.len() < 6 * stride {
            return;
        }
        for x in 0..w {
            let at = |r: usize| r * stride + x * 4;
            deblock_seam(band, [at(2), at(3), at(4), at(5)], alpha, beta, tc);
        }
    });
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_deblock(handle: *mut c_void, strength: f32) -> *mut c_void {
    op(handle, |native| {
        let mut rgba = native.inner.to_rgba8();
        deblock_rgba(&mut rgba, strength);
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

/// The lowest and highest values of `hist` once `cut` pixels are dropped from each end.
fn levels_bounds(hist: &[u64; 256], cut: u64) -> (usize, usize) {
    let (mut lo, mut seen) = (0, 0u64);
    while lo < 255 && seen + hist[lo] <= cut {
        seen += hist[lo];
        lo += 1;
    }
    let (mut hi, mut seen) = (255, 0u64);
    while hi > 0 && seen + hist[hi] <= cut {
        seen += hist[hi];
        hi -= 1;
    }
    (lo, hi)
}

#[no_mangle]
pub unsafe extern "C" fn tk_image_auto_levels(handle: *mut c_void, clip: f32, white_balance: bool) -> *mut c_void {
    op(handle, |native| {
        let mut rgba = native.inner.to_rgba8();
        let hist = rgba
            .as_raw()
            .par_chunks(4 * 4096)
            .fold(
                || [[0u64; 256]; 3],
                |mut h, px| {
                    for p in px.chunks_exact(4) {
                        h[0][p[0] as usize] += 1;
                        h[1][p[1] as usize] += 1;
                        h[2][p[2] as usize] += 1;
                    }
                    h
                },
            )
            .reduce(
                || [[0u64; 256]; 3],
                |mut a, b| {
                    for c in 0..3 {
                        for v in 0..256 {
                            a[c][v] += b[c][v];
                        }
                    }
                    a
                },
            );
        let n = (rgba.width() as u64 * rgba.height() as u64).max(1);
        let cut = (n as f64 * clip.clamp(0.0, 0.2) as f64) as u64;
        let mut bounds = [levels_bounds(&hist[0], cut), levels_bounds(&hist[1], cut), levels_bounds(&hist[2], cut)];
        if !white_balance {
            // One stretch for all three keeps the colour cast; only the range opens up.
            let shared = (bounds.iter().map(|b| b.0).min().unwrap(), bounds.iter().map(|b| b.1).max().unwrap());
            bounds = [shared; 3];
        }
        let mut lut = [[0u8; 256]; 3];
        for c in 0..3 {
            let (lo, hi) = bounds[c];
            for v in 0..256 {
                // A near-flat channel (a gray card, a blank sky) is left as it is.
                lut[c][v] = if hi <= lo + 16 {
                    v as u8
                } else {
                    (((v as f32 - lo as f32) * 255.0 / (hi - lo) as f32).round().clamp(0.0, 255.0)) as u8
                };
            }
        }
        if white_balance {
            // Gray world, gently: each channel's mean moves toward the gray mean by at most 10 %,
            // so a red costume on a red backdrop is not turned cyan.
            let mean = |c: usize| (0..256).map(|v| hist[c][v] as f64 * lut[c][v] as f64).sum::<f64>() / n as f64;
            let means = [mean(0), mean(1), mean(2)];
            let gray = (means[0] + means[1] + means[2]) / 3.0;
            for c in 0..3 {
                let gain = if means[c] > 1.0 { (gray / means[c]).clamp(0.9, 1.1) } else { 1.0 };
                for v in 0..256 {
                    lut[c][v] = (lut[c][v] as f64 * gain).round().clamp(0.0, 255.0) as u8;
                }
            }
        }
        rgba.as_mut().par_chunks_mut(4 * 4096).for_each(|px| {
            for p in px.chunks_exact_mut(4) {
                p[0] = lut[0][p[0] as usize];
                p[1] = lut[1][p[1] as usize];
                p[2] = lut[2][p[2] as usize];
            }
        });
        Ok(NativeImage::new(DynamicImage::ImageRgba8(rgba)))
    })
}

/// Luma of `img` on a copy at most `side` px on its long side, as `f32` rows of `w`.
fn luma_small(img: &DynamicImage, side: u32) -> Result<(Vec<f32>, usize, usize), String> {
    let small = if img.width().max(img.height()) > side { resized(img, side, side, 3, 1)? } else { img.clone() };
    let rgb = small.to_rgb8();
    let (w, h) = (rgb.width() as usize, rgb.height() as usize);
    let y = rgb.pixels().map(|p| 0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32).collect();
    Ok((y, w, h))
}

/// The variance of the 4-neighbour Laplacian of the luma, on a copy at most 1024 px on its long
/// side so the score compares across sizes; -1 when it failed.
#[no_mangle]
pub unsafe extern "C" fn tk_image_sharpness(handle: *mut c_void) -> f64 {
    let mut score = -1.0;
    guard(|| {
        let (y, w, h) = luma_small(&img(handle)?.inner, 1024)?;
        if w < 3 || h < 3 {
            score = 0.0;
            return Ok(0);
        }
        let (sum, sq) = (1..h - 1)
            .into_par_iter()
            .map(|r| {
                let (mut s, mut q) = (0f64, 0f64);
                for c in 1..w - 1 {
                    let i = r * w + c;
                    let l = (y[i - 1] + y[i + 1] + y[i - w] + y[i + w] - 4.0 * y[i]) as f64;
                    s += l;
                    q += l * l;
                }
                (s, q)
            })
            .reduce(|| (0.0, 0.0), |a, b| (a.0 + b.0, a.1 + b.1));
        let n = ((w - 2) * (h - 2)) as f64;
        score = sq / n - (sum / n) * (sum / n);
        Ok(0)
    });
    score
}

/// The DCT perceptual hash `tk_image_hash` gives for algorithm 0.
fn phash_of(img: &DynamicImage) -> u64 {
    let hasher = HasherConfig::new().hash_alg(HashAlg::Mean).preproc_dct().hash_size(8, 8).to_hasher();
    let h = hasher.hash_image(img);
    let mut arr = [0u8; 8];
    arr.copy_from_slice(&h.as_bytes()[..8]);
    u64::from_be_bytes(arr)
}

/// The longest side [tk_image_phash_files] decodes at: the hash looks at 32 px, and a JPEG
/// decodes this small at an eighth of the work.
const PHASH_SIDE: u32 = 256;

/// The pHash of each of the `\0`-joined `paths`, decoded small and upright in parallel; `ok[i]`
/// is 0 for a file that could not be read or decoded. Returns the number of paths.
#[no_mangle]
pub unsafe extern "C" fn tk_image_phash_files(
    paths: *const u8,
    plen: usize,
    out: *mut u64,
    ok: *mut u8,
    cap: usize,
) -> i32 {
    guard(|| {
        let joined = text(paths, plen)?;
        let names: Vec<&str> = if joined.is_empty() { Vec::new() } else { joined.split('\0').collect() };
        if names.len() > cap {
            return Err(format!("output holds {} hashes, needs {}", cap, names.len()));
        }
        let hashes = std::slice::from_raw_parts_mut(out, names.len());
        let oks = std::slice::from_raw_parts_mut(ok, names.len());
        hashes.par_iter_mut().zip(oks.par_iter_mut()).zip(names.par_iter()).for_each(|((h, k), p)| {
            let decoded = std::fs::read(p).ok().and_then(|data| {
                let img = decode(&data, 0, PHASH_SIDE).ok()?;
                Some(upright(img, read_exif_orientation_from_bytes(&data)))
            });
            match decoded {
                Some(img) => {
                    *h = phash_of(&img);
                    *k = 1;
                }
                None => *k = 0,
            }
        });
        Ok(names.len() as i32)
    })
}

/// A contact sheet: `count` images, each fitted into a `cell`-px square and centred, in rows of
/// `columns`, `gap` px apart and around, on `background` (RGBA packed as `r << 24 | … | a`).
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
        let list = std::slice::from_raw_parts(handles, count);
        let images = list.iter().map(|&h| img(h)).collect::<Result<Vec<_>, _>>()?;
        let thumbs = images
            .par_iter()
            .map(|n| resized(&n.inner, cell, cell, 1, 0).map(|t| t.to_rgba8()))
            .collect::<Result<Vec<_>, _>>()?;
        let cols = columns.min(count as u32);
        let rows = (count as u32).div_ceil(cols);
        let width = cols * cell + (cols + 1) * gap;
        let height = rows * cell + (rows + 1) * gap;
        let bg = background.to_be_bytes();
        let mut canvas = RgbaImage::from_pixel(width, height, Rgba(bg));
        for (i, t) in thumbs.iter().enumerate() {
            let (c, r) = (i as u32 % cols, i as u32 / cols);
            let x = gap + c * (cell + gap) + (cell - t.width()) / 2;
            let y = gap + r * (cell + gap) + (cell - t.height()) / 2;
            image::imageops::overlay(&mut canvas, t, x as i64, y as i64);
        }
        Ok(NativeImage::new(DynamicImage::ImageRgba8(canvas)))
    })
}

/// The crop of [aspect] that keeps the most detail and skin: Sobel energy plus a skin-tone
/// bonus, summed along the axis the crop slides on, with a mild pull to the centre; computed on
/// a copy at most 256 px on its long side.
#[no_mangle]
pub unsafe extern "C" fn tk_image_crop_smart(handle: *mut c_void, aspect: f64) -> *mut c_void {
    op(handle, |native| {
        if aspect <= 0.0 {
            return Err("Aspect ratio must be positive".to_string());
        }
        let (w, h) = (native.inner.width(), native.inner.height());
        let (cw, ch) = if w as f64 / h as f64 > aspect {
            (((h as f64 * aspect).round() as u32).clamp(1, w), h)
        } else {
            (w, ((w as f64 / aspect).round() as u32).clamp(1, h))
        };
        if cw == w && ch == h {
            return Ok(NativeImage::new(native.inner.clone()));
        }
        let small = if w.max(h) > 256 { resized(&native.inner, 256, 256, 3, 1)? } else { native.inner.clone() };
        let rgb = small.to_rgb8();
        let (sw, sh) = (rgb.width() as usize, rgb.height() as usize);
        let px: Vec<[f32; 3]> = rgb.pixels().map(|p| [p[0] as f32, p[1] as f32, p[2] as f32]).collect();
        let luma: Vec<f32> = px.iter().map(|p| 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]).collect();
        let mut edge = vec![0f32; sw * sh];
        for y in 1..sh.saturating_sub(1) {
            for x in 1..sw.saturating_sub(1) {
                let l = |dx: isize, dy: isize| luma[(y as isize + dy) as usize * sw + (x as isize + dx) as usize];
                let gx = l(1, -1) + 2.0 * l(1, 0) + l(1, 1) - l(-1, -1) - 2.0 * l(-1, 0) - l(-1, 1);
                let gy = l(-1, 1) + 2.0 * l(0, 1) + l(1, 1) - l(-1, -1) - 2.0 * l(0, -1) - l(1, -1);
                edge[y * sw + x] = gx.abs() + gy.abs();
            }
        }
        let max_edge = edge.iter().cloned().fold(1.0f32, f32::max);
        let energy: Vec<f32> = px
            .iter()
            .zip(&edge)
            .map(|(p, e)| {
                let cb = 128.0 - 0.168736 * p[0] - 0.331264 * p[1] + 0.5 * p[2];
                let cr = 128.0 + 0.5 * p[0] - 0.418688 * p[1] - 0.081312 * p[2];
                let skin = (77.0..=127.0).contains(&cb) && (133.0..=173.0).contains(&cr);
                e / max_edge + if skin { 0.5 } else { 0.0 }
            })
            .collect();
        let horizontal = cw < w;
        let (len, span) = if horizontal { (sw, sh) } else { (sh, sw) };
        let line: Vec<f32> = (0..len)
            .map(|i| (0..span).map(|j| if horizontal { energy[j * sw + i] } else { energy[i * sw + j] }).sum())
            .collect();
        let win = ((if horizontal { cw as f64 / w as f64 } else { ch as f64 / h as f64 }) * len as f64).round() as usize;
        let win = win.clamp(1, len);
        let mut sum: f32 = line[..win].iter().sum();
        let (mut best, mut best_at) = (f32::MIN, 0usize);
        for at in 0..=len - win {
            if at > 0 {
                sum += line[at + win - 1] - line[at - 1];
            }
            let d = ((at as f32 + win as f32 / 2.0) - len as f32 / 2.0) / (len as f32 / 2.0);
            let score = sum * (1.0 - 0.3 * d * d);
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
        Ok(NativeImage::new(native.inner.crop_imm(x, y, cw, ch)))
    })
}
