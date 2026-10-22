import AppKit
import SwiftUI

// MARK: - Choice Flag

/// Tracks whether the user has made an explicit LLM choice. Until they do, the
/// first-launch prompt is shown on every launch while no AI model is selected.
enum FirstRunModelPrompt {
    static let choiceMadeKey = "llmChoiceMade"

    static var hasMadeChoice: Bool { UserDefaults.standard.bool(forKey: choiceMadeKey) }

    /// Call only for user-initiated choices (Settings picker, prompt buttons),
    /// never for programmatic fallbacks.
    static func recordChoice() { UserDefaults.standard.set(true, forKey: choiceMadeKey) }
}

// MARK: - Controller

/// Launch-time window asking whether to install an AI model. Closing it is "Not now":
/// the flag stays unset and the prompt returns on the next launch.
@MainActor
final class FirstRunModelPromptWindowController: NSWindowController {
    /// Kept for the app's lifetime once created (like the other utility windows), so the
    /// hosting view is never released while one of its button actions is running.
    private static var instance: FirstRunModelPromptWindowController?

    private init(coordinator: ConversationCoordinator, recommended: ModelOption) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hitoku Draft"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let view = FirstRunModelPromptView(
            coordinator: coordinator,
            recommended: recommended,
            close: { [weak window] in window?.close() }
        )
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shows the prompt when the user has never made an LLM choice and no model is selected.
    /// Call at launch, after What's New has been dismissed.
    static func checkAndShowIfNeeded(coordinator: ConversationCoordinator) {
        guard !FirstRunModelPrompt.hasMadeChoice else { return }

        // A model is active without the flag (e.g. a custom model added in Settings):
        // that was a choice, so record it and never ask.
        guard coordinator.modelManager.selectedModel.isNone else {
            FirstRunModelPrompt.recordChoice()
            return
        }

        let recommended = ModelRegistry.smartDefault
        guard !recommended.isNone else { return }

        let controller = instance ?? FirstRunModelPromptWindowController(
            coordinator: coordinator,
            recommended: recommended
        )
        instance = controller
        controller.show()
    }
}

// MARK: - View

private struct FirstRunModelPromptView: View {
    let coordinator: ConversationCoordinator
    let recommended: ModelOption
    let close: @MainActor () -> Void

    @Environment(\.openSettings) private var openSettings

    private var bodyText: String {
        let sizeGB = recommended.estimatedMemoryGB
        guard sizeGB > 0 else { return L("first_run.model_body_nosize", recommended.name) }
        return L("first_run.model_body", recommended.name, Self.formattedSize(sizeGB))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "cpu")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("first_run.model_title"))
                        .font(.system(size: 22, weight: .bold))
                    Text(bodyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            // Choices. No Return shortcut on the install button: this window can appear
            // at launch while the user is typing elsewhere, and a stray Return must not
            // start a multi-GB download.
            VStack(spacing: 8) {
                Button(action: installRecommended) {
                    Text(L("first_run.install_recommended")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: chooseInSettings) {
                    Text(L("first_run.choose_in_settings")).frame(maxWidth: .infinity)
                }

                Button(action: continueWithout) {
                    Text(L("first_run.continue_without")).frame(maxWidth: .infinity)
                }

                Text(L("first_run.ask_again_note"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        .background(PromptWindowActivator())
    }

    // MARK: Actions

    /// Same path as picking the model in Settings: select, persist, then switch
    /// (downloads if needed, then loads). Settings opens on the Models tab so the
    /// loading status is visible.
    private func installRecommended() {
        FirstRunModelPrompt.recordChoice()
        coordinator.modelManager.selectedModel = recommended
        UserDefaults.standard.set(recommended.path, forKey: "selectedModelPath")
        Task { await coordinator.switchModel() }
        close()
        openModelSettings()
    }

    /// Leaves the flag unset: the Settings picker records the choice when they pick.
    private func chooseInSettings() {
        close()
        openModelSettings()
    }

    private func continueWithout() {
        FirstRunModelPrompt.recordChoice()
        close()
    }

    private func openModelSettings() {
        SettingsNavigator.shared.requestedTab = .model
        openSettings()
        ActivationPolicyManager.shared.bringWindowsToFront()
    }

    private static func formattedSize(_ gb: Double) -> String {
        gb < 1.0 ? String(format: "%.0f MB", gb * 1024) : String(format: "%.1f GB", gb)
    }
}

// MARK: - Window Activation

/// Bridges into AppKit to force-activate this window for LSUIElement apps.
/// Mirrors the activator used by the What's New window.
private struct PromptWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ActivatorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class ActivatorView: NSView {
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
