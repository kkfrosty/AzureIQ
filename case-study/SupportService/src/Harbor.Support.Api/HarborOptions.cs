namespace Harbor.Support.Api;

public sealed record HarborOptions
{
    public const string CompanyId = "harbor-it-services";
    public string PathBase { get; init; } = "";
    public EntraOptions Entra { get; init; } = new();
    public StorageOptions Storage { get; init; } = new();
    public SearchOptions Search { get; init; } = new();
    public AiOptions Ai { get; init; } = new();
    public VoiceOptions Voice { get; init; } = new();
    public LimitOptions Limits { get; init; } = new();

    public void Validate()
    {
        if (PathBase.Length > 0 && (!PathBase.StartsWith('/') || PathBase.EndsWith('/') ||
            PathBase.Contains("..", StringComparison.Ordinal) || PathBase.Contains('?')))
            throw new InvalidOperationException("Harbor:PathBase must be empty or a slash-prefixed path without a trailing slash.");
        Limits.Validate();
    }

    public static bool IsHttpsEndpoint(string value, out Uri endpoint) =>
        Uri.TryCreate(value, UriKind.Absolute, out endpoint!) &&
        endpoint.Scheme == Uri.UriSchemeHttps && endpoint.UserInfo.Length == 0 &&
        endpoint.Query.Length == 0 && endpoint.Fragment.Length == 0;
}

public sealed record EntraOptions
{
    public string TenantId { get; init; } = "";
    public string ClientId { get; init; } = "";
    public string ApiAudience { get; init; } = "";
    public string Scope { get; init; } = "";
    public string DelegatedScope { get; init; } = "Support.Access";
    public string GatewayRole { get; init; } = "Support.Gateway";
    public string CustomerRole { get; init; } = "Support.Customer";
    public IReadOnlyList<string> Audiences
    {
        get
        {
            var clientId = ApiAudience.StartsWith("api://", StringComparison.Ordinal) ? ApiAudience[6..] : ApiAudience;
            return Guid.TryParse(clientId, out var id) ? [id.ToString("D"), $"api://{id:D}"] : [];
        }
    }
    public bool IsConfigured => Guid.TryParse(TenantId, out _) && Guid.TryParse(ClientId, out _) &&
        Audiences.Count == 2 && !string.IsNullOrWhiteSpace(Scope) &&
        !string.IsNullOrWhiteSpace(DelegatedScope) && Scope.EndsWith('/' + DelegatedScope, StringComparison.Ordinal) &&
        !string.IsNullOrWhiteSpace(GatewayRole) && !string.IsNullOrWhiteSpace(CustomerRole);
    public string Authority => $"https://login.microsoftonline.com/{TenantId}/v2.0";
}

public sealed record StorageOptions
{
    public string ServiceUri { get; init; } = "";
    public string CasesTableName { get; init; } = "HarborCases";
    public string UsageTableName { get; init; } = "HarborUsage";
    public bool IsConfigured => HarborOptions.IsHttpsEndpoint(ServiceUri, out _) &&
        IsTableName(CasesTableName) && IsTableName(UsageTableName) && CasesTableName != UsageTableName;

    public static bool IsTableName(string value) => value.Length is >= 3 and <= 63 &&
        char.IsAsciiLetter(value[0]) && value.All(char.IsAsciiLetterOrDigit);
}

public sealed record SearchOptions
{
    public string Endpoint { get; init; } = "";
    public string IndexName { get; init; } = "harbor-knowledge-v1";
    public bool IsConfigured => HarborOptions.IsHttpsEndpoint(Endpoint, out _) &&
        IndexName.Length is >= 2 and <= 128 &&
        IndexName.All(character => char.IsAsciiLetterLower(character) || char.IsAsciiDigit(character) || character == '-');
}

public sealed record AiOptions
{
    public string ChatEndpoint { get; init; } = "";
    public string TokenScope { get; init; } = "";
    public string Deployment { get; init; } = "";
    public string ApiVersion { get; init; } = "2024-10-21";
    public bool IsConfigured => HarborOptions.IsHttpsEndpoint(ChatEndpoint, out var endpoint) &&
        endpoint.AbsolutePath.EndsWith("/ai/chat", StringComparison.Ordinal) &&
        TokenScope.EndsWith("/.default", StringComparison.Ordinal) &&
        !TokenScope.Contains("cognitiveservices.azure.com", StringComparison.OrdinalIgnoreCase) &&
        !TokenScope.Contains("ai.azure.com", StringComparison.OrdinalIgnoreCase) &&
        !string.IsNullOrWhiteSpace(Deployment) && !string.IsNullOrWhiteSpace(ApiVersion);
}

public sealed record VoiceOptions
{
    public string Endpoint { get; init; } = "";
    public string TokenScope { get; init; } = "https://ai.azure.com/.default";
    public string Model { get; init; } = "";
    public string ApiVersion { get; init; } = "2026-07-15";
    public string VoiceName { get; init; } = "en-US-AvaNeural";
    public string[] AllowedOrigins { get; init; } = [];
    public bool IsConfigured => HarborOptions.IsHttpsEndpoint(Endpoint, out var endpoint) &&
        endpoint.AbsolutePath == "/voice-live/realtime" &&
        TokenScope.EndsWith("/.default", StringComparison.Ordinal) &&
        !string.IsNullOrWhiteSpace(Model) && ApiVersion == "2026-07-15" &&
        !string.IsNullOrWhiteSpace(VoiceName) && AllowedOrigins.Length > 0 &&
        AllowedOrigins.All(IsAllowedOriginShape);

    public static bool IsAllowedOriginShape(string value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var origin) &&
        (origin.Scheme == Uri.UriSchemeHttps || origin.Scheme == Uri.UriSchemeHttp && origin.IsLoopback) &&
        origin.AbsolutePath == "/" && origin.Query.Length == 0 && origin.Fragment.Length == 0 &&
        origin.UserInfo.Length == 0 && value == origin.GetLeftPart(UriPartial.Authority);
}

public sealed record LimitOptions
{
    public string LabWindowId { get; init; } = "";
    public DateTimeOffset? LabWindowEndsAt { get; init; }
    public int TextRequestsPerMinute { get; init; } = 10;
    public int TextRequestsPerWindow { get; init; } = 100;
    public int TextMaxChars { get; init; } = 2000;
    public int TextMaxOutputTokens { get; init; } = 600;
    public int ModelConcurrency { get; init; } = 2;
    public int ProviderTimeoutSeconds { get; init; } = 20;
    public int ProposalSeconds { get; init; } = 600;
    public int VoiceSessionsPerCaller { get; init; } = 1;
    public int VoiceConcurrency { get; init; } = 2;
    public int VoiceSessionSeconds { get; init; } = 300;
    public int VoiceIdleSeconds { get; init; } = 60;
    public int VoiceSecondsPerWindow { get; init; } = 1200;
    public int VoiceTicketSeconds { get; init; } = 30;
    public int VoiceClientMessageBytes { get; init; } = 16384;
    public int VoiceServerMessageBytes { get; init; } = 65536;
    public int VoiceAudioChunkBytes { get; init; } = 4800;
    public int VoiceAudioBytesPerSecond { get; init; } = 57600;
    public int VoiceEventsPerSecond { get; init; } = 40;
    public int VoiceToolCallsPerSession { get; init; } = 8;

    public void Validate()
    {
        if (TextRequestsPerMinute is < 1 or > 10 || TextRequestsPerWindow is < 1 or > 100 ||
            TextMaxChars is < 1 or > 2000 || TextMaxOutputTokens is < 1 or > 600 ||
            ModelConcurrency is < 1 or > 2 || ProviderTimeoutSeconds is < 1 or > 60 ||
            ProposalSeconds is < 1 or > 600 || VoiceSessionsPerCaller != 1 || VoiceConcurrency is < 1 or > 2 ||
            VoiceSessionSeconds is < 1 or > 300 || VoiceIdleSeconds is < 1 or > 60 ||
            VoiceSecondsPerWindow is < 1 or > 1200 || VoiceTicketSeconds is < 1 or > 30 ||
            VoiceClientMessageBytes is < 256 or > 16384 || VoiceServerMessageBytes is < 1024 or > 65536 ||
            VoiceAudioChunkBytes is < 2 or > 4800 || VoiceAudioChunkBytes % 2 != 0 ||
            VoiceAudioBytesPerSecond is < 4800 or > 57600 || VoiceEventsPerSecond is < 1 or > 40 ||
            VoiceToolCallsPerSession is < 1 or > 8)
            throw new InvalidOperationException("Harbor:Limits must stay within the approved small-lab ceilings.");
    }

    public void RequireActiveWindow(TimeProvider clock)
    {
        if (string.IsNullOrWhiteSpace(LabWindowId) || LabWindowId.Length > 128 || LabWindowEndsAt is null)
            throw new HarborException(503, "lab_not_configured", "An approved, bounded lab window is required for inference.");
        if (LabWindowEndsAt <= clock.GetUtcNow())
            throw new HarborException(429, "lab_window_closed", "The lab window has ended.");
    }
}
