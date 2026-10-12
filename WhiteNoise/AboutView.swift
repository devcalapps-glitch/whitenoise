import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private static let privacyURL = URL(string: "https://devcalapps-glitch.github.io/whitenoise/privacy/")!
    private static let supportURL = URL(string: "https://devcalapps-glitch.github.io/whitenoise/support/")!
    private static let supportEmail = "support@longestchariot.com"

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image("AboutIcon")
                            .resizable()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityHidden(true)
                        Text("Sleep Sounds")
                            .font(.title2.weight(.semibold))
                        Text(version)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Label("Collects no data", systemImage: "hand.raised.fill")
                    Label("Works offline", systemImage: "wifi.slash")
                } footer: {
                    Text("No accounts, ads, analytics, or tracking. Every sound is built into the app.")
                }

                Section {
                    Link(destination: Self.privacyURL) {
                        Label("Privacy Policy", systemImage: "lock.shield")
                    }
                    Link(destination: Self.supportURL) {
                        Label("Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "mailto:\(Self.supportEmail)")!) {
                        Label("Contact Us", systemImage: "envelope")
                    }
                } footer: {
                    Text("© 2026 LONGEST CHARIOT LLC")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    AboutView()
        .preferredColorScheme(.dark)
}
