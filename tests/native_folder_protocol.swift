import Foundation

@main struct Tests {
    static func main() {
        precondition(PWNativeFolderProtocol.payload(path: "/Avion") == Data([10, 6] + Array("/Avion".utf8)))
        let long = "/" + String(repeating: "é", count: 80)
        precondition(PWNativeFolderProtocol.payload(path: long) == Data([10, 161, 1] + Array(long.utf8)))
        for bad in ["Avion", "", "/a\0b", "/" + String(repeating: "a", count: 16384)] { precondition(PWNativeFolderProtocol.payload(path: bad) == nil) }
        for reply in [Data(), Data([8, 0]), Data([8, 2]), Data([8]), Data([10, 1])] { precondition(!PWNativeFolderProtocol.accepted(response: reply)) }
        precondition(PWNativeFolderProtocol.accepted(response: Data([8, 1])))
        precondition(PWNativeFolderProtocol.accepted(response: Data([8, 3])))
        precondition(PWNativeFolderProtocol.accepted(response: Data([8, 1, 18, 2, 97, 98])))
        precondition(!PWNativeFolderProtocol.accepted(response: Data([8, 1, 8, 2])))
        precondition(!PWNativeFolderProtocol.accepted(response: Data([8, 1, 18, 3, 97])))
        precondition(PWNativeFolderProtocol.documentsPayload == Data([8, 6, 16, 1]))
        let uri = "spotify:local:PNL:Deux:91%27s:234"
        let item = Data([42, UInt8(uri.utf8.count)] + Array(uri.utf8))
        let body = Data([10, UInt8(item.count)]) + item
        let reply = Data([10, 3, 8, 200, 1, 18, UInt8(body.count)]) + body
        precondition(PWNativeFolderProtocol.indexedURIs(response: reply) == [uri])
        precondition(PWNativeFolderProtocol.indexedURIs(response: Data([10, 3, 8, 148, 3, 18, 0])) == nil)
        precondition(PWNativeFolderProtocol.indexedURIs(response: Data([18, 0])) == nil)
        print("PASS: native folder encoding and conservative response validation")
    }
}
