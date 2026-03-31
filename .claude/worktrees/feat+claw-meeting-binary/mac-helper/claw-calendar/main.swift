import EventKit
import Foundation

let store = EKEventStore()
let semaphore = DispatchSemaphore(value: 0)

// Request calendar access
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { granted, _ in
        defer { semaphore.signal() }
        guard granted else {
            print("[]")
            return
        }
        printEvents(store: store)
    }
} else {
    store.requestAccess(to: .event) { granted, _ in
        defer { semaphore.signal() }
        guard granted else {
            print("[]")
            return
        }
        printEvents(store: store)
    }
}

semaphore.wait()

func printEvents(store: EKEventStore) {
    let now = Date()
    let twoHoursLater = now.addingTimeInterval(2 * 60 * 60)

    let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60 * 60), end: twoHoursLater, calendars: nil)
    let events = store.events(matching: predicate)

    // Load sensitive keywords from environment
    let sensitiveKeywords: [String] = (ProcessInfo.processInfo.environment["SENSITIVE_TITLE_KEYWORDS"] ?? "")
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    var results: [[String: Any]] = []
    for event in events.prefix(10) {
        let isNow = event.startDate <= now && event.endDate >= now
        // Skip events that ended before now (the predicate start is -1h to catch current events)
        if event.endDate < now { continue }

        var title = event.title ?? "Untitled"

        // Redact sensitive titles
        let titleLower = title.lowercased()
        for keyword in sensitiveKeywords {
            if titleLower.contains(keyword) {
                title = "[private event]"
                break
            }
        }

        results.append([
            "title": title,
            "start": formatter.string(from: event.startDate),
            "end": formatter.string(from: event.endDate),
            "is_now": isNow,
        ])
    }

    if let data = try? JSONSerialization.data(withJSONObject: results),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    } else {
        print("[]")
    }
}
