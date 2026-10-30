const std = @import("std");
const db = @import("db.zig");

// Network JSON import from a URL, matching rust-egui's
// json_import.rs behaviour exactly, plus raw-file import
// (importFromFile / startFileImport) matching rust-egui's
// import_from_file: the same parser, shapes, and defaults,
// read on the same worker-thread + poll path, UTF-8 only.
//
// Accepted document shapes (see test-data/README.md for a
// fixture for each one):
//   - a single recipe object: {"title": ..., ...}
//   - a bare array of recipe objects: [{...}, {...}]
//   - a collection object: {"recipes": [...]}
// A recipe's fields follow test-data/recipes.json: title,
// description, servings, image_path, notes, ingredients
// (amount, unit, name objects, in order), and steps
// (strings, in order). Missing description, notes,
// ingredients, or steps default to empty; missing
// image_path defaults to null ("" in this stack's Recipe,
// which stores a null image_path as an empty string);
// missing servings defaults to 0. A recipe with no usable
// title is an error, not a recipe with an empty title in
// the list. Extra fields are ignored.
//
// Fetching is a plain std TCP http:// client: no HTTP
// crate, no new dependency, no TLS. https:// is rejected
// with a clear message, exactly as rust-egui rejects it.
// The local test-data server (test-data/run_server.sh,
// plain http:// on localhost) is the QA route, so http://
// is all this importer needs. Handles chunked bodies and
// up to 3 redirects; non-200 is an error including the
// status code.
//
// Threading mirrors imageloader.zig: fetching and parsing
// run on a worker thread, so a slow server never blocks
// the UI, and the main thread polls once per frame.
// Unlike imageloader, the worker never touches DVUI or
// the database — it only produces recipes — and the main
// thread (pollImport) inserts them through db.zig's
// insertRecipe, one at a time, exactly as rust-egui's
// poll_imports does: a failed insert stops the import but
// leaves recipes already inserted in place, and nothing
// is selected on failure. The first imported recipe is
// selected on success, as in rust-egui.
//
// Zig 0.17 notes: std.fs is gone (std.Io instead), and
// networking moved from std.net to std.Io.net — but
// this importer does NOT use Io.net for socket I/O, for
// a found reason, not a preference. Io.net reads work on
// the main thread (verified against the real test-data
// server: 5601 bytes read), but a read issued from a
// spawned worker thread never returns, even with data
// waiting — verified with small standalone programs:
// main-thread Reader reads work, worker-thread Reader
// reads hang, worker-thread posix.read of data already
// sent works, and a worker-thread client reading from a
// main-thread Io.net Writer never sees the reply while
// the same exchange over libc send/recv works. Since
// this importer must read on a worker thread (the UI
// must never block), socket I/O here uses Linux syscalls
// directly (std.os.linux: socket/connect/sendto/recvfrom
// and, for the tests, bind/listen/accept/getsockname).
// That makes this file's socket layer Linux-only — the
// stack is Linux-first (Linux and Fedora install
// scripts; no macOS/Windows build yet), and a portable
// build would switch back to Io.net once its
// worker-thread reads work. DNS is the one exception:
// resolving a hostname still goes through Io.net
// (IpAddress.resolve), which works from a worker thread;
// dotted-quad literals and "localhost" short-circuit
// before it and never touch Io at all.
// Parsing uses std.json.Value and walks the tree by hand
// rather than deserializing into a struct, because the
// three accepted top-level shapes need a shape dispatch
// first, and because a missing title must be a distinct
// error, not a parse failure with no message.

// --- Parsing ---

pub const ParseError = error{
    InvalidJson,
    NotARecipe,
    RecipesNotArray,
    InvalidRecipe,
    MissingTitle,
    InvalidServings,
};

fn getStringField(obj: std.json.ObjectMap, name: []const u8, default: []const u8) ParseError![]const u8 {
    const value = obj.get(name) orelse return default;
    return switch (value) {
        .string => |s| s,
        else => error.InvalidRecipe,
    };
}

fn valueToRecipe(alloc: std.mem.Allocator, value: std.json.Value) !db.Recipe {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidRecipe,
    };
    const title_raw = obj.get("title") orelse return error.MissingTitle;
    const title = switch (title_raw) {
        .string => |s| s,
        else => return error.InvalidRecipe,
    };
    if (std.mem.trim(u8, title, " \t\r\n").len == 0) return error.MissingTitle;

    const description = try getStringField(obj, "description", "");
    const notes = try getStringField(obj, "notes", "");
    const image_path = switch (obj.get("image_path") orelse .null) {
        .null => "",
        .string => |s| s,
        else => return error.InvalidRecipe,
    };
    var servings: u32 = 0;
    if (obj.get("servings")) |servings_value| {
        const n = switch (servings_value) {
            .integer => |i| i,
            else => return error.InvalidServings,
        };
        if (n < 0 or n > std.math.maxInt(u32)) return error.InvalidServings;
        servings = @intCast(n);
    }

    // The working lists hold strings borrowed from the parsed
    // document; defer (not errdefer) frees their slices on
    // every path, after the return value's strings have been
    // duplicated out of them.
    var ingredients: std.ArrayList(db.Ingredient) = .empty;
    defer ingredients.deinit(alloc);
    if (obj.get("ingredients")) |ings| {
        const arr = switch (ings) {
            .array => |a| a,
            else => return error.InvalidRecipe,
        };
        for (arr.items) |item| {
            const ing_obj = switch (item) {
                .object => |o| o,
                else => return error.InvalidRecipe,
            };
            try ingredients.append(alloc, .{
                .amount = try getStringField(ing_obj, "amount", ""),
                .unit = try getStringField(ing_obj, "unit", ""),
                .name = try getStringField(ing_obj, "name", ""),
            });
        }
    }

    var steps: std.ArrayList([]const u8) = .empty;
    defer steps.deinit(alloc);
    if (obj.get("steps")) |steps_value| {
        const arr = switch (steps_value) {
            .array => |a| a,
            else => return error.InvalidRecipe,
        };
        for (arr.items) |item| {
            const step = switch (item) {
                .string => |s| s,
                else => return error.InvalidRecipe,
            };
            try steps.append(alloc, step);
        }
    }

    // Duplicate every string out of the parsed document:
    // the caller frees the parsed value, and the recipes
    // must outlive it (the worker thread hands them to the
    // main thread, which inserts them into SQLite).
    return .{
        .title = try alloc.dupe(u8, title),
        .description = try alloc.dupe(u8, description),
        .servings = servings,
        .image_path = try alloc.dupe(u8, image_path),
        .ingredients = try dupeIngredients(alloc, ingredients.items),
        .steps = try dupeSteps(alloc, steps.items),
        .notes = try alloc.dupe(u8, notes),
    };
}

fn dupeIngredients(alloc: std.mem.Allocator, ings: []const db.Ingredient) ![]db.Ingredient {
    const out = try alloc.alloc(db.Ingredient, ings.len);
    for (ings, 0..) |ing, i| {
        out[i] = .{
            .amount = try alloc.dupe(u8, ing.amount),
            .unit = try alloc.dupe(u8, ing.unit),
            .name = try alloc.dupe(u8, ing.name),
        };
    }
    return out;
}

fn dupeSteps(alloc: std.mem.Allocator, steps: []const []const u8) ![][]const u8 {
    const out = try alloc.alloc([]const u8, steps.len);
    for (steps, 0..) |step, i| {
        out[i] = try alloc.dupe(u8, step);
    }
    return out;
}

/// Free one recipe's strings and child slices (not the
/// recipe struct itself).
fn freeRecipe(alloc: std.mem.Allocator, recipe: db.Recipe) void {
    alloc.free(recipe.title);
    alloc.free(recipe.description);
    alloc.free(recipe.image_path);
    for (recipe.ingredients) |ing| {
        alloc.free(ing.amount);
        alloc.free(ing.unit);
        alloc.free(ing.name);
    }
    alloc.free(recipe.ingredients);
    for (recipe.steps) |step| alloc.free(step);
    alloc.free(recipe.steps);
    alloc.free(recipe.notes);
}

/// Free recipes produced by parseRecipes/fetchAndParse,
/// including every string and child slice.
pub fn freeRecipes(alloc: std.mem.Allocator, recipes: []db.Recipe) void {
    for (recipes) |recipe| freeRecipe(alloc, recipe);
    alloc.free(recipes);
}

/// Parse a whole document in any of the three accepted
/// shapes. Returned recipes are owned by the caller (see
/// freeRecipes); the parsed JSON itself is freed here.
pub fn parseRecipes(alloc: std.mem.Allocator, text: []const u8) ![]db.Recipe {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();
    var recipes: std.ArrayList(db.Recipe) = .empty;
    errdefer {
        // Free each already-built recipe, then the list
        // slice itself (freeRecipes would free the slice
        // too, and deinit would then free it again).
        for (recipes.items) |recipe| freeRecipe(alloc, recipe);
        recipes.deinit(alloc);
    }
    switch (parsed.value) {
        .array => |arr| {
            for (arr.items) |item| {
                try recipes.append(alloc, try valueToRecipe(alloc, item));
            }
        },
        .object => |obj| {
            if (obj.get("recipes")) |collection| {
                const arr = switch (collection) {
                    .array => |a| a,
                    else => return error.RecipesNotArray,
                };
                for (arr.items) |item| {
                    try recipes.append(alloc, try valueToRecipe(alloc, item));
                }
            } else if (obj.contains("title")) {
                try recipes.append(alloc, try valueToRecipe(alloc, parsed.value));
            } else {
                return error.NotARecipe;
            }
        },
        else => return error.NotARecipe,
    }
    return recipes.toOwnedSlice(alloc);
}

// --- HTTP fetching (http:// only) ---

pub const FetchError = error{
    HttpsNotSupported,
    InvalidUrl,
    MissingHost,
    InvalidPort,
    DnsFailed,
    ConnectFailed,
    SendFailed,
    ReadFailed,
    InvalidResponse,
    MalformedChunked,
    TruncatedResponse,
    NotUtf8,
    HttpStatus,
    TooManyRedirects,
};

/// Status code of the last non-200 response, set when
/// fetchOnce returns error.HttpStatus, so the UI message
/// can name the code (rust-egui's error includes it).
pub var last_http_status: u16 = 0;

const HttpUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseHttpUrl(url: []const u8) FetchError!HttpUrl {
    const rest = std.mem.trim(u8, url, " \t\r\n");
    if (std.mem.startsWith(u8, rest, "https://")) return error.HttpsNotSupported;
    const after_scheme = if (std.mem.startsWith(u8, rest, "http://"))
        rest["http://".len..]
    else
        return error.InvalidUrl;
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/');
    const host_port = if (slash) |i| after_scheme[0..i] else after_scheme;
    const path = if (slash) |i| after_scheme[i..] else "/";
    if (host_port.len == 0) return error.MissingHost;
    var host = host_port;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        const port_text = host_port[colon + 1 ..];
        if (port_text.len > 0) {
            port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
            host = host_port[0..colon];
        }
    }
    if (host.len == 0) return error.MissingHost;
    return .{ .host = host, .port = port, .path = path };
}

const FetchOutcome = union(enum) {
    body: []const u8,
    redirect: []const u8,
};

// Decode a chunked transfer-encoding body: hex size lines
// (with optional ";extension" suffixes), data, CRLF,
// repeated, ending with a zero-size chunk. Trailing
// headers after the final chunk are ignored, as in
// rust-egui (the whole response is already in memory).
fn decodeChunked(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = body;
    while (true) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.MalformedChunked;
        var size_text = rest[0..line_end];
        if (std.mem.indexOfScalar(u8, size_text, ';')) |semi| size_text = size_text[0..semi];
        size_text = std.mem.trim(u8, size_text, " \t");
        const size = std.fmt.parseInt(usize, size_text, 16) catch return error.MalformedChunked;
        rest = rest[line_end + 2 ..];
        if (size == 0) break;
        if (rest.len < size + 2) return error.TruncatedResponse;
        try out.appendSlice(alloc, rest[0..size]);
        rest = rest[size + 2 ..];
    }
    return out.toOwnedSlice(alloc);
}

// --- Raw Linux socket calls (see the module header
// for why Io.net is not used for socket I/O) ---
//
// std.os.linux syscalls return usize: a small value is
// the result (fd, bytes), a huge value is -errno. This
// helper turns that into an error, retrying on EINTR at
// the call sites that loop.
const SyscallError = error{ SyscallFailed, Interrupted };

fn syscallResult(rc: usize) SyscallError!usize {
    if (@as(isize, @bitCast(rc)) < 0) {
        return switch (std.posix.errno(rc)) {
            .INTR => error.Interrupted,
            else => error.SyscallFailed,
        };
    }
    return rc;
}

fn ipv4Sockaddr(bytes: [4]u8, port: u16) std.os.linux.sockaddr.in {
    // sockaddr_in stores port and address in network
    // byte order; nativeToBig puts them there on a
    // little-endian machine and is a no-op on a
    // big-endian one.
    const addr: u32 = (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | bytes[3];
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, addr),
    };
}

/// Resolve a host to IPv4 bytes: dotted quads parse
/// directly, "localhost" is loopback, anything else goes
// through Io.net's resolver (which works from a worker
// thread) and must come back IPv4 — IPv6 is not handled
// by the raw-socket client below, so it is a DNS failure
// here, documented as a gap in the README.
fn resolveHost(host: []const u8, port: u16, io: std.Io) FetchError![4]u8 {
    if (std.Io.net.IpAddress.parseIp4(host, port)) |addr| {
        return switch (addr) {
            .ip4 => |a| a.bytes,
            else => error.DnsFailed,
        };
    } else |_| {}
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return .{ 127, 0, 0, 1 };
    const resolved = std.Io.net.IpAddress.resolve(io, host, port) catch return error.DnsFailed;
    return switch (resolved) {
        .ip4 => |a| a.bytes,
        else => error.DnsFailed,
    };
}

fn connectTcp(bytes: [4]u8, port: u16) FetchError!i32 {
    const linux = std.os.linux;
    const fd = while (true) {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        const val = syscallResult(rc) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return error.ConnectFailed,
        };
        break @as(i32, @intCast(val));
    };
    errdefer _ = linux.close(fd);
    var addr = ipv4Sockaddr(bytes, port);
    while (true) {
        const rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        _ = syscallResult(rc) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return error.ConnectFailed,
        };
        break;
    }
    return fd;
}

fn sendAll(fd: i32, data: []const u8) FetchError!void {
    const linux = std.os.linux;
    var sent: usize = 0;
    while (sent < data.len) {
        const rc = linux.sendto(fd, data.ptr + sent, data.len - sent, 0, null, 0);
        const n = syscallResult(rc) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return error.SendFailed,
        };
        if (n == 0) return error.SendFailed;
        sent += n;
    }
}

fn fetchOnce(alloc: std.mem.Allocator, url: HttpUrl, io: std.Io) !FetchOutcome {
    // Timeouts: unlike rust-egui's 10s connect / 30s read
    // timeouts, this client uses blocking sockets with no
    // timeouts set (setsockopt timeout constants vary by
    // architecture in this release's std, and the Io.net
    // timeout path panics — see the module header). So a
    // dead or stalled server blocks this worker thread —
    // never the UI, which only polls the slot — until the
    // OS times the operation out. No timeout is faked.
    const ip = try resolveHost(url.host, url.port, io);
    const fd = try connectTcp(ip, url.port);
    defer _ = std.os.linux.close(fd);
    var host_header_buf: [512]u8 = undefined;
    const host_header = if (url.port == 80)
        url.host
    else
        std.fmt.bufPrint(&host_header_buf, "{s}:{d}", .{ url.host, url.port }) catch url.host;
    const request = std.fmt.allocPrint(
        alloc,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\nUser-Agent: recipe-manager-test\r\nAccept: application/json\r\n\r\n",
        .{ url.path, host_header },
    ) catch return error.SendFailed;
    defer alloc.free(request);
    try sendAll(fd, request);

    // defer, not errdefer: every body below is an owned
    // copy (chunked decode or dupe), never an alias of
    // raw, so raw is freed on every path including success.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    var chunk_buf: [8192]u8 = undefined;
    while (true) {
        const rc = std.os.linux.recvfrom(fd, &chunk_buf, chunk_buf.len, 0, null, null);
        const n = syscallResult(rc) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) break;
        try raw.appendSlice(alloc, chunk_buf[0..n]);
    }
    const header_end = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return error.InvalidResponse;
    const headers_text = raw.items[0..header_end];
    var lines = std.mem.splitScalar(u8, headers_text, '\n');
    const status_line = lines.next() orelse return error.InvalidResponse;
    // "HTTP/1.1 200 OK": the status is the second token.
    var tokens = std.mem.tokenizeScalar(u8, std.mem.trim(u8, status_line, " \r"), ' ');
    _ = tokens.next();
    const code_text = tokens.next() orelse return error.InvalidResponse;
    const status = std.fmt.parseInt(u16, code_text, 10) catch return error.InvalidResponse;
    var location: ?[]const u8 = null;
    var chunked = false;
    var content_length: ?usize = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon], " ");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "location")) {
            location = value;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.findIgnoreCase(value, "chunked") != null) chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    if (status == 301 or status == 302 or status == 303 or status == 307 or status == 308) {
        // Duplicate: location slices into raw, which the
        // defer above frees on return; the caller frees
        // this copy after resolving it.
        if (location) |loc| return .{ .redirect = try alloc.dupe(u8, loc) };
    }
    if (status != 200) {
        last_http_status = status;
        return error.HttpStatus;
    }
    const body_bytes = raw.items[header_end + 4 ..];
    var body: []u8 = undefined;
    if (chunked) {
        body = try decodeChunked(alloc, body_bytes);
    } else if (content_length) |length| {
        if (body_bytes.len < length) return error.TruncatedResponse;
        body = try alloc.dupe(u8, body_bytes[0..length]);
    } else {
        body = try alloc.dupe(u8, body_bytes);
    }
    if (!std.unicode.utf8ValidateSlice(body)) {
        alloc.free(body);
        return error.NotUtf8;
    }
    return .{ .body = body };
}

fn resolveRedirect(alloc: std.mem.Allocator, current: HttpUrl, location: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        return alloc.dupe(u8, location);
    }
    var host_buf: [512]u8 = undefined;
    const host = if (current.port == 80)
        current.host
    else
        std.fmt.bufPrint(&host_buf, "{s}:{d}", .{ current.host, current.port }) catch current.host;
    if (std.mem.startsWith(u8, location, "/")) {
        return std.fmt.allocPrint(alloc, "http://{s}{s}", .{ host, location });
    }
    // A relative path resolves against the current path's directory.
    const base = if (std.mem.lastIndexOfScalar(u8, current.path, '/')) |i|
        current.path[0 .. i + 1]
    else
        "/";
    return std.fmt.allocPrint(alloc, "http://{s}{s}{s}", .{ host, base, location });
}

/// Fetch a URL's body, following up to 3 redirects (4
/// attempts total, as in rust-egui). The returned body is
/// owned by the caller.
pub fn fetchUrl(alloc: std.mem.Allocator, url: []const u8, io: std.Io) ![]const u8 {
    var current = try alloc.dupe(u8, url);
    // errdefer, not defer: the body path frees current
    // itself before returning, and the redirect path frees
    // the old URL when it replaces it, so only error paths
    // still own current here.
    errdefer alloc.free(current);
    for (0..4) |_| {
        const parsed = try parseHttpUrl(current);
        switch (try fetchOnce(alloc, parsed, io)) {
            .body => |body| {
                alloc.free(current);
                return body;
            },
            .redirect => |location| {
                const next = resolveRedirect(alloc, parsed, location) catch |e| {
                    alloc.free(location);
                    return e;
                };
                alloc.free(location);
                alloc.free(current);
                current = next;
            },
        }
    }
    // No manual free here: the errdefer above frees
    // current on this error return (a manual free would
    // double-free).
    return error.TooManyRedirects;
}

/// Fetch a document and parse it. This is what the worker
/// thread runs, so a slow server or a large document never
/// blocks the UI.
pub fn fetchAndParse(alloc: std.mem.Allocator, url: []const u8, io: std.Io) ![]db.Recipe {
    const body = try fetchUrl(alloc, url, io);
    defer alloc.free(body);
    return parseRecipes(alloc, body);
}

// --- Raw-file import (matching rust-egui's
// import_from_file) ---

/// Import recipes from a raw file on disk: read the whole
/// file as text and parse it with the same shapes and
/// defaults as the URL importer (single object, bare
/// array, or {"recipes": [...]}). Deliberately UTF-8
/// only: JSON text is UTF-8 by definition, and detecting
/// other encodings (UTF-16, Shift_JIS, Windows-1252, ...)
/// is the separate text-encoding-import item, not this
/// one. A non-UTF-8 file therefore errors here rather
/// than importing garbled text. The returned recipes are
/// owned by the caller (see freeRecipes). Read errors
/// propagate as the underlying file error (FileNotFound,
/// AccessDenied, ...); formatFileError turns those into
/// rust-egui's "Could not read file {path}: ..." style.
pub fn importFromFile(alloc: std.mem.Allocator, path: []const u8, io: std.Io) ![]db.Recipe {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30));
    defer alloc.free(text);
    if (!std.unicode.utf8ValidateSlice(text)) return error.FileNotUtf8;
    return parseRecipes(alloc, text);
}

/// A one-line UI message for a file-import error, in
/// rust-egui's style ("Could not read file {path}: …",
/// "Could not parse recipe JSON: …"). Parse errors reuse
/// formatError; a non-UTF-8 file gets its own message;
/// anything else from the read step is a read failure
/// naming the underlying error. OutOfMemory keeps
/// formatError's generic message rather than posing as a
/// read failure.
pub fn formatFileError(alloc: std.mem.Allocator, path: []const u8, err: anyerror) ![]u8 {
    return switch (err) {
        error.InvalidJson,
        error.NotARecipe,
        error.RecipesNotArray,
        error.InvalidRecipe,
        error.MissingTitle,
        error.InvalidServings,
        error.OutOfMemory,
        => formatError(alloc, err),
        error.FileNotUtf8 => alloc.dupe(u8, "File was not valid UTF-8."),
        else => std.fmt.allocPrint(alloc, "Could not read file {s}: {s}.", .{ path, @errorName(err) }),
    };
}

/// A one-line UI message for an import error, in
/// rust-egui's style ("Could not parse recipe JSON: …",
/// "Server returned HTTP 404.", …). The message is
/// allocated from `alloc`.
pub fn formatError(alloc: std.mem.Allocator, err: anyerror) ![]u8 {
    return switch (err) {
        error.InvalidJson => alloc.dupe(u8, "Could not parse recipe JSON."),
        error.NotARecipe => alloc.dupe(u8, "JSON must be a single recipe, an array of recipes, or an object with a \"recipes\" array."),
        error.RecipesNotArray => alloc.dupe(u8, "The \"recipes\" field must be an array of recipes."),
        error.InvalidRecipe => alloc.dupe(u8, "Could not parse recipe JSON: invalid recipe."),
        error.MissingTitle => alloc.dupe(u8, "Imported recipe is missing a title."),
        error.InvalidServings => alloc.dupe(u8, "Could not parse recipe JSON: invalid servings."),
        error.HttpsNotSupported => alloc.dupe(u8, "HTTPS URLs are not supported by this importer; use an http:// URL (for example, the local test server)."),
        error.InvalidUrl => alloc.dupe(u8, "URL must start with http://."),
        error.MissingHost => alloc.dupe(u8, "URL is missing a host."),
        error.InvalidPort => alloc.dupe(u8, "Invalid port in URL."),
        error.ConnectFailed => alloc.dupe(u8, "Could not connect to the server."),
        error.DnsFailed => alloc.dupe(u8, "Could not resolve the server."),
        error.SendFailed => alloc.dupe(u8, "Could not send request."),
        error.ReadFailed => alloc.dupe(u8, "Could not read response."),
        error.InvalidResponse => alloc.dupe(u8, "Response was not valid HTTP."),
        error.MalformedChunked => alloc.dupe(u8, "Malformed chunked response."),
        error.TruncatedResponse => alloc.dupe(u8, "Response ended before the full body arrived."),
        error.NotUtf8 => alloc.dupe(u8, "Response was not valid UTF-8."),
        error.HttpStatus => std.fmt.allocPrint(alloc, "Server returned HTTP {d}.", .{last_http_status}),
        error.TooManyRedirects => alloc.dupe(u8, "Too many redirects."),
        else => std.fmt.allocPrint(alloc, "Import failed: {s}.", .{@errorName(err)}),
    };
}

// --- Worker thread + main-thread poll ---

pub const Outcome = union(enum) {
    imported: struct { count: usize, first_id: i64 },
    failed: []const u8,
};

const Slot = struct {
    mutex: std.Thread.Mutex = .{},
    done: bool = false,
    err: ?anyerror = null,
    // Preformatted failure message (in msg_arena), set by
    // the file worker so the read failure can name the
    // file path, as rust-egui's message does; null for
    // URL imports, where pollImport formats from err.
    err_msg: ?[]const u8 = null,
    recipes: []db.Recipe = &.{},
    arena: std.heap.ArenaAllocator,
};

var slot: ?*Slot = null;

// Module-lifetime arena for outcome messages handed to
// main: pollImport returns a message slice, and main
// formats it into its own buffer in the same frame, but
// the slice must stay valid until then — so it lives
// here, not in the worker arena that pollImport frees.
var msg_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const msg_alloc = msg_arena.allocator();

fn importWorker(url: []const u8, s: *Slot) void {
    // The worker's Io: Threaded, from the page allocator,
    // created on this thread. It is only used for DNS
    // fallback in resolveHost (dotted quads and
    // "localhost" never touch it); socket I/O is raw
    // syscalls, which need no Io at all.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const arena_alloc = s.arena.allocator();
    const recipes = fetchAndParse(arena_alloc, url, io) catch |err| {
        s.mutex.lock();
        s.err = err;
        s.done = true;
        s.mutex.unlock();
        return;
    };
    s.mutex.lock();
    s.recipes = recipes;
    s.done = true;
    s.mutex.unlock();
}

/// Start importing from `url` on a worker thread, unless
/// an import is already running (a second click while
/// importing is ignored, as the UI shows a spinner instead
/// of the button). The URL is copied: the caller's slice
/// only needs to live for this call.
pub fn startImport(url: []const u8) void {
    if (slot != null) return;
    const page = std.heap.page_allocator;
    const s = page.create(Slot) catch return;
    s.* = .{ .arena = std.heap.ArenaAllocator.init(page) };
    const url_copy = s.arena.allocator().dupe(u8, std.mem.trim(u8, url, " \t\r\n")) catch {
        page.destroy(s);
        return;
    };
    slot = s;
    const thread = std.Thread.spawn(.{}, importWorker, .{ url_copy, s }) catch {
        slot = null;
        s.arena.deinit();
        page.destroy(s);
        return;
    };
    thread.detach();
}

fn importFileWorker(path: []const u8, s: *Slot) void {
    // Same worker-thread pattern as importWorker: the
    // file is read and parsed here, never on the UI
    // thread, and the main thread polls the slot. The
    // Threaded Io is created on this thread, as in
    // importWorker; file reads go through it (unlike
    // socket reads, file reads have no worker-thread
    // hang — imageloader.zig already reads files this
    // way on its worker thread).
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const arena_alloc = s.arena.allocator();
    const recipes = importFromFile(arena_alloc, path, io) catch |err| {
        const msg = formatFileError(msg_alloc, path, err) catch "Import failed.";
        s.mutex.lock();
        s.err = err;
        s.err_msg = msg;
        s.done = true;
        s.mutex.unlock();
        return;
    };
    s.mutex.lock();
    s.recipes = recipes;
    s.done = true;
    s.mutex.unlock();
}

/// Start importing from a file on a worker thread, with
/// the same already-running guard and the same poll path
/// as startImport. The path is copied: the caller's
/// slice only needs to live for this call.
pub fn startFileImport(path: []const u8) void {
    if (slot != null) return;
    const page = std.heap.page_allocator;
    const s = page.create(Slot) catch return;
    s.* = .{ .arena = std.heap.ArenaAllocator.init(page) };
    const path_copy = s.arena.allocator().dupe(u8, std.mem.trim(u8, path, " \t\r\n")) catch {
        page.destroy(s);
        return;
    };
    slot = s;
    const thread = std.Thread.spawn(.{}, importFileWorker, .{ path_copy, s }) catch {
        slot = null;
        s.arena.deinit();
        page.destroy(s);
        return;
    };
    thread.detach();
}

/// True while an import worker is running.
pub fn isImporting() bool {
    return slot != null;
}

/// Collect a finished import, if any, without blocking.
/// Returns null while the worker is still running or when
/// no import is in flight. On success the recipes are
/// inserted through db.zig (on this, the main, thread)
/// and the database reloaded; the outcome carries the
/// count and the first imported id for main to select.
/// On failure nothing is selected. The worker slot and
/// its arena are freed here, after the outcome message
/// has been copied into the module arena.
pub fn pollImport() ?Outcome {
    const s = slot orelse return null;
    s.mutex.lock();
    const done = s.done;
    const err = s.err;
    const err_msg = s.err_msg;
    const recipes = s.recipes;
    s.mutex.unlock();
    if (!done) return null;
    slot = null;
    defer {
        s.arena.deinit();
        std.heap.page_allocator.destroy(s);
    }
    if (err) |e| {
        const msg = if (err_msg) |m|
            m
        else
            formatError(msg_alloc, e) catch "Import failed.";
        return .{ .failed = msg };
    }
    var count: usize = 0;
    var first_id: i64 = 0;
    for (recipes) |recipe| {
        const id = db.insertRecipe(recipe) catch |insert_err| {
            // Reload anyway, so recipes already inserted
            // before the failure show up in the list.
            db.reload() catch {};
            const msg = std.fmt.allocPrint(
                msg_alloc,
                "Could not insert imported recipe: {s}.",
                .{@errorName(insert_err)},
            ) catch "Could not insert imported recipe.";
            return .{ .failed = msg };
        };
        if (count == 0) first_id = id;
        count += 1;
    }
    db.reload() catch |reload_err| {
        const msg = std.fmt.allocPrint(
            msg_alloc,
            "Could not reload recipes: {s}.",
            .{@errorName(reload_err)},
        ) catch "Could not reload recipes.";
        return .{ .failed = msg };
    };
    return .{ .imported = .{ .count = count, .first_id = first_id } };
}

// --- Tests ---

const test_alloc = std.testing.allocator;

const single_json =
    \\{
    \\  "title": "Mushroom Risotto",
    \\  "description": "Creamy rice.",
    \\  "servings": 4,
    \\  "ingredients": [{"amount": "1", "unit": "lb", "name": "mushrooms"}],
    \\  "steps": ["Cook it."]
    \\}
;

test "parse single recipe object" {
    const recipes = try parseRecipes(test_alloc, single_json);
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 1), recipes.len);
    try std.testing.expectEqualStrings("Mushroom Risotto", recipes[0].title);
    try std.testing.expectEqual(@as(u32, 4), recipes[0].servings);
    try std.testing.expectEqual(@as(usize, 1), recipes[0].ingredients.len);
    try std.testing.expectEqualStrings("mushrooms", recipes[0].ingredients[0].name);
    try std.testing.expectEqual(@as(usize, 1), recipes[0].steps.len);
    try std.testing.expectEqualStrings("Cook it.", recipes[0].steps[0]);
}

test "parse bare array" {
    const text = try std.fmt.allocPrint(test_alloc, "[{s}, {s}]", .{ single_json, single_json });
    defer test_alloc.free(text);
    const recipes = try parseRecipes(test_alloc, text);
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 2), recipes.len);
}

test "parse wrapped collection" {
    const text = try std.fmt.allocPrint(test_alloc, "{{\"recipes\": [{s}]}}", .{single_json});
    defer test_alloc.free(text);
    const recipes = try parseRecipes(test_alloc, text);
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 1), recipes.len);
    try std.testing.expectEqualStrings("Mushroom Risotto", recipes[0].title);
}

test "parse minimal recipe uses defaults" {
    const recipes = try parseRecipes(test_alloc, "{\"title\": \"Toast\"}");
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 1), recipes.len);
    try std.testing.expectEqualStrings("Toast", recipes[0].title);
    try std.testing.expectEqualStrings("", recipes[0].description);
    try std.testing.expectEqual(@as(u32, 0), recipes[0].servings);
    try std.testing.expectEqualStrings("", recipes[0].image_path);
    try std.testing.expectEqual(@as(usize, 0), recipes[0].ingredients.len);
    try std.testing.expectEqual(@as(usize, 0), recipes[0].steps.len);
}

test "parse empty collection" {
    const recipes = try parseRecipes(test_alloc, "{\"recipes\": []}");
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 0), recipes.len);
}

test "parse invalid JSON is an error" {
    try std.testing.expectError(error.InvalidJson, parseRecipes(test_alloc, "{ this is not json"));
}

test "parse object without recipes or title is an error" {
    try std.testing.expectError(error.NotARecipe, parseRecipes(test_alloc, "{\"nope\": 1}"));
}

test "parse recipe without title is an error" {
    // A top-level object that is neither a collection nor
    // a recipe is NotARecipe; a recipe in recipe position
    // with a missing or blank title is MissingTitle.
    // Both are errors; the distinction is only in the UI
    // message (see formatError).
    try std.testing.expectError(error.NotARecipe, parseRecipes(test_alloc, "{\"description\": \"No title here.\"}"));
    try std.testing.expectError(error.MissingTitle, parseRecipes(test_alloc, "{\"title\": \"   \"}"));
    try std.testing.expectError(error.MissingTitle, parseRecipes(test_alloc, "[{\"description\": \"No title here.\"}]"));
}

test "parse recipes field must be an array" {
    try std.testing.expectError(error.RecipesNotArray, parseRecipes(test_alloc, "{\"recipes\": {\"title\": \"Toast\"}}"));
}

test "url parsing defaults and https rejection" {
    const url = try parseHttpUrl("http://localhost:8000/recipes.json");
    try std.testing.expectEqualStrings("localhost", url.host);
    try std.testing.expectEqual(@as(u16, 8000), url.port);
    try std.testing.expectEqualStrings("/recipes.json", url.path);
    const plain = try parseHttpUrl("http://example.com");
    try std.testing.expectEqual(@as(u16, 80), plain.port);
    try std.testing.expectEqualStrings("/", plain.path);
    try std.testing.expectError(error.HttpsNotSupported, parseHttpUrl("https://example.com/recipes.json"));
    try std.testing.expectError(error.MissingHost, parseHttpUrl("http:///recipes.json"));
}

test "chunked body decodes" {
    const decoded = try decodeChunked(test_alloc, "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    defer test_alloc.free(decoded);
    try std.testing.expectEqualStrings("hello world", decoded);
}

// A one-shot local HTTP server: binds first (so the port
// is known), then serves exactly one response in a thread.
// Mirrors rust-egui's serve_once test helper. Raw
// syscalls, like the client: no Io.net here at all, so
// the tests exercise exactly the socket layer the client
// uses, with no Threaded-Io thread surprises.
fn serveOnce(response: []const u8) !struct { port: u16, thread: std.Thread } {
    const linux = std.os.linux;
    const fd = syscallResult(linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0)) catch return error.SocketFailed;
    const listen_fd: i32 = @intCast(fd);
    errdefer _ = linux.close(listen_fd);
    var addr = ipv4Sockaddr(.{ 127, 0, 0, 1 }, 0);
    _ = syscallResult(linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) catch return error.SocketFailed;
    _ = syscallResult(linux.listen(listen_fd, 128)) catch return error.SocketFailed;
    // Port 0 was requested, so ask the kernel what it
    // assigned (getsockname fills the sockaddr back in).
    var bound = addr;
    var bound_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = syscallResult(linux.getsockname(listen_fd, @ptrCast(&bound), &bound_len)) catch return error.SocketFailed;
    const port = std.mem.bigToNative(u16, bound.port);
    const thread = try std.Thread.spawn(.{}, serveOnceWorker, .{ listen_fd, response });
    return .{ .port = port, .thread = thread };
}

fn serveOnceWorker(listen_fd: i32, response: []const u8) void {
    const linux = std.os.linux;
    defer _ = linux.close(listen_fd);
    const conn = syscallResult(linux.accept(listen_fd, null, null)) catch return;
    const conn_fd: i32 = @intCast(conn);
    defer _ = linux.close(conn_fd);
    // Read (and discard) the request; the response does
    // not depend on it, and a client that already sent
    // everything will not block on this read.
    var request_buf: [4096]u8 = undefined;
    _ = syscallResult(linux.recvfrom(conn_fd, &request_buf, request_buf.len, 0, null, null)) catch {};
    sendAll(conn_fd, response) catch {};
}

test "fetch from a local server" {
    // std.testing.io is only the DNS-fallback Io for
    // fetchAndParse; 127.0.0.1 literals short-circuit
    // before it, so it is never actually used here.
    const io = std.testing.io;
    const body = try std.fmt.allocPrint(test_alloc, "{{\"recipes\": [{s}]}}", .{single_json});
    defer test_alloc.free(body);
    const response = try std.fmt.allocPrint(
        test_alloc,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer test_alloc.free(response);
    const served = try serveOnce(response);
    const url = try std.fmt.allocPrint(test_alloc, "http://127.0.0.1:{d}/recipes.json", .{served.port});
    defer test_alloc.free(url);
    const recipes = try fetchAndParse(test_alloc, url, io);
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 1), recipes.len);
    try std.testing.expectEqualStrings("Mushroom Risotto", recipes[0].title);
    served.thread.join();
}

test "fetch non-200 is an error" {
    const io = std.testing.io;
    const served = try serveOnce("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot found");
    const url = try std.fmt.allocPrint(test_alloc, "http://127.0.0.1:{d}/missing.json", .{served.port});
    defer test_alloc.free(url);
    const err = fetchUrl(test_alloc, url, io);
    try std.testing.expectError(error.HttpStatus, err);
    try std.testing.expectEqual(@as(u16, 404), last_http_status);
    served.thread.join();
}

test "fetch chunked response from a local server" {
    const io = std.testing.io;
    const body = try std.fmt.allocPrint(test_alloc, "{{\"recipes\": [{s}]}}", .{single_json});
    defer test_alloc.free(body);
    // One chunk holding the whole body, then the terminator.
    const response = try std.fmt.allocPrint(
        test_alloc,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n",
        .{ body.len, body },
    );
    defer test_alloc.free(response);
    const served = try serveOnce(response);
    const url = try std.fmt.allocPrint(test_alloc, "http://127.0.0.1:{d}/recipes.json", .{served.port});
    defer test_alloc.free(url);
    const recipes = try fetchAndParse(test_alloc, url, io);
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 1), recipes.len);
    try std.testing.expectEqualStrings("Mushroom Risotto", recipes[0].title);
    served.thread.join();
}

test "imported recipes insert into a throwaway database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fmt.allocPrintSentinel(test_alloc, "{s}/test.db", .{path_buf[0..n]}, 0);
    defer test_alloc.free(path);
    const seed: [0]db.Recipe = .{};
    try db.openForTest(path.ptr, &seed);
    const recipes = try parseRecipes(test_alloc, single_json);
    defer freeRecipes(test_alloc, recipes);
    const id = try db.insertRecipe(recipes[0]);
    try db.reload();
    try std.testing.expectEqual(@as(usize, 1), db.recipes.len);
    try std.testing.expectEqual(id, db.recipes[0].id);
    try std.testing.expectEqualStrings("Mushroom Risotto", db.recipes[0].title);
    try std.testing.expectEqual(@as(usize, 1), db.recipes[0].ingredients.len);
}

// --- Raw-file import tests (mirroring rust-egui's
// import_from_file tests) ---

// Write `contents` to `name` inside a fresh temp dir and
// return the file's absolute path, allocated from the
// test allocator.
fn writeTempFile(tmp: *std.testing.TmpDir, name: []const u8, contents: []const u8) ![]u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = contents });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    return std.fmt.allocPrint(test_alloc, "{s}/{s}", .{ path_buf[0..n], name });
}

test "import from file single recipe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(&tmp, "single.json", single_json);
    defer test_alloc.free(path);
    const recipes = try importFromFile(test_alloc, path, std.testing.io);
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 1), recipes.len);
    try std.testing.expectEqualStrings("Mushroom Risotto", recipes[0].title);
}

test "import from file collection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = try std.fmt.allocPrint(test_alloc, "{{\"recipes\": [{s}, {s}]}}", .{ single_json, single_json });
    defer test_alloc.free(body);
    const path = try writeTempFile(&tmp, "collection.json", body);
    defer test_alloc.free(path);
    const recipes = try importFromFile(test_alloc, path, std.testing.io);
    defer freeRecipes(test_alloc, recipes);
    try std.testing.expectEqual(@as(usize, 2), recipes.len);
}

test "import from file bare array and empty collection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const array_body = try std.fmt.allocPrint(test_alloc, "[{s}]", .{single_json});
    defer test_alloc.free(array_body);
    const array_path = try writeTempFile(&tmp, "array.json", array_body);
    defer test_alloc.free(array_path);
    const from_array = try importFromFile(test_alloc, array_path, std.testing.io);
    defer freeRecipes(test_alloc, from_array);
    try std.testing.expectEqual(@as(usize, 1), from_array.len);
    const empty_path = try writeTempFile(&tmp, "empty.json", "{\"recipes\": []}");
    defer test_alloc.free(empty_path);
    const from_empty = try importFromFile(test_alloc, empty_path, std.testing.io);
    defer freeRecipes(test_alloc, from_empty);
    try std.testing.expectEqual(@as(usize, 0), from_empty.len);
}

test "import from file invalid, non-UTF-8, and missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const invalid_path = try writeTempFile(&tmp, "invalid.json", "{ this is not json");
    defer test_alloc.free(invalid_path);
    try std.testing.expectError(error.InvalidJson, importFromFile(test_alloc, invalid_path, std.testing.io));
    const invalid_msg = try formatFileError(test_alloc, invalid_path, error.InvalidJson);
    defer test_alloc.free(invalid_msg);
    try std.testing.expect(std.mem.indexOf(u8, invalid_msg, "Could not parse recipe JSON") != null);
    const non_utf8_path = try writeTempFile(&tmp, "non-utf8.json", "\xff\xfe{\"title\": \"Toast\"}");
    defer test_alloc.free(non_utf8_path);
    try std.testing.expectError(error.FileNotUtf8, importFromFile(test_alloc, non_utf8_path, std.testing.io));
    const non_utf8_msg = try formatFileError(test_alloc, non_utf8_path, error.FileNotUtf8);
    defer test_alloc.free(non_utf8_msg);
    try std.testing.expectEqualStrings("File was not valid UTF-8.", non_utf8_msg);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const missing_path = try std.fmt.allocPrint(test_alloc, "{s}/missing.json", .{path_buf[0..n]});
    defer test_alloc.free(missing_path);
    const missing_err = importFromFile(test_alloc, missing_path, std.testing.io);
    try std.testing.expectError(error.FileNotFound, missing_err);
    const missing_msg = try formatFileError(test_alloc, missing_path, error.FileNotFound);
    defer test_alloc.free(missing_msg);
    try std.testing.expect(std.mem.indexOf(u8, missing_msg, "Could not read file") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_msg, missing_path) != null);
}

// Locate a shared test-data fixture. @src().file is only
// the file name in this build, so it cannot anchor the
// path; instead probe the two plausible working
// directories: zig-dvui/ (the documented `zig test
// src/json_import.zig` invocation, where the fixtures
// are at ../test-data) and the repo root (test-data).
// If neither probes, return the documented location so
// the failure names a real path.
fn fixturePath(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const candidates = [_][]const u8{ "../test-data/", "test-data/" };
    for (candidates) |prefix| {
        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name });
        std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch {
            alloc.free(path);
            continue;
        };
        return path;
    }
    return std.fmt.allocPrint(alloc, "../test-data/{s}", .{name});
}

test "import from file shared fixtures" {
    const single_path = try fixturePath(test_alloc, "recipe-single.json");
    defer test_alloc.free(single_path);
    const single = try importFromFile(test_alloc, single_path, std.testing.io);
    defer freeRecipes(test_alloc, single);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualStrings("Mushroom Risotto", single[0].title);
    const array_path = try fixturePath(test_alloc, "recipes-array.json");
    defer test_alloc.free(array_path);
    const array = try importFromFile(test_alloc, array_path, std.testing.io);
    defer freeRecipes(test_alloc, array);
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqualStrings("Pancakes", array[0].title);
    try std.testing.expectEqualStrings("Greek Salad", array[1].title);
    const collection_path = try fixturePath(test_alloc, "recipes.json");
    defer test_alloc.free(collection_path);
    const collection = try importFromFile(test_alloc, collection_path, std.testing.io);
    defer freeRecipes(test_alloc, collection);
    try std.testing.expectEqual(@as(usize, 3), collection.len);
    try std.testing.expectEqualStrings("Fried Chicken", collection[0].title);
    try std.testing.expectEqualStrings("Lasagna", collection[1].title);
    try std.testing.expectEqualStrings("Butter Tarts", collection[2].title);
    const empty_path = try fixturePath(test_alloc, "recipes-empty.json");
    defer test_alloc.free(empty_path);
    const empty = try importFromFile(test_alloc, empty_path, std.testing.io);
    defer freeRecipes(test_alloc, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const invalid_path = try fixturePath(test_alloc, "invalid.json");
    defer test_alloc.free(invalid_path);
    try std.testing.expectError(error.InvalidJson, importFromFile(test_alloc, invalid_path, std.testing.io));
}
