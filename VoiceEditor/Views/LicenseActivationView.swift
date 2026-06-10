import SwiftUI

struct LicenseActivationView: View {
    var licenseManager: LicenseManager
    @State private var licenseKey = ""

    var body: some View {
        VStack(spacing: 20) {
            if licenseManager.isActivated {
                activatedView
            } else {
                activateView
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Activated State

    private var activatedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text(L("license.activated"))
                .font(.headline)

            if let email = licenseManager.licenseEmail {
                HStack(spacing: 4) {
                    Text(L("license.email"))
                        .foregroundStyle(.secondary)
                    Text(email)
                }
                .font(.callout)
            }

            Button(L("license.deactivate")) {
                licenseManager.deactivate()
            }
            .foregroundStyle(.red)
            .padding(.top, 8)
        }
    }

    // MARK: - Not Activated State

    private var activateView: some View {
        VStack(spacing: 16) {
            Text(L("license.activate_title"))
                .font(.headline)

            HStack {
                TextField(L("license.enter_key"), text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { activate() }

                Button(L("license.activate_button")) { activate() }
                    .buttonStyle(.bordered)
                    .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || licenseManager.isActivating)
            }

            if licenseManager.isActivating {
                ProgressView()
                    .controlSize(.small)
            }

            if let error = licenseManager.activationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(spacing: 8) {
                Link(L("license.get_license"), destination: URL(string: "https://hitokume.gumroad.com/l/hitokudraft")!)
                    .font(.body)

                HStack(spacing: 0) {
                    Text(L("license.already_purchased_prefix"))
                        .foregroundStyle(.secondary)
                    Link(L("license.already_purchased_link"), destination: URL(string: "https://gumroad.com/license-key-lookup")!)
                }
                .font(.caption)
            }
        }
    }

    private func activate() {
        Task {
            await licenseManager.activate(licenseKey: licenseKey)
            if licenseManager.isActivated {
                licenseKey = ""
            }
        }
    }
}
