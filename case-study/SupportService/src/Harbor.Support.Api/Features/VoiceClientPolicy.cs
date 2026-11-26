using System.Text.Json;

namespace Harbor.Support.Api.Features;

public sealed record ClientVoiceEvent(string Type, string? Audio);

public sealed class VoiceClientPolicy(LimitOptions limits, TimeProvider clock, DateTimeOffset expiresAt)
{
    private long currentSecond = -1;
    private int eventsThisSecond;
    private int bytesThisSecond;
    private long totalAudioBytes;
    private long lastAudioTicks = clock.GetUtcNow().UtcTicks;
    public DateTimeOffset LastAudioAt => new(Interlocked.Read(ref lastAudioTicks), TimeSpan.Zero);

    public ClientVoiceEvent Validate(JsonElement message)
    {
        var now = clock.GetUtcNow();
        if (now >= expiresAt)
            throw new HarborException(410, "voice_session_expired", "The voice session or authorization expired.");
        if (message.ValueKind != JsonValueKind.Object ||
            !message.TryGetProperty("type", out var typeValue) || typeValue.ValueKind != JsonValueKind.String)
            throw new HarborException(400, "voice_message_invalid", "Voice messages must be typed JSON objects.");
        var type = typeValue.GetString()!;
        if (type is not ("audio.append" or "audio.clear" or "response.interrupt" or "session.stop"))
            throw new HarborException(403, "voice_event_denied", "That browser voice event is not allowed.");
        var expected = type == "audio.append" ? new[] { "type", "audio" } : ["type"];
        var properties = message.EnumerateObject().Select(property => property.Name).ToArray();
        if (properties.Length != expected.Length || properties.Distinct().Count() != properties.Length ||
            properties.Any(property => !expected.Contains(property, StringComparer.Ordinal)))
            throw new HarborException(400, "voice_message_invalid", "Voice messages cannot set instructions, tools, or additional fields.");
        var second = now.ToUnixTimeSeconds();
        if (currentSecond != second)
        {
            currentSecond = second;
            eventsThisSecond = 0;
            bytesThisSecond = 0;
        }
        if (++eventsThisSecond > limits.VoiceEventsPerSecond)
            throw new HarborException(429, "voice_event_rate", "The voice event rate limit was exceeded.");
        if (type != "audio.append")
            return new ClientVoiceEvent(type, null);
        if (!message.TryGetProperty("audio", out var audioValue) || audioValue.ValueKind != JsonValueKind.String)
            throw new HarborException(400, "voice_audio_invalid", "Audio must be base64 PCM16.");
        var audio = audioValue.GetString()!;
        var bytes = new byte[limits.VoiceAudioChunkBytes];
        if (audio.Length > ((limits.VoiceAudioChunkBytes + 2) / 3) * 4 ||
            !Convert.TryFromBase64String(audio, bytes, out var length) || length == 0 || length % 2 != 0)
            throw new HarborException(400, "voice_audio_invalid", "Audio must be a bounded, even-length mono PCM16 chunk.");
        bytesThisSecond += length;
        totalAudioBytes += length;
        if (bytesThisSecond > limits.VoiceAudioBytesPerSecond ||
            totalAudioBytes > (long)limits.VoiceSessionSeconds * 48000)
            throw new HarborException(429, "voice_audio_budget", "The bounded voice-audio allowance was exceeded.");
        Interlocked.Exchange(ref lastAudioTicks, now.UtcTicks);
        return new ClientVoiceEvent(type, audio);
    }
}
