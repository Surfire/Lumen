import AppKit
import Combine
import Contacts
import EventKit
import Foundation

enum PersonalDataScope: String, Equatable, Hashable, Sendable {
    case contacts
    case calendar
    case reminders
}

enum PersonalDataAuthStatus: String, Equatable, Hashable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

struct PersonalDataProvider: Sendable {
    let contactsStatus: @Sendable () -> PersonalDataAuthStatus
    let requestContactsAccess: @Sendable () async -> PersonalDataAuthStatus
    let fetchContacts: @Sendable () async -> [ContactHit]
    let calendarStatus: @Sendable () -> PersonalDataAuthStatus
    let requestCalendarAccess: @Sendable () async -> PersonalDataAuthStatus
    let fetchEvents: @Sendable (_ from: Date, _ to: Date) async -> [CalendarEventHit]
    let remindersStatus: @Sendable () -> PersonalDataAuthStatus
    let requestRemindersAccess: @Sendable () async -> PersonalDataAuthStatus
    let fetchReminders: @Sendable () async -> [ReminderHit]
    let completeReminder: @Sendable (_ id: String) async -> Bool

    init(
        contactsStatus: @escaping @Sendable () -> PersonalDataAuthStatus = { .notDetermined },
        requestContactsAccess: @escaping @Sendable () async -> PersonalDataAuthStatus = { .denied },
        fetchContacts: @escaping @Sendable () async -> [ContactHit] = { [] },
        calendarStatus: @escaping @Sendable () -> PersonalDataAuthStatus = { .notDetermined },
        requestCalendarAccess: @escaping @Sendable () async -> PersonalDataAuthStatus = { .denied },
        fetchEvents: @escaping @Sendable (_ from: Date, _ to: Date) async -> [CalendarEventHit] = { _, _ in [] },
        remindersStatus: @escaping @Sendable () -> PersonalDataAuthStatus = { .notDetermined },
        requestRemindersAccess: @escaping @Sendable () async -> PersonalDataAuthStatus = { .denied },
        fetchReminders: @escaping @Sendable () async -> [ReminderHit] = { [] },
        completeReminder: @escaping @Sendable (_ id: String) async -> Bool = { _ in false }
    ) {
        self.contactsStatus = contactsStatus
        self.requestContactsAccess = requestContactsAccess
        self.fetchContacts = fetchContacts
        self.calendarStatus = calendarStatus
        self.requestCalendarAccess = requestCalendarAccess
        self.fetchEvents = fetchEvents
        self.remindersStatus = remindersStatus
        self.requestRemindersAccess = requestRemindersAccess
        self.fetchReminders = fetchReminders
        self.completeReminder = completeReminder
    }

    // Never instantiates CNContactStore or EKEventStore unless an explicit request/fetch closure runs.
    static let system = PersonalDataProvider(
        contactsStatus: {
            currentContactsStatus()
        },
        requestContactsAccess: {
            let store = CNContactStore()
            _ = try? await store.requestAccess(for: .contacts)
            return currentContactsStatus()
        },
        fetchContacts: {
            await Task.detached(priority: .utility) { () -> [ContactHit] in
                guard currentContactsStatus() == .authorized else { return [] }
                let store = CNContactStore()
                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactMiddleNameKey as CNKeyDescriptor,
                    CNContactNicknameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                    CNContactJobTitleKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                    CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                ]
                let request = CNContactFetchRequest(keysToFetch: keys)
                var results: [ContactHit] = []
                let limit = 5_000
                try? store.enumerateContacts(with: request) { contact, stop in
                    if results.count >= limit {
                        stop.pointee = true
                        return
                    }
                    let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let organization = org.isEmpty ? nil : org
                    let jobTitle = contact.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let primaryPhone = contact.phoneNumbers
                        .map { $0.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty })
                    let primaryEmail = contact.emailAddresses
                        .map { ($0.value as String).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty })

                    let formattedName = CNContactFormatter.string(from: contact, style: .fullName)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fullName = [formattedName, org, primaryEmail ?? "", primaryPhone ?? ""]
                        .first(where: { !$0.isEmpty }) ?? ""
                    guard !fullName.isEmpty else { return }

                    var subtitleParts: [String] = []
                    if let organization,
                       organization.compare(fullName, options: .caseInsensitive) != .orderedSame {
                        if !jobTitle.isEmpty {
                            subtitleParts.append("\(jobTitle) · \(organization)")
                        } else {
                            subtitleParts.append(organization)
                        }
                    } else if !jobTitle.isEmpty {
                        subtitleParts.append(jobTitle)
                    }
                    if let primaryPhone, primaryPhone != fullName {
                        subtitleParts.append(primaryPhone)
                    } else if let primaryEmail, primaryEmail != fullName {
                        subtitleParts.append(primaryEmail)
                    }
                    if subtitleParts.count < 2, let primaryEmail, primaryEmail != fullName,
                       !subtitleParts.contains(primaryEmail) {
                        subtitleParts.append(primaryEmail)
                    }
                    let subtitle = subtitleParts.prefix(2).joined(separator: " · ")

                    results.append(ContactHit(
                        id: contact.identifier,
                        fullName: fullName,
                        subtitle: subtitle,
                        primaryPhone: primaryPhone,
                        primaryEmail: primaryEmail,
                        organization: organization
                    ))
                }
                results.sort { lhs, rhs in
                    let cmp = lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName)
                    if cmp != .orderedSame { return cmp == .orderedAscending }
                    return lhs.id < rhs.id
                }
                return results
            }.value
        },
        calendarStatus: {
            currentEventKitStatus(for: .event)
        },
        requestCalendarAccess: {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                    store.requestAccess(to: .event) { granted, error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume(returning: granted)
                        }
                    }
                }
            }
            return currentEventKitStatus(for: .event)
        },
        fetchEvents: { from, to in
            await Task.detached(priority: .utility) { () -> [CalendarEventHit] in
                guard currentEventKitStatus(for: .event) == .authorized else { return [] }
                let store = EKEventStore()
                let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
                let now = Date()
                let events = store.events(matching: predicate)
                var results: [CalendarEventHit] = []
                results.reserveCapacity(min(events.count, 1_000))

                for event in events {
                    let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, let startDate = event.startDate, let endDate = event.endDate else { continue }
                    let baseID = event.eventIdentifier ?? title
                    let occurrenceID = "\(baseID)@\(Int(startDate.timeIntervalSince1970))"
                    let calendarTitle = event.calendar?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let rawLocation = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let location = (rawLocation?.isEmpty == false) ? rawLocation : nil
                    let meetingURL = PersonalDataFormatting.extractMeetingURL(
                        eventURL: event.url,
                        location: location,
                        notes: event.notes
                    )
                    let dateSummary = PersonalDataFormatting.eventDateSummary(
                        start: startDate,
                        end: endDate,
                        isAllDay: event.isAllDay,
                        now: now
                    )
                    results.append(CalendarEventHit(
                        id: occurrenceID,
                        title: title,
                        startDate: startDate,
                        endDate: endDate,
                        isAllDay: event.isAllDay,
                        calendarTitle: calendarTitle,
                        location: location,
                        meetingURL: meetingURL,
                        dateSummary: dateSummary
                    ))
                }

                results.sort { lhs, rhs in
                    if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                    if lhs.title != rhs.title { return lhs.title < rhs.title }
                    return lhs.id < rhs.id
                }
                if results.count > 1_000 {
                    return Array(results.prefix(1_000))
                }
                return results
            }.value
        },
        remindersStatus: {
            currentEventKitStatus(for: .reminder)
        },
        requestRemindersAccess: {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToReminders()
            } else {
                _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                    store.requestAccess(to: .reminder) { granted, error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume(returning: granted)
                        }
                    }
                }
            }
            return currentEventKitStatus(for: .reminder)
        },
        fetchReminders: {
            await Task.detached(priority: .utility) { () -> [ReminderHit] in
                guard currentEventKitStatus(for: .reminder) == .authorized else { return [] }
                let store = EKEventStore()
                let predicate = store.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: nil
                )
                let now = Date()
                let calendar = Calendar.current
                let hits: [ReminderHit] = await withCheckedContinuation { continuation in
                    store.fetchReminders(matching: predicate) { reminders in
                        var items: [ReminderHit] = []
                        if let reminders {
                            items.reserveCapacity(min(reminders.count, 2_000))
                            for reminder in reminders where !reminder.isCompleted {
                                let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !title.isEmpty else { continue }
                                let dueDate = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
                                let listTitle = reminder.calendar?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                let rawNotes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                                let notes = (rawNotes?.isEmpty == false) ? rawNotes : nil
                                let dueSummary = PersonalDataFormatting.reminderDueSummary(dueDate: dueDate, now: now)
                                items.append(ReminderHit(
                                    id: reminder.calendarItemIdentifier,
                                    title: title,
                                    dueDate: dueDate,
                                    listTitle: listTitle,
                                    notes: notes,
                                    priority: reminder.priority,
                                    dueSummary: dueSummary,
                                    isCompleted: reminder.isCompleted
                                ))
                            }
                        }
                        continuation.resume(returning: items)
                    }
                }
                let sorted = hits.sorted { lhs, rhs in
                    switch (lhs.dueDate, rhs.dueDate) {
                    case let (l?, r?) where l != r:
                        return l < r
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    default:
                        let lp = PersonalDataFormatting.priorityRank(lhs.priority)
                        let rp = PersonalDataFormatting.priorityRank(rhs.priority)
                        if lp != rp { return lp < rp }
                        if lhs.title != rhs.title { return lhs.title < rhs.title }
                        return lhs.id < rhs.id
                    }
                }
                return sorted.count > 2_000 ? Array(sorted.prefix(2_000)) : sorted
            }.value
        },
        completeReminder: { id in
            await Task.detached(priority: .userInitiated) { () -> Bool in
                guard currentEventKitStatus(for: .reminder) == .authorized else { return false }
                let store = EKEventStore()
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
                reminder.isCompleted = true
                reminder.completionDate = Date()
                do {
                    try store.save(reminder, commit: true)
                    return true
                } catch {
                    return false
                }
            }.value
        }
    )

    private static func currentContactsStatus() -> PersonalDataAuthStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    private static func currentEventKitStatus(for entityType: EKEntityType) -> PersonalDataAuthStatus {
        let status = EKEventStore.authorizationStatus(for: entityType)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return .authorized
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            case .denied, .writeOnly: return .denied
            @unknown default: return .denied
            }
        } else {
            switch status.rawValue {
            case EKAuthorizationStatus.notDetermined.rawValue: return .notDetermined
            case EKAuthorizationStatus.restricted.rawValue: return .restricted
            case EKAuthorizationStatus.denied.rawValue: return .denied
            case 3: return .authorized
            default: return .denied
            }
        }
    }
}

private enum PersonalDataFormatting {
    private static let httpsRegex = try! NSRegularExpression(pattern: #"https://[^\s<>"'\)\]]+"#, options: [.caseInsensitive])

    static func extractMeetingURL(eventURL: URL?, location: String?, notes: String?) -> String? {
        if let eventURL, let scheme = eventURL.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            return eventURL.absoluteString
        }
        for candidate in [location, notes].compactMap({ $0 }) where !candidate.isEmpty {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let match = httpsRegex.firstMatch(in: candidate, range: range),
               let swiftRange = Range(match.range, in: candidate) {
                var raw = String(candidate[swiftRange])
                while let last = raw.last, [".", ",", ";", ":", "!", "?"].contains(last) {
                    raw.removeLast()
                }
                if URL(string: raw) != nil {
                    return raw
                }
            }
        }
        return nil
    }

    static func eventDateSummary(start: Date, end: Date, isAllDay: Bool, now: Date) -> String {
        let calendar = Calendar.current
        let dayLabel = relativeDayLabel(for: start, now: now, calendar: calendar)
        if isAllDay {
            return "\(dayLabel) · All Day"
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.current
        timeFormatter.dateFormat = "HH:mm"
        let startTime = timeFormatter.string(from: start)
        if calendar.isDate(start, inSameDayAs: end) && end > start {
            return "\(dayLabel) \(startTime)–\(timeFormatter.string(from: end))"
        }
        return "\(dayLabel) \(startTime)"
    }

    static func reminderDueSummary(dueDate: Date?, now: Date) -> String {
        guard let dueDate else { return "No due date" }
        let calendar = Calendar.current
        let dayLabel = relativeDayLabel(for: dueDate, now: now, calendar: calendar)
        let components = calendar.dateComponents([.hour, .minute], from: dueDate)
        if (components.hour ?? 0) == 0 && (components.minute ?? 0) == 0 {
            return dayLabel
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.current
        timeFormatter.dateFormat = "HH:mm"
        return "\(dayLabel) \(timeFormatter.string(from: dueDate))"
    }

    static func priorityRank(_ priority: Int) -> Int {
        switch priority {
        case 1...4: return 0
        case 5: return 1
        case 6...9: return 2
        default: return 3
        }
    }

    private static func relativeDayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}

private struct IndexedContact: Sendable {
    let hit: ContactHit
    let lowerName: String
    let normName: String
    let pinyinName: [String]
    let lowerOrg: String
    let normOrg: String
    let pinyinOrg: [String]
    let lowerSubtitle: String
    let lowerEmail: String
    let digitsPhone: String

    init(hit: ContactHit) {
        self.hit = hit
        let locale = Locale(identifier: "en_US_POSIX")
        self.lowerName = hit.fullName.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.normName = LaunchCatalog.normalized(hit.fullName)
        self.pinyinName = LaunchCatalog.pinyinAliases(hit.fullName)
        let org = hit.organization ?? ""
        self.lowerOrg = org.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.normOrg = LaunchCatalog.normalized(org)
        self.pinyinOrg = LaunchCatalog.pinyinAliases(org)
        self.lowerSubtitle = hit.subtitle.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.lowerEmail = (hit.primaryEmail ?? "").lowercased()
        self.digitsPhone = (hit.primaryPhone ?? "").filter(\.isNumber)
    }
}

private struct IndexedEvent: Sendable {
    let hit: CalendarEventHit
    let lowerTitle: String
    let normTitle: String
    let pinyinTitle: [String]
    let lowerLocation: String
    let lowerCalendar: String
    let lowerSummary: String

    init(hit: CalendarEventHit) {
        self.hit = hit
        let locale = Locale(identifier: "en_US_POSIX")
        self.lowerTitle = hit.title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.normTitle = LaunchCatalog.normalized(hit.title)
        self.pinyinTitle = LaunchCatalog.pinyinAliases(hit.title)
        self.lowerLocation = (hit.location ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.lowerCalendar = hit.calendarTitle.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.lowerSummary = hit.dateSummary.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }
}

private struct IndexedReminder: Sendable {
    let hit: ReminderHit
    let lowerTitle: String
    let normTitle: String
    let pinyinTitle: [String]
    let lowerNotes: String
    let lowerList: String
    let lowerSummary: String

    init(hit: ReminderHit) {
        self.hit = hit
        let locale = Locale(identifier: "en_US_POSIX")
        self.lowerTitle = hit.title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.normTitle = LaunchCatalog.normalized(hit.title)
        self.pinyinTitle = LaunchCatalog.pinyinAliases(hit.title)
        self.lowerNotes = (hit.notes ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.lowerList = hit.listTitle.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        self.lowerSummary = hit.dueSummary.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }
}

@MainActor
final class PersonalDataStore: ObservableObject {
    static let contactsEnabledKey = "lumen.contactsSearchEnabled"
    static let calendarEnabledKey = "lumen.calendarSearchEnabled"
    static let remindersEnabledKey = "lumen.remindersSearchEnabled"

    private static let contactsTTL: TimeInterval = 180
    private static let eventsTTL: TimeInterval = 60
    private static let remindersTTL: TimeInterval = 60

    @Published private(set) var contactsEnabled: Bool
    @Published private(set) var calendarEnabled: Bool
    @Published private(set) var remindersEnabled: Bool

    @Published private(set) var contactsAuth: PersonalDataAuthStatus
    @Published private(set) var calendarAuth: PersonalDataAuthStatus
    @Published private(set) var remindersAuth: PersonalDataAuthStatus

    @Published private(set) var contactsCount: Int = 0
    @Published private(set) var eventsCount: Int = 0
    @Published private(set) var remindersCount: Int = 0

    private let defaults: UserDefaults
    private let provider: PersonalDataProvider

    private var indexedContacts: [IndexedContact] = []
    private var indexedEvents: [IndexedEvent] = []
    private var indexedReminders: [IndexedReminder] = []

    private var lastContactsFetch: Date?
    private var lastEventsFetch: Date?
    private var lastRemindersFetch: Date?

    private var contactsGeneration: UInt64 = 0
    private var eventsGeneration: UInt64 = 0
    private var remindersGeneration: UInt64 = 0

    init(defaults: UserDefaults = .standard, provider: PersonalDataProvider = .system) {
        self.defaults = defaults
        self.provider = provider
        // Strictly opt-in: all personal data toggles default to false.
        self.contactsEnabled = defaults.object(forKey: Self.contactsEnabledKey) as? Bool ?? false
        self.calendarEnabled = defaults.object(forKey: Self.calendarEnabledKey) as? Bool ?? false
        self.remindersEnabled = defaults.object(forKey: Self.remindersEnabledKey) as? Bool ?? false
        // Synchronous authorizationStatus checks never trigger TCC permission dialogs.
        self.contactsAuth = provider.contactsStatus()
        self.calendarAuth = provider.calendarStatus()
        self.remindersAuth = provider.remindersStatus()

        let hasActiveAuthorizedSource =
            (contactsEnabled && contactsAuth == .authorized)
            || (calendarEnabled && calendarAuth == .authorized)
            || (remindersEnabled && remindersAuth == .authorized)
        if hasActiveAuthorizedSource {
            Task { [weak self] in
                await self?.refreshIfNeeded(force: true)
            }
        }
    }

    func setContactsEnabled(_ enabled: Bool) async {
        guard enabled else {
            contactsEnabled = false
            defaults.set(false, forKey: Self.contactsEnabledKey)
            clearContacts()
            return
        }
        var status = provider.contactsStatus()
        contactsAuth = status
        if status == .notDetermined {
            status = await provider.requestContactsAccess()
            contactsAuth = status
        }
        if status == .authorized {
            contactsEnabled = true
            defaults.set(true, forKey: Self.contactsEnabledKey)
            await refreshContacts(force: true)
        } else {
            contactsEnabled = false
            defaults.set(false, forKey: Self.contactsEnabledKey)
            clearContacts()
        }
    }

    func setCalendarEnabled(_ enabled: Bool) async {
        guard enabled else {
            calendarEnabled = false
            defaults.set(false, forKey: Self.calendarEnabledKey)
            clearEvents()
            return
        }
        var status = provider.calendarStatus()
        calendarAuth = status
        if status == .notDetermined {
            status = await provider.requestCalendarAccess()
            calendarAuth = status
        }
        if status == .authorized {
            calendarEnabled = true
            defaults.set(true, forKey: Self.calendarEnabledKey)
            await refreshEvents(force: true)
        } else {
            calendarEnabled = false
            defaults.set(false, forKey: Self.calendarEnabledKey)
            clearEvents()
        }
    }

    func setRemindersEnabled(_ enabled: Bool) async {
        guard enabled else {
            remindersEnabled = false
            defaults.set(false, forKey: Self.remindersEnabledKey)
            clearReminders()
            return
        }
        var status = provider.remindersStatus()
        remindersAuth = status
        if status == .notDetermined {
            status = await provider.requestRemindersAccess()
            remindersAuth = status
        }
        if status == .authorized {
            remindersEnabled = true
            defaults.set(true, forKey: Self.remindersEnabledKey)
            await refreshReminders(force: true)
        } else {
            remindersEnabled = false
            defaults.set(false, forKey: Self.remindersEnabledKey)
            clearReminders()
        }
    }

    func refreshAuthorizationStatuses() {
        let nextContacts = provider.contactsStatus()
        let nextCalendar = provider.calendarStatus()
        let nextReminders = provider.remindersStatus()

        if contactsAuth != nextContacts { contactsAuth = nextContacts }
        if calendarAuth != nextCalendar { calendarAuth = nextCalendar }
        if remindersAuth != nextReminders { remindersAuth = nextReminders }

        if contactsAuth != .authorized { clearContacts() }
        if calendarAuth != .authorized { clearEvents() }
        if remindersAuth != .authorized { clearReminders() }
    }

    func refreshIfNeeded(force: Bool = false) async {
        refreshAuthorizationStatuses()
        async let contactsTask: Void = refreshContacts(force: force)
        async let eventsTask: Void = refreshEvents(force: force)
        async let remindersTask: Void = refreshReminders(force: force)
        _ = await (contactsTask, eventsTask, remindersTask)
    }

    func completeReminder(id: String) async -> Bool {
        guard remindersEnabled, remindersAuth == .authorized else { return false }
        let completed = await provider.completeReminder(id)
        guard completed else { return false }
        indexedReminders.removeAll { $0.hit.id == id }
        if remindersCount != indexedReminders.count {
            remindersCount = indexedReminders.count
        }
        return true
    }

    func matches(_ query: String, limitPerSource: Int = 5) -> [(result: LauncherResult, score: Double)] {
        guard limitPerSource > 0 else { return [] }
        let searchContacts = contactsEnabled && contactsAuth == .authorized && !indexedContacts.isEmpty
        let searchEvents = calendarEnabled && calendarAuth == .authorized && !indexedEvents.isEmpty
        let searchReminders = remindersEnabled && remindersAuth == .authorized && !indexedReminders.isEmpty
        guard searchContacts || searchEvents || searchReminders else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return [] }
        let hasCJK = trimmed.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        guard trimmed.count >= 2 || hasCJK else { return [] }

        let lowerQuery = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let normQuery = LaunchCatalog.normalized(trimmed)
        let digitQuery = trimmed.filter(\.isNumber)
        let tokens = lowerQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let normTokens = tokens.map(LaunchCatalog.normalized)
        guard !tokens.isEmpty else { return [] }

        var combined: [(result: LauncherResult, score: Double)] = []
        let now = Date()

        if searchContacts {
            let contactMatches = indexedContacts.compactMap { entry -> (result: LauncherResult, score: Double)? in
                guard let score = Self.scoreContact(
                    entry,
                    lowerQuery: lowerQuery,
                    normQuery: normQuery,
                    digitQuery: digitQuery,
                    tokens: tokens,
                    normTokens: normTokens
                ) else { return nil }
                return (.contact(entry.hit), score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.result.id < rhs.result.id
            }
            .prefix(limitPerSource)
            combined.append(contentsOf: contactMatches)
        }

        if searchEvents {
            let eventMatches = indexedEvents.compactMap { entry -> (result: LauncherResult, score: Double)? in
                guard var score = Self.scoreEvent(
                    entry,
                    lowerQuery: lowerQuery,
                    normQuery: normQuery,
                    tokens: tokens,
                    normTokens: normTokens
                ) else { return nil }
                let delta = entry.hit.startDate.timeIntervalSince(now)
                if delta >= -3_600 && delta <= 48 * 3_600 {
                    score = min(84.0, score + 2.0)
                }
                return (.calendarEvent(entry.hit), score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.result.id < rhs.result.id
            }
            .prefix(limitPerSource)
            combined.append(contentsOf: eventMatches)
        }

        if searchReminders {
            let reminderMatches = indexedReminders.compactMap { entry -> (result: LauncherResult, score: Double)? in
                guard !entry.hit.isCompleted,
                      let score = Self.scoreReminder(
                          entry,
                          lowerQuery: lowerQuery,
                          normQuery: normQuery,
                          tokens: tokens,
                          normTokens: normTokens
                      ) else { return nil }
                return (.reminder(entry.hit), score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.result.id < rhs.result.id
            }
            .prefix(limitPerSource)
            combined.append(contentsOf: reminderMatches)
        }

        combined.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.result.id < rhs.result.id
        }
        return combined
    }

    static func openPrivacySettings(for scope: PersonalDataScope) {
        let anchor: String
        switch scope {
        case .contacts: anchor = "Privacy_Contacts"
        case .calendar: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        _ = LaunchDispatcher.openSettings(url)
    }

    private func refreshContacts(force: Bool) async {
        guard contactsEnabled, contactsAuth == .authorized else { return }
        if !force, let lastContactsFetch, Date().timeIntervalSince(lastContactsFetch) < Self.contactsTTL {
            return
        }
        contactsGeneration &+= 1
        let gen = contactsGeneration
        let hits = await provider.fetchContacts()
        let indexed = await Task.detached(priority: .utility) {
            hits.map(IndexedContact.init)
        }.value
        guard contactsEnabled, contactsAuth == .authorized, contactsGeneration == gen else { return }
        indexedContacts = indexed
        lastContactsFetch = Date()
        if contactsCount != indexed.count {
            contactsCount = indexed.count
        }
    }

    private func refreshEvents(force: Bool) async {
        guard calendarEnabled, calendarAuth == .authorized else { return }
        if !force, let lastEventsFetch, Date().timeIntervalSince(lastEventsFetch) < Self.eventsTTL {
            return
        }
        eventsGeneration &+= 1
        let gen = eventsGeneration
        let now = Date()
        let from = now.addingTimeInterval(-86_400)
        let to = now.addingTimeInterval(30 * 86_400)
        let hits = await provider.fetchEvents(from, to)
        let indexed = await Task.detached(priority: .utility) {
            hits.map(IndexedEvent.init)
        }.value
        guard calendarEnabled, calendarAuth == .authorized, eventsGeneration == gen else { return }
        indexedEvents = indexed
        lastEventsFetch = Date()
        if eventsCount != indexed.count {
            eventsCount = indexed.count
        }
    }

    private func refreshReminders(force: Bool) async {
        guard remindersEnabled, remindersAuth == .authorized else { return }
        if !force, let lastRemindersFetch, Date().timeIntervalSince(lastRemindersFetch) < Self.remindersTTL {
            return
        }
        remindersGeneration &+= 1
        let gen = remindersGeneration
        let hits = await provider.fetchReminders()
        let indexed = await Task.detached(priority: .utility) {
            hits.filter { !$0.isCompleted }.map(IndexedReminder.init)
        }.value
        guard remindersEnabled, remindersAuth == .authorized, remindersGeneration == gen else { return }
        indexedReminders = indexed
        lastRemindersFetch = Date()
        if remindersCount != indexed.count {
            remindersCount = indexed.count
        }
    }

    private func clearContacts() {
        contactsGeneration &+= 1
        indexedContacts.removeAll()
        lastContactsFetch = nil
        if contactsCount != 0 { contactsCount = 0 }
    }

    private func clearEvents() {
        eventsGeneration &+= 1
        indexedEvents.removeAll()
        lastEventsFetch = nil
        if eventsCount != 0 { eventsCount = 0 }
    }

    private func clearReminders() {
        remindersGeneration &+= 1
        indexedReminders.removeAll()
        lastRemindersFetch = nil
        if remindersCount != 0 { remindersCount = 0 }
    }

    private static func scoreContact(
        _ entry: IndexedContact,
        lowerQuery: String,
        normQuery: String,
        digitQuery: String,
        tokens: [String],
        normTokens: [String]
    ) -> Double? {
        func tokenScore(_ token: String, _ norm: String) -> Double? {
            if entry.lowerName == token || (!norm.isEmpty && entry.normName == norm) { return 82.0 }
            if entry.lowerName.hasPrefix(token) || (!norm.isEmpty && entry.normName.hasPrefix(norm)) { return 76.0 }
            if !norm.isEmpty && entry.pinyinName.contains(norm) { return 74.0 }
            if entry.lowerName.contains(token) || (!norm.isEmpty && entry.normName.contains(norm)) { return 70.0 }
            if !norm.isEmpty && entry.pinyinName.contains(where: { $0.hasPrefix(norm) }) { return 66.0 }
            if !entry.lowerOrg.isEmpty,
               entry.lowerOrg.contains(token)
               || (!norm.isEmpty && (entry.normOrg.contains(norm) || entry.pinyinOrg.contains(where: { $0.hasPrefix(norm) }))) {
                return 62.0
            }
            if !entry.lowerEmail.isEmpty && entry.lowerEmail.contains(token) { return 60.0 }
            let tokenDigits = token.filter(\.isNumber)
            if tokenDigits.count >= 3 && !entry.digitsPhone.isEmpty && entry.digitsPhone.contains(tokenDigits) {
                return 60.0
            }
            if !entry.lowerSubtitle.isEmpty && entry.lowerSubtitle.contains(token) { return 54.0 }
            return nil
        }

        if tokens.count == 1 {
            if digitQuery.count >= 4, !entry.digitsPhone.isEmpty, entry.digitsPhone.contains(digitQuery) {
                return max(tokenScore(lowerQuery, normQuery) ?? 0, 64.0)
            }
            return tokenScore(lowerQuery, normQuery)
        }

        var sum = 0.0
        for index in tokens.indices {
            guard let score = tokenScore(tokens[index], normTokens[index]) else { return nil }
            sum += score
        }
        return min(82.0, max(50.0, sum / Double(tokens.count)))
    }

    private static func scoreEvent(
        _ entry: IndexedEvent,
        lowerQuery: String,
        normQuery: String,
        tokens: [String],
        normTokens: [String]
    ) -> Double? {
        func tokenScore(_ token: String, _ norm: String) -> Double? {
            if entry.lowerTitle == token || (!norm.isEmpty && entry.normTitle == norm) { return 80.0 }
            if entry.lowerTitle.hasPrefix(token) || (!norm.isEmpty && entry.normTitle.hasPrefix(norm)) { return 74.0 }
            if !norm.isEmpty && entry.pinyinTitle.contains(norm) { return 72.0 }
            if entry.lowerTitle.contains(token) || (!norm.isEmpty && entry.normTitle.contains(norm)) { return 68.0 }
            if !norm.isEmpty && entry.pinyinTitle.contains(where: { $0.hasPrefix(norm) }) { return 62.0 }
            if !entry.lowerLocation.isEmpty && entry.lowerLocation.contains(token) { return 58.0 }
            if !entry.lowerCalendar.isEmpty && entry.lowerCalendar.contains(token) { return 54.0 }
            if !entry.lowerSummary.isEmpty && entry.lowerSummary.contains(token) { return 50.0 }
            return nil
        }

        if tokens.count == 1 {
            return tokenScore(lowerQuery, normQuery)
        }
        var sum = 0.0
        for index in tokens.indices {
            guard let score = tokenScore(tokens[index], normTokens[index]) else { return nil }
            sum += score
        }
        return min(80.0, max(48.0, sum / Double(tokens.count)))
    }

    private static func scoreReminder(
        _ entry: IndexedReminder,
        lowerQuery: String,
        normQuery: String,
        tokens: [String],
        normTokens: [String]
    ) -> Double? {
        func tokenScore(_ token: String, _ norm: String) -> Double? {
            if entry.lowerTitle == token || (!norm.isEmpty && entry.normTitle == norm) { return 78.0 }
            if entry.lowerTitle.hasPrefix(token) || (!norm.isEmpty && entry.normTitle.hasPrefix(norm)) { return 72.0 }
            if !norm.isEmpty && entry.pinyinTitle.contains(norm) { return 70.0 }
            if entry.lowerTitle.contains(token) || (!norm.isEmpty && entry.normTitle.contains(norm)) { return 66.0 }
            if !norm.isEmpty && entry.pinyinTitle.contains(where: { $0.hasPrefix(norm) }) { return 60.0 }
            if !entry.lowerNotes.isEmpty && entry.lowerNotes.contains(token) { return 56.0 }
            if !entry.lowerList.isEmpty && entry.lowerList.contains(token) { return 52.0 }
            if !entry.lowerSummary.isEmpty && entry.lowerSummary.contains(token) { return 48.0 }
            return nil
        }

        if tokens.count == 1 {
            return tokenScore(lowerQuery, normQuery)
        }
        var sum = 0.0
        for index in tokens.indices {
            guard let score = tokenScore(tokens[index], normTokens[index]) else { return nil }
            sum += score
        }
        return min(78.0, max(48.0, sum / Double(tokens.count)))
    }
}
