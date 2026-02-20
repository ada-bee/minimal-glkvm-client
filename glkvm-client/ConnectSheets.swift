import SwiftUI

struct PasswordPromptSheet: View {
    @Binding var isPresented: Bool
    @Binding var password: String

    let onCancel: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Required")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    isPresented = false
                }
                Button("Connect") {
                    onConnect()
                    isPresented = false
                }
                .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
