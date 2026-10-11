import Testing
import Foundation
@testable import UniversalTVRemote

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct FireTVTests {
    @MainActor
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }
    @Test @MainActor
    func testReadOnlyMonitoringDisconnectsAndRecoversWithoutWake() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let driver = FireTVDriver(device: DiscoveredTV(id: "fireTV:test", brand: .fireTV,
                                  name: "Test TV", host: "192.0.2.1"), configuration: config)
        var reachable = true
        var requests: [URLRequest] = []
        StubURLProtocol.handler = { request in
            requests.append(request)
            if !reachable { throw URLError(.cannotConnectToHost) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
        }
        var connected = false
        driver.onStateChange = { if $0 == .connected { connected = true } }
        driver.connect(token: "test-token")
        await waitFor { connected }
        reachable = false
        var disconnected = false
        driver.onStateChange = { if case .failed = $0 { disconnected = true } }
        driver.checkHealth()
        await waitFor { disconnected }
        reachable = true
        var recovered = false
        driver.onStateChange = { if $0 == .connected { recovered = true } }
        driver.checkHealth()
        await waitFor { recovered }
        driver.disconnect()
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { ["/v1/FireTV/apps", "/apps/FireTVRemote"].contains($0.url?.path ?? "") })
    }

    @Test @MainActor
    func testRejectedTokenCannotBecomeConnectedOnNextPoll() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let driver = FireTVDriver(device: DiscoveredTV(id: "fireTV:test", brand: .fireTV,
                                  name: "Test TV", host: "192.0.2.1"), configuration: config)
        var count = 0
        StubURLProtocol.handler = { request in
            count += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        var rejected = false
        driver.onStateChange = { if case .failed = $0 { rejected = true } }
        driver.connect(token: "test-token")
        await waitFor { rejected }
        driver.checkHealth()
        driver.disconnect()
        #expect(count == 1)
    }

    @Test @MainActor
    func testStoppedRemoteServiceIsExplainedWithoutStartingIt() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let driver = FireTVDriver(device: DiscoveredTV(id: "fireTV:test", brand: .fireTV,
                                  name: "Test TV", host: "192.0.2.1"), configuration: config)
        var requests: [URLRequest] = []
        StubURLProtocol.handler = { request in
            requests.append(request)
            if request.url?.port == 8080 { throw URLError(.cannotConnectToHost) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("<service><state>stopped</state></service>".utf8))
        }
        var stopped = false
        driver.onStateChange = {
            if case .failed(let message) = $0 { stopped = message.contains("remote service is stopped") }
        }
        driver.connect(token: "test-token")
        await waitFor { stopped }
        driver.disconnect()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
