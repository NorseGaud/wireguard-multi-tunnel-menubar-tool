import Foundation

enum StealthArgSecurity {
    // Allowlist: letters, digits, and common flag/value punctuation. No whitespace or shell ops.
    private static let allowedCharacters =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=+.:/@"
    private static let allowed = CharacterSet(charactersIn: allowedCharacters)

    static func validateExtraArgs(_ args: [String]) throws {
        for arg in args {
            guard !arg.isEmpty else {
                throw StealthValidationError.invalidExtraArgs(arg)
            }
            guard arg.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw StealthValidationError.invalidExtraArgs(arg)
            }
        }
    }
}
