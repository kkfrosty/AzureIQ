using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Harbor.Support.Api.Features;
using Microsoft.AspNetCore.OpenApi;
using Microsoft.OpenApi;

namespace Harbor.Support.Api.Infrastructure;

public static class ContractExporter
{
    public static IReadOnlyDictionary<string, string> ToolOperations { get; } =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["company_info"] = "GetCompany",
            ["service_catalog"] = "ListServices",
            ["service_status"] = "GetSyntheticServiceStatus",
            ["search_knowledge"] = "SearchCompanyKnowledge",
            ["list_my_cases"] = "ListMyCases",
            ["get_my_case"] = "GetMyCase",
            ["prepare_case"] = "PrepareCase"
        };

    public static async Task<int> ExportAsync(
        WebApplication app, string outputDirectory, CancellationToken cancellationToken)
    {
        app.Urls.Clear();
        app.Urls.Add("http://127.0.0.1:0");
        await app.StartAsync(cancellationToken);
        try
        {
            using var scope = app.Services.CreateScope();
            var provider = scope.ServiceProvider.GetRequiredKeyedService<IOpenApiDocumentProvider>("v1");
            var api = await provider.GetOpenApiDocumentAsync(cancellationToken);
            var json = await api.SerializeAsJsonAsync(OpenApiSpecVersion.OpenApi3_0, cancellationToken);
            var document = JsonNode.Parse(json)!.AsObject();
            var operations = document["paths"]!.AsObject().SelectMany(path =>
                path.Value!.AsObject().Where(method => method.Value?["operationId"] is not null)
                    .Select(method => new
                    {
                        Path = path.Key,
                        Method = method.Key.ToUpperInvariant(),
                        Id = method.Value!["operationId"]!.GetValue<string>()
                    })).ToArray();
            var export = SupportTools.Definitions.Select(tool =>
            {
                var operation = operations.Single(candidate => candidate.Id == ToolOperations[tool.Name]);
                return new
                {
                    name = tool.Name,
                    description = tool.Description,
                    operationId = operation.Id,
                    method = operation.Method,
                    path = operation.Path,
                    inputSchema = tool.Parameters,
                    parameterBindings = tool.Name switch
                    {
                        "search_knowledge" => new Dictionary<string, string> { ["serviceId"] = "query.serviceId", ["query"] = "query.q" },
                        "service_status" => new Dictionary<string, string> { ["serviceId"] = "path.serviceId" },
                        "get_my_case" => new Dictionary<string, string> { ["id"] = "path.id" },
                        "prepare_case" => new Dictionary<string, string>
                        {
                            ["serviceId"] = "body.serviceId", ["subject"] = "body.subject",
                            ["summary"] = "body.summary", ["impact"] = "body.impact"
                        },
                        _ => []
                    },
                    annotations = new
                    {
                        readOnlyHint = tool.Name != "prepare_case",
                        destructiveHint = false,
                        openWorldHint = false
                    }
                };
            }).ToArray();
            var directory = Directory.CreateDirectory(outputDirectory);
            var openApiPath = Path.Combine(directory.FullName, "support-v1.openapi.json");
            await File.WriteAllTextAsync(openApiPath, json + Environment.NewLine, cancellationToken);
            var digest = Convert.ToHexStringLower(SHA256.HashData(await File.ReadAllBytesAsync(openApiPath, cancellationToken)));
            var manifest = new
            {
                schemaVersion = "1.0",
                openApi = "support-v1.openapi.json",
                openApiSha256 = digest,
                transport = "APIM executable MCP backed by this OpenAPI; not a second backend MCP server",
                authentication = "Customer JWT to APIM; APIM gateway identity and forwarded caller JWT to private backend",
                excludedOperations = new[] { "ConfirmCaseProposal", "CommitConfirmedCase", "CreateVoiceSession", "RevokeMyVoiceSession", "ConnectVoiceRelay" },
                tools = export
            };
            await File.WriteAllTextAsync(Path.Combine(directory.FullName, "support-mcp-tools.json"),
                JsonSerializer.Serialize(manifest, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }) +
                Environment.NewLine, cancellationToken);
            Console.WriteLine($"Exported OpenAPI 3 and {export.Length} fixed support tools; SHA-256 {digest}.");
            return 0;
        }
        finally
        {
            await app.StopAsync(CancellationToken.None);
            await app.DisposeAsync();
        }
    }
}
