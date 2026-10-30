#include "json_import.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <utility>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace {

// ----------------------------------------------------------------
// Small JSON value + parser, for recipe documents only.
// ----------------------------------------------------------------

struct JsonValue {
    enum class Type { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool boolean = false;
    // Numbers: integers keep their value exactly; a number with
    // a fraction or exponent part is not an integer (serde would
    // reject it for servings, which is an integer field).
    bool is_integer = false;
    long long integer = 0;
    std::string str;
    std::vector<JsonValue> array;
    std::vector<std::pair<std::string, JsonValue>> object;

    // Last value for key, or nullptr. (serde_json's map keeps the
    // last value for a repeated key, so lookup matches it.)
    const JsonValue* find(const std::string& key) const {
        if (type != Type::Object) {
            return nullptr;
        }
        const JsonValue* found = nullptr;
        for (const auto& pair : object) {
            if (pair.first == key) {
                found = &pair.second;
            }
        }
        return found;
    }
};

// JSON nesting depth cap, matching serde_json's default recursion
// limit: deeper documents are an error, not a stack overflow.
const int kMaxDepth = 128;

std::string trim(const std::string& text) {
    size_t first = 0;
    while (first < text.size() &&
           std::isspace(static_cast<unsigned char>(text[first]))) {
        ++first;
    }
    size_t last = text.size();
    while (last > first &&
           std::isspace(static_cast<unsigned char>(text[last - 1]))) {
        --last;
    }
    return text.substr(first, last - first);
}

// Appends the UTF-8 encoding of a Unicode code point (0 to
// 0x10FFFF, excluding surrogates, which the caller resolves
// into pairs before calling this).
void append_utf8(std::string& out, unsigned int code_point) {
    if (code_point < 0x80) {
        out.push_back(static_cast<char>(code_point));
    } else if (code_point < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (code_point >> 6)));
        out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
    } else if (code_point < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (code_point >> 12)));
        out.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (code_point >> 18)));
        out.push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
    }
}

class JsonParser {
public:
    JsonParser(const std::string& text, std::string& error)
        : text_(text), error_(error) {}

    // Parses the whole document: one value, then only whitespace.
    bool parse_document(JsonValue& out) {
        if (!parse_value(out, 0)) {
            return false;
        }
        skip_whitespace();
        if (pos_ != text_.size()) {
            return fail("Unexpected trailing characters after the JSON document.");
        }
        return true;
    }

private:
    const std::string& text_;
    std::string& error_;
    size_t pos_ = 0;

    bool fail(const std::string& message) {
        if (error_.empty()) {
            error_ = "Could not parse recipe JSON: " + message;
        }
        return false;
    }

    void skip_whitespace() {
        while (pos_ < text_.size()) {
            char c = text_[pos_];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++pos_;
            } else {
                break;
            }
        }
    }

    bool consume(char expected) {
        if (pos_ < text_.size() && text_[pos_] == expected) {
            ++pos_;
            return true;
        }
        return false;
    }

    bool consume_literal(const char* literal) {
        size_t len = std::strlen(literal);
        if (text_.compare(pos_, len, literal) == 0) {
            pos_ += len;
            return true;
        }
        return false;
    }

    bool parse_value(JsonValue& out, int depth) {
        if (depth > kMaxDepth) {
            return fail("JSON is nested too deeply.");
        }
        skip_whitespace();
        if (pos_ >= text_.size()) {
            return fail("Unexpected end of input.");
        }
        char c = text_[pos_];
        if (c == '{') {
            return parse_object(out, depth);
        }
        if (c == '[') {
            return parse_array(out, depth);
        }
        if (c == '"') {
            std::string str;
            if (!parse_string(str)) {
                return false;
            }
            out.type = JsonValue::Type::String;
            out.str = std::move(str);
            return true;
        }
        if (c == 't') {
            if (!consume_literal("true")) {
                return fail("Invalid value.");
            }
            out.type = JsonValue::Type::Bool;
            out.boolean = true;
            return true;
        }
        if (c == 'f') {
            if (!consume_literal("false")) {
                return fail("Invalid value.");
            }
            out.type = JsonValue::Type::Bool;
            out.boolean = false;
            return true;
        }
        if (c == 'n') {
            if (!consume_literal("null")) {
                return fail("Invalid value.");
            }
            out.type = JsonValue::Type::Null;
            return true;
        }
        if (c == '-' || (c >= '0' && c <= '9')) {
            return parse_number(out);
        }
        return fail("Unexpected character.");
    }

    bool parse_object(JsonValue& out, int depth) {
        ++pos_;  // '{'
        out.type = JsonValue::Type::Object;
        out.object.clear();
        skip_whitespace();
        if (consume('}')) {
            return true;
        }
        while (true) {
            skip_whitespace();
            if (pos_ >= text_.size() || text_[pos_] != '"') {
                return fail("Expected a string key in an object.");
            }
            std::string key;
            if (!parse_string(key)) {
                return false;
            }
            skip_whitespace();
            if (!consume(':')) {
                return fail("Expected ':' after an object key.");
            }
            JsonValue value;
            if (!parse_value(value, depth + 1)) {
                return false;
            }
            out.object.emplace_back(std::move(key), std::move(value));
            skip_whitespace();
            if (consume('}')) {
                return true;
            }
            if (!consume(',')) {
                return fail("Expected ',' or '}' in an object.");
            }
        }
    }

    bool parse_array(JsonValue& out, int depth) {
        ++pos_;  // '['
        out.type = JsonValue::Type::Array;
        out.array.clear();
        skip_whitespace();
        if (consume(']')) {
            return true;
        }
        while (true) {
            JsonValue value;
            if (!parse_value(value, depth + 1)) {
                return false;
            }
            out.array.push_back(std::move(value));
            skip_whitespace();
            if (consume(']')) {
                return true;
            }
            if (!consume(',')) {
                return fail("Expected ',' or ']' in an array.");
            }
        }
    }

    // Parses one \uXXXX escape (pos_ is just past the 'u').
    // Returns false on a bad hex digit; on success sets code
    // point (a surrogate value is returned as-is, so the caller
    // can resolve pairs).
    bool parse_hex4(unsigned int& code_point) {
        if (pos_ + 4 > text_.size()) {
            return fail("Truncated \\u escape in a string.");
        }
        code_point = 0;
        for (int i = 0; i < 4; ++i) {
            char c = text_[pos_ + static_cast<size_t>(i)];
            code_point <<= 4;
            if (c >= '0' && c <= '9') {
                code_point |= static_cast<unsigned int>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                code_point |= static_cast<unsigned int>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                code_point |= static_cast<unsigned int>(c - 'A' + 10);
            } else {
                return fail("Invalid \\u escape in a string.");
            }
        }
        pos_ += 4;
        return true;
    }

    bool parse_string(std::string& out) {
        ++pos_;  // opening '"'
        out.clear();
        while (true) {
            if (pos_ >= text_.size()) {
                return fail("Unterminated string.");
            }
            unsigned char c = static_cast<unsigned char>(text_[pos_]);
            if (c == '"') {
                ++pos_;
                return true;
            }
            if (c < 0x20) {
                return fail("Unescaped control character in a string.");
            }
            if (c != '\\') {
                out.push_back(static_cast<char>(c));
                ++pos_;
                continue;
            }
            ++pos_;  // backslash
            if (pos_ >= text_.size()) {
                return fail("Unterminated escape in a string.");
            }
            char escape = text_[pos_++];
            switch (escape) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    unsigned int code_point = 0;
                    if (!parse_hex4(code_point)) {
                        return false;
                    }
                    if (code_point >= 0xD800 && code_point <= 0xDBFF) {
                        // High surrogate: a low surrogate must follow.
                        if (pos_ + 1 >= text_.size() || text_[pos_] != '\\' ||
                            text_[pos_ + 1] != 'u') {
                            return fail("Lone high surrogate in a string.");
                        }
                        pos_ += 2;
                        unsigned int low = 0;
                        if (!parse_hex4(low)) {
                            return false;
                        }
                        if (low < 0xDC00 || low > 0xDFFF) {
                            return fail("Invalid low surrogate in a string.");
                        }
                        code_point = 0x10000 + ((code_point - 0xD800) << 10) +
                                     (low - 0xDC00);
                    } else if (code_point >= 0xDC00 && code_point <= 0xDFFF) {
                        return fail("Lone low surrogate in a string.");
                    }
                    append_utf8(out, code_point);
                    break;
                }
                default:
                    return fail("Invalid escape in a string.");
            }
        }
    }

    bool parse_number(JsonValue& out) {
        size_t start = pos_;
        if (pos_ < text_.size() && text_[pos_] == '-') {
            ++pos_;
        }
        if (pos_ >= text_.size()) {
            return fail("Invalid number.");
        }
        if (text_[pos_] == '0') {
            ++pos_;
        } else if (text_[pos_] >= '1' && text_[pos_] <= '9') {
            while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
            }
        } else {
            return fail("Invalid number.");
        }
        bool is_integer = true;
        if (pos_ < text_.size() && text_[pos_] == '.') {
            is_integer = false;
            ++pos_;
            if (pos_ >= text_.size() || text_[pos_] < '0' || text_[pos_] > '9') {
                return fail("Invalid number.");
            }
            while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
            }
        }
        if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
            is_integer = false;
            ++pos_;
            if (pos_ < text_.size() && (text_[pos_] == '+' || text_[pos_] == '-')) {
                ++pos_;
            }
            if (pos_ >= text_.size() || text_[pos_] < '0' || text_[pos_] > '9') {
                return fail("Invalid number.");
            }
            while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
            }
        }
        out.type = JsonValue::Type::Number;
        out.is_integer = is_integer;
        out.integer = 0;
        if (is_integer) {
            // Exact integer value; overflow is an error rather
            // than a wrapped value.
            const std::string digits = text_.substr(start, pos_ - start);
            try {
                size_t used = 0;
                out.integer = std::stoll(digits, &used);
                if (used != digits.size()) {
                    return fail("Invalid number.");
                }
            } catch (...) {
                return fail("Number is out of range.");
            }
        }
        return true;
    }
};

// ----------------------------------------------------------------
// Recipe extraction from a parsed value.
// ----------------------------------------------------------------

// A string field, or the default when absent. A present field of
// the wrong type is an error (serde would reject it too), not a
// silent default.
bool string_field(const JsonValue& object, const char* key, std::string& out,
                  std::string& error) {
    const JsonValue* value = object.find(key);
    if (value == nullptr) {
        out.clear();
        return true;
    }
    if (value->type != JsonValue::Type::String) {
        error = std::string("Field \"") + key + "\" must be a string.";
        return false;
    }
    out = value->str;
    return true;
}

bool recipe_from_value(const JsonValue& value, Recipe& recipe,
                       std::string& error) {
    if (value.type != JsonValue::Type::Object) {
        error = "Could not parse recipe JSON: each recipe must be an object.";
        return false;
    }
    const JsonValue* title = value.find("title");
    if (title == nullptr || title->type != JsonValue::Type::String ||
        trim(title->str).empty()) {
        error = "Imported recipe is missing a title.";
        return false;
    }
    recipe.id = 0;
    recipe.title = title->str;
    if (!string_field(value, "description", recipe.description, error) ||
        !string_field(value, "notes", recipe.notes, error)) {
        return false;
    }
    const JsonValue* servings = value.find("servings");
    if (servings == nullptr) {
        recipe.servings = 0;
    } else if (servings->type != JsonValue::Type::Number ||
               !servings->is_integer ||
               servings->integer < std::numeric_limits<int>::min() ||
               servings->integer > std::numeric_limits<int>::max()) {
        error = "Field \"servings\" must be a whole number.";
        return false;
    } else {
        recipe.servings = static_cast<int>(servings->integer);
    }
    const JsonValue* image_path = value.find("image_path");
    if (image_path == nullptr || image_path->type == JsonValue::Type::Null) {
        recipe.image_path.clear();
    } else if (image_path->type == JsonValue::Type::String) {
        recipe.image_path = image_path->str;
    } else {
        error = "Field \"image_path\" must be a string or null.";
        return false;
    }
    recipe.ingredients.clear();
    const JsonValue* ingredients = value.find("ingredients");
    if (ingredients != nullptr) {
        if (ingredients->type != JsonValue::Type::Array) {
            error = "Field \"ingredients\" must be an array.";
            return false;
        }
        for (const JsonValue& item : ingredients->array) {
            if (item.type != JsonValue::Type::Object) {
                error = "Each ingredient must be an object.";
                return false;
            }
            Ingredient ingredient;
            if (!string_field(item, "amount", ingredient.amount, error) ||
                !string_field(item, "unit", ingredient.unit, error) ||
                !string_field(item, "name", ingredient.name, error)) {
                return false;
            }
            recipe.ingredients.push_back(std::move(ingredient));
        }
    }
    recipe.steps.clear();
    const JsonValue* steps = value.find("steps");
    if (steps != nullptr) {
        if (steps->type != JsonValue::Type::Array) {
            error = "Field \"steps\" must be an array.";
            return false;
        }
        for (const JsonValue& item : steps->array) {
            if (item.type != JsonValue::Type::String) {
                error = "Each step must be a string.";
                return false;
            }
            recipe.steps.push_back(item.str);
        }
    }
    return true;
}

// ----------------------------------------------------------------
// HTTP fetching (http:// only).
// ----------------------------------------------------------------

struct HttpUrl {
    std::string host;
    int port = 80;
    std::string path;
};

bool parse_http_url(const std::string& url, HttpUrl& out, std::string& error) {
    if (url.rfind("https://", 0) == 0) {
        error =
            "HTTPS URLs are not supported by this importer; use an http:// URL "
            "(for example, the local test server).";
        return false;
    }
    if (url.rfind("http://", 0) != 0) {
        error = "URL must start with http://.";
        return false;
    }
    std::string rest = url.substr(7);
    size_t slash = rest.find('/');
    std::string host_port = slash == std::string::npos ? rest : rest.substr(0, slash);
    std::string path = slash == std::string::npos ? "/" : rest.substr(slash);
    if (host_port.empty()) {
        error = "URL is missing a host.";
        return false;
    }
    size_t colon = host_port.rfind(':');
    std::string host = host_port;
    int port = 80;
    if (colon != std::string::npos) {
        std::string port_text = host_port.substr(colon + 1);
        if (port_text.empty()) {
            host = host_port.substr(0, colon);
        } else {
            bool digits = !port_text.empty() &&
                          std::all_of(port_text.begin(), port_text.end(),
                                      [](unsigned char c) { return std::isdigit(c) != 0; });
            long parsed = 0;
            if (!digits) {
                error = "Invalid port in URL: " + port_text + ".";
                return false;
            }
            try {
                parsed = std::stol(port_text);
            } catch (...) {
                error = "Invalid port in URL: " + port_text + ".";
                return false;
            }
            if (parsed < 1 || parsed > 65535) {
                error = "Invalid port in URL: " + port_text + ".";
                return false;
            }
            host = host_port.substr(0, colon);
            port = static_cast<int>(parsed);
        }
    }
    if (host.empty()) {
        error = "URL is missing a host.";
        return false;
    }
    out.host = host;
    out.port = port;
    out.path = path;
    return true;
}

// Lowercases a header name in place (ASCII only, as HTTP names are).
std::string lower_ascii(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return text;
}

enum class FetchOutcome { Body, Redirect };

bool decode_chunked(const std::string& body, std::string& out,
                    std::string& error) {
    out.clear();
    size_t pos = 0;
    while (true) {
        size_t line_end = body.find("\r\n", pos);
        if (line_end == std::string::npos) {
            error = "Malformed chunked response.";
            return false;
        }
        std::string size_text = body.substr(pos, line_end - pos);
        size_t semicolon = size_text.find(';');
        if (semicolon != std::string::npos) {
            size_text = size_text.substr(0, semicolon);
        }
        size_text = trim(size_text);
        if (size_text.empty()) {
            error = "Malformed chunked response.";
            return false;
        }
        long size = 0;
        try {
            size_t used = 0;
            size = std::stol(size_text, &used, 16);
            if (used != size_text.size() || size < 0) {
                error = "Malformed chunked response.";
                return false;
            }
        } catch (...) {
            error = "Malformed chunked response.";
            return false;
        }
        pos = line_end + 2;
        if (size == 0) {
            return true;
        }
        if (body.size() < pos + static_cast<size_t>(size) + 2) {
            error = "Truncated chunked response.";
            return false;
        }
        out.append(body, pos, static_cast<size_t>(size));
        pos += static_cast<size_t>(size) + 2;
    }
}

// Connects with a 10s timeout (non-blocking connect + select), so
// an unreachable host fails on the worker thread instead of
// hanging it indefinitely.
bool connect_with_timeout(const addrinfo* addresses, int& sockfd,
                          std::string& error) {
    for (const addrinfo* addr = addresses; addr != nullptr; addr = addr->ai_next) {
        int fd = socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol);
        if (fd < 0) {
            continue;
        }
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int result = connect(fd, addr->ai_addr, addr->ai_addrlen);
        if (result != 0 && errno != EINPROGRESS) {
            close(fd);
            continue;
        }
        if (result != 0) {
            fd_set write_set;
            FD_ZERO(&write_set);
            FD_SET(fd, &write_set);
            timeval timeout{10, 0};
            result = select(fd + 1, nullptr, &write_set, nullptr, &timeout);
            if (result <= 0) {
                close(fd);
                continue;
            }
            int socket_error = 0;
            socklen_t len = sizeof(socket_error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &len) != 0 ||
                socket_error != 0) {
                close(fd);
                continue;
            }
        }
        fcntl(fd, F_SETFL, flags);
        timeval read_timeout{30, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &read_timeout, sizeof(read_timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &read_timeout, sizeof(read_timeout));
        sockfd = fd;
        return true;
    }
    error = "Could not connect.";
    return false;
}

bool fetch_once(const HttpUrl& url, FetchOutcome& outcome, std::string& body,
                std::string& location, std::string& error) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    std::string port_text = std::to_string(url.port);
    addrinfo* addresses = nullptr;
    if (getaddrinfo(url.host.c_str(), port_text.c_str(), &hints, &addresses) != 0 ||
        addresses == nullptr) {
        error = "Could not resolve " + url.host + ".";
        return false;
    }
    int sockfd = -1;
    std::string connect_error;
    bool connected = connect_with_timeout(addresses, sockfd, connect_error);
    freeaddrinfo(addresses);
    if (!connected) {
        error = "Could not connect to " + url.host + ": " + connect_error;
        return false;
    }

    std::string host_header = url.port == 80
                                  ? url.host
                                  : url.host + ":" + std::to_string(url.port);
    std::string request = "GET " + url.path + " HTTP/1.1\r\nHost: " + host_header +
                          "\r\nConnection: close\r\nUser-Agent: recipe-manager-test\r\n"
                          "Accept: application/json\r\n\r\n";
    size_t sent = 0;
    while (sent < request.size()) {
        ssize_t n = send(sockfd, request.data() + sent, request.size() - sent, 0);
        if (n <= 0) {
            close(sockfd);
            error = "Could not send request.";
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    std::string raw;
    char buffer[8192];
    while (true) {
        ssize_t n = recv(sockfd, buffer, sizeof(buffer), 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(sockfd);
            error = "Could not read response.";
            return false;
        }
        if (n == 0) {
            break;
        }
        raw.append(buffer, static_cast<size_t>(n));
    }
    close(sockfd);

    size_t header_end = raw.find("\r\n\r\n");
    if (header_end == std::string::npos) {
        error = "Response was not valid HTTP.";
        return false;
    }
    std::string headers = raw.substr(0, header_end);
    std::string response_body = raw.substr(header_end + 4);
    size_t line_end = headers.find("\r\n");
    std::string status_line = line_end == std::string::npos ? headers
                                                            : headers.substr(0, line_end);
    // Status line: "HTTP/1.1 200 OK" — the code is the second token.
    size_t first_space = status_line.find(' ');
    size_t second_space = first_space == std::string::npos
                              ? std::string::npos
                              : status_line.find(' ', first_space + 1);
    if (first_space == std::string::npos) {
        error = "Response was not valid HTTP.";
        return false;
    }
    std::string code_text = status_line.substr(
        first_space + 1,
        (second_space == std::string::npos ? status_line.size() : second_space) -
            first_space - 1);
    int status = 0;
    try {
        size_t used = 0;
        status = std::stoi(code_text, &used);
        if (used != code_text.size()) {
            error = "Response was not valid HTTP.";
            return false;
        }
    } catch (...) {
        error = "Response was not valid HTTP.";
        return false;
    }

    std::string redirect_location;
    bool chunked = false;
    bool has_length = false;
    size_t content_length = 0;
    size_t pos = line_end == std::string::npos ? headers.size() : line_end + 2;
    while (pos < headers.size()) {
        size_t end = headers.find("\r\n", pos);
        std::string line = headers.substr(
            pos, end == std::string::npos ? std::string::npos : end - pos);
        size_t colon = line.find(':');
        if (colon != std::string::npos) {
            std::string name = lower_ascii(trim(line.substr(0, colon)));
            std::string value = trim(line.substr(colon + 1));
            if (name == "location") {
                redirect_location = value;
            } else if (name == "transfer-encoding" &&
                       lower_ascii(value).find("chunked") != std::string::npos) {
                chunked = true;
            } else if (name == "content-length") {
                try {
                    size_t used = 0;
                    content_length = std::stoull(value, &used);
                    has_length = used == value.size();
                } catch (...) {
                    has_length = false;
                }
            }
        }
        if (end == std::string::npos) {
            break;
        }
        pos = end + 2;
    }

    if ((status == 301 || status == 302 || status == 303 || status == 307 ||
         status == 308) &&
        !redirect_location.empty()) {
        outcome = FetchOutcome::Redirect;
        location = redirect_location;
        return true;
    }
    if (status != 200) {
        error = "Server returned HTTP " + std::to_string(status) + " for " + url.host +
                ":" + std::to_string(url.port) + ".";
        return false;
    }
    if (chunked) {
        if (!decode_chunked(response_body, body, error)) {
            return false;
        }
    } else if (has_length) {
        if (response_body.size() < content_length) {
            error = "Response ended before the full body arrived.";
            return false;
        }
        body = response_body.substr(0, content_length);
    } else {
        body = response_body;
    }
    outcome = FetchOutcome::Body;
    return true;
}

std::string resolve_redirect(const HttpUrl& current, const std::string& location) {
    if (location.rfind("http://", 0) == 0 || location.rfind("https://", 0) == 0) {
        return location;
    }
    std::string host = current.port == 80
                           ? current.host
                           : current.host + ":" + std::to_string(current.port);
    if (!location.empty() && location[0] == '/') {
        return "http://" + host + location;
    }
    // A relative path resolves against the current path's directory.
    size_t slash = current.path.rfind('/');
    std::string base = slash == std::string::npos ? "/" : current.path.substr(0, slash + 1);
    return "http://" + host + base + location;
}

}  // namespace

bool parse_recipes(const std::string& text, std::vector<Recipe>& recipes,
                   std::string& error) {
    error.clear();
    JsonValue document;
    JsonParser parser(text, error);
    if (!parser.parse_document(document)) {
        return false;
    }
    std::vector<Recipe> parsed;
    if (document.type == JsonValue::Type::Array) {
        for (const JsonValue& item : document.array) {
            Recipe recipe;
            if (!recipe_from_value(item, recipe, error)) {
                return false;
            }
            parsed.push_back(std::move(recipe));
        }
    } else if (document.type == JsonValue::Type::Object) {
        const JsonValue* collection = document.find("recipes");
        if (collection != nullptr) {
            if (collection->type != JsonValue::Type::Array) {
                error = "The \"recipes\" field must be an array of recipes.";
                return false;
            }
            for (const JsonValue& item : collection->array) {
                Recipe recipe;
                if (!recipe_from_value(item, recipe, error)) {
                    return false;
                }
                parsed.push_back(std::move(recipe));
            }
        } else if (document.find("title") != nullptr) {
            Recipe recipe;
            if (!recipe_from_value(document, recipe, error)) {
                return false;
            }
            parsed.push_back(std::move(recipe));
        } else {
            error =
                "JSON must be a single recipe, an array of recipes, or an object "
                "with a \"recipes\" array.";
            return false;
        }
    } else {
        error =
            "JSON must be a single recipe, an array of recipes, or an object "
            "with a \"recipes\" array.";
        return false;
    }
    recipes = std::move(parsed);
    return true;
}

bool fetch_url(const std::string& url, std::string& body, std::string& error) {
    error.clear();
    std::string current = url;
    for (int attempt = 0; attempt < 4; ++attempt) {
        HttpUrl parsed;
        if (!parse_http_url(current, parsed, error)) {
            return false;
        }
        FetchOutcome outcome = FetchOutcome::Body;
        std::string fetched;
        std::string location;
        if (!fetch_once(parsed, outcome, fetched, location, error)) {
            return false;
        }
        if (outcome == FetchOutcome::Body) {
            body = fetched;
            return true;
        }
        current = resolve_redirect(parsed, location);
    }
    error = "Too many redirects.";
    return false;
}

bool fetch_and_parse(const std::string& url, std::vector<Recipe>& recipes,
                     std::string& error) {
    std::string body;
    if (!fetch_url(url, body, error)) {
        return false;
    }
    return parse_recipes(body, recipes, error);
}

// Checks that text is well-formed UTF-8: correct leading and
// continuation bytes, no overlong encodings, no surrogates, and
// nothing above U+10FFFF. The JSON parser below passes raw bytes
// through in strings, so without this check a Latin-1 or
// Shift_JIS file would silently import as mojibake instead of
// failing; encoding detection is a separate todo item, so for
// now a non-UTF-8 file is an error.
bool is_valid_utf8(const std::string& text) {
    size_t i = 0;
    while (i < text.size()) {
        unsigned char c = static_cast<unsigned char>(text[i]);
        if (c < 0x80) {
            ++i;
            continue;
        }
        unsigned int code_point = 0;
        int extra = 0;
        if ((c & 0xE0) == 0xC0) {
            code_point = c & 0x1F;
            extra = 1;
            if (code_point < 2) {
                return false;  // Overlong (C0/C1).
            }
        } else if ((c & 0xF0) == 0xE0) {
            code_point = c & 0x0F;
            extra = 2;
        } else if ((c & 0xF8) == 0xF0) {
            code_point = c & 0x07;
            extra = 3;
            if (code_point > 4) {
                return false;  // Above U+10FFFF.
            }
        } else {
            return false;  // Stray continuation byte or 0xF8+.
        }
        if (i + static_cast<size_t>(extra) >= text.size()) {
            return false;  // Truncated sequence.
        }
        for (int j = 1; j <= extra; ++j) {
            unsigned char next = static_cast<unsigned char>(text[i + static_cast<size_t>(j)]);
            if ((next & 0xC0) != 0x80) {
                return false;
            }
            code_point = (code_point << 6) | (next & 0x3F);
        }
        if ((extra == 2 && code_point < 0x800) ||
            (extra == 3 && code_point < 0x10000) ||
            (code_point >= 0xD800 && code_point <= 0xDFFF) ||
            code_point > 0x10FFFF) {
            return false;  // Overlong, surrogate, or out of range.
        }
        i += static_cast<size_t>(extra) + 1;
    }
    return true;
}

bool import_from_file(const std::string& path, std::vector<Recipe>& recipes,
                      std::string& error) {
    error.clear();
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        // errno is set by the failed open on POSIX; fall back to
        // a plain message if it somehow is not.
        int reason = errno;
        error = "Could not read file " + path + ": " +
                (reason != 0 ? std::strerror(reason) : "could not open file") + ".";
        return false;
    }
    std::string text((std::istreambuf_iterator<char>(file)),
                     std::istreambuf_iterator<char>());
    if (file.bad()) {
        error = "Could not read file " + path + ": read failed.";
        return false;
    }
    if (!is_valid_utf8(text)) {
        error = "Could not read file " + path + ": file is not valid UTF-8.";
        return false;
    }
    return parse_recipes(text, recipes, error);
}
