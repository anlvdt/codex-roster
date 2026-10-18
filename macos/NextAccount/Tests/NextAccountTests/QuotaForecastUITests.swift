import Foundation
import Testing
@testable import CodexRoster

/// Forecast and runway math surfaced in the notch deck (audit E2/F wave 2).
///
/// The expected strings are the implementation's real output: `humanize` only
/// switches to hours at 120 minutes, so 100 minutes reads "100m", not "1h 40m".
@Test func forecastSummaryFormatsEstimateAndConfidence() {
    let forecast = QuotaWindowForecast(
        window: "five_hour",
        remainingPercent: 20,
        burnPerMinute: 0.2,
        timeToEmptyMinutes: 100,
        ciLowMinutes: 80,
        ciHighMinutes: 120,
        confidence: "high",
        sampleCount: 6
    )
    #expect(forecast.summary(vietnamese: false) == "empty in ~100m (CI 80m–2h) · confidence high")
    #expect(forecast.summary(vietnamese: true) == "cạn sau ~100 phút (CI 80 phút–2 giờ) · độ tin cậy high")
}

@Test func forecastSummaryUsesHoursAboveTwoHoursAndOmitsAMissingInterval() {
    let long = QuotaWindowForecast(
        window: "weekly",
        remainingPercent: 12,
        burnPerMinute: 0.05,
        timeToEmptyMinutes: 150,
        ciLowMinutes: 120,
        ciHighMinutes: 240,
        confidence: "medium",
        sampleCount: 9
    )
    #expect(long.summary(vietnamese: false) == "empty in ~2h 30m (CI 2h–4h) · confidence medium")
    #expect(long.summary(vietnamese: true) == "cạn sau ~2 giờ 30 phút (CI 2 giờ–4 giờ) · độ tin cậy medium")

    // No confidence interval: the interval segment is omitted entirely.
    let bare = QuotaWindowForecast(
        window: "five_hour",
        remainingPercent: 60,
        burnPerMinute: 0.1,
        timeToEmptyMinutes: 45,
        ciLowMinutes: nil,
        ciHighMinutes: nil,
        confidence: "low",
        sampleCount: 2
    )
    #expect(bare.summary(vietnamese: false) == "empty in ~45m · confidence low")
}

@Test func forecastSummaryIsNilWithoutAMeasurableBurn() {
    let unknown = QuotaWindowForecast(
        window: "five_hour",
        remainingPercent: 100,
        burnPerMinute: 0,
        timeToEmptyMinutes: nil,
        ciLowMinutes: nil,
        ciHighMinutes: nil,
        confidence: "low",
        sampleCount: 3
    )
    #expect(unknown.summary(vietnamese: false) == nil)
    #expect(unknown.summary(vietnamese: true) == nil)
}

@Test func forecastHumanizesShortAndLongDurations() {
    #expect(QuotaWindowForecast.humanize(22, vietnamese: false) == "22m")
    #expect(QuotaWindowForecast.humanize(22, vietnamese: true) == "22 phút")
    #expect(QuotaWindowForecast.humanize(120, vietnamese: false) == "2h")
    #expect(QuotaWindowForecast.humanize(125, vietnamese: true) == "2 giờ 5 phút")
    // Negative or NaN-ish input must not produce a negative label.
    #expect(QuotaWindowForecast.humanize(-5, vietnamese: false) == "0m")
}

@Test func runwayFlagsWhenTheWindowDiesBeforeItsReset() {
    let willDrain = QuotaRunway(minutesToEmpty: 30, minutesUntilReset: 120, confidence: "high")
    #expect(willDrain.runsOutBeforeReset)
    #expect(abs(willDrain.fraction - 0.25) < 0.0001)

    let survives = QuotaRunway(minutesToEmpty: 240, minutesUntilReset: 120, confidence: "high")
    #expect(!survives.runsOutBeforeReset)
    #expect(survives.fraction == 1, "the marker must clamp at the end of the bar")
}

@Test func runwayFractionNeverGoesNegativeOrAboveOne() {
    let zero = QuotaRunway(minutesToEmpty: 0, minutesUntilReset: 60, confidence: "low")
    #expect(zero.fraction == 0)
    let overrun = QuotaRunway(minutesToEmpty: 600, minutesUntilReset: 60, confidence: "medium")
    #expect(overrun.fraction == 1)
}

@Test func archivedFilterHidesArchivedRowsFromTheDefaultList() {
    let active = SavedAccount(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        provider: "open_ai",
        email: "active@example.com",
        name: nil,
        customLabel: nil,
        planLabel: "Plus",
        environment: "macos",
        isActive: true,
        archived: false,
        usage: nil,
        usageError: nil
    )
    let archived = SavedAccount(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        provider: "open_ai",
        email: "archived@example.com",
        name: nil,
        customLabel: nil,
        planLabel: "Plus",
        environment: "macos",
        isActive: false,
        archived: true,
        usage: nil,
        usageError: nil
    )
    #expect(RosterListFilter.all.matches(active))
    #expect(!RosterListFilter.all.matches(archived), "archived rows stay out of the default list")
    #expect(RosterListFilter.archived.matches(archived))
    #expect(!RosterListFilter.archived.matches(active))

    // The archived chip is `.triage(.archived)`: it must keep matching archived
    // rows. A blanket `!archived` guard on every triage bucket silently emptied
    // that chip (CI caught it).
    #expect(RosterListFilter.triage(.archived).matches(archived))
    #expect(!RosterListFilter.triage(.archived).matches(active))
    #expect(RosterListFilter.triage(.active).matches(active))
    #expect(!RosterListFilter.triage(.active).matches(archived))
    #expect(!RosterListFilter.triage(.ready).matches(archived), "archived rows must not reappear under Ready")
}

/// Notch ear labels must degrade instead of clipping (the ears are 146pt wide).
@Test func earCompactDropsMinutesOnceTheResetIsFarAway() {
    let calendar = Calendar.current
    let far = calendar.date(byAdding: .day, value: 3, to: Date())!
    let farLabel = ResetClockFormat.earCompact(far, asClock: true, language: .english)
    #expect(!farLabel.contains(":"), "a reset days away should not spend width on minutes: \(farLabel)")

    let soon = Date().addingTimeInterval(2 * 3600)
    let soonLabel = ResetClockFormat.earCompact(soon, asClock: true, language: .english)
    #expect(soonLabel.contains(":"), "a reset within the day keeps its exact time: \(soonLabel)")

    // Countdown mode is unaffected: it is already short ("3D", "12M").
    #expect(ResetClockFormat.earCompact(far, asClock: false, language: .english).count <= 4)
}

@Test func minimalEarLabelIsShorterThanTheShortForm() {
    let calendar = Calendar.current
    let far = calendar.date(byAdding: .day, value: 3, to: Date())!
    let minimal = ResetClockFormat.minimal(far, asClock: true, language: .english)
    let short = ResetClockFormat.earCompact(far, asClock: true, language: .english)
    #expect(minimal.count < short.count, "the last-resort label must be shorter: \(minimal) vs \(short)")

    let soon = Date().addingTimeInterval(3600)
    let soonMinimal = ResetClockFormat.minimal(soon, asClock: true, language: .english)
    let soonFull = ResetClockFormat.compact(soon, asClock: true, language: .english)
    #expect(soonMinimal.count <= soonFull.count)
}

/// Free/Go plans have no weekly limit and only a monthly one, so the primary
/// window must not be labelled "5h" (the roster used to mislabel it).
@Test func freeMonthlyPrimaryWindowIsLabelledMonthly() {
    let fetched = RustDate(value: Date())
    let monthly = UsageWindow(
        remainingPercent: 0,
        resetAt: RustDate(value: Date().addingTimeInterval(30 * 86_400))
    )
    let usage = AccountUsage(
        fetchedAt: fetched,
        fiveHour: monthly,
        weekly: nil,
        credits: nil,
        bankedResets: nil,
        subscriptionActiveUntil: nil,
        lunaReserve: nil,
        primaryWindowKind: nil   // older cache: derive it from the span
    )
    #expect(usage.primaryWindowLabel == "1M")

    let fiveHourly = AccountUsage(
        fetchedAt: fetched,
        fiveHour: UsageWindow(
            remainingPercent: 80,
            resetAt: RustDate(value: Date().addingTimeInterval(4 * 3_600))
        ),
        weekly: nil,
        credits: nil,
        bankedResets: nil,
        subscriptionActiveUntil: nil,
        lunaReserve: nil,
        primaryWindowKind: "five_hour"
    )
    #expect(fiveHourly.primaryWindowLabel == "5h")

    let explicitMonthly = AccountUsage(
        fetchedAt: fetched,
        fiveHour: monthly,
        weekly: nil,
        credits: nil,
        bankedResets: nil,
        subscriptionActiveUntil: nil,
        lunaReserve: nil,
        primaryWindowKind: "monthly"
    )
    #expect(explicitMonthly.primaryWindowLabel == "1M")
}

/// K12/Edu plans used to fall into the "Other" band because only pro/plus/team/
/// free/go were recognised by the plan-band grouping.
@Test func educationPlansGetTheirOwnBandInsteadOfOther() {
    func account(plan: String?) -> SavedAccount {
        SavedAccount(
            id: UUID(),
            provider: "open_ai",
            email: "person@example.com",
            name: nil,
            customLabel: nil,
            planLabel: plan,
            environment: "macos",
            isActive: false,
            archived: false,
            usage: nil,
            usageError: nil
        )
    }
    #expect(account(plan: "K12").planGroupKey == "edu")
    #expect(account(plan: "k12").planGroupKey == "edu")
    #expect(account(plan: "Edu").planGroupKey == "edu")
    #expect(account(plan: "Campus").planGroupKey == "edu")
    #expect(account(plan: "Plus").planGroupKey == "plus")
    #expect(account(plan: "Pro").planGroupKey == "pro")
    #expect(account(plan: "Team").planGroupKey == "team")
    #expect(account(plan: "Free").planGroupKey == "free")
    #expect(account(plan: "Go").planGroupKey == "free")
    #expect(account(plan: "Mystery Tier").planGroupKey == "other")
    #expect(account(plan: nil).planGroupKey == "other")
}
