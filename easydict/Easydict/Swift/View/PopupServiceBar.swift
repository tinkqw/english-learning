//
//  PopupServiceBar.swift
//  Easydict
//
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SFSafeSymbols
import SwiftUI

/// AppKit bridge for the popup's presentation-only service selection.
@objc(EZPopupServiceBar)
final class PopupServiceBar: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = NSHostingView(rootView: PopupServiceBarContent(state: state))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        state.select = { [weak self] in self?.selectService?($0) }
        state.copy = { [weak self] in self?.copyResult?() }
        state.more = { [weak self] in self?.showActions?() }
        state.stop = { [weak self] in self?.stopQuery?() }
    }

    required init?(coder: NSCoder) { nil }

    @objc var selectService: ((String) -> Void)?
    @objc var copyResult: (() -> Void)?
    @objc var showActions: (() -> Void)?
    @objc var stopQuery: (() -> Void)?

    @objc var preferredHeight: CGFloat {
        state.stale || state.incomplete || state.selectedRunning ? 48 : 32
    }

    @objc(updateWithServices:selectedID:canCopy:isRunning:selectedRunning:incomplete:stopped:stale:)
    func update(services: [QueryService], selectedID: String?, canCopy: Bool,
                isRunning: Bool, selectedRunning: Bool, incomplete: Bool, stopped: Bool, stale: Bool) {
        state.items = services.map { .init(id: $0.serviceTypeWithUniqueIdentifier(), name: $0.name()) }
        state.selectedID = selectedID
        state.canCopy = canCopy
        state.isRunning = isRunning
        state.selectedRunning = selectedRunning
        state.incomplete = incomplete
        state.stopped = stopped
        state.stale = stale
    }

    private let state = PopupServiceBarState()
}

private final class PopupServiceBarState: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let name: String
    }

    @Published var items: [Item] = []
    @Published var selectedID: String?
    @Published var canCopy = false
    @Published var isRunning = false
    @Published var selectedRunning = false
    @Published var incomplete = false
    @Published var stopped = false
    @Published var stale = false
    var select: ((String) -> Void)?
    var copy: (() -> Void)?
    var more: (() -> Void)?
    var stop: (() -> Void)?
}

private struct PopupServiceBarContent: View {
    @ObservedObject var state: PopupServiceBarState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(state.items) { item in
                            Button {
                                state.select?(item.id)
                            } label: {
                                Text(verbatim: item.name)
                                    .lineLimit(1)
                                    .frame(maxWidth: 140)
                                    .padding(.horizontal, 9)
                                    .frame(height: 28)
                                    .background {
                                        if item.id == state.selectedID {
                                            RoundedRectangle(cornerRadius: 9)
                                                .fill(Color(nsColor: .popupReading))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                            .accessibilityAddTraits(item.id == state.selectedID ? .isSelected : [])
                        }
                    }
                }
                .frame(height: 28)
                .accessibilityLabel(Text("popup.service.selection"))

                if state.isRunning {
                    Button { state.stop?() } label: {
                        Image(systemSymbol: .stopCircle)
                    }
                    .help(Text("popup.query.stop"))
                    .accessibilityLabel(Text("popup.query.stop"))
                }
                Button { state.copy?() } label: {
                    Image(systemSymbol: .docOnDoc)
                }
                .disabled(!state.canCopy)
                .help(copyTitle)
                .accessibilityLabel(copyTitle)

                Button { state.more?() } label: {
                    Image(systemSymbol: .ellipsis)
                }
                .help(Text("popup.result.actions"))
                .accessibilityLabel(Text("popup.result.actions"))
                .disabled(state.selectedID == nil)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            if state.stale {
                Text("popup.result.stale")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if state.incomplete {
                incompleteTitle
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if state.selectedRunning {
                Text("popup.result.loading")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: .popupText))
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
    }

    private var copyTitle: Text {
        if state.stale { return Text("popup.result.copy_previous") }
        if state.incomplete { return Text("popup.result.copy_incomplete") }
        if state.selectedRunning { return Text("popup.result.copy_fragment") }
        return Text("popup.result.copy")
    }

    private var incompleteTitle: Text {
        if state.stopped { return Text("popup.result.stopped") }
        return Text("popup.result.incomplete")
    }
}

extension NSColor {
    static let popupShell = popupColor(light: 0xEEF1F7, dark: 0x1D222B)
    static let popupReading = popupColor(light: 0xFFFFFF, dark: 0x272C35)
    static let popupInset = popupColor(light: 0xF4F6F9, dark: 0x323843)
    static let popupText = popupColor(light: 0x242B36, dark: 0xEDF0F5)

    private static func popupColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
}

/// Shared popup surfaces, resolved inside the view's effective appearance.
@objc(EZPopupAppearance)
final class PopupAppearance: NSObject {
    @objc static var shellColor: NSColor { .popupShell }
    @objc static var textColor: NSColor { .popupText }

    @objc(applyShellToView:)
    static func applyShell(to view: NSView) {
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.popupShell.withAlphaComponent(0.9).cgColor
        }
    }

    @objc(applyToView:inline:)
    static func apply(to view: NSView, inline: Bool) {
        view.wantsLayer = true
        view.layer?.cornerRadius = inline ? 12 : 16
        view.layer?.masksToBounds = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = (inline ? NSColor.popupInset : .popupReading).cgColor
        }
    }
}

/// Compact titlebar; legacy quick links remain available through its menu.
@objc(EZPopupChrome)
final class PopupChrome: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = NSHostingView(rootView: PopupChromeContent(state: state))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        state.pin = { [weak self] in self?.togglePin?() }
        state.main = { [weak self] in self?.openMainWindow?() }
        state.more = { [weak self] in self?.showMenu?() }
        state.settings = { [weak self] in self?.openSettings?() }
    }

    required init?(coder: NSCoder) { nil }
    @objc var togglePin: (() -> Void)?
    @objc var openMainWindow: (() -> Void)?
    @objc var showMenu: (() -> Void)?
    @objc var openSettings: (() -> Void)?
    @objc func updateMainStyle(_ main: Bool) { state.mainStyle = main }
    @objc func updatePin(_ pinned: Bool) { state.pinned = pinned }
    private let state = PopupChromeState()
}

private final class PopupChromeState: ObservableObject {
    @Published var pinned = false
    @Published var mainStyle = false
    var pin: (() -> Void)?
    var main: (() -> Void)?
    var more: (() -> Void)?
    var settings: (() -> Void)?
}

private struct PopupChromeContent: View {
    @ObservedObject var state: PopupChromeState

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "Easydict")
            Spacer(minLength: 8)
            if state.mainStyle {
                Button { state.settings?() } label: { Image(systemSymbol: .gearshape) }
                    .help(Text("open_app_settings"))
                    .accessibilityLabel(Text("open_app_settings"))
            } else {
                Button { state.pin?() } label: {
                    Image(systemSymbol: state.pinned ? .pinFill : .pin)
                        .foregroundStyle(state.pinned ? Color.accentColor : Color(nsColor: .popupText))
                }
                .help(Text(state.pinned ? "unpin" : "pin"))
                .accessibilityLabel(Text(state.pinned ? "unpin" : "pin"))
                Button { state.main?() } label: {
                    HStack(spacing: 4) {
                        Text("popup.main_window")
                        Image(systemSymbol: .arrowUpRight)
                    }
                }
                .help(Text("popup.main_window"))
            }
            Button { state.more?() } label: { Image(systemSymbol: .ellipsis) }
                .help(Text("quick_action"))
                .accessibilityLabel(Text("quick_action"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: .popupText))
    }
}
