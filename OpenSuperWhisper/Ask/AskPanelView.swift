import SwiftUI

/// The floating Ask panel: one card that holds a question, what the on-device
/// model made of it, and the four things a user can do next.
///
/// Everything it draws comes from `AskPanelViewModel`; it makes no decision of
/// its own beyond how to render one.
struct AskPanelView: View {

    /// Geometry shared with `AskPanelWindowController`. The window is larger
    /// than the card on purpose: the card draws its own shadow, and anything
    /// outside the *window* bounds is cut off - the same constraint
    /// `IndicatorWindow` and `CapsuleHUDView` document.
    static let cardSize = CGSize(width: 440, height: 380)
    static let shadowMargin: CGFloat = 24
    static let windowSize = CGSize(
        width: cardSize.width + shadowMargin * 2,
        height: cardSize.height + shadowMargin * 2
    )

    @ObservedObject var viewModel: AskPanelViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        card
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Material.regularMaterial)
                    .overlay {
                        // A hairline of definition. Material alone disappears
                        // against both a light window and a dark one.
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.5 : 0.22),
                        radius: 18,
                        y: 6
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // The root view must fill the panel: a hosting view left to size
            // itself would shrink the window to the card and clip the shadow.
            .frame(width: Self.windowSize.width, height: Self.windowSize.height)
            .onAppear { isFieldFocused = true }
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            conversation
            Divider().opacity(0.5)
            composer
            actions
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("Ask")
                .font(.system(size: 13, weight: .semibold))

            // The one claim worth making on this surface: the question and the
            // answer never leave this Mac. See `docs/ask-panel.md`.
            Text("On device")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                }

            Spacer(minLength: 8)

            Button {
                viewModel.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the Ask panel")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - The conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.exchanges) { exchange in
                        exchangeView(exchange)
                            .id(exchange.id)
                    }
                    liveRow
                        .id(Self.liveRowID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: viewModel.state) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.liveRowID, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private static let liveRowID = "ask.live"

    @ViewBuilder
    private func exchangeView(_ exchange: AskExchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let screen = exchange.screen {
                screenBadge(screen, caption: "Asked about this screen")
            }
            questionLine(exchange.question)
            answerCard(exchange.answer)
        }
    }

    // MARK: - What the model was shown

    /// The screenshot a ⌥S question was asked about.
    ///
    /// It is shown, not merely mentioned: the whole risk of a screen query is
    /// answering about the wrong window, and a thumbnail is the only way the user
    /// can tell at a glance that the right one was captured. It stays with the
    /// exchange afterwards, so an answer three questions back still says which
    /// screen it was about.
    private func screenBadge(_ screen: ScreenObservation, caption: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(decorative: screen.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(screen.source.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Screenshot of \(screen.source.label)")
    }

    /// Wide enough to recognise a window by, small enough that the answer stays
    /// the thing being read.
    static let thumbnailSize = CGSize(width: 64, height: 40)

    /// The row that changes: whatever the panel is doing right now, under
    /// everything it has already done.
    @ViewBuilder
    private var liveRow: some View {
        switch viewModel.state {
        case .idle:
            if viewModel.exchanges.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask a question")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Type it below, hold your shortcut and say \"Ask: …\", or press ⌥S to ask about what is on your screen. Answers are generated on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

        case .listening:
            VStack(alignment: .leading, spacing: 6) {
                if let screen = viewModel.pendingScreen {
                    screenBadge(screen, caption: "Asking about this screen")
                } else if viewModel.isScreenQuery {
                    // The shortcut takes the screenshot and starts the recording
                    // at the same moment, so this is what the first fraction of a
                    // second of every screen query looks like.
                    statusRow(systemImage: "viewfinder", tint: .secondary, text: "Capturing the screen…")
                }
                statusRow(
                    systemImage: "mic.fill",
                    tint: .red,
                    text: viewModel.isScreenQuery ? "Listening - ask about this screen…" : "Listening…"
                )
            }

        case .transcribing:
            VStack(alignment: .leading, spacing: 6) {
                if let screen = viewModel.pendingScreen {
                    screenBadge(screen, caption: "Asking about this screen")
                } else if viewModel.isScreenQuery {
                    statusRow(systemImage: "viewfinder", tint: .secondary, text: "Capturing the screen…")
                }
                progressRow("Transcribing…")
            }

        case .thinking(let question):
            VStack(alignment: .leading, spacing: 6) {
                if let screen = viewModel.pendingScreen {
                    screenBadge(screen, caption: "Asking about this screen")
                } else if viewModel.isScreenQuery {
                    // A spoken question can finish transcribing before its
                    // screenshot arrives; the question is waiting for it, and
                    // the panel says so instead of claiming to think.
                    statusRow(systemImage: "viewfinder", tint: .secondary, text: "Capturing the screen…")
                }
                questionLine(question)
                progressRow("Thinking…")
            }

        case .answered:
            // Already drawn by the loop above - `exchanges` holds the exchange
            // the moment it arrives, so drawing it here too would show it twice.
            EmptyView()

        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func questionLine(_ question: String) -> some View {
        Text(question)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerCard(_ answer: String) -> some View {
        Text(answer)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.09))
            }
    }

    private func statusRow(systemImage: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            PulsingLabel(text: text)
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14)
            PulsingLabel(text: text)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask anything…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1 ... 3)
                .focused($isFieldFocused)
                .disabled(viewModel.isBusy)
                .onSubmit { Task { await viewModel.submit() } }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.textBackgroundColor).opacity(colorScheme == .dark ? 0.35 : 0.7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(borderColor, lineWidth: 0.5)
                        }
                }

            Button {
                Task { await viewModel.submit() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(viewModel.canSubmitDraft ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmitDraft)
            // Return is handled by the field's own `onSubmit`, not by a
            // shortcut here: two paths onto the same action would submit twice.
            .help("Ask this question")
            .accessibilityLabel("Ask")
        }
        // A `.plain` field has no disabled appearance of its own, so without
        // this the box looks typeable while a recording or an answer is in
        // flight and the keystrokes go nowhere.
        .opacity(viewModel.isBusy ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Copy") { viewModel.copyAnswer() }
                .disabled(!viewModel.canUseAnswer)
                .help("Copy the answer to the clipboard")
                .accessibilityLabel("Copy to Clipboard")

            Button("Insert") { viewModel.insertAnswer() }
                .disabled(!viewModel.canUseAnswer)
                .help("Paste the answer into the app you were last using")
                .accessibilityLabel("Insert into Active App")

            Spacer(minLength: 4)

            voiceButton

            Button("Close") { viewModel.close() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var voiceButton: some View {
        switch viewModel.state {
        case .listening:
            HStack(spacing: 6) {
                Button {
                    viewModel.cancelVoiceFollowUp()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Discard this recording")
                .accessibilityLabel("Discard recording")

                Button {
                    viewModel.finishVoiceFollowUp()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Stop recording and ask what you said")
            }

        case .idle, .answered, .failed, .transcribing, .thinking:
            Button {
                viewModel.startVoiceFollowUp()
            } label: {
                Label("Ask by voice", systemImage: "mic.fill")
            }
            .disabled(viewModel.isBusy)
            .help("Record your next question")
            .accessibilityLabel("Voice Follow-up")
        }
    }
}

#Preview("Ask panel") {
    let answered = AskPanelViewModel { _ in
        .answered("Taipei is the capital of Taiwan. It sits at the northern end of the island.")
    }
    let thinking = AskPanelViewModel { _ in .timedOut }

    return HStack(spacing: 0) {
        AskPanelView(viewModel: answered)
        AskPanelView(viewModel: thinking)
    }
    .background(Color(.windowBackgroundColor))
    .task {
        await answered.ask("What is the capital of Taiwan?")
        thinking.startVoiceFollowUp()
    }
}
