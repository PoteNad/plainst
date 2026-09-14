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
PlainstBuffer plainst_compile(const uint8_t *text, size_t len, bool want_pdf);

/// "PLI1", u32 pixel width and height, f32 point width, height and baseline, then
/// premultiplied RGBA pixels; or "PLE1" followed by an error message.
PlainstBuffer plainst_render_math(const uint8_t *equation, size_t len, bool block,
                                  double pixels_per_pt, uint32_t rgba);

void plainst_warm_up(void);

size_t plainst_bundled_font_count(void);

/// Borrows static font data that lives for the whole process.
const uint8_t *plainst_bundled_font(size_t index, size_t *len);

#endif
