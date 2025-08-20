import Foundation

/// Parses a time string in "h:mm a", "hh:mm a", "h:mma", or "hh:mma" format (case-insensitive for AM/PM)
/// into total minutes since midnight (0-1439).
/// Returns nil if parsing fails.
func parseTimeHMMA(timeString: String) -> Int? {
    let trimmedTime = timeString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX") // Essential for AM/PM parsing

    // Try common formats
    let formats = [
        "h:mma",   // 09:30AM, 9:30AM
        "hh:mma",  // 09:30AM
        "h:mm a",  // 09:30 AM, 9:30 AM
        "hh:mm a"  // 09:30 AM
    ]

    for format in formats {
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmedTime) {
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            return hour * 60 + minute
        }
    }
    
    // Fallback for times like "11:00 AM" (note the space before AM/PM)
    // This was covered by "h:mm a" and "hh:mm a" but kept for explicitness in thought process

    return nil
} 