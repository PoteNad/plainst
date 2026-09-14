//! Turns Typst source into a flat list of elements the editor can style.
//!
//! The outline never changes the text. It only reports where each supported
//! construct lives and which of its characters are markup, so the Writing view
//! can hide delimiters and the Source view can colour them.

use typst_syntax::{SyntaxKind, SyntaxNode, ast};

use crate::{Utf16Map, json_string};

/// One styled construct, in UTF-16 offsets.
struct Element {
    kind: &'static str,
    start: u32,
    end: u32,
    /// Ranges that are pure markup and may be hidden while writing.
    markers: Vec<(u32, u32)>,
    /// Heading level or list number.
    number: Option<i64>,
    /// Whether a raw block or equation is displayed on its own.
    block: bool,
    /// A replacement string for shorthands such as `--`.
    text: Option<&'static str>,
    /// A secondary range, such as the term in a term list item.
    content: Option<(u32, u32)>,
}

impl Element {
    fn new(kind: &'static str, start: u32, end: u32) -> Self {
        Self {
            kind,
            start,
            end,
            markers: Vec::new(),
            number: None,
            block: false,
            text: None,
            content: None,
        }
    }
}

struct Walker<'a> {
    map: &'a Utf16Map,
    elements: Vec<Element>,
}

fn elements(text: &str) -> Vec<Element> {
    let root = typst_syntax::parse(text);
    let map = Utf16Map::new(text);
    let mut walker = Walker {
        map: &map,
        elements: Vec::new(),
    };
    walker.markup(&root, 0);
    walker.elements
}

const KINDS: [&str; 14] = [
    "heading",
    "strong",
    "emph",
    "raw",
    "link",
    "code",
    "comment",
    "linebreak",
    "escape",
    "shorthand",
    "math",
    "list",
    "enum",
    "term",
];
const SHORTHANDS: [&str; 4] = ["\u{2013}", "\u{2014}", "\u{2026}", "\u{00a0}"];

/// Parses `text` and returns its outline as little-endian `i32` values:
/// `kind, start, end, number, flags, content start, content end, shorthand, marker count`,
/// then each marker's start and end. Missing numbers are `i32::MIN`, a missing content
/// range is `-1, -1`, and a missing shorthand is `-1`. Flag bit 0 marks block elements.
pub fn outline_binary(text: &str) -> Vec<u8> {
    let elements = elements(text);
    let mut out = Vec::with_capacity(elements.len() * 40);
    let mut push = |value: i32| out.extend_from_slice(&value.to_le_bytes());
    for element in &elements {
        push(KINDS.iter().position(|k| *k == element.kind).unwrap_or(5) as i32);
        push(element.start as i32);
        push(element.end as i32);
        push(
            element
                .number
                .map(|n| n.clamp(i32::MIN as i64 + 1, i32::MAX as i64) as i32)
                .unwrap_or(i32::MIN),
        );
        push(element.block as i32);
        let (cs, ce) = element
            .content
            .map(|(s, e)| (s as i32, e as i32))
            .unwrap_or((-1, -1));
        push(cs);
        push(ce);
        push(
            element
                .text
                .and_then(|t| SHORTHANDS.iter().position(|s| *s == t))
                .map_or(-1, |i| i as i32),
        );
        push(element.markers.len() as i32);
        for (s, e) in &element.markers {
            push(*s as i32);
            push(*e as i32);
        }
    }
    out
}

/// Parses `text` and returns its outline as JSON, which is easier to read in tests.
pub fn outline_json(text: &str) -> String {
    let walker = Walker {
        map: &Utf16Map::new(""),
        elements: elements(text),
    };

    let mut out = String::with_capacity(walker.elements.len() * 48 + 2);
    out.push('[');
    for (index, element) in walker.elements.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str("{\"k\":");
        json_string(&mut out, element.kind);
        out.push_str(&format!(",\"s\":{},\"e\":{}", element.start, element.end));
        if !element.markers.is_empty() {
            out.push_str(",\"m\":[");
            for (i, (s, e)) in element.markers.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&format!("[{s},{e}]"));
            }
            out.push(']');
        }
        if let Some(number) = element.number {
            out.push_str(&format!(",\"n\":{number}"));
        }
        if element.block {
            out.push_str(",\"b\":true");
        }
        if let Some(text) = element.text {
            out.push_str(",\"t\":");
            json_string(&mut out, text);
        }
        if let Some((s, e)) = element.content {
            out.push_str(&format!(",\"c\":[{s},{e}]"));
        }
        out.push('}');
    }
    out.push(']');
    out
}

impl Walker<'_> {
    fn u(&self, byte: usize) -> u32 {
        self.map.get(byte)
    }

    /// Walks a markup node, keeping track of automatic enum numbering.
    fn markup(&mut self, node: &SyntaxNode, offset: usize) {
        let children: Vec<&SyntaxNode> = node.children().collect();
        let mut enum_counter: i64 = 0;
        let mut cursor = offset;
        let mut index = 0;
        while index < children.len() {
            let child = children[index];
            let start = cursor;
            cursor += child.len();
            match child.kind() {
                SyntaxKind::EnumItem => {}
                SyntaxKind::Space
                | SyntaxKind::Parbreak
                | SyntaxKind::LineComment
                | SyntaxKind::BlockComment => {}
                _ => enum_counter = 0,
            }
            if child.kind() == SyntaxKind::Hash {
                // Embedded code: the hash and the expression after it.
                let mut end = cursor;
                if let Some(next) = children.get(index + 1) {
                    end += next.len();
                    cursor = end;
                    index += 1;
                }
                self.elements
                    .push(Element::new("code", self.u(start), self.u(end)));
                index += 1;
                continue;
            }
            if child.kind() == SyntaxKind::EnumItem {
                enum_counter = self.enum_item(child, start, enum_counter);
            } else {
                self.node(child, start);
            }
            index += 1;
        }
    }

    fn node(&mut self, node: &SyntaxNode, offset: usize) {
        let end = offset + node.len();
        match node.kind() {
            SyntaxKind::Heading => self.heading(node, offset),
            SyntaxKind::Strong => self.delimited(node, offset, "strong"),
            SyntaxKind::Emph => self.delimited(node, offset, "emph"),
            SyntaxKind::Raw => self.raw(node, offset),
            SyntaxKind::Link => {
                self.elements
                    .push(Element::new("link", self.u(offset), self.u(end)))
            }
            SyntaxKind::Label | SyntaxKind::Ref => {
                self.elements
                    .push(Element::new("code", self.u(offset), self.u(end)))
            }
            SyntaxKind::LineComment | SyntaxKind::BlockComment => {
                self.elements
                    .push(Element::new("comment", self.u(offset), self.u(end)))
            }
            SyntaxKind::Linebreak => {
                self.elements
                    .push(Element::new("linebreak", self.u(offset), self.u(end)))
            }
            SyntaxKind::Escape => {
                let mut element = Element::new("escape", self.u(offset), self.u(end));
                if node.len() == 2 {
                    element.markers.push((self.u(offset), self.u(offset + 1)));
                } else {
                    element.kind = "code";
                }
                self.elements.push(element);
            }
            SyntaxKind::Shorthand => {
                let replacement = match node.leaf_text().as_str() {
                    "--" => Some("\u{2013}"),
                    "---" => Some("\u{2014}"),
                    "..." => Some("\u{2026}"),
                    "~" => Some("\u{00a0}"),
                    _ => None,
                };
                if let Some(replacement) = replacement {
                    let mut element = Element::new("shorthand", self.u(offset), self.u(end));
                    element.text = Some(replacement);
                    self.elements.push(element);
                }
            }
            SyntaxKind::Equation => {
                let mut element = Element::new("math", self.u(offset), self.u(end));
                element.block = node.cast::<ast::Equation>().is_some_and(|eq| eq.block());
                self.elements.push(element);
            }
            SyntaxKind::ListItem => self.list_item(node, offset),
            SyntaxKind::TermItem => self.term_item(node, offset),
            SyntaxKind::Markup => self.markup(node, offset),
            _ => {}
        }
    }

    fn heading(&mut self, node: &SyntaxNode, offset: usize) {
        let mut element = Element::new("heading", self.u(offset), self.u(offset + node.len()));
        let mut cursor = offset;
        let mut marker_end = offset;
        for child in node.children() {
            let start = cursor;
            cursor += child.len();
            match child.kind() {
                SyntaxKind::HeadingMarker => {
                    element.number = Some(child.len() as i64);
                    marker_end = cursor;
                }
                SyntaxKind::Space if marker_end == start => marker_end = cursor,
                SyntaxKind::Markup => {
                    element.markers.push((self.u(offset), self.u(marker_end)));
                    self.elements.push(element);
                    self.markup(child, start);
                    return;
                }
                _ => {}
            }
        }
        element.markers.push((self.u(offset), self.u(marker_end)));
        self.elements.push(element);
    }

    fn delimited(&mut self, node: &SyntaxNode, offset: usize, kind: &'static str) {
        let children: Vec<&SyntaxNode> = node.children().collect();
        let end = offset + node.len();
        let mut element = Element::new(kind, self.u(offset), self.u(end));
        let delimiter = if kind == "strong" {
            SyntaxKind::Star
        } else {
            SyntaxKind::Underscore
        };
        if children.first().is_some_and(|c| c.kind() == delimiter) {
            element.markers.push((self.u(offset), self.u(offset + 1)));
        }
        if children.len() > 1 && children.last().is_some_and(|c| c.kind() == delimiter) {
            element.markers.push((self.u(end - 1), self.u(end)));
        }
        self.elements.push(element);
        let mut cursor = offset;
        for child in children {
            if child.kind() == SyntaxKind::Markup {
                self.markup(child, cursor);
            }
            cursor += child.len();
        }
    }

    fn raw(&mut self, node: &SyntaxNode, offset: usize) {
        let end = offset + node.len();
        let text = node.full_text();
        let children: Vec<&SyntaxNode> = node.children().collect();
        let delimiter = children.first().map(|c| c.len()).unwrap_or(1);
        let mut element = Element::new("raw", self.u(offset), self.u(end));
        element.block = delimiter >= 3;
        if element.block {
            let first_line = text.find('\n').map(|i| i + 1).unwrap_or(text.len());
            element
                .markers
                .push((self.u(offset), self.u(offset + first_line)));
            let closes = children.len() > 1
                && children
                    .last()
                    .is_some_and(|c| c.kind() == SyntaxKind::RawDelim);
            if closes {
                let last_line = text.rfind('\n').map(|i| i + 1).unwrap_or(0);
                if last_line >= first_line {
                    // Hide the closing fence and the newline before it.
                    let hidden_from = if last_line > first_line {
                        last_line - 1
                    } else {
                        last_line
                    };
                    element
                        .markers
                        .push((self.u(offset + hidden_from), self.u(end)));
                }
            }
        } else {
            element
                .markers
                .push((self.u(offset), self.u(offset + delimiter)));
            if children.len() > 1
                && children
                    .last()
                    .is_some_and(|c| c.kind() == SyntaxKind::RawDelim)
            {
                element.markers.push((self.u(end - delimiter), self.u(end)));
            }
        }
        self.elements.push(element);
    }

    fn list_item(&mut self, node: &SyntaxNode, offset: usize) {
        let mut element = Element::new("list", self.u(offset), self.u(offset + node.len()));
        let mut cursor = offset;
        for child in node.children() {
            let start = cursor;
            cursor += child.len();
            match child.kind() {
                SyntaxKind::ListMarker => element.markers.push((self.u(start), self.u(cursor))),
                SyntaxKind::Markup => {
                    self.elements.push(element);
                    self.markup(child, start);
                    return;
                }
                _ => {}
            }
        }
        self.elements.push(element);
    }

    /// Returns the number this item displays so the next item can continue.
    fn enum_item(&mut self, node: &SyntaxNode, offset: usize, previous: i64) -> i64 {
        let mut element = Element::new("enum", self.u(offset), self.u(offset + node.len()));
        let mut number = previous + 1;
        let mut cursor = offset;
        for child in node.children() {
            let start = cursor;
            cursor += child.len();
            match child.kind() {
                SyntaxKind::EnumMarker => {
                    let marker = child.leaf_text();
                    if let Ok(explicit) = marker.trim_end_matches('.').parse::<i64>() {
                        number = explicit;
                    }
                    element.markers.push((self.u(start), self.u(cursor)));
                }
                SyntaxKind::Markup => {
                    element.number = Some(number);
                    self.elements.push(element);
                    self.markup(child, start);
                    return number;
                }
                _ => {}
            }
        }
        element.number = Some(number);
        self.elements.push(element);
        number
    }

    fn term_item(&mut self, node: &SyntaxNode, offset: usize) {
        let mut element = Element::new("term", self.u(offset), self.u(offset + node.len()));
        let mut cursor = offset;
        let mut seen_colon = false;
        let mut bodies = Vec::new();
        for child in node.children() {
            let start = cursor;
            cursor += child.len();
            match child.kind() {
                SyntaxKind::TermMarker => element.markers.push((self.u(start), self.u(cursor))),
                SyntaxKind::Space if !seen_colon && element.content.is_none() => {
                    if let Some(last) = element.markers.last_mut() {
                        if last.1 == self.u(start) {
                            last.1 = self.u(cursor);
                        }
                    }
                }
                SyntaxKind::Colon => {
                    seen_colon = true;
                    element.markers.push((self.u(start), self.u(cursor)));
                }
                SyntaxKind::Markup => {
                    if !seen_colon {
                        element.content = Some((self.u(start), self.u(cursor)));
                    }
                    bodies.push((child, start));
                }
                _ => {}
            }
        }
        self.elements.push(element);
        for (child, start) in bodies {
            self.markup(child, start);
        }
    }
}
