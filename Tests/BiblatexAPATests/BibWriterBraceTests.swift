import XCTest
@testable import BiblatexAPA

/// A field value with unbalanced braces closes its own field early and everything
/// after it is parsed as bibtex syntax — so a value can inject a whole fabricated
/// entry. Reported from PsychQuant/Akashic-Library#176.
///
/// These are the first tests in this package. The target was declared in
/// `Package.swift` but the directory did not exist, so `swift test` had nothing
/// to run — a security fix to a canonical shared library should not ship that way.
final class BibWriterBraceTests: XCTestCase {

    private func entry(title: String) -> BibEntry {
        var fields = OrderedDict()
        fields["title"] = title
        fields["date"] = "2020"
        return BibEntry(entryType: "article", key: "inject2020", fields: fields,
                        rawText: "", lineNumber: 1)
    }

    /// The reported injection.
    func testUnbalancedBraceCannotFabricateAnEntry() {
        let hostile = "ok},\n}\n@ARTICLE{forged2099,\n  TITLE = {I am fake"
        let out = BibWriter.serialize(entry(title: hostile))
        XCTAssertFalse(out.contains("@ARTICLE{forged2099"),
                       "a field value must not be able to open a new entry:\n\(out)")
        // The content is still there, just neutralised
        XCTAssertTrue(out.contains("forged2099"), "escaping is not deletion")
    }

    /// **Balanced braces must pass through untouched.** biblatex uses them inside
    /// values to protect capitalisation and Zotero emits them routinely; escaping
    /// those would change the rendered output of every such record.
    func testBalancedBracesArePreserved() {
        let legit = "{DNA} sequencing of {E. coli}"
        let out = BibWriter.serialize(entry(title: legit))
        XCTAssertTrue(out.contains("TITLE = {\(legit)},"),
                      "protected capitalisation must survive verbatim:\n\(out)")
        XCTAssertFalse(out.contains("\\{"), "nothing to escape here")
    }

    /// Nested-but-balanced is still balanced.
    func testNestedBalancedBracesArePreserved() {
        let legit = "a {b {c} d} e"
        XCTAssertTrue(BibWriter.serialize(entry(title: legit)).contains("TITLE = {\(legit)},"))
    }

    /// Closing before opening is unbalanced even though the totals match.
    func testCloseBeforeOpenIsTreatedAsUnbalanced() {
        XCTAssertEqual(BibWriter.braceSafe("}{"),
                       "\\textbraceright{}\\textbraceleft{}",
                       "totals match but the structure is not well-nested")
    }

    /// An unmatched opener is unbalanced too — it swallows the rest of the file.
    func testUnmatchedOpenerIsEscaped() {
        XCTAssertEqual(BibWriter.braceSafe("a {b"), "a \\textbraceleft{}b")
    }

    func testValuesWithoutBracesAreUntouched() {
        XCTAssertEqual(BibWriter.braceSafe("plain title"), "plain title")
    }

    // MARK: - The invariant that makes it safe

    /// **The escaped form must itself be brace-balanced.** This — not any
    /// particular escape spelling — is what keeps a value inside its own field:
    /// btparse counts braces and ignores backslashes, so only balance protects.
    ///
    /// The earlier `\{` / `\}` form fails this: real `biber --tool` reports a
    /// syntax error and drops the genuine entry along with the fabricated one.
    func testEscapedOutputIsItselfBalanced() {
        let hostile = [
            "ok},\n}\n@ARTICLE{forged2099,\n  TITLE = {I am fake",
            "}{",
            "a {b",
            #"ok\},\n\}\n@ARTICLE{forged_pre,"#,   // 已經帶 LaTeX 逃脫的 `\}`
            #"trailing backslash \"#,
        ]
        for value in hostile {
            let out = BibWriter.braceSafe(value)
            var depth = 0
            for ch in out {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    XCTAssertGreaterThanOrEqual(depth, 0,
                        "closes before it opens — can leave the field: \(out)")
                }
            }
            XCTAssertEqual(depth, 0, "unbalanced output for \(value.debugDescription): \(out)")
        }
    }

    /// A backslash already in the value must not survive **adjacent to a bare
    /// brace**. `\` + `}` renders as a line break followed by a live closing
    /// brace — the injection would be back, which is what the `\}` form did.
    func testPreEscapedBackslashCannotReintroduceALiveBrace() {
        let out = BibWriter.braceSafe(#"ok\},\n\}\n@ARTICLE{forged_pre,"#)
        XCTAssertFalse(out.contains(#"\\"#),
                       "a doubled backslash leaves the next brace live: \(out)")
    }

    /// Round-trip through the package's own parser: exactly the one genuine
    /// entry, and the fabricated key is not an entry key.
    func testSerializedHostileValueRoundTripsAsOneEntry() {
        let hostile = "ok},\n}\n@ARTICLE{forged2099,\n  TITLE = {I am fake"
        let text = BibWriter.serialize(entry(title: hostile)) + "\n"
        let parsed = BibParser.parse(content: text)
        XCTAssertEqual(parsed.entries.count, 1, "one entry in, one entry out")
        XCTAssertEqual(parsed.entries.first?.key, "inject2020")
        XCTAssertTrue(parsed.entries.first?.title?.contains("forged2099") == true,
                      "the payload survives as text — escaping is not deletion")
    }
}
