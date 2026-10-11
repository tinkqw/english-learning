//
//  InlineLookupPopover.swift
//  Easydict
//
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SFSafeSymbols
import SwiftUI

/// An in-window word card that leaves the parent result and its scroll offset intact.
@objc(EZInlineLookupPopover)
final class InlineLookupPopover: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        let host = NSHostingView(rootView: InlineLookupContent(state: state))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        state.close = { [weak self] in self?.closeCard?() }
        state.resize = { [weak self] in self?.reposition() }
        state.speak = { [weak self] in self?.playPhonetic?($0) }
        state.retry = { [weak self] in self?.retryLookup?() }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    @objc var closeCard: (() -> Void)?
    @objc var playPhonetic: ((EZWordPhonetic) -> Void)?
    @objc var retryLookup: (() -> Void)?
    @objc var contentWidth: CGFloat { max(1, frame.width - 32) }

    @objc(updateWithResult:word:sourceName:fullContent:fullHeight:fontRatio:)
    func update(result: QueryResult, word: String, sourceName: String,
                fullContent: NSView?, fullHeight: CGFloat, fontRatio: CGFloat) {
        state.word = word
        state.sourceName = sourceName
        state.result = result
        state.fullContent = fullContent
        state.fullHeight = fullHeight
        state.fontRatio = fontRatio
        reposition()
    }

    @objc(updateFullHeight:)
    func updateFullHeight(_ height: CGFloat) { state.fullHeight = height }

    /// Tracks the exact link range, so repeated occurrences highlight only the clicked word.
    @objc(presentInView:anchor:range:)
    func present(in parent: NSView, anchor: NSTextView, range: NSRange) {
        anchorView = anchor
        anchorRange = range
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        anchor.layoutManager?.addTemporaryAttribute(.backgroundColor,
            value: NSColor.controlAccentColor.withAlphaComponent(0.16), forCharacterRange: range)
        reposition()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.closeCard?()
                    return nil
                }
            } else {
                let point = self.convert(event.locationInWindow, from: nil)
                let anchorPoint = self.anchorView?.convert(event.locationInWindow, from: nil)
                let onAnchor = anchorPoint.map { self.linkRect()?.contains($0) == true } ?? false
                if !self.bounds.contains(point), !onAnchor { self.closeCard?() }
            }
            return event
        }
    }

    @objc func dismiss() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let anchorView, NSMaxRange(anchorRange) <= anchorView.string.utf16.count {
            anchorView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: anchorRange)
        }
        anchorView = nil
        removeFromSuperview()
    }

    /// Follows the word while scrolling; dismisses when it leaves the reading viewport.
    @objc func reposition() {
        guard let parent = superview, let anchor = anchorView else { return }
        guard anchor.window === parent.window, anchor.superview != nil,
              let rect = linkRect(), rect.intersects(anchor.visibleRect) else {
            closeCard?()
            return
        }
        let target = anchor.convert(rect, to: parent)
        let available = parent.bounds.insetBy(dx: 12, dy: 12)
        guard available.width > 0, available.height > 0 else { return }
        let width = min(360 * state.fontRatio, available.width)
        let height = min((state.expanded ? 520 : 270) * state.fontRatio, available.height)
        let gap: CGFloat = 8
        let below = parent.isFlipped ? target.maxY + gap : target.minY - gap - height
        let above = parent.isFlipped ? target.minY - gap - height : target.maxY + gap
        let fitsBelow = below >= available.minY && below + height <= available.maxY
        let fitsAbove = above >= available.minY && above + height <= available.maxY
        let belowSpace = parent.isFlipped ? available.maxY - target.maxY : target.minY - available.minY
        let aboveSpace = parent.isFlipped ? target.minY - available.minY : available.maxY - target.maxY
        let preferredY = fitsBelow ? below : (fitsAbove ? above : (belowSpace >= aboveSpace ? below : above))
        frame = NSRect(x: min(max(target.minX, available.minX), available.maxX - width),
                       y: min(max(preferredY, available.minY), available.maxY - height),
                       width: width, height: height)
    }

    private func linkRect() -> NSRect? {
        guard let anchor = anchorView, let manager = anchor.layoutManager,
              let container = anchor.textContainer, anchorRange.length > 0,
              NSMaxRange(anchorRange) <= anchor.string.utf16.count else { return nil }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: anchorRange, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: anchor.textContainerOrigin.x, dy: anchor.textContainerOrigin.y)
    }

    private let state = InlineLookupState()
    private weak var anchorView: NSTextView?
    private var anchorRange = NSRange(location: 0, length: 0)
    private var eventMonitor: Any?
}

private final class InlineLookupState: ObservableObject {
    @Published var word = ""
    @Published var sourceName = ""
    @Published var result: QueryResult?
    @Published var fullContent: NSView?
    @Published var fullHeight: CGFloat = 0
    @Published var fontRatio: CGFloat = 1
    @Published var expanded = false
    var close: (() -> Void)?
    var resize: (() -> Void)?
    var speak: ((EZWordPhonetic) -> Void)?
    var retry: (() -> Void)?
}

private struct InlineLookupContent: View {
    @ObservedObject var state: InlineLookupState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(format: String(localized: "popup.inline.source"), state.sourceName))
                    .font(.system(size: 11 * state.fontRatio)).foregroundStyle(.secondary)
                Spacer()
                Button { state.close?() } label: { Image(systemSymbol: .xmark) }
                    .help("popup.inline.close")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            ScrollView {
                if state.expanded, let content = state.fullContent {
                    InlineLookupNativeContent(content: content)
                        .frame(height: state.fullHeight).padding(.horizontal, 16)
                } else {
                    compactContent.padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            Divider()
            Button {
                state.expanded.toggle()
                state.resize?()
            } label: {
                HStack {
                    if state.expanded { Text("popup.inline.compact") }
                    else { Text("popup.inline.full_dictionary") }
                    Spacer()
                    Image(systemSymbol: state.expanded ? .chevronUp : .chevronDown)
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .disabled(state.fullContent == nil)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13 * state.fontRatio))
        .foregroundStyle(Color(nsColor: .popupText))
        .background { RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .popupReading)) }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.secondary.opacity(0.18), lineWidth: 1) }
    }

    @ViewBuilder private var compactContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: state.word).font(.system(size: 22 * state.fontRatio, weight: .semibold))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let result = state.result {
                ForEach(Array((result.wordResult?.phonetics ?? []).prefix(2).enumerated()), id: \.offset) { _, phonetic in
                    Button { state.speak?(phonetic) } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: phonetic.name ?? "").foregroundStyle(.secondary)
                            Text(verbatim: phonetic.value ?? "")
                            Image(systemSymbol: .speakerWave2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.help("play_audio")
                }
                if result.isLoading {
                    ProgressView().controlSize(.small)
                } else if let error = result.errorMessage {
                    Text(verbatim: error).foregroundStyle(.secondary)
                    Button("retry") { state.retry?() }
                } else if let parts = result.wordResult?.parts, !parts.isEmpty {
                    ForEach(Array(parts.prefix(2).enumerated()), id: \.offset) { _, part in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: part.part ?? "").foregroundStyle(.secondary)
                            Text(verbatim: part.means.prefix(3).joined(separator: "; "))
                                .lineLimit(3).textSelection(.enabled)
                        }
                    }
                } else {
                    Text(verbatim: result.translatedText ?? String(localized: "no_results_found"))
                        .lineLimit(4).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keeps the existing dictionary renderer and its actions inside the expanded card.
private struct InlineLookupNativeContent: NSViewRepresentable {
    let content: NSView
    func makeNSView(context: Context) -> NSView { content }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
