import Foundation

/// How long the notification "Snooze" action silences system notifications. The in-app inbox is unaffected.
public enum NotificationSnooze: String, CaseIterable, Sendable {
    case fifteenMinutes = "15m", oneHour = "1h", untilTomorrow = "tomorrow"
    /// Application setting holding the raw value; missing or unknown values mean 15 minutes.
    public static let settingName = "notificationSnoozeDuration"
    public init(setting: String?) { self = setting.flatMap(Self.init(rawValue:)) ?? .fifteenMinutes }
    public var label: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .untilTomorrow: "Until 8:00 tomorrow"
        }
    }
    public func until(_ now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .fifteenMinutes: return now.addingTimeInterval(15*60)
        case .oneHour: return now.addingTimeInterval(60*60)
        case .untilTomorrow:
            let tomorrow = calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:now)) ?? now.addingTimeInterval(24*60*60)
            return calendar.date(bySettingHour:8,minute:0,second:0,of:tomorrow) ?? tomorrow
        }
    }
}
