// JSON import from a URL for the recipe manager.
//
// This module is deliberately small and dependency-light: serde_json
// for parsing, and a plain TCP HTTP client for fetching. No HTTP
// crate, no async runtime, and no TLS: the QA route for this test
// app is the local test-data server (see test-data/README.md),
// which serves plain http:// on localhost, and this importer says
// so rather than pretending to support https://.
//
// The fetch runs on a worker thread (see main.rs, which spawns it
// the same way it spawns image decoding) and sends its result back
// over a channel, so neither the download nor the parse blocks the
// UI. The database inserts happen on the UI thread afterwards,
// using the same db::insert_recipe the Add form uses.
//
// Accepted document shapes (see test-data/README.md for fixtures
// for each one):
//   - a single recipe object: {"title": ..., ...}
//   - a bare array of recipe objects: [{...}, {...}]
//   - a collection object: {"recipes": [...]}
// A recipe's fields follow test-data/recipes.json: title,
// description, servings, image_path, notes, ingredients (amount,
// unit, name objects, in order), and steps (strings, in order).
// Missing description, notes, ingredients, or steps default to
// empty; missing image_path defaults to null; missing servings
// defaults to 0. A recipe with no usable title is an error, not
// a recipe with an empty title in the list.
use crate::{Ingredient, Recipe};
use serde::Deserialize;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

// The per-recipe shape in JSON. title is required (serde fails
// without it); everything else defaults, so a minimal recipe
// like {"title": "Toast"} parses instead of erroring.
#[derive(Deserialize)]
struct JsonIngredient {
    #[serde(default)]
    amount: String,
    #[serde(default)]
    unit: String,
    #[serde(default)]
    name: String,
}

#[derive(Deserialize)]
struct JsonRecipe {
    title: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    servings: i64,
    #[serde(default)]
    image_path: Option<String>,
    #[serde(default)]
    notes: String,
    #[serde(default)]
    ingredients: Vec<JsonIngredient>,
    #[serde(default)]
    steps: Vec<String>,
}

impl JsonRecipe {
    fn into_recipe(self) -> Result<Recipe, String> {
        if self.title.trim().is_empty() {
            return Err("Imported recipe is missing a title.".to_string());
        }
        Ok(Recipe {
            id: 0,
            title: self.title,
            description: self.description,
            servings: self.servings,
            image_path: self.image_path,
            ingredients: self
                .ingredients
                .into_iter()
                .map(|ingredient| Ingredient {
                    amount: ingredient.amount,
                    unit: ingredient.unit,
                    name: ingredient.name,
                })
                .collect(),
            steps: self.steps,
            notes: self.notes,
        })
    }
}

fn parse_one(value: serde_json::Value) -> Result<Recipe, String> {
    let recipe: JsonRecipe = serde_json::from_value(value)
        .map_err(|err| format!("Could not parse recipe JSON: {}", err))?;
    recipe.into_recipe()
}

// Parse a whole document in any of the three accepted shapes.
pub(crate) fn parse_recipes(text: &str) -> Result<Vec<Recipe>, String> {
    let value: serde_json::Value = serde_json::from_str(text)
        .map_err(|err| format!("Could not parse recipe JSON: {}", err))?;
    match value {
        serde_json::Value::Array(recipes) => recipes.into_iter().map(parse_one).collect(),
        serde_json::Value::Object(map) => {
            if let Some(recipes) = map.get("recipes") {
                match recipes {
                    serde_json::Value::Array(recipes) => {
                        recipes.clone().into_iter().map(parse_one).collect()
                    }
                    _ => Err("The \"recipes\" field must be an array of recipes.".to_string()),
                }
            } else if map.contains_key("title") {
                parse_one(serde_json::Value::Object(map)).map(|recipe| vec![recipe])
            } else {
                Err("JSON must be a single recipe, an array of recipes, \
                     or an object with a \"recipes\" array."
                    .to_string())
            }
        }
        _ => Err("JSON must be a single recipe, an array of recipes, \
             or an object with a \"recipes\" array."
            .to_string()),
    }
}

// --- HTTP fetching (http:// only) ---

struct HttpUrl {
    host: String,
    port: u16,
    path: String,
}

fn parse_http_url(url: &str) -> Result<HttpUrl, String> {
    if url.starts_with("https://") {
        return Err("HTTPS URLs are not supported by this importer; \
             use an http:// URL (for example, the local test server)."
            .to_string());
    }
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| "URL must start with http://.".to_string())?;
    let (host_port, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    if host_port.is_empty() {
        return Err("URL is missing a host.".to_string());
    }
    let (host, port) = match host_port.rsplit_once(':') {
        Some((host, port_text)) if !port_text.is_empty() => {
            let port: u16 = port_text
                .parse()
                .map_err(|_| format!("Invalid port in URL: {}.", port_text))?;
            (host.to_string(), port)
        }
        _ => (host_port.to_string(), 80),
    };
    if host.is_empty() {
        return Err("URL is missing a host.".to_string());
    }
    Ok(HttpUrl {
        host,
        port,
        path: path.to_string(),
    })
}

enum FetchOutcome {
    Body(String),
    Redirect(String),
}

// Decode a chunked transfer-encoding body: hex size lines (with
// optional ";extension" suffixes), data, CRLF, repeated, ending
// with a zero-size chunk and trailing headers up to a blank line.
fn decode_chunked(body: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut rest = body;
    loop {
        let line_end = rest
            .windows(2)
            .position(|window| window == b"\r\n")
            .ok_or_else(|| "Malformed chunked response.".to_string())?;
        let size_text = std::str::from_utf8(&rest[..line_end])
            .map_err(|_| "Malformed chunked response.".to_string())?;
        let size_text = size_text.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_text, 16)
            .map_err(|_| "Malformed chunked response.".to_string())?;
        rest = &rest[line_end + 2..];
        if size == 0 {
            break;
        }
        if rest.len() < size + 2 {
            return Err("Truncated chunked response.".to_string());
        }
        out.extend_from_slice(&rest[..size]);
        rest = &rest[size + 2..];
    }
    Ok(out)
}

fn fetch_once(url: &HttpUrl) -> Result<FetchOutcome, String> {
    // Try every resolved address in turn, not just the first one:
    // on this VM `localhost` resolves to ::1 first, but the local
    // test-data server binds 127.0.0.1 only, so taking only the
    // first address died with "Connection refused" while the
    // server was up. (Found while porting this importer to
    // rust-iced, which tries all addresses.)
    let addrs: Vec<_> = (url.host.as_str(), url.port)
        .to_socket_addrs()
        .map_err(|err| format!("Could not resolve {}: {}", url.host, err))?
        .collect();
    if addrs.is_empty() {
        return Err(format!("Could not resolve {}.", url.host));
    }
    let mut stream = None;
    let mut last_err = String::new();
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, Duration::from_secs(10)) {
            Ok(connected) => {
                stream = Some(connected);
                break;
            }
            Err(err) => last_err = err.to_string(),
        }
    }
    let mut stream = match stream {
        Some(stream) => stream,
        None => return Err(format!("Could not connect to {}: {}", url.host, last_err)),
    };
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .map_err(|err| err.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(30)))
        .map_err(|err| err.to_string())?;
    let host_header = if url.port == 80 {
        url.host.clone()
    } else {
        format!("{}:{}", url.host, url.port)
    };
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nUser-Agent: recipe-manager-test\r\nAccept: application/json\r\n\r\n",
        url.path, host_header
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|err| format!("Could not send request: {}", err))?;
    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .map_err(|err| format!("Could not read response: {}", err))?;
    let header_end = raw
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| "Response was not valid HTTP.".to_string())?;
    let headers_text = String::from_utf8_lossy(&raw[..header_end]);
    let mut lines = headers_text.lines();
    let status_line = lines.next().unwrap_or("");
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse().ok())
        .ok_or_else(|| "Response was not valid HTTP.".to_string())?;
    let mut location: Option<String> = None;
    let mut chunked = false;
    let mut content_length: Option<usize> = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            match name.trim().to_ascii_lowercase().as_str() {
                "location" => location = Some(value.trim().to_string()),
                "transfer-encoding" if value.to_ascii_lowercase().contains("chunked") => {
                    chunked = true;
                }
                "content-length" => {
                    content_length = value.trim().parse().ok();
                }
                _ => {}
            }
        }
    }
    if matches!(status, 301 | 302 | 303 | 307 | 308) {
        if let Some(location) = location {
            return Ok(FetchOutcome::Redirect(location));
        }
    }
    if status != 200 {
        return Err(format!(
            "Server returned HTTP {} for {}:{}.",
            status, url.host, url.port
        ));
    }
    let body_bytes = &raw[header_end + 4..];
    let body = if chunked {
        decode_chunked(body_bytes)?
    } else if let Some(length) = content_length {
        if body_bytes.len() < length {
            return Err("Response ended before the full body arrived.".to_string());
        }
        body_bytes[..length].to_vec()
    } else {
        body_bytes.to_vec()
    };
    String::from_utf8(body)
        .map_err(|_| "Response was not valid UTF-8.".to_string())
        .map(FetchOutcome::Body)
}

fn resolve_redirect(current: &HttpUrl, location: &str) -> Result<String, String> {
    if location.starts_with("http://") || location.starts_with("https://") {
        return Ok(location.to_string());
    }
    if let Some(path) = location.strip_prefix('/') {
        let host = if current.port == 80 {
            current.host.clone()
        } else {
            format!("{}:{}", current.host, current.port)
        };
        return Ok(format!("http://{}/{}", host, path));
    }
    // A relative path resolves against the current path's directory.
    let base = match current.path.rfind('/') {
        Some(index) => &current.path[..=index],
        None => "/",
    };
    let host = if current.port == 80 {
        current.host.clone()
    } else {
        format!("{}:{}", current.host, current.port)
    };
    Ok(format!("http://{}{}{}", host, base, location))
}

pub(crate) fn fetch_url(url: &str) -> Result<String, String> {
    let mut current = url.to_string();
    for _ in 0..4 {
        let parsed = parse_http_url(&current)?;
        match fetch_once(&parsed)? {
            FetchOutcome::Body(body) => return Ok(body),
            FetchOutcome::Redirect(location) => {
                current = resolve_redirect(&parsed, &location)?;
            }
        }
    }
    Err("Too many redirects.".to_string())
}

// Fetch a document and parse it. This is what the worker thread
// runs, so a slow server or a large document never blocks the UI.
pub(crate) fn fetch_and_parse(url: &str) -> Result<Vec<Recipe>, String> {
    let body = fetch_url(url)?;
    parse_recipes(&body)
}

// Import recipes from a raw file on disk: read the whole file as
// text and parse it with the same shapes and defaults as the URL
// importer (single object, bare array, or {"recipes": [...]}).
// This is deliberately UTF-8 only: JSON text is UTF-8 by
// definition, and detecting other encodings (UTF-16, Shift_JIS,
// Windows-1252, ...) is the separate text-encoding-import item,
// not this one. A non-UTF-8 file therefore errors here rather
// than importing garbled text.
pub(crate) fn import_from_file(path: &std::path::Path) -> Result<Vec<Recipe>, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|err| format!("Could not read file {}: {}", path.display(), err))?;
    parse_recipes(&text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    const SINGLE: &str = r#"{
        "title": "Mushroom Risotto",
        "description": "Creamy rice.",
        "servings": 4,
        "ingredients": [{"amount": "1", "unit": "lb", "name": "mushrooms"}],
        "steps": ["Cook it."]
    }"#;

    #[test]
    fn parse_single_recipe_object() {
        let recipes = parse_recipes(SINGLE).unwrap();
        assert_eq!(recipes.len(), 1);
        assert_eq!(recipes[0].title, "Mushroom Risotto");
        assert_eq!(recipes[0].servings, 4);
        assert_eq!(recipes[0].ingredients.len(), 1);
        assert_eq!(recipes[0].ingredients[0].name, "mushrooms");
        assert_eq!(recipes[0].steps, vec!["Cook it."]);
    }

    #[test]
    fn parse_bare_array() {
        let recipes = parse_recipes(&format!("[{}, {}]", SINGLE, SINGLE)).unwrap();
        assert_eq!(recipes.len(), 2);
    }

    #[test]
    fn parse_wrapped_collection() {
        let recipes = parse_recipes(&format!("{{\"recipes\": [{}]}}", SINGLE)).unwrap();
        assert_eq!(recipes.len(), 1);
        assert_eq!(recipes[0].title, "Mushroom Risotto");
    }

    #[test]
    fn parse_minimal_recipe_uses_defaults() {
        let recipes = parse_recipes(r#"{"title": "Toast"}"#).unwrap();
        assert_eq!(recipes.len(), 1);
        assert_eq!(recipes[0].title, "Toast");
        assert_eq!(recipes[0].description, "");
        assert_eq!(recipes[0].servings, 0);
        assert_eq!(recipes[0].image_path, None);
        assert!(recipes[0].ingredients.is_empty());
        assert!(recipes[0].steps.is_empty());
    }

    #[test]
    fn parse_empty_collection() {
        let recipes = parse_recipes(r#"{"recipes": []}"#).unwrap();
        assert!(recipes.is_empty());
    }

    #[test]
    fn parse_invalid_json_is_an_error() {
        assert!(parse_recipes("{ this is not json").is_err());
    }

    #[test]
    fn parse_object_without_recipes_or_title_is_an_error() {
        assert!(parse_recipes(r#"{"nope": 1}"#).is_err());
    }

    #[test]
    fn parse_recipe_without_title_is_an_error() {
        assert!(parse_recipes(r#"{"description": "No title here."}"#).is_err());
        assert!(parse_recipes(r#"{"title": "   "}"#).is_err());
    }

    #[test]
    fn parse_recipes_field_must_be_an_array() {
        assert!(parse_recipes(r#"{"recipes": {"title": "Toast"}}"#).is_err());
    }

    #[test]
    fn url_parsing_defaults_and_https_rejection() {
        let url = parse_http_url("http://localhost:8000/recipes.json").unwrap();
        assert_eq!(url.host, "localhost");
        assert_eq!(url.port, 8000);
        assert_eq!(url.path, "/recipes.json");
        let url = parse_http_url("http://example.com").unwrap();
        assert_eq!(url.port, 80);
        assert_eq!(url.path, "/");
        assert!(parse_http_url("https://example.com/recipes.json").is_err());
        assert!(parse_http_url("http:///recipes.json").is_err());
    }

    #[test]
    fn chunked_body_decodes() {
        let decoded = decode_chunked(b"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n").unwrap();
        assert_eq!(decoded, b"hello world");
    }

    // A one-shot local HTTP server: binds first (so the port is
    // known), then serves exactly one response in a thread.
    fn serve_once(response: &'static [u8]) -> (u16, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut request = [0u8; 4096];
                let _ = stream.read(&mut request);
                let _ = stream.write_all(response);
            }
        });
        (port, handle)
    }

    #[test]
    fn fetch_from_a_local_server() {
        let body = format!("{{\"recipes\": [{}]}}", SINGLE);
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        // Leak the response so the serving thread owns a 'static slice.
        let response: &'static [u8] = Box::leak(response.into_bytes().into_boxed_slice());
        let (port, handle) = serve_once(response);
        let recipes = fetch_and_parse(&format!("http://127.0.0.1:{}/recipes.json", port)).unwrap();
        assert_eq!(recipes.len(), 1);
        assert_eq!(recipes[0].title, "Mushroom Risotto");
        handle.join().unwrap();
    }

    #[test]
    fn fetch_via_localhost_reaches_ipv4_only_server() {
        // Regression test: `localhost` resolves to ::1 first on
        // this VM, but the server binds 127.0.0.1 only, so a
        // first-address-only connect fails with "Connection
        // refused" even though the server is up.
        let body = format!("{{\"recipes\": [{}]}}", SINGLE);
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let response: &'static [u8] = Box::leak(response.into_bytes().into_boxed_slice());
        let (port, handle) = serve_once(response);
        let recipes = fetch_and_parse(&format!("http://localhost:{}/recipes.json", port)).unwrap();
        assert_eq!(recipes.len(), 1);
        assert_eq!(recipes[0].title, "Mushroom Risotto");
        handle.join().unwrap();
    }

    #[test]
    fn fetch_non_200_is_an_error() {
        let response: &'static [u8] =
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot found";
        let (port, handle) = serve_once(response);
        let err = fetch_url(&format!("http://127.0.0.1:{}/missing.json", port)).unwrap_err();
        assert!(err.contains("404"), "error was: {}", err);
        handle.join().unwrap();
    }

    // Write `contents` to a fresh temp file and return its path.
    // The caller removes it afterwards; the name includes the
    // process id and the test's tag so parallel tests never share
    // a file.
    fn write_temp_file(tag: &str, contents: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "rust-egui-import-test-{}-{}.json",
            std::process::id(),
            tag
        ));
        std::fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn import_from_file_single_recipe() {
        let path = write_temp_file("single", SINGLE);
        let recipes = import_from_file(&path).unwrap();
        assert_eq!(recipes.len(), 1);
        assert_eq!(recipes[0].title, "Mushroom Risotto");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn import_from_file_collection() {
        let body = format!("{{\"recipes\": [{}, {}]}}", SINGLE, SINGLE);
        let path = write_temp_file("collection", &body);
        let recipes = import_from_file(&path).unwrap();
        assert_eq!(recipes.len(), 2);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn import_from_file_bare_array_and_empty() {
        let path = write_temp_file("array", &format!("[{}]", SINGLE));
        assert_eq!(import_from_file(&path).unwrap().len(), 1);
        let _ = std::fs::remove_file(&path);
        let path = write_temp_file("empty", "{\"recipes\": []}");
        assert_eq!(import_from_file(&path).unwrap().len(), 0);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn import_from_file_invalid_and_missing() {
        let path = write_temp_file("invalid", "{ this is not json");
        let Err(err) = import_from_file(&path) else {
            panic!("expected an import error");
        };
        assert!(
            err.contains("Could not parse recipe JSON"),
            "error was: {}",
            err
        );
        let _ = std::fs::remove_file(&path);
        let missing = std::env::temp_dir().join(format!(
            "rust-egui-import-test-{}-missing.json",
            std::process::id()
        ));
        let Err(err) = import_from_file(&missing) else {
            panic!("expected a missing-file error");
        };
        assert!(err.contains("Could not read file"), "error was: {}", err);
    }

    #[test]
    fn import_from_file_shared_fixtures() {
        // The repo's shared test-data fixtures, read from disk
        // rather than from inline JSON, so the file path itself
        // is exercised end to end.
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("test-data");
        let recipes = import_from_file(&root.join("recipe-single.json")).unwrap();
        assert_eq!(recipes.len(), 1);
        assert_eq!(recipes[0].title, "Mushroom Risotto");
        let recipes = import_from_file(&root.join("recipes-array.json")).unwrap();
        assert_eq!(
            recipes.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(),
            vec!["Pancakes", "Greek Salad"]
        );
        let recipes = import_from_file(&root.join("recipes.json")).unwrap();
        assert_eq!(
            recipes.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(),
            vec!["Fried Chicken", "Lasagna", "Butter Tarts"]
        );
        let recipes = import_from_file(&root.join("recipes-empty.json")).unwrap();
        assert_eq!(recipes.len(), 0);
        let Err(err) = import_from_file(&root.join("invalid.json")) else {
            panic!("expected an import error");
        };
        assert!(
            err.contains("Could not parse recipe JSON"),
            "error was: {}",
            err
        );
    }
}
