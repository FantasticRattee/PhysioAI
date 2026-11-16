import SwiftUI

struct NativeRootView: View {
    @EnvironmentObject private var app: NativeAppModel

    var body: some View {
        Group {
            switch app.route {
            case .welcome:
                NativeWelcomeView()
            case .login:
                NativeLoginView()
            case .register:
                NativeRegisterView()
            case .home:
                NativeHomeView()
            case .history:
                NativeSessionHistoryView()
            case .communication:
                NativeCommunicationView()
            case .practice:
                if app.selectedExercise?.id == NativeExercise.dynamicWeightShift.id {
                    DWSPracticeScreen()
                } else {
                    NativePracticeView()
                }
            case .summary:
                if let report = app.latestDWSReport, app.latestSummary?.exercise.id == NativeExercise.dynamicWeightShift.id {
                    DWSSessionScoreboard(report: report)
                } else {
                    NativeSummaryView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: app.route)
    }
}
