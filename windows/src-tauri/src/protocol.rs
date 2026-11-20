//! `miku://` serves the shared page and its assets, like macOS `StaticHTTPServer.swift`.
//!
//! - `/companion/...` and `/assets/...` come from the `Wallpaper/` folder: the repository's own
//!   copy in debug builds (so edits to the shared page show on reload), the bundled resources in
//!   release builds. Nothing is copied into `windows/`.
//! - `/assets/companion-model/tda/...` comes from the folder the user imported the Tda model into
//!   (`%APPDATA%\MikuDesktop\CharacterModels\tda`) once it holds `miku.pmx`. The model is never
//!   bundled (AGENTS.md).
//!
//! On Windows WebView2 sees the scheme as `http://miku.localhost/`; elsewhere as `miku://localhost/`.

use std::borrow::Cow;
use std::path::{Path, PathBuf};

use percent_encoding::percent_decode_str;
use tauri::http::{header, Request, Response, StatusCode};

pub const SCHEME: &str = "miku";

/// The page URL for one layer (`background` or `character`).
pub fn layer_url(layer: &str) -> tauri::Url {
    #[cfg(windows)]
    let base = "http://miku.localhost";
    #[cfg(not(windows))]
    let base = "miku://localhost";
    format!("{base}/companion/index.html?layer={layer}")
        .parse()
        .expect("static layer URL")
}

pub struct PageFiles {
    root: PathBuf,
    imported_tda: PathBuf,
}

const IMPORTED_PREFIX: [&str; 3] = ["assets", "companion-model", "tda"];

impl PageFiles {
    pub fn new(root: PathBuf, imported_tda: PathBuf) -> Self {
        Self { root, imported_tda }
    }

    /// The file for a request path, or `None` when it would leave its folder or does not exist.
    pub fn resolve(&self, request_path: &str) -> Option<PathBuf> {
        let decoded = percent_decode_str(request_path).decode_utf8().ok()?;
        if decoded.contains('\0') || decoded.contains('\\') || decoded.contains(':') {
            return None;
        }
        let components: Vec<&str> = decoded.split('/').filter(|part| !part.is_empty()).collect();
        if components.iter().any(|part| *part == ".." || *part == ".") {
            return None;
        }

        let (base, rest) = if components.len() >= 3
            && components[..3] == IMPORTED_PREFIX
            && self.imported_tda.join("miku.pmx").is_file()
        {
            (self.imported_tda.as_path(), &components[3..])
        } else {
            (self.root.as_path(), &components[..])
        };

        let base = base.canonicalize().ok()?;
        let mut requested = rest.iter().fold(base.clone(), |path, part| path.join(part));
        if requested.is_dir() {
            requested.push("index.html");
        }
        // Resolves symlinks and checks the file exists; it must still be inside its folder.
        let requested = requested.canonicalize().ok()?;
        requested.starts_with(&base).then_some(requested)
    }

    pub fn respond(&self, request: &Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
        let method = request.method().as_str();
        if method != "GET" && method != "HEAD" {
            return plain(StatusCode::METHOD_NOT_ALLOWED);
        }
        let Some(file) = self.resolve(request.uri().path()) else {
            return plain(StatusCode::NOT_FOUND);
        };
        let body = match std::fs::read(&file) {
            Ok(body) => body,
            Err(_) => return plain(StatusCode::NOT_FOUND),
        };
        let length = body.len();
        let body = if method == "HEAD" { Vec::new() } else { body };
        Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, mime_type(&file))
            .header(header::CONTENT_LENGTH, length)
            .header(header::CACHE_CONTROL, "no-cache")
            .header("X-Content-Type-Options", "nosniff")
            .body(Cow::Owned(body))
            .unwrap_or_else(|_| plain(StatusCode::INTERNAL_SERVER_ERROR))
    }
}

pub fn not_found() -> Response<Cow<'static, [u8]>> {
    plain(StatusCode::NOT_FOUND)
}

fn plain(status: StatusCode) -> Response<Cow<'static, [u8]>> {
    let mut response = Response::new(Cow::Borrowed(&[][..]));
    *response.status_mut() = status;
    response
}

/// Same table as `StaticHTTPServer.mimeType`, plus the model formats the loader fetches.
pub fn mime_type(path: &Path) -> &'static str {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "bmp" => "image/bmp",
        "txt" | "md" => "text/plain; charset=utf-8",
        "wasm" => "application/wasm",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct Fixture {
        dir: PathBuf,
        files: PageFiles,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    fn fixture(name: &str, imported_model: bool) -> Fixture {
        let dir = std::env::temp_dir().join(format!("miku-protocol-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let root = dir.join("Wallpaper");
        fs::create_dir_all(root.join("companion")).unwrap();
        fs::create_dir_all(root.join("assets/companion-model")).unwrap();
        fs::write(root.join("companion/index.html"), "page").unwrap();
        fs::write(root.join("assets/companion-model/miku_v2.pmd"), "default").unwrap();
        fs::write(dir.join("secret.txt"), "outside").unwrap();
        let imported = dir.join("CharacterModels/tda");
        fs::create_dir_all(&imported).unwrap();
        if imported_model {
            fs::write(imported.join("miku.pmx"), "tda").unwrap();
        }
        Fixture { files: PageFiles::new(root, imported), dir }
    }

    #[test]
    fn serves_the_shared_page_and_directory_index() {
        let f = fixture("page", false);
        assert!(f.files.resolve("/companion/index.html").unwrap().ends_with("index.html"));
        assert!(f.files.resolve("/companion/").unwrap().ends_with("index.html"));
        assert!(f.files.resolve("/assets/companion-model/miku_v2.pmd").is_some());
    }

    #[test]
    fn refuses_paths_outside_the_root() {
        let f = fixture("escape", false);
        assert!(f.files.resolve("/../secret.txt").is_none());
        assert!(f.files.resolve("/companion/%2e%2e/%2e%2e/secret.txt").is_none());
        assert!(f.files.resolve("/companion/..%5C..%5Csecret.txt").is_none());
        assert!(f.files.resolve("/C:/Windows/win.ini").is_none());
        assert!(f.files.resolve("/companion/missing.js").is_none());
    }

    #[test]
    fn imported_tda_model_is_served_only_once_imported() {
        let without = fixture("no-tda", false);
        assert!(without.files.resolve("/assets/companion-model/tda/miku.pmx").is_none());

        let with = fixture("tda", true);
        let file = with.files.resolve("/assets/companion-model/tda/miku.pmx").unwrap();
        assert_eq!(fs::read_to_string(file).unwrap(), "tda");
        assert!(with.files.resolve("/assets/companion-model/tda/../../../../secret.txt").is_none());
    }

    #[test]
    fn layer_urls_carry_the_layer() {
        assert!(layer_url("background").as_str().ends_with("/companion/index.html?layer=background"));
        assert!(layer_url("character").as_str().ends_with("?layer=character"));
    }
}
