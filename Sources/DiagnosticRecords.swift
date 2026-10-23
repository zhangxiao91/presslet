import Foundation

struct EventRecord: Codable {
    let elapsed: Double
    let source: String
    let app: String
    let bundleID: String
    let type: String
    let stage: Int?
    let pressure: Double?
    let transition: Double?
    let firstDeep: Bool
}

struct AppStats: Codable {
    var app: String
    var bundleID: String
    var source: String
    var pressureEvents = 0
    var deepPresses = 0
    var clicks = 0
}
