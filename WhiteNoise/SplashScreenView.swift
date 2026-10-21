import SwiftUI

struct SplashScreenView: View {
    var onDismiss: (() -> Void)?

    @State private var isVisible = false

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image("AboutIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color("AccentColor").opacity(0.35), radius: 24, x: 0, y: 8)
                    .scaleEffect(isVisible ? 1.0 : 0.88)

                VStack(spacing: 6) {
                    Text("Sleep Sounds")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("Nature for rest & sleep")
                        .font(.subheadline)
                        .foregroundStyle(Theme.dimText.opacity(0.7))
                }
                .opacity(isVisible ? 1.0 : 0.0)
                .offset(y: isVisible ? 0 : 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onDismiss?()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                isVisible = true
            }
        }
    }
}

#Preview {
    SplashScreenView()
        .preferredColorScheme(.dark)
}
