import CryptoKit
import Foundation

enum AIFingerprintError: Error, Equatable, Sendable {
    case invalidInput
    case invalidSourceRevision
    case invalidVersion
    case invalidModelID
}

/// A stable digest of the exact bounded data authorized for an analysis. It
/// deliberately excludes database paths, credentials, and any unbounded
/// source payload. Field lengths make the encoding unambiguous.
enum AIFingerprint {
    static let version = 1

    static func make(
        scope: SynchronizationScope,
        input: CopilotAnalysisInput,
        sourceRevision: String,
        selectedModelID: String?,
        effectiveModelID: String,
        automaticActionConfidenceThreshold: Double = OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold,
        promptVersion: Int,
        outputSchemaVersion: Int
    ) throws -> String {
        guard isSourceRevision(sourceRevision) else { throw AIFingerprintError.invalidSourceRevision }
        guard promptVersion > 0, outputSchemaVersion > 0 else { throw AIFingerprintError.invalidVersion }
        guard AIConsentRepository.isValidModelID(selectedModelID) else { throw AIFingerprintError.invalidModelID }
        guard AIConsentRepository.isValidModelID(effectiveModelID) else { throw AIFingerprintError.invalidModelID }
        guard AIConsentRepository.isValidAutomaticActionConfidenceThreshold(automaticActionConfidenceThreshold) else {
            throw AIFingerprintError.invalidInput
        }
        do {
            try input.validate()
        } catch {
            throw AIFingerprintError.invalidInput
        }

        var material = Data("triage.ai-fingerprint.v\(version)".utf8)
        append(scope.accountID.rawValue, to: &material)
        append(scope.organizationID.rawValue, to: &material)
        append(scope.credentialRevision.rawValue, to: &material)
        append(scope.capabilityRevision.rawValue, to: &material)
        append(sourceRevision, to: &material)
        append(selectedModelID ?? "", to: &material)
        append(effectiveModelID, to: &material)
        append(automaticActionConfidenceThreshold.bitPattern, to: &material)
        append(UInt64(promptVersion), to: &material)
        append(UInt64(outputSchemaVersion), to: &material)
        append(input.candidateID.rawValue, to: &material)
        append(input.contentIsUntrusted ? "1" : "0", to: &material)
        append(input.workItemTitle, to: &material)
        append(input.workItemState, to: &material)
        for reason in input.deterministicReasons.sorted() { append(reason, to: &material) }
        append(input.body, to: &material)
        for label in input.labels.sorted() { append(label, to: &material) }
        for field in input.projectFields.sorted(by: { $0.key < $1.key }) {
            append(field.key, to: &material)
            append(field.value, to: &material)
        }
        // Conversation order is semantic and therefore intentionally retained.
        for excerpt in input.conversation {
            append(excerpt.evidenceID.rawValue, to: &material)
            append(excerpt.authorRole, to: &material)
            append(excerpt.text, to: &material)
            append(UInt64(excerpt.timestamp.timeIntervalSince1970.bitPattern), to: &material)
        }
        for evidenceID in input.evidenceIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            append(evidenceID.rawValue, to: &material)
        }
        for evidence in input.evidence.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            append(evidence.id.rawValue, to: &material)
            append(evidence.actorRole, to: &material)
            append(evidence.text, to: &material)
            append(UInt64(evidence.timestamp.timeIntervalSince1970.bitPattern), to: &material)
            append(UInt64(evidence.explicitDeadline?.timeIntervalSince1970.bitPattern ?? 0), to: &material)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSourceRevision(_ value: String) -> Bool {
        // Normalized GitHub sources use their durable upstream revision (for
        // example an ISO-8601 `updatedAt` value or a bounded ETag), not only
        // an internally generated hex digest. The fingerprint hashes the
        // exact value below, so keep it bounded and free of control data
        // rather than imposing an incompatible representation.
        !value.isEmpty
            && value.utf8.count <= 500
            && value.unicodeScalars.allSatisfy {
                $0.properties.generalCategory != .control
            }
    }

    private static func append(_ value: String, to material: inout Data) {
        append(Data(value.utf8), to: &material)
    }

    private static func append(_ value: UInt64, to material: inout Data) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { material.append(contentsOf: $0) }
    }

    private static func append(_ value: Data, to material: inout Data) {
        append(UInt64(value.count), to: &material)
        material.append(value)
    }
}
