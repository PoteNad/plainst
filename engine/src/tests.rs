use super::*;

#[test]
fn outline_reports_supported_markup() {
    let text = "= Title\n\nSome *bold* and _it_ with $x^2$.\n\n$ a + b $\n\n- one\n+ first\n+ second\n/ Term: desc\n`code` -- #set text(red)\n// note\n";
    let json = outline_json(text);
    for kind in [
        "heading",
        "strong",
        "emph",
        "math",
        "list",
        "enum",
        "term",
        "raw",
        "shorthand",
        "code",
        "comment",
    ] {
        assert!(
            json.contains(&format!("\"k\":\"{kind}\"")),
            "missing {kind}: {json}"
        );
    }
    assert!(
        json.contains("\"k\":\"math\",\"s\":43,\"e\":52,\"b\":true"),
        "{json}"
    );
    assert!(json.contains("\"n\":2"), "{json}");
}

#[test]
fn outline_uses_utf16_offsets() {
    let json = outline_json("é😀 *b*");
    assert!(json.contains("\"k\":\"strong\",\"s\":4,\"e\":7"), "{json}");
}

#[test]
fn renders_inline_math_with_baseline() {
    let image = render_math("$x^2/y$", false, 2.0, [0, 0, 0, 255]).unwrap();
    assert!(image.width_px > 4 && image.height_px > 4);
    assert_eq!(
        image.pixels.len(),
        (image.width_px * image.height_px * 4) as usize
    );
    assert!(
        image.baseline_pt > 0.0 && image.baseline_pt < image.height_pt,
        "{} {}",
        image.baseline_pt,
        image.height_pt
    );
}

#[test]
fn renders_display_math() {
    let image = render_math("$ sum_(k=1)^n k $", true, 2.0, [0, 0, 0, 255]).unwrap();
    assert!(image.height_pt > 10.0);
}

#[test]
fn reports_math_errors() {
    assert!(render_math("$#foo$", false, 2.0, [0, 0, 0, 255]).is_err());
}

#[test]
fn compiles_pdf() {
    let output = compile("= Hello\n\nWorld $x$\n", true, 0);
    assert!(output.json.contains("\"pages\":1"), "{}", output.json);
    assert!(output.pdf.unwrap().starts_with(b"%PDF"));
}

#[test]
fn reports_diagnostics_in_utf16() {
    let output = compile("é #unknown", false, 0);
    assert!(
        output.json.contains("\"error\":true,\"s\":3,\"e\":10"),
        "{}",
        output.json
    );
}

#[test]
fn packages_are_unavailable() {
    let output = compile("#import \"@preview/foo:0.1.0\": *\n", false, 0);
    assert!(output.json.contains("offline"), "{}", output.json);
}

#[test]
fn completes_math_symbols() {
    let text = "Energy $alp$ here";
    let json = complete_json(text, 11, false, 0);
    assert!(json.contains("\"label\":\"alpha\""), "{json}");
    assert!(json.contains("\"symbol\":\"α\""), "{json}");
    assert!(json.starts_with("{\"from\":8,"), "{json}");
}

#[test]
fn completes_math_functions_with_snippets() {
    let json = complete_json("$fra$", 4, false, 0);
    assert!(json.contains("\"label\":\"frac\""), "{json}");
    assert!(json.contains("${"), "{json}");
}

#[test]
fn lists_symbols() {
    let json = symbols_json();
    assert!(json.contains("[\"alpha\",\"α\"]"), "{}", &json[..200]);
    assert!(json.contains("[\"arrow.r\",\"→\"]"));
    assert!(json.contains("{\"title\":\"Lowercase Greek\""));
}

#[test]
fn symbol_groups_cover_every_symbol() {
    // If codex adds symbols, regenerate engine/src/symbol_groups.txt so they get a real category.
    assert!(
        !symbols_json().contains("{\"title\":\"Other\""),
        "run scripts/generate-symbol-groups.swift"
    );
    let listed = include_str!("symbol_groups.txt");
    for line in listed
        .lines()
        .filter(|l| !l.starts_with('#') && !l.starts_with("==") && !l.is_empty())
    {
        assert!(
            codex::SYM.get(line).is_some(),
            "unknown symbol {line} in symbol_groups.txt"
        );
    }
}

#[test]
fn completes_references_from_the_compiled_document() {
    use typst::syntax::Source;
    let text = "#set heading(numbering: \"1.\")\n= Introduction <intro>\n\nSee @";
    let source = Source::new(*world::MAIN_ID, text.to_owned());
    let document =
        typst::compile::<typst_layout::PagedDocument>(&world::PlainstWorld::new(source.clone()))
            .output
            .expect("the document compiles");
    let json = ide::complete_in(&source, text.len(), false, Some(&document));
    assert!(
        json.contains("\"kind\":\"label\",\"label\":\"intro\""),
        "{json}"
    );
    assert!(json.contains("\"detail\":\"Introduction\""), "{json}");
}

#[test]
fn outline_reports_labels_and_references() {
    let json = outline_json("= Intro <intro>\n\nSee @intro.\n");
    assert!(json.contains("\"k\":\"label\",\"s\":8,\"e\":15"), "{json}");
    assert!(
        json.contains("\"k\":\"ref\",\"s\":21,\"e\":27,\"m\":[[21,22]]"),
        "{json}"
    );
}

#[test]
fn previews_pages_and_jumps_both_ways() {
    let key = 0x5EED;
    let text = "= Title\n\nFirst page.\n#pagebreak()\nSecond page with $x^2$.\n";
    assert!(!compile(text, false, key).json.contains("\"error\":true"));
    let pages = pages_binary(key);
    assert_eq!(&pages[..4], b"PLP1");
    assert_eq!(u32::from_le_bytes(pages[4..8].try_into().unwrap()), 2);
    let width = f32::from_le_bytes(pages[8..12].try_into().unwrap());
    assert!((width - 595.28).abs() < 1.0, "{width}");
    let hash = u128::from_le_bytes(pages[16..32].try_into().unwrap());

    let image = render_page_binary(key, 0, 1.0, hash);
    assert_eq!(&image[..4], b"PLI1");
    assert_eq!(&render_page_binary(key, 0, 1.0, hash ^ 1)[..4], b"PLE1");

    // Text on the second page leads back to its source, and back again.
    let second = text.find("Second").unwrap() as u32 + 2;
    let places = positions_binary(key, text, second as usize);
    assert_eq!(&places[..4], b"PLJ1");
    assert_eq!(u32::from_le_bytes(places[4..8].try_into().unwrap()), 1);
    assert_eq!(u32::from_le_bytes(places[8..12].try_into().unwrap()), 1);
    let x = f32::from_le_bytes(places[12..16].try_into().unwrap());
    let y = f32::from_le_bytes(places[16..20].try_into().unwrap());
    let offset = jump_from_click(key, 1, x as f64 + 1.0, y as f64 - 3.0);
    let found = text.find("Second").unwrap() as i64;
    assert!((found..found + 6).contains(&offset), "{offset}");
    assert!(positions_binary(key, "edited", 1)[4..8] == [0, 0, 0, 0]);
    forget(key);
    assert_eq!(pages_binary(key)[4..8], [0, 0, 0, 0]);
}

#[test]
fn reads_the_document_style_from_top_level_set_rules() {
    let text = "#set text(font: (\"New Computer Modern\", \"Libertinus Serif\"), size: 10pt)\n\
                #set par(first-line-indent: 1em, justify: true)\n\
                #set text(size: 1em) if false\n\
                #let f() = { set text(size: 20pt) }\n\
                #set text(fill: red, size: 12pt)\n\nBody.\n";
    let json = style_json(text);
    assert!(
        json.starts_with("{\"font\":\"New Computer Modern\",\"size\":12,\"justify\":true"),
        "{json}"
    );
    // The last text rule is the one to edit, with both of its arguments.
    let last = text.rfind("#set text(fill").unwrap();
    assert!(
        json.contains(&format!("\"text\":{{\"s\":{last},")),
        "{json}"
    );
    assert!(json.contains("{\"n\":\"fill\""), "{json}");
    assert!(json.contains("{\"n\":\"first-line-indent\""), "{json}");
    assert_eq!(
        style_json("Plain text.\n"),
        "{\"font\":null,\"size\":null,\"justify\":null,\"text\":null,\"par\":null}"
    );
    assert!(
        style_json("#set text(size: 2cm)").contains("\"size\":56.69"),
        "{}",
        style_json("#set text(size: 2cm)")
    );
}

#[test]
fn lists_font_families() {
    let json = font_families_json();
    assert!(json.contains("\"Libertinus Serif\""), "{json}");
    assert!(json.contains("\"New Computer Modern\""), "{json}");
}

#[test]
fn outline_reports_link_calls() {
    let text = "See #link(\"https://typst.app\")[the *Typst* site] or #link(\"https://a.b\").";
    let json = outline_json(text);
    let start = text.find("#link").unwrap();
    let body = text.find("the *").unwrap();
    assert!(
        json.contains(&format!("\"k\":\"hyperlink\",\"s\":{start},")),
        "{json}"
    );
    assert!(
        json.contains(&format!("\"c\":[{body},{}]", text.find("] or").unwrap())),
        "{json}"
    );
    // Markup inside the link text is still styled.
    assert!(json.contains("\"k\":\"strong\""), "{json}");
    let bare = text.rfind("#link").unwrap();
    let address = text.rfind("https://a.b").unwrap();
    assert!(
        json.contains(&format!("\"k\":\"hyperlink\",\"s\":{bare},")),
        "{json}"
    );
    assert!(
        json.contains(&format!("\"c\":[{address},{}]", address + 11)),
        "{json}"
    );
    // Other calls stay embedded code.
    assert!(outline_json("#link(dest: \"x\")[y]").contains("\"k\":\"code\""));
}

#[test]
fn outline_colours_code_blocks_by_language() {
    let text = "```python\n# note\ndef area(r):\n    return 3.14 * r  # half\n```\n\n```unknown\nfn x\n```\n\n`let x = \"s\"`\n";
    let json = outline_json(text);
    let token = |needle: &str, category: i64| {
        let start = text.find(needle).unwrap();
        format!(
            "\"k\":\"token\",\"s\":{start},\"e\":{},\"n\":{category}",
            start + needle.len()
        )
    };
    assert!(json.contains(&token("# note", 0)), "{json}");
    assert!(json.contains(&token("def", 2)), "{json}");
    assert!(json.contains(&token("area", 4)), "{json}");
    assert!(json.contains(&token("return", 2)), "{json}");
    assert!(json.contains(&token("3.14", 3)), "{json}");
    // Unknown languages and untagged raw text stay plain.
    let unknown = text.find("```unknown").unwrap();
    assert!(
        !json.split("\"k\":\"token\",\"s\":").skip(1).any(|rest| {
            rest.split(',')
                .next()
                .and_then(|s| s.parse::<usize>().ok())
                .is_some_and(|s| s > unknown)
        }),
        "{json}"
    );
}

#[test]
fn code_highlighting_is_quick() {
    let started = std::time::Instant::now();
    outline_json("```rust\nfn main() {}\n```\n");
    let first = started.elapsed();
    let block = format!(
        "```python\n{}```\n",
        "def f(x):\n    return x * 2  # twice\n".repeat(500)
    );
    let started = std::time::Instant::now();
    outline_json(&block);
    let fresh = started.elapsed();
    let started = std::time::Instant::now();
    outline_json(&format!("Edited.\n\n{block}"));
    let cached = started.elapsed();
    eprintln!("first {first:?}, 1000 lines {fresh:?}, unchanged {cached:?}");
    assert!(
        cached < fresh / 4,
        "an unchanged block should come from the cache"
    );
}
