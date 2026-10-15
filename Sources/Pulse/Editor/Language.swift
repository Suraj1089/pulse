import Foundation

enum TokenKind {
    case keyword, string, comment, type, number, attribute
}

/// A language is one combined regular expression whose alternatives are tried
/// left to right, so comments and strings win over keywords inside them.
/// That single pass is what keeps highlighting cheap.
struct Language {
    let name: String
    let lineComment: String?
    let rules: [(pattern: String, kind: TokenKind)]

    // MARK: Building blocks

    private static func words(_ list: String) -> String {
        let escaped = list.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        return "\\b(?:" + escaped.joined(separator: "|") + ")\\b"
    }

    private static let cBlockComment = "/\\*[\\s\\S]*?(?:\\*/|\\z)"
    private static let slashComment = "//[^\\n]*"
    private static let hashComment = "#[^\\n]*"
    private static let doubleQuoted = "\"(?:[^\"\\\\\\n]|\\\\.)*\"?"
    private static let singleQuoted = "'(?:[^'\\\\\\n]|\\\\.)*'?"
    private static let backtick = "`(?:[^`\\\\]|\\\\.)*`?"
    private static let tripleDouble = "\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"
    private static let tripleSingle = "'''[\\s\\S]*?(?:'''|\\z)"
    private static let number = "\\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b"
    private static let capitalized = "\\b[A-Z][A-Za-z0-9_]*\\b"

    // MARK: Languages

    static let swift = Language(name: "Swift", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (tripleDouble, .string), (doubleQuoted, .string),
        ("@\\w+", .attribute), ("#\\w+", .attribute),
        (words("actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in indirect init inout internal is lazy let mutating nil nonisolated open operator override private protocol public repeat required rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while unowned convenience dynamic get set willSet didSet"), .keyword),
        (capitalized, .type), (number, .number),
    ])

    static let javascript = Language(name: "JavaScript", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (backtick, .string), (doubleQuoted, .string), (singleQuoted, .string),
        ("@\\w+", .attribute),
        (words("abstract as async await break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let namespace new null of private protected public readonly return set static super switch this throw true try type typeof undefined var void while with yield"), .keyword),
        (capitalized, .type), (number, .number),
    ])

    static let python = Language(name: "Python", lineComment: "#", rules: [
        (hashComment, .comment),
        (tripleDouble, .string), (tripleSingle, .string), (doubleQuoted, .string), (singleQuoted, .string),
        ("@[\\w.]+", .attribute),
        (words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda match case None nonlocal not or pass raise return self True try while with yield"), .keyword),
        (capitalized, .type), (number, .number),
    ])

    static let go = Language(name: "Go", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (backtick, .string), (doubleQuoted, .string), (singleQuoted, .string),
        (words("break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var"), .keyword),
        (words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any"), .type),
        (capitalized, .type), (number, .number),
    ])

    static let rust = Language(name: "Rust", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (doubleQuoted, .string),
        ("#!?\\[[^\\]\\n]*\\]", .attribute), ("\\b\\w+!", .attribute),
        (words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"), .keyword),
        (words("bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize"), .type),
        (capitalized, .type), (number, .number),
    ])

    static let cFamily = Language(name: "C", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        ("^\\s*#\\s*\\w+", .attribute), ("@\\w+", .attribute),
        (words("auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend goto if inline int long namespace new nullptr operator private protected public return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while self super nil YES NO id instancetype"), .keyword),
        (capitalized, .type), (number, .number),
    ])

    static let java = Language(name: "Java", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (tripleDouble, .string), (doubleQuoted, .string), (singleQuoted, .string),
        ("@\\w+", .attribute),
        (words("abstract boolean break byte case catch char class const continue data default do double else enum extends false final finally float for fun if implements import in instanceof int interface is long native new null object override package private protected public return short static super switch this throw throws true try val var void when while"), .keyword),
        (capitalized, .type), (number, .number),
    ])

    static let shell = Language(name: "Shell", lineComment: "#", rules: [
        (hashComment, .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        ("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", .attribute),
        (words("if then else elif fi for in do done while until case esac function return export local readonly set unset source exit echo"), .keyword),
        (number, .number),
    ])

    static let ruby = Language(name: "Ruby", lineComment: "#", rules: [
        (hashComment, .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        (":[A-Za-z_]\\w*", .attribute), ("@{1,2}\\w+", .attribute),
        (words("alias and begin break case class def do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require"), .keyword),
        (capitalized, .type), (number, .number),
    ])

    static let json = Language(name: "JSON", lineComment: nil, rules: [
        ("\"(?:[^\"\\\\\\n]|\\\\.)*\"(?=\\s*:)", .attribute),
        (doubleQuoted, .string),
        (words("true false null"), .keyword),
        ("-?" + number, .number),
    ])

    static let yaml = Language(name: "YAML", lineComment: "#", rules: [
        (hashComment, .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        ("^\\s*-?\\s*[\\w.\\-\"']+(?=\\s*:)", .attribute),
        (words("true false null yes no on off"), .keyword),
        (number, .number),
    ])

    static let toml = Language(name: "TOML", lineComment: "#", rules: [
        (hashComment, .comment),
        (tripleDouble, .string), (doubleQuoted, .string), (singleQuoted, .string),
        ("^\\s*\\[[^\\]\\n]*\\]", .keyword),
        ("^\\s*[\\w.\\-\"]+(?=\\s*=)", .attribute),
        (words("true false"), .keyword),
        (number, .number),
    ])

    static let markup = Language(name: "HTML", lineComment: nil, rules: [
        ("<!--[\\s\\S]*?(?:-->|\\z)", .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        ("</?[A-Za-z][\\w:.-]*", .keyword), ("/?>", .keyword),
        ("\\b[\\w:-]+(?==)", .attribute),
        ("&\\w+;", .number),
    ])

    static let css = Language(name: "CSS", lineComment: nil, rules: [
        (cBlockComment, .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        ("@[\\w-]+", .keyword),
        ("[\\w-]+(?=\\s*:[^;{}]*[;}])", .attribute),
        ("#[0-9A-Fa-f]{3,8}\\b", .number),
        ("-?\\d*\\.?\\d+(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\\b", .number),
    ])

    static let markdown = Language(name: "Markdown", lineComment: nil, rules: [
        ("^```[\\s\\S]*?(?:^```|\\z)", .string),
        ("`[^`\\n]+`", .string),
        ("^#{1,6} [^\\n]*", .keyword),
        ("^\\s*(?:[-*+]|\\d+\\.) ", .attribute),
        ("\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", .type),
        ("\\*\\*[^*\\n]+\\*\\*", .number),
    ])

    static let sql = Language(name: "SQL", lineComment: "--", rules: [
        ("--[^\\n]*", .comment), (cBlockComment, .comment),
        (singleQuoted, .string), (doubleQuoted, .string),
        ("(?i)\\b(?:select|from|where|insert|into|values|update|set|delete|create|table|index|view|drop|alter|add|join|left|right|inner|outer|on|group|by|order|having|limit|offset|as|and|or|not|null|is|in|like|primary|key|foreign|references|default|unique|distinct|union|all|case|when|then|else|end|begin|commit|returning)\\b", .keyword),
        (number, .number),
    ])

    // MARK: Detection

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        let table: [(String, Language)] = [
            ("swift", swift),
            ("js mjs cjs jsx ts tsx mts cts", javascript),
            ("py pyi", python),
            ("go", go),
            ("rs", rust),
            ("c h cc cpp cxx hpp hh m mm", cFamily),
            ("java kt kts scala dart cs", java),
            ("sh bash zsh fish", shell),
            ("rb", ruby),
            ("json jsonc", json),
            ("yml yaml", yaml),
            ("toml", toml),
            ("html htm xml svg plist vue", markup),
            ("css scss less", css),
            ("md markdown", markdown),
            ("sql", sql),
        ]
        for (extensions, language) in table {
            for ext in extensions.split(separator: " ") { map[String(ext)] = language }
        }
        return map
    }()

    private static let byFileName: [String: Language] = [
        "Makefile": shell, "Dockerfile": shell, "Gemfile": ruby, "Rakefile": ruby,
        ".zshrc": shell, ".bashrc": shell, ".profile": shell, ".gitignore": shell, ".env": shell,
        "Package.resolved": json,
    ]

    static func detect(url: URL?) -> Language? {
        guard let url else { return nil }
        if let match = byFileName[url.lastPathComponent] { return match }
        return byExtension[url.pathExtension.lowercased()]
    }
}
