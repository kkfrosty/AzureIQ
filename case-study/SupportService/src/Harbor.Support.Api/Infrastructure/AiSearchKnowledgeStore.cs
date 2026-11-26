using Azure;
using Azure.Core;
using Azure.Search.Documents;
using Azure.Search.Documents.Models;
using Harbor.Support.Api.Features;

namespace Harbor.Support.Api.Infrastructure;

public sealed class AiSearchKnowledgeStore(HarborOptions options, TokenCredential credential) : IKnowledgeStore
{
    public bool IsConfigured => options.Search.IsConfigured;

    public async Task<IReadOnlyList<KnowledgeDocument>> SearchAsync(
        string serviceId, string query, CancellationToken cancellationToken)
    {
        if (!IsConfigured)
            throw new HarborException(503, "search_not_configured", "The real company knowledge provider is not configured.");
        var settings = new SearchClientOptions
        {
            Retry = { MaxRetries = 0, NetworkTimeout = TimeSpan.FromSeconds(options.Limits.ProviderTimeoutSeconds) }
        };
        var client = new SearchClient(new Uri(options.Search.Endpoint), options.Search.IndexName, credential, settings);
        var search = new Azure.Search.Documents.SearchOptions
        {
            QueryType = SearchQueryType.Simple,
            SearchMode = SearchMode.Any,
            Size = 3,
            IncludeTotalCount = false,
            Filter = SearchFilter.Create(
                $"companyId eq {HarborOptions.CompanyId} and (serviceId eq {serviceId} or serviceId eq {"support-portal"})")
        };
        search.Select.Add("docId");
        search.Select.Add("companyId");
        search.Select.Add("serviceId");
        search.Select.Add("title");
        search.Select.Add("content");
        search.Select.Add("sourceRef");
        search.Select.Add("docVersion");
        search.Select.Add("contentHash");
        search.Select.Add("updatedAt");
        search.SearchFields.Add("title");
        search.SearchFields.Add("content");
        try
        {
            var response = await client.SearchAsync<SearchDocument>(query, search, cancellationToken);
            var documents = new List<KnowledgeDocument>(3);
            await foreach (var match in response.Value.GetResultsAsync().WithCancellation(cancellationToken))
            {
                var row = match.Document;
                documents.Add(new KnowledgeDocument(String(row, "docId"), String(row, "companyId"), String(row, "serviceId"),
                    String(row, "title"), String(row, "content"), String(row, "sourceRef"),
                    String(row, "docVersion"), String(row, "contentHash"), row["updatedAt"] switch
                    {
                        DateTimeOffset offset => offset,
                        string value when DateTimeOffset.TryParse(value, System.Globalization.CultureInfo.InvariantCulture,
                            System.Globalization.DateTimeStyles.None, out var offset) => offset,
                        _ => throw new HarborException(502, "invalid_grounding", "The knowledge source timestamp is invalid.")
                    }));
                if (documents.Count == 3)
                    break;
            }
            return documents;
        }
        catch (RequestFailedException)
        {
            throw new HarborException(503, "search_unavailable", "Company search is unavailable; no fixture answer was substituted.");
        }
        catch (Azure.Identity.AuthenticationFailedException)
        {
            throw new HarborException(503, "search_identity_unavailable", "The search managed identity could not authenticate.");
        }
    }

    private static string String(SearchDocument row, string name) =>
        row.TryGetValue(name, out var value) && value is string text ? text :
        throw new HarborException(502, "invalid_grounding", "The knowledge provider returned an invalid source shape.");
}
