import SwiftUI

struct NativeWelcomeView: View {
    @EnvironmentObject private var app: NativeAppModel

    var body: some View {
        ZStack {
            NativeTheme.cream.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(app.isThai ? "EN" : "ไทย") {
                        app.setLanguage(app.isThai ? "en" : "th")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(NativeTheme.forest)
                    .frame(minHeight: 36)
                    .padding(.horizontal, 14)
                    .background(NativeTheme.paper, in: Capsule())
                    .overlay(Capsule().stroke(NativeTheme.line, lineWidth: 1))
                }
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    NativeBrandMark(size: 96)
                    Text(app.isThai ? "ยินดีต้อนรับสู่ PhysioAI" : "Welcome to PhysioAI")
                        .font(.system(size: 30, weight: .heavy))
                        .kerning(-0.8)
                        .foregroundColor(NativeTheme.ink)
                        .multilineTextAlignment(.center)
                    Text(app.isThai ? "AI กายภาพบำบัดที่นำคุณฝึกที่บ้าน" : "AI physiotherapy that guides you at home")
                        .font(.system(size: 15))
                        .foregroundColor(NativeTheme.ink2)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                // React Native's hero reserves a 20pt bottom inset. Keep the
                // SwiftUI hero on the same vertical baseline instead of
                // letting its intrinsic text height drift the mark downward.
                .padding(.bottom, 20)
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Button {
                        app.fixtureMode = false
                        app.showLogin()
                    } label: {
                        Text(app.isThai ? "เข้าสู่ระบบ" : "Log in")
                    }
                    .buttonStyle(NativePrimaryButtonStyle())

                    Button {
                        app.fixtureMode = false
                        app.showRegister()
                    } label: {
                        Text(app.isThai ? "สมัครสมาชิก" : "Create account")
                    }
                    .buttonStyle(NativeSecondaryButtonStyle())
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 480, maxHeight: .infinity)
        }
    }
}
