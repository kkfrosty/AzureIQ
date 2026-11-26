using System.Globalization;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.IdentityModel.Tokens;

namespace Harbor.Support.Api.Features;

public static class CustomerIdentity
{
    public const string GatewayScheme = "Gateway";
    public const string CustomerScheme = "Customer";
    public const string GatewayIdentityType = "HarborGateway";
    public const string CustomerIdentityType = "HarborCustomer";
    public const string CallerHeader = "X-Harbor-Caller-Authorization";

    public static void AddHarborIdentity(this IServiceCollection services, HarborOptions options)
    {
        services.AddAuthentication()
            .AddJwtBearer(GatewayScheme, jwt => Configure(jwt, options.Entra, GatewayIdentityType, false))
            .AddJwtBearer(CustomerScheme, jwt => Configure(jwt, options.Entra, CustomerIdentityType, true));
        services.AddAuthorizationBuilder()
            .AddPolicy(CustomerScheme, new AuthorizationPolicyBuilder(GatewayScheme, CustomerScheme)
                .RequireAuthenticatedUser().AddRequirements(new CustomerAccessRequirement()).Build())
            .AddPolicy(GatewayScheme, new AuthorizationPolicyBuilder(GatewayScheme)
                .RequireAuthenticatedUser().AddRequirements(new GatewayAccessRequirement()).Build());
        services.AddSingleton<IAuthorizationHandler, CustomerAccessHandler>();
        services.AddSingleton<IAuthorizationHandler, GatewayAccessHandler>();
    }

    private static void Configure(JwtBearerOptions jwt, EntraOptions settings, string identityType, bool caller)
    {
        jwt.MapInboundClaims = false;
        jwt.IncludeErrorDetails = false;
        jwt.RequireHttpsMetadata = true;
        if (settings.IsConfigured)
        {
            jwt.Authority = settings.Authority;
        }
        jwt.TokenValidationParameters = new TokenValidationParameters
        {
            AuthenticationType = identityType,
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidAudiences = settings.Audiences,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            RequireExpirationTime = true,
            RequireSignedTokens = true,
            ClockSkew = TimeSpan.Zero,
            NameClaimType = "oid",
            RoleClaimType = "roles"
        };
        jwt.Events = new JwtBearerEvents
        {
            OnMessageReceived = context =>
            {
                if (!settings.IsConfigured)
                    context.NoResult();
                else if (caller)
                {
                    var header = context.Request.Headers[CallerHeader].ToString();
                    if (header.StartsWith("Bearer ", StringComparison.Ordinal) && !header.Contains(','))
                        context.Token = header[7..];
                    else
                        context.NoResult();
                }
                return Task.CompletedTask;
            },
            OnChallenge = async context =>
            {
                context.HandleResponse();
                if (!context.Response.HasStarted)
                    await WriteAuthProblemAsync(context.HttpContext,
                        settings.IsConfigured ? 401 : 503,
                        settings.IsConfigured ? "authentication_required" : "identity_not_configured");
            },
            OnForbidden = async context =>
            {
                if (!context.Response.HasStarted)
                    await WriteAuthProblemAsync(context.HttpContext, 403, "access_denied");
            }
        };
    }

    private static async Task WriteAuthProblemAsync(HttpContext context, int status, string code)
    {
        context.Response.StatusCode = status;
        if (status == 401)
            context.Response.Headers.WWWAuthenticate = "Bearer";
        await context.Response.WriteAsJsonAsync(new ProblemDetails
        {
            Status = status,
            Title = code,
            Type = $"urn:harbor:problem:{code}",
            Detail = status == 503 ? "Approved runtime identity bindings are not configured." :
                "A valid gateway identity and authorized Harbor customer identity are required.",
            Extensions = { ["code"] = code, ["traceId"] = context.TraceIdentifier }
        }, options: (System.Text.Json.JsonSerializerOptions?)null,
            contentType: "application/problem+json", cancellationToken: context.RequestAborted);
    }

    public static CustomerContext GetCustomer(ClaimsPrincipal principal, HarborOptions options)
    {
        var identity = principal.Identities.SingleOrDefault(candidate =>
            candidate.IsAuthenticated && candidate.AuthenticationType == CustomerIdentityType);
        if (identity is null || !IsCustomer(identity, options.Entra) ||
            !long.TryParse(identity.FindFirst("exp")?.Value, CultureInfo.InvariantCulture, out var expiry))
            throw new HarborException(403, "access_denied", "A scoped Harbor customer identity is required.");
        var owner = Hash($"{HarborOptions.CompanyId}:{identity.FindFirst("tid")!.Value}:{identity.FindFirst("oid")!.Value}");
        return new CustomerContext(HarborOptions.CompanyId, $"h_{owner}", DateTimeOffset.FromUnixTimeSeconds(expiry));
    }

    public static bool IsGateway(ClaimsIdentity identity, EntraOptions options) =>
        identity.IsAuthenticated && identity.AuthenticationType == GatewayIdentityType &&
        identity.FindFirst("tid")?.Value == options.TenantId &&
        Guid.TryParse(identity.FindFirst("oid")?.Value, out _) &&
        identity.FindFirst("scp") is null &&
        identity.HasClaim("roles", options.GatewayRole);

    public static bool IsCustomer(ClaimsIdentity identity, EntraOptions options) =>
        identity.IsAuthenticated && identity.AuthenticationType == CustomerIdentityType &&
        identity.FindFirst("tid")?.Value == options.TenantId &&
        Guid.TryParse(identity.FindFirst("oid")?.Value, out _) &&
        identity.FindFirst("idtyp")?.Value != "app" &&
        identity.HasClaim("roles", options.CustomerRole) &&
        (identity.FindFirst("scp")?.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Contains(options.DelegatedScope, StringComparer.Ordinal) ?? false);

    public static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    public static bool HashEquals(string left, string right) =>
        left.Length == right.Length && CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(left), Encoding.UTF8.GetBytes(right));
}

public sealed record CustomerAccessRequirement : IAuthorizationRequirement;
public sealed record GatewayAccessRequirement : IAuthorizationRequirement;

public sealed class CustomerAccessHandler(HarborOptions options) : AuthorizationHandler<CustomerAccessRequirement>
{
    protected override Task HandleRequirementAsync(AuthorizationHandlerContext context, CustomerAccessRequirement requirement)
    {
        if (options.Entra.IsConfigured &&
            context.User.Identities.Count(identity => CustomerIdentity.IsGateway(identity, options.Entra)) == 1 &&
            context.User.Identities.Count(identity => CustomerIdentity.IsCustomer(identity, options.Entra)) == 1)
            context.Succeed(requirement);
        return Task.CompletedTask;
    }
}

public sealed class GatewayAccessHandler(HarborOptions options) : AuthorizationHandler<GatewayAccessRequirement>
{
    protected override Task HandleRequirementAsync(AuthorizationHandlerContext context, GatewayAccessRequirement requirement)
    {
        if (options.Entra.IsConfigured &&
            context.User.Identities.Count(identity => CustomerIdentity.IsGateway(identity, options.Entra)) == 1)
            context.Succeed(requirement);
        return Task.CompletedTask;
    }
}
