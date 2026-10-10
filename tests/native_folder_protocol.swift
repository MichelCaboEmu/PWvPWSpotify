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
        print("PASS: native folder encoding and conservative response validation")
    }
}
