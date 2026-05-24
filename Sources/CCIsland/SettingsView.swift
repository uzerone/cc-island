import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    let closeAction: () -> Void
    @State private var launchAtLogin: Bool = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var linkHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            Divider().background(Color.white.opacity(0.08))

            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
            .toggleStyle(SwitchToggleStyle())
            .tint(.green)
            .onChange(of: launchAtLogin) { newValue in
                do {
                    try LoginItem.set(enabled: newValue)
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                    launchAtLogin = LoginItem.isEnabled
                }
            }

            if let err = loginError {
                Text(err)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.orange.opacity(0.9))
                    .lineLimit(2)
            }

            Divider().background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("CC Island")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text("v\(BundleInfo.version) (\(BundleInfo.build))")
                        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundColor(.white.opacity(0.5))
                }
                Text("A Dynamic-Island-style monitor for Claude Code usage.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                Button {
                    if let url = URL(string: "https://github.com/uzerone") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .bold))
                        Text("github.com/uzerone")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .underline()
                    }
                    .foregroundColor(linkHover
                                     ? Color(red: 0.55, green: 0.85, blue: 1.0)
                                     : Color(red: 0.55, green: 0.85, blue: 1.0).opacity(0.75))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(
                        Capsule().fill(Color.white.opacity(linkHover ? 0.1 : 0))
                    )
                    // Hit-test the full padded area, not just the glyphs.
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    linkHover = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.red.opacity(0.55)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

enum BundleInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

/// Toggles launch-at-login via the modern `SMAppService` API (macOS 13+).
/// Falls back gracefully on older systems by reporting via a thrown error.
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func set(enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(domain: "CCIsland", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Requires macOS 13+"])
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
