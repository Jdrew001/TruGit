import Foundation
import SwiftUI

struct CodeHighlighting {
    private enum Token: String, CaseIterable {
        case comment, string, keyword, number, type, function, key, tag

        var color: Color {
            switch self {
            case .comment: Color(red: 0.59, green: 0.66, blue: 0.73)
            case .string: Color(red: 0.68, green: 0.86, blue: 0.58)
            case .keyword: Color(red: 0.82, green: 0.67, blue: 1)
            case .number: Color(red: 1, green: 0.74, blue: 0.51)
            case .type, .tag: Color(red: 0.47, green: 0.86, blue: 0.81)
            case .function, .key: Color(red: 0.56, green: 0.76, blue: 1)
            }
        }
    }

    private enum Language {
        case swift, javascript, python, ruby, shell, cFamily, rust, go, jvm, data, markup, sql, plain

        init(path: String) {
            let name = (path as NSString).lastPathComponent.lowercased()
            let suffix = (name as NSString).pathExtension
            switch suffix {
            case "swift": self = .swift
            case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": self = .javascript
            case "py", "pyw", "pyi": self = .python
            case "rb", "rake", "gemspec": self = .ruby
            case "sh", "bash", "zsh", "fish": self = .shell
            case "c", "h", "cpp", "cxx", "cc", "hpp", "m", "mm", "cs", "php": self = .cFamily
            case "rs": self = .rust
            case "go": self = .go
            case "java", "kt", "kts", "scala": self = .jvm
            case "json", "jsonc", "yaml", "yml", "toml", "ini", "env": self = .data
            case "html", "htm", "xml", "svg", "plist", "vue", "svelte", "md", "mdx", "css", "scss":
                self = .markup
            case "sql": self = .sql
            default:
                switch name {
                case "dockerfile", "makefile", ".bashrc", ".zshrc": self = .shell
                case "gemfile", "rakefile", "podfile": self = .ruby
                default: self = .plain
                }
            }
        }

        var commentPattern: String {
            switch self {
            case .python, .ruby, .shell, .data: #"#[^\n]*"#
            case .sql: #"--[^\n]*|/\*.*?(?:\*/|$)"#
            case .markup: #"<!--.*?(?:-->|$)|/\*.*?(?:\*/|$)"#
            case .plain: ""
            default: #"//[^\n]*|/\*.*?(?:\*/|$)"#
            }
        }

        var keywords: String {
            switch self {
            case .swift:
                "actor any as async await break case catch class continue default defer deinit do else enum extension fallthrough false for func guard if import in init inout is let nil nonisolated open operator override private protocol public repeat return self some static struct super switch throw throws true try typealias var weak where while"
            case .javascript:
                "as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null of private protected public readonly return static super switch this throw true try type typeof undefined var void while with yield"
            case .python:
                "and as assert async await break case class continue def del elif else except False finally for from global if import in is lambda match None nonlocal not or pass raise return self True try while with yield"
            case .ruby:
                "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or private protected public raise redo rescue retry return self super then true undef unless until when while yield"
            case .shell:
                "case do done elif else esac export fi for function if in local readonly return select set then unset until while FROM RUN COPY ADD ENV CMD ARG ENTRYPOINT WORKDIR EXPOSE"
            case .cFamily, .jvm:
                "abstract auto bool boolean break byte case catch char class const continue double else enum extends extern false final finally float for foreach if implements import int interface long namespace new noexcept null nullptr package private protected public return short sizeof static struct super switch synchronized template this throw throws true try typedef typename union unsigned using virtual void volatile while"
            case .rust:
                "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self static struct super trait true type unsafe use where while"
            case .go:
                "break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var"
            case .data: "true false null yes no on off"
            case .sql:
                "select from where join left right inner outer on as union distinct insert into values update set delete create table alter drop index group order by having limit offset with case when then else end and or not null is true false exists in primary key references default returning"
            case .markup, .plain: ""
            }
        }

        var rules: [(Token, String)] {
            guard self != .plain else { return [] }

            var rules: [(Token, String)] = [(.comment, commentPattern)]
            if self == .markup {
                rules.append((.tag, #"</?[\p{L}_][\p{L}\p{N}:_-]*|/>"#))
            }
            if self == .data || self == .markup {
                rules.append((.key, #""(?:\\.|[^"\\])*"(?=\s*:)|\b[A-Za-z_][\w-]*(?=\s*[:=])"#))
            }
            rules.append((.string, #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\x60(?:\\.|[^\x60\\])*\x60"#))
            if !keywords.isEmpty {
                let values = keywords.split(separator: " ").joined(separator: "|")
                let match = #"\b(?:"# + values + #")\b"#
                rules.append((.keyword, self == .sql ? "(?i:" + match + ")" : match))
            }
            rules += [
                (.number, #"\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)\b"#),
                (.type, #"\b[A-Z][A-Za-z0-9_]*\b"#),
                (.function, #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#),
            ]
            return rules
        }
    }

    private let expression: NSRegularExpression?

    init(path: String) {
        let rules = Language(path: path).rules
        let pattern = rules.map { token, expression in
            "(?<\(token.rawValue)>\(expression))"
        }.joined(separator: "|")
        expression = rules.isEmpty ? nil : try? NSRegularExpression(pattern: pattern)
    }

    func highlight(_ text: String) -> AttributedString {
        guard let expression else { return AttributedString(text) }

        var result = AttributedString()
        var cursor = text.startIndex
        let range = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text),
                  let token = Token.allCases.first(where: { match.range(withName: $0.rawValue).location != NSNotFound })
            else { continue }

            result.append(AttributedString(text[cursor..<range.lowerBound]))
            var colored = AttributedString(text[range])
            colored.foregroundColor = token.color
            result.append(colored)
            cursor = range.upperBound
        }
        result.append(AttributedString(text[cursor...]))
        return result
    }
}
