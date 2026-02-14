import ArgumentParser
import Testing

@testable import PredictionsServer

@Suite
struct AddressParsingTests {
    @Test
    func parseListenAddrWithEmptyHost() throws {
        let addr = try parseListenAddr(":8080")
        #expect(addr.port == 8080)
        #expect(addr.description.contains("::"))
    }

    @Test
    func parseListenAddrWithIPv4() throws {
        let addr = try parseListenAddr("127.0.0.1:8080")
        #expect(addr.port == 8080)
        #expect(addr.ipAddress == "127.0.0.1")
    }

    @Test
    func parseListenAddrInvalidFormat() {
        #expect { try parseListenAddr("invalid") } throws: { $0 is ValidationError }
    }

    @Test
    func parseListenAddrInvalidPort() {
        #expect(throws: (any Error).self) { try parseListenAddr(":99999") }
        #expect(throws: (any Error).self) { try parseListenAddr(":0") }
        #expect(throws: (any Error).self) { try parseListenAddr(":abc") }
    }
}
