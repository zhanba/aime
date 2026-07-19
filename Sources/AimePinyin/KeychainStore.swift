import Foundation
import Security

/// LLM API Key 的钥匙串存取（login keychain 通用密码项），替代明文 UserDefaults。
/// app 负责写入；aime-ime 等其他进程首次读取时系统弹一次授权，「始终允许」后静默
/// （签名身份稳定时重新构建不会重弹）。swift build 直接产出的评测 CLI 无稳定签名，
/// 每次重编译都会触发授权弹窗，用 AIME_API_KEY 环境变量绕过。
public enum KeychainStore {
    private static let service = "com.zhanba.aime"
    private static let account = "llm-api-key"

    /// 引擎读取入口：AIME_API_KEY 环境变量优先，其次钥匙串
    public static func loadAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["AIME_API_KEY"], !env.isEmpty {
            return env
        }
        return storedAPIKey()
    }

    /// 钥匙串里的实际存储值（设置页展示与迁移判断用，不受环境变量影响）
    public static func storedAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 空串 = 删除条目
    public static func saveAPIKey(_ key: String) {
        guard !key.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let attrs = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
