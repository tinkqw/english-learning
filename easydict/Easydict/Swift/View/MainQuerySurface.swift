//
//  MainQuerySurface.swift
//  Easydict
//
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

/// One reading surface with independently scrollable source and result views.
@objc(EZMainQuerySurface)
final class MainQuerySurface: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(sourceContainer)
        addSubview(resultContainer)
        addSubview(divider)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    @objc let sourceContainer = NSView()
    @objc let resultContainer = NSView()
    @objc var sideBySide = false { didSet { if sideBySide != oldValue { needsLayout = true } } }
    @objc var sourceVisible = true { didSet { if sourceVisible != oldValue { needsLayout = true } } }
    @objc var sourceHeight: CGFloat = 98 { didSet { if sourceHeight != oldValue { needsLayout = true } } }

    override func layout() {
        super.layout()
        sourceContainer.isHidden = !sourceVisible
        divider.isHidden = !sourceVisible
        guard sourceVisible else {
            resultContainer.frame = bounds
            return
        }
        if sideBySide {
            let width = floor(bounds.width / 2)
            sourceContainer.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            divider.frame = NSRect(x: width, y: 0, width: 1, height: bounds.height)
            resultContainer.frame = NSRect(x: width + 1, y: 0,
                                           width: bounds.width - width - 1, height: bounds.height)
        } else {
            // Leave space for the dictionary even at the smallest height setting.
            let height = min(bounds.height, max(76, min(sourceHeight, bounds.height * 0.45)))
            sourceContainer.frame = NSRect(x: 0, y: bounds.height - height,
                                           width: bounds.width, height: height)
            divider.frame = NSRect(x: 12, y: bounds.height - height - 1,
                                   width: max(0, bounds.width - 24), height: 1)
            resultContainer.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                           height: max(0, bounds.height - height - 1))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private let divider = NSView()

    private func updateAppearance() {
        PopupAppearance.apply(to: self, inline: false)
        divider.wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}
