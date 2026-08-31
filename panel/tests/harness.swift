import Foundation

// MARK: - 轻量测试框架(无 XCTest 依赖,swiftc 直编,CLT 环境兼容)

final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0

    @discardableResult
    func check(_ name: String, _ cond: Bool, _ detail: String = "") -> Bool {
        if cond {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name) \(detail)")
        }
        return cond
    }

    func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got), want \(want)")
    }

    func noThrow<T>(_ name: String, _ body: () throws -> T) -> T? {
        do {
            let v = try body()
            check(name, true)
            return v
        } catch {
            check(name, false, "unexpected throw: \(error)")
            return nil
        }
    }

    func throwsError<T>(_ name: String, _ body: () throws -> T) {
        do {
            _ = try body()
            check(name, false, "expected throw, none raised")
        } catch {
            check(name, true)
        }
    }

    func skip(_ name: String, _ why: String) {
        skipped += 1
        print("  – \(name) (SKIP: \(why))")
       }

    /// 套件级异常:计为失败并继续
    func recordSuiteError(_ e: Error) {
        failed += 1
        print("  ✗ SUITE THREW: \(e)")
    }
}

/// 运行一个套件;顶层抛出 → 计为失败并继续后续套件
func runSuite(_ r: TestRunner, _ name: String, _ body: () throws -> Void) {
    print("== \(name) ==")
    do {
        try body()
    } catch {
                r.recordSuiteError(error)
    }
}
