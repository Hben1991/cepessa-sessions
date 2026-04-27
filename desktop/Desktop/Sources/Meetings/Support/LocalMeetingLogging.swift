import Foundation

func localMeetingLog(_ message: String) {
    print("[CepessaSessions] \(message)")
}

func localMeetingLogError(_ message: String, error: Error? = nil) {
    if let error {
        print("[CepessaSessions][error] \(message): \(error.localizedDescription)")
    } else {
        print("[CepessaSessions][error] \(message)")
    }
}
