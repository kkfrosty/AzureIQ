using System.Text.Json;
using System.Text.Json.Serialization;

namespace Harbor.Support.Api.Features;

public sealed record ToolDefinition(string Name, string Description, JsonElement Parameters);
public sealed record ToolResult(JsonElement Output, CaseProposal? Proposal = null, IReadOnlyList<Citation>? Citations = null);
public sealed record ServiceToolRequest(string ServiceId);
public sealed record SearchToolRequest(string ServiceId, string Query);
public sealed record CaseToolRequest(string Id);

public sealed class SupportTools(Catalog catalog, KnowledgeService knowledge, CaseService cases)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        AllowDuplicateProperties = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public static IReadOnlyList<ToolDefinition> Definitions { get; } =
    [
        Define("company_info", "Read the fictional Harbor company scope and privacy notice.", """{"type":"object","properties":{},"additionalProperties":false}"""),
        Define("service_catalog", "Read only the approved Harbor services.", """{"type":"object","properties":{},"additionalProperties":false}"""),
        Define("search_knowledge", "Search approved Harbor company evidence; returns at most three versioned citations.",
            """{"type":"object","properties":{"serviceId":{"type":"string","enum":["managed-endpoints","microsoft-365","office-network","support-portal"]},"query":{"type":"string","minLength":1,"maxLength":2000}},"required":["serviceId","query"],"additionalProperties":false}"""),
        Define("service_status", "Read explicitly synthetic service status, never real telemetry.",
            """{"type":"object","properties":{"serviceId":{"type":"string","enum":["managed-endpoints","microsoft-365","office-network","support-portal"]}},"required":["serviceId"],"additionalProperties":false}"""),
        Define("list_my_cases", "List only the authenticated caller's cases.", """{"type":"object","properties":{},"additionalProperties":false}"""),
        Define("get_my_case", "Read a caller-owned case by opaque identifier.",
            """{"type":"object","properties":{"id":{"type":"string","pattern":"^[a-f0-9]{32}$"}},"required":["id"],"additionalProperties":false}"""),
        Define("prepare_case", "Prepare an immutable expiring proposal ONLY. It cannot confirm or create a case.",
            """{"type":"object","properties":{"serviceId":{"type":"string","enum":["managed-endpoints","microsoft-365","office-network","support-portal"]},"subject":{"type":"string","minLength":1,"maxLength":120},"summary":{"type":"string","minLength":1,"maxLength":2000},"impact":{"type":"string","enum":["low","medium","high"]}},"required":["serviceId","subject","summary","impact"],"additionalProperties":false}""")
    ];

    private static ToolDefinition Define(string name, string description, string schema) =>
        new(name, description, JsonSerializer.Deserialize<JsonElement>(schema));

    public async Task<ToolResult> ExecuteAsync(
        CustomerContext customer, string name, JsonElement arguments, CancellationToken cancellationToken)
    {
        Infrastructure.TableCaseStore.RequireCompany(customer);
        if (arguments.ValueKind != JsonValueKind.Object)
            throw new HarborException(400, "invalid_tool_arguments", "Tool arguments must be a typed object.");
        return name switch
        {
            "company_info" => Empty(arguments, catalog.Company),
            "service_catalog" => Empty(arguments, catalog.Services),
            "search_knowledge" => await SearchAsync(customer, Read<SearchToolRequest>(arguments), cancellationToken),
            "service_status" => Result(catalog.GetStatus(Read<ServiceToolRequest>(arguments).ServiceId)),
            "list_my_cases" => await ListAsync(customer, arguments, cancellationToken),
            "get_my_case" => Result(await cases.GetAsync(customer, Read<CaseToolRequest>(arguments).Id, cancellationToken)),
            "prepare_case" => await PrepareAsync(customer, Read<PrepareCaseRequest>(arguments), cancellationToken),
            _ => throw new HarborException(403, "tool_denied", "That tool is not in Harbor's fixed assistant tool allowlist.")
        };
    }

    private static T Read<T>(JsonElement arguments)
    {
        try
        {
            return arguments.Deserialize<T>(Json) ??
                throw new HarborException(400, "invalid_tool_arguments", "The typed tool arguments are invalid.");
        }
        catch (JsonException)
        {
            throw new HarborException(400, "invalid_tool_arguments", "The tool argument shape is invalid.");
        }
    }

    private static ToolResult Result<T>(T value) => new(JsonSerializer.SerializeToElement(value, Json));

    private static ToolResult Empty<T>(JsonElement arguments, T value)
    {
        if (arguments.EnumerateObject().Any())
            throw new HarborException(400, "invalid_tool_arguments", "This read tool accepts no parameters.");
        return Result(value);
    }

    private async Task<ToolResult> SearchAsync(CustomerContext customer, SearchToolRequest request, CancellationToken cancellationToken)
    {
        var result = await knowledge.SearchAsync(customer, request.ServiceId, request.Query, cancellationToken);
        return new ToolResult(JsonSerializer.SerializeToElement(result, Json), Citations: result.Citations);
    }

    private async Task<ToolResult> ListAsync(CustomerContext customer, JsonElement arguments, CancellationToken cancellationToken)
    {
        if (arguments.EnumerateObject().Any())
            throw new HarborException(400, "invalid_tool_arguments", "This read tool accepts no parameters.");
        return Result(await cases.ListAsync(customer, cancellationToken));
    }

    private async Task<ToolResult> PrepareAsync(CustomerContext customer, PrepareCaseRequest request, CancellationToken cancellationToken)
    {
        var proposal = await cases.PrepareAsync(customer, request, cancellationToken);
        return new ToolResult(JsonSerializer.SerializeToElement(new { proposal, caseCreated = false, humanConfirmationRequired = true }, Json), proposal);
    }
}
