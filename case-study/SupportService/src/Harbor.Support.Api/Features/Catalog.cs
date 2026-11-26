using System.Text.Json;
using Harbor.Support.Api.Features;

namespace Harbor.Support.Api.Features;

public sealed class Catalog
{
    public CompanyInfo Company { get; }
    public IReadOnlyList<ServiceInfo> Services { get; }
    public IReadOnlyList<SyntheticStatus> Statuses { get; }
    public IReadOnlyList<KnowledgeDocument> ApprovedDocuments { get; }

    public Catalog(string dataDirectory)
    {
        var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        Company = Read<CompanyInfo>(Path.Combine(dataDirectory, "company.json"), json);
        Services = Read<ServiceInfo[]>(Path.Combine(dataDirectory, "services.json"), json);
        Statuses = Read<SyntheticStatus[]>(Path.Combine(dataDirectory, "service-status.synthetic.json"), json);
        ApprovedDocuments = Read<KnowledgeDocument[]>(Path.Combine(dataDirectory, "knowledge", "search-documents.json"), json);
        if (Company.CompanyId != HarborOptions.CompanyId || !Company.Synthetic || ApprovedDocuments.Count != 8 ||
            Services.Select(service => service.ServiceId).Distinct().Count() != Services.Count ||
            ApprovedDocuments.Select(document => document.DocId).Distinct().Count() != ApprovedDocuments.Count ||
            Statuses.Any(status => !status.Synthetic || !Services.Any(service => service.ServiceId == status.ServiceId)))
            throw new InvalidOperationException("The approved synthetic Harbor corpus is inconsistent.");
        foreach (var document in ApprovedDocuments)
            ValidateDocument(document);
    }

    private static T Read<T>(string path, JsonSerializerOptions options) =>
        JsonSerializer.Deserialize<T>(File.ReadAllText(path), options) ??
        throw new InvalidOperationException("An approved Harbor data file is invalid.");

    public ServiceInfo RequireService(string? id) => Services.SingleOrDefault(service => service.ServiceId == id) ??
        throw new HarborException(404, "unknown_service", "That service is not in the approved Harbor catalog.");

    public SyntheticStatus GetStatus(string id)
    {
        RequireService(id);
        return Statuses.Single(status => status.ServiceId == id);
    }

    public void ValidateDocument(KnowledgeDocument document)
    {
        if (document.CompanyId != HarborOptions.CompanyId || document.Content.Length is < 1 or > 12000 ||
            !document.DocId.StartsWith("hbr-", StringComparison.Ordinal) ||
            !document.DocId.All(character => char.IsAsciiLetterLower(character) || char.IsAsciiDigit(character) || character == '-') ||
            document.SourceRef != $"knowledge/{document.DocId}.md" ||
            !CustomerIdentity.HashEquals(document.ContentHash, CustomerIdentity.Hash(document.Content)))
            throw new HarborException(502, "invalid_grounding", "The knowledge provider returned unapproved source material.");
        RequireService(document.ServiceId);
        var approved = ApprovedDocuments.SingleOrDefault(candidate => candidate.DocId == document.DocId);
        if (approved is not null && (document.DocVersion != approved.DocVersion ||
            document.Title != approved.Title || document.ServiceId != approved.ServiceId ||
            document.UpdatedAt != approved.UpdatedAt || document.ContentHash != approved.ContentHash))
            throw new HarborException(502, "invalid_grounding", "The knowledge provider returned an unapproved source version.");
        if (approved is null)
            throw new HarborException(502, "invalid_grounding", "The knowledge provider returned an unapproved source.");
    }

    public static Citation Cite(KnowledgeDocument document) =>
        new(document.DocId, document.Title, document.SourceRef, document.DocVersion, document.ContentHash, document.UpdatedAt);
}
