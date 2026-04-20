import Foundation

func localMeetingLog(_ message: String) {
    print("[OmiDesktopMeetings] \(message)")
}

func localMeetingLogError(_ message: String, error: Error? = nil) {
    if let error {
        print("[OmiDesktopMeetings][error] \(message): \(error.localizedDescription)")
    } else {
        print("[OmiDesktopMeetings][error] \(message)")
    }
}
