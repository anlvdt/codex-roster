import Foundation
import Testing
@testable import CodexRoster

/// Forecast and runway math surfaced in the notch deck (audit E2/F wave 2).
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
}
