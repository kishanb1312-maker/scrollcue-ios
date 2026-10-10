import UIKit

/// Visual style needed to lay out a script.
struct LayoutStyle: Equatable {
    var font: UIFont
    var textColor: UIColor
    var dimColor: UIColor
    var highlightColor: UIColor
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var alignment: NSTextAlignment
    var rightToLeft: Bool
    var highlightCurrentWord: Bool
    var dimReadText: Bool

    init(settings s: PrompterSettings, fontSize: Double? = nil) {
        font = s.font.uiFont(size: CGFloat(fontSize ?? s.fontSize), bold: s.bold)
        textColor = s.textColor.withAlpha(s.textOpacity)
        dimColor = s.textColor.withAlpha(s.textOpacity * 0.4)
        highlightColor = s.highlightColor.withAlpha(s.textOpacity)
        let scale = CGFloat((fontSize ?? s.fontSize) / max(s.fontSize, 1))
        lineSpacing = CGFloat(s.lineSpacing) * scale
        paragraphSpacing = CGFloat(s.paragraphSpacing) * scale
        alignment = s.alignment.nsAlignment
        rightToLeft = s.rightToLeft
        highlightCurrentWord = s.highlightCurrentWord
        dimReadText = s.dimReadText
    }
}

/// TextKit layout of a script at a given width. Maps between a continuous
/// "word position" (fractional word index) and a vertical offset, so several
/// views with different widths (main screen, PiP, camera overlay) stay in sync.
final class PrompterLayout {
    struct Line {
        let midY: CGFloat
        let rect: CGRect
        let firstWord: Int
    }

    let tokens: ScriptTokens
    let style: LayoutStyle
    let width: CGFloat

    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer

    private(set) var lines: [Line] = []
    private(set) var wordLine: [Int] = []
    private(set) var contentHeight: CGFloat = 0

    private var appliedRead = 0
    private var appliedCurrent: Int? = nil

    init(tokens: ScriptTokens, style: LayoutStyle, width: CGFloat) {
        self.tokens = tokens
        self.style = style
        self.width = max(width, 40)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = style.paragraphSpacing
        paragraph.alignment = style.alignment
        paragraph.baseWritingDirection = style.rightToLeft ? .rightToLeft : .leftToRight
        paragraph.lineBreakMode = .byWordWrapping

        storage = NSTextStorage(string: tokens.text, attributes: [
            .font: style.font,
            .foregroundColor: style.textColor,
            .paragraphStyle: paragraph,
        ])
        container = NSTextContainer(size: CGSize(width: self.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.allowsNonContiguousLayout = false
        storage.addLayoutManager(manager)

        buildLines()
    }

    private func buildLines() {
        let glyphCount = manager.numberOfGlyphs
        guard glyphCount > 0, tokens.count > 0 else {
            contentHeight = style.font.lineHeight
            return
        }
        manager.ensureLayout(for: container)
        var result: [Line] = []
        var wl = [Int](repeating: 0, count: tokens.count)
        var wordCursor = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: glyphCount)) { rect, used, _, glyphRange, _ in
            let chars = self.manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let end = chars.location + chars.length
            var first: Int? = nil
            while wordCursor < self.tokens.count && self.tokens.words[wordCursor].range.location < end {
                if first == nil { first = wordCursor }
                wl[wordCursor] = result.count
                wordCursor += 1
            }
            if let first {
                result.append(Line(midY: used.midY, rect: CGRect(x: used.minX, y: rect.minY, width: used.width, height: rect.height), firstWord: first))
            }
        }
        // Anything left (shouldn't happen) belongs to the last line.
        while wordCursor < tokens.count { wl[wordCursor] = max(result.count - 1, 0); wordCursor += 1 }
        lines = result
        wordLine = wl
        contentHeight = manager.usedRect(for: container).height
    }

    var lineHeight: CGFloat { style.font.lineHeight + style.lineSpacing }

    // MARK: Position mapping

    /// Vertical position (in layout coordinates) for a fractional word index.
    func y(forPosition p: Double) -> CGFloat {
        let n = tokens.count
        guard n > 0, !lines.isEmpty else { return 0 }
        let p = min(max(p, 0), Double(n))
        let wi = min(Int(p), n - 1)
        let li = wordLine[wi]
        let line = lines[li]
        let hasNext = li + 1 < lines.count
        let nextFirst = hasNext ? lines[li + 1].firstWord : n
        let nextY = hasNext ? lines[li + 1].midY : line.midY + line.rect.height
        let span = max(Double(nextFirst - line.firstWord), 1)
        let t = CGFloat((p - Double(line.firstWord)) / span)
        return line.midY + t * (nextY - line.midY)
    }

    /// Inverse of `y(forPosition:)`.
    func position(forY y: CGFloat) -> Double {
        let n = tokens.count
        guard n > 0, !lines.isEmpty else { return 0 }
        if y <= lines[0].midY { return 0 }
        // Binary search the last line whose midY <= y.
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].midY <= y { lo = mid } else { hi = mid - 1 }
        }
        let line = lines[lo]
        let hasNext = lo + 1 < lines.count
        let nextFirst = hasNext ? lines[lo + 1].firstWord : n
        let nextY = hasNext ? lines[lo + 1].midY : line.midY + line.rect.height
        let t = min(max(Double((y - line.midY) / max(nextY - line.midY, 1)), 0), 1)
        return Double(line.firstWord) + t * Double(nextFirst - line.firstWord)
    }

    func lineIndex(forPosition p: Double) -> Int {
        guard !lines.isEmpty, tokens.count > 0 else { return 0 }
        return wordLine[min(max(Int(p), 0), tokens.count - 1)]
    }

    /// Fractional position after moving `delta` lines from `p`.
    func position(movingLines delta: Int, from p: Double) -> Double {
        guard !lines.isEmpty else { return p }
        let target = min(max(lineIndex(forPosition: p) + delta, 0), lines.count - 1)
        if delta > 0 && lineIndex(forPosition: p) == lines.count - 1 { return Double(tokens.count) }
        return Double(lines[target].firstWord)
    }

    /// Word index at a point in layout coordinates.
    func wordIndex(at point: CGPoint) -> Int? {
        guard tokens.count > 0 else { return nil }
        var fraction: CGFloat = 0
        let ci = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return tokens.wordIndex(atCharacter: ci)
    }

    // MARK: Highlighting

    /// Re-colors only the words whose state changed.
    func applyProgress(read: Int, current: Int?) {
        let n = tokens.count
        guard n > 0 else { return }
        let read = min(max(read, 0), n)
        let current = style.highlightCurrentWord ? current.flatMap { $0 < n ? $0 : nil } : nil
        if read == appliedRead && current == appliedCurrent { return }

        var lo = min(read, appliedRead)
        var hi = max(read, appliedRead)
        if let c = current { lo = min(lo, c); hi = max(hi, c + 1) }
        if let c = appliedCurrent { lo = min(lo, c); hi = max(hi, c + 1) }
        lo = max(lo, 0); hi = min(hi, n)
        guard lo < hi else { return }

        storage.beginEditing()
        for i in lo..<hi {
            let color: UIColor
            if i == current { color = style.highlightColor }
            else if i < read && style.dimReadText { color = style.dimColor }
            else { color = style.textColor }
            storage.addAttribute(.foregroundColor, value: color, range: tokens.words[i].range)
        }
        storage.endEditing()
        appliedRead = read
        appliedCurrent = current
    }

    // MARK: Drawing

    /// Draws the text into the current UIGraphics context. `offset` is the
    /// layout y that appears at the top of the viewport; `origin` is where the
    /// text container's left edge sits.
    func draw(in rect: CGRect, offset: CGFloat, originX: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext(), manager.numberOfGlyphs > 0 else { return }
        let visible = CGRect(x: 0, y: offset, width: width, height: rect.height)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: originX, y: -offset)
        manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        ctx.restoreGState()
    }
}
