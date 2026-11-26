using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using Azure.Core;
using Harbor.Support.Api;
using Harbor.Support.Api.Features;
using Harbor.Support.Api.Infrastructure;
using Harbor.Support.Tests;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.DataProtection.KeyManagement;
using Microsoft.AspNetCore.DataProtection.Repositories;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace Harbor.Support.IntegrationTests;

public sealed class HarborFactory : WebApplicationFactory<Program>
{
    private readonly RSA rsa = RSA.Create(2048);
    public TestClock Clock { get; } = new() { Now = DateTimeOffset.UtcNow };
    public MemoryCaseStore Store { get; } = new();
    public TestUsageLedger Usage { get; } = new();
    public TestTextClient Text { get; } = new();
    public TestKnowledgeStore Knowledge { get; } = new();
    public TestVoiceFactory Voice { get; } = new();
    public HarborOptions Options => TestData.Options(Clock);
    private RsaSecurityKey Key => new(rsa) { KeyId = "synthetic-harbor-test-signing-key" };

    protected override IHost CreateHost(IHostBuilder builder)
    {
        builder.ConfigureHostConfiguration(configuration => configuration.AddInMemoryCollection(
            new Dictionary<string, string?>
            {
                ["Harbor:PathBase"] = "/support",
                ["Harbor:Entra:TenantId"] = TestData.Tenant,
                ["Harbor:Entra:ClientId"] = TestData.Client,
                ["Harbor:Entra:ApiAudience"] = TestData.Audience,
                ["Harbor:Entra:Scope"] = TestData.Audience + "/Support.Access",
                ["Harbor:Storage:ServiceUri"] = Options.Storage.ServiceUri,
                ["Harbor:Search:Endpoint"] = Options.Search.Endpoint,
                ["Harbor:Ai:ChatEndpoint"] = Options.Ai.ChatEndpoint,
                ["Harbor:Ai:TokenScope"] = Options.Ai.TokenScope,
                ["Harbor:Ai:Deployment"] = Options.Ai.Deployment,
                ["Harbor:Voice:Endpoint"] = Options.Voice.Endpoint,
                ["Harbor:Voice:Model"] = Options.Voice.Model,
                ["Harbor:Voice:AllowedOrigins:0"] = TestData.Origin,
                ["Harbor:Limits:LabWindowId"] = Options.Limits.LabWindowId,
                ["Harbor:Limits:LabWindowEndsAt"] = Options.Limits.LabWindowEndsAt!.Value.ToString("O"),
                ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = null
            }));
        return base.CreateHost(builder);
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Development");
        builder.ConfigureServices(services =>
        {
            services.AddDataProtection().UseEphemeralDataProtectionProvider();
            services.Configure<KeyManagementOptions>(keys => keys.XmlRepository = new TestKeyRepository());
            services.RemoveAll<TokenCredential>();
            services.AddSingleton<TokenCredential>(new TestCredential());
            services.RemoveAll<TimeProvider>();
            services.AddSingleton<TimeProvider>(Clock);
            services.RemoveAll<ICaseStore>();
            services.AddSingleton<ICaseStore>(Store);
            services.RemoveAll<IKnowledgeStore>();
            services.AddSingleton<IKnowledgeStore>(Knowledge);
            services.RemoveAll<IUsageLedger>();
            services.AddSingleton<IUsageLedger>(Usage);
            services.RemoveAll<ITextClient>();
            services.AddSingleton<ITextClient>(Text);
            services.RemoveAll<IVoiceUpstreamFactory>();
            services.AddSingleton<IVoiceUpstreamFactory>(Voice);
            foreach (var scheme in new[] { CustomerIdentity.GatewayScheme, CustomerIdentity.CustomerScheme })
                services.PostConfigure<JwtBearerOptions>(scheme, jwt =>
                {
                    var configuration = new OpenIdConnectConfiguration { Issuer = Options.Entra.Authority };
                    configuration.SigningKeys.Add(Key);
                    jwt.ConfigurationManager = new StaticConfigurationManager<OpenIdConnectConfiguration>(configuration);
                    jwt.TokenValidationParameters.ValidIssuer = Options.Entra.Authority;
                });
        });
    }

    public sealed class TestKeyRepository : IXmlRepository
    {
        private readonly List<System.Xml.Linq.XElement> elements = [];
        public IReadOnlyCollection<System.Xml.Linq.XElement> GetAllElements() => elements.ToArray();
        public void StoreElement(System.Xml.Linq.XElement element, string friendlyName) => elements.Add(new(element));
    }

    public string Token(bool gateway = false, string? owner = null, string? role = null, string? scope = null,
        string? tenant = null, string? audience = null, bool expired = false, bool wrongSignature = false)
    {
        var claims = new List<Claim>
        {
            new("tid", tenant ?? TestData.Tenant),
            new("oid", owner ?? (gateway ? "00000000-0000-0000-0000-000000000003" : "00000000-0000-0000-0000-000000000004")),
            new("roles", role ?? (gateway ? "Support.Gateway" : "Support.Customer")),
            new("idtyp", gateway ? "app" : "user")
        };
        if (!gateway || scope is not null)
            claims.Add(new("scp", scope ?? "Support.Access"));
        using var untrusted = wrongSignature ? RSA.Create(2048) : null;
        var signingKey = wrongSignature ? new RsaSecurityKey(untrusted!) { KeyId = "untrusted-key" } : Key;
        var token = new JwtSecurityToken(Options.Entra.Authority, audience ?? TestData.ApiClient, claims,
            DateTime.UtcNow.AddMinutes(-5), DateTime.UtcNow.AddMinutes(expired ? -1 : 30),
            new SigningCredentials(signingKey, SecurityAlgorithms.RsaSha256));
        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    public HttpClient CustomerClient(string? owner = null)
    {
        var client = CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", Token(gateway: true));
        client.DefaultRequestHeaders.Add(CustomerIdentity.CallerHeader, "Bearer " + Token(owner: owner));
        return client;
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
            rsa.Dispose();
    }
}
