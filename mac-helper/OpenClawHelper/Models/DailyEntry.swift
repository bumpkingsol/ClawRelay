import Foundation

struct DailyEntry: Decodable, Identifiable {
    var id: String { "\(date)-\(project)" }
    let date: String
    let project: String
    let hours: Double
}
