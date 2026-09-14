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
    let output = compile("= Hello\n\nWorld $x$\n", true);
    assert!(output.json.contains("\"pages\":1"), "{}", output.json);
    assert!(output.pdf.unwrap().starts_with(b"%PDF"));
}

#[test]
fn reports_diagnostics_in_utf16() {
    let output = compile("é #unknown", false);
    assert!(
        output.json.contains("\"error\":true,\"s\":3,\"e\":10"),
        "{}",
        output.json
    );
}

#[test]
fn packages_are_unavailable() {
    let output = compile("#import \"@preview/foo:0.1.0\": *\n", false);
    assert!(output.json.contains("offline"), "{}", output.json);
}

#[test]
fn completes_math_symbols() {
    let text = "Energy $alp$ here";
    let json = complete_json(text, 11, false);
    assert!(json.contains("\"label\":\"alpha\""), "{json}");
    assert!(json.contains("\"symbol\":\"α\""), "{json}");
    assert!(json.starts_with("{\"from\":8,"), "{json}");
}

#[test]
fn completes_math_functions_with_snippets() {
    let json = complete_json("$fra$", 4, false);
    assert!(json.contains("\"label\":\"frac\""), "{json}");
    assert!(json.contains("${"), "{json}");
}

#[test]
fn lists_symbols() {
    let json = symbols_json();
    assert!(json.contains("[\"alpha\",\"α\"]"), "{}", &json[..200]);
    assert!(json.contains("[\"arrow.r\",\"→\"]"));
}
