import SwiftUI
import AppKit
import Combine
import ServiceManagement
import Foundation

private let appVersion: String = {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    return "v\(short)"
}()

private let appShortVersion: String = {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}()

private let requiredRootHelperVersion = "1.42"

// MARK: - GitHub updater

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let assets: [GitHubReleaseAsset]

    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    var appZip: GitHubReleaseAsset? {
        assets.first { $0.name.hasPrefix("L2TP-Office-") && $0.name.hasSuffix(".zip") }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published var checking = false
    @Published var installing = false
    @Published var statusText = ""

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/svkostrov/L2TpMac/releases/latest")!

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkForUpdates(silent: true)
        }
    }

    func checkForUpdates(silent: Bool) {
        guard !checking, !installing else { return }
        checking = true
        statusText = "Проверяю…"

        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("L2TP-Office/\(appShortVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, error in
            Task { @MainActor in
                self.checking = false
                if let error {
                    self.statusText = "Не удалось проверить обновления: \(error.localizedDescription)"
                    if !silent { self.showMessage(self.statusText) }
                    return
                }
                guard let data,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                      release.appZip != nil else {
                    self.statusText = "Не удалось прочитать latest release."
                    if !silent { self.showMessage(self.statusText) }
                    return
                }
                guard Self.compareVersions(release.version, appShortVersion) == .orderedDescending else {
                    self.statusText = "Актуальная версия"
                    if !silent { self.showMessage(self.statusText) }
                    return
                }
                self.statusText = "Доступно v\(release.version)"
                self.askToInstall(release)
            }
        }.resume()
    }

    private func askToInstall(_ release: GitHubRelease) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Доступно обновление L2TP Office"
        alert.informativeText = "Установлена \(appVersion), доступна v\(release.version). Скачать и установить обновление из GitHub Releases?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Обновить")
        alert.addButton(withTitle: "Позже")
        alert.addButton(withTitle: "Открыть релиз")
        let answer = alert.runModal()
        if answer == .alertFirstButtonReturn {
            install(release)
        } else if answer == .alertThirdButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func install(_ release: GitHubRelease) {
        guard let asset = release.appZip else { return }
        installing = true
        statusText = "Скачиваю v\(release.version)..."

        URLSession.shared.downloadTask(with: asset.browserDownloadURL) { location, _, error in
            if let error {
                Task { @MainActor in
                    self.installing = false
                    self.statusText = "Ошибка скачивания: \(error.localizedDescription)"
                    self.showMessage(self.statusText)
                }
                return
            }
            guard let location else {
                Task { @MainActor in
                    self.installing = false
                    self.statusText = "GitHub не вернул файл обновления."
                    self.showMessage(self.statusText)
                }
                return
            }

            do {
                let fm = FileManager.default
                let workDir = fm.temporaryDirectory.appendingPathComponent("l2tp-office-update-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                let zipURL = workDir.appendingPathComponent(asset.name)
                try fm.moveItem(at: location, to: zipURL)

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zipURL.path, workDir.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { throw NSError(domain: "Updater", code: 1) }

                let newApp = workDir.appendingPathComponent("L2TP Office.app", isDirectory: true)
                guard fm.fileExists(atPath: newApp.path) else { throw NSError(domain: "Updater", code: 2) }
                let scriptURL = workDir.appendingPathComponent("install-update.sh")
                let script = Self.installScript(newAppPath: newApp.path)
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

                Task { @MainActor in
                    self.statusText = "Устанавливаю v\(release.version)..."
                    self.runInstaller(scriptPath: scriptURL.path)
                }
            } catch {
                Task { @MainActor in
                    self.installing = false
                    self.statusText = "Ошибка подготовки обновления."
                    self.showMessage(self.statusText)
                }
            }
        }.resume()
    }

    private func runInstaller(scriptPath: String) {
        let osa = "do shell script \"\(Self.appleScriptQuoted("/bin/bash \(Self.shellQuote(scriptPath))"))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", osa]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            installing = false
            statusText = "Не удалось запустить установщик."
            showMessage(statusText)
        }
    }

    nonisolated private static func installScript(newAppPath: String) -> String {
        """
        #!/bin/bash
        set -euo pipefail
        NEW_APP=\(shellQuote(newAppPath))
        TARGET="/Applications/L2TP Office.app"
        /usr/bin/osascript -e 'tell application id "com.rokot.l2tp-office" to quit' >/dev/null 2>&1 || true
        sleep 2
        /bin/rm -rf "$TARGET"
        /usr/bin/ditto "$NEW_APP" "$TARGET"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
        /usr/bin/touch "$TARGET"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1 || true
        /usr/bin/open "$TARGET"
        """
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func appleScriptQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let lv = i < l.count ? l[i] : 0
            let rv = i < r.count ? r[i] : 0
            if lv < rv { return .orderedAscending }
            if lv > rv { return .orderedDescending }
        }
        return .orderedSame
    }

    private func showMessage(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - VPN Manager

final class VPNManager: ObservableObject {
    @Published var isConnected = false      // ppp0 поднят И это НАШ pppd
    @Published var foreignTunnel = false    // ppp0 поднят, но pppd не наш (BR-07)
    @Published var busy = false
    @Published var localIP = ""
    @Published var remoteIP = ""
    @Published var statusText = "Отключено"
    @Published var lastError = ""
    @Published var logText = ""
    @Published var reconnectEnabled = false {
        didSet {
            persist()
            if loaded && !reconnectEnabled {
                shouldMaintainConnection = false
                cancelReconnectTimer()
            }
        }
    }
    @Published var reconnecting = false

    // Settings
    @Published var server = "" { didSet { persist() } }
    @Published var username = "" { didSet { persist() } }
    @Published var password = "" { didSet { persist() } }
    @Published var networks = "" { didSet { persist() } }
    @Published var autoConnect = false { didSet { persist() } }
    @Published var launchAtLogin = false {
        didSet {
            guard loaded else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Автозапуск: \(error.localizedDescription)"
            }
        }
    }

    static let logPath = "/tmp/l2tp-office-app.log"
    static let pidPath = "/var/run/l2tp-office-app.pid"
    static let optsPath = "/etc/ppp/l2tp-office-app.opts"   // маркер наших pppd в argv
    static let helperPath = Bundle.main.executableURL?
        .deletingLastPathComponent()
        .appendingPathComponent("l2tp-office-helper")
        .path ?? "/Applications/L2TP Office.app/Contents/MacOS/l2tp-office-helper"
    static let rootHelperPath = "/Library/PrivilegedHelperTools/com.rokot.l2tp-office.root-helper"
    static let sudoersPath = "/etc/sudoers.d/l2tp-office"
    static let pppMTU = 1200
    private var loaded = false
    private var timer: Timer?
    private var reconnectTimer: Timer?
    private var shouldMaintainConnection = false
    private var wasConnected = false

    init() {
        let d = UserDefaults.standard
        server   = d.string(forKey: "server") ?? "213.79.84.225"
        username = d.string(forKey: "username") ?? ""
        let savedNetworks = d.string(forKey: "networks")
        networks = (savedNetworks == nil || savedNetworks == "172.16.0.0/12, 10.10.10.0/24")
            ? "172.16.99.0/24"
            : savedNetworks!
        autoConnect = d.bool(forKey: "autoConnect")
        reconnectEnabled = d.bool(forKey: "reconnectEnabled")
        password = Self.decodeStoredPassword(d.string(forKey: "vpnPasswordLocal") ?? "")
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        loaded = true
        d.removeObject(forKey: "routeAll")
        clearLogOnLaunch()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if autoConnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, !self.isConnected, !self.foreignTunnel, self.settingsValid else { return }
                // BR-15: активируем приложение, чтобы админ-диалог имел видимый контекст
                NSApp.activate(ignoringOtherApps: true)
                self.connect()
            }
        }
    }

    private func persist() {
        guard loaded else { return }
        let d = UserDefaults.standard
        d.set(server, forKey: "server")
        d.set(username, forKey: "username")
        d.set(networks, forKey: "networks")
        d.set(autoConnect, forKey: "autoConnect")
        d.set(reconnectEnabled, forKey: "reconnectEnabled")
        d.set(Self.encodeStoredPassword(password), forKey: "vpnPasswordLocal")
    }

    private static func encodeStoredPassword(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func decodeStoredPassword(_ value: String) -> String {
        guard let data = Data(base64Encoded: value),
              let decoded = String(data: data, encoding: .utf8) else { return "" }
        return decoded
    }

    // MARK: Validation (BR-02, BR-12)

    static func isValidCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for o in octets {
            guard !o.isEmpty, o.count <= 3, let v = Int(o), (0...255).contains(v) else { return false }
        }
        if parts.count == 2 {
            guard !parts[1].isEmpty, let p = Int(parts[1]), (0...32).contains(p) else { return false }
        }
        return true
    }

    var serverValid: Bool {
        let s = server.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    var invalidNetworks: [String] {
        parsedNetworks().filter { !Self.isValidCIDR($0) }
    }

    var networksValid: Bool {
        !parsedNetworks().isEmpty && invalidNetworks.isEmpty
    }

    var settingsValid: Bool {
        serverValid &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        networksValid
    }

    func parsedNetworks() -> [String] {
        networks
            .components(separatedBy: CharacterSet(charactersIn: ",;\n "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Status polling

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let out = Self.run("/sbin/ifconfig", ["ppp0"])
            var ip = "", rip = ""
            for raw in out.split(separator: "\n") {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("inet ") {
                    let p = t.split(separator: " ").map(String.init)
                    if p.count >= 4 { ip = p[1]; rip = p[3] }
                }
            }
            // BR-07: наш ли это туннель — ищем pppd с нашим opts-файлом в argv
            let oursAlive = !Self.run("/usr/bin/pgrep", ["-f", Self.optsPath]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let log = Self.tail(Self.logPath, lines: 60)
            DispatchQueue.main.async {
                self.localIP = ip
                self.remoteIP = rip
                let up = !ip.isEmpty
                self.isConnected = up && oursAlive
                self.foreignTunnel = up && !oursAlive
                if !self.busy {
                    if self.reconnecting { self.statusText = "Ожидаю переподключение…" }
                    else if self.isConnected { self.statusText = "Подключено" }
                    else if self.foreignTunnel { self.statusText = "Активен сторонний PPP-туннель" }
                    else { self.statusText = "Отключено" }
                }
                self.logText = log
                self.handleReconnectAfterRefresh(up: self.isConnected || self.foreignTunnel)
            }
        }
    }

    private func handleReconnectAfterRefresh(up: Bool) {
        defer { wasConnected = up }
        guard loaded else { return }
        guard reconnectEnabled, shouldMaintainConnection, !foreignTunnel else { return }
        if wasConnected, !up, !busy {
            scheduleReconnect(reason: "Соединение оборвалось — переподключаюсь…")
        }
    }

    // MARK: Connect / Disconnect

    func connect() {
        guard !busy, settingsValid, !foreignTunnel else { return }
        shouldMaintainConnection = true
        reconnecting = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        runPrivileged(request: requestFile(action: "connect"), action: "Подключаюсь…") { result in
            if Self.isCancelled(result) {
                self.shouldMaintainConnection = false
                self.lastError = "Подключение отменено (диалог пароля закрыт)."
            } else if result.contains("CONNECTED-ROUTEWARN") {
                self.lastError = "Подключено, но часть маршрутов не добавилась — проверь список сетей."
            } else if result.contains("CONNECTED") {
                self.lastError = ""
            } else if result.contains("AUTHFAIL") {
                self.lastError = "Ошибка аутентификации: проверь логин и пароль."
            } else if result.contains("FAILED") {
                self.lastError = "pppd завершился с ошибкой — смотри лог."
            } else if result.contains("TIMEOUT") {
                self.lastError = "Сервер не ответил за 25 секунд."
            } else if result.isEmpty {
                self.lastError = "Скрипт не вернул результат — смотри лог."
            } else {
                self.lastError = result
            }
            if self.reconnectEnabled,
               self.shouldMaintainConnection,
               !result.contains("CONNECTED"),
               !Self.isCancelled(result) {
                self.scheduleReconnect(reason: self.lastError.isEmpty ? "Не подключилось — пробую снова…" : self.lastError)
            }
        }
    }

    func disconnect() {
        guard !busy, !foreignTunnel else { return }
        shouldMaintainConnection = false
        cancelReconnectTimer()
        runPrivileged(request: requestFile(action: "disconnect"), action: "Отключаю…") { result in
            // BR-04: отмена диалога — явное сообщение, туннель остался
            self.lastError = Self.isCancelled(result) ? "Отключение отменено (диалог пароля закрыт)." : ""
        }
    }

    func emergencyStop() {
        shouldMaintainConnection = false
        cancelReconnectTimer()
        runPrivileged(request: requestFile(action: "disconnect"), action: "Аварийно останавливаю подключение…") { result in
            if Self.isCancelled(result) {
                self.lastError = "Аварийная остановка отменена."
            } else if result.contains("DONE") || result.isEmpty {
                self.lastError = ""
            } else {
                self.lastError = result
            }
        }
    }

    private func scheduleReconnect(reason: String) {
        guard reconnectEnabled, shouldMaintainConnection, settingsValid, !busy, !isConnected, !foreignTunnel else { return }
        reconnectTimer?.invalidate()
        reconnecting = true
        statusText = "Ожидаю переподключение…"
        lastError = reason
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.reconnectTimer = nil
            guard self.reconnectEnabled,
                  self.shouldMaintainConnection,
                  self.settingsValid,
                  !self.busy,
                  !self.isConnected,
                  !self.foreignTunnel else {
                self.reconnecting = false
                return
            }
            self.connect()
        }
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnecting = false
    }

    func clearLog() {
        runPrivileged(request: requestFile(action: "clearlog"), action: "Очищаю лог…") { result in
            if Self.isCancelled(result) {
                self.lastError = "Очистка лога отменена."
            } else if result.contains("DONE") || result.isEmpty {
                self.lastError = ""
                self.logText = Self.tail(Self.logPath, lines: 60)
            } else {
                self.lastError = result
            }
        }
    }

    func disconnectBeforeTerminate(completion: @escaping () -> Void) {
        guard isConnected, !foreignTunnel else {
            completion()
            return
        }
        runPrivileged(request: requestFile(action: "disconnect"), action: "Отключаю перед выходом…") { _ in
            self.lastError = ""
            completion()
        }
    }

    // BR-14: подтверждение выхода при активном туннеле
    func quit() {
        if isConnected {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "VPN-туннель активен"
            a.informativeText = "Отключить туннель и выйти из приложения?"
            a.alertStyle = .warning
            a.addButton(withTitle: "Отключить и выйти")
            a.addButton(withTitle: "Отмена")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            disconnectBeforeTerminate {
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    private static func isCancelled(_ out: String) -> Bool {
        let l = out.lowercased()
        return l.contains("user canceled") || l.contains("user cancelled") || out.contains("(-128)")
    }

    private func runPrivileged(request: String, action: String, completion: @escaping (String) -> Void) {
        busy = true
        statusText = action
        lastError = ""   // OPT-2: старая ошибка не висит во время новой попытки
        DispatchQueue.global(qos: .userInitiated).async {
            let requestPath = NSTemporaryDirectory() + "l2tp-request-\(UUID().uuidString).env"
            defer { try? FileManager.default.removeItem(atPath: requestPath) }
            do {
                try request.write(toFile: requestPath, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestPath)
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.lastError = "Не удалось создать request-файл."
                    self.refresh()
                }
                return
            }
            if !Self.rootHelperInstalled() {
                let setup = Self.installRootHelper()
                if Self.isCancelled(setup) || !Self.rootHelperInstalled() {
                    DispatchQueue.main.async {
                        self.busy = false
                        self.lastError = Self.isCancelled(setup)
                            ? "Установка helper-а отменена."
                            : "Не удалось установить helper: \(setup)"
                        self.refresh()
                    }
                    return
                }
            }
            var out = Self.runRootHelper(requestPath: requestPath)
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isSudoAuthenticationFailure(out) {
                let setup = Self.installRootHelper()
                if !Self.isCancelled(setup) && Self.rootHelperInstalled() {
                    out = Self.runRootHelper(requestPath: requestPath).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    out = Self.isCancelled(setup) ? "USERCANCEL" : "Не удалось установить helper: \(setup)"
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                completion(out)
                self.refresh()
            }
        }
    }

    private func requestFile(action: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
        }
        let nets = parsedNetworks().filter { Self.isValidCIDR($0) }.joined(separator: " ")
        return """
        ACTION=\(b64(action))
        SERVER=\(b64(server.trimmingCharacters(in: .whitespaces)))
        USERNAME=\(b64(username))
        PASSWORD=\(b64(password))
        ROUTE_ALL=\(b64("false"))
        NETWORKS=\(b64(nets))
        """
    }

    private func clearLogOnLaunch() {
        Self.clearLogFileLocally()
        guard Self.rootHelperInstalled() else { return }
        let requestPath = NSTemporaryDirectory() + "l2tp-clear-log-\(UUID().uuidString).env"
        do {
            try requestFile(action: "clearlog").write(toFile: requestPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestPath)
            _ = Self.runRootHelper(requestPath: requestPath)
        } catch {
            return
        }
        try? FileManager.default.removeItem(atPath: requestPath)
    }

    private static func clearLogFileLocally() {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logPath)
    }

    private static func runRootHelper(requestPath: String) -> String {
        let command = "/usr/bin/sudo -n \(shellQuote(rootHelperPath)) \(shellQuote(requestPath)) 2>&1"
        let osa = "do shell script \"\(appleScriptQuoted(command))\""
        return run("/usr/bin/osascript", ["-e", osa])
    }

    private static func rootHelperInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: rootHelperPath) else { return false }
        let probePath = NSTemporaryDirectory() + "l2tp-helper-probe-\(UUID().uuidString).env"
        let probe = "ACTION=\(Data("version".utf8).base64EncodedString())\n"
        do {
            try probe.write(toFile: probePath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: probePath)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: probePath) }
        let out = runRootHelper(requestPath: probePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.contains("ROOT-HELPER-VERSION \(requiredRootHelperVersion)")
    }

    private static func installRootHelper() -> String {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("l2tp-office-root-helper.sh").path,
              FileManager.default.fileExists(atPath: bundled) else {
            return "root-helper не найден в bundle."
        }
        let user = NSUserName()
        let setup = """
        set -euo pipefail
        /bin/mkdir -p /Library/PrivilegedHelperTools /etc/sudoers.d
        /bin/cp \(shellQuote(bundled)) \(shellQuote(rootHelperPath))
        /usr/sbin/chown root:wheel \(shellQuote(rootHelperPath))
        /bin/chmod 0500 \(shellQuote(rootHelperPath))
        SUDOERS_TMP=$(/usr/bin/mktemp /tmp/l2tp-sudoers.XXXXXX)
        /bin/echo '\(user) ALL=(root) NOPASSWD: \(rootHelperPath)' > "$SUDOERS_TMP"
        /usr/sbin/chown root:wheel "$SUDOERS_TMP"
        /bin/chmod 0440 "$SUDOERS_TMP"
        /usr/sbin/visudo -cf "$SUDOERS_TMP" >/dev/null
        /bin/mv "$SUDOERS_TMP" \(shellQuote(sudoersPath))
        echo ROOT-HELPER-READY
        """
        let command = "/bin/bash -c \(shellQuote(setup))"
        let osa = "do shell script \"\(appleScriptQuoted(command))\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", osa])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSudoAuthenticationFailure(_ out: String) -> Bool {
        let l = out.lowercased()
        return l.contains("sudo:")
            || l.contains("a password is required")
            || l.contains("not in the sudoers")
            || l.contains("password is required")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Helpers

    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func tail(_ path: String, lines: Int) -> String {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return "Лог пока пуст." }
        return s.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

// MARK: - Status dot (BR-16: busy имеет приоритет)

func statusColor(_ vpn: VPNManager) -> Color {
    if vpn.busy { return .orange }
    if vpn.isConnected { return .green }
    if vpn.foreignTunnel { return .yellow }
    return .red
}

// MARK: - Termination

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var vpn: VPNManager?
    private var terminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vpn, vpn.isConnected, !vpn.foreignTunnel, !terminationInProgress else {
            return .terminateNow
        }
        terminationInProgress = true
        vpn.disconnectBeforeTerminate {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var vpn: VPNManager
    @EnvironmentObject var updater: AppUpdater
    @State private var showVPNPassword = false

    private var connectDisabled: Bool {
        vpn.isConnected || vpn.busy || vpn.foreignTunnel || !vpn.settingsValid
    }
    private var disconnectDisabled: Bool {
        !vpn.isConnected || vpn.busy || vpn.foreignTunnel
    }
    private var connectingInProgress: Bool {
        (vpn.busy && !vpn.isConnected && vpn.statusText.contains("Подключ")) || vpn.reconnecting
    }
    private var stopButtonDisabled: Bool {
        connectingInProgress ? vpn.foreignTunnel : disconnectDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(vpn))
                    .frame(width: 14, height: 14)
                Text(vpn.statusText).font(.title2.weight(.semibold))
                if vpn.isConnected {
                    Text("\(vpn.localIP) → \(vpn.remoteIP)")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    updater.checkForUpdates(silent: false)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: updater.installing ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                            .foregroundStyle(updater.installing ? .blue : .secondary)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(appVersion)
                                .font(.callout.weight(.medium))
                            if !updater.statusText.isEmpty {
                                Text(updater.statusText)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(updater.checking || updater.installing)
                .help("Проверить обновления")
                if vpn.busy { ProgressView().controlSize(.small) }
            }

            if !vpn.lastError.isEmpty {
                Label(vpn.lastError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if vpn.foreignTunnel {
                Label("Интерфейс ppp0 занят другим PPP-клиентом — управление недоступно.", systemImage: "info.circle.fill")
                    .foregroundStyle(.yellow)
                    .font(.callout)
            }

            // Settings
            GroupBox("Настройки подключения") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Сервер")
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("IP или hostname", text: $vpn.server)
                                .textFieldStyle(.roundedBorder)
                            if !vpn.server.isEmpty && !vpn.serverValid {
                                Text("Недопустимый адрес: только буквы, цифры, точки и дефисы, без пробелов")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    GridRow {
                        Text("Логин")
                        TextField("Имя пользователя VPN", text: $vpn.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Пароль")
                        HStack(spacing: 8) {
                            Group {
                                if showVPNPassword {
                                    TextField("Пароль VPN", text: $vpn.password)
                                } else {
                                    SecureField("Пароль VPN", text: $vpn.password)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            Button {
                                showVPNPassword.toggle()
                            } label: {
                                Image(systemName: showVPNPassword ? "eye.slash" : "eye")
                                    .frame(width: 22)
                            }
                            .buttonStyle(.plain)
                            .help(showVPNPassword ? "Скрыть пароль" : "Показать пароль")
                        }
                    }
                    GridRow {
                        Text("Сети")
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("например: 172.16.99.0/24", text: $vpn.networks)
                                .textFieldStyle(.roundedBorder)
                            if !vpn.invalidNetworks.isEmpty {
                                // BR-02: невалидные CIDR подсвечиваются, подключение блокируется
                                Text("Неверный CIDR: \(vpn.invalidNetworks.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.red)
                            } else if vpn.parsedNetworks().isEmpty {
                                Text("Укажи хотя бы одну сеть")
                                    .font(.caption).foregroundStyle(.red)
                            } else {
                                // BR-13: поясняем поведение DNS в split-режиме
                                Text("CIDR через запятую или пробел. DNS VPN-сервера в этом режиме не используется")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(6)
                .disabled(vpn.isConnected || vpn.busy)
            }

            GroupBox("Автозапуск") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Запускать приложение при входе в систему", isOn: $vpn.launchAtLogin)
                    Toggle("Подключаться автоматически при запуске приложения", isOn: $vpn.autoConnect)
                    Toggle("Автопереподключение при обрыве", isOn: $vpn.reconnectEnabled)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Buttons (BR-01: без keyboardShortcut — Enter в полях больше не подключает)
            HStack(spacing: 10) {
                Button {
                    vpn.connect()
                } label: {
                    Label("Подключить", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(connectDisabled)
                .opacity(connectDisabled ? 0.45 : 1.0)   // BR-08: явная индикация disabled

                Button {
                    if connectingInProgress {
                        vpn.emergencyStop()
                    } else {
                        vpn.disconnect()
                    }
                } label: {
                    Label(
                        connectingInProgress ? "Остановить подключение" : "Отключить",
                        systemImage: connectingInProgress ? "xmark.octagon.fill" : "lock.open"
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(.red)
                .disabled(stopButtonDisabled)
                .opacity(stopButtonDisabled ? 0.45 : 1.0)
            }

            // Log
            GroupBox("Лог PPP/L2TP") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Button {
                            vpn.clearLog()
                        } label: {
                            Label("Очистить лог", systemImage: "trash")
                        }
                        .disabled(vpn.busy)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(vpn.logText)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("logEnd")
                        }
                        .onAppear {   // OPT-3: скролл вниз при первом открытии
                            proxy.scrollTo("logEnd", anchor: .bottom)
                        }
                        .onChange(of: vpn.logText) { _ in
                            proxy.scrollTo("logEnd", anchor: .bottom)
                        }
                    }
                    .frame(minHeight: 150)
                }
            }
        }
        .padding(16)
        // BR-03: минимальная высота соответствует реальному контенту (режим split + ошибки)
        .frame(minWidth: 560, minHeight: 680)
    }
}

// MARK: - Menu bar

struct MenuContent: View {
    @EnvironmentObject var vpn: VPNManager
    @EnvironmentObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    private var connectDisabled: Bool {
        vpn.isConnected || vpn.busy || vpn.foreignTunnel || !vpn.settingsValid
    }
    private var disconnectDisabled: Bool {
        !vpn.isConnected || vpn.busy || vpn.foreignTunnel
    }
    private var connectingInProgress: Bool {
        (vpn.busy && !vpn.isConnected && vpn.statusText.contains("Подключ")) || vpn.reconnecting
    }
    private var stopButtonDisabled: Bool {
        connectingInProgress ? vpn.foreignTunnel : disconnectDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(vpn))
                    .frame(width: 10, height: 10)
                Text(vpn.isConnected ? "Подключено · \(vpn.localIP)" : vpn.statusText)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                if vpn.busy { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                Button {
                    vpn.connect()
                } label: {
                    Label("Подключить", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .disabled(connectDisabled)
                .opacity(connectDisabled ? 0.5 : 1.0)

                Button {
                    if connectingInProgress {
                        vpn.emergencyStop()
                    } else {
                        vpn.disconnect()
                    }
                } label: {
                    Label(
                        connectingInProgress ? "Остановить подключение" : "Отключить",
                        systemImage: connectingInProgress ? "xmark.octagon.fill" : "lock.open"
                    )
                    .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .disabled(stopButtonDisabled)
                .opacity(stopButtonDisabled ? 0.5 : 1.0)
            }
            Divider()
            HStack {
                Button("Открыть окно") {
                    // BR-17: openWindow из MenuBarExtra не всегда открывает закрытое окно —
                    // сначала ищем существующее окно и показываем его, иначе создаём новое
                    NSApp.activate(ignoringOtherApps: true)
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
                        if win.isMiniaturized { win.deminiaturize(nil) }
                        win.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "main")
                    }
                }
                Spacer()
                Button("Выход") { vpn.quit() }   // BR-14: с подтверждением при активном туннеле
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            Button {
                updater.checkForUpdates(silent: false)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: updater.installing ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appVersion)
                            .font(.callout.weight(.medium))
                        Text(updater.statusText.isEmpty ? "Проверить обновления" : updater.statusText)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(updater.checking || updater.installing)
        }
        .padding(12)
        .frame(width: 280)
    }
}

struct MenuIcon: View {
    @ObservedObject var vpn: VPNManager
    var body: some View {
        // Замкнут при активном туннеле, разомкнут без подключения
        Image(systemName: vpn.isConnected ? "lock.fill" : "lock.open")
    }
}

// MARK: - App

@main
struct L2TPOfficeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vpn = VPNManager()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup("L2TP Office", id: "main") {
            ContentView()
                .environmentObject(vpn)
                .environmentObject(updater)
                .onAppear {
                    appDelegate.vpn = vpn
                }
        }
        // BR-03: окно нельзя сделать меньше минимального контента, больше — можно
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent()
                .environmentObject(vpn)
                .environmentObject(updater)
        } label: {
            MenuIcon(vpn: vpn)
        }
        .menuBarExtraStyle(.window)
    }
}
