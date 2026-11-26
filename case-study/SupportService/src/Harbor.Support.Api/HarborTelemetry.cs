using System.Diagnostics;
using System.Diagnostics.Metrics;
using OpenTelemetry;

namespace Harbor.Support.Api;

public static class HarborTelemetry
{
    public static readonly ActivitySource Source = new("Harbor.Support");
    public static readonly Meter Meter = new("Harbor.Support");
    public static readonly Counter<long> Commits = Meter.CreateCounter<long>("harbor.case.commits");
    public static readonly Counter<long> VoiceTerminations = Meter.CreateCounter<long>("harbor.voice.terminations");
    public static readonly Histogram<double> ProviderDuration = Meter.CreateHistogram<double>("harbor.provider.duration", "ms");
}

public sealed class PrivacyTraceProcessor : BaseProcessor<Activity>
{
    public override void OnEnd(Activity activity)
    {
        activity.SetTag("url.query", null);
        activity.SetTag("http.url", StripQuery(activity.GetTagItem("http.url")));
        activity.SetTag("url.full", StripQuery(activity.GetTagItem("url.full")));
        activity.SetTag("exception.message", null);
        activity.SetTag("exception.stacktrace", null);
        foreach (var key in activity.TagObjects.Select(tag => tag.Key).Where(key =>
            key.Contains("header", StringComparison.OrdinalIgnoreCase) ||
            key.Contains("body", StringComparison.OrdinalIgnoreCase) ||
            key.Contains("prompt", StringComparison.OrdinalIgnoreCase)).ToArray())
            activity.SetTag(key, null);
    }

    private static object? StripQuery(object? value) =>
        value is string text && Uri.TryCreate(text, UriKind.Absolute, out var uri) ?
            uri.GetLeftPart(UriPartial.Path) : value;
}
