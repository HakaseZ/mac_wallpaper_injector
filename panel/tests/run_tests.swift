// code-review-marker
import Foundation

// MWI 沙箱测试:单元 + 集成,全部路径经 Paths.current 注入临时目录,不触碰真实系统壁纸状态。
// 用法: ./tests.sh(默认);系统级 e2e 见 run_e2e.swift(./tests.sh e2e)

@main
struct RunTests {
    static func main() {
        let r = TestRunner()
        runSuite(r, "MOVPatcher") { try movPatcherTests(r) }
        runSuite(r, "AerialManifest") { try aerialManifestTests(r) }
        runSuite(r, "Pipeline") { try pipelineTests(r) }
        runSuite(r, "HTTPServer") { try httpServerTests(r) }
        runSuite(r, "Thumbnail") { try thumbnailTests(r) }
        print("\n===== \(r.passed) passed, \(r.failed) failed, \(r.skipped) skipped =====")
        exit(r.failed == 0 ? 0 : 1)
    }
}
