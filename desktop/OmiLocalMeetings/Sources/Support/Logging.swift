import Foundation

func log(_ message: String) {
    print("[OmiLocalMeetings] \(message)")
}

func logError(_ message: String, error: Error? = nil) {
    if let error {
        print("[OmiLocalMeetings][error] \(message): \(error.localizedDescription)")
    } else {
        print("[OmiLocalMeetings][error] \(message)")
    }
}
