import SwiftUI

struct HostContentView: View {
    @State private var vm = HostViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    TextField("WebSocket URL", text: Bindable(vm).serverURL)
                        .autocorrectionDisabled()

                    Text("Status: \(vm.connectionStatus)")
                    Text("Message: \(vm.lastMessage)")

                    Section("Diagnostics") {
                        Text("Last event: \(vm.debugLastEvent)")
                        Text("Reconnect attempt: \(vm.debugReconnectAttempt)")
                        Text("Last error: \(vm.debugLastError)")
                    }

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
                .navigationTitle("Connect")
            }
            .tabItem { Label("Connect", systemImage: "network") }

            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(vm.statusLine).font(.headline)

                    GroupBox("Msgs (raw JSON)") {
                        ScrollView {
                            Text(vm.msgsJsonLog.isEmpty ? "—" : vm.msgsJsonLog.joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 72, maxHeight: 220)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.grid.indices, id: \.self) { idx in
                                Text(vm.grid[idx])
                                    .font(.system(size: 14, design: .monospaced))
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
                        Task { await vm.sendHeartbeat() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .navigationTitle("Game")
            }
            .tabItem { Label("Game", systemImage: "gamecontroller") }
        }
        .task { await vm.runSnapshotPollLoop() }
        .onChange(of: scenePhase) { _, newValue in
            Task {
                if newValue == .background {
                    await vm.appDidEnterBackground()
                } else if newValue == .active {
                    await vm.appWillEnterForeground()
                }
            }
        }
    }
}
