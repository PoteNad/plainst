//! Plainst's bridge to the Typst compiler.
//!
//! The Swift app owns the text; this crate only reads it. Every entry point takes
//! the complete UTF-8 source and returns a freshly allocated buffer that Swift
//! releases with `plainst_buffer_free`. All offsets handed back are UTF-16 code
//! units so they line up with `NSString` ranges.

mod ffi;
mod highlight;
mod ide;
mod outline;
mod preview;
mod style;
mod world;

pub use ide::{complete_json, symbols_json};
pub use outline::{outline_binary, outline_json};
pub use preview::{forget, jump_from_click, pages_binary, positions_binary, render_page_binary};
pub use style::{font_families_json, style_json};
pub use world::{CompileOutput, MathImage, compile, render_math};

/// Escapes a string for inclusion in hand-written JSON.
pub(crate) fn json_string(out: &mut String, value: &str) {
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Maps byte offsets in a source string to UTF-16 offsets.
pub(crate) struct Utf16Map {
    /// UTF-16 offset for every byte offset that starts a character, plus the end.
    table: Vec<u32>,
}

impl Utf16Map {
    pub(crate) fn new(text: &str) -> Self {
        let mut table = vec![0u32; text.len() + 1];
        let mut utf16 = 0u32;
        let mut last = 0usize;
        for (index, ch) in text.char_indices() {
            for slot in &mut table[last..=index] {
                *slot = utf16;
            }
            utf16 += ch.len_utf16() as u32;
            last = index + 1;
        }
        for slot in &mut table[last..] {
            *slot = utf16;
        }
        Self { table }
    }

    pub(crate) fn get(&self, byte: usize) -> u32 {
        self.table[byte.min(self.table.len() - 1)]
    }
}

#[cfg(test)]
mod tests;
