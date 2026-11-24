import Foundation

/// An Xtream catch-up archive's address, `…/timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts`,
/// which names where it starts and how long it runs. Such an origin can only be read straight
/// through (AE#958), so a place past what the session holds is reached by asking for the archive
/// again from a later minute, the way IPTV players seek in catch-up.
struct CatchUpArchive {
    /// Up to and including `/timeshift/{user}/{pass}/`.
    private let head: String
    /// The start the address names, in the provider's own clock (kept as UTC, only ever shifted).
    private let start: Date
    /// From the `/` after the start: the stream id and anything after it.
    private let tail: String
    /// The programme's whole length, in seconds.
    let length: Double

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(.*/timeshift/[^/]+/[^/]+/)(\d+)/(\d{4}-\d{2}-\d{2}:\d{2}-\d{2})(/.+)$"#
    )

    private static let format: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd:HH-mm"
        return format
    }()

    init?(_ address: String, length: Double?) {
        guard let length, length > 60 else { return nil }
        let whole = NSRange(address.startIndex..., in: address)
        guard let match = Self.pattern.firstMatch(in: address, range: whole), match.numberOfRanges == 5,
              let head = Range(match.range(at: 1), in: address),
              let start = Range(match.range(at: 3), in: address),
              let tail = Range(match.range(at: 4), in: address),
              let date = Self.format.date(from: String(address[start])) else { return nil }
        self.head = String(address[head])
        self.start = date
        self.tail = String(address[tail])
        self.length = length
    }

    /// The whole minute at or before `seconds` into the programme that a reopen can start from,
    /// leaving at least a minute to play.
    func offset(for seconds: Double) -> Double {
        let minute = (max(seconds, 0) / 60).rounded(.down) * 60
        return min(minute, max(((length - 60) / 60).rounded(.down) * 60, 0))
    }

    /// The archive from `offset` seconds into the programme to its end.
    func address(from offset: Double) -> String {
        let begin = start.addingTimeInterval(offset)
        let minutes = Int(((length - offset) / 60).rounded(.up))
        return head + "\(max(minutes, 1))/" + Self.format.string(from: begin) + tail
    }
}
