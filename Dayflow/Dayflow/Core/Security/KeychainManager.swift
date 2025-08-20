//
//  KeychainManager.swift
//  Dayflow
//

import Foundation
import Security

/// Thread-safe manager for securely storing API keys in macOS Keychain
final class KeychainManager {
    
    // MARK: - Singleton
    
    static let shared = KeychainManager()
    
    // MARK: - Constants
    
    private let servicePrefix = "com.teleportlabs.dayflow.apikeys"
    private let queue = DispatchQueue(label: "com.teleportlabs.dayflow.keychain", qos: .userInitiated)
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Stores an API key in the keychain
    /// - Parameters:
    ///   - apiKey: The API key to store
    ///   - provider: The provider identifier (e.g., "gemini", "dayflow")
    /// - Returns: true if successful, false otherwise
    @discardableResult
    func store(_ apiKey: String, for provider: String) -> Bool {
        return queue.sync {
            guard let data = apiKey.data(using: .utf8) else { return false }
            
            let service = "\(servicePrefix).\(provider)"
            
            // Delete any existing item first
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            
            // Add new item
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ]
            
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            return status == errSecSuccess
        }
    }
    
    /// Retrieves an API key from the keychain
    /// - Parameter provider: The provider identifier
    /// - Returns: The API key if found, nil otherwise
    func retrieve(for provider: String) -> String? {
        return queue.sync {
            let service = "\(servicePrefix).\(provider)"
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let apiKey = String(data: data, encoding: .utf8) else {
                return nil
            }
            
            return apiKey
        }
    }
    
    /// Deletes an API key from the keychain
    /// - Parameter provider: The provider identifier
    /// - Returns: true if successful, false otherwise
    @discardableResult
    func delete(for provider: String) -> Bool {
        return queue.sync {
            let service = "\(servicePrefix).\(provider)"
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider
            ]
            
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }
    
    /// Checks if an API key exists in the keychain
    /// - Parameter provider: The provider identifier
    /// - Returns: true if the key exists, false otherwise
    func exists(for provider: String) -> Bool {
        return retrieve(for: provider) != nil
    }
}