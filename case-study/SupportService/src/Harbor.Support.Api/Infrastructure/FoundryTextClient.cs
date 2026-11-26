using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;
using Harbor.Support.Api.Features;

namespace Harbor.Support.Api.Infrastructure;

public sealed class FoundryTextClient(HttpClient http, HarborOptions options, TokenCredential credential) : ITextClient
{
    public bool IsConfigured => options.Ai.IsConfigured;
    public string Provider => "managed-identity-apim";

    public async Task<TextCompletion> CompleteAsync(
        string message, KnowledgeResult knowledge, SyntheticStatus status, CancellationToken cancellationToken)
    {
        if (!IsConfigured)
            throw new HarborException(503, "text_not_configured", "The managed-identity APIM model route is not configured.");
        var endpoint = new UriBuilder(options.Ai.ChatEndpoint)
        {
            Query = $"api-version={Uri.EscapeDataString(options.Ai.ApiVersion)}"
        };
        try
        {
            var token = await credential.GetTokenAsync(new TokenRequestContext([options.Ai.TokenScope]), cancellationToken);
            using var request = new HttpRequestMessage(HttpMethod.Post, endpoint.Uri);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
            request.Content = JsonContent.Create(new
            {
                model = options.Ai.Deployment,
                messages = new object[]
                {
                    new { role = "system", content = AssistantInstructions.CompanyOnly },
                    new { role = "user", content = JsonSerializer.Serialize(new { question = message, evidence = knowledge.Documents, syntheticStatus = status }) }
                },
                max_tokens = options.Limits.TextMaxOutputTokens,
                temperature = 0.1,
                stream = false
            });
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (!response.IsSuccessStatusCode)
                throw new HarborException(response.StatusCode == System.Net.HttpStatusCode.TooManyRequests ? 429 : 502,
                    "model_provider_failed", "The real APIM model route failed; no successful inference is claimed.");
            using var document = await BoundedJson.ReadHttpAsync(response, 65536, cancellationToken);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array || choices.GetArrayLength() != 1 ||
                choices[0].ValueKind != JsonValueKind.Object ||
                !choices[0].TryGetProperty("message", out var result) ||
                result.ValueKind != JsonValueKind.Object ||
                !result.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.String)
                throw new HarborException(502, "invalid_model_response", "The model route returned an unsupported response shape.");
            var inputTokens = Tokens(root, "prompt_tokens");
            var outputTokens = Tokens(root, "completion_tokens");
            if (outputTokens > options.Limits.TextMaxOutputTokens)
                throw new HarborException(502, "model_output_limit", "The provider exceeded the requested output-token budget.");
            return new TextCompletion(content.GetString()!, inputTokens, outputTokens);
        }
        catch (AuthenticationFailedException)
        {
            throw new HarborException(503, "model_identity_unavailable", "The backend managed identity could not authenticate to the approved APIM audience.");
        }
        catch (HttpRequestException)
        {
            throw new HarborException(503, "model_unavailable", "The real APIM model route could not be reached.");
        }
        catch (JsonException)
        {
            throw new HarborException(502, "invalid_model_response", "The model route returned invalid JSON.");
        }
    }

    private static int? Tokens(JsonElement root, string name) =>
        root.TryGetProperty("usage", out var usage) && usage.ValueKind == JsonValueKind.Object &&
        usage.TryGetProperty(name, out var count) && count.ValueKind == JsonValueKind.Number &&
        count.TryGetInt32(out var value) && value >= 0 ? value : null;
}

public static class BoundedJson
{
    public static async Task<JsonDocument> ReadHttpAsync(
        HttpResponseMessage response, int maximumBytes, CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength > maximumBytes)
            throw new HarborException(502, "provider_message_limit", "The provider response exceeded the bounded message size.");
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var bytes = new MemoryStream();
        var buffer = new byte[4096];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken);
            if (count == 0)
                break;
            if (bytes.Length + count > maximumBytes)
                throw new HarborException(502, "provider_message_limit", "The provider response exceeded the bounded message size.");
            bytes.Write(buffer, 0, count);
        }
        return JsonDocument.Parse(bytes.ToArray());
    }
}
