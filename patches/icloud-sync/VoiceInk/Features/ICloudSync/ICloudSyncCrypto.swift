import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Passphrase-based encryption for the API keys stored in the iCloud Drive sync file.
/// PBKDF2-HMAC-SHA256 derives the key, AES-GCM encrypts and authenticates the payload.
enum ICloudSyncCrypto {
    struct SealedPayload: Codable {
        let salt: Data
        let rounds: UInt32
        let combined: Data
    }

    enum CryptoError: LocalizedError {
        case randomFailed
        case keyDerivationFailed
        case wrongPassphrase

        var errorDescription: String? {
            switch self {
            case .randomFailed, .keyDerivationFailed:
                return "Could not encrypt the API keys."
            case .wrongPassphrase:
                return "The API key passphrase does not match the one used on your other Mac."
            }
        }
    }

    private static let rounds: UInt32 = 310_000
    private static var cachedKey: (passphrase: String, salt: Data, rounds: UInt32, key: SymmetricKey)?

    static func seal(_ plaintext: Data, passphrase: String, reusingSaltFrom existing: SealedPayload?) throws
        -> SealedPayload
    {
        let salt: Data
        if let existing, existing.rounds == rounds, (try? open(existing, passphrase: passphrase)) != nil {
            salt = existing.salt
        } else {
            salt = try randomBytes(count: 16)
        }
        let key = try deriveKey(passphrase: passphrase, salt: salt, rounds: rounds)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw CryptoError.keyDerivationFailed }
        return SealedPayload(salt: salt, rounds: rounds, combined: combined)
    }

    static func open(_ sealed: SealedPayload, passphrase: String) throws -> Data {
        let key = try deriveKey(passphrase: passphrase, salt: sealed.salt, rounds: sealed.rounds)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.combined), using: key)
        } catch {
            throw CryptoError.wrongPassphrase
        }
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw CryptoError.randomFailed
        }
        return Data(bytes)
    }

    private static func deriveKey(passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        if let cachedKey, cachedKey.passphrase == passphrase, cachedKey.salt == salt, cachedKey.rounds == rounds {
            return cachedKey.key
        }

        let password = Array(passphrase.utf8).map { CChar(bitPattern: $0) }
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            rounds,
            &derived, derived.count
        )
        guard status == Int32(kCCSuccess) else { throw CryptoError.keyDerivationFailed }

        let key = SymmetricKey(data: derived)
        cachedKey = (passphrase, salt, rounds, key)
        return key
    }
}
