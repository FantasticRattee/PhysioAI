import Foundation
import SwiftUI
import UIKit

/// Local-only file export for the supported V8 RuleBasedSession contracts. It
/// deliberately receives already-derived JSON only; it has no API, patient
/// identifier, raw media, or landmark dependency.
enum NativeEvidenceExportError: LocalizedError {
    case noCompletedRepetitions
    case invalidSummary

    var errorDescription: String? {
        switch self {
        case .noCompletedRepetitions:
            return "No completed repetitions are available to export."
        case .invalidSummary:
            return "Evidence JSON summary does not match its repetition records."
        }
    }
}

enum NativeEvidenceExport {
    private static let supportedSchemas: Set<String> = [
        RuleBasedSessionRecorder.schema,
        NativeSitToStandRuleBasedEvidenceV12Module.schema,
    ]

    static func validate(_ data: Data) throws -> RuleBasedSessionRecord {
        let record = try JSONDecoder().decode(RuleBasedSessionRecord.self, from: data)
        let repetitions = record.repetitions
        let correct = repetitions.filter { $0.outcome == .correct }.count
        let incorrect = repetitions.filter { $0.outcome == .incorrect }.count
        let cannotAssess = repetitions.filter { $0.outcome == .cannotAssess }.count
        let incomplete = repetitions.filter { $0.outcome == .incomplete }.count

        guard supportedSchemas.contains(record.schema),
              record.summary.totalReps > 0 else {
            throw NativeEvidenceExportError.noCompletedRepetitions
        }
        guard record.summary.totalReps == repetitions.count,
              record.summary.correctRepCount == correct,
              record.summary.incorrectRepCount == incorrect,
              record.summary.cannotAssessRepCount == cannotAssess,
              record.summary.incompleteRepCount == incomplete else {
            throw NativeEvidenceExportError.invalidSummary
        }
        return record
    }

    static func writeTemporaryFile(_ data: Data) throws -> URL {
        let record = try validate(data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let exerciseSlug: String
        switch record.exerciseID {
        case NativeSitToStandV72AIModule.exerciseID:
            exerciseSlug = "sit-to-stand"
        case NativeBottleGrabCapturePolicy.bottleGrabExerciseID:
            exerciseSlug = "bottle-grab"
        default:
            exerciseSlug = "exercise"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("physioai-\(exerciseSlug)-evidence-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct NativeEvidenceShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct NativeActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
