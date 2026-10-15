import Foundation

/// In-memory I/O for DEBUG-only store construction. No production file,
/// preference domain, or runtime option can select this backend.
@MainActor
final class NativeVisibilityStoreTestIO {
    var preferenceData: Data
    var journalData: Data?
    var events: [String] = []
    var beforeRead: (() throws -> Void)?
    var beforeJournalSave: ((Data?) throws -> Void)?
    var afterPreferenceWrite: (() throws -> Void)?

    init(preferences: Data, journal: Data? = nil) {
        preferenceData = preferences
        journalData = journal
    }

    func readPreferences() throws -> Data {
        try beforeRead?()
        return preferenceData
    }

    func saveJournal(_ data: Data?) throws {
        try beforeJournalSave?(data)
        journalData = data
        events.append("journal")
    }

    func writePreferences(_ data: Data) throws {
        preferenceData = data
        events.append("preferences")
        try afterPreferenceWrite?()
    }
}
