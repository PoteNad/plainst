//! Colours the code inside raw blocks that name a language, with the same syntax
//! definitions Typst uses when it typesets them.

use std::cell::RefCell;
use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::rc::Rc;
use std::sync::LazyLock;

use syntect::parsing::{ParseState, Scope, ScopeStack};
use typst::text::RAW_SYNTAXES;
use typst_syntax::{SyntaxKind, SyntaxNode};

/// Token categories, in the order the editor's styles expect.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Token {
    Comment = 0,
    String = 1,
    Keyword = 2,
    Constant = 3,
    Function = 4,
    Type = 5,
}

/// Scope prefixes and the category each one means. The innermost matching scope wins.
static CATEGORIES: LazyLock<Vec<(Scope, Option<Token>)>> = LazyLock::new(|| {
    [
        ("comment", Some(Token::Comment)),
        ("string", Some(Token::String)),
        ("constant.character.escape", Some(Token::Constant)),
        ("constant", Some(Token::Constant)),
        ("keyword.operator", None),
        ("keyword", Some(Token::Keyword)),
        ("storage.type", Some(Token::Keyword)),
        ("storage.modifier", Some(Token::Keyword)),
        ("variable.language", Some(Token::Keyword)),
        ("entity.name.function", Some(Token::Function)),
        ("support.function", Some(Token::Function)),
        ("variable.function", Some(Token::Function)),
        ("meta.function-call.identifier", Some(Token::Function)),
        ("entity.other.attribute-name", Some(Token::Function)),
        ("entity.name.tag", Some(Token::Keyword)),
        ("entity.name.type", Some(Token::Type)),
        ("entity.name.class", Some(Token::Type)),
        ("entity.name.struct", Some(Token::Type)),
        ("entity.name.enum", Some(Token::Type)),
        ("entity.other.inherited-class", Some(Token::Type)),
        ("support.type", Some(Token::Type)),
        ("support.class", Some(Token::Type)),
    ]
    .into_iter()
    .filter_map(|(name, token)| Scope::new(name).ok().map(|scope| (scope, token)))
    .collect()
});

fn category(stack: &ScopeStack) -> Option<Token> {
    for scope in stack.as_slice().iter().rev() {
        if let Some((_, token)) = CATEGORIES
            .iter()
            .find(|(prefix, _)| prefix.is_prefix_of(*scope))
        {
            if token.is_some() {
                return *token;
            }
        }
    }
    None
}

thread_local! {
    /// Tokens of recently highlighted raw nodes, relative to each node's start. The outline is
    /// rebuilt on every edit, but most code blocks are unchanged.
    static CACHE: RefCell<HashMap<u64, Rc<Vec<(usize, usize, Token)>>>> = RefCell::new(HashMap::new());
}

/// Reports the tokens of a raw node's code as byte ranges in the document.
pub fn raw_tokens(node: &SyntaxNode, offset: usize, mut report: impl FnMut(usize, usize, Token)) {
    if !node.children().any(|c| c.kind() == SyntaxKind::RawLang) {
        return;
    }
    let mut hasher = DefaultHasher::new();
    node.full_text().hash(&mut hasher);
    let key = hasher.finish();
    let tokens = CACHE.with_borrow_mut(|cache| {
        if let Some(tokens) = cache.get(&key) {
            return tokens.clone();
        }
        let mut tokens = Vec::new();
        highlight(node, |start, end, token| tokens.push((start, end, token)));
        if cache.len() >= 256 {
            cache.clear();
        }
        let tokens = Rc::new(tokens);
        cache.insert(key, tokens.clone());
        tokens
    });
    for &(start, end, token) in tokens.iter() {
        report(offset + start, offset + end, token);
    }
}

/// Highlights a raw node's code, reporting byte ranges relative to the node's start.
fn highlight(node: &SyntaxNode, mut report: impl FnMut(usize, usize, Token)) {
    let Some(tag) = node.children().find(|c| c.kind() == SyntaxKind::RawLang) else {
        return;
    };
    let set = &*RAW_SYNTAXES;
    let Some(syntax) = set.find_syntax_by_token(tag.leaf_text()) else {
        return;
    };
    let mut state = ParseState::new(syntax);
    let mut stack = ScopeStack::new();
    // Adjacent tokens of one category are reported as one range.
    let mut pending: Option<(usize, usize, Token)> = None;
    let mut emit = |start: usize, end: usize, token: Option<Token>, flush: bool| {
        match (pending, token) {
            (Some((s, e, t)), Some(new)) if e == start && t == new => pending = Some((s, end, t)),
            _ => {
                if let Some((s, e, t)) = pending.take() {
                    report(s, e, t);
                }
                if let Some(new) = token {
                    if end > start {
                        pending = Some((start, end, new));
                    }
                }
            }
        }
        if flush {
            if let Some((s, e, t)) = pending.take() {
                report(s, e, t);
            }
        }
    };

    let mut cursor = 0;
    for child in node.children() {
        let start = cursor;
        cursor += child.len();
        if child.kind() != SyntaxKind::Text {
            continue;
        }
        let line = child.leaf_text();
        // The syntaxes expect one line at a time, without its newline.
        let Ok(ops) = state.parse_line(line, set) else {
            return;
        };
        let mut position = 0;
        for (index, op) in ops {
            if index > position {
                emit(start + position, start + index, category(&stack), false);
                position = index;
            }
            if stack.apply(&op).is_err() {
                return;
            }
        }
        if line.len() > position {
            emit(
                start + position,
                start + line.len(),
                category(&stack),
                false,
            );
        }
    }
    emit(cursor, cursor, None, true);
}
