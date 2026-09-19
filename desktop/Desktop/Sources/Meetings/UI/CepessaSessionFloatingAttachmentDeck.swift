import Foundation

struct CepessaSessionFloatingAttachmentDeck: Equatable {
    let previews: [CepessaSessionFloatingAttachmentPreview]
    let overflowCount: Int

    static let empty = Self(previews: [], overflowCount: 0)

    var hasContent: Bool {
        !previews.isEmpty || overflowCount > 0
    }

    static func build(
        from session: LocalSession,
        sessionFolderURL: URL?,
        maxVisible: Int = 3
    ) -> Self {
        let sortedAttachments = session.attachments
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString > rhs.id.uuidString
                }
                return lhs.timestamp > rhs.timestamp
            }

        let visibleAttachments = Array(sortedAttachments.prefix(maxVisible))
        let previews = visibleAttachments.map {
            CepessaSessionFloatingAttachmentPreview(
                attachment: $0,
                sessionFolderURL: sessionFolderURL
            )
        }
        let overflowCount = max(0, sortedAttachments.count - previews.count)
        return Self(previews: previews, overflowCount: overflowCount)
    }
}

struct CepessaSessionFloatingAttachmentPreview: Identifiable, Equatable {
    let id: UUID
    let title: String
    let fileName: String?
    let kind: LocalSessionAttachment.Kind
    let timestamp: Date
    let sessionOffset: TimeInterval?
    let fileURL: URL?

    init(attachment: LocalSessionAttachment, sessionFolderURL: URL?) {
        self.id = attachment.id
        self.title = attachment.title
        self.fileName = attachment.fileName
        self.kind = attachment.kind
        self.timestamp = attachment.timestamp
        self.sessionOffset = attachment.sessionOffset

        self.fileURL = LocalSessionAttachmentResolver.localURL(
            for: attachment,
            in: sessionFolderURL
        )
    }

    init(_ attachment: LocalSessionAttachment, sessionFolderURL: URL?) {
        self.init(attachment: attachment, sessionFolderURL: sessionFolderURL)
    }
}
