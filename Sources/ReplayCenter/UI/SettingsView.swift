import SwiftUI

struct SettingsView: View {
    @Bindable var model: TileGridModel
    let onClose: () -> Void
    @State private var startupStreams: StartupStreamsMode
    @State private var tileLayout: TileLayoutConfig
    @State private var errorMessage: String?

    init(model: TileGridModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _startupStreams = State(initialValue: model.settings.startupStreams ?? .configured)
        _tileLayout = State(initialValue: model.layout)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.54)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(alignment: .leading, spacing: 14) {
                    Picker("起動時ストリーム", selection: $startupStreams) {
                        Text("設定ファイル").tag(StartupStreamsMode.configured)
                        Text("空").tag(StartupStreamsMode.empty)
                    }
                    .pickerStyle(.segmented)

                    Picker("タイル配置", selection: $tileLayout) {
                        ForEach(TileLayoutConfig.presets, id: \.self) { layout in
                            Text(layout.summary).tag(layout)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("キャンセル") {
                        onClose()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    Button("保存") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(18)
            .frame(width: 420)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 20)
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var header: some View {
        HStack {
            Text("設定")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private func save() {
        let settings = AppSettings(startupStreams: startupStreams)
        guard model.applySettings(settings, tileLayout: tileLayout) else {
            errorMessage = "削除されるタイルを未割り当てにしてください。"
            return
        }
        onClose()
    }
}
