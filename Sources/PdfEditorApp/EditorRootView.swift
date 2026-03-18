import PdfEditorCore
import SwiftUI

struct EditorRootView: View {
    @ObservedObject var appState: AppState
    @State private var unlockPassword = ""

    var body: some View {
        Group {
            if appState.session.document == nil {
                EmptyStateView(openAction: appState.openDocument)
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

    var body: some View {
        VStack(spacing: 16) {
            Text("Open a PDF to start editing")
                .font(.largeTitle.bold())
            Text("Digital PDFs will expose editable text blocks. Image-only scans stay read-only.")
                .foregroundStyle(.secondary)
            Button("Open PDF…", action: openAction)
                .buttonStyle(.borderedProminent)
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
                    if let report = session.document?.editabilityReport.pageReports.first(where: { $0.pageIndex == pageIndex }) {
                        Text(report.isEditable ? "Editable" : "Read-only")
                            .font(.caption)
                            .foregroundStyle(report.isEditable ? Color.green : Color.secondary)
                    }
                }
                .tag(pageIndex)
            }
        }
        .navigationTitle(session.document?.descriptor.title ?? session.document?.descriptor.sourceURL.lastPathComponent ?? "PDF")
    }
}

private struct WorkspaceView: View {
    @ObservedObject var session: DocumentSession
    @Binding var unlockPassword: String
    let unlockAction: () -> Void

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PageCanvasRepresentable(session: session, pageIndex: session.currentPageIndex)
                StatusBanner(session: session)
            }
            .frame(minWidth: 700, minHeight: 600)

            InspectorView(
                session: session,
                unlockPassword: $unlockPassword,
                unlockAction: unlockAction
            )
            .frame(minWidth: 280, idealWidth: 320)
        }
    }
}

private struct StatusBanner: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                        ForEach(report.issues) { issue in
                            Text(issue.message)
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
}
