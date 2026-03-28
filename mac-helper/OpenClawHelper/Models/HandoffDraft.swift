import Foundation

struct HandoffDraft {
    var project: String = ""
    var task: String = ""
    var message: String = ""
    var priority: String = "normal"

    var isValid: Bool { !task.isEmpty }
    var projectOrDefault: String { project.isEmpty ? "general" : project }
}
