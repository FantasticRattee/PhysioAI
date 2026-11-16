import SwiftUI
import UIKit

struct NativeLoginView: View {
    @EnvironmentObject private var app: NativeAppModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NativePageBackground(horizontalPadding: 20, verticalPadding: 18) {
            VStack(spacing: 0) {
                NativeBackButton(
                    title: app.isThai ? "ย้อนกลับ" : "Back",
                    action: { app.backToWelcome() },
                    fillsWidth: true,
                )
                NativeBrandMark(size: 72)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                Text(app.isThai ? "เข้าสู่ระบบ" : "Log in")
                    .font(.system(size: 30, weight: .heavy))
                    .kerning(-0.7)
                    .foregroundColor(NativeTheme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 8) {
                    NativeField(title: app.isThai ? "อีเมล" : "Email", text: $email, keyboard: .emailAddress, placeholder: "you@email.com")
                    SecureNativeField(title: app.isThai ? "รหัสผ่าน" : "Password", text: $password, placeholder: "••••••••")

                    Button {
                        app.submitLogin(email: email, password: password)
                    } label: {
                        HStack {
                            if app.isBusy { ProgressView().tint(.white) }
                            Text(app.isThai ? "เข้าสู่ระบบ" : "Log in")
                        }
                    }
                    .buttonStyle(NativeFormButtonStyle())
                    .padding(.top, 16)
                    .disabled(app.isBusy)

                    if let message = app.statusMessage {
                        NativeStatusMessage(text: message)
                    }

                }
                .padding(18)
                .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(NativeTheme.line, lineWidth: 1))
                .frame(maxWidth: 520)

                Spacer(minLength: 0)

                Button {
                    app.showRegister()
                } label: {
                    HStack(spacing: 4) {
                        Text(app.isThai ? "ยังไม่มีบัญชี?" : "Don't have an account?")
                        Text(app.isThai ? "สมัคร" : "Sign up")
                            .fontWeight(.heavy)
                            .foregroundColor(NativeTheme.forest)
                    }
                }
                .font(.system(size: 15))
                .foregroundColor(NativeTheme.ink2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
    }
}

struct NativeRegisterView: View {
    @EnvironmentObject private var app: NativeAppModel
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        NativePageBackground(horizontalPadding: 20, verticalPadding: 18) {
            VStack(spacing: 0) {
                NativeBackButton(
                    title: app.isThai ? "ย้อนกลับ" : "Back",
                    action: { app.backToWelcome() },
                    fillsWidth: true,
                )
                Text(app.isThai ? "สมัครสมาชิก" : "Create account")
                    .font(.system(size: 30, weight: .heavy))
                    .kerning(-0.7)
                    .foregroundColor(NativeTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 18)

                VStack(alignment: .leading, spacing: 8) {
                    NativeField(title: app.isThai ? "ชื่อ-นามสกุล" : "Full name", text: $name, keyboard: .default, placeholder: "…")
                    NativeField(title: app.isThai ? "อีเมล" : "Email", text: $email, keyboard: .emailAddress, placeholder: "you@email.com")
                    SecureNativeField(title: app.isThai ? "รหัสผ่าน" : "Password", text: $password, placeholder: "••••••••")
                    SecureNativeField(title: app.isThai ? "ยืนยันรหัสผ่าน" : "Confirm password", text: $confirm, placeholder: "••••••••")

                    Button {
                        app.submitRegister(name: name, email: email, password: password, confirm: confirm)
                    } label: {
                        HStack {
                            if app.isBusy { ProgressView().tint(.white) }
                            Text(app.isThai ? "สมัครสมาชิก" : "Create account")
                        }
                    }
                    .buttonStyle(NativeFormButtonStyle())
                    .padding(.top, 16)
                    .disabled(app.isBusy)

                    if let message = app.statusMessage {
                        NativeStatusMessage(text: message)
                    }
                }
                .padding(18)
                .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(NativeTheme.line, lineWidth: 1))
                .frame(maxWidth: 520)

                Spacer(minLength: 0)
                Button {
                    app.showLogin()
                } label: {
                    HStack(spacing: 4) {
                        Text(app.isThai ? "มีบัญชีอยู่แล้ว?" : "Already have an account?")
                        Text(app.isThai ? "เข้าสู่ระบบ" : "Log in")
                            .fontWeight(.heavy)
                            .foregroundColor(NativeTheme.forest)
                    }
                }
                .font(.system(size: 15))
                .foregroundColor(NativeTheme.ink2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
    }
}

private struct NativeField: View {
    let title: String
    @Binding var text: String
    let keyboard: UIKeyboardType
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.3)
                .foregroundColor(NativeTheme.ink2)
                .padding(.top, 6)
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(NativeTheme.ink3))
                .textInputAutocapitalization(.never)
                .keyboardType(keyboard)
                .font(.system(size: 16))
                .foregroundColor(NativeTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 52)
                .background(NativeTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeTheme.line, lineWidth: 1))
        }
    }
}

private struct SecureNativeField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.3)
                .foregroundColor(NativeTheme.ink2)
                .padding(.top, 6)
            SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(NativeTheme.ink3))
                .font(.system(size: 16))
                .foregroundColor(NativeTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 52)
                .background(NativeTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeTheme.line, lineWidth: 1))
        }
    }
}

enum NativeStatusTone {
    case good
    case warn
    case bad

    var foreground: Color {
        switch self {
        case .good: return NativeTheme.forest
        case .warn: return Color(red: 0.48, green: 0.30, blue: 0.12)
        case .bad: return Color(red: 0.58, green: 0.16, blue: 0.14)
        }
    }

    var background: Color {
        switch self {
        case .good: return NativeTheme.mint.opacity(0.2)
        case .warn: return Color.orange.opacity(0.14)
        case .bad: return Color.red.opacity(0.12)
        }
    }
}

struct NativeStatusMessage: View {
    let text: String
    var tone: NativeStatusTone = .good

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(tone.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 12))
    }
}
