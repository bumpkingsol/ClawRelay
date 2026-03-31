import Foundation

struct JCQuestion: Decodable, Identifiable {
    let id: Int
    let question: String
    let project: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, question, project
        case createdAt = "created_at"
    }
}
