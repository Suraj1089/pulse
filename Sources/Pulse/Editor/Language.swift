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
    /// Go to Definition: lines that define a name ("{name}"; "{word}" is the
    /// name as a whole word), looked for in every file of the language.
    /// Written in the syntax ripgrep, git grep -E and NSRegularExpression
    /// share: no \b, \s or (?:), and a literal tab in [ \t]. Variables count
    /// here at the top level or one level in (properties, constants).
    var definitions: [String] = []
    /// Variables anywhere, such as a function's locals: only in the file being edited.
    var locals: [String] = []

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
    ], definitions: [
        "^[ \t]*(@[[:alnum:]_]+(\\([^)\\n]*\\))?[ \t]+)*([a-z]+(\\([a-z]+\\))?[ \t]+)*(func|class|struct|enum|protocol|actor|typealias|associatedtype|case)[ \t]+{word}",
        "^( {0,4}|\t)(@[[:alnum:]_]+(\\([^)\\n]*\\))?[ \t]+)*([a-z]+(\\([a-z]+\\))?[ \t]+)*(let|var)[ \t]+{word}",
    ], locals: [
        "^[ \t]*([a-z]+[ \t]+)*(let|var)[ \t]+{word}",
        "^[ \t]*for[ \t]+(case[ \t]+)?(let[ \t]+)?{word}",
    ])

    static let javascript = Language(name: "JavaScript", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (backtick, .string), (doubleQuoted, .string), (singleQuoted, .string),
        ("@\\w+", .attribute),
        (words("abstract as async await break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let namespace new null of private protected public readonly return set static super switch this throw true try type typeof undefined var void while with yield"), .keyword),
        (capitalized, .type), (number, .number),
    ], definitions: [
        "^[ \t]*([a-z]+[ \t]+)*(function\\*?|class|interface|type|enum|namespace)[ \t]+{word}",
        "^( {0,4}|\t)([a-z]+[ \t]+)*(const|let|var)[ \t]+{word}",
        // A method: its line ends with the "{" that opens its body.
        "^[ \t]+([a-z]+[ \t]+)*{name}[ \t]*(<[^>\\n]*>)?\\([^)\\n]*\\)[^;\\n]*[{][ \t]*$",
    ], locals: [
        "^[ \t]*([a-z]+[ \t]+)*(const|let|var)[ \t]+{word}",
        "^[ \t]*for[ \t]*\\([ \t]*(const|let|var)[ \t]+{word}",
    ])

    static let python = Language(name: "Python", lineComment: "#", rules: [
        (hashComment, .comment),
        (tripleDouble, .string), (tripleSingle, .string), (doubleQuoted, .string), (singleQuoted, .string),
        ("@[\\w.]+", .attribute),
        (words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda match case None nonlocal not or pass raise return self True try while with yield"), .keyword),
        (capitalized, .type), (number, .number),
    ], definitions: [
        "^[ \t]*(async[ \t]+)?(def|class)[ \t]+{word}",
        "^( {0,4}|\t){name}[ \t]*(:[^=\\n]*)?=([^=]|$)",
        "^[ \t]*self\\.{name}[ \t]*(:[^=\\n]*)?=([^=]|$)",
    ], locals: [
        "^[ \t]*{name}[ \t]*(:[^=\\n]*)?=([^=]|$)",
        "^[ \t]*(async[ \t]+)?for[ \t]+{word}",
        "^[ \t]*(async[ \t]+)?(with|except)[ \t].*[ \t]as[ \t]+{word}",
    ])

    static let go = Language(name: "Go", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (backtick, .string), (doubleQuoted, .string), (singleQuoted, .string),
        (words("break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var"), .keyword),
        (words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any"), .type),
        (capitalized, .type), (number, .number),
    ], definitions: [
        "^func[ \t]+(\\([^)\\n]*\\)[ \t]*)?{word}",
        "^[ \t]*type[ \t]+{word}",
        "^( {0,4}|\t)(var|const)[ \t]+{word}",
    ], locals: [
        "^[ \t]*([[:alnum:]_]+[ \t]*,[ \t]*)*{name}([ \t]*,[ \t]*[[:alnum:]_]+)*[ \t]*:=",
        "^[ \t]*(var|const)[ \t]+{word}",
    ])

    static let rust = Language(name: "Rust", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (doubleQuoted, .string),
        ("#!?\\[[^\\]\\n]*\\]", .attribute), ("\\b\\w+!", .attribute),
        (words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"), .keyword),
        (words("bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize"), .type),
        (capitalized, .type), (number, .number),
    ], definitions: [
        "^[ \t]*(pub(\\([^)\\n]*\\))?[ \t]+)?([a-z]+[ \t]+)*(fn|struct|enum|trait|type|mod|union|const|static)[ \t]+{word}",
        "^[ \t]*macro_rules![ \t]*{word}",
    ], locals: [
        "^[ \t]*let[ \t]+(mut[ \t]+)?{word}",
    ])

    static let cFamily = Language(name: "C", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        ("^\\s*#\\s*\\w+", .attribute), ("@\\w+", .attribute),
        (words("auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend goto if inline int long namespace new nullptr operator private protected public return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while self super nil YES NO id instancetype"), .keyword),
        (capitalized, .type), (number, .number),
    ], definitions: [
        "^[ \t]*#[ \t]*define[ \t]+{word}",
        "^[ \t]*(typedef[ \t]+)?(struct|class|union|enum|namespace)[ \t]+(class[ \t]+)?{word}",
        "^[ \t]*[}][ \t]*{name}[ \t]*;",
        // A function body at the left margin: a return type, the name and "(",
        // and no ";" (that would be a declaration).
        "^[A-Za-z_][[:alnum:]_ \t*:<>,]*[ \t*:]{name}[ \t]*\\([^;\\n]*$",
        "^[ \t]*[-+][ \t]*\\([^)\\n]*\\)[ \t]*{word}",
        "^@(interface|implementation|protocol)[ \t]+{word}",
    ])

    static let java = Language(name: "Java", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
        (tripleDouble, .string), (doubleQuoted, .string), (singleQuoted, .string),
        ("@\\w+", .attribute),
        (words("abstract boolean break byte case catch char class const continue data default do double else enum extends false final finally float for fun if implements import in instanceof int interface is long native new null object override package private protected public return short static super switch this throw throws true try val var void when while"), .keyword),
        (capitalized, .type), (number, .number),
    ], definitions: [
        "^[ \t]*(@[[:alnum:]_.]+(\\([^)\\n]*\\))?[ \t]+)*([a-z]+[ \t]+)*(class|interface|enum|record|object|trait|struct|def|typealias)[ \t]+{word}",
        "^[ \t]*([a-z]+[ \t]+)*fun[ \t]+(<[^>\\n]*>[ \t]*)?([[:alnum:]_<>?]+\\.)?{word}",
        // A method: a return type, the name and "(", and no ";".
        "^[ \t]+(@[[:alnum:]_.]+(\\([^)\\n]*\\))?[ \t]+)*([a-z]+[ \t]+)*[A-Za-z_][[:alnum:]_<>,.?]*[ \t]+{name}[ \t]*\\([^;\\n]*$",
        "^( {0,4}|\t)(@[[:alnum:]_.]+(\\([^)\\n]*\\))?[ \t]+)*([a-z]+[ \t]+)*(val|var)[ \t]+{word}",
        "^( {0,4}|\t)([a-z]+[ \t]+)*[A-Za-z_][[:alnum:]_<>,.?]*[ \t]+{name}[ \t]*(=([^=]|$)|;)",
    ], locals: [
        "^[ \t]*([a-z]+[ \t]+)*(val|var)[ \t]+{word}",
        "^[ \t]+([a-z]+[ \t]+)*[A-Za-z_][[:alnum:]_<>,.?]*[ \t]+{name}[ \t]*=([^=]|$)",
    ])

    static let shell = Language(name: "Shell", lineComment: "#", rules: [
        (hashComment, .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        ("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", .attribute),
        (words("if then else elif fi for in do done while until case esac function return export local readonly set unset source exit echo"), .keyword),
        (number, .number),
    ], definitions: [
        "^[ \t]*(function[ \t]+)?{name}[ \t]*\\([ \t]*\\)",
        "^[ \t]*function[ \t]+{word}",
        "^[ \t]*(export[ \t]+|readonly[ \t]+|local[ \t]+|declare([ \t]+-[[:alnum:]]+)*[ \t]+)?{name}=",
    ])

    static let ruby = Language(name: "Ruby", lineComment: "#", rules: [
        (hashComment, .comment),
        (doubleQuoted, .string), (singleQuoted, .string),
        (":[A-Za-z_]\\w*", .attribute), ("@{1,2}\\w+", .attribute),
        (words("alias and begin break case class def do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require"), .keyword),
        (capitalized, .type), (number, .number),
    ], definitions: [
        "^[ \t]*def[ \t]+(self\\.)?{word}",
        "^[ \t]*(class|module)[ \t]+([[:alnum:]_]+::)*{word}",
        "^( {0,4}|\t){name}[ \t]*=([^=~]|$)",
        "^[ \t]*attr_(reader|writer|accessor)[ \t].*:{word}",
    ], locals: [
        "^[ \t]*{name}[ \t]*=([^=~]|$)",
    ])

    static let json = Language(name: "JSON", lineComment: nil, rules: [
        ("\"(?:[^\"\\\\\\n]|\\\\.)*\"(?=\\s*:)", .attribute),
        (doubleQuoted, .string),
        (words("true false null"), .keyword),
        ("-?" + number, .number),
    ])

    /// JSON with comments, for config files such as keybindings.json.
    static let jsonc = Language(name: "JSON with Comments", lineComment: "//", rules: [
        (cBlockComment, .comment), (slashComment, .comment),
    ] + json.rules)

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
        "Package.resolved": json, "keybindings.json": jsonc,
    ]

    static func detect(url: URL?) -> Language? {
        guard let url else { return nil }
        if let match = byFileName[url.lastPathComponent] { return match }
        return byExtension[url.pathExtension.lowercased()]
    }

    /// The file extensions detected as this language: Go to Definition
    /// searches only those files.
    var extensions: [String] {
        Language.byExtension.filter { $0.value.name == name }.keys.sorted()
    }

    // MARK: Go to Definition

    /// One pattern for the lines that define `name` (see `definitions`), or
    /// nil if the language has none. `withLocals` adds `locals`, for the file
    /// being edited.
    func definitionPattern(for name: String, withLocals: Bool) -> String? {
        let alternatives = definitions + (withLocals ? locals : [])
        guard !alternatives.isEmpty else { return nil }
        return alternatives.joined(separator: "|")
            .replacingOccurrences(of: "{word}", with: "{name}([^[:alnum:]_]|$)")
            .replacingOccurrences(of: "{name}", with: name)
    }
}

extension NSString {
    /// A letter, digit or "_": what names are made of in every language Pulse highlights.
    func isIdentifierCharacter(at index: Int) -> Bool {
        guard index >= 0, index < length else { return false }
        let c = character(at: index)
        if c < 128 { return c == 95 || (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) }
        return Unicode.Scalar(c).map { CharacterSet.alphanumerics.contains($0) } ?? false
    }

    /// The name at `index`, or ending there (the caret after a word), or nil.
    /// A number is not a name.
    func identifierRange(at index: Int) -> NSRange? {
        var start = isIdentifierCharacter(at: index) ? index : index - 1
        guard isIdentifierCharacter(at: start) else { return nil }
        var end = start + 1
        while isIdentifierCharacter(at: start - 1) { start -= 1 }
        while isIdentifierCharacter(at: end) { end += 1 }
        guard !(48...57).contains(character(at: start)) else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
