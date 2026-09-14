//! Editor assistance from Typst's own IDE crate: completions and the symbol catalogue.

use typst::syntax::Source;
use typst_ide::{Completion, CompletionKind, IdeWorld};
use typst_layout::PagedDocument;

use crate::world::{MAIN_ID, PlainstWorld};
use crate::{Utf16Map, json_string};

impl IdeWorld for PlainstWorld {
    fn upcast(&self) -> &dyn typst::World {
        self
    }
}

fn kind_name(kind: &CompletionKind) -> &'static str {
    match kind {
        CompletionKind::Syntax => "syntax",
        CompletionKind::Func => "function",
        CompletionKind::Type => "type",
        CompletionKind::Param => "parameter",
        CompletionKind::Constant => "constant",
        CompletionKind::Path => "path",
        CompletionKind::Package => "package",
        CompletionKind::Label => "label",
        CompletionKind::Font => "font",
        CompletionKind::Symbol(_) => "symbol",
    }
}

/// Completions at a UTF-16 cursor position, as JSON:
/// `{"from": <utf16>, "items": [{"kind", "label", "apply", "detail", "symbol"}]}`.
/// Returns an empty item list when Typst has nothing to offer.
pub fn complete_json(text: &str, cursor_utf16: usize, explicit: bool) -> String {
    let source = Source::new(*MAIN_ID, text.to_owned());
    let Some(cursor) = source.lines().utf16_to_byte(cursor_utf16) else {
        return "{\"from\":0,\"items\":[]}".into();
    };
    let world = PlainstWorld::new(source.clone());
    let result = typst_ide::autocomplete(&world, None::<&PagedDocument>, &source, cursor, explicit);
    let Some((from, completions)) = result else {
        return "{\"from\":0,\"items\":[]}".into();
    };
    let map = Utf16Map::new(text);
    let mut out = format!("{{\"from\":{},\"items\":[", map.get(from));
    for (index, Completion { kind, label, apply, detail }) in completions.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str("{\"kind\":");
        json_string(&mut out, kind_name(kind));
        out.push_str(",\"label\":");
        json_string(&mut out, label);
        out.push_str(",\"apply\":");
        json_string(&mut out, apply.as_deref().unwrap_or(label));
        out.push_str(",\"detail\":");
        json_string(&mut out, detail.as_deref().unwrap_or(""));
        out.push_str(",\"symbol\":");
        json_string(&mut out, if let CompletionKind::Symbol(s) = kind { s } else { "" });
        out.push('}');
    }
    out.push_str("]}");
    out
}

/// Every symbol Typst knows, with its full name and character, as JSON `[[name, symbol], …]`.
/// Deprecated names are left out.
pub fn symbols_json() -> String {
    let mut out = String::from("[");
    let mut first = true;
    for (name, binding) in codex::SYM.iter() {
        if binding.deprecation.is_some() {
            continue;
        }
        let codex::Def::Symbol(symbol) = binding.def else { continue };
        for (modifiers, value, deprecation) in symbol.variants() {
            if deprecation.is_some() {
                continue;
            }
            let full = if modifiers.is_empty() {
                name.to_string()
            } else {
                format!("{name}.{}", modifiers.as_str())
            };
            if !first {
                out.push(',');
            }
            first = false;
            out.push('[');
            json_string(&mut out, &full);
            out.push(',');
            json_string(&mut out, value);
            out.push(']');
        }
    }
    out.push(']');
    out
}
