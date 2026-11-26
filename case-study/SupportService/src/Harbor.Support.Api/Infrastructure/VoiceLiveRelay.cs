using System.Net.WebSockets;
using System.Text.Json;
using Harbor.Support.Api.Features;

namespace Harbor.Support.Api.Infrastructure;

public sealed class VoiceLiveRelay(
    IVoiceUpstreamFactory factory, SupportTools tools, HarborOptions options, TimeProvider clock,
    ILogger<VoiceLiveRelay> logger)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public JsonElement SessionConfiguration() => JsonSerializer.SerializeToElement(new
    {
        type = "session.update",
        session = new
        {
            modalities = new[] { "text", "audio" },
            instructions = AssistantInstructions.Voice,
            voice = new { type = "azure-standard", name = options.Voice.VoiceName },
            input_audio_format = "pcm16",
            output_audio_format = "pcm16",
            input_audio_sampling_rate = 24000,
            turn_detection = new { type = "server_vad", silence_duration_ms = 500, create_response = false, interrupt_response = true },
            max_response_output_tokens = options.Limits.TextMaxOutputTokens,
            tool_choice = "auto",
            tools = SupportTools.Definitions.Select(Definition).ToArray()
        }
    }, Json);

    private static object Definition(ToolDefinition definition) =>
        new { type = "function", name = definition.Name, description = definition.Description, parameters = definition.Parameters };

    public async Task RunAsync(HttpContext context, VoiceLease lease, CancellationToken cancellationToken)
    {
        var remaining = lease.ExpiresAt - clock.GetUtcNow();
        if (remaining <= TimeSpan.Zero)
            throw new HarborException(410, "voice_session_expired", "The voice lease has expired.");
        using var duration = new CancellationTokenSource(remaining, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lease.Cancellation.Token, duration.Token);
        using var sendGate = new SemaphoreSlim(1, 1);
        using var browserSendGate = new SemaphoreSlim(1, 1);
        using var span = HarborTelemetry.Source.StartActivity("voice.relay");
        WebSocket? browser = null;
        Task[] pumps = [];
        var termination = "stopped";
        try
        {
            using var handshakeTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(options.Limits.ProviderTimeoutSeconds), clock);
            using var handshake = CancellationTokenSource.CreateLinkedTokenSource(linked.Token, handshakeTimeout.Token);
            await using var upstream = await factory.ConnectAsync(handshake.Token);
            await upstream.SendAsync(SessionConfiguration(), handshake.Token);
            browser = await context.WebSockets.AcceptWebSocketAsync(VoiceLeaseRegistry.Protocol);
            var policy = new VoiceClientPolicy(options.Limits, clock, lease.ExpiresAt);

            async Task SendUpstreamAsync(object value, CancellationToken token)
            {
                await sendGate.WaitAsync(token);
                try { await upstream.SendAsync(JsonSerializer.SerializeToElement(value, Json), token); }
                finally { sendGate.Release(); }
            }

            async Task SendBrowserAsync(object value, CancellationToken token)
            {
                await browserSendGate.WaitAsync(token);
                try { await VoiceSocketJson.SendAsync(browser, JsonSerializer.SerializeToElement(value, Json), options.Limits.VoiceServerMessageBytes, token); }
                finally { browserSendGate.Release(); }
            }

            async Task PumpClientAsync()
            {
                while (!linked.IsCancellationRequested)
                {
                    var incoming = await VoiceSocketJson.ReceiveAsync(browser, options.Limits.VoiceClientMessageBytes, linked.Token);
                    if (incoming is null)
                        return;
                    var client = policy.Validate(incoming.Value);
                    switch (client.Type)
                    {
                        case "audio.append":
                            await SendUpstreamAsync(new { type = "input_audio_buffer.append", audio = client.Audio }, linked.Token);
                            break;
                        case "audio.clear":
                            await SendUpstreamAsync(new { type = "input_audio_buffer.clear" }, linked.Token);
                            break;
                        case "response.interrupt":
                            await SendUpstreamAsync(new { type = "response.cancel" }, linked.Token);
                            await SendUpstreamAsync(new { type = "input_audio_buffer.clear" }, linked.Token);
                            break;
                        case "session.stop":
                            return;
                    }
                }
            }

            async Task MonitorIdleAsync()
            {
                while (!linked.IsCancellationRequested)
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), clock, linked.Token);
                    if (clock.GetUtcNow() - policy.LastAudioAt >= TimeSpan.FromSeconds(options.Limits.VoiceIdleSeconds))
                        throw new HarborException(408, "voice_idle_timeout", "The voice session ended because no microphone audio was received.");
                }
            }

            async Task PumpProviderAsync()
            {
                var callIds = new HashSet<string>(StringComparer.Ordinal);
                var toolCalls = 0;
                var stage = 0;
                long outputAudioBytes = 0;
                while (!linked.IsCancellationRequested)
                {
                    var incoming = await upstream.ReceiveAsync(linked.Token);
                    if (incoming is null)
                        return;
                    var message = incoming.Value;
                    if (!message.TryGetProperty("type", out var typeValue) || typeValue.ValueKind != JsonValueKind.String)
                        throw new HarborException(502, "voice_provider_protocol", "The voice provider returned an invalid event.");
                    switch (typeValue.GetString())
                    {
                        case "session.updated":
                            await SendBrowserAsync(new { type = "session.ready", provider = factory.Provider, sampleRate = 24000 }, linked.Token);
                            break;
                        case "input_audio_buffer.speech_started":
                            await SendBrowserAsync(new { type = "speech.started" }, linked.Token);
                            break;
                        case "input_audio_buffer.speech_stopped":
                            stage = 1;
                            await SendUpstreamAsync(new
                            {
                                type = "response.create",
                                response = new
                                {
                                    modalities = new[] { "text" },
                                    tool_choice = "required",
                                    tools = SupportTools.Definitions.Where(definition => definition.Name != "prepare_case").Select(Definition).ToArray(),
                                    max_response_output_tokens = options.Limits.TextMaxOutputTokens
                                }
                            }, linked.Token);
                            break;
                        case "response.function_call_arguments.done":
                        {
                            var name = RequiredString(message, "name", 64);
                            var callId = RequiredString(message, "call_id", 128);
                            var arguments = RequiredString(message, "arguments", 12000);
                            if (!callIds.Add(callId) || ++toolCalls > options.Limits.VoiceToolCallsPerSession)
                                throw new HarborException(429, "voice_tool_budget", "The voice tool limit or duplicate-call protection was reached.");
                            if (stage == 1 && name == "prepare_case" || stage == 2 && name != "prepare_case" ||
                                stage is not (1 or 2) || !SupportTools.Definitions.Any(definition => definition.Name == name))
                                throw new HarborException(403, "voice_tool_denied", "The provider requested an unapproved tool or response stage.");
                            using var argumentDocument = JsonDocument.Parse(arguments, new JsonDocumentOptions { MaxDepth = 8 });
                            using var toolSpan = HarborTelemetry.Source.StartActivity("voice.tool");
                            toolSpan?.SetTag("harbor.tool", name);
                            var result = await tools.ExecuteAsync(lease.Customer, name, argumentDocument.RootElement, linked.Token);
                            var output = result.Output.GetRawText();
                            if (output.Length > 20000)
                                throw new HarborException(413, "voice_tool_output_limit", "The voice tool output exceeded its context budget.");
                            await SendUpstreamAsync(new
                            {
                                type = "conversation.item.create",
                                item = new { type = "function_call_output", call_id = callId, output }
                            }, linked.Token);
                            if (result.Citations is not null)
                                await SendBrowserAsync(new { type = "knowledge.sources", citations = result.Citations }, linked.Token);
                            if (result.Proposal is not null)
                                await SendBrowserAsync(new { type = "case.proposal", proposal = result.Proposal }, linked.Token);
                            stage++;
                            await SendUpstreamAsync(new
                            {
                                type = "response.create",
                                response = new
                                {
                                    modalities = new[] { "text", "audio" },
                                    tool_choice = stage == 2 ? "auto" : "none",
                                    tools = stage == 2 ? SupportTools.Definitions.Where(definition => definition.Name == "prepare_case").Select(Definition).ToArray() : [],
                                    max_response_output_tokens = options.Limits.TextMaxOutputTokens
                                }
                            }, linked.Token);
                            break;
                        }
                        case "response.audio.delta":
                        {
                            if (stage < 2)
                                throw new HarborException(502, "voice_ungrounded_audio", "The provider attempted audio without approved server context.");
                            var audio = RequiredString(message, "delta", options.Limits.VoiceServerMessageBytes);
                            var decoded = new byte[options.Limits.VoiceServerMessageBytes];
                            if (!Convert.TryFromBase64String(audio, decoded, out var bytes) || bytes % 2 != 0)
                                throw new HarborException(502, "voice_provider_audio", "The provider returned invalid PCM16.");
                            outputAudioBytes += bytes;
                            if (outputAudioBytes > (long)options.Limits.VoiceSessionSeconds * 48000)
                                throw new HarborException(429, "voice_output_budget", "The voice output-audio budget was exceeded.");
                            await SendBrowserAsync(new { type = "audio.delta", audio }, linked.Token);
                            break;
                        }
                        case "response.audio_transcript.done":
                            if (stage >= 2)
                                await SendBrowserAsync(new { type = "assistant.text", text = RequiredString(message, "transcript", 8000) }, linked.Token);
                            break;
                        case "response.done":
                            if (message.TryGetProperty("response", out var response) &&
                                response.TryGetProperty("status", out var status) && status.GetString() == "failed")
                                throw new HarborException(502, "voice_provider_failed", "The real voice provider failed to produce a response.");
                            break;
                        case "error":
                            throw new HarborException(502, "voice_provider_failed", "The real voice provider reported a failure.");
                    }
                }
            }

            pumps = [PumpClientAsync(), PumpProviderAsync(), MonitorIdleAsync()];
            var first = await Task.WhenAny(pumps);
            await first;
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested)
        {
            termination = duration.IsCancellationRequested ? "voice_session_expired" :
                lease.Cancellation.IsCancellationRequested ? "voice_revoked" : "voice_disconnected";
        }
        catch (OperationCanceledException)
        {
            if (browser is null)
                throw new HarborException(504, "voice_handshake_timeout", "The bounded real Voice Live handshake timed out.");
            termination = "voice_provider_timeout";
        }
        catch (HarborException failure) when (browser is not null)
        {
            termination = failure.Code;
            await SendFailureAsync(browser, failure.Code, failure.Message, browserSendGate);
        }
        catch (JsonException) when (browser is not null)
        {
            termination = "voice_json_invalid";
            await SendFailureAsync(browser, termination, "A voice event contained malformed JSON.", browserSendGate);
        }
        catch (WebSocketException) when (browser is not null)
        {
            termination = "voice_transport_failed";
            logger.LogWarning("Voice transport ended; trace {TraceId}", span?.TraceId.ToString());
        }
        finally
        {
            linked.Cancel();
            try { await Task.WhenAll(pumps); }
            catch (OperationCanceledException) when (linked.IsCancellationRequested) { }
            catch (HarborException failure) { logger.LogWarning("Voice pump ended with {Code}", failure.Code); }
            catch (WebSocketException) { logger.LogWarning("Voice pump transport closed."); }
            catch (JsonException) { logger.LogWarning("Voice pump received invalid JSON."); }
            if (browser is not null)
            {
                using var closeTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                try
                {
                    if (browser.State is WebSocketState.Open or WebSocketState.CloseReceived)
                        await browser.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, termination, closeTimeout.Token);
                }
                catch (WebSocketException) { logger.LogDebug("Voice peer disconnected before close acknowledgement."); }
                catch (OperationCanceledException) { logger.LogDebug("Voice close acknowledgement timed out."); }
                browser.Dispose();
            }
            HarborTelemetry.VoiceTerminations.Add(1, new KeyValuePair<string, object?>("reason", termination));
        }
    }

    private async Task SendFailureAsync(WebSocket browser, string code, string detail, SemaphoreSlim gate)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            await gate.WaitAsync(timeout.Token);
            try
            {
                if (browser.State == WebSocketState.Open)
                    await VoiceSocketJson.SendAsync(browser, JsonSerializer.SerializeToElement(new { type = "voice.error", code, detail }),
                        options.Limits.VoiceServerMessageBytes, timeout.Token);
            }
            finally { gate.Release(); }
        }
        catch (WebSocketException) { logger.LogDebug("Voice failure could not be delivered to the disconnected peer."); }
        catch (OperationCanceledException) { logger.LogDebug("Voice failure delivery timed out."); }
    }

    private static string RequiredString(JsonElement message, string name, int maximum) =>
        message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String &&
        value.GetString() is { Length: > 0 } text && text.Length <= maximum ? text :
        throw new HarborException(502, "voice_provider_protocol", "The voice provider returned an invalid bounded event field.");
}
