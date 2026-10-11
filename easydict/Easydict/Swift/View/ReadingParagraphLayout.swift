//
//  ReadingParagraphLayout.swift
//  Easydict
//
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

/// Compact reading styles preserve characters, link ranges, and the source used for copying.
@objc(EZReadingParagraphLayout)
final class ReadingParagraphLayout: NSObject {
    @objc(compactResult:baseFont:)
    static func compactResult(_ source: NSAttributedString, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        apply(to: result, baseFont: baseFont)
        return result
    }

    /// Restore normal input styles before compacting blank paragraphs, including after editing a blank line.
    @objc(compactSourceInTextView:baseFont:)
    static func compactSource(in textView: NSTextView, baseFont: NSFont) {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let result = NSMutableAttributedString(attributedString: storage)
        let paragraph = (textView.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        paragraph.minimumLineHeight = 0
        paragraph.maximumLineHeight = 0
        result.addAttributes([.font: baseFont, .paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: result.length))
        apply(to: result, baseFont: baseFont)
        if !storage.isEqual(to: result) { storage.setAttributedString(result) }
        var typing = textView.typingAttributes
        typing[.font] = baseFont
        typing[.paragraphStyle] = paragraph
        textView.typingAttributes = typing
    }

    private enum Kind { case blank, body, heading, item, quote, code }
    private struct Paragraph {
        let range: NSRange
        let kind: Kind
    }

    private static func apply(to text: NSMutableAttributedString, baseFont: NSFont) {
        guard text.length > 0 else { return }
        let paragraphs = paragraphs(in: text, baseFont: baseFont)
        let ratio = baseFont.pointSize / 15
        var index = 0
        while index < paragraphs.count {
            let current = paragraphs[index]
            if current.kind == .code { index += 1; continue }
            if current.kind == .blank {
                var end = index + 1
                while end < paragraphs.count, paragraphs[end].kind == .blank { end += 1 }
                let next = end < paragraphs.count ? paragraphs[end].kind : .body
                let gap: CGFloat
                switch next {
                case .heading: gap = 16
                case .item: gap = 14
                case .quote: gap = 5
                default: gap = 9
                }
                // Multiple source blank lines share one visual gap without deleting any characters.
                let lineHeight = gap * ratio / CGFloat(end - index)
                for blank in paragraphs[index..<end] {
                    let style = paragraphStyle(in: text, range: blank.range)
                    style.lineSpacing = 0
                    style.paragraphSpacing = 0
                    style.paragraphSpacingBefore = 0
                    style.minimumLineHeight = lineHeight
                    style.maximumLineHeight = lineHeight
                    text.addAttribute(.paragraphStyle, value: style, range: blank.range)
                }
                index = end
                continue
            }
            let style = paragraphStyle(in: text, range: current.range)
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            if current.kind == .heading {
                if index > 0, paragraphs[index - 1].kind != .blank {
                    style.paragraphSpacingBefore = 16 * ratio
                }
                style.paragraphSpacing = 5 * ratio
            }
            text.addAttribute(.paragraphStyle, value: style, range: current.range)
            index += 1
        }
    }

    private static func paragraphStyle(in text: NSAttributedString, range: NSRange) -> NSMutableParagraphStyle {
        (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
    }

    private static func paragraphs(in text: NSAttributedString, baseFont: NSFont) -> [Paragraph] {
        let string = text.string as NSString
        var result: [Paragraph] = []
        var location = 0
        var fence: String?
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let content = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let style = paragraphStyle(in: text, range: range)
            let marker = content.hasPrefix("```") ? "```" : (content.hasPrefix("~~~") ? "~~~" : nil)
            let kind: Kind
            if let activeFence = fence {
                kind = .code
                if content.hasPrefix(activeFence) { fence = nil }
            } else if let marker {
                kind = .code
                fence = marker
            } else if style.headIndent == 8, text.attribute(.backgroundColor, at: location, effectiveRange: nil) != nil {
                // Fenced Markdown code keeps its whitespace and monospaced metrics.
                kind = .code
            } else if content.isEmpty {
                kind = .blank
            } else if content.hasPrefix("•") || content.range(of: "^\\d+\\.[\\t ]", options: .regularExpression) != nil {
                kind = .item
            } else if text.attribute(.markdownBlockquote, at: location, effectiveRange: nil) != nil {
                kind = .quote
            } else if isHeading(text, range: range, baseFont: baseFont) {
                kind = .heading
            } else {
                kind = .body
            }
            result.append(Paragraph(range: range, kind: kind))
            location = NSMaxRange(range)
        }
        return result
    }

    private static func isHeading(_ text: NSAttributedString, range: NSRange, baseFont: NSFont) -> Bool {
        let string = text.string as NSString
        let content = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        let contentRange = string.range(of: content, options: [], range: range)
        var allHeadingFonts = true
        text.enumerateAttribute(.font, in: contentRange) { value, _, stop in
            guard let font = value as? NSFont,
                  font.pointSize > baseFont.pointSize * 1.03 || font.fontDescriptor.symbolicTraits.contains(.bold) else {
                allHeadingFonts = false
                stop.pointee = true
                return
            }
        }
        return allHeadingFonts
    }
}
