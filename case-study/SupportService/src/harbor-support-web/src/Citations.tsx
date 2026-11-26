import type { Citation } from './contracts';

export function Citations({ citations }: { citations: Citation[] }) {
  if (citations.length === 0) return <p className="small muted">No company source was cited for this response.</p>;
  return <details className="citations" open>
    <summary>Company sources ({citations.length})</summary>
    <ul>{citations.map((source, index) => <li key={`${source.docId}-${index}`}>
      <strong>{source.title}</strong>
      <p className="small">{source.sourceRef} · Version {source.docVersion} · {new Date(source.updatedAt).toLocaleDateString()}</p>
      <details><summary>Source integrity reference</summary><p className="mono small">{source.docId}<br />{source.contentHash}</p></details>
    </li>)}</ul>
  </details>;
}
