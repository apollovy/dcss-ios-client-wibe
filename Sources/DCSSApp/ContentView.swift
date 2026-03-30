import SwiftUI

struct ContentView: View {
    @State private var vm = GameViewModel()

    var body: some View {
        TabView {
            ConnectView(vm: vm)
                .tabItem { Label("Connect", systemImage: "network") }

            GameScreenView(vm: vm)
                .tabItem { Label("Game", systemImage: "gamecontroller") }

            SettingsView(vm: vm)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

private struct ConnectView: View {
    let vm: GameViewModel

    var body: some View {
        NavigationStack {
            Form {
                TextField("WebSocket URL", text: Bindable(vm).serverURL)
                    .autocorrectionDisabled()
                Text("Status: \(vm.connectionStatus)")
                Text("Message: \(vm.lastMessage)")

                HStack {
                    Button("Connect") {
                        Task { await vm.connect() }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Disconnect") {
                        Task { await vm.disconnect() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .navigationTitle("DCSS Connect")
        }
    }
}

private struct GameScreenView: View {
    let vm: GameViewModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(vm.statusLine)
                    .font(.headline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(vm.grid.indices, id: \.self) { idx in
                            Text(vm.grid[idx])
                                .font(.system(size: 14 * vm.fontScale, weight: .regular, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    TextField("Command", text: Bindable(vm).commandInput)
                        .autocorrectionDisabled()
                    Button("Send") {
                        Task { await vm.sendCommand() }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Heartbeat") {
                    Task { await vm.heartbeat() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Game")
        }
    }
}

private struct SettingsView: View {
    let vm: GameViewModel

    var body: some View {
        NavigationStack {
            Form {
                Slider(value: Bindable(vm).fontScale, in: 0.8...1.8, step: 0.1) {
                    Text("Font scale")
                }
                Text("Font scale: \(vm.fontScale, format: .number.precision(.fractionLength(1)))")
                Button("Save") {
                    vm.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Settings")
        }
    }
}
