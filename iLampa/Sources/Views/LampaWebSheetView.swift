import SwiftUI

// Modal interactive view embedding the shared WebKit Lampa runtime.
// Smoothly transitions attachment mode from .attachedUnobtrusive (background) to .attachedVisible
// and back on dismissal without reloading the page or losing JavaScript context and plugin state.
@MainActor
struct LampaWebSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host = LampaHeadlessHost.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                LampaHostContainerView(isInteractive: true)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .overlay(alignment: .bottom) {
                if let error = host.compatibilityError {
                    Text(error)
                        .font(.caption)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                        .accessibilityIdentifier("lampaCompatibilityError")
                } else if !host.isAppReady {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            if host.lastLifecycleMessage.hasPrefix("failed") || host.bootstrapStatus.bootstrapError != nil {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text("Lampa недоступна. Нажмите «Обновить».")
                            } else {
                                ProgressView()
                                Text("Подготовка Lampa и восстановление плагинов…")
                            }
                        }
                        .font(.caption)
                        Text(host.lastLifecycleMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("lampaRuntimeStatus")
                }
            }
            .overlay(alignment: .topTrailing) {
                if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                    // Expose actual production lifecycle state; a visible WKWebView alone is not readiness.
                    Text(host.lastLifecycleMessage)
                        .font(.caption2)
                        .padding(4)
                        .background(.regularMaterial)
                        .accessibilityIdentifier("lampaRuntimeState")
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Интерфейс Lampa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        host.bootstrap()
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("reloadLampaButton")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                    .bold()
                    .accessibilityIdentifier("closeLampaSheetButton")
                }
            }
            .onAppear {
                host.setAttachmentMode(.attachedVisible)
            }
            .onDisappear {
                host.setAttachmentMode(.attachedUnobtrusive)
            }
        }
    }
}
