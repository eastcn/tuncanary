import Foundation

/// 自带测试运行器入口。汇总四个模块的测试套件。
@main
enum SelfTestMain {
    static func main() async {
        let suites = CoreSuites.all + SystemSuites.all + ProbeSuites.all + UISuites.all + RuntimeSuites.all
        let code = await TestRunner.run(suites: suites, arguments: Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
}
