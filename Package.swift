// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TunCanary",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TunCanary", targets: ["TunCanary"]),
        .executable(name: "TunCanarySelfTest", targets: ["TunCanarySelfTest"]),
        .library(name: "TunCanaryCore", targets: ["TunCanaryCore"]),
        .library(name: "TunCanarySystem", targets: ["TunCanarySystem"]),
        .library(name: "TunCanaryProbe", targets: ["TunCanaryProbe"]),
        .library(name: "TunCanaryUI", targets: ["TunCanaryUI"]),
        .library(name: "TunCanaryRuntime", targets: ["TunCanaryRuntime"]),
    ],
    targets: [
        // 纯逻辑：模型、解析器、判定、汇总、设置、诊断。除 SettingsStore 外不做 I/O。
        .target(name: "TunCanaryCore"),

        // 系统采集（getifaddrs、SCDynamicStore、proc_*、网络变化监听）。
        .target(
            name: "TunCanarySystem",
            dependencies: ["TunCanaryCore"],
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
            ]
        ),

        // 连通性探测（URLSession）。
        .target(
            name: "TunCanaryProbe",
            dependencies: ["TunCanaryCore"]
        ),

        // 菜单栏、弹窗、设置、通知、登录项。
        .target(
            name: "TunCanaryUI",
            dependencies: ["TunCanaryCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        ),

        .target(
            name: "TunCanaryRuntime",
            dependencies: ["TunCanaryCore", "TunCanaryProbe", "TunCanaryUI"]
        ),

        // 程序入口。
        .executableTarget(
            name: "TunCanary",
            dependencies: [
                "TunCanaryCore",
                "TunCanarySystem",
                "TunCanaryProbe",
                "TunCanaryUI",
                "TunCanaryRuntime",
            ]
        ),

        // 自带测试运行器（没有 XCTest / Testing）。
        .executableTarget(
            name: "TunCanarySelfTest",
            dependencies: [
                "TunCanaryCore",
                "TunCanarySystem",
                "TunCanaryProbe",
                "TunCanaryUI",
                "TunCanaryRuntime",
            ]
        ),
    ]
)
