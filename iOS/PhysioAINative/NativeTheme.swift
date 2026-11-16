import SwiftUI

enum NativeTheme {
    // Keep these values in lockstep with Patient/src/core/theme.js. The
    // native lane is a renderer replacement, not a second visual theme.
    static let cream = Color(red: 245 / 255, green: 241 / 255, blue: 232 / 255)
    static let paper = Color(red: 251 / 255, green: 247 / 255, blue: 239 / 255)
    static let surface2 = Color(red: 243 / 255, green: 238 / 255, blue: 227 / 255)
    static let surface3 = Color(red: 233 / 255, green: 225 / 255, blue: 211 / 255)
    static let line = Color(red: 222 / 255, green: 214 / 255, blue: 199 / 255)
    static let ink = Color(red: 42 / 255, green: 40 / 255, blue: 35 / 255)
    static let ink2 = Color(red: 107 / 255, green: 101 / 255, blue: 90 / 255)
    static let ink3 = Color(red: 167 / 255, green: 158 / 255, blue: 140 / 255)
    static let forest = Color(red: 37 / 255, green: 68 / 255, blue: 59 / 255)
    static let mint = Color(red: 123 / 255, green: 168 / 255, blue: 143 / 255)
    static let accent = mint
    static let brandSoft = Color(red: 234 / 255, green: 241 / 255, blue: 236 / 255)
    static let muted = ink2
    static let inverse = cream
}

struct NativePrimaryButtonStyle: ButtonStyle {
    var fill: Color = NativeTheme.forest

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .heavy))
            .foregroundColor(NativeTheme.inverse)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(fill.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct NativeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .heavy))
            .foregroundColor(NativeTheme.forest)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(NativeTheme.paper.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(NativeTheme.line, lineWidth: 1))
    }
}

/// Form action token from Patient/src/screens/LoginScreen.js and
/// RegisterScreen.js (54pt / 14pt radius, distinct from the Welcome CTA).
struct NativeFormButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .heavy))
            .foregroundColor(NativeTheme.inverse)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(NativeTheme.forest.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct NativePageBackground<Content: View>: View {
    let content: Content
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    init(horizontalPadding: CGFloat = 22, verticalPadding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    var body: some View {
        NativeTheme.cream
            .ignoresSafeArea()
            .overlay(
                ScrollView {
                    content
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                }
            )
    }
}

struct NativeBrandMark: View {
    var size: CGFloat = 96

    var body: some View {
        VStack(spacing: 8) {
            NativeLogoMark(size: size)

            HStack(spacing: 0) {
                Text("Physio")
                    .foregroundColor(NativeTheme.ink)
                    .kerning(-0.8)
                Text("AI")
                    .foregroundColor(NativeTheme.forest)
                    .kerning(-0.8)
            }
            .font(.system(size: size * 0.42, weight: .heavy))
        }
    }
}

/// Exact SwiftUI rendering of Patient/src/components/Logo.js. Keeping the
/// path in the same 64x64 coordinate system avoids another hand-drawn logo
/// drifting from the React Native reference.
struct NativeLogoMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 19, y: 46))
                path.addLine(to: CGPoint(x: 47, y: 40))
                path.addLine(to: CGPoint(x: 37, y: 14))
            }
            .stroke(NativeTheme.forest, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(NativeTheme.mint)
                .frame(width: 16, height: 16)
                .position(x: 19, y: 46)
        }
        .frame(width: 64, height: 64)
        .scaleEffect(size / 64)
        .frame(width: size, height: size)
    }
}

struct NativeBackButton: View {
    let title: String
    let action: () -> Void
    var fillsWidth: Bool = false

    var body: some View {
        Button(action: action) {
            Text("‹ \(title)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(NativeTheme.forest)
        }
        .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44, alignment: .leading)
    }
}
