import AppKit
import SwiftUI

final class AcknowledgmentsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AcknowledgmentsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Acknowledgments"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AcknowledgmentsView())
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Main View

struct AcknowledgmentsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                Text("Hitoku Draft is a commercial macOS app built on open-source software and open-weight AI models. All components are compatible with commercial distribution under the terms described below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Swift Libraries
                AckSectionHeader("Swift Libraries")

                LibraryCard(
                    name: "FluidAudio",
                    source: "github.com/FluidInference/FluidAudio (local vendored copy)",
                    license: "Apache 2.0",
                    usedFor: "Speech-to-text via Parakeet TDT v3 CoreML, voice activity detection, silence detection"
                )

                LibraryCard(
                    name: "mlx-swift-lm",
                    source: "github.com/ml-explore/mlx-swift-examples (local vendored copy)",
                    license: "MIT — Copyright © 2024 ml-explore",
                    usedFor: "LLM loading (MLXLLM, MLXLMCommon), model factory, generation pipeline"
                )

                LibraryCard(
                    name: "mlx-swift — v0.30.6",
                    source: "github.com/ml-explore/mlx-swift",
                    license: "MIT — Copyright © 2024 ml-explore",
                    usedFor: "Core Apple Silicon tensor operations underlying all LLM inference"
                )

                LibraryCard(
                    name: "KeyboardShortcuts — v2.4.0",
                    source: "github.com/sindresorhus/KeyboardShortcuts",
                    license: "MIT — Copyright © Sindre Sorhus",
                    usedFor: "Global hotkey registration (voice edit, dictation, grammar fix)"
                )

                // Transitive Dependencies
                AckSectionHeader("Transitive Dependencies")

                TransitiveDepsGrid(deps: [
                    ("swift-transformers", "1.1.9", "Apache 2.0"),
                    ("swift-jinja", "2.3.2", "Apache 2.0"),
                    ("swift-collections", "1.4.0", "Apache 2.0"),
                    ("swift-crypto", "4.2.0", "Apache 2.0"),
                    ("swift-asn1", "1.5.1", "Apache 2.0"),
                    ("swift-numerics", "1.1.1", "Apache 2.0"),
                    ("yyjson", "0.12.0", "MIT"),
                ])

                // AI Models
                AckSectionHeader("AI Models (downloaded at runtime)")
                Text("Not embedded in the app binary or DMG. Downloaded on first launch and cached locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ModelCard(
                    name: "NVIDIA Parakeet TDT 0.6B v3 (CoreML)",
                    license: "CC BY 4.0 — Attribution required, commercial use permitted",
                    by: "NVIDIA",
                    note: "Attribution: \"Parakeet TDT 0.6B v3 by NVIDIA, licensed under CC BY 4.0\""
                )

                ModelCard(
                    name: "Qwen3 4B / 8B 4-bit",
                    license: "Apache 2.0 — Commercial use permitted",
                    by: "Alibaba Cloud (Qwen Team)"
                )

                ModelCard(
                    name: "IBM Granite 4.0 1B 4-bit / 8-bit",
                    license: "Apache 2.0 — Commercial use permitted",
                    by: "IBM Research"
                )

                ModelCard(
                    name: "LFM2.5 1.2B Instruct 4-bit / 8-bit  ⚠️",
                    license: "LFM Open License v1.0 (Apache 2.0 base + revenue cap)",
                    by: "Liquid AI",
                    note: "Free for companies with < $10M annual revenue. Above that threshold, a paid license from Liquid AI is required."
                )

                Divider()

                Text("Last updated: March 2026")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 540)
        .background(AckWindowActivator())
    }
}

// MARK: - Subviews

private struct AckSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Divider()
        }
    }
}

private struct LibraryCard: View {
    let name: String
    let source: String
    let license: String
    let usedFor: String

    var body: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(source)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("License")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(license)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Used for")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(usedFor)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 2)
        } label: {
            Text(name)
                .font(.subheadline)
                .bold()
        }
    }
}

private struct TransitiveDepsGrid: View {
    let deps: [(String, String, String)]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Package").font(.caption).bold().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Version").font(.caption).bold().foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text("License").font(.caption).bold().foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))

            ForEach(Array(deps.enumerated()), id: \.offset) { index, dep in
                HStack {
                    Text(dep.0).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(dep.1).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(width: 70, alignment: .leading)
                    Text(dep.2).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(width: 100, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
    }
}

private struct ModelCard: View {
    let name: String
    let license: String
    let by: String
    var note: String? = nil

    var body: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("License")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(license)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("By")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(by)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if let note {
                    GridRow {
                        Text("Note")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            Text(name)
                .font(.subheadline)
                .bold()
        }
    }
}

// MARK: - Window Activation

/// Bridges into AppKit to force-activate the Acknowledgments window for LSUIElement apps.
/// Mirrors the WindowActivator pattern used in SettingsView.
private struct AckWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AckActivatorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class AckActivatorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                ActivationPolicyManager.shared.trackWindow(window)
                window.standardWindowButton(.closeButton)?.keyEquivalent = "\u{1B}"
                window.standardWindowButton(.closeButton)?.keyEquivalentModifierMask = []
            }
        }
    }
}
