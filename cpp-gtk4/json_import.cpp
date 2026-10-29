#include "json_import.h"

#include <arpa/inet.h>
#include <cerrno>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace {

// --- UTF-8 validation ---
// rust-egui reads the whole body as a UTF-8 string before
// parsing, so a non-UTF-8 body is an error there too. Reject
// overlong forms, surrogates, and code points above U+10FFFF.

bool valid_utf8(const std::string& text) {
    size_t i = 0;
    while (i < text.size()) {
        unsigned char c = static_cast<unsigned char>(text[i]);
        if (c < 0x80) {
            ++i;
            continue;
        }
        uint32_t code = 0;
        size_t extra = 0;
        if ((c & 0xE0) == 0xC0) {
            code = c & 0x1F;
            extra = 1;
            if (code < 2) {
                return false;  // Overlong.
            }
        } else if ((c & 0xF0) == 0xE0) {
            code = c & 0x0F;
            extra = 2;
        } else if ((c & 0xF8) == 0xF0) {
            code = c & 0x07;
            extra = 3;
            if (code > 4) {
                return false;  // Above U+10FFFF.
            }
        } else {
            return false;
        }
        if (i + extra >= text.size()) {
            return false;
        }
        for (size_t k = 1; k <= extra; ++k) {
            unsigned char next = static_cast<unsigned char>(text[i + k]);
            if ((next & 0xC0) != 0x80) {
                return false;
            }
            code = (code << 6) | (next & 0x3F);
        }
        if (extra == 2 && code < 0x800) {
            return false;  // Overlong.
        }
        if (extra == 3 && code < 0x10000) {
            return false;  // Overlong.
        }
        if (code >= 0xD800 && code <= 0xDFFF) {
            return false;  // Surrogate.
        }
        if (code > 0x10FFFF) {
            return false;
        }
        i += extra + 1;
    }
    return true;
}

void append_utf8(std::string& out, uint32_t code) {
    if (code < 0x80) {
        out += static_cast<char>(code);
    } else if (code < 0x800) {
        out += static_cast<char>(0xC0 | (code >> 6));
        out += static_cast<char>(0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
        out += static_cast<char>(0xE0 | (code >> 12));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (code >> 18));
        out += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
    }
}

// --- JSON value ---

struct Value {
    enum class Type { Null, Bool, Number, String, Array, Object };
    Type type = Type::Null;
    bool boolean = false;
    std::string number;  // Raw token, for integer checking.
    std::string str;
    std::vector<Value> array;
    // Object members in document order; lookup takes the last
    // match, matching serde's last-wins duplicate keys.
    std::vector<std::pair<std::string, Value>> object;
};

const Value* find_field(const Value& object, const std::string& name) {
    const Value* found = nullptr;
    for (const auto& member : object.object) {
        if (member.first == name) {
            found = &member.second;
        }
    }
    return found;
}

class Parser {
   public:
    Parser(const std::string& text, std::string& error)
        : text_(text), error_(error) {}

    bool parse(Value& out) {
        skip_ws();
        if (!parse_value(out, 0)) {
            return false;
        }
        skip_ws();
        if (pos_ != text_.size()) {
            return fail("Trailing characters after the JSON document.");
        }
        return true;
    }

   private:
    static const int kMaxDepth = 200;

    const std::string& text_;
    std::string& error_;
    size_t pos_ = 0;

    bool fail(const std::string& message) {
        error_ = "Could not parse recipe JSON: " + message;
        return false;
    }

    void skip_ws() {
        while (pos_ < text_.size()) {
            char c = text_[pos_];
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
                break;
            }
            ++pos_;
        }
    }

    bool consume(char expected) {
        if (pos_ < text_.size() && text_[pos_] == expected) {
            ++pos_;
            return true;
        }
        return false;
    }

    bool expect(char expected, const std::string& what) {
        if (consume(expected)) {
            return true;
        }
        return fail("Expected " + what + ".");
    }

    bool parse_value(Value& out, int depth) {
        if (depth > kMaxDepth) {
            return fail("JSON nesting is too deep.");
        }
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
            out.type = Value::Type::String;
            return parse_string(out.str);
        }
        if (c == 't') {
            return parse_literal("true", Value::Type::Bool, true, out);
        }
        if (c == 'f') {
            return parse_literal("false", Value::Type::Bool, false, out);
        }
        if (c == 'n') {
            return parse_literal("null", Value::Type::Null, false, out);
        }
        if (c == '-' || (c >= '0' && c <= '9')) {
            return parse_number(out);
        }
        return fail("Unexpected character.");
    }

    bool parse_literal(const char* word, Value::Type type, bool boolean,
                       Value& out) {
        size_t len = std::strlen(word);
        if (text_.compare(pos_, len, word) != 0) {
            return fail("Invalid literal.");
        }
        pos_ += len;
        out.type = type;
        out.boolean = boolean;
        return true;
    }

    bool parse_number(Value& out) {
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
            while (pos_ < text_.size() &&
                   text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
            }
        } else {
            return fail("Invalid number.");
        }
        if (pos_ < text_.size() && text_[pos_] == '.') {
            ++pos_;
            if (pos_ >= text_.size() || text_[pos_] < '0' ||
                text_[pos_] > '9') {
                return fail("Invalid number.");
            }
            while (pos_ < text_.size() &&
                   text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
            }
        }
        if (pos_ < text_.size() &&
            (text_[pos_] == 'e' || text_[pos_] == 'E')) {
            ++pos_;
            if (pos_ < text_.size() &&
                (text_[pos_] == '+' || text_[pos_] == '-')) {
                ++pos_;
            }
            if (pos_ >= text_.size() || text_[pos_] < '0' ||
                text_[pos_] > '9') {
                return fail("Invalid number.");
            }
            while (pos_ < text_.size() &&
                   text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
            }
        }
        out.type = Value::Type::Number;
        out.number = text_.substr(start, pos_ - start);
        return true;
    }

    bool parse_hex4(uint32_t& code) {
        if (pos_ + 4 > text_.size()) {
            return fail("Invalid \\u escape.");
        }
        code = 0;
        for (int i = 0; i < 4; ++i) {
            char c = text_[pos_++];
            code <<= 4;
            if (c >= '0' && c <= '9') {
                code |= static_cast<uint32_t>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                code |= static_cast<uint32_t>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                code |= static_cast<uint32_t>(c - 'A' + 10);
            } else {
                return fail("Invalid \\u escape.");
            }
        }
        return true;
    }

    bool parse_string(std::string& out) {
        if (!expect('"', "a string")) {
            return false;
        }
        out.clear();
        while (true) {
            if (pos_ >= text_.size()) {
                return fail("Unterminated string.");
            }
            unsigned char c = static_cast<unsigned char>(text_[pos_++]);
            if (c == '"') {
                return true;
            }
            if (c < 0x20) {
                return fail("Unescaped control character in string.");
            }
            if (c != '\\') {
                out += static_cast<char>(c);
                continue;
            }
            if (pos_ >= text_.size()) {
                return fail("Unterminated string.");
            }
            char escape = text_[pos_++];
            switch (escape) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    uint32_t code = 0;
                    if (!parse_hex4(code)) {
                        return false;
                    }
                    if (code >= 0xD800 && code <= 0xDBFF) {
                        // High surrogate: a low surrogate must follow.
                        if (pos_ + 1 >= text_.size() ||
                            text_[pos_] != '\\' || text_[pos_ + 1] != 'u') {
                            return fail("Unpaired surrogate in string.");
                        }
                        pos_ += 2;
                        uint32_t low = 0;
                        if (!parse_hex4(low)) {
                            return false;
                        }
                        if (low < 0xDC00 || low > 0xDFFF) {
                            return fail("Unpaired surrogate in string.");
                        }
                        code = 0x10000 + ((code - 0xD800) << 10) +
                               (low - 0xDC00);
                    } else if (code >= 0xDC00 && code <= 0xDFFF) {
                        return fail("Unpaired surrogate in string.");
                    }
                    append_utf8(out, code);
                    break;
                }
                default:
                    return fail("Invalid escape in string.");
            }
        }
    }

    bool parse_array(Value& out, int depth) {
        out.type = Value::Type::Array;
        ++pos_;  // '['
        skip_ws();
        if (consume(']')) {
            return true;
        }
        while (true) {
            skip_ws();
            Value element;
            if (!parse_value(element, depth + 1)) {
                return false;
            }
            out.array.push_back(std::move(element));
            skip_ws();
            if (consume(']')) {
                return true;
            }
            if (!expect(',', "a ',' or ']' in array")) {
                return false;
            }
        }
    }

    bool parse_object(Value& out, int depth) {
        out.type = Value::Type::Object;
        ++pos_;  // '{'
        skip_ws();
        if (consume('}')) {
            return true;
        }
        while (true) {
            skip_ws();
            std::string key;
            if (pos_ >= text_.size() || text_[pos_] != '"') {
                return fail("Expected an object key string.");
            }
            if (!parse_string(key)) {
                return false;
            }
            skip_ws();
            if (!expect(':', "a ':' in object")) {
                return false;
            }
            skip_ws();
            Value value;
            if (!parse_value(value, depth + 1)) {
                return false;
            }
            out.object.emplace_back(std::move(key), std::move(value));
            skip_ws();
            if (consume('}')) {
                return true;
            }
            if (!expect(',', "a ',' or '}' in object")) {
                return false;
            }
        }
    }
};

std::string trimmed(const std::string& text) {
    size_t begin = 0;
    while (begin < text.size() &&
           std::isspace(static_cast<unsigned char>(text[begin]))) {
        ++begin;
    }
    size_t end = text.size();
    while (end > begin &&
           std::isspace(static_cast<unsigned char>(text[end - 1]))) {
        --end;
    }
    return text.substr(begin, end - begin);
}

bool string_field(const Value& recipe, const std::string& name,
                  std::string& out, std::string& error) {
    const Value* field = find_field(recipe, name);
    if (field == nullptr) {
        out.clear();
        return true;
    }
    if (field->type != Value::Type::String) {
        error = "Could not parse recipe JSON: field \"" + name +
                "\" must be a string.";
        return false;
    }
    out = field->str;
    return true;
}

bool parse_one_recipe(const Value& value, ImportedRecipe& out,
                      std::string& error) {
    if (value.type != Value::Type::Object) {
        error = "Could not parse recipe JSON: each recipe must be "
                "an object.";
        return false;
    }
    const Value* title = find_field(value, "title");
    if (title == nullptr || title->type != Value::Type::String ||
        trimmed(title->str).empty()) {
        error = "Could not parse recipe JSON: imported recipe is "
                "missing a title.";
        return false;
    }
    out.title = title->str;
    if (!string_field(value, "description", out.description, error)) {
        return false;
    }
    if (!string_field(value, "notes", out.notes, error)) {
        return false;
    }
    const Value* servings = find_field(value, "servings");
    out.servings = 0;
    if (servings != nullptr) {
        if (servings->type != Value::Type::Number ||
            servings->number.find_first_of(".eE") != std::string::npos) {
            error = "Could not parse recipe JSON: field \"servings\" "
                    "must be an integer.";
            return false;
        }
        try {
            size_t used = 0;
            out.servings = std::stoll(servings->number, &used);
            if (used != servings->number.size()) {
                throw std::out_of_range("servings");
            }
        } catch (...) {
            error = "Could not parse recipe JSON: field \"servings\" "
                    "is out of range.";
            return false;
        }
    }
    const Value* image = find_field(value, "image_path");
    out.image_path.clear();
    if (image != nullptr) {
        if (image->type == Value::Type::Null) {
            out.image_path.clear();
        } else if (image->type == Value::Type::String) {
            out.image_path = image->str;
        } else {
            error = "Could not parse recipe JSON: field \"image_path\" "
                    "must be a string or null.";
            return false;
        }
    }
    out.ingredients.clear();
    const Value* ingredients = find_field(value, "ingredients");
    if (ingredients != nullptr) {
        if (ingredients->type != Value::Type::Array) {
            error = "Could not parse recipe JSON: field \"ingredients\" "
                    "must be an array.";
            return false;
        }
        for (const Value& item : ingredients->array) {
            if (item.type != Value::Type::Object) {
                error = "Could not parse recipe JSON: each ingredient "
                        "must be an object.";
                return false;
            }
            ImportedIngredient ingredient;
            if (!string_field(item, "amount", ingredient.amount, error) ||
                !string_field(item, "unit", ingredient.unit, error) ||
                !string_field(item, "name", ingredient.name, error)) {
                return false;
            }
            out.ingredients.push_back(std::move(ingredient));
        }
    }
    out.steps.clear();
    const Value* steps = find_field(value, "steps");
    if (steps != nullptr) {
        if (steps->type != Value::Type::Array) {
            error = "Could not parse recipe JSON: field \"steps\" must "
                    "be an array.";
            return false;
        }
        for (const Value& item : steps->array) {
            if (item.type != Value::Type::String) {
                error = "Could not parse recipe JSON: each step must "
                        "be a string.";
                return false;
            }
            out.steps.push_back(item.str);
        }
    }
    return true;
}

bool parse_recipe_list(const std::vector<Value>& items,
                       std::vector<ImportedRecipe>& out,
                       std::string& error) {
    for (const Value& item : items) {
        ImportedRecipe recipe;
        if (!parse_one_recipe(item, recipe, error)) {
            return false;
        }
        out.push_back(std::move(recipe));
    }
    return true;
}

// --- HTTP fetching (http:// only) ---

struct HttpUrl {
    std::string host;
    int port = 80;
    std::string path;
};

bool parse_http_url(const std::string& url, HttpUrl& out,
                    std::string& error) {
    if (url.rfind("https://", 0) == 0) {
        error = "HTTPS URLs are not supported by this importer; use "
                "an http:// URL (for example, the local test "
                "server).";
        return false;
    }
    if (url.rfind("http://", 0) != 0) {
        error = "URL must start with http://.";
        return false;
    }
    std::string rest = url.substr(7);
    size_t slash = rest.find('/');
    std::string host_port =
        slash == std::string::npos ? rest : rest.substr(0, slash);
    out.path = slash == std::string::npos ? "/" : rest.substr(slash);
    if (host_port.empty()) {
        error = "URL is missing a host.";
        return false;
    }
    size_t colon = host_port.rfind(':');
    out.host = host_port;
    out.port = 80;
    if (colon != std::string::npos) {
        std::string port_text = host_port.substr(colon + 1);
        if (port_text.empty()) {
            error = "URL is missing a host.";
            return false;
        }
        try {
            size_t used = 0;
            long port = std::stol(port_text, &used);
            if (used != port_text.size() || port < 1 || port > 65535) {
                throw std::out_of_range("port");
            }
            out.port = static_cast<int>(port);
        } catch (...) {
            error = "Invalid port in URL: " + port_text + ".";
            return false;
        }
        out.host = host_port.substr(0, colon);
    }
    if (out.host.empty()) {
        error = "URL is missing a host.";
        return false;
    }
    return true;
}

std::string lowercased(std::string text) {
    for (char& c : text) {
        c = static_cast<char>(
            std::tolower(static_cast<unsigned char>(c)));
    }
    return text;
}

// Decode a chunked transfer-encoding body: hex size lines (with
// optional ";extension" suffixes), data, CRLF, repeated, ending
// with a zero-size chunk and trailing headers up to a blank line.
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
        size_t semi = size_text.find(';');
        if (semi != std::string::npos) {
            size_text = size_text.substr(0, semi);
        }
        size_text = trimmed(size_text);
        size_t size = 0;
        try {
            size_t used = 0;
            size = std::stoul(size_text, &used, 16);
            if (used != size_text.size()) {
                throw std::invalid_argument("chunk size");
            }
        } catch (...) {
            error = "Malformed chunked response.";
            return false;
        }
        pos = line_end + 2;
        if (size == 0) {
            return true;
        }
        if (body.size() - pos < size + 2) {
            error = "Truncated chunked response.";
            return false;
        }
        out.append(body, pos, size);
        pos += size + 2;
    }
}

// Connect with a 10s timeout, then set 30s read/write timeouts.
bool connect_with_timeout(const std::string& host, int port, int& sock,
                          std::string& error) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* addresses = nullptr;
    std::string port_text = std::to_string(port);
    int rc = getaddrinfo(host.c_str(), port_text.c_str(), &hints,
                         &addresses);
    if (rc != 0) {
        error = "Could not resolve " + host + ": " + gai_strerror(rc);
        return false;
    }
    bool connected = false;
    for (addrinfo* ai = addresses; ai != nullptr; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            continue;
        }
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int result = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (result < 0 && errno == EINPROGRESS) {
            fd_set writers;
            FD_ZERO(&writers);
            FD_SET(fd, &writers);
            timeval timeout{};
            timeout.tv_sec = 10;
            int ready = select(fd + 1, nullptr, &writers, nullptr,
                               &timeout);
            if (ready > 0) {
                int sock_error = 0;
                socklen_t len = sizeof(sock_error);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &sock_error, &len);
                result = sock_error == 0 ? 0 : -1;
            } else {
                result = -1;  // Timeout, or select error.
            }
        }
        fcntl(fd, F_SETFL, flags);
        if (result == 0) {
            timeval timeout{};
            timeout.tv_sec = 30;
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       sizeof(timeout));
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                       sizeof(timeout));
            sock = fd;
            connected = true;
            break;
        }
        close(fd);
    }
    freeaddrinfo(addresses);
    if (!connected) {
        error = "Could not connect to " + host + ".";
        return false;
    }
    return true;
}

bool send_all(int sock, const std::string& data, std::string& error) {
    size_t sent = 0;
    while (sent < data.size()) {
        ssize_t n = send(sock, data.data() + sent, data.size() - sent, 0);
        if (n <= 0) {
            error = "Could not send request.";
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

enum class FetchOutcome { Body, Redirect };

bool fetch_once(const HttpUrl& url, FetchOutcome& outcome,
                std::string& body_or_location, std::string& error) {
    int sock = -1;
    if (!connect_with_timeout(url.host, url.port, sock, error)) {
        return false;
    }
    std::string host_header = url.port == 80
        ? url.host
        : url.host + ":" + std::to_string(url.port);
    std::string request = "GET " + url.path + " HTTP/1.1\r\nHost: " +
        host_header +
        "\r\nConnection: close\r\nUser-Agent: recipe-manager-test\r\n"
        "Accept: application/json\r\n\r\n";
    if (!send_all(sock, request, error)) {
        close(sock);
        return false;
    }
    std::string raw;
    char buffer[8192];
    while (true) {
        ssize_t n = recv(sock, buffer, sizeof(buffer), 0);
        if (n < 0) {
            error = "Could not read response.";
            close(sock);
            return false;
        }
        if (n == 0) {
            break;
        }
        raw.append(buffer, static_cast<size_t>(n));
    }
    close(sock);

    size_t header_end = raw.find("\r\n\r\n");
    if (header_end == std::string::npos) {
        error = "Response was not valid HTTP.";
        return false;
    }
    std::string headers = raw.substr(0, header_end);
    size_t first_line_end = headers.find("\r\n");
    std::string status_line = first_line_end == std::string::npos
        ? headers
        : headers.substr(0, first_line_end);
    // Status is the second whitespace-separated token.
    size_t first_space = status_line.find(' ');
    size_t second_space = first_space == std::string::npos
        ? std::string::npos
        : status_line.find(' ', first_space + 1);
    int status = 0;
    try {
        std::string code = status_line.substr(
            first_space + 1,
            (second_space == std::string::npos
                 ? std::string::npos
                 : second_space - first_space - 1));
        size_t used = 0;
        status = std::stoi(code, &used);
        if (used != code.size()) {
            throw std::invalid_argument("status");
        }
    } catch (...) {
        error = "Response was not valid HTTP.";
        return false;
    }
    std::string location;
    bool chunked = false;
    bool has_length = false;
    size_t content_length = 0;
    size_t line_start = first_line_end == std::string::npos
        ? headers.size()
        : first_line_end + 2;
    while (line_start < headers.size()) {
        size_t line_end = headers.find("\r\n", line_start);
        if (line_end == std::string::npos) {
            line_end = headers.size();
        }
        std::string line = headers.substr(line_start,
                                          line_end - line_start);
        size_t colon = line.find(':');
        if (colon != std::string::npos) {
            std::string name = lowercased(trimmed(line.substr(0, colon)));
            std::string value = trimmed(line.substr(colon + 1));
            if (name == "location") {
                location = value;
            } else if (name == "transfer-encoding" &&
                       lowercased(value).find("chunked") !=
                           std::string::npos) {
                chunked = true;
            } else if (name == "content-length") {
                try {
                    size_t used = 0;
                    content_length = std::stoul(value, &used);
                    has_length = used == value.size();
                } catch (...) {
                    has_length = false;
                }
            }
        }
        line_start = line_end + 2;
    }
    if ((status == 301 || status == 302 || status == 303 ||
         status == 307 || status == 308) &&
        !location.empty()) {
        outcome = FetchOutcome::Redirect;
        body_or_location = location;
        return true;
    }
    if (status != 200) {
        error = "Server returned HTTP " + std::to_string(status) +
                " for " + url.host + ":" + std::to_string(url.port) + ".";
        return false;
    }
    std::string body_bytes = raw.substr(header_end + 4);
    if (chunked) {
        if (!decode_chunked(body_bytes, body_or_location, error)) {
            return false;
        }
    } else if (has_length) {
        if (body_bytes.size() < content_length) {
            error = "Response ended before the full body arrived.";
            return false;
        }
        body_or_location = body_bytes.substr(0, content_length);
    } else {
        body_or_location = body_bytes;
    }
    outcome = FetchOutcome::Body;
    return true;
}

std::string resolve_redirect(const HttpUrl& current,
                             const std::string& location) {
    if (location.rfind("http://", 0) == 0 ||
        location.rfind("https://", 0) == 0) {
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
    std::string base = slash == std::string::npos
        ? "/"
        : current.path.substr(0, slash + 1);
    return "http://" + host + base + location;
}

}  // namespace

bool parse_recipes(const std::string& text,
                   std::vector<ImportedRecipe>& out, std::string& error) {
    if (!valid_utf8(text)) {
        error = "Could not parse recipe JSON: response was not "
                "valid UTF-8.";
        return false;
    }
    Value root;
    Parser parser(text, error);
    if (!parser.parse(root)) {
        return false;
    }
    std::vector<ImportedRecipe> parsed;
    if (root.type == Value::Type::Array) {
        if (!parse_recipe_list(root.array, parsed, error)) {
            return false;
        }
    } else if (root.type == Value::Type::Object) {
        const Value* recipes = find_field(root, "recipes");
        if (recipes != nullptr) {
            if (recipes->type != Value::Type::Array) {
                error = "Could not parse recipe JSON: the \"recipes\" "
                        "field must be an array of recipes.";
                return false;
            }
            if (!parse_recipe_list(recipes->array, parsed, error)) {
                return false;
            }
        } else if (find_field(root, "title") != nullptr) {
            ImportedRecipe recipe;
            if (!parse_one_recipe(root, recipe, error)) {
                return false;
            }
            parsed.push_back(std::move(recipe));
        } else {
            error = "Could not parse recipe JSON: JSON must be a "
                    "single recipe, an array of recipes, or an "
                    "object with a \"recipes\" array.";
            return false;
        }
    } else {
        error = "Could not parse recipe JSON: JSON must be a single "
                "recipe, an array of recipes, or an object with a "
                "\"recipes\" array.";
        return false;
    }
    out = std::move(parsed);
    return true;
}

bool fetch_url(const std::string& url, std::string& body,
               std::string& error) {
    std::string current = url;
    for (int attempt = 0; attempt < 4; ++attempt) {
        HttpUrl parsed;
        if (!parse_http_url(current, parsed, error)) {
            return false;
        }
        FetchOutcome outcome;
        std::string result;
        if (!fetch_once(parsed, outcome, result, error)) {
            return false;
        }
        if (outcome == FetchOutcome::Body) {
            body = result;
            return true;
        }
        current = resolve_redirect(parsed, result);
    }
    error = "Too many redirects.";
    return false;
}

bool fetch_and_parse(const std::string& url,
                     std::vector<ImportedRecipe>& out,
                     std::string& error) {
    std::string body;
    if (!fetch_url(url, body, error)) {
        return false;
    }
    return parse_recipes(body, out, error);
}
