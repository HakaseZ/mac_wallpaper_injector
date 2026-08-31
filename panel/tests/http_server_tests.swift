import Foundation

// MARK: - HTTPServer 测试(本地静态服务:200/404/目录穿越防护)

func httpServerTests(_ r: TestRunner) throws {
    let sandbox = try Sandbox()
    defer { sandbox.teardown() }

    // 写一个测试文件
    let hello = "hello mwi".data(using: .utf8)!
    try hello.write(to: sandbox.paths.httpDir.appendingPathComponent("a.txt"))

    let port = UInt16(20_000 + Int.random(in: 0..<40_000))
    let server = HTTPServer(port: port, directory: sandbox.paths.httpDir)
    try server.start()
    defer { server.stop() }
    // 等 listener 就绪
    Thread.sleep(forTimeInterval: 0.3)

    func get(_ path: String) -> (status: Int, body: Data) {
        let url = URL(string: "http://127.0.0.1:\(port)/\(path)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, Data) = (0, Data())
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            result = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 8)
        return result
    }

    let ok = get("a.txt")
    r.equal("GET 200", ok.status, 200)
    r.equal("GET 内容", String(data: ok.body, encoding: .utf8) ?? "", "hello mwi")

    let miss = get("nope.txt")
    r.equal("GET 缺失 404", miss.status, 404)

    let trav = get("..%2F..%2F..%2Fetc%2Fpasswd")
    r.equal("GET 目录穿越 404", trav.status, 404)

    let query = get("a.txt?x=1")
    r.equal("GET 带查询串 200", query.status, 200)
}
