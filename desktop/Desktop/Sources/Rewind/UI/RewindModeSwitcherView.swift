import SwiftUI

struct RewindModeSwitcherView: View {
    @Binding var selectedMode: RewindMode

    var body: some View {
        HStack(spacing: 10) {
            ForEach(RewindMode.allCases) { mode in
                modeButton(mode)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OmiColors.border.opacity(0.32), lineWidth: 1)
                )
        )
    }

    private func modeButton(_ mode: RewindMode) -> some View {
        let isSelected = selectedMode == mode

        return Button {
            selectedMode = mode
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.symbol)
                    .scaledFont(size: 12, weight: .semibold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title)
                        .scaledFont(size: 13, weight: .semibold)
                    Text(mode.subtitle)
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? .black : .white)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                isSelected ? OmiColors.purplePrimary.opacity(0.35) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: isSelected ? .black.opacity(0.24) : .clear, radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .help("Switch to \(mode.title)")
    }
}
