/// ScrollbackTests.swift
///
/// Tests that the scrollback-to-ANSI conversion correctly populates SwiftTerm's scrollback ring.
///
/// # What we are testing
///
/// `KytosPaneTerminalSnapshot.toANSIBytes()` converts a snapshot into a byte sequence that is fed
/// to `TerminalView.feed(byteArray:)`.  The sequence has two phases:
///
///   1. **Scrollback phase** — each historical line is emitted as plain text followed by `\r\n`.
///      SwiftTerm pushes each `\r\n`-terminated line into its scrollback ring.
///
///   2. **Flush phase** — `rows` bare `\r\n` are emitted *after* the scrollback lines.  Without
///      this flush the last `min(rows, scrollbackCount)` lines sit on the visible screen and get
///      silently overwritten by the screen overlay, making them unreachable via scrollback.
///
///   3. **Screen phase** — `screenANSIBytes()` uses absolute `CSI row;col H` positioning to paint
///      the visible screen.
///
/// We verify the contract by feeding the ANSI bytes into a headless `Terminal` and inspecting its
/// scrollback ring with `getScrollbackInfo()` / `getScrollInvariantLine(row:)`.

import Testing
@testable import SwiftTerm

// MARK: - Minimal stand-in types
//
// The real KytosPaneTerminalSnapshot lives in KytosApp (macOS-only, no test host),
// so we replicate the minimal logic under test here. The tests validate the *algorithm*
// rather than importing production code.

private struct Cell {
    let char: String   // single grapheme cluster, or "" / "\0" for blank
    let width: Int8    // 1 = normal, 2 = wide, 0 = wide-char spacer
}

private typealias Line = [Cell]

/// Replicates `KytosPaneTerminalSnapshot.toANSIBytes()` (the parts relevant to scrollback).
/// Returns the ANSI byte sequence that should be fed to SwiftTerm.
private func buildScrollbackANSI(scrollbackLines: [Line], rows: Int, cols: Int) -> [UInt8] {
    var out: [UInt8] = []

    // --- Scrollback phase ---
    for line in scrollbackLines {
        // Trim trailing blank cells (mirrors production code).
        var trimmedEnd = line.count
        while trimmedEnd > 0 {
            let c = line[trimmedEnd - 1]
            let ch = c.char
            if (ch == " " || ch.isEmpty || ch == "\0") && c.width <= 1 {
                trimmedEnd -= 1
            } else {
                break
            }
        }
        for cell in line.prefix(trimmedEnd) {
            if cell.width == 0 { continue }
            let ch = cell.char.isEmpty || cell.char == "\0" ? " " : cell.char
            out.append(contentsOf: ch.utf8)
        }
        out.append(contentsOf: "\r\n".utf8)
    }

    // --- Flush phase (the fix) ---
    // Push the last min(rows-1, N) lines off the visible screen and into the ring.
    if !scrollbackLines.isEmpty {
        for _ in 0..<(rows - 1) {
            out.append(contentsOf: "\r\n".utf8)
        }
    }

    // --- Screen phase (minimal: just paint row 0 so the terminal has a visible screen) ---
    // Move to top-left and write a sentinel so we can confirm the screen overlay ran.
    out.append(contentsOf: "\u{1b}[1;1H".utf8)  // CSI 1;1H
    out.append(contentsOf: "SCREEN".utf8)
    out.append(contentsOf: "\u{1b}[H".utf8)     // return cursor home

    return out
}

// MARK: - Test helper

private final class NoopDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

private func makeTerminal(cols: Int = 80, rows: Int = 5, scrollback: Int = 500) -> Terminal {
    let delegate = NoopDelegate()
    let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
    return Terminal(delegate: delegate, options: options)
}

/// Returns the text content of a single scrollback line (trimmed of trailing spaces).
private func scrollbackLineText(_ terminal: Terminal, absoluteRow: Int) -> String? {
    guard let line = terminal.getScrollInvariantLine(row: absoluteRow) else { return nil }
    var chars: [Character] = []
    for i in 0..<line.count {
        chars.append(terminal.getCharacter(for: line[i]))
    }
    var s = String(chars)
    // Trim trailing spaces / nulls SwiftTerm uses to fill.
    while s.last == " " || s.last == "\0" { s.removeLast() }
    return s
}

// MARK: - Tests

@Suite("Scrollback ANSI flush")
struct ScrollbackFlushTests {

    /// After attaching with 3 scrollback lines on a 5-row terminal,
    /// all 3 lines should be accessible in the scrollback ring.
    @Test func allScrollbackLinesArePushedIntoRing() throws {
        let rows = 5
        let scrollbackContent = ["alpha", "beta", "gamma"]
        let lines: [Line] = scrollbackContent.map { text in
            text.map { Cell(char: String($0), width: 1) }
        }

        let ansi = buildScrollbackANSI(scrollbackLines: lines, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows)
        terminal.feed(buffer: ansi[...])

        let (start, count) = terminal.getScrollbackInfo()
        #expect(count == scrollbackContent.count,
            "Expected \(scrollbackContent.count) scrollback lines, got \(count)")

        for (i, expected) in scrollbackContent.enumerated() {
            let actual = scrollbackLineText(terminal, absoluteRow: start + i)
            #expect(actual == expected,
                "Scrollback line \(i): expected \"\(expected)\", got \"\(actual ?? "<nil>")\"")
        }
    }

    /// With more scrollback lines than the ring capacity, the ring is filled to capacity
    /// and the oldest lines are trimmed (normal ring rotation), but we get exactly
    /// `scrollback` lines — not fewer.
    @Test func ringCapacityIsRespected() {
        let rows = 5
        let ringCapacity = 10
        let lineCount = 20  // exceeds capacity
        let lines: [Line] = (0..<lineCount).map { i in
            "line\(i)".map { Cell(char: String($0), width: 1) }
        }

        let ansi = buildScrollbackANSI(scrollbackLines: lines, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows, scrollback: ringCapacity)
        terminal.feed(buffer: ansi[...])

        let (_, count) = terminal.getScrollbackInfo()
        #expect(count == ringCapacity,
            "Ring should hold exactly \(ringCapacity) lines, got \(count)")
    }

    /// Fewer scrollback lines than `rows` — all lines make it into the ring.
    @Test func fewerLinesThanRowsAreAllPushed() throws {
        let rows = 10
        let scrollbackContent = ["only", "two"]  // < rows
        let lines: [Line] = scrollbackContent.map { text in
            text.map { Cell(char: String($0), width: 1) }
        }

        let ansi = buildScrollbackANSI(scrollbackLines: lines, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows)
        terminal.feed(buffer: ansi[...])

        let (start, count) = terminal.getScrollbackInfo()
        #expect(count == scrollbackContent.count)
        for (i, expected) in scrollbackContent.enumerated() {
            let actual = scrollbackLineText(terminal, absoluteRow: start + i)
            #expect(actual == expected)
        }
    }

    /// Zero scrollback lines → ring stays empty, no crash.
    @Test func emptyScrollbackIsNoOp() {
        let ansi = buildScrollbackANSI(scrollbackLines: [], rows: 5, cols: 80)
        let terminal = makeTerminal(rows: 5)
        terminal.feed(buffer: ansi[...])

        let (_, count) = terminal.getScrollbackInfo()
        #expect(count == 0)
    }

    /// The screen overlay (screen phase) does NOT add lines to the scrollback ring —
    /// everything already in the ring stays there after the screen is painted.
    @Test func screenOverlayDoesNotCorruptScrollback() {
        let rows = 5
        let scrollbackContent = ["persists"]
        let lines: [Line] = scrollbackContent.map { text in
            text.map { Cell(char: String($0), width: 1) }
        }

        let ansi = buildScrollbackANSI(scrollbackLines: lines, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows)
        terminal.feed(buffer: ansi[...])

        let (start, count) = terminal.getScrollbackInfo()
        #expect(count == 1)
        let actual = scrollbackLineText(terminal, absoluteRow: start)
        #expect(actual == "persists")
    }

    /// Trailing blank cells are trimmed before being pushed into the ring,
    /// so the stored text matches the non-blank content exactly.
    @Test func trailingBlankCellsTrimmed() throws {
        let rows = 5
        // "hello" followed by padding spaces (simulating a 80-col line stored at wider width)
        var line: Line = "hello".map { Cell(char: String($0), width: 1) }
        line += Array(repeating: Cell(char: " ", width: 1), count: 75)

        let ansi = buildScrollbackANSI(scrollbackLines: [line], rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows)
        terminal.feed(buffer: ansi[...])

        let (start, count) = terminal.getScrollbackInfo()
        #expect(count == 1)
        let actual = scrollbackLineText(terminal, absoluteRow: start)
        #expect(actual == "hello")
    }

    /// Exactly `rows` scrollback lines — a boundary case where without the flush
    /// all lines would land on the visible screen and get overwritten.
    @Test func exactlyRowsScrollbackLinesAreAllPreserved() throws {
        let rows = 5
        let scrollbackContent = (0..<rows).map { "row\($0)" }
        let lines: [Line] = scrollbackContent.map { text in
            text.map { Cell(char: String($0), width: 1) }
        }

        let ansi = buildScrollbackANSI(scrollbackLines: lines, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows)
        terminal.feed(buffer: ansi[...])

        let (start, count) = terminal.getScrollbackInfo()
        #expect(count == rows,
            "Expected \(rows) scrollback lines (one per row), got \(count)")

        for (i, expected) in scrollbackContent.enumerated() {
            let actual = scrollbackLineText(terminal, absoluteRow: start + i)
            #expect(actual == expected,
                "Line \(i): expected \"\(expected)\", got \"\(actual ?? "<nil>")\"")
        }
    }
}

// MARK: - Delta scrollback tests

/// Replicates the delta `toANSIBytes(terminalRows:)` approach:
/// 1. ESC[2J + ESC[H — clear screen and go home
/// 2. Write each scrolledOff line + \r\n
/// 3. ESC[rows;1H + min(N, rows-1) newlines — flush into ring
/// 4. Positioned screen content
private func buildDeltaScrollANSI(scrolledOffLines: [Line], screenLines: [Line], rows: Int, cols: Int) -> [UInt8] {
    var out: [UInt8] = []
    let N = scrolledOffLines.count
    if N > 0 {
        out.append(contentsOf: "\u{1b}[2J\u{1b}[H".utf8)
        for line in scrolledOffLines {
            var trimmedEnd = line.count
            while trimmedEnd > 0 {
                let c = line[trimmedEnd - 1]
                if (c.char == " " || c.char.isEmpty || c.char == "\0") && c.width <= 1 {
                    trimmedEnd -= 1
                } else { break }
            }
            for cell in line.prefix(trimmedEnd) {
                if cell.width == 0 { continue }
                let ch = cell.char.isEmpty || cell.char == "\0" ? " " : cell.char
                out.append(contentsOf: ch.utf8)
            }
            out.append(contentsOf: "\r\n".utf8)
        }
        let flushCount = min(N, rows - 1)
        out.append(contentsOf: "\u{1b}[\(rows);1H".utf8)
        for _ in 0..<flushCount {
            out.append(contentsOf: "\n".utf8)
        }
    }
    // Positioned screen content
    for (i, line) in screenLines.enumerated() {
        out.append(contentsOf: "\u{1b}[\(i + 1);1H\u{1b}[2K".utf8)
        for cell in line {
            if cell.width == 0 { continue }
            let ch = cell.char.isEmpty || cell.char == "\0" ? " " : cell.char
            out.append(contentsOf: ch.utf8)
        }
    }
    return out
}

@Suite("Delta scroll injection")
struct DeltaScrollTests {

    /// Few scrolled-off lines (< rows): all pushed into ring, no blank lines.
    @Test func deltaFewScrolledOffLines() {
        let rows = 5
        let scrolledOff = ["alpha", "beta"].map { t in t.map { Cell(char: String($0), width: 1) } }
        let screen = (0..<rows).map { i in "scr\(i)".map { Cell(char: String($0), width: 1) } }

        let ansi = buildDeltaScrollANSI(scrolledOffLines: scrolledOff, screenLines: screen, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows)
        // Pre-fill screen so it has content before the delta
        terminal.feed(buffer: Array("A\r\nB\r\nC\r\nD\r\nE".utf8)[...])
        terminal.feed(buffer: ansi[...])

        let (start, count) = terminal.getScrollbackInfo()
        #expect(count == 2, "Expected 2 scrollback lines, got \(count)")
        #expect(scrollbackLineText(terminal, absoluteRow: start) == "alpha")
        #expect(scrollbackLineText(terminal, absoluteRow: start + 1) == "beta")
    }

    /// Exactly rows scrolled-off lines: all pushed into ring.
    @Test func deltaExactlyRowsScrolledOff() {
        let rows = 5
        let scrolledOff = (0..<rows).map { i in "line\(i)".map { Cell(char: String($0), width: 1) } }
        let screen = (0..<rows).map { i in "scr\(i)".map { Cell(char: String($0), width: 1) } }

        let ansi = buildDeltaScrollANSI(scrolledOffLines: scrolledOff, screenLines: screen, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows)
        terminal.feed(buffer: Array("A\r\nB\r\nC\r\nD\r\nE".utf8)[...])
        terminal.feed(buffer: ansi[...])

        let (start, count) = terminal.getScrollbackInfo()
        #expect(count == rows, "Expected \(rows) scrollback lines, got \(count)")
        for i in 0..<rows {
            #expect(scrollbackLineText(terminal, absoluteRow: start + i) == "line\(i)")
        }
    }

    /// Many scrolled-off lines (> rows): all pushed into ring.
    @Test func deltaManyScrolledOffLines() {
        let rows = 5
        let N = 12
        let scrolledOff = (0..<N).map { i in "off\(i)".map { Cell(char: String($0), width: 1) } }
        let screen = (0..<rows).map { i in "scr\(i)".map { Cell(char: String($0), width: 1) } }

        let ansi = buildDeltaScrollANSI(scrolledOffLines: scrolledOff, screenLines: screen, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows, scrollback: 500)
        terminal.feed(buffer: Array("A\r\nB\r\nC\r\nD\r\nE".utf8)[...])
        terminal.feed(buffer: ansi[...])

        let (start, count) = terminal.getScrollbackInfo()
        #expect(count == N, "Expected \(N) scrollback lines, got \(count)")
        for i in 0..<N {
            #expect(scrollbackLineText(terminal, absoluteRow: start + i) == "off\(i)")
        }
    }

    /// No scrolled-off lines: ring stays unchanged.
    @Test func deltaNoScrolledOffLines() {
        let rows = 5
        let screen = (0..<rows).map { i in "scr\(i)".map { Cell(char: String($0), width: 1) } }

        let ansi = buildDeltaScrollANSI(scrolledOffLines: [], screenLines: screen, rows: rows, cols: 80)
        let terminal = makeTerminal(rows: rows)
        terminal.feed(buffer: ansi[...])

        let (_, count) = terminal.getScrollbackInfo()
        #expect(count == 0, "No scrolled lines means no scrollback, got \(count)")
    }

    /// Screen content is correctly positioned after scroll injection.
    @Test func deltaScreenContentCorrectAfterScroll() {
        let rows = 5
        let scrolledOff = ["x", "y", "z"].map { t in t.map { Cell(char: String($0), width: 1) } }
        let screenText = ["Hello", "World", "Test!", "Line4", "Line5"]
        let screen = screenText.map { t in t.map { Cell(char: String($0), width: 1) } }

        let ansi = buildDeltaScrollANSI(scrolledOffLines: scrolledOff, screenLines: screen, rows: rows, cols: 80)
        let terminal = makeTerminal(cols: 80, rows: rows)
        terminal.feed(buffer: Array("AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE".utf8)[...])
        terminal.feed(buffer: ansi[...])

        // Check visible screen content
        let (sbStart, sbCount) = terminal.getScrollbackInfo()
        #expect(sbCount == 3)
        for i in 0..<rows {
            guard let line = terminal.getScrollInvariantLine(row: sbStart + sbCount + i) else {
                Issue.record("Could not get screen line \(i)")
                continue
            }
            var text = ""
            for j in 0..<min(screenText[i].count, line.count) {
                text.append(terminal.getCharacter(for: line[j]))
            }
            #expect(text == screenText[i], "Screen row \(i): expected '\(screenText[i])', got '\(text)'")
        }
    }
}
