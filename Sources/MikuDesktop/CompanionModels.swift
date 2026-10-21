import Foundation

struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let date: Date
    /// A picture sent with the message, stored next to the memory file (see CompanionMemory).
    let imageName: String?

    init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(), imageName: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.imageName = imageName
    }
}

struct CompanionReply: Codable, Sendable {
    let text: String
    let emotion: String
    let action: String
}
