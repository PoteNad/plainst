//! The C interface used by the Swift app. See `Sources/CPlainstEngine/plainst_engine.h`.

use std::slice;

use crate::world;

/// A heap buffer owned by the caller once returned.
#[repr(C)]
pub struct PlainstBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl PlainstBuffer {
    fn from_vec(bytes: Vec<u8>) -> Self {
        let mut boxed = bytes.into_boxed_slice();
        let buffer = PlainstBuffer {
            data: boxed.as_mut_ptr(),
            len: boxed.len(),
        };
        std::mem::forget(boxed);
        buffer
    }
}

/// Reads the UTF-8 text passed from Swift. Invalid UTF-8 is replaced rather than trusted.
unsafe fn text<'a>(data: *const u8, len: usize) -> std::borrow::Cow<'a, str> {
    if data.is_null() || len == 0 {
        return std::borrow::Cow::Borrowed("");
    }
    let bytes = unsafe { slice::from_raw_parts(data, len) };
    String::from_utf8_lossy(bytes)
}

fn guarded(f: impl FnOnce() -> Vec<u8>) -> PlainstBuffer {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| {
        let mut out = b"PLE1".to_vec();
        out.extend_from_slice(b"The Typst engine stopped unexpectedly");
        out
    });
    PlainstBuffer::from_vec(result)
}

/// Frees a buffer returned by any other function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plainst_buffer_free(buffer: PlainstBuffer) {
    if !buffer.data.is_null() {
        drop(unsafe { Box::from_raw(slice::from_raw_parts_mut(buffer.data, buffer.len)) });
    }
}

/// Returns the document outline in the binary layout described by `outline_binary`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plainst_outline(data: *const u8, len: usize) -> PlainstBuffer {
    let source = unsafe { text(data, len) };
    guarded(|| crate::outline_binary(&source))
}

/// Compiles the document: `PLC1`, a little-endian u32 JSON length, the JSON, then PDF bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plainst_compile(
    data: *const u8,
    len: usize,
    want_pdf: bool,
) -> PlainstBuffer {
    let source = unsafe { text(data, len) };
    guarded(|| {
        let output = world::compile(&source, want_pdf);
        let mut out = b"PLC1".to_vec();
        out.extend_from_slice(&(output.json.len() as u32).to_le_bytes());
        out.extend_from_slice(output.json.as_bytes());
        if let Some(pdf) = output.pdf {
            out.extend_from_slice(&pdf);
        }
        out
    })
}

/// Renders an equation: `PLI1`, u32 width and height in pixels, f32 width, height and
/// baseline in points, then premultiplied RGBA pixels. Errors are `PLE1` and a message.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plainst_render_math(
    data: *const u8,
    len: usize,
    block: bool,
    pixels_per_pt: f64,
    rgba: u32,
) -> PlainstBuffer {
    let source = unsafe { text(data, len) };
    guarded(|| {
        let scale = if pixels_per_pt.is_finite() {
            pixels_per_pt.clamp(0.1, 32.0)
        } else {
            2.0
        };
        match world::render_math(&source, block, scale, rgba.to_be_bytes()) {
            Ok(image) => {
                let mut out = b"PLI1".to_vec();
                out.extend_from_slice(&image.width_px.to_le_bytes());
                out.extend_from_slice(&image.height_px.to_le_bytes());
                out.extend_from_slice(&image.width_pt.to_le_bytes());
                out.extend_from_slice(&image.height_pt.to_le_bytes());
                out.extend_from_slice(&image.baseline_pt.to_le_bytes());
                out.extend_from_slice(&image.pixels);
                out
            }
            Err(message) => {
                let mut out = b"PLE1".to_vec();
                out.extend_from_slice(message.as_bytes());
                out
            }
        }
    })
}

/// Loads fonts and the standard library ahead of the first render.
#[unsafe(no_mangle)]
pub extern "C" fn plainst_warm_up() {
    let _ = std::panic::catch_unwind(world::warm_up);
}

/// The number of font files bundled with Typst.
#[unsafe(no_mangle)]
pub extern "C" fn plainst_bundled_font_count() -> usize {
    typst_assets::fonts().count()
}

/// Borrows a bundled font file. The data lives for the whole process and must not be freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plainst_bundled_font(index: usize, len: *mut usize) -> *const u8 {
    match typst_assets::fonts().nth(index) {
        Some(font) => {
            if !len.is_null() {
                unsafe { *len = font.len() };
            }
            font.as_ptr()
        }
        None => std::ptr::null(),
    }
}
