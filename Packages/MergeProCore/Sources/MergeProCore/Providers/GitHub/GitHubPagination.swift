import Foundation

/// RFC 8288 `Link` header pagination shared by every GitHub REST list reader.
///
/// Parsing follows RFC 8288 §3: comma-separated link-values, each a `<target>` followed by
/// `;`-separated parameters. Commas and semicolons inside `<…>` or a quoted string never split.
/// `rel` may be quoted or a bare token and may carry several space-separated relation types
/// (`rel="next last"`); relation types compare case-insensitively and only the first `rel` counts.
///
/// Following a continuation applies one validation for every caller: an absolute target at the API
/// origin (`GitHubHTTPClient.isSafeAPIURL`: HTTPS, same host and port, no user or password), on the
/// requested list's path or, when the caller pins a repository ID, GitHub's `/repositories/{id}/…`
/// form of it. Several `next` links must agree; any unsafe one rejects the page.
enum GitHubPagination {
    struct Link: Equatable, Sendable {
        /// Text between `<` and `>`; nil when the link-value has no bracketed target.
        let target: String?
        /// Relation types, lowercased.
        let relations: Set<String>
    }

    static func links(_ header: String?) -> [Link] {
        guard let header, !header.isEmpty else { return [] }
        return split(header, on: ",").compactMap { value in
            let parts = split(value, on: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, !(parts.count == 1 && first.isEmpty) else { return nil }
            let target = first.count >= 2 && first.hasPrefix("<") && first.hasSuffix(">") ? String(first.dropFirst().dropLast()) : nil
            var relations: Set<String> = []
            // Without a bracketed target the first part may itself be a parameter (`rel="next"` alone).
            for parameter in target == nil ? parts[...] : parts.dropFirst() {
                guard let equals = parameter.firstIndex(of: "="),
                      parameter[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "rel" else { continue }
                var value = parameter[parameter.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                relations = Set(value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.lowercased() })
                break
            }
            return Link(target: target, relations: relations)
        }
    }

    /// Hint for readers that build their own continuation (a page number at the trusted origin) and
    /// never follow the provider's URL. Only a `next` relation counts (even with a malformed target);
    /// a link-value naming no `next` is never a continuation, so these readers cannot page forever on it.
    static func hasNext(_ header: String?) -> Bool {
        links(header).contains { $0.relations.contains("next") }
    }

    /// The validated continuation URL, or nil on the last page. Throws `GitHubFailure.unsafeURL` for a
    /// `next` link that is malformed, relative, off-origin, carries credentials, leaves the requested
    /// path (or pinned repository), or disagrees with another `next` link.
    static func next(_ header: String?, client: GitHubHTTPClient, requested: URL, repositoryID: String? = nil) throws -> URL? {
        var result: URL?
        for link in links(header) where link.relations.contains("next") {
            guard let target = link.target, let url = URL(string: target), url.scheme != nil,
                  client.isSafeAPIURL(url),
                  GitHubHTTPClient.samePaginatedPath(url, as: requested, repositoryID: repositoryID),
                  result == nil || result == url else { throw GitHubFailure.unsafeURL }
            result = url
        }
        return result
    }

    /// Splits on `separator` outside `<…>` and outside quoted strings (with backslash escapes). A `<`
    /// opens a target only at the start of a piece (a link-value, or its leading target before the first
    /// `;`): a stray `<` inside a parameter value never swallows the rest of the header.
    private static func split(_ text: some StringProtocol, on separator: Character) -> [String] {
        var pieces: [String] = [], piece = "", inTarget = false, quoted = false, escaped = false
        for character in text {
            if quoted {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
            } else if inTarget {
                if character == ">" { inTarget = false }
            } else if character == "<", piece.allSatisfy(\.isWhitespace) { inTarget = true }
            else if character == "\"" { quoted = true }
            else if character == separator { pieces.append(piece); piece = ""; continue }
            piece.append(character)
        }
        pieces.append(piece)
        return pieces
    }
}
