using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexRoster.Windows.Models;

/// <summary>
/// Decodes timestamps emitted by the Rust <c>time</c> crate's default serde format
/// (9-element array) as well as RFC3339 / ISO-8601 strings.
/// </summary>
public sealed class RustDateTimeOffsetConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            var text = reader.GetString();
            if (string.IsNullOrWhiteSpace(text))
            {
                throw new JsonException("Timestamp string was empty.");
            }

            if (DateTimeOffset.TryParse(
                    text,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out var parsed))
            {
                return parsed;
            }

            throw new JsonException($"Unsupported timestamp string: {text}");
        }

        if (reader.TokenType == JsonTokenType.StartArray)
        {
            Span<long> values = stackalloc long[9];
            var count = 0;
            while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
            {
                if (count >= values.Length)
                {
                    throw new JsonException("Unsupported Rust timestamp array length.");
                }

                values[count++] = reader.TokenType switch
                {
                    JsonTokenType.Number => reader.GetInt64(),
                    _ => throw new JsonException("Rust timestamp array must contain numbers."),
                };
            }

            if (count != 9)
            {
                throw new JsonException("Unsupported Rust timestamp array length.");
            }

            return FromRustArray(values);
        }

        throw new JsonException($"Unsupported timestamp token: {reader.TokenType}");
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value.ToString("O", CultureInfo.InvariantCulture));
    }

    private static DateTimeOffset FromRustArray(ReadOnlySpan<long> values)
    {
        var year = checked((int)values[0]);
        var ordinal = checked((int)values[1]);
        var hour = checked((int)values[2]);
        var minute = checked((int)values[3]);
        var second = checked((int)values[4]);
        var nanosecond = values[5];
        var offset = new TimeSpan(
            checked((int)values[6]),
            checked((int)values[7]),
            checked((int)values[8]));

        // time crate stores local wall-clock components + UTC offset.
        var local = new DateTime(year, 1, 1, 0, 0, 0, DateTimeKind.Unspecified)
            .AddDays(ordinal - 1)
            .AddHours(hour)
            .AddMinutes(minute)
            .AddSeconds(second)
            .AddTicks(nanosecond / 100); // 1 tick = 100 nanoseconds

        return new DateTimeOffset(local, offset);
    }
}
