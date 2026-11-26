using System.Net.WebSockets;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;

namespace Harbor.Support.Api.Infrastructure;

public interface IVoiceUpstreamFactory
{
    bool IsConfigured { get; }
    string Provider { get; }
    Task<IVoiceConnection> ConnectAsync(CancellationToken cancellationToken);
}

public interface IVoiceConnection : IAsyncDisposable
{
    Task SendAsync(JsonElement message, CancellationToken cancellationToken);
    Task<JsonElement?> ReceiveAsync(CancellationToken cancellationToken);
}

public sealed class VoiceLiveConnectionFactory(HarborOptions options, TokenCredential credential) : IVoiceUpstreamFactory
{
    public bool IsConfigured => options.Voice.IsConfigured;
    public string Provider => "managed-identity-voice-live";

    public async Task<IVoiceConnection> ConnectAsync(CancellationToken cancellationToken)
    {
        if (!IsConfigured)
            throw new HarborException(503, "voice_not_configured", "The real Voice Live provider is not configured.");
        var socket = new ClientWebSocket();
        var connected = false;
        try
        {
            var token = await credential.GetTokenAsync(new TokenRequestContext([options.Voice.TokenScope]), cancellationToken);
            socket.Options.SetRequestHeader("Authorization", $"Bearer {token.Token}");
            socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);
            var endpoint = new UriBuilder(options.Voice.Endpoint)
            {
                Scheme = "wss",
                Port = -1,
                Query = $"api-version={Uri.EscapeDataString(options.Voice.ApiVersion)}&model={Uri.EscapeDataString(options.Voice.Model)}"
            };
            await socket.ConnectAsync(endpoint.Uri, cancellationToken);
            connected = true;
            return new VoiceLiveConnection(socket, options.Limits.VoiceServerMessageBytes);
        }
        catch (AuthenticationFailedException)
        {
            throw new HarborException(503, "voice_identity_unavailable", "The Voice Live managed identity could not authenticate.");
        }
        catch (WebSocketException)
        {
            throw new HarborException(503, "voice_provider_unavailable", "The real Voice Live connection failed.");
        }
        finally
        {
            if (!connected)
                socket.Dispose();
        }
    }
}

public sealed class VoiceLiveConnection(ClientWebSocket socket, int maximumMessageBytes) : IVoiceConnection
{
    public Task SendAsync(JsonElement message, CancellationToken cancellationToken) =>
        VoiceSocketJson.SendAsync(socket, message, maximumMessageBytes, cancellationToken);
    public Task<JsonElement?> ReceiveAsync(CancellationToken cancellationToken) =>
        VoiceSocketJson.ReceiveAsync(socket, maximumMessageBytes, cancellationToken);
    public ValueTask DisposeAsync()
    {
        socket.Abort();
        socket.Dispose();
        return ValueTask.CompletedTask;
    }
}

public static class VoiceSocketJson
{
    public static async Task<JsonElement?> ReceiveAsync(WebSocket socket, int maximumBytes, CancellationToken cancellationToken)
    {
        var buffer = new byte[Math.Min(8192, maximumBytes)];
        using var message = new MemoryStream();
        while (true)
        {
            var received = await socket.ReceiveAsync(buffer.AsMemory(), cancellationToken);
            if (received.MessageType == WebSocketMessageType.Close)
                return null;
            if (received.MessageType != WebSocketMessageType.Text)
                throw new HarborException(400, "voice_binary_denied", "Only bounded typed JSON voice events are accepted.");
            if (message.Length + received.Count > maximumBytes)
                throw new HarborException(413, "voice_message_limit", "The voice event exceeded the bounded message size.");
            message.Write(buffer, 0, received.Count);
            if (received.EndOfMessage)
                break;
        }
        using var parsed = JsonDocument.Parse(message.ToArray(), new JsonDocumentOptions { MaxDepth = 16 });
        return parsed.RootElement.Clone();
    }

    public static async Task SendAsync(WebSocket socket, JsonElement message, int maximumBytes, CancellationToken cancellationToken)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(message);
        if (bytes.Length > maximumBytes)
            throw new HarborException(413, "voice_message_limit", "The voice event exceeded the bounded message size.");
        await socket.SendAsync(bytes.AsMemory(), WebSocketMessageType.Text, true, cancellationToken);
    }
}
