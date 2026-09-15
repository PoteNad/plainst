#ifndef PLAINST_ENGINE_H
#define PLAINST_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// A buffer allocated by the engine. Release it with plainst_buffer_free.
typedef struct PlainstBuffer {
  uint8_t *data;
  size_t len;
} PlainstBuffer;

void plainst_buffer_free(PlainstBuffer buffer);

/// The document outline as little-endian int32 records with UTF-16 offsets
/// (see outline_binary in engine/src/outline.rs).
PlainstBuffer plainst_outline(const uint8_t *text, size_t len);

/// "PLC1", a little-endian u32 JSON length, diagnostics JSON, then PDF bytes if requested.
/// A document without errors is kept under `key` (one per window) for completions and
/// the preview.
PlainstBuffer plainst_compile(const uint8_t *text, size_t len, bool want_pdf, uint64_t key);

/// "PLI1", u32 pixel width and height, f32 point width, height and baseline, then
/// premultiplied RGBA pixels; or "PLE1" followed by an error message.
PlainstBuffer plainst_render_math(const uint8_t *equation, size_t len, bool block,
                                  double pixels_per_pt, uint32_t rgba);

/// Typst completions at a UTF-16 cursor offset, as UTF-8 JSON:
/// {"from": utf16, "items": [{"kind", "label", "apply", "detail", "symbol"}]}.
PlainstBuffer plainst_complete(const uint8_t *text, size_t len, size_t cursor_utf16, bool explicit_,
                               uint64_t key);

/// "PLP1", u32 page count, then f32 width and height in points and a u128 content hash as
/// two u64 values for each page of the last good document under `key`.
PlainstBuffer plainst_preview_pages(uint64_t key);

/// "PLI1", u32 pixel width and height, then premultiplied RGBA pixels; "PLE1" when the page
/// no longer has the given hash.
PlainstBuffer plainst_render_page(uint64_t key, size_t index, double pixels_per_pt,
                                  uint64_t hash_low, uint64_t hash_high);

/// The UTF-16 source offset under a point on a page (in points from its top left), or -1.
int64_t plainst_jump_from_click(uint64_t key, size_t page, double x_pt, double y_pt);

/// "PLJ1", u32 count, then u32 page index and f32 x and y in points for each place the text
/// at the cursor appears. Empty unless `text` is the source of the kept document.
PlainstBuffer plainst_preview_positions(uint64_t key, const uint8_t *text, size_t len,
                                        size_t cursor_utf16);

void plainst_forget(uint64_t key);

/// Every Typst symbol name and its character, as UTF-8 JSON [[name, symbol], ...].
PlainstBuffer plainst_symbols(void);

void plainst_warm_up(void);

size_t plainst_bundled_font_count(void);

/// Borrows static font data that lives for the whole process.
const uint8_t *plainst_bundled_font(size_t index, size_t *len);

#endif
