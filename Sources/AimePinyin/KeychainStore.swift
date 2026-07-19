import Foundation
import Security

/// LLM API Key 的钥匙串存取（login keychain 通用密码项），替代明文 UserDefaults。
/// app 负责写入，写入时把 aime.app 与 aime-ime.app 一并写进条目 ACL 信任列表，
/// 两个进程读取都不弹授权（SecTrustedApplication 系 API 已废弃但无替代——
/// 现代方案 keychain access group 需要 app group entitlement + Team ID，
/// 等 Developer ID 签名落地时再迁）。swift build 直接产出的评测 CLI 不在信任列表，
/// 读取会弹授权，用 AIME_API_KEY 环境变量绕过。
public enum KeychainStore {
    private static let service = "com.zhanba.aime"
    private static let account = "llm-api-key"

    /// ACL 信任的读取方：本进程 + 安装位置的 app 与 IME（路径不存在的自动跳过）
    private static let trustedAppPaths = [
        "/Applications/aime.app",
        ("~/Library/Input Methods/aime-ime.app" as NSString).expandingTildeInPath,
    ]

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

    /// 空串 = 删除条目。始终删旧建新：ACL 只能在建条目时指定，
    /// SecItemUpdate 不会补上后装的信任方
    public static func saveAPIKey(_ key: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !key.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        if let access = makeAccess() {
            query[kSecAttrAccess as String] = access
        }
        SecItemAdd(query as CFDictionary, nil)
    }

    /// app 启动时调用：把现存条目按当前信任列表重建。
    /// 修复旧条目（无 ACL 或 IME 尚未安装时创建的），幂等
    public static func repairAccess() {
        guard let key = storedAPIKey(), !key.isEmpty else { return }
        saveAPIKey(key)
    }

    private static func makeAccess() -> SecAccess? {
        var trusted: [SecTrustedApplication] = []
        var selfApp: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &selfApp) == errSecSuccess, let selfApp {
            trusted.append(selfApp)
        }
        for path in trustedAppPaths {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app {
                trusted.append(app)
            }
        }
        var access: SecAccess?
        guard SecAccessCreate("aime LLM API Key" as CFString, trusted as CFArray, &access) == errSecSuccess else {
            return nil
        }
        return access
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
