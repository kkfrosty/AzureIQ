using System.Text.RegularExpressions;

namespace Harbor.Support.Api.Features;

public interface IKnowledgeStore
{
    bool IsConfigured { get; }
    Task<IReadOnlyList<KnowledgeDocument>> SearchAsync(string serviceId, string query, CancellationToken cancellationToken);
}

public sealed class KnowledgeService(IKnowledgeStore store, Catalog catalog)
{
    public async Task<KnowledgeResult> SearchAsync(
        CustomerContext customer, string serviceId, string? query, CancellationToken cancellationToken)
    {
        Infrastructure.TableCaseStore.RequireCompany(customer);
        catalog.RequireService(serviceId);
        var normalized = CaseService.Normalize(query, 2000, "query");
        CompanyPolicy.EnsureCompanyQuestion(catalog, serviceId, normalized);
        if (!store.IsConfigured)
            throw new HarborException(503, "search_not_configured", "The real company knowledge provider is not configured.");
        using var span = HarborTelemetry.Source.StartActivity("knowledge.search");
        var documents = await store.SearchAsync(serviceId, CompanyPolicy.LexicalQuery(normalized), cancellationToken);
        if (documents.Count > 3)
            throw new HarborException(502, "invalid_grounding", "The knowledge provider exceeded the approved result cap.");
        foreach (var document in documents)
        {
            catalog.ValidateDocument(document);
            if (document.ServiceId != serviceId && document.ServiceId != "support-portal")
                throw new HarborException(502, "invalid_grounding", "The knowledge provider returned an unrelated service.");
        }
        if (documents.Count == 0)
            throw new HarborException(422, "insufficient_evidence", "No approved company evidence supports that question.");
        return new KnowledgeResult(HarborOptions.CompanyId, documents, documents.Select(Catalog.Cite).ToArray());
    }
}

public static class CompanyPolicy
{
    private static readonly Regex Secret = new(
        @"(?i)(password\s*[:=]|bearer\s+[a-z0-9._-]+|api[-_ ]?key\s*[:=]|connectionstring\s*[:=]|credit card\s*[:=])",
        RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    private static readonly Regex Unsupported = new(
        @"(?i)(ignore (previous|all|your)|system prompt|developer instructions|https?://|run (a |this )?(script|command)|reset my password|change (my )?(mfa|billing)|send (an? )?(email|message)|remote execut|close (my |the )?case|capital of|weather|stock price|write (a |me )?poem)",
        RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    private static readonly Regex Words = new("[a-zA-Z0-9-]+", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    private static readonly HashSet<string> Common = new(StringComparer.OrdinalIgnoreCase)
    {
        "how", "what", "when", "where", "which", "why", "can", "could", "should", "would", "is", "are", "was",
        "the", "a", "an", "and", "or", "to", "of", "for", "my", "our", "i", "we", "you", "it", "with", "do", "does", "in"
    };

    public static bool ContainsSecret(string text) => Secret.IsMatch(text);

    public static void EnsureCompanyQuestion(Catalog catalog, string serviceId, string text)
    {
        var service = catalog.RequireService(serviceId);
        var words = Words.Matches(text).Select(match => match.Value).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (ContainsSecret(text))
            throw new HarborException(400, "sensitive_content", "Do not submit credentials or payment details.");
        if (Unsupported.IsMatch(text) ||
            !words.Overlaps(service.Topics.Concat(["harbor", "support", "service", "services", "case", "cases", "privacy"])))
            throw new HarborException(422, "unsupported_topic", "Harbor only answers approved company service and case-process questions; it cannot perform actions.");
    }

    public static string LexicalQuery(string text)
    {
        var terms = Words.Matches(text).Select(match => match.Value).Where(word => !Common.Contains(word))
            .Take(24).Select(word => word.Length > 40 ? word[..40] : word).ToArray();
        if (terms.Length == 0)
            throw new HarborException(400, "invalid_query", "Use a short company service question.");
        return string.Join(' ', terms);
    }
}
