//! The document's own text style, from its top-level `#set text(...)` and `#set par(...)`
//! rules, so the Writing view can follow them and the Format menu can rewrite them.

use typst_syntax::ast::{self, ArrayItem, Expr, Unit};
use typst_syntax::{LinkedNode, SyntaxKind};

use crate::{Utf16Map, json_string};

/// Typst's default text size, in points.
const DEFAULT_SIZE: f64 = 11.0;

/// A set rule found at the top level of the document.
struct Rule {
    start: usize,
    end: usize,
    /// Each argument's name, if it has one, and its byte range.
    args: Vec<(Option<String>, usize, usize)>,
}

/// The style set by top-level, unconditional set rules, as JSON:
/// `{"font", "size", "justify", "text": rule, "par": rule}`. Values are null when no rule
/// sets them; later rules override earlier ones. Each rule is the last of its kind, as
/// `{"s", "e", "args": [{"n", "s", "e"}]}` with UTF-16 offsets.
pub fn style_json(text: &str) -> String {
    let root = typst_syntax::parse(text);
    let map = Utf16Map::new(text);
    let linked = LinkedNode::new(&root);
    let children: Vec<LinkedNode> = linked.children().collect();

    let mut font: Option<String> = None;
    let mut size: Option<f64> = None;
    let mut justify: Option<bool> = None;
    let mut text_rule: Option<Rule> = None;
    let mut par_rule: Option<Rule> = None;

    for (index, hash) in children.iter().enumerate() {
        if hash.kind() != SyntaxKind::Hash {
            continue;
        }
        let Some(node) = children.get(index + 1) else {
            continue;
        };
        let Some(rule) = node.cast::<ast::SetRule>() else {
            continue;
        };
        if rule.condition().is_some() {
            continue;
        }
        let Expr::Ident(target) = rule.target() else {
            continue;
        };
        let target = target.as_str();
        if target != "text" && target != "par" {
            continue;
        }

        let mut args = Vec::new();
        if let Some(list) = node.children().find(|child| child.kind() == SyntaxKind::Args) {
            for arg in list.children() {
                match arg.kind() {
                    SyntaxKind::LeftParen
                    | SyntaxKind::RightParen
                    | SyntaxKind::Comma
                    | SyntaxKind::Space
                    | SyntaxKind::LineComment
                    | SyntaxKind::BlockComment => {}
                    SyntaxKind::Named => {
                        let named = arg.cast::<ast::Named>().expect("a named argument");
                        let name = named.name().as_str().to_string();
                        let value = named.expr();
                        match (target, name.as_str()) {
                            ("text", "font") => font = font_name(value).or(font),
                            ("text", "size") => size = points(value).or(size),
                            ("par", "justify") => {
                                if let Expr::Bool(flag) = value {
                                    justify = Some(flag.get());
                                }
                            }
                            _ => {}
                        }
                        args.push((Some(name), arg.offset(), arg.range().end));
                    }
                    _ => args.push((None, arg.offset(), arg.range().end)),
                }
            }
        }
        let found = Rule { start: hash.offset(), end: node.range().end, args };
        if target == "text" {
            text_rule = Some(found);
        } else {
            par_rule = Some(found);
        }
    }

    let mut out = String::from("{\"font\":");
    match &font {
        Some(name) => json_string(&mut out, name),
        None => out.push_str("null"),
    }
    out.push_str(",\"size\":");
    out.push_str(&size.map_or("null".to_string(), |s| format!("{s}")));
    out.push_str(",\"justify\":");
    out.push_str(justify.map_or("null", |j| if j { "true" } else { "false" }));
    for (key, rule) in [("text", &text_rule), ("par", &par_rule)] {
        out.push_str(&format!(",\"{key}\":"));
        let Some(rule) = rule else {
            out.push_str("null");
            continue;
        };
        out.push_str(&format!(
            "{{\"s\":{},\"e\":{},\"args\":[",
            map.get(rule.start),
            map.get(rule.end)
        ));
        for (i, (name, start, end)) in rule.args.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str("{\"n\":");
            match name {
                Some(name) => json_string(&mut out, name),
                None => out.push_str("null"),
            }
            out.push_str(&format!(",\"s\":{},\"e\":{}}}", map.get(*start), map.get(*end)));
        }
        out.push_str("]}");
    }
    out.push('}');
    out
}

/// The first family named by a `font` argument: a string or an array of strings.
fn font_name(value: Expr) -> Option<String> {
    match value {
        Expr::Str(name) => Some(name.get().to_string()),
        Expr::Array(list) => list.items().find_map(|item| match item {
            ArrayItem::Pos(Expr::Str(name)) => Some(name.get().to_string()),
            _ => None,
        }),
        _ => None,
    }
}

/// A `size` argument in points, for absolute lengths and `em`.
fn points(value: Expr) -> Option<f64> {
    let Expr::Numeric(number) = value else {
        return None;
    };
    let (amount, unit) = number.get();
    let points = match unit {
        Unit::Pt => amount,
        Unit::Mm => amount * 72.0 / 25.4,
        Unit::Cm => amount * 72.0 / 2.54,
        Unit::In => amount * 72.0,
        Unit::Em => amount * DEFAULT_SIZE,
        _ => return None,
    };
    (points.is_finite() && points > 0.0).then_some(points)
}

/// Every font family Typst can use, sorted, as a JSON array of strings.
pub fn font_families_json() -> String {
    let mut families: Vec<&str> =
        crate::world::fonts().book().families().map(|(name, _)| name).collect();
    families.sort_by_key(|name| name.to_lowercase());
    families.dedup();
    let mut out = String::from("[");
    for (i, name) in families.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        json_string(&mut out, name);
    }
    out.push(']');
    out
}
