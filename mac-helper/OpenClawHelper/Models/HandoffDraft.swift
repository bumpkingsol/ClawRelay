import Foundation

struct HandoffDraft {
    var project: String = ""
    var task: String = ""
    var message: String = ""

    var isValid: Bool { !project.isEmpty && !task.isEmpty }
}
