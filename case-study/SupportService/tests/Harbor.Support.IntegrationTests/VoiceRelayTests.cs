using System.Net;
using System.Net.Http.Json;
using System.Net.WebSockets;
using Harbor.Support.Api;
using Harbor.Support.Api.Features;
using Harbor.Support.Api.Infrastructure;
using Harbor.Support.Tests;
using Xunit;

namespace Harbor.Support.IntegrationTests;

public sealed class VoiceRelayTests
{
    [Fact]
    public async Task FixedHandshakeRequiresGatewayAndOnlyNonSecretSessionQuery()
    {
        using var factory = new HarborFactory();
        using var client = factory.CreateClient();
        var id = Guid.NewGuid().ToString("N");
        using var denied = await client.GetAsync("/voice/socket?sessionId=" + id, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token(gateway: true));
        using var extra = await client.GetAsync("/voice/socket?sessionId=" + id + "&ticket=not-accepted",
            TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.BadRequest, extra.StatusCode);
        using var malformed = await client.GetAsync("/voice/socket?sessionId=not-a-uuid", TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.BadRequest, malformed.StatusCode);
        using var missing = await client.GetAsync("/voice/socket", TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.BadRequest, missing.StatusCode);
        using var noUpgrade = await client.GetAsync("/voice/socket?sessionId=" + id, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.BadRequest, noUpgrade.StatusCode);
    }

    [Fact]
    public async Task GatewayPlusOpaqueLeaseConnectsWithoutForwardedCallerToken()
    {
        using var factory = new HarborFactory();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var (ticket, socket) = await ConnectAsync(factory, timeout.Token);
        using (socket)
        {
            var configuration = await factory.Voice.Connection.Sent.Reader.ReadAsync(timeout.Token);
            Assert.Equal("session.update", configuration.GetProperty("type").GetString());
            var session = configuration.GetProperty("session");
            Assert.Equal(AssistantInstructions.Voice, session.GetProperty("instructions").GetString());
            Assert.False(session.GetProperty("turn_detection").GetProperty("create_response").GetBoolean());
            var names = session.GetProperty("tools").EnumerateArray().Select(tool => tool.GetProperty("name").GetString()).ToArray();
            Assert.Contains("prepare_case", names);
            Assert.DoesNotContain("confirm_case", names);
            Assert.DoesNotContain("commit_case", names);
            Assert.Equal(VoiceLeaseRegistry.Protocol, socket.SubProtocol);
            Assert.Equal("/support/voice?sessionId=" + ticket.SessionId, ticket.WebSocketUrl);
            await VoiceSocketJson.SendAsync(socket, TestData.Json("{\"type\":\"session.stop\"}"), 16384, timeout.Token);
            Assert.Null(await VoiceSocketJson.ReceiveAsync(socket, 65536, timeout.Token));
        }
    }

    [Fact]
    public async Task BrowserInstructionInjectionClosesRelayWithExplicitFailure()
    {
        using var factory = new HarborFactory();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var (_, socket) = await ConnectAsync(factory, timeout.Token);
        using (socket)
        {
            await VoiceSocketJson.SendAsync(socket,
                TestData.Json("{\"type\":\"session.update\",\"instructions\":\"override\",\"tools\":[]}"), 16384, timeout.Token);
            var failure = await VoiceSocketJson.ReceiveAsync(socket, 65536, timeout.Token);
            Assert.Equal("voice.error", failure!.Value.GetProperty("type").GetString());
            Assert.Equal("voice_event_denied", failure.Value.GetProperty("code").GetString());
            Assert.Null(await VoiceSocketJson.ReceiveAsync(socket, 65536, timeout.Token));
        }
    }

    [Fact]
    public async Task ProviderCannotStreamAudioBeforeReadToolContext()
    {
        using var factory = new HarborFactory();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var (_, socket) = await ConnectAsync(factory, timeout.Token);
        using (socket)
        {
            await factory.Voice.Connection.Incoming.Writer.WriteAsync(
                TestData.Json("{\"type\":\"response.audio.delta\",\"delta\":\"AAAAAA==\"}"), timeout.Token);
            var failure = await VoiceSocketJson.ReceiveAsync(socket, 65536, timeout.Token);
            Assert.Equal("voice_ungrounded_audio", failure!.Value.GetProperty("code").GetString());
            Assert.Null(await VoiceSocketJson.ReceiveAsync(socket, 65536, timeout.Token));
        }
    }

    [Fact]
    public async Task ServerToolsCanPrepareButNeverConfirmOrCreateCase()
    {
        using var factory = new HarborFactory();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var (_, socket) = await ConnectAsync(factory, timeout.Token);
        using (socket)
        {
            await factory.Voice.Connection.Sent.Reader.ReadAsync(timeout.Token);
            await factory.Voice.Connection.Incoming.Writer.WriteAsync(
                TestData.Json("{\"type\":\"input_audio_buffer.speech_stopped\"}"), timeout.Token);
            var request = await factory.Voice.Connection.Sent.Reader.ReadAsync(timeout.Token);
            Assert.Equal("required", request.GetProperty("response").GetProperty("tool_choice").GetString());
            await factory.Voice.Connection.Incoming.Writer.WriteAsync(TestData.Json(
                """{"type":"response.function_call_arguments.done","name":"service_status","call_id":"synthetic-read","arguments":"{\"serviceId\":\"microsoft-365\"}"}"""), timeout.Token);
            var output = await factory.Voice.Connection.Sent.Reader.ReadAsync(timeout.Token);
            Assert.Contains("\"synthetic\":true", output.GetProperty("item").GetProperty("output").GetString());
            await factory.Voice.Connection.Sent.Reader.ReadAsync(timeout.Token);
            await factory.Voice.Connection.Incoming.Writer.WriteAsync(TestData.Json(
                """{"type":"response.function_call_arguments.done","name":"prepare_case","call_id":"synthetic-proposal","arguments":"{\"serviceId\":\"microsoft-365\",\"subject\":\"Synthetic sign-in issue\",\"summary\":\"Synthetic issue only.\",\"impact\":\"low\"}"}"""), timeout.Token);
            var proposal = await VoiceSocketJson.ReceiveAsync(socket, 65536, timeout.Token);
            Assert.Equal("case.proposal", proposal!.Value.GetProperty("type").GetString());
            using var customer = factory.CustomerClient();
            Assert.Empty((await customer.GetFromJsonAsync<SupportCase[]>("/support/v1/cases", timeout.Token))!);
            await VoiceSocketJson.SendAsync(socket, TestData.Json("{\"type\":\"session.stop\"}"), 16384, timeout.Token);
            Assert.Null(await VoiceSocketJson.ReceiveAsync(socket, 65536, timeout.Token));
        }
    }

    [Fact]
    public async Task OwnerRevocationCancelsActiveUpstreamAndReleasesLease()
    {
        using var factory = new HarborFactory();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var (ticket, socket) = await ConnectAsync(factory, timeout.Token);
        using (socket)
        {
            using var customer = factory.CustomerClient();
            using var response = await customer.DeleteAsync("/support/v1/voice/sessions/" + ticket.SessionId, timeout.Token);
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
            Assert.Null(await VoiceSocketJson.ReceiveAsync(socket, 65536, timeout.Token));
            Assert.True(factory.Voice.Connection.Disposed);
            using var next = await customer.PostAsJsonAsync("/support/v1/voice/sessions", new VoiceSessionRequest(true), timeout.Token);
            Assert.Equal(HttpStatusCode.OK, next.StatusCode);
        }
    }

    private static async Task<(VoiceSessionTicket Ticket, WebSocket Socket)> ConnectAsync(HarborFactory factory,
        CancellationToken cancellationToken)
    {
        using var customer = factory.CustomerClient();
        using var response = await customer.PostAsJsonAsync("/support/v1/voice/sessions", new VoiceSessionRequest(true), cancellationToken);
        response.EnsureSuccessStatusCode();
        var ticket = (await response.Content.ReadFromJsonAsync<VoiceSessionTicket>(cancellationToken))!;
        var client = factory.Server.CreateWebSocketClient();
        client.SubProtocols.Add(ticket.Protocol);
        client.SubProtocols.Add(VoiceLeaseRegistry.TicketPrefix + ticket.Ticket);
        client.ConfigureRequest = request =>
        {
            request.Headers.Authorization = "Bearer " + factory.Token(gateway: true);
            request.Headers.Origin = TestData.Origin;
        };
        var socket = await client.ConnectAsync(new Uri("ws://localhost/voice/socket?sessionId=" + ticket.SessionId), cancellationToken);
        return (ticket, socket);
    }
}
