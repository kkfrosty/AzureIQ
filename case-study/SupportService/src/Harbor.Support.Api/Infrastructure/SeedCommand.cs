using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Data.Tables;
using Azure.Identity;
using Azure.Search.Documents;
using Azure.Search.Documents.Indexes;
using Azure.Search.Documents.Indexes.Models;
using Azure.Search.Documents.Models;
using Harbor.Support.Api.Features;

namespace Harbor.Support.Api.Infrastructure;

public static class SeedCommand
{
    public static async Task<int> RunAsync(string[] arguments, CancellationToken cancellationToken)
    {
        var configuration = new ConfigurationBuilder().SetBasePath(AppContext.BaseDirectory)
            .AddJsonFile("appsettings.json").AddEnvironmentVariables().Build();
        var options = configuration.GetSection("Harbor").Get<HarborOptions>() ?? new HarborOptions();
        options.Validate();
        var catalog = new Catalog(Path.Combine(AppContext.BaseDirectory, "data"));
        if (arguments.Length != 1 || arguments[0] is not ("--dry-run" or "--execute-approved-initialization"))
        {
            Console.Error.WriteLine("Use seed --dry-run, or seed --execute-approved-initialization only after the separate exact initialization approval.");
            return 2;
        }
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            command = "harbor-initialize-v1",
            companyId = HarborOptions.CompanyId,
            indexName = options.Search.IndexName,
            tableNames = new[] { options.Storage.CasesTableName, options.Storage.UsageTableName },
            documents = catalog.ApprovedDocuments.Select(document => new { document.DocId, document.DocVersion, document.ContentHash }),
            deletes = false,
            caseFixtureUpload = false,
            providerCalls = arguments[0] != "--dry-run"
        }, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
        if (arguments[0] == "--dry-run")
            return 0;
        if (!options.Search.IsConfigured || !options.Storage.IsConfigured)
        {
            Console.Error.WriteLine("Approved Search and Table runtime bindings are required. No provider call was made.");
            return 2;
        }
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
        TokenCredential credential = Program.CreateManagedIdentityCredential(configuration["AZURE_CLIENT_ID"]);
        var settings = new SearchClientOptions { Retry = { MaxRetries = 0, NetworkTimeout = TimeSpan.FromSeconds(20) } };
        var indexSettings = new SearchClientOptions { Retry = { MaxRetries = 0, NetworkTimeout = TimeSpan.FromSeconds(20) } };
        var indexClient = new SearchIndexClient(new Uri(options.Search.Endpoint), credential, indexSettings);
        var expected = Index(options.Search.IndexName);
        try
        {
            SearchIndex? existing;
            try { existing = (await indexClient.GetIndexAsync(options.Search.IndexName, linked.Token)).Value; }
            catch (RequestFailedException failure) when (failure.Status == 404) { existing = null; }
            if (existing is null)
                await indexClient.CreateIndexAsync(expected, linked.Token);
            else if (!Matches(existing, expected))
            {
                Console.Error.WriteLine("Existing index schema differs from the bounded Harbor schema. Initialization stopped without replacing or deleting it.");
                return 3;
            }
            var search = new SearchClient(new Uri(options.Search.Endpoint), options.Search.IndexName, credential, settings);
            var documents = catalog.ApprovedDocuments.Select(Document).ToArray();
            var result = await search.UploadDocumentsAsync(documents, cancellationToken: linked.Token);
            if (result.Value.Results.Count != documents.Length || result.Value.Results.Any(item => !item.Succeeded))
            {
                Console.Error.WriteLine("At least one approved document upload was not acknowledged. No success is claimed.");
                return 3;
            }
            var tableOptions = new TableClientOptions { Retry = { MaxRetries = 0, NetworkTimeout = TimeSpan.FromSeconds(20) } };
            foreach (var name in new[] { options.Storage.CasesTableName, options.Storage.UsageTableName })
                await new TableClient(new Uri(options.Storage.ServiceUri), name, credential, tableOptions).CreateIfNotExistsAsync(linked.Token);
            Console.WriteLine("Approved corpus upload and the two table-create operations were acknowledged. No cases were seeded; no rows or indexes were deleted.");
            return 0;
        }
        catch (RequestFailedException failure)
        {
            Console.Error.WriteLine($"Initialization failed with provider status {failure.Status}. Partial initialization is possible; reconcile before retry.");
            return 3;
        }
        catch (AuthenticationFailedException)
        {
            Console.Error.WriteLine("The separate seed-job managed identity could not authenticate. No credential fallback is used.");
            return 3;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            Console.Error.WriteLine("The bounded initialization timed out. Partial initialization is possible; reconcile before retry.");
            return 3;
        }
    }

    public static SearchIndex Index(string name) => new(name)
    {
        Fields =
        [
            new SimpleField("docId", SearchFieldDataType.String) { IsKey = true, IsFilterable = true },
            new SimpleField("companyId", SearchFieldDataType.String) { IsFilterable = true },
            new SimpleField("serviceId", SearchFieldDataType.String) { IsFilterable = true },
            new SearchableField("title") { AnalyzerName = LexicalAnalyzerName.EnMicrosoft },
            new SearchableField("content") { AnalyzerName = LexicalAnalyzerName.EnMicrosoft },
            new SimpleField("sourceRef", SearchFieldDataType.String),
            new SimpleField("docVersion", SearchFieldDataType.String),
            new SimpleField("contentHash", SearchFieldDataType.String),
            new SimpleField("updatedAt", SearchFieldDataType.DateTimeOffset)
        ]
    };

    public static bool Matches(SearchIndex actual, SearchIndex expected) =>
        actual.Fields.Count == expected.Fields.Count && expected.Fields.All(field =>
            actual.Fields.Any(candidate => candidate.Name == field.Name && candidate.Type == field.Type &&
                candidate.IsKey.GetValueOrDefault() == field.IsKey.GetValueOrDefault() &&
                candidate.IsFilterable.GetValueOrDefault() == field.IsFilterable.GetValueOrDefault() &&
                candidate.IsSearchable.GetValueOrDefault() == field.IsSearchable.GetValueOrDefault() &&
                candidate.AnalyzerName == field.AnalyzerName)) &&
        actual.VectorSearch is null && actual.SemanticSearch is null;

    public static SearchDocument Document(KnowledgeDocument document) => new()
    {
        ["docId"] = document.DocId,
        ["companyId"] = document.CompanyId,
        ["serviceId"] = document.ServiceId,
        ["title"] = document.Title,
        ["content"] = document.Content,
        ["sourceRef"] = document.SourceRef,
        ["docVersion"] = document.DocVersion,
        ["contentHash"] = document.ContentHash,
        ["updatedAt"] = document.UpdatedAt
    };
}
