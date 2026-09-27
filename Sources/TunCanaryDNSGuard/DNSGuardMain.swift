import Darwin
import Foundation
import TunCanaryCore
import TunCanarySystem

/// DNS 守护进程：由 LaunchDaemon 以 root 身份启动，每次完成一次判定和写入后退出。
@main
enum DNSGuardMain {
    static let usage = """
    用法：
      tuncanary-dns-guard                     运行一次（需要 root，由 LaunchDaemon 调用）
      tuncanary-dns-guard --dry-run           只判定，不写入，不更新状态文件
      tuncanary-dns-guard --print-config --home <目录> --target-dns <地址,...> [--proxy-config-dir <目录>]
                                              输出一份默认配置（安装脚本使用）
      tuncanary-dns-guard --suggest-target    读取当前用户的 TunCanary 设置，输出断开期的预期 DNS
      tuncanary-dns-guard --version
    """

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case nil:
            exit(await run(dryRun: false, paths: DNSGuardPaths()))
        case "--dry-run":
            arguments.removeFirst()
            var paths = DNSGuardPaths()
            if arguments.first == "--root", arguments.count == 2 {
                paths = DNSGuardPaths(root: arguments[1])
            } else if !arguments.isEmpty {
                fail(usage, code: 64)
            }
            exit(await run(dryRun: true, paths: paths))
        case "--print-config":
            printConfig(Array(arguments.dropFirst()))
        case "--suggest-target":
            guard arguments.count == 1 else { fail(usage, code: 64) }
            let settings = SettingsStore().load()
            let expected = settings.effectiveExpectedDNS
            guard settings.disconnectedDNSRule == .equals, !expected.isEmpty else {
                fail("TunCanary 设置中“VPN 断开、TUN 运行时”不是“指定地址”，请用 --target-dns 指定目标 DNS", code: 1)
            }
            print(expected.joined(separator: ","))
        case "--version":
            print("tuncanary-dns-guard \(AppIdentity.version)")
        case "--help", "-h":
            print(usage)
        default:
            fail(usage, code: 64)
        }
    }

    // MARK: - 运行

    static func run(dryRun: Bool, paths: DNSGuardPaths) async -> Int32 {
        let store = DNSGuardStateStore(paths: paths)
        if !dryRun {
            guard geteuid() == 0 else {
                printError("需要 root 权限。请通过 LaunchDaemon 运行，或使用 --dry-run 试运行")
                return 1
            }
            if let problem = FileSecurity.problem(paths: paths) {
                record(store, reason: problem)
                printError(problem)
                return 1
            }
        }

        let config: DNSGuardConfig
        do {
            config = try DNSGuardConfig.parse(Data(contentsOf: URL(fileURLWithPath: paths.configFile)))
        } catch let error as DNSGuardFileParser.ParseError {
            return configFailure(store, dryRun: dryRun, reason: error.message)
        } catch {
            return configFailure(store, dryRun: dryRun, reason: "无法读取配置")
        }
        let problems = config.validate()
        guard problems.isEmpty else {
            return configFailure(store, dryRun: dryRun, reason: "配置无效：" + problems.joined(separator: "；"))
        }

        let knownPaths = KnownPaths(homeDirectory: config.homeDirectory, proxyConfigDirectory: config.proxyConfigDir)
        let adapters = VPNAdapterStore(directory: paths.supportDirectory + "/adapters").load()
        // 没有适配器时 VPN 总是判为“已断开”，连接期也会被当成断开期写入，所以宁可不写。
        guard adapters.adapters.isEmpty == false else {
            return configFailure(store, dryRun: dryRun, reason: "未加载 VPN 适配器，无法确认 VPN 状态，不写入")
        }
        guard adapters.problems.isEmpty else {
            return configFailure(store, dryRun: dryRun,
                                 reason: "VPN 适配器配置无效，不写入：" + adapters.problems.joined(separator: "；"))
        }
        let runner = DNSGuardRunner(
            config: config,
            sampler: DNSGuardSystemSampler(paths: knownPaths, adapters: adapters),
            writer: DNSGuardSystemWriter(),
            prober: DNSGuardSystemProber(),
            store: store,
            redactor: Redactor(homeDirectory: config.homeDirectory),
            dryRun: dryRun)
        let report = await runner.run()
        print(report.event.text)
        if let problem = report.storageProblem {
            printError("保存状态失败：\(problem)")
            return 1
        }
        return 0
    }

    static func configFailure(_ store: DNSGuardStateStore, dryRun: Bool, reason: String) -> Int32 {
        if !dryRun { record(store, reason: reason) }
        printError(reason)
        return 1
    }

    /// 无法运行时也记一条事件，让菜单栏应用能看到原因。
    static func record(_ store: DNSGuardStateStore, reason: String) {
        var state = store.loadState()
        let event = DNSGuardEvent(date: Date(), outcome: .skipped, reason: reason)
        if !DNSGuardRunner.sameResult(event, state.lastRun) { try? store.appendEvent(event) }
        state.lastRun = event
        try? store.saveState(state)
    }

    // MARK: - 生成配置

    static func printConfig(_ arguments: [String]) {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--home", "--target-dns", "--proxy-config-dir"].contains(key), index + 1 < arguments.count,
                  options[key] == nil else { fail(usage, code: 64) }
            options[key] = arguments[index + 1]
            index += 2
        }
        guard let home = options["--home"], let target = options["--target-dns"] else { fail(usage, code: 64) }
        let proxyDir = options["--proxy-config-dir"]
            ?? KnownPaths(homeDirectory: home).clashVergeConfigDirectory
        let config = DNSGuardConfig(targetDNS: DNSList.split(target), homeDirectory: home, proxyConfigDir: proxyDir)
        let problems = config.validate()
        guard problems.isEmpty else { fail("配置无效：" + problems.joined(separator: "；"), code: 1) }
        FileHandle.standardOutput.write(config.encoded())
        print()
    }

    // MARK: - 输出

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func fail(_ message: String, code: Int32) -> Never {
        printError(message)
        exit(code)
    }
}

/// root 运行前的文件权限检查：配置、适配器和所在目录须归 root 所有，且组和其他用户不可写。
enum FileSecurity {
    static func problem(paths: DNSGuardPaths) -> String? {
        let adapters = paths.supportDirectory + "/adapters"
        var items = [paths.supportDirectory, paths.configFile]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: adapters, isDirectory: &isDirectory) {
            items.append(adapters)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: adapters)) ?? []
            items += names.map { adapters + "/" + $0 }
        }
        for path in items {
            var info = stat()
            guard lstat(path, &info) == 0 else { return "无法检查文件权限：\(path)" }
            if info.st_mode & S_IFMT == S_IFLNK { return "拒绝使用符号链接：\(path)" }
            if info.st_uid != 0 || info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
                return "文件须归 root 所有且组和其他用户不可写：\(path)"
            }
        }
        return nil
    }
}
