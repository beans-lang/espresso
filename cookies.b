// Cookies: reading the request's `Cookie` header, and building a `Set-Cookie`
// value that cannot be forged from its own inputs.
//
// The write side is the part that matters. A `Set-Cookie` value is a
// semicolon-separated list, so a name or a value carrying `;` writes an
// attribute the caller never asked for — `Secure` off, `Path=/`, a second
// cookie — and a value carrying CR or LF splices whole headers into the
// response. Both are refused here, at the call that sets the cookie and names
// the cookie, rather than later by the response encoder naming a header block.
// `http.field_is_safe` is the CR/LF/NUL rule std.http already applies to every
// field it writes; this file adds the cookie grammar on top of it and does not
// restate it.
package espresso

import std.http

/// The `SameSite` attribute, as the three values a browser understands. It is
/// an enum and not a string precisely so nothing a request carried can ever
/// end up spelling an attribute.
pub enum SameSite {
    /// Sent on same-site requests and on top-level cross-site navigations.
    /// The default, and what a session cookie wants.
    lax
    /// Sent only on same-site requests. A link from another site arrives
    /// logged out, which is correct for an admin surface and surprising for
    /// a content one.
    strict
    /// Sent on every request. A browser refuses it without `Secure`, so
    /// `set_cookie` refuses it here too rather than letting the cookie
    /// silently vanish.
    none
}

/// The attributes of one `Set-Cookie`, with safe defaults: path `/`,
/// `HttpOnly`, `Secure`, `SameSite=Lax`, and no `Max-Age` (a session cookie
/// the browser drops when it closes).
///
/// `secure` defaults to **true**. A plain-http development server must set it
/// to false: Chrome and Firefox accept a `Secure` cookie from
/// `http://localhost`, Safari does not, and a cookie a browser drops is a
/// login that silently never happens. Defaulting the other way would ship the
/// insecure choice to everyone who never thought about it.
pub class CookieOptions {
    /// The path prefix the cookie is sent for. `""` omits the attribute,
    /// which makes the browser scope it to the current directory — almost
    /// never what an application wants, which is why the default is `/`.
    pub path: string = "/"
    /// The domain the cookie is sent to, including subdomains. Empty omits
    /// the attribute, which scopes the cookie to the exact host that set it —
    /// the narrower and safer choice.
    pub domain: string = ""
    /// Lifetime in seconds. Negative omits `Max-Age` entirely, making it a
    /// session cookie; `0` tells the browser the cookie has already expired,
    /// which is how a cookie is deleted.
    pub max_age_seconds: int = -1
    /// Keeps the cookie out of `document.cookie`. On by default: a session
    /// token script can read is a session token XSS can steal.
    pub http_only: bool = true
    /// Sends the cookie only over TLS. On by default; see the class note.
    pub secure: bool = true
    pub same_site: SameSite = SameSite.lax

    pub fn init() {}
}

fn same_site_text(value: SameSite) -> string {
    return match value {
        lax => "Lax",
        strict => "Strict",
        none => "None",
    }
}

// RFC 6265 cookie-name is an RFC 9110 token: letters, digits, and the
// `!#$%&'*+-.^_`|~` marks. Excluding only `=` and `;` would still admit a
// space or a comma, which different browsers split differently.
fn cookie_name_is_safe(name: string) -> bool {
    if name.len() == 0 { return false }
    for index: int in 0..name.len() {
        let byte: int = name.byte_at(index)
        let alpha: bool =
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        let digit: bool = byte >= 48 && byte <= 57
        let mark: bool =
            byte == 33 || byte == 35 || byte == 36 || byte == 37 ||
            byte == 38 || byte == 39 || byte == 42 || byte == 43 ||
            byte == 45 || byte == 46 || byte == 94 || byte == 95 ||
            byte == 96 || byte == 124 || byte == 126
        if !alpha && !digit && !mark { return false }
    }
    return true
}

// RFC 6265 cookie-octet: printable US-ASCII without space, `"`, `,`, `;` and
// `\`. An empty value is legal and means the cookie is present and empty.
//
// This is stricter than base64 or hex needs, and deliberately so: it is the
// set every browser agrees on, and it is closed under the round trip this
// package promises — a value that goes out through `set_cookie` comes back
// from `cookie()` byte for byte, because nothing was encoded on the way out
// and nothing is decoded on the way in.
fn cookie_value_is_safe(value: string) -> bool {
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        if byte == 33 { continue }
        if byte >= 35 && byte <= 43 { continue }
        if byte >= 45 && byte <= 58 { continue }
        if byte >= 60 && byte <= 91 { continue }
        if byte >= 93 && byte <= 126 { continue }
        return false
    }
    return true
}

// An attribute's free text — a path, a domain. std.http's field_is_safe is
// the CR/LF/NUL rule every written field obeys; a semicolon on top of it
// would end the attribute and start another one.
fn cookie_attribute_is_safe(text: string) -> bool {
    if !http.field_is_safe(text) { return false }
    return !text.contains(";") && !text.contains(",")
}

/// Builds one `Set-Cookie` field value, or says which input it refused.
///
/// Every refusal names the cookie, because the caller wrote the name and can
/// find it; none of them can reach the wire, because none of them are
/// serialized.
pub fn set_cookie_value(name: string,
                        value: string,
                        options: CookieOptions) -> Result<string> {
    if !cookie_name_is_safe(name) {
        return err(
            "cookie name '{name}' is not a token: a cookie name is letters, digits and !#$%&'*+-.^_`|~",
            "cookie")
    }
    if !cookie_value_is_safe(value) {
        return err(
            "the value of cookie '{name}' carries a byte a Set-Cookie header cannot hold: space, comma, semicolon, backslash, double quote and control bytes are all excluded",
            "cookie")
    }
    if !cookie_attribute_is_safe(options.path) {
        return err(
            "the Path of cookie '{name}' carries a semicolon, comma or control byte",
            "cookie")
    }
    if !cookie_attribute_is_safe(options.domain) {
        return err(
            "the Domain of cookie '{name}' carries a semicolon, comma or control byte",
            "cookie")
    }
    if options.same_site == SameSite.none && !options.secure {
        return err(
            "cookie '{name}' asks for SameSite=None without Secure; a browser drops such a cookie, so this would be a login that silently never happens",
            "cookie")
    }
    var built: string = "{name}={value}"
    if options.path != "" { built = "{built}; Path={options.path}" }
    if options.domain != "" { built = "{built}; Domain={options.domain}" }
    if options.max_age_seconds >= 0 {
        built = "{built}; Max-Age={options.max_age_seconds}"
    }
    if options.http_only { built = "{built}; HttpOnly" }
    if options.secure { built = "{built}; Secure" }
    return ok("{built}; SameSite={same_site_text(options.same_site)}")
}

// Folds every `Cookie` header of a request into `target`, in the order the
// client sent them.
//
// RFC 6265 §5.4 says a client sends one `Cookie` header, but HTTP/2 permits
// splitting it and proxies do rejoin it, so every occurrence is read. A piece
// with no `=`, or with an empty name, is skipped rather than guessed at — the
// permissive read every server does, and the only one under which a lookup by
// name means anything.
//
// Nothing is decoded. A cookie value is opaque bytes to RFC 6265; percent-
// decoding it here would corrupt any value that legitimately contains `%`,
// and it would break the round trip `set_cookie` promises.
fn parse_cookies_into(headers: http.Headers, target: QueryValues) {
    target.clear()
    for header: string in headers.all("Cookie") {
        for piece: string in header.split(";") {
            var start: int = 0
            var end: int = piece.len()
            for start < end {
                let byte: int = piece.byte_at(start)
                if byte != 32 && byte != 9 { break }
                start += 1
            }
            for end > start {
                let byte: int = piece.byte_at(end - 1)
                if byte != 32 && byte != 9 { break }
                end -= 1
            }
            if start >= end { continue }
            let trimmed: string = piece.slice(start, end)
            match trimmed.find("=") {
                some(at) => {
                    if at == 0 { continue }
                    target.add(trimmed.slice(0, at),
                               trimmed.slice(at + 1, trimmed.len()))
                }
                none => {}
            }
        }
    }
}
