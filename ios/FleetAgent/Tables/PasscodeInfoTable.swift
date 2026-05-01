import LocalAuthentication

/// Reports biometric authentication availability.
/// Columns: biometric_type, is_available, can_evaluate
struct PasscodeInfoTable: FleetTable {
    static let tableName = "passcode_info"

    static func generate() -> [TableRow] {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        let biometricType: String
        switch context.biometryType {
        case .none:         biometricType = "none"
        case .touchID:      biometricType = "touch_id"
        case .faceID:       biometricType = "face_id"
        case .opticID:      biometricType = "optic_id"
        @unknown default:   biometricType = "unknown"
        }

        return [[
            "biometric_type": biometricType,
            "is_available": canEvaluate ? "1" : "0",
            "can_evaluate": canEvaluate ? "1" : "0",
        ]]
    }
}
