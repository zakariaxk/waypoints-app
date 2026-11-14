import Core
import DesignSystem
import SwiftUI

/// X1 Report or block (plan 10.10).
public struct ReportSheet: View {
    let target: ContentRef
    let thing: String
    let handle: String?
    let blockUser: UserID?
    let safety: any SafetyService
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ContentReportReason?
    @State private var note = ""
    @State private var alsoBlock = false
    @State private var sending = false
    @State private var error: String?
    @State private var done = false
    @State private var failed = 0

    /// `blockUser` is the author to offer blocking; `nil` hides the switch.
    public init(target: ContentRef, thing: String, handle: String? = nil, blockUser: UserID? = nil, safety: any SafetyService) {
        self.target = target; self.thing = thing; self.handle = handle; self.blockUser = blockUser; self.safety = safety
    }

    private static let reasons: [(ContentReportReason, LocalizedStringKey)] = [
        (.spam, "Spam"), (.harassment, "Harassment"), (.nudity, "Nudity"),
        (.dangerousDriving, "Dangerous driving"), (.scam, "Scam"), (.other, "Something else"),
    ]

    public var body: some View {
        Sheet(Text("Report \(thing)")) {
            ScrollView {
                VStack(spacing: 0) {
                    if done {
                        Text("Reported. We review reports within 24 hours.")
                            .typeStyle(.body).foregroundStyle(Color.chalk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.margin)
                        PrimaryButton("Done") { dismiss() }.padding(.horizontal, Space.margin)
                    } else {
                        ForEach(Self.reasons, id: \.0) { value, title in
                            Button {
                                reason = value
                                if value == .harassment, blockUser != nil { alsoBlock = true }
                            } label: {
                                Row(Text(title), trailing: {
                                    Image(systemName: reason == value ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(reason == value ? Color.sodium : Color.gravel)
                                })
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                        Field("Note", text: $note, prompt: "Optional", limit: 300)
                            .padding(.horizontal, Space.margin).padding(.top, Space.s16)
                        if let handle, blockUser != nil {
                            Row(Text("Also block @\(handle)"), showsDivider: false, trailing: {
                                Toggle("", isOn: $alsoBlock).labelsHidden().tint(.sodium)
                            })
                        }
                        VStack(spacing: Space.s8) {
                            PrimaryButton("Send report", isLoading: sending) { send() }
                                .disabled(reason == nil)
                            if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                        }
                        .padding(Space.margin)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .haptic(.fail, trigger: failed)
    }

    private func send() {
        guard let reason else { return }
        sending = true
        error = nil
        Task {
            do {
                try await safety.report(target, reason: reason, note: note.isEmpty ? nil : note)
                if alsoBlock, let blockUser { try await safety.block(blockUser) }
                done = true
            } catch WaypointsError.rateLimited {
                self.error = "You're doing that a lot. Try again in a few minutes."
                failed += 1
            } catch WaypointsError.suspended {
                self.error = "This account is suspended. Write to support@waypoints.app."
                failed += 1
            } catch {
                self.error = "Couldn't send the report. Check your connection and try again."
                failed += 1
            }
            sending = false
        }
    }
}

/// X2 Terms gate: six plain lines and "Agree".
public struct TermsGate: View {
    let safety: any SafetyService
    let onAgree: @MainActor () -> Void
    @State private var sending = false
    @State private var error: String?

    public init(safety: any SafetyService, onAgree: @escaping @MainActor () -> Void) {
        self.safety = safety; self.onAgree = onAgree
    }

    private static let rules: [LocalizedStringKey] = [
        "No harassment.",
        "No nudity.",
        "No street racing content.",
        "No scams.",
        "Report what you see.",
        "We remove people who break these.",
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text("The rules").typeStyle(.display).foregroundStyle(Color.chalk).padding(.top, Space.s48)
            ForEach(Array(Self.rules.enumerated()), id: \.offset) { _, rule in
                Text(rule).typeStyle(.body).foregroundStyle(Color.chalk)
            }
            Link("Read the full Terms", destination: URL(string: "https://waypoints.app/terms")!)
                .typeStyle(.sub).foregroundStyle(Color.sodium)
            Spacer()
            if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
            PrimaryButton("Agree", isLoading: sending) {
                sending = true
                Task {
                    do {
                        try await safety.acceptTerms()
                        onAgree()
                    } catch {
                        self.error = "Couldn't save. Check your connection and try again."
                    }
                    sending = false
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.s24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.asphalt.ignoresSafeArea())
    }
}
