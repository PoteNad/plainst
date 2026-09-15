//! The live preview: the last good document of each editor window, its page images, and
//! jumps between pages and source.

use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};

use typst::introspection::PagedPosition;
use typst::layout::{Abs, Point};
use typst::syntax::Source;
use typst::utils::Scalar;
use typst_ide::Jump;
use typst_layout::PagedDocument;

use crate::Utf16Map;
use crate::world::PlainstWorld;

/// A document that compiled without errors, with the source it came from.
pub struct Compiled {
    pub document: PagedDocument,
    pub source: Source,
}

/// Documents by the key of the window that compiled them, most recent last.
static DOCUMENTS: Mutex<Vec<(u64, Arc<Compiled>)>> = Mutex::new(Vec::new());
/// Windows closed without forgetting their documents stop being kept after this many.
const KEPT: usize = 16;

pub(crate) fn store(key: u64, compiled: Compiled) {
    let mut documents = DOCUMENTS.lock().unwrap_or_else(|e| e.into_inner());
    documents.retain(|(k, _)| *k != key);
    documents.push((key, Arc::new(compiled)));
    if documents.len() > KEPT {
        documents.remove(0);
    }
}

pub(crate) fn get(key: u64) -> Option<Arc<Compiled>> {
    let documents = DOCUMENTS.lock().unwrap_or_else(|e| e.into_inner());
    documents
        .iter()
        .find(|(k, _)| *k == key)
        .map(|(_, c)| c.clone())
}

/// Drops the document kept for a window that closed.
pub fn forget(key: u64) {
    let mut documents = DOCUMENTS.lock().unwrap_or_else(|e| e.into_inner());
    documents.retain(|(k, _)| *k != key);
}

fn page_hash(document: &PagedDocument, index: usize) -> u128 {
    typst::utils::hash128(&document.pages()[index])
}

/// The pages of a window's document: `PLP1`, u32 count, then for each page its f32 width
/// and height in points and a u128 content hash as two little-endian u64 values.
pub fn pages_binary(key: u64) -> Vec<u8> {
    let mut out = b"PLP1".to_vec();
    let Some(compiled) = get(key) else {
        out.extend_from_slice(&0u32.to_le_bytes());
        return out;
    };
    let pages = compiled.document.pages();
    out.extend_from_slice(&(pages.len() as u32).to_le_bytes());
    for (index, page) in pages.iter().enumerate() {
        let size = page.frame.size();
        out.extend_from_slice(&(size.x.to_pt() as f32).to_le_bytes());
        out.extend_from_slice(&(size.y.to_pt() as f32).to_le_bytes());
        out.extend_from_slice(&page_hash(&compiled.document, index).to_le_bytes());
    }
    out
}

/// Renders one page if its content still has `hash`: `PLI1`, u32 pixel width and height,
/// then premultiplied RGBA pixels. A stale or missing page is `PLE1`.
pub fn render_page_binary(key: u64, index: usize, pixels_per_pt: f64, hash: u128) -> Vec<u8> {
    let stale = || b"PLE1stale".to_vec();
    let Some(compiled) = get(key) else { return stale() };
    let Some(page) = compiled.document.pages().get(index) else {
        return stale();
    };
    if page_hash(&compiled.document, index) != hash {
        return stale();
    }
    let options = typst_render::RenderOptions {
        pixel_per_pt: Scalar::new(pixels_per_pt.clamp(0.1, 16.0)),
        render_bleed: false,
    };
    let pixmap = typst_render::render(page, &options);
    let mut out = b"PLI1".to_vec();
    out.extend_from_slice(&pixmap.width().to_le_bytes());
    out.extend_from_slice(&pixmap.height().to_le_bytes());
    out.extend_from_slice(&pixmap.take());
    out
}

/// The UTF-16 offset in the compiled source for a click on a page, or -1.
pub fn jump_from_click(key: u64, page: usize, x_pt: f64, y_pt: f64) -> i64 {
    let Some(compiled) = get(key) else { return -1 };
    let Some(number) = NonZeroUsize::new(page + 1) else {
        return -1;
    };
    let world = PlainstWorld::new(compiled.source.clone());
    let position = PagedPosition {
        page: number,
        point: Point::new(Abs::pt(x_pt), Abs::pt(y_pt)),
    };
    match typst_ide::jump_from_click(&world, &compiled.document, &position) {
        Some(Jump::File(id, offset)) if id == compiled.source.id() => {
            Utf16Map::new(compiled.source.text()).get(offset) as i64
        }
        Some(Jump::Position(position)) => {
            // A link inside the document: jump to what it points at instead.
            let target = typst_ide::jump_from_click(&world, &compiled.document, &position);
            match target {
                Some(Jump::File(id, offset)) if id == compiled.source.id() => {
                    Utf16Map::new(compiled.source.text()).get(offset) as i64
                }
                _ => -1,
            }
        }
        _ => -1,
    }
}

/// Where the text at a UTF-16 cursor appears on the pages: `PLJ1`, u32 count, then u32
/// page index and f32 x and y in points for each place. Empty unless `text` is exactly
/// the compiled source, since positions in edited text don't match the pages.
pub fn positions_binary(key: u64, text: &str, cursor_utf16: usize) -> Vec<u8> {
    let mut out = b"PLJ1".to_vec();
    let positions = get(key)
        .filter(|compiled| compiled.source.text() == text)
        .and_then(|compiled| {
            let cursor = compiled.source.lines().utf16_to_byte(cursor_utf16)?;
            Some(typst_ide::jump_from_cursor(
                &compiled.document,
                &compiled.source,
                cursor,
            ))
        })
        .unwrap_or_default();
    out.extend_from_slice(&(positions.len() as u32).to_le_bytes());
    for position in positions {
        out.extend_from_slice(&((position.page.get() - 1) as u32).to_le_bytes());
        out.extend_from_slice(&(position.point.x.to_pt() as f32).to_le_bytes());
        out.extend_from_slice(&(position.point.y.to_pt() as f32).to_le_bytes());
    }
    out
}
