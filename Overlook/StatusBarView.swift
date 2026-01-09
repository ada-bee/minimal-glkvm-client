import SwiftUI

struct StatusBarView: View {
    let deviceName: String
    let isConnected: Bool
    let latency: Int

    var body: some View {
        HStack {
            Text(deviceName)
                .font(.caption)

            Spacer()

            Text(isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(isConnected ? .green : .red)

            Text("Latency: \(latency)ms")
                .font(.caption)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}
