import SwiftUI

struct InputBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isEnabled: Bool
    @Binding var showVoice: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Microphone button
            Button {
                showVoice = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(isEnabled ? .blue : .gray)
            }
            .disabled(!isEnabled)

            // Text field
            TextField("Ask Claude...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused(isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .onSubmit(onSend)

            // Send button
            Button(action: { isFocused.wrappedValue = false; onSend() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .blue : .gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
