using System.Security.Cryptography;
using Microsoft.AspNetCore.WebUtilities;
using Harbor.Support.Api.Infrastructure;

namespace Harbor.Support.Api.Features;

public sealed class VoiceLease(
    string id, CustomerContext customer, string ticketHash, DateTimeOffset ticketExpiresAt, DateTimeOffset expiresAt) : IDisposable
{
    public string Id { get; } = id;
    public CustomerContext Customer { get; } = customer;
    public string TicketHash { get; } = ticketHash;
    public DateTimeOffset TicketExpiresAt { get; } = ticketExpiresAt;
    public DateTimeOffset ExpiresAt { get; } = expiresAt;
    public bool Connected { get; internal set; }
    public CancellationTokenSource Cancellation { get; } = new();
    public void Dispose() => Cancellation.Dispose();
}

public sealed class VoiceLeaseRegistry(HarborOptions options, TimeProvider clock) : IDisposable
{
    public const string Protocol = "harbor.voice.v1";
    public const string TicketPrefix = "harbor.ticket.";
    private readonly Lock gate = new();
    private readonly Dictionary<string, VoiceLease> leases = new(StringComparer.Ordinal);

    public (VoiceLease Lease, string Ticket) Prepare(CustomerContext customer)
    {
        TableCaseStore.RequireCompany(customer);
        options.Limits.RequireActiveWindow(clock);
        lock (gate)
        {
            PruneExpired();
            if (leases.Count >= options.Limits.VoiceConcurrency ||
                leases.Values.Count(lease => lease.Customer.OwnerKey == customer.OwnerKey) >= options.Limits.VoiceSessionsPerCaller)
                throw new HarborException(429, "voice_concurrency_exhausted", "The caller or global voice-session limit is reached.");
            var now = clock.GetUtcNow();
            var expiresAt = new[] { now.AddSeconds(options.Limits.VoiceSessionSeconds),
                customer.AuthorizationExpiresAt, options.Limits.LabWindowEndsAt!.Value }.Min();
            if (expiresAt <= now)
                throw new HarborException(403, "authorization_expired", "Sign in again before starting voice.");
            var ticket = WebEncoders.Base64UrlEncode(RandomNumberGenerator.GetBytes(32));
            var lease = new VoiceLease(Guid.NewGuid().ToString("N"), customer, CustomerIdentity.Hash(ticket),
                new[] { now.AddSeconds(options.Limits.VoiceTicketSeconds), expiresAt }.Min(), expiresAt);
            leases.Add(lease.Id, lease);
            return (lease, ticket);
        }
    }

    public VoiceLease Consume(string id, IReadOnlyList<string> protocols, string origin)
    {
        if (!options.Voice.AllowedOrigins.Contains(origin, StringComparer.Ordinal) ||
            !VoiceOptions.IsAllowedOriginShape(origin))
            throw new HarborException(403, "voice_origin_denied", "The WebSocket Origin is not approved.");
        if (protocols.Count != 2 || protocols.Distinct(StringComparer.Ordinal).Count() != 2 ||
            !protocols.Contains(Protocol, StringComparer.Ordinal))
            throw new HarborException(400, "voice_protocol_denied", "Use only the fixed Harbor protocol and one connection ticket.");
        var ticketProtocol = protocols.SingleOrDefault(protocol => protocol.StartsWith(TicketPrefix, StringComparison.Ordinal));
        if (ticketProtocol is null || ticketProtocol.Length != TicketPrefix.Length + 43 ||
            !ticketProtocol[TicketPrefix.Length..].All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_'))
            throw new HarborException(403, "voice_ticket_invalid", "The one-time voice ticket is invalid.");
        lock (gate)
        {
            if (!leases.TryGetValue(id, out var lease))
                throw new HarborException(404, "voice_session_not_found", "No valid voice lease was found.");
            if (lease.Connected)
                throw new HarborException(409, "voice_ticket_reused", "The one-time voice ticket was already used.");
            if (lease.TicketExpiresAt <= clock.GetUtcNow() || lease.ExpiresAt <= clock.GetUtcNow() || lease.Cancellation.IsCancellationRequested)
                throw new HarborException(410, "voice_ticket_expired", "The voice ticket or caller authorization expired.");
            if (!CustomerIdentity.HashEquals(lease.TicketHash, CustomerIdentity.Hash(ticketProtocol[TicketPrefix.Length..])))
                throw new HarborException(403, "voice_ticket_invalid", "The one-time voice ticket is invalid.");
            lease.Connected = true;
            return lease;
        }
    }

    public void Revoke(CustomerContext customer, string id)
    {
        lock (gate)
        {
            if (!leases.TryGetValue(id, out var lease) || lease.Customer.OwnerKey != customer.OwnerKey ||
                lease.Customer.CompanyId != customer.CompanyId)
                throw new HarborException(404, "voice_session_not_found", "No caller-owned voice session was found.");
            Remove(id, lease);
        }
    }

    public void Release(string id)
    {
        lock (gate)
        {
            if (leases.TryGetValue(id, out var lease))
                Remove(id, lease);
        }
    }

    private void PruneExpired()
    {
        var now = clock.GetUtcNow();
        foreach (var lease in leases.Values.Where(lease =>
            lease.ExpiresAt <= now || !lease.Connected && lease.TicketExpiresAt <= now).ToArray())
            Remove(lease.Id, lease);
    }

    private void Remove(string id, VoiceLease lease)
    {
        leases.Remove(id);
        lease.Cancellation.Cancel();
        if (!lease.Connected)
            lease.Dispose();
    }

    public void Dispose()
    {
        lock (gate)
        {
            foreach (var lease in leases.Values.ToArray())
                Remove(lease.Id, lease);
        }
    }
}

public sealed class VoiceSessionService(
    IVoiceUpstreamFactory upstream, IUsageLedger usage, VoiceLeaseRegistry leases, HarborOptions options, TimeProvider clock)
{
    public async Task<VoiceSessionTicket> CreateAsync(
        CustomerContext customer, VoiceSessionRequest request, CancellationToken cancellationToken)
    {
        if (!request.Consent)
            throw new HarborException(422, "voice_consent_required", "Explicit microphone and audio-processing consent is required.");
        if (!upstream.IsConfigured)
            throw new HarborException(503, "voice_not_configured", "The real Voice Live provider and approved Origins are not configured.");
        var (lease, ticket) = leases.Prepare(customer);
        var reserved = false;
        try
        {
            var seconds = (int)Math.Ceiling((lease.ExpiresAt - clock.GetUtcNow()).TotalSeconds);
            await usage.ReserveVoiceAsync(customer, seconds, cancellationToken);
            reserved = true;
            return new VoiceSessionTicket(lease.Id, ticket, lease.TicketExpiresAt, lease.ExpiresAt,
                $"{options.PathBase}/voice?sessionId={lease.Id}", VoiceLeaseRegistry.Protocol, upstream.Provider);
        }
        finally
        {
            if (!reserved)
                leases.Release(lease.Id);
        }
    }
}
