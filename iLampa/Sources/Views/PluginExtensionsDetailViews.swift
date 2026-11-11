import SwiftUI

/// Informational compatibility view conforming to canonical `pluginunsupported` screen:
/// "JS-интерфейс — Этот компонент создаёт собственный JavaScript-интерфейс, который не поддерживается нативным рендерером."
/// Guarantees: No fake "Запустить" button; clear explanation; direct diagnostics links.
struct PluginUnsupportedView: View {
    let pluginName: String
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundColor(.orange)
                        Text("JS-интерфейс не поддерживается")
                            .font(.headline)
                    }

                    Text("Собственные JavaScript-интерфейсы плагина «\(pluginName)» не поддерживаются нативным рендерером. Наличие такого интерфейса не подтверждено только регистрацией компонента.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Что доступно") {
                LabeledContent("Плагин", value: "Данные о расширении")
                LabeledContent("Нативное действие") {
                    Text("Недоступно")
                        .foregroundColor(.orange)
                }
                LabeledContent("Состояние", value: "Без изменений")
            }

            Section("Для диагностики") {
                NavigationLink {
                    LogViewerSubView(initialFilter: nil)
                } label: {
                    HStack {
                        Image(systemName: "terminal")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Просмотреть события в журнале")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Почему компонент не показан нативно")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("unsupportedViewLogsButton")

                NavigationLink {
                    DeveloperToolsView()
                } label: {
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Инструменты разработчика")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Отдельный отладочный интерфейс WebKit")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("unsupportedDevToolsButton")
            }

            Section {
                Text("Фальшивые элементы управления и имитации кнопок исключены. Исходный веб-интерфейс доступен исключительно в режиме разработчика.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("JS-интерфейс")
    }
}

/// Native presentation of third-party plugin actions conforming to canonical `pluginactions` screen
struct PluginActionsView: View {
    let plugin: LampaPluginRecord
    let actions: [PluginRegisteredSource]
    var onExecuteAction: ((PluginRegisteredSource) -> Void)?

    @State private var executedActionMessage: String?
    @State private var showExecutionAlert = false

    var body: some View {
        Form {
            if actions.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Нет зарегистрированных нативных действий")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Действия отображаются только если плагин предоставил исполняемый обратный вызов через мост Lampa.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section("Действия плагина") {
                    ForEach(actions) { action in
                        Button {
                            guard let onExecuteAction else { return }
                            onExecuteAction(action)
                            executedActionMessage = "Команда «\(action.name)» отправлена в среду выполнения."
                            showExecutionAlert = true
                        } label: {
                            HStack {
                                Image(systemName: action.capability.iconName)
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.name)
                                        .font(.body.bold())
                                        .foregroundColor(.primary)
                                    if let desc = action.description {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .disabled(onExecuteAction == nil)
                    }
                }
            }

            Section("Совместимость") {
                NavigationLink(destination: PluginUnsupportedView(pluginName: plugin.name)) {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("JS-only компоненты")
                                .font(.body)
                            Text("Что нельзя открыть нативно")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Действия расширения")
        .alert("Выполнение команды", isPresented: $showExecutionAlert) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(executedActionMessage ?? "")
        }
    }
}

/// Native presentation of `Lampa.SettingsApi` settings conforming to canonical `pluginsettings` screen
struct PluginSettingsApiView: View {
    let plugin: LampaPluginRecord
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Настройки Lampa.SettingsApi")
                        .font(.headline)
                    Text("Параметры отображаются нативно только при подтверждённой регистрации и двусторонней поддержке через мост.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section("Параметры плагина") {
                Text("Подтверждённые настройки с поддержкой чтения и записи недоступны.")
                    .foregroundColor(.secondary)
            }

            Section("Ограничения") {
                NavigationLink(destination: PluginUnsupportedView(pluginName: plugin.name)) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Неподдерживаемые компоненты")
                                .font(.body)
                            Text("Описание без фальшивых элементов управления")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Настройки расширения")
    }
}

/// Plugin collisions and resolution view conforming to canonical `collisions` screen
struct PluginCollisionsView: View {
    let reports: [PluginCollisionReport]

    var body: some View {
        Form {
            if reports.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.largeTitle)
                            .foregroundColor(.green)
                            .padding(.vertical, 4)
                        Text("Конфликтов не обнаружено")
                            .font(.headline)
                        Text("Все активные плагины регистрируют независимые компоненты и не дублируют встроенные модули.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Обнаружены конфликты расширений (\(reports.count))")
                            .font(.headline)
                            .foregroundColor(.orange)
                        Text("В целях стабильности при совпадении идентификаторов компонентов приоритет отдаётся встроенной или явно выбранной версии.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                ForEach(reports, id: \.loser.id) { report in
                    Section(header: Text("Конфликт: \(report.winner.name)")) {
                        HStack {
                            Text("Победитель (активен)")
                            Spacer()
                            Text(report.winner.name)
                                .bold()
                                .foregroundColor(.green)
                        }

                        HStack {
                            Text("Отключён")
                            Spacer()
                            Text(report.loser.name)
                                .foregroundColor(.secondary)
                        }

                        Text(report.userMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Конфликты плагинов")
    }
}
