//! A single-file Typst world with bundled fonts and no file or network access.

use std::sync::{LazyLock, Mutex, OnceLock};

use typst::diag::{FileError, FileResult, PackageError, Severity, SourceDiagnostic, Warned};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::layout::{Abs, Frame, FrameItem, Point};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::{LazyHash, Scalar};
use typst::{Library, LibraryExt, World, WorldExt};
use typst_kit::datetime::Time;
use typst_kit::fonts::FontStore;
use typst_layout::PagedDocument;

use crate::{Utf16Map, json_string};

static LIBRARY: LazyLock<LazyHash<Library>> = LazyLock::new(|| LazyHash::new(Library::default()));
static FONTS: OnceLock<FontStore> = OnceLock::new();
pub(crate) static MAIN_ID: LazyLock<FileId> = LazyLock::new(|| file_id("main.typ"));
static MATH_ID: LazyLock<FileId> = LazyLock::new(|| file_id("equation.typ"));
/// The last compiled document source, kept so Typst can reparse incrementally.
static DOCUMENT: Mutex<Option<Source>> = Mutex::new(None);
/// Compilations share Typst's global memoization cache, so run them one at a time.
static COMPILER: Mutex<()> = Mutex::new(());

fn file_id(name: &str) -> FileId {
    RootedPath::new(
        VirtualRoot::Project,
        VirtualPath::new(name).expect("valid path"),
    )
    .intern()
}

/// Loads the bundled fonts first, then the fonts installed on this Mac.
pub(crate) fn fonts() -> &'static FontStore {
    FONTS.get_or_init(|| {
        let mut store = FontStore::new();
        store.extend(typst_kit::fonts::embedded());
        if std::env::var_os("PLAINST_NO_SYSTEM_FONTS").is_none() {
            store.extend(typst_kit::fonts::system());
        }
        store
    })
}

pub(crate) struct PlainstWorld {
    main: Source,
    time: Time,
}

impl PlainstWorld {
    pub(crate) fn new(main: Source) -> Self {
        Self {
            main,
            time: Time::system(),
        }
    }
}

impl World for PlainstWorld {
    fn library(&self) -> &LazyHash<Library> {
        &LIBRARY
    }

    fn book(&self) -> &LazyHash<FontBook> {
        fonts().book()
    }

    fn main(&self) -> FileId {
        self.main.id()
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main.id() {
            Ok(self.main.clone())
        } else {
            Err(unavailable(id))
        }
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if id == self.main.id() {
            Ok(Bytes::from_string(self.main.clone()))
        } else {
            Err(unavailable(id))
        }
    }

    fn font(&self, index: usize) -> Option<Font> {
        fonts().font(index)
    }

    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        self.time.today(offset)
    }
}

/// Plainst edits one self-contained file, so other files and packages are never loaded.
fn unavailable(id: FileId) -> FileError {
    if matches!(id.get().root(), VirtualRoot::Package(_)) {
        FileError::Package(PackageError::Other(Some(
            "Plainst works offline with single files, so packages are not available".into(),
        )))
    } else {
        FileError::Other(Some(
            "Plainst edits single files, so other files cannot be loaded".into(),
        ))
    }
}

/// The result of compiling a whole document.
pub struct CompileOutput {
    pub json: String,
    pub pdf: Option<Vec<u8>>,
}

/// Compiles the document, returning diagnostics and, when requested, a PDF.
///
/// A document without errors is kept under `key` for completions and the preview.
pub fn compile(text: &str, want_pdf: bool, key: u64) -> CompileOutput {
    let _guard = COMPILER.lock().unwrap_or_else(|e| e.into_inner());
    let source = {
        let mut cached = DOCUMENT.lock().unwrap_or_else(|e| e.into_inner());
        match cached.as_mut() {
            Some(source) => {
                if source.text() != text {
                    source.replace(text);
                }
                source.clone()
            }
            None => {
                let source = Source::new(*MAIN_ID, text.to_owned());
                *cached = Some(source.clone());
                source
            }
        }
    };
    let world = PlainstWorld::new(source.clone());
    let Warned { output, warnings } = typst::compile::<PagedDocument>(&world);
    let map = Utf16Map::new(text);

    let mut diagnostics: Vec<SourceDiagnostic> = warnings.into_iter().collect();
    let mut pages = 0;
    let mut pdf = None;
    match output {
        Ok(document) => {
            pages = document.pages().len();
            if want_pdf {
                match typst_pdf::pdf(&document, &typst_pdf::PdfOptions::default()) {
                    Ok(bytes) => pdf = Some(bytes),
                    Err(errors) => diagnostics.extend(errors),
                }
            }
            crate::preview::store(key, crate::preview::Compiled { document, source });
        }
        Err(errors) => diagnostics.extend(errors),
    }
    typst::comemo::evict(30);

    let mut json = format!("{{\"pages\":{pages},\"diagnostics\":[");
    for (index, diagnostic) in diagnostics.iter().enumerate() {
        if index > 0 {
            json.push(',');
        }
        let range = (diagnostic.span.id() == Some(*MAIN_ID))
            .then(|| world.range(diagnostic.span))
            .flatten();
        let (start, end) = range
            .as_ref()
            .map(|r| (map.get(r.start), map.get(r.end)))
            .unwrap_or((0, 0));
        json.push_str("{\"error\":");
        json.push_str(if diagnostic.severity == Severity::Error {
            "true"
        } else {
            "false"
        });
        json.push_str(&format!(
            ",\"s\":{start},\"e\":{end},\"located\":{}",
            range.is_some()
        ));
        json.push_str(",\"message\":");
        json_string(&mut json, &diagnostic.message);
        json.push_str(",\"hints\":[");
        for (i, hint) in diagnostic.hints.iter().enumerate() {
            if i > 0 {
                json.push(',');
            }
            json_string(&mut json, &hint.v);
        }
        json.push_str("]}");
    }
    json.push_str("]}");
    CompileOutput { json, pdf }
}

/// A rendered equation.
pub struct MathImage {
    pub width_px: u32,
    pub height_px: u32,
    pub width_pt: f32,
    pub height_pt: f32,
    /// Distance from the top of the image to the text baseline, in points.
    pub baseline_pt: f32,
    /// Premultiplied RGBA pixels.
    pub pixels: Vec<u8>,
}

/// Renders an equation exactly as written (including its `$` delimiters).
///
/// Inline equations are measured inside a box so the editor can align them with
/// the surrounding text; display equations are rendered on their own.
pub fn render_math(
    equation: &str,
    block: bool,
    pixels_per_pt: f64,
    rgba: [u8; 4],
) -> Result<MathImage, String> {
    let _guard = COMPILER.lock().unwrap_or_else(|e| e.into_inner());
    let [r, g, b, a] = rgba;
    let body = if block {
        equation.to_owned()
    } else {
        format!("#box[{equation}]")
    };
    let text = format!(
        "#set page(width: auto, height: auto, margin: 0pt, fill: none)\n\
         #set text(fill: rgb({r}, {g}, {b}, {a}), top-edge: \"bounds\", bottom-edge: \"bounds\")\n{body}"
    );
    let world = PlainstWorld::new(Source::new(*MATH_ID, text));
    let result = typst::compile::<PagedDocument>(&world).output;
    typst::comemo::evict(30);
    let document = result.map_err(|errors| {
        errors
            .iter()
            .find(|e| e.severity == Severity::Error)
            .map(|e| e.message.to_string())
            .unwrap_or_else(|| "The equation could not be rendered".into())
    })?;
    let page = document.pages().first().ok_or("The equation is empty")?;
    let size = page.frame.size();
    if size.x.to_pt() <= 0.0 || size.y.to_pt() <= 0.0 {
        return Err("The equation is empty".into());
    }
    let baseline = if block {
        size.y
    } else {
        find_baseline(&page.frame, Point::zero()).unwrap_or(size.y)
    };
    let options = typst_render::RenderOptions {
        pixel_per_pt: Scalar::new(pixels_per_pt),
        render_bleed: false,
    };
    let pixmap = typst_render::render(page, &options);
    Ok(MathImage {
        width_px: pixmap.width(),
        height_px: pixmap.height(),
        width_pt: size.x.to_pt() as f32,
        height_pt: size.y.to_pt() as f32,
        baseline_pt: baseline.to_pt() as f32,
        pixels: pixmap.take(),
    })
}

/// Finds the baseline of the first frame that has one, in page coordinates.
fn find_baseline(frame: &Frame, origin: Point) -> Option<Abs> {
    for (pos, item) in frame.items() {
        if let FrameItem::Group(group) = item {
            let at = origin + *pos;
            if group.frame.has_baseline() {
                return Some(at.y + group.frame.baseline());
            }
            if let Some(found) = find_baseline(&group.frame, at) {
                return Some(found);
            }
        }
    }
    None
}

/// Loads fonts and the standard library so the first real render is quick.
pub fn warm_up() {
    let _ = render_math("$x$", false, 1.0, [0, 0, 0, 255]);
}
