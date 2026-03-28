import Foundation

struct Handoff: Identifiable, Decodable {
    let id: Int
    let project: String
    let task: String
    let message: String
    let priority: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, project, task, message, priority, status
        case createdAt = "created_at"
    }
}
