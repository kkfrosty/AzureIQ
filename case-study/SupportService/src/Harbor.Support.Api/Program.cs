using System.Diagnostics;
using System.Text.Json.Serialization;
using Azure.Core;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Harbor.Support.Api.Features;
using Harbor.Support.Api.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.OpenApi;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

namespace Harbor.Support.Api;

public sealed class Program
{
    public static async Task<int> Main(string[] args)
    {
        if (args.FirstOrDefault() == "seed")
            return await SeedCommand.RunAsync(args[1..], CancellationToken.None);
        var exportContracts = args.FirstOrDefault() == "export-contracts";
        if (exportContracts && args.Length != 2)
        {
            Console.Error.WriteLine("Use export-contracts <output-directory>.");
            return 2;
        }
        var builder = exportContracts
            ? WebApplication.CreateBuilder(new WebApplicationOptions { Args = [], EnvironmentName = Environments.Development })
            : WebApplication.CreateBuilder(args);
        var options = builder.Configuration.GetSection("Harbor").Get<HarborOptions>() ?? new HarborOptions();
        options.Validate();
        builder.WebHost.ConfigureKestrel(server => server.Limits.MaxRequestBodySize = 16384);
        builder.Services.AddSingleton(options);
        builder.Services.AddSingleton(TimeProvider.System);
        builder.Services.AddSingleton<TokenCredential>(_ => CreateManagedIdentityCredential(builder.Configuration["AZURE_CLIENT_ID"]));
        builder.Services.AddSingleton(_ => new Catalog(Path.Combine(AppContext.BaseDirectory, "data")));
        builder.Services.AddHarborIdentity(options);
        builder.Services.AddSingleton<ICaseStore, TableCaseStore>();
        builder.Services.AddSingleton<IKnowledgeStore, AiSearchKnowledgeStore>();
        builder.Services.AddSingleton<IUsageLedger, TableUsageLedger>();
        builder.Services.AddSingleton<CaseService>();
        builder.Services.AddSingleton<KnowledgeService>();
        builder.Services.AddSingleton<SupportTools>();
        builder.Services.AddSingleton<VoiceLeaseRegistry>();
        builder.Services.AddSingleton<IVoiceUpstreamFactory, VoiceLiveConnectionFactory>();
        builder.Services.AddSingleton<VoiceSessionService>();
        builder.Services.AddSingleton<VoiceLiveRelay>();
        builder.Services.AddHttpClient<ITextClient, FoundryTextClient>(http =>
        {
            http.Timeout = TimeSpan.FromSeconds(options.Limits.ProviderTimeoutSeconds);
            http.MaxResponseContentBufferSize = 65536;
        }).ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false });
        builder.Services.AddSingleton<AssistantService>();
        builder.Services.AddProblemDetails(problem => problem.CustomizeProblemDetails = context =>
        {
            context.ProblemDetails.Extensions["traceId"] = Activity.Current?.TraceId.ToString() ?? context.HttpContext.TraceIdentifier;
        });
        builder.Services.AddExceptionHandler<HarborExceptionHandler>();
        builder.Services.ConfigureHttpJsonOptions(json =>
        {
            json.SerializerOptions.PropertyNameCaseInsensitive = false;
            json.SerializerOptions.AllowDuplicateProperties = false;
            json.SerializerOptions.UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow;
            json.SerializerOptions.MaxDepth = 16;
        });
        builder.Services.Configure<Microsoft.AspNetCore.Routing.RouteHandlerOptions>(routing => routing.ThrowOnBadRequest = true);
        builder.Services.AddOpenApi("v1", document =>
        {
            document.OpenApiVersion = OpenApiSpecVersion.OpenApi3_0;
            document.AddDocumentTransformer((api, _, _) =>
            {
                api.Info = new OpenApiInfo
                {
                    Title = "Harbor IT Services Support",
                    Version = "v1",
                    Description = "Fictional company support. Public APIM caller JWT; backend independently validates gateway role and forwarded caller JWT. No confirmation issuance is an assistant tool."
                };
                api.Servers = [new OpenApiServer { Url = string.IsNullOrEmpty(options.PathBase) ? "/" : options.PathBase }];
                api.Components ??= new OpenApiComponents();
                api.Components.SecuritySchemes = new Dictionary<string, IOpenApiSecurityScheme>
                {
                    ["customerBearer"] = new OpenApiSecurityScheme { Type = SecuritySchemeType.Http, Scheme = "bearer", BearerFormat = "JWT", Description = "Public APIM: delegated Support.Access and Support.Customer in the approved tenant; the server maps that role to Harbor. APIM forwards the original token in X-Harbor-Caller-Authorization." },
                    ["gatewayBearer"] = new OpenApiSecurityScheme { Type = SecuritySchemeType.Http, Scheme = "bearer", BearerFormat = "JWT", Description = "Private backend: app-only token with Support.Gateway in Authorization; never a browser credential." }
                };
                return Task.CompletedTask;
            });
            document.AddOperationTransformer((operation, context, _) =>
            {
                var policies = context.Description.ActionDescriptor.EndpointMetadata.OfType<IAuthorizeData>().ToArray();
                if (policies.Length > 0)
                    operation.Security =
                    [
                        new OpenApiSecurityRequirement
                        {
                            [new OpenApiSecuritySchemeReference(policies.Any(policy => policy.Policy == CustomerIdentity.CustomerScheme) ?
                                "customerBearer" : "gatewayBearer", context.Document)] = []
                        }
                    ];
                return Task.CompletedTask;
            });
        });
        var telemetry = builder.Services.AddOpenTelemetry()
            .WithTracing(tracing => tracing.AddSource("Harbor.Support").AddProcessor(new PrivacyTraceProcessor()))
            .WithMetrics(metrics => metrics.AddMeter("Harbor.Support"));
        if (!exportContracts && !string.IsNullOrWhiteSpace(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
            telemetry.UseAzureMonitor(monitor =>
            {
                monitor.Credential = CreateManagedIdentityCredential(builder.Configuration["AZURE_CLIENT_ID"]);
                monitor.ConnectionString = builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"];
                monitor.SamplingRatio = 0.1f;
            });

        var app = builder.Build();
        if (options.PathBase.Length > 0)
            app.UsePathBase(options.PathBase);
        app.UseExceptionHandler();
        app.Use(async (context, next) =>
        {
            var bodyLimit = context.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpMaxRequestBodySizeFeature>();
            if (bodyLimit is { IsReadOnly: false })
                bodyLimit.MaxRequestBodySize = 16384;
            if (context.Request.ContentLength > 16384)
                throw new HarborException(413, "request_too_large", "The request exceeded the small application body limit.");
            context.Response.Headers["X-Harbor-Trace-Id"] = Activity.Current?.TraceId.ToString() ?? context.TraceIdentifier;
            context.Response.Headers.XContentTypeOptions = "nosniff";
            context.Response.Headers["Referrer-Policy"] = "no-referrer";
            if (context.Request.Path.StartsWithSegments("/v1") || context.Request.Path.StartsWithSegments("/voice"))
                context.Response.Headers.CacheControl = "no-store";
            await next(context);
        });
        app.UseRouting();
        app.UseStatusCodePages(async status =>
        {
            if (!status.HttpContext.Response.HasStarted)
                await Results.Problem(statusCode: status.HttpContext.Response.StatusCode,
                    title: "request_failed", type: "urn:harbor:problem:request_failed")
                    .ExecuteAsync(status.HttpContext);
        });
        app.UseAuthentication();
        app.UseAuthorization();
        var websocketOptions = new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(15) };
        foreach (var origin in options.Voice.AllowedOrigins)
            websocketOptions.AllowedOrigins.Add(origin);
        app.UseWebSockets(websocketOptions);
        if (app.Environment.IsDevelopment())
            app.MapOpenApi("/openapi/{documentName}.json");

        app.MapGet("/health/live", () => TypedResults.Ok(new { status = "live" }))
            .WithName("GetLiveness").WithTags("Health");
        app.MapGet("/health/ready", () => options.Entra.IsConfigured && options.Storage.IsConfigured &&
            options.Search.IsConfigured && options.Ai.IsConfigured
                ? Results.Ok(new { status = "ready" }) : Results.StatusCode(503))
            .WithName("GetReadiness").WithTags("Health").Produces(200).Produces(503);
        app.MapGet("/v1/config", () => TypedResults.Ok(new RuntimeConfig("Harbor IT Services", true,
            new RuntimeAuthConfig(options.Entra.IsConfigured, options.Entra.IsConfigured ? options.Entra.Authority : null,
                options.Entra.IsConfigured ? options.Entra.ClientId : null, options.Entra.IsConfigured ? options.Entra.Scope : null, "./"),
            new RuntimeCapabilities(options.Storage.IsConfigured, options.Search.IsConfigured, options.Ai.IsConfigured,
                options.Voice.IsConfigured, "real-providers"), options.Limits.TextMaxChars, options.Limits.VoiceSessionSeconds)))
            .WithName("GetRuntimeConfig").WithTags("Configuration").Produces<RuntimeConfig>();

        var customerApi = app.MapGroup("/v1").RequireAuthorization(CustomerIdentity.CustomerScheme);
        customerApi.MapGet("/customer", (HttpContext context) =>
        {
            var customer = CustomerIdentity.GetCustomer(context.User, options);
            return TypedResults.Ok(new CustomerInfo(customer.CompanyId, customer.AuthorizationExpiresAt));
        }).WithName("GetCustomer").WithTags("Customer").Produces<CustomerInfo>();
        customerApi.MapGet("/company", (Catalog catalog) => TypedResults.Ok(catalog.Company))
            .WithName("GetCompany").WithTags("Company").Produces<CompanyInfo>();
        customerApi.MapGet("/services", (Catalog catalog) => TypedResults.Ok(catalog.Services))
            .WithName("ListServices").WithTags("Company").Produces<IReadOnlyList<ServiceInfo>>();
        customerApi.MapGet("/status/{serviceId}", (string serviceId, Catalog catalog) => TypedResults.Ok(catalog.GetStatus(serviceId)))
            .WithName("GetSyntheticServiceStatus").WithTags("Status").Produces<SyntheticStatus>();
        customerApi.MapGet("/knowledge/search", async (string serviceId, string q, HttpContext context,
            KnowledgeService knowledge, CancellationToken cancellationToken) =>
                TypedResults.Ok(await knowledge.SearchAsync(CustomerIdentity.GetCustomer(context.User, options), serviceId, q, cancellationToken)))
            .WithName("SearchCompanyKnowledge").WithTags("Knowledge").Produces<KnowledgeResult>();
        customerApi.MapGet("/cases", async (HttpContext context, CaseService cases, CancellationToken cancellationToken) =>
            TypedResults.Ok(await cases.ListAsync(CustomerIdentity.GetCustomer(context.User, options), cancellationToken)))
            .WithName("ListMyCases").WithTags("Cases").Produces<IReadOnlyList<SupportCase>>();
        customerApi.MapGet("/cases/{id}", async (string id, HttpContext context, CaseService cases, CancellationToken cancellationToken) =>
            TypedResults.Ok(await cases.GetAsync(CustomerIdentity.GetCustomer(context.User, options), id, cancellationToken)))
            .WithName("GetMyCase").WithTags("Cases").Produces<SupportCase>();
        customerApi.MapGet("/case-proposals/{id}", async (string id, HttpContext context, CaseService cases, CancellationToken cancellationToken) =>
            TypedResults.Ok(await cases.GetProposalAsync(CustomerIdentity.GetCustomer(context.User, options), id, cancellationToken)))
            .WithName("GetMyCaseProposal").WithTags("Cases").Produces<CaseProposal>();
        customerApi.MapPost("/case-proposals", async (PrepareCaseRequest request, HttpContext context, CaseService cases,
            CancellationToken cancellationToken) =>
        {
            var proposal = await cases.PrepareAsync(CustomerIdentity.GetCustomer(context.User, options), request, cancellationToken);
            return TypedResults.Created($"{options.PathBase}/v1/case-proposals/{proposal.Id}", proposal);
        }).WithName("PrepareCase").WithTags("Cases").Produces<CaseProposal>(201);
        customerApi.MapPost("/case-proposals/{id}/confirmation", async (string id, ConfirmationRequest request,
            HttpContext context, CaseService cases, CancellationToken cancellationToken) =>
            TypedResults.Ok(await cases.ConfirmAsync(CustomerIdentity.GetCustomer(context.User, options), id, request, cancellationToken)))
            .WithName("ConfirmCaseProposal").WithTags("Human confirmation").Produces<ConfirmationGrant>()
            .WithDescription("Separate deliberate human action only. Never expose this operation as a model, voice, or MCP tool.");
        customerApi.MapPost("/case-proposals/{id}/commit", async (string id, CommitCaseRequest request,
            [Microsoft.AspNetCore.Mvc.FromHeader(Name = "Idempotency-Key")] string idempotencyKey,
            HttpContext context, CaseService cases, CancellationToken cancellationToken) =>
        {
            var result = await cases.CommitAsync(CustomerIdentity.GetCustomer(context.User, options), id,
                idempotencyKey, request, cancellationToken);
            return result.Replayed ? Results.Ok(result) : Results.Created($"{options.PathBase}/v1/cases/{result.Case.Id}", result);
        }).WithName("CommitConfirmedCase").WithTags("Cases").Produces<CommitCaseResult>(201).Produces<CommitCaseResult>()
            .WithDescription("Requires exact proposalHash, a separate human confirmation grant, and a GUID Idempotency-Key header. Exact retries return the original case.");
        customerApi.MapPost("/chat/messages", async (ChatMessageRequest request, HttpContext context,
            AssistantService assistant, CancellationToken cancellationToken) =>
            TypedResults.Ok(await assistant.AnswerAsync(CustomerIdentity.GetCustomer(context.User, options), request, cancellationToken)))
            .WithName("SendChatMessage").WithTags("Assistant").Produces<ChatAnswer>();
        customerApi.MapPost("/voice/sessions", async (VoiceSessionRequest request, HttpContext context,
            VoiceSessionService sessions, CancellationToken cancellationToken) =>
            TypedResults.Ok(await sessions.CreateAsync(CustomerIdentity.GetCustomer(context.User, options), request, cancellationToken)))
            .WithName("CreateVoiceSession").WithTags("Voice").Produces<VoiceSessionTicket>()
            .WithDescription("Consent required. Reserves durable bounded usage; issues a 30-second single-use opaque subprotocol ticket, not an upstream credential.");
        customerApi.MapDelete("/voice/sessions/{id}", (string id, HttpContext context, VoiceLeaseRegistry leases) =>
        {
            CaseService.RequireId(id);
            leases.Revoke(CustomerIdentity.GetCustomer(context.User, options), id);
            return TypedResults.NoContent();
        }).WithName("RevokeMyVoiceSession").WithTags("Voice").Produces(204);

        app.MapGet("/voice/socket", async (string sessionId, HttpContext context, VoiceLeaseRegistry leases,
            VoiceLiveRelay relay, CancellationToken cancellationToken) =>
        {
            CaseService.RequireId(sessionId);
            if (context.Request.Query.Count != 1 || context.Request.Query["sessionId"].Count != 1)
                throw new HarborException(400, "voice_query_invalid", "Only the non-secret sessionId query parameter is accepted.");
            if (!context.WebSockets.IsWebSocketRequest)
                throw new HarborException(400, "websocket_required", "This route requires a WebSocket upgrade with the fixed protocol and ticket.");
            var lease = leases.Consume(sessionId, context.WebSockets.WebSocketRequestedProtocols.ToArray(),
                context.Request.Headers.Origin.ToString());
            try { await relay.RunAsync(context, lease, cancellationToken); }
            finally
            {
                leases.Release(lease.Id);
                lease.Dispose();
            }
        }).RequireAuthorization(CustomerIdentity.GatewayScheme).WithName("ConnectVoiceRelay").WithTags("Voice")
            .Produces(101).WithDescription("Private WSS /voice/socket?sessionId=<opaque-id>; fixed APIM handshake /support/voice?sessionId=<opaque-id>. Backend gateway JWT plus approved Origin and Sec-WebSocket-Protocol: harbor.voice.v1, harbor.ticket.<opaque-ticket>. Only the non-secret sessionId is permitted in the URL.");
        app.MapMethods("/v1/{**unmatched}", ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"],
            () => Results.Problem(statusCode: 404, title: "endpoint_not_found", type: "urn:harbor:problem:endpoint_not_found"))
            .ExcludeFromDescription();
        app.UseDefaultFiles();
        app.UseStaticFiles();
        app.MapFallbackToFile("index.html");
        if (exportContracts)
            return await ContractExporter.ExportAsync(app, args[1], CancellationToken.None);
        await app.RunAsync();
        return 0;
    }

    public static ManagedIdentityCredential CreateManagedIdentityCredential(string? clientId)
    {
        if (string.IsNullOrEmpty(clientId))
            return new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);
        if (!Guid.TryParse(clientId, out _))
            throw new InvalidOperationException("AZURE_CLIENT_ID must identify the approved user-assigned managed identity.");
        return new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(clientId));
    }
}
