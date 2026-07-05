import PdfEditorCore
import SwiftUI

struct EditorRootView: View {
    @ObservedObject var appState: AppState
    @State private var unlockPassword = ""

    var body: some View {
        Group {
            if appState.session.document == nil {
                if let openingURL = appState.openingDocumentURL {
                    OpeningStateView(fileName: openingURL.lastPathComponent)
                } else {
                    EmptyStateView(
                        openAction: appState.openDocument,
                        isOpeningDocument: appState.isOpeningDocument
                    )
                }
            } else {
                NavigationSplitView {
                    SidebarView(session: appState.session)
                } detail: {
                    WorkspaceView(
                        session: appState.session,
                        unlockPassword: $unlockPassword,
                        unlockAction: { appState.unlockDocument(with: unlockPassword) }
                    )
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open PDF…") {
                    appState.openDocument()
                }
                .disabled(appState.isOpeningDocument)

                Button("Save") {
                    appState.saveDocument()
                }
                .disabled(!appState.session.canSave)

                Button("Save As…") {
                    appState.saveDocumentAs()
                }
                .disabled(appState.session.document == nil)
            }
        }
        .alert("PDF Editor", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                appState.errorMessage = nil
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert("Overlay Fallback Required", isPresented: Binding(
            get: { appState.overlaySaveRequest != nil },
            set: { if !$0 { appState.cancelOverlaySave() } }
        )) {
            Button("Cancel", role: .cancel) {
                appState.cancelOverlaySave()
            }
            Button("Continue Save") {
                appState.confirmOverlaySave()
            }
        } message: {
            Text(overlayMessage)
        }
    }

    private var overlayMessage: String {
        guard let request = appState.overlaySaveRequest else {
            return ""
        }

        let overlayLines = request.report.blockOutcomes
            .filter { $0.mode == .overlayFallback }
            .map { "Page \($0.pageIndex + 1): \($0.message)" }

        return ([ "True rewrite is unavailable for some edited blocks. Saving will use visual content overlay for those blocks only." ] + overlayLines)
            .joined(separator: "\n")
    }
}

private struct EmptyStateView: View {
    let openAction: () -> Void
    let isOpeningDocument: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Open a PDF to start editing")
                .font(.largeTitle.bold())
            Text("Digital PDFs will expose editable text blocks. Image-only scans stay read-only.")
                .foregroundStyle(.secondary)
            Button("Open PDF…", action: openAction)
                .buttonStyle(.borderedProminent)
                .disabled(isOpeningDocument)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct OpeningStateView: View {
    let fileName: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Opening PDF…")
                .font(.largeTitle.bold())
            Text(fileName)
                .font(.headline)
            Text("Reading document metadata and preparing the first page.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct SidebarView: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        List(selection: Binding<Int?>(
            get: { session.currentPageIndex },
            set: { session.currentPageIndex = $0 ?? 0 }
        )) {
            ForEach(0..<session.pageCount, id: \.self) { pageIndex in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page \(pageIndex + 1)")
                    Text(statusText(for: pageIndex))
                        .font(.caption)
                        .foregroundStyle(statusColor(for: pageIndex))
                }
                .tag(pageIndex)
            }
        }
        .navigationTitle(session.document?.descriptor.title ?? session.document?.descriptor.sourceURL.lastPathComponent ?? "PDF")
    }

    private func statusText(for pageIndex: Int) -> String {
        switch session.pageLoadState(for: pageIndex) {
        case .unloaded:
            return "Not analyzed"
        case .loading:
            return "Loading"
        case .failed:
            return "Load failed"
        case .loaded:
            guard let report = session.pageReport(for: pageIndex) else {
                return "Read-only"
            }
            return report.isEditable ? "Editable" : "Read-only"
        }
    }

    private func statusColor(for pageIndex: Int) -> Color {
        switch session.pageLoadState(for: pageIndex) {
        case .unloaded:
            return .secondary
        case .loading:
            return .orange
        case .failed:
            return .red
        case .loaded:
            return session.pageReport(for: pageIndex)?.isEditable == true ? .green : .secondary
        }
    }
}

private struct WorkspaceView: View {
    @ObservedObject var session: DocumentSession
    @Binding var unlockPassword: String
    let unlockAction: () -> Void

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ZStack {
                    PageCanvasRepresentable(session: session, pageIndex: session.currentPageIndex)
                    PageLoadOverlay(loadState: session.currentPageLoadState)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                StatusBanner(session: session)
            }
            .frame(minWidth: 700, minHeight: 600)
            .task(id: pageLoadTaskID) {
                guard session.document != nil, !session.requiresPassword else {
                    return
                }

                session.loadBlocksIfNeeded(for: session.currentPageIndex)
            }
            .onChange(of: session.currentPageIndex, initial: false) { _, newPageIndex in
                guard session.selectedBlock?.pageIndex != newPageIndex else {
                    return
                }

                session.selectBlock(nil)
            }

            InspectorView(
                session: session,
                unlockPassword: $unlockPassword,
                unlockAction: unlockAction
            )
            .frame(minWidth: 280, idealWidth: 320)
        }
    }

    private var pageLoadTaskID: String {
        let documentID = session.document?.id.uuidString ?? "no-document"
        return "\(documentID):\(session.currentPageIndex):\(session.requiresPassword)"
    }
}

private struct StatusBanner: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch session.currentPageLoadState {
            case .loading:
                Text("Loading editable blocks for page \(session.currentPageIndex + 1)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("Page \(session.currentPageIndex + 1) block extraction failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .unloaded, .loaded:
                EmptyView()
            }

            if let statusMessage = session.statusMessage {
                Text(statusMessage)
                    .font(.subheadline)
            }

            if let validation = session.lastValidationReport {
                Text("\(validation.validator): \(validation.messages.joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(validation.isValid ? Color.secondary : Color.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial)
    }
}

private struct PageLoadOverlay: View {
    let loadState: PageBlockLoadState

    var body: some View {
        switch loadState {
        case .unloaded, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading editable blocks…")
                    .font(.headline)
                Text("The page preview is ready. Text block extraction is still in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .failed(let message):
            VStack(spacing: 10) {
                Text("Could not load editable blocks")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .loaded:
            EmptyView()
        }
    }
}

private struct InspectorView: View {
    @ObservedObject var session: DocumentSession
    @Binding var unlockPassword: String
    let unlockAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.requiresPassword {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Unlock Required")
                            .font(.headline)
                        SecureField("Password", text: $unlockPassword)
                        Button("Unlock", action: unlockAction)
                            .buttonStyle(.borderedProminent)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Document")
                        .font(.headline)
                    Text(session.document?.descriptor.sourceURL.path ?? "No file loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.document?.descriptor.backend.displayName ?? "No backend")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !session.documentIssues.isEmpty {
                        ForEach(session.documentIssues) { issue in
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Selection")
                        .font(.headline)

                    if let block = session.selectedBlock {
                        Text("Page \(block.pageIndex + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(block.persistenceMode.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(persistenceColor(for: block.persistenceMode))
                        if let persistenceMessage = block.persistenceMessage {
                            Text(persistenceMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        TextEditor(text: Binding(
                            get: { session.draftText },
                            set: { session.updateDraftText($0) }
                        ))
                        .frame(minHeight: 140)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary, lineWidth: 1)
                        }

                        Button("Discard Edit") {
                            session.discardSelectedEdit()
                        }
                        .disabled(session.pendingEdits[block.id] == nil)
                    } else {
                        Text("Click a highlighted text block to inspect or edit it.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let report = session.currentPageReport, !report.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Page")
                            .font(.headline)
                        Text(currentPageStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(currentPageStatusColor)
                        if let loadFailure = session.currentPageLoadState.failureMessage {
                            Text(loadFailure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(report.issues) { issue in
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Page")
                            .font(.headline)
                        Text(currentPageStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(currentPageStatusColor)
                        if let loadFailure = session.currentPageLoadState.failureMessage {
                            Text(loadFailure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func persistenceColor(for mode: BlockPersistenceMode) -> Color {
        switch mode {
        case .trueRewrite:
            return .green
        case .overlayFallback:
            return .orange
        case .blocked:
            return .secondary
        }
    }

    private var currentPageStatusText: String {
        switch session.currentPageLoadState {
        case .unloaded:
            return "Not analyzed"
        case .loading:
            return "Loading"
        case .failed:
            return "Load failed"
        case .loaded:
            return session.currentPageReport?.isEditable == true ? "Editable" : "Read-only"
        }
    }

    private var currentPageStatusColor: Color {
        switch session.currentPageLoadState {
        case .loaded:
            return session.currentPageReport?.isEditable == true ? .green : .secondary
        case .unloaded, .loading:
            return .orange
        case .failed:
            return .red
        }
    }
}
