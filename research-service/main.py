from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse
import httpx
import re
import io
import os
import asyncio
import base64
from difflib import SequenceMatcher
import xml.etree.ElementTree as ET
from urllib.parse import quote, unquote, urlparse
from typing import Any, Optional, List

app = FastAPI(title="Firecrawl Research Proxy")

OPENALEX_BASE = "https://api.openalex.org"
ARXIV_BASE = "https://export.arxiv.org/api"
GITHUB_BASE = "https://api.github.com"
S2_BASE = "https://api.semanticscholar.org/graph/v1"
S2_RECOMMENDATIONS_BASE = "https://api.semanticscholar.org/recommendations/v1"
CROSSREF_BASE = "https://api.crossref.org"
EUROPEPMC_BASE = "https://www.ebi.ac.uk/europepmc/webservices/rest"
MAILTO = os.environ.get("MAILTO", "research@firecrawl.local")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
S2_API_KEY = os.environ.get("S2_API_KEY", "")

TIMEOUT = 300.0

BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

ARXIV_ID_RE = re.compile(
    r"^(?:\d{4}\.\d{4,5}(?:v\d+)?|[a-z][a-z0-9.-]+/\d{7}(?:v\d+)?)$",
    re.I,
)


def normalize_title(value: Optional[str]) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (value or "").lower()).strip()


def parse_paper_reference(value: str) -> dict:
    """Parse a paper reference without guessing an opaque id as a title."""
    raw = unquote((value or "").strip())
    if not raw:
        return {"kind": "title", "value": "", "canonical": ""}

    parsed = urlparse(raw)
    if parsed.scheme in ("http", "https") and parsed.netloc:
        host = parsed.netloc.lower().split(":", 1)[0]
        path = parsed.path.strip("/")
        if host.endswith("arxiv.org"):
            match = re.match(r"(?:abs|pdf)/(.+?)(?:\.pdf)?$", path, re.I)
            if match and ARXIV_ID_RE.match(match.group(1)):
                ident = match.group(1)
                return {"kind": "arxiv", "value": ident, "canonical": f"arxiv:{ident}"}
        if host in ("doi.org", "dx.doi.org") and path:
            return {"kind": "doi", "value": path, "canonical": f"doi:{path}"}
        if host.endswith("europepmc.org"):
            match = re.search(r"(?:article|abstract|med)/([^/]+)", path, re.I)
            if match:
                ident = match.group(1)
                if ident.upper().startswith("PMC"):
                    ident = ident.upper()
                    return {"kind": "pmcid", "value": ident, "canonical": f"pmcid:{ident}"}
                if ident.isdigit():
                    return {"kind": "pmid", "value": ident, "canonical": f"pmid:{ident}"}
        if host.endswith("pubmed.ncbi.nlm.nih.gov") and path.isdigit():
            return {"kind": "pmid", "value": path, "canonical": f"pmid:{path}"}
        if host.endswith("openalex.org") and re.fullmatch(r"W\d+", path, re.I):
            ident = path.upper()
            return {"kind": "openalex", "value": ident, "canonical": f"openalex:{ident}"}

    lower = raw.lower()
    for prefix, kind in (
        ("arxiv:", "arxiv"),
        ("doi:", "doi"),
        ("pmid:", "pmid"),
        ("pmcid:", "pmcid"),
        ("openalex:", "openalex"),
        ("corpusid:", "corpusid"),
    ):
        if lower.startswith(prefix):
            ident = raw[len(prefix):].strip()
            if kind == "pmcid": ident = ident.upper()
            if kind == "openalex": ident = ident.upper()
            return {"kind": kind, "value": ident, "canonical": f"{kind}:{ident}"}

    if re.match(r"^10\.\d{4,9}/\S+$", raw, re.I):
        return {"kind": "doi", "value": raw, "canonical": f"doi:{raw}"}
    if re.fullmatch(r"PMC\d+", raw, re.I):
        ident = raw.upper()
        return {"kind": "pmcid", "value": ident, "canonical": f"pmcid:{ident}"}
    if re.fullmatch(r"\d+", raw):
        return {"kind": "pmid", "value": raw, "canonical": f"pmid:{raw}"}
    if re.fullmatch(r"W\d+", raw, re.I):
        ident = raw.upper()
        return {"kind": "openalex", "value": ident, "canonical": f"openalex:{ident}"}
    if ARXIV_ID_RE.match(raw):
        return {"kind": "arxiv", "value": raw, "canonical": f"arxiv:{raw}"}
    return {"kind": "title", "value": raw, "canonical": raw}

def oa_params(extra=None):
    p = {"mailto": MAILTO}
    if extra:
        p.update(extra)
    return p

def gh_headers():
    h = {
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "Firecrawl-Research-Proxy/1.0",
    }
    if GITHUB_TOKEN:
        h["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    return h

def s2_headers():
    h = {"User-Agent": "Firecrawl-Research-Proxy/1.0"}
    if S2_API_KEY:
        h["x-api-key"] = S2_API_KEY
    return h

def reconstruct_abstract(inverted_index):
    if not inverted_index:
        return None
    word_positions = []
    for word, positions in inverted_index.items():
        for pos in positions:
            word_positions.append((pos, word))
    word_positions.sort()
    return " ".join(word for _, word in word_positions)

def oa_to_result(work: dict, score: Optional[float] = None) -> dict:
    work_id = work.get("id", "")
    oa_id = work_id.rsplit("/", 1)[-1] if work_id else ""

    doi = work.get("doi")
    doi_val = doi.replace("https://doi.org/", "") if doi else None

    ids = {}
    if doi_val:
        ids["doi"] = [doi_val]
    if oa_id:
        ids["openalex"] = [oa_id]

    locations = work.get("locations") or []
    for loc in locations:
        landing = loc.get("landing_url") or ""
        if "arxiv.org" in landing:
            arxiv_match = re.search(r"arxiv\.org/(?:abs|pdf)/([^/?#]+)", landing)
            if arxiv_match:
                ids["arxiv"] = [arxiv_match.group(1).removesuffix(".pdf")]
                break
        pdf = loc.get("pdf_url") or ""
        if "arxiv.org" in pdf:
            arxiv_match = re.search(r"arxiv\.org/(?:pdf|abs)/([^/?#]+)", pdf)
            if arxiv_match:
                ids["arxiv"] = [arxiv_match.group(1).removesuffix(".pdf")]
                break

    raw_ids = work.get("ids") or {}
    if raw_ids.get("openalex"):
        ids["openalex"] = [raw_ids["openalex"].rsplit("/", 1)[-1]]
    if raw_ids.get("doi"):
        ids["doi"] = [raw_ids["doi"].replace("https://doi.org/", "")]
    if raw_ids.get("mag"):
        ids["mag"] = [str(raw_ids["mag"])]
    if raw_ids.get("pmid"):
        ids["pmid"] = [str(raw_ids["pmid"])]
    if raw_ids.get("pmcid"):
        ids["pmcid"] = [raw_ids["pmcid"]]
    if raw_ids.get("arxiv"):
        ids["arxiv"] = [str(raw_ids["arxiv"])]

    primary = None
    for ns in ("arxiv", "doi", "pmcid", "pmid", "openalex"):
        if ids.get(ns):
            primary = f"{ns}:{ids[ns][0]}"
            break

    authors = []
    for a in work.get("authorships") or []:
        author = a.get("author") or {}
        entry = {"name": author.get("display_name", "")}
        insts = a.get("institutions") or []
        if insts and insts[0].get("display_name"):
            entry["affiliation"] = insts[0]["display_name"]
        authors.append(entry)

    concepts = []
    for c in work.get("concepts") or []:
        concepts.append(c.get("display_name", ""))

    pub_date = work.get("publication_date")

    return {
        "paperId": f"openalex:{oa_id}" if oa_id else (primary or work_id),
        "primaryId": primary or (f"openalex:{oa_id}" if oa_id else work_id),
        "title": work.get("title") or "",
        "authors": ", ".join(a["name"] for a in authors if a.get("name")),
        "authorDetails": authors,
        "abstract": reconstruct_abstract(work.get("abstract_inverted_index")) or "",
        "categories": concepts,
        "createdDate": pub_date,
        "updateDate": pub_date,
        "ids": ids,
        "openAlexId": oa_id,
        "score": float(score if score is not None else work.get("relevance_score") or 0),
        "citedByCount": int(work.get("cited_by_count") or 0),
    }

def normalize_paper_id(paper_id: str) -> str:
    return parse_paper_reference(paper_id)["canonical"]

def get_arxiv_id_from_ids(ids: dict) -> Optional[str]:
    arxiv = ids.get("arxiv") or ids.get("ArXiv")
    if arxiv and isinstance(arxiv, list) and arxiv:
        return arxiv[0]
    return None

ARXIV_NS = {"atom": "http://www.w3.org/2005/Atom", "arxiv": "http://arxiv.org/schemas/atom"}

async def arxiv_lookup(arxiv_id: str) -> Optional[dict]:
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(f"{ARXIV_BASE}/query", params={"id_list": arxiv_id, "max_results": 1})
        if resp.status_code != 200:
            return None
        root = ET.fromstring(resp.text)
        entries = root.findall("atom:entry", ARXIV_NS)
        if not entries:
            return None
        entry = entries[0]
        title = entry.find("atom:title", ARXIV_NS)
        summary = entry.find("atom:summary", ARXIV_NS)
        published = entry.find("atom:published", ARXIV_NS)
        updated = entry.find("atom:updated", ARXIV_NS)
        authors = []
        for author in entry.findall("atom:author", ARXIV_NS):
            name = author.find("atom:name", ARXIV_NS)
            if name is not None:
                authors.append({"name": name.text.strip()})
        categories = []
        for cat in entry.findall("atom:category", ARXIV_NS):
            term = cat.get("term")
            if term:
                categories.append(term)
        title_text = re.sub(r"\s+", " ", title.text.strip()) if title is not None else None
        abstract_text = re.sub(r"\s+", " ", summary.text.strip()) if summary is not None else None
        pub_date = published.text[:10] if published is not None else None
        up_date = updated.text[:10] if updated is not None else None
        doi_el = entry.find("arxiv:doi", ARXIV_NS)
        doi_val = doi_el.text.strip() if doi_el is not None else None
        ids = {"arxiv": [arxiv_id]}
        if doi_val:
            ids["doi"] = [doi_val]
        return {
            "paperId": f"arxiv:{arxiv_id}",
            "primaryId": f"arxiv:{arxiv_id}",
            "title": title_text or "",
            "authors": ", ".join(a["name"] for a in authors if a.get("name")),
            "authorDetails": authors,
            "abstract": abstract_text or "",
            "categories": categories,
            "createdDate": pub_date,
            "updateDate": up_date,
            "ids": ids,
            "openAlexId": None,
            "score": 0,
        }
    except Exception as e:
        print(f"arXiv lookup error: {e}")
        return None

async def arxiv_to_openalex_id(arxiv_id: str) -> Optional[str]:
    paper = await arxiv_lookup(arxiv_id)
    if not paper or not paper.get("title"):
        return None
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(
                f"{OPENALEX_BASE}/works",
                params=oa_params({
                    "search": paper["title"],
                    "per_page": 5,
                    "select": "id,title,ids,locations",
                }),
            )
        if resp.status_code != 200:
            return None
        results = resp.json().get("results", [])
        requested = normalize_title(paper["title"])
        for w in results:
            locations = w.get("locations") or []
            for loc in locations:
                for url in (loc.get("landing_page_url") or "", loc.get("pdf_url") or ""):
                    match = re.search(r"arxiv\.org/(?:abs|pdf)/([^/?#]+)", url, re.I)
                    if match and match.group(1).removesuffix(".pdf").lower() == arxiv_id.lower():
                        return w.get("id", "").rsplit("/", 1)[-1]
            raw_ids = w.get("ids") or {}
            for value in (raw_ids.get("arxiv"), raw_ids.get("doi")):
                if value and arxiv_id.lower() in str(value).lower():
                    return w.get("id", "").rsplit("/", 1)[-1]
            if normalize_title(w.get("title")) == requested:
                return w.get("id", "").rsplit("/", 1)[-1]
    except Exception:
        pass
    return None


async def crossref_lookup(doi: str) -> Optional[dict]:
    """Fallback: look up a DOI via Crossref when OpenAlex 404s."""
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(f"{CROSSREF_BASE}/works/{quote(doi, safe='')}")
        if resp.status_code != 200:
            return None
        msg = resp.json().get("message", {})
        title_parts = msg.get("title") or []
        title = title_parts[0] if title_parts else None
        authors = []
        for a in msg.get("author") or []:
            name = f"{a.get('given', '')} {a.get('family', '')}".strip()
            if name:
                authors.append({"name": name})
        abstract = msg.get("abstract")
        if abstract:
            abstract = re.sub(r"<[^>]+>", "", abstract)
        pub_date = None
        for dp in ("published-print", "published-online", "created"):
            parts = msg.get(dp, {}).get("date-parts")
            if parts and parts[0]:
                pub_date = "-".join(str(p) for p in parts[0])
                break
        return {
            "paperId": f"doi:{doi}",
            "primaryId": f"doi:{doi}",
            "title": title or "",
            "authors": ", ".join(a["name"] for a in authors if a.get("name")),
            "authorDetails": authors,
            "abstract": abstract or "",
            "categories": [c for c in msg.get("subject") or []],
            "createdDate": pub_date,
            "updateDate": pub_date,
            "ids": {"doi": [doi]},
            "openAlexId": None,
            "score": 0,
        }
    except Exception as e:
        print(f"Crossref lookup error: {e}")
        return None


def s2_api_id(paper_id: str) -> str:
    """Normalize a paper ID to Semantic Scholar's namespace (ArXiv:, DOI:, PMCID:, PMID:)."""
    reference = parse_paper_reference(paper_id)
    prefixes = {"arxiv": "ArXiv", "pmcid": "PMCID", "pmid": "PMID", "doi": "DOI", "corpusid": "CorpusId"}
    prefix = prefixes.get(reference["kind"])
    return f"{prefix}:{reference['value']}" if prefix else reference["value"]


async def s2_lookup(paper_id: str) -> Optional[dict]:
    """Fallback: look up a paper via Semantic Scholar Graph API."""
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(
                f"{S2_BASE}/paper/{quote(s2_api_id(paper_id), safe=':')}",
                params={"fields": "paperId,title,abstract,authors,year,venue,externalIds,openAccessPdf,citationCount,referenceCount"},
                headers=s2_headers(),
            )
        if resp.status_code != 200:
            return None
        p = resp.json()
        ext = p.get("externalIds") or {}
        ids = {}
        if ext.get("DOI"):
            ids["doi"] = [ext["DOI"]]
        if ext.get("ArXiv"):
            ids["arxiv"] = [ext["ArXiv"]]
        if ext.get("PubMed"):
            ids["pmid"] = [str(ext["PubMed"])]
        if ext.get("PubMedCentral"):
            ids["pmcid"] = [ext["PubMedCentral"]]
        ids["corpusid"] = [str(p.get("paperId", ""))]
        authors = [{"name": a.get("name", "")} for a in p.get("authors") or []]
        primary = None
        for ns in ("arxiv", "doi", "pmcid", "pmid"):
            if ids.get(ns):
                primary = f"{ns.lower()}:{ids[ns][0]}"
                break
        if not primary:
            primary = f"corpusid:{p.get('paperId', '')}"
        return {
            "paperId": f"corpusid:{p.get('paperId', '')}",
            "primaryId": primary,
            "title": p.get("title") or "",
            "authors": ", ".join(a["name"] for a in authors if a.get("name")),
            "authorDetails": authors,
            "abstract": p.get("abstract") or "",
            "categories": [p.get("venue")] if p.get("venue") else [],
            "createdDate": str(p.get("year", "")),
            "updateDate": str(p.get("year", "")),
            "ids": ids,
            "openAlexId": None,
            "score": float(p.get("citationCount") or 0),
        }
    except Exception as e:
        print(f"S2 lookup error: {e}")
        return None


async def europepmc_metadata_lookup(identifier: str, id_type: str = "pmcid") -> Optional[dict]:
    """Last-resort fallback: resolve a PMCID/PMID to core metadata via Europe PMC."""
    field = "PMCID" if id_type == "pmcid" else "EXT_ID"
    ident = identifier.strip()
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(
                f"{EUROPEPMC_BASE}/search",
                params={"query": f"{field}:{ident}", "format": "json", "resultType": "core"},
            )
        if resp.status_code != 200:
            return None
        hits = (resp.json().get("resultList") or {}).get("result") or []
        if not hits:
            return None
        p = hits[0]
        ids = {}
        if p.get("doi"):
            ids["doi"] = [p["doi"]]
        if p.get("pmcid"):
            ids["pmcid"] = [p["pmcid"]]
        if p.get("pmid"):
            ids["pmid"] = [str(p["pmid"])]
        authors = [
            {"name": name.strip()}
            for name in (p.get("authorString") or "").split(",")
            if name.strip()
        ]
        abstract = p.get("abstractText")
        if abstract:
            abstract = re.sub(r"<[^>]+>", " ", abstract)
            abstract = re.sub(r"\s+", " ", abstract).strip()
        primary = None
        for ns in ("doi", "arxiv", "pmcid", "pmid"):
            if ids.get(ns):
                primary = f"{ns.lower()}:{ids[ns][0]}"
                break
        return {
            "paperId": primary or f"{id_type}:{ident}",
            "primaryId": primary or f"{id_type}:{ident}",
            "title": p.get("title") or "",
            "authors": ", ".join(a["name"] for a in authors if a.get("name")),
            "authorDetails": authors,
            "abstract": abstract or "",
            "categories": [p["journalTitle"]] if p.get("journalTitle") else [],
            "createdDate": str(p.get("firstPublicationDate") or p.get("pubYear") or ""),
            "updateDate": str(p.get("firstPublicationDate") or ""),
            "ids": ids,
            "openAlexId": None,
            "score": 0,
        }
    except Exception as e:
        print(f"Europe PMC metadata lookup error: {e}")
        return None


async def s2_recommendations(paper_id: str, limit: int = 20) -> list:
    """Get similar papers from Semantic Scholar recommendations API."""
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(
                f"{S2_RECOMMENDATIONS_BASE}/papers/forpaper/{quote(s2_api_id(paper_id), safe=':')}",
                params={"fields": "paperId,title,abstract,authors,year,venue,externalIds,citationCount", "limit": limit},
                headers=s2_headers(),
            )
        if resp.status_code != 200:
            return []
        data = resp.json()
        results = []
        for p in data.get("recommendedPapers") or []:
            ext = p.get("externalIds") or {}
            ids = {}
            if ext.get("DOI"):
                ids["doi"] = [ext["DOI"]]
            if ext.get("ArXiv"):
                ids["arxiv"] = [ext["ArXiv"]]
            if ext.get("PubMed"):
                ids["pmid"] = [str(ext["PubMed"])]
            authors = [{"name": a.get("name", "")} for a in p.get("authors") or []]
            primary = None
            for ns in ("arxiv", "doi", "pmid"):
                if ids.get(ns):
                    primary = f"{ns.lower()}:{ids[ns][0]}"
                    break
            if not primary:
                primary = f"corpusid:{p.get('paperId', '')}"
            results.append({
                "paperId": f"corpusid:{p.get('paperId', '')}",
                "primaryId": primary,
                "title": p.get("title") or "",
                "authors": ", ".join(a["name"] for a in authors if a.get("name")),
                "authorDetails": authors,
                "abstract": p.get("abstract") or "",
                "categories": [p.get("venue")] if p.get("venue") else [],
                "createdDate": str(p.get("year", "")),
                "updateDate": str(p.get("year", "")),
                "ids": ids,
                "openAlexId": None,
                "score": float(p.get("citationCount") or 0),
            })
        return results
    except Exception as e:
        print(f"S2 recommendations error: {e}")
        return []


async def resolve_oa_id(paper_id: str) -> Optional[str]:
    """Resolve any paper ID format to an OpenAlex work ID."""
    reference = parse_paper_reference(paper_id)
    if reference["kind"] == "arxiv":
        return await arxiv_to_openalex_id(reference["value"])
    if reference["kind"] == "corpusid":
        s2_result = await s2_lookup(reference["canonical"])
        if s2_result:
            for namespace in ("doi", "pmid", "pmcid", "arxiv"):
                values = s2_result.get("ids", {}).get(namespace) or []
                if values:
                    return await resolve_oa_id(f"{namespace}:{values[0]}")
        return None

    oa_lookup = reference["value"]
    if reference["kind"] in ("doi", "pmid", "pmcid"):
        oa_lookup = f"{reference['kind']}:{reference['value']}"
    elif reference["kind"] == "openalex":
        oa_lookup = reference["value"]

    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(
                f"{OPENALEX_BASE}/works/{quote(oa_lookup, safe=':')}",
                params=oa_params({"select": "id"}),
            )
        if resp.status_code == 200:
            return resp.json().get("id", "").rsplit("/", 1)[-1]
    except Exception:
        pass

    if reference["kind"] == "title":
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT) as client:
                resp = await client.get(
                    f"{OPENALEX_BASE}/works",
                    params=oa_params({
                        "search": reference["value"],
                        "per_page": 5,
                        "select": "id,title",
                    }),
                )
            if resp.status_code == 200:
                hits = resp.json().get("results", [])
                target = normalize_title(reference["value"])
                for hit in hits:
                    candidate = normalize_title(hit.get("title"))
                    if candidate == target or SequenceMatcher(None, candidate, target).ratio() >= 0.96:
                        return hit.get("id", "").rsplit("/", 1)[-1]
        except Exception:
            pass
    return None


@app.get("/v2/research/papers")
async def search_papers(
    request: Request,
    query: str = Query(..., min_length=1),
    k: Optional[int] = Query(None, ge=1, le=10000),
    authors: Optional[List[str]] = Query(None),
    categories: Optional[List[str]] = Query(None),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    limit = min(k or 40, 10000)
    params = oa_params({
        "search": query,
        "per_page": 200,
        "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations,referenced_works,cited_by_count,relevance_score",
    })

    filters = []
    from_date = request.query_params.get("from")
    to_date = request.query_params.get("to")
    if from_date:
        filters.append(f"from_publication_date:{from_date}")
    if to_date:
        filters.append(f"to_publication_date:{to_date}")
    if filters:
        params["filter"] = ",".join(filters)

    def matches(result: dict) -> bool:
        if authors:
            author_value = result.get("authors", "")
            names = author_value.lower() if isinstance(author_value, str) else " ".join(a.get("name", "").lower() for a in author_value)
            if not all(a.lower() in names for a in authors):
                return False
        if categories:
            available = [str(value).lower() for value in result.get("categories", [])]
            if not all(any(value == wanted.lower() or value.startswith(wanted.lower()) for value in available) for wanted in categories):
                return False
        return True

    results = []
    raw_total = 0
    page = 1
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        while len(results) < limit and page <= 50:
            p = dict(params)
            p["page"] = page
            resp = await client.get(f"{OPENALEX_BASE}/works", params=p)
            if resp.status_code != 200:
                break
            data = resp.json()
            raw_total = data.get("meta", {}).get("count", raw_total)
            page_results = data.get("results", [])
            if not page_results:
                break
            for work in page_results:
                result = oa_to_result(work)
                if matches(result):
                    results.append(result)
                    if len(results) >= limit:
                        break
            if len(page_results) < 200 or page * 200 >= raw_total:
                break
            page += 1

    filtered = bool(authors or categories)
    return {
        "success": True,
        "results": results[:limit],
        "total": len(results) if filtered else raw_total,
        "truncated": len(results) >= limit and (filtered or raw_total > limit),
    }


# ── Route order matters: register /similar BEFORE /{paper_id} ──
# because {paper_id:path} is greedy and would swallow "X/similar" as paper_id.

@app.get("/__legacy/research/papers/{paper_id:path}/similar")
async def similar_papers(
    paper_id: str,
    request: Request,
    intent: str = Query(..., min_length=1),
    mode: Optional[str] = Query(None),
    k: Optional[int] = Query(None, ge=1, le=10000),
    rerank: Optional[str] = Query(None),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    oa_id = await resolve_oa_id(paper_id)
    if not oa_id:
        return JSONResponse(status_code=404, content={"success": False, "error": "Paper not found"})

    limit = min(k or 20, 200)
    anchors = request.query_params.getlist("anchor")

    params = oa_params({
        "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations,referenced_works,cited_by_count",
    })

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        resp = await client.get(f"{OPENALEX_BASE}/works/{oa_id}", params=params)

    if resp.status_code != 200:
        return JSONResponse(status_code=404, content={"success": False, "error": "Paper not found"})

    work = resp.json()
    seed_refs = set(r.rsplit("/", 1)[-1] for r in (work.get("referenced_works") or []))

    results = []
    pool_size = 0

    # Try Semantic Scholar recommendations first (best quality)
    s2_id = paper_id
    if not paper_id.startswith("CorpusId:"):
        # Try to find S2-compatible ID
        raw_ids = work.get("ids") or {}
        if raw_ids.get("doi"):
            s2_id = raw_ids["doi"].replace("https://doi.org/", "DOI:")
        elif raw_ids.get("pmid"):
            s2_id = f"PMID:{raw_ids['pmid']}"
        elif raw_ids.get("pmcid"):
            s2_id = raw_ids["pmcid"]
        else:
            s2_id = f"CorpusId:{oa_id}"

    s2_results = await s2_recommendations(s2_id, limit)
    if s2_results:
        pool_size += len(s2_results)
        results.extend(s2_results)

    # If S2 didn't return enough, fall back to OpenAlex co-citation
    if len(results) < limit:
        remaining = limit - len(results)
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            if mode == "references":
                ref_ids = work.get("referenced_works") or []
                pool_size = len(ref_ids)
                batch = ref_ids[:remaining]
                if batch:
                    ids_param = "|".join(r.rsplit("/", 1)[-1] for r in batch)
                    resp2 = await client.get(
                        f"{OPENALEX_BASE}/works",
                        params=oa_params({
                            "filter": f"openalex_id:{ids_param}",
                            "per_page": min(len(batch), 200),
                            "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations",
                        }),
                    )
                    if resp2.status_code == 200:
                        for w in resp2.json().get("results", []):
                            results.append(oa_to_result(w))

            elif mode == "citers":
                resp2 = await client.get(
                    f"{OPENALEX_BASE}/works",
                    params=oa_params({
                        "filter": f"cites:{oa_id}",
                        "per_page": remaining,
                        "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations",
                        "sort": "cited_by_count:desc",
                    }),
                )
                if resp2.status_code == 200:
                    data2 = resp2.json()
                    for w in data2.get("results", []):
                        results.append(oa_to_result(w))
                    pool_size += data2.get("meta", {}).get("count", 0)

            else:
                # Default "similar" mode: co-citation scored candidates
                # Get citers (papers that cite this one)
                resp2 = await client.get(
                    f"{OPENALEX_BASE}/works",
                    params=oa_params({
                        "filter": f"cites:{oa_id}",
                        "per_page": remaining,
                        "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations,referenced_works",
                        "sort": "cited_by_count:desc",
                    }),
                )
                candidates = []
                if resp2.status_code == 200:
                    for w in resp2.json().get("results", []):
                        candidates.append(w)
                        results.append(oa_to_result(w))
                    pool_size += resp2.json().get("meta", {}).get("count", 0)

                # Score candidates by co-citation: how many of the seed's refs do they share?
                if candidates and seed_refs:
                    scored = []
                    for w in candidates:
                        c_refs = set(r.rsplit("/", 1)[-1] for r in (w.get("referenced_works") or []))
                        shared = len(seed_refs & c_refs)
                        scored.append((shared, w))
                    scored.sort(key=lambda x: x[0], reverse=True)
                    # Rebuild results in co-citation order
                    existing_ids = {r.get("paperId") for r in results}
                    results = [oa_to_result(w) for _, w in scored]
                    # Add back any S2 results that weren't in the co-citation set
                    for s2r in s2_results:
                        if s2r.get("paperId") not in {r.get("paperId") for r in results}:
                            results.insert(0, s2r)

                # Also add seed's own references as candidates (bibliographic coupling)
                if len(results) < limit and seed_refs:
                    batch = list(seed_refs)[:remaining]
                    ids_param = "|".join(batch)
                    resp3 = await client.get(
                        f"{OPENALEX_BASE}/works",
                        params=oa_params({
                            "filter": f"openalex_id:{ids_param}",
                            "per_page": min(len(batch), 200),
                            "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations",
                        }),
                    )
                    if resp3.status_code == 200:
                        for w in resp3.json().get("results", []):
                            results.append(oa_to_result(w))

        # Handle anchors
        if anchors:
            for anchor in anchors:
                a_oa_id = await resolve_oa_id(anchor)
                if not a_oa_id:
                    continue
                async with httpx.AsyncClient(timeout=TIMEOUT) as client:
                    a_resp = await client.get(f"{OPENALEX_BASE}/works/{a_oa_id}", params=params)
                if a_resp.status_code != 200:
                    continue
                a_work = a_resp.json()
                a_refs = a_work.get("referenced_works") or []
                pool_size += len(a_refs)
                if mode == "references":
                    batch = a_refs[:limit]
                else:
                    batch = a_refs[:limit]
                if batch:
                    ids_param = "|".join(r.rsplit("/", 1)[-1] for r in batch)
                    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
                        r2 = await client.get(
                            f"{OPENALEX_BASE}/works",
                            params=oa_params({
                                "filter": f"openalex_id:{ids_param}",
                                "per_page": min(len(batch), 200),
                                "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations",
                            }),
                        )
                    if r2.status_code == 200:
                        for w in r2.json().get("results", []):
                            results.append(oa_to_result(w))

    # Deduplicate
    seen = set()
    deduped = []
    for r in results:
        pid = r.get("paperId")
        if pid and pid not in seen:
            seen.add(pid)
            deduped.append(r)
    results = deduped

    # If intent provided, do a simple relevance rerank
    if intent and not s2_results:
        intent_words = set(re.findall(r"\w+", intent.lower()))
        if intent_words:
            scored = []
            for r in results:
                text = " ".join(filter(None, [r.get("title") or "", r.get("abstract") or ""])).lower()
                text_words = set(re.findall(r"\w+", text))
                overlap = len(intent_words & text_words)
                scored.append((overlap, r))
            scored.sort(key=lambda x: x[0], reverse=True)
            results = [r for _, r in scored]

    if k:
        results = results[:k]

    # Surface what the seed actually resolved to so callers can catch
    # wrong-ID mistakes immediately (e.g. an arXiv id pointing at a
    # different paper than intended).
    return {
        "success": True,
        "results": results,
        "poolSize": pool_size,
        "seed": {
            "requested": paper_id,
            "openalexId": oa_id,
            "resolvedTitle": work.get("title"),
        },
    }


RELATED_SELECT = "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations,referenced_works,cited_by_count,relevance_score"


async def openalex_works_by_ids(client: httpx.AsyncClient, ids: list[str]) -> list[dict]:
    works = []
    unique = list(dict.fromkeys(i.rsplit("/", 1)[-1] for i in ids if i))
    for start in range(0, len(unique), 200):
        batch = unique[start:start + 200]
        if not batch:
            continue
        response = await client.get(
            f"{OPENALEX_BASE}/works",
            params=oa_params({
                "filter": f"openalex_id:{'|'.join(batch)}",
                "per_page": len(batch),
                "select": RELATED_SELECT,
            }),
        )
        if response.status_code == 200:
            works.extend(response.json().get("results", []))
    return works


def s2_reference_for_work(work: dict) -> Optional[str]:
    result = oa_to_result(work)
    ids = result.get("ids", {})
    for namespace in ("arxiv", "doi", "pmid", "pmcid"):
        values = ids.get(namespace) or []
        if values:
            return f"{namespace}:{values[0]}"
    return None


def similarity_semantic_score(result: dict, intent: str) -> float:
    words = {word for word in re.findall(r"[a-z0-9]+", intent.lower()) if len(word) > 2}
    if not words:
        return 0.0
    text = " ".join((result.get("title") or "", result.get("abstract") or "")).lower()
    return len(words & set(re.findall(r"[a-z0-9]+", text))) / len(words)


@app.get("/v2/research/papers/{paper_id:path}/similar")
async def similar_papers_v2(
    paper_id: str,
    request: Request,
    intent: str = Query(..., min_length=1),
    mode: Optional[str] = Query(None),
    k: Optional[int] = Query(None, ge=1, le=10000),
    rerank: Optional[str] = Query(None),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    oa_id = await resolve_oa_id(paper_id)
    if not oa_id:
        return JSONResponse(status_code=404, content={"success": False, "error": "Paper not found"})

    limit = min(k or 40, 10000)
    traversal = mode or "similar"
    if traversal not in ("similar", "citers", "references"):
        return JSONResponse(status_code=400, content={"success": False, "error": "Unsupported related-paper mode"})
    rerank_enabled = rerank is True or str(rerank).lower() == "true"
    requested_anchors = request.query_params.getlist("anchor")

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        primary_response = await client.get(
            f"{OPENALEX_BASE}/works/{quote(oa_id, safe='')}",
            params=oa_params({"select": RELATED_SELECT}),
        )
        if primary_response.status_code != 200:
            return JSONResponse(status_code=404, content={"success": False, "error": "Paper not found"})
        primary_work = primary_response.json()

        seed_works = [(oa_id, primary_work)]
        for anchor in requested_anchors:
            anchor_id = await resolve_oa_id(anchor)
            if not anchor_id or anchor_id == oa_id or any(existing == anchor_id for existing, _ in seed_works):
                continue
            anchor_response = await client.get(
                f"{OPENALEX_BASE}/works/{quote(anchor_id, safe='')}",
                params=oa_params({"select": RELATED_SELECT}),
            )
            if anchor_response.status_code == 200:
                seed_works.append((anchor_id, anchor_response.json()))

        seed_ids = {seed_id for seed_id, _ in seed_works}
        candidates: dict[str, dict[str, Any]] = {}

        def add_candidate(result: dict, structural: float, overlap: int) -> None:
            key = result.get("paperId") or result.get("primaryId")
            if not key or result.get("openAlexId") in seed_ids:
                return
            current = candidates.get(key)
            if current is None:
                candidates[key] = {"result": result, "structural": structural, "overlap": overlap}
            else:
                current["structural"] = max(current["structural"], structural)
                current["overlap"] = max(current["overlap"], overlap)

        if traversal == "similar":
            s2_ids = [ref for _, work in seed_works if (ref := s2_reference_for_work(work))]
            recommendation_batches = await asyncio.gather(
                *(s2_recommendations(ref, min(limit, 500)) for ref in s2_ids),
                return_exceptions=True,
            )
            for batch in recommendation_batches:
                if isinstance(batch, Exception):
                    continue
                for result in batch:
                    add_candidate(result, 0, 1)

        reference_ids: list[str] = []
        for _, work in seed_works:
            reference_ids.extend(work.get("referenced_works") or [])
        if traversal in ("references", "similar") and reference_ids:
            references = await openalex_works_by_ids(client, reference_ids[: max(limit * 3, 200)])
            for work in references:
                work_id = work.get("id", "").rsplit("/", 1)[-1]
                overlap = sum(1 for _, seed in seed_works if work_id in [r.rsplit("/", 1)[-1] for r in (seed.get("referenced_works") or [])])
                add_candidate(oa_to_result(work), 1, max(overlap, 1))

        if traversal in ("citers", "similar"):
            for seed_id, _ in seed_works:
                response = await client.get(
                    f"{OPENALEX_BASE}/works",
                    params=oa_params({
                        "filter": f"cites:{seed_id}",
                        "per_page": min(200, max(limit, 20)),
                        "select": RELATED_SELECT,
                        "sort": "cited_by_count:desc",
                    }),
                )
                if response.status_code != 200:
                    continue
                for work in response.json().get("results", []):
                    add_candidate(oa_to_result(work), float(work.get("cited_by_count") or 0), 1)

    ranked = []
    for item in candidates.values():
        result = item["result"]
        semantic = similarity_semantic_score(result, intent)
        structural = float(item["structural"])
        article_rank = float(result.get("citedByCount") or 0)
        result["score"] = semantic * (100 if rerank_enabled else 10) + structural + min(article_rank, 100) / 100
        result["signals"] = {
            "structural": structural,
            "semantic": semantic,
            "articleRank": article_rank,
            "seedOverlap": item["overlap"],
        }
        ranked.append(result)
    ranked.sort(key=lambda result: (-result.get("score", 0), result.get("paperId", "")))
    results = ranked[:limit]
    return {
        "success": True,
        "results": results,
        "poolSize": len(ranked),
        "truncated": len(ranked) > len(results),
        "note": "No related papers matched the requested traversal and intent." if not results else None,
        "seed": {
            "requested": paper_id,
            "openalexId": oa_id,
            "resolvedTitle": primary_work.get("title"),
            "anchors": requested_anchors,
        },
    }


@app.get("/v2/research/papers/{paper_id:path}")
async def get_paper(
    paper_id: str,
    request: Request,
    query: Optional[str] = Query(None),
    k: Optional[int] = Query(None, ge=1, le=500),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    reference = parse_paper_reference(paper_id)
    is_arxiv = reference["kind"] == "arxiv"
    arxiv_id = reference["value"] if is_arxiv else None

    if is_arxiv:
        arxiv_result = await arxiv_lookup(arxiv_id)
        if arxiv_result:
            oa_id = await arxiv_to_openalex_id(arxiv_id)
            if oa_id:
                arxiv_result["openAlexId"] = oa_id

            if query is not None:
                passages = await find_passages(arxiv_result, {}, query, k or 4)
                return {
                    "success": True,
                    "paper": arxiv_result,
                    "paperId": arxiv_result["paperId"],
                    "query": query,
                    "passages": passages,
                }

            return {"success": True, "paper": arxiv_result}

    # Titles are accepted as a convenience, but resolve them with the same
    # exact/similarity verification used by related-paper lookups.
    if reference["kind"] == "title":
        resolved = await resolve_oa_id(reference["value"])
        if not resolved:
            return JSONResponse(status_code=404, content={"success": False, "error": "Paper not found"})
        reference = {"kind": "openalex", "value": resolved, "canonical": f"openalex:{resolved}"}

    # Try OpenAlex first
    oa_id_raw = reference["canonical"]
    if reference["kind"] in ("doi", "pmid", "pmcid"):
        oa_lookup = f"{reference['kind']}:{reference['value']}"
    elif reference["kind"] == "openalex":
        oa_lookup = reference["value"]
    else:
        oa_lookup = reference["value"]

    params = oa_params({
        "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations,referenced_works,cited_by_count,open_access",
    })

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        resp = await client.get(f"{OPENALEX_BASE}/works/{quote(oa_lookup, safe=':')}", params=params)

    if resp.status_code == 404:
        # Fallback: try Crossref for DOI lookups
        if oa_id_raw.startswith("doi:"):
            crossref_result = await crossref_lookup(oa_id_raw[4:])
            if crossref_result:
                if query is not None:
                    passages = await find_passages(crossref_result, {}, query, k or 4)
                    return {
                        "success": True,
                        "paper": crossref_result,
                        "paperId": crossref_result["paperId"],
                        "query": query,
                        "passages": passages,
                    }
                return {"success": True, "paper": crossref_result}
        # Fallback: try Semantic Scholar
        s2_result = await s2_lookup(paper_id)
        if s2_result:
            if query is not None:
                passages = await find_passages(s2_result, {}, query, k or 4)
                return {
                    "success": True,
                    "paper": s2_result,
                    "paperId": s2_result["paperId"],
                    "query": query,
                    "passages": passages,
                }
            return {"success": True, "paper": s2_result}
        # Last fallback: Europe PMC for PubMed Central / PMID identifiers
        epmc_id = None
        if oa_id_raw.startswith("pmcid:"):
            epmc_id = ("pmcid", oa_id_raw[6:])
        elif oa_id_raw.startswith("pmid:"):
            epmc_id = ("pmid", oa_id_raw[5:])
        if epmc_id:
            epmc_result = await europepmc_metadata_lookup(epmc_id[1], id_type=epmc_id[0])
            if epmc_result:
                if query is not None:
                    passages = await find_passages(epmc_result, {}, query, k or 4)
                    return {
                        "success": True,
                        "paper": epmc_result,
                        "paperId": epmc_result["paperId"],
                        "query": query,
                        "passages": passages,
                    }
                return {"success": True, "paper": epmc_result}
        return JSONResponse(status_code=404, content={"success": False, "error": "Paper not found"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"success": False, "error": f"OpenAlex error: {resp.text}"})

    work = resp.json()
    result = oa_to_result(work)

    if query is not None:
        passages = await find_passages(result, work, query, k or 4)
        return {
            "success": True,
            "paper": result,
            "paperId": result["paperId"],
            "query": query,
            "passages": passages,
        }

    return {"success": True, "paper": result}


@app.get("/__legacy/research/github")
async def search_github(
    request: Request,
    query: str = Query(..., min_length=1),
    k: Optional[int] = Query(None, ge=1, le=1000),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    limit = min(k or 20, 100)
    results = []

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        issues_resp, repos_resp = await asyncio.gather(
            client.get(
                f"{GITHUB_BASE}/search/issues",
                params={"q": query, "per_page": min(limit, 100)},
                headers=gh_headers(),
            ),
            client.get(
                f"{GITHUB_BASE}/search/repositories",
                params={"q": query, "per_page": min(limit, 100)},
                headers=gh_headers(),
            ),
        )

        if repos_resp.status_code == 200:
            repos_data = repos_resp.json()
            for repo in repos_data.get("items", [])[:10]:
                full_name = repo.get("full_name", "")
                readme_url = repo.get("html_url", "") + "#readme"
                readme_content = ""
                try:
                    rd_resp = await client.get(
                        f"{GITHUB_BASE}/repos/{full_name}/readme",
                        headers={**gh_headers(), "Accept": "application/vnd.github.v3.raw"},
                    )
                    if rd_resp.status_code == 200:
                        readme_content = rd_resp.text[:100000]
                except Exception:
                    pass
                results.append({
                    "repo": full_name,
                    "resultType": "repo_readme",
                    "url": repo.get("html_url", ""),
                    "readmeUrl": readme_url,
                    "contentMd": readme_content,
                    "snippet": repo.get("description", ""),
                })

        if issues_resp.status_code == 200:
            issues_data = issues_resp.json()
            for item in issues_data.get("items", []):
                repo_url = item.get("repository_url", "")
                repo_name = repo_url.replace("https://api.github.com/repos/", "") if repo_url else ""
                is_pr = "pull_request" in item
                body = (item.get("body") or "").strip()[:100000]
                results.append({
                    "repo": repo_name,
                    "resultType": "pr" if is_pr else "issue",
                    "number": item.get("number"),
                    "pageType": "pull_request" if is_pr else "issue",
                    "url": item.get("html_url", ""),
                    "snippet": item.get("title", ""),
                    "contentMd": body,
                })

    if k:
        results = results[:k]

    return {"success": True, "results": results}


async def github_search_pages(client: httpx.AsyncClient, endpoint: str, query: str, limit: int) -> list[dict]:
    items = []
    for page in range(1, min((limit + 99) // 100, 10) + 1):
        page_size = min(limit - len(items), 100)
        response = await client.get(
            f"{GITHUB_BASE}/search/{endpoint}",
            params={"q": query, "per_page": page_size, "page": page, "sort": "best-match"},
            headers=gh_headers(),
        )
        if response.status_code != 200:
            break
        page_items = response.json().get("items", [])
        items.extend(page_items)
        if len(page_items) < page_size:
            break
        if len(items) >= limit:
            break
    return items[:limit]


def github_repo_name(item: dict) -> str:
    repository = item.get("repository") or {}
    if repository.get("full_name"):
        return repository["full_name"]
    repository_url = item.get("repository_url") or ""
    return repository_url.replace("https://api.github.com/repos/", "").strip("/")


async def fetch_github_readme(client: httpx.AsyncClient, repo: dict) -> tuple[str, str]:
    full_name = repo.get("full_name", "")
    if not full_name:
        return "", ""
    try:
        response = await client.get(
            f"{GITHUB_BASE}/repos/{full_name}/readme",
            headers={**gh_headers(), "Accept": "application/vnd.github.v3.raw"},
        )
        if response.status_code == 200:
            return response.text[:100000], repo.get("html_url", "") + "#readme"
    except Exception:
        pass
    return "", repo.get("html_url", "") + "#readme"


@app.get("/v2/research/github")
async def search_github_v2(
    request: Request,
    query: str = Query(..., min_length=1),
    k: Optional[int] = Query(None, ge=1, le=1000),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    limit = min(k or 20, 1000)
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        repo_task = github_search_pages(client, "repositories", query, limit)
        issue_task = github_search_pages(client, "issues", query, limit)
        repos, issues = await asyncio.gather(repo_task, issue_task, return_exceptions=True)
        repos = [] if isinstance(repos, Exception) else repos
        issues = [] if isinstance(issues, Exception) else issues

        readme_map = {}
        for repo in repos[: min(limit, 20)]:
            full_name = repo.get("full_name", "")
            readme_map[full_name] = fetch_github_readme(client, repo)
        readmes = await asyncio.gather(*readme_map.values(), return_exceptions=True)
        for full_name, value in zip(readme_map, readmes):
            if not isinstance(value, Exception):
                readme_map[full_name] = value

    results = []
    for repo in repos:
        full_name = repo.get("full_name", "")
        readme_content, readme_url = readme_map.get(full_name, ("", repo.get("html_url", "") + "#readme"))
        results.append({
            "repo": full_name,
            "resultType": "repo_readme",
            "url": repo.get("html_url", ""),
            "readmeUrl": readme_url,
            "snippet": repo.get("description") or "",
            **({"contentMd": readme_content} if readme_content else {}),
            "scores": {"lexical": float(repo.get("score") or 0)},
        })
    for item in issues:
        is_pr = "pull_request" in item
        results.append({
            "repo": github_repo_name(item),
            "resultType": "github_history",
            "number": item.get("number"),
            "pageType": "pull_request" if is_pr else "issue",
            "url": item.get("html_url", ""),
            "snippet": item.get("title") or "",
            **({"contentMd": (item.get("body") or "").strip()[:100000]} if item.get("body") else {}),
            "scores": {"lexical": float(item.get("score") or 0)},
        })

    return {"success": True, "results": results[:limit]}


def build_github_code_query(
    query: str,
    language: Optional[str] = None,
    min_stars: Optional[int] = None,
    max_stars: Optional[int] = None,
    license: Optional[str] = None,
    topic: Optional[List[str]] = None,
    archived: Optional[bool] = None,
    fork: Optional[bool] = None,
    repos: Optional[List[str]] = None,
) -> str:
    parts = [query]
    repo_filters = [repo.strip() for repo in (repos or []) if repo.strip()]
    if len(repo_filters) > 1:
        raise ValueError("GitHub code search accepts one repo qualifier per request")
    if repo_filters:
        parts.append(f"repo:{repo_filters[0]}")
    if language:
        parts.append(f"language:{language}")
    return " ".join(parts)


@app.get("/__legacy/code/search")
async def code_search(
    request: Request,
    query: str = Query(..., min_length=1),
    k: Optional[int] = Query(None, ge=1, le=1000),
    types: Optional[List[str]] = Query(None),
    repos: Optional[List[str]] = Query(None),
    sources: Optional[List[str]] = Query(None),
    passages: Optional[int] = Query(None, ge=1, le=5),
    language: Optional[str] = Query(None),
    topic: Optional[List[str]] = Query(None),
    license: Optional[str] = Query(None),
    min_stars: Optional[int] = Query(None, ge=0),
    max_stars: Optional[int] = Query(None, ge=0),
    archived: Optional[bool] = Query(None),
    fork: Optional[bool] = Query(None),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    """Developer/code search across GitHub repos and issues/PRs.

    `types`/`sources` accept: repo(s)/repo_readme, issue(s), pull_request(s)/pr(s).
    """
    limit = min(k or 10, 100)
    selected = {t.strip().lower() for t in (types or []) + (sources or []) if t}
    want_repos, want_issues, want_prs = True, True, True
    if selected:
        want_repos = any(t in ("repos", "repo", "repo_readme", "readme") for t in selected)
        want_issues = any(t in ("issues", "issue") for t in selected)
        want_prs = any(t in ("pull_requests", "pull_request", "prs", "pr") for t in selected)
        if not (want_repos or want_issues or want_prs):
            want_repos = want_issues = want_prs = True

    ghq = build_github_code_query(
        query,
        language=language,
        min_stars=min_stars,
        max_stars=max_stars,
        license=license,
        topic=topic,
        archived=archived,
        fork=fork,
        repos=repos,
    )

    issues_q = ghq
    if want_prs and not want_issues:
        issues_q += " is:pr"
    elif want_issues and not want_prs:
        issues_q += " is:issue"

    results = []
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        repos_resp = issues_resp = None

        async def fetch_repos():
            return await client.get(
                f"{GITHUB_BASE}/search/repositories",
                params={"q": ghq, "per_page": min(limit, 100), "sort": "best-match"},
                headers=gh_headers(),
            )

        async def fetch_issues():
            return await client.get(
                f"{GITHUB_BASE}/search/issues",
                params={"q": issues_q, "per_page": min(limit, 100), "sort": "best-match"},
                headers=gh_headers(),
            )

        tasks = []
        if want_repos:
            tasks.append(fetch_repos())
        if want_issues or want_prs:
            tasks.append(fetch_issues())

        responses = await asyncio.gather(*tasks, return_exceptions=True)
        idx = 0
        if want_repos:
            repos_resp = responses[idx]
            idx += 1
        if want_issues or want_prs:
            issues_resp = responses[idx]

        if isinstance(repos_resp, httpx.Response) and repos_resp.status_code == 200:
            repo_cap = min(limit, 10)
            for repo in repos_resp.json().get("items", [])[:repo_cap]:
                full_name = repo.get("full_name", "")
                readme_content = ""
                try:
                    rd_resp = await client.get(
                        f"{GITHUB_BASE}/repos/{full_name}/readme",
                        headers={**gh_headers(), "Accept": "application/vnd.github.v3.raw"},
                    )
                    if rd_resp.status_code == 200:
                        readme_content = rd_resp.text[:100000]
                except Exception:
                    pass
                stars = repo.get("stargazers_count", 0)
                lang = repo.get("language") or ""
                header = (
                    f"# {repo.get('full_name', '')}\n\n"
                    f"{repo.get('description') or ''}\n\n"
                    f"- Stars: {stars} | Language: {lang} | "
                    f"License: {(repo.get('license') or {}).get('spdx_id') or 'none'}\n"
                )
                results.append({
                    "repo": full_name,
                    "resultType": "repo_readme",
                    "url": repo.get("html_url", ""),
                    "readmeUrl": repo.get("html_url", "") + "#readme",
                    "snippet": repo.get("description", ""),
                    "contentMd": header + "\n" + readme_content,
                    "stars": stars,
                    "language": lang,
                    "topics": repo.get("topics", []),
                })

        if isinstance(issues_resp, httpx.Response) and issues_resp.status_code == 200:
            for item in issues_resp.json().get("items", []):
                repo_url = item.get("repository_url", "")
                repo_name = repo_url.replace("https://api.github.com/repos/", "") if repo_url else ""
                is_pr = "pull_request" in item
                body = (item.get("body") or "").strip()[:100000]
                results.append({
                    "repo": repo_name,
                    "resultType": "pull_request" if is_pr else "issue",
                    "number": item.get("number"),
                    "pageType": "pull_request" if is_pr else "issue",
                    "url": item.get("html_url", ""),
                    "snippet": item.get("title", ""),
                    "contentMd": body,
                })

    results.sort(key=lambda r: r.get("stars", 0), reverse=True)

    return {"success": True, "query": ghq, "count": len(results), "results": results[: k or limit]}


async def github_code_pages(client: httpx.AsyncClient, query: str, limit: int) -> list[dict]:
    items = []
    for page in range(1, min((limit + 99) // 100, 10) + 1):
        page_size = min(limit - len(items), 100)
        response = await client.get(
            f"{GITHUB_BASE}/search/code",
            params={"q": query, "per_page": page_size, "page": page},
            headers={**gh_headers(), "Accept": "application/vnd.github.text-match+json"},
        )
        if response.status_code != 200:
            break
        page_items = response.json().get("items", [])
        items.extend(page_items)
        if len(page_items) < page_size:
            break
    return items[:limit]


async def github_code_passages(client: httpx.AsyncClient, item: dict, count: int) -> list[dict]:
    matches = item.get("text_matches") or []
    passages = [
        {"text": str(match.get("fragment") or "").strip(), "citation_url": item.get("html_url", "")}
        for match in matches[:count]
        if match.get("fragment")
    ]
    if passages:
        return passages

    repository = (item.get("repository") or {}).get("full_name")
    path = item.get("path")
    if not repository or not path:
        return []
    try:
        response = await client.get(
            f"{GITHUB_BASE}/repos/{repository}/contents/{quote(path, safe='/')}",
            headers=gh_headers(),
        )
        payload = response.json() if response.status_code == 200 else {}
        encoded = payload.get("content")
        if encoded:
            text = base64.b64decode(encoded).decode("utf-8", errors="replace")[:20000]
            return [{"text": text, "citation_url": item.get("html_url", "")}]
    except Exception:
        pass
    return []


def github_license(repo: dict) -> dict:
    license_info = repo.get("license") or {}
    spdx = license_info.get("spdx_id")
    if spdx and spdx != "NOASSERTION":
        return {"state": "licensed", "spdx_id": spdx}
    return {"state": "known_absent", "spdx_id": None}


@app.get("/v2/code/search")
@app.post("/v2/code/search")
@app.post("/v2/search/developer")
@app.get("/v2/search/developer")
async def developer_search(
    request: Request,
    query: Optional[str] = Query(None),
    k: Optional[int] = Query(None, ge=1, le=1000),
    types: Optional[List[str]] = Query(None),
    repos: Optional[List[str]] = Query(None),
    sources: Optional[List[str]] = Query(None),
    passages: Optional[int] = Query(None, ge=1, le=5),
    language: Optional[str] = Query(None),
    topic: Optional[List[str]] = Query(None),
    license: Optional[str] = Query(None),
    min_stars: Optional[int] = Query(None, ge=0),
    max_stars: Optional[int] = Query(None, ge=0),
    archived: Optional[bool] = Query(None),
    fork: Optional[bool] = Query(None),
    skills: Optional[str] = Query(None),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    if request.method == "POST":
        try:
            body = await request.json()
        except Exception:
            body = {}
        query = query or body.get("query")
        k = k if k is not None else body.get("k")
        types = types if types is not None else body.get("types")
        repos = repos if repos is not None else body.get("repos")
        sources = sources if sources is not None else body.get("sources")
        passages = passages if passages is not None else body.get("passages")
        language = language or body.get("language")
        topic = topic if topic is not None else body.get("topic")
        license = license or body.get("license")
        min_stars = min_stars if min_stars is not None else body.get("min_stars")
        max_stars = max_stars if max_stars is not None else body.get("max_stars")
        archived = archived if archived is not None else body.get("archived")
        fork = fork if fork is not None else body.get("fork")
        skills = skills or body.get("skills")
    if not query or not query.strip():
        return JSONResponse(status_code=400, content={"success": False, "error": "query is required"})
    limit = min(k or 10, 1000)
    selected = {value.strip().lower() for value in (types or []) if value.strip()}
    allowed_types = {"doc", "readme", "issue", "pull_request", "pr", "code"}
    if selected - allowed_types:
        return JSONResponse(status_code=400, content={"success": False, "error": "Unsupported developer search type"})
    want_code = not selected or bool(selected & {"doc", "readme", "code"})
    want_issues = not selected or "issue" in selected
    want_prs = not selected or bool(selected & {"pull_request", "pr"})
    if skills not in (None, "only"):
        return JSONResponse(status_code=400, content={"success": False, "error": "skills must be 'only'"})
    if topic or license or min_stars is not None or max_stars is not None or archived is not None or fork is not None:
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "error": "topic, license, star, archived, and fork filters are not supported by GitHub code or issue search",
            },
        )

    repo_scopes = [repo.strip() for repo in (repos or []) if repo.strip()] or [None]
    per_scope_limit = max(1, (limit + len(repo_scopes) - 1) // len(repo_scopes))
    code_queries = []
    issue_queries = []
    for repo in repo_scopes:
        code_query = build_github_code_query(query, language, repos=[repo] if repo else None)
        if skills == "only":
            code_query += " filename:SKILL.md"
        elif selected == {"readme"}:
            code_query += " filename:README.md"
        elif selected == {"doc"}:
            code_query += " extension:md"
        code_queries.append(code_query)

        issues_query = query + (f" repo:{repo}" if repo else "")
        if want_prs and not want_issues:
            issues_query += " is:pr"
        elif want_issues and not want_prs:
            issues_query += " is:issue"
        issue_queries.append(issues_query)

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        code_tasks = [github_code_pages(client, item, per_scope_limit) for item in code_queries] if want_code else []
        issue_tasks = [github_search_pages(client, "issues", item, per_scope_limit) for item in issue_queries] if (want_issues or want_prs) else []
        batches = await asyncio.gather(*code_tasks, *issue_tasks, return_exceptions=True)
        code_items = [item for batch in batches[:len(code_tasks)] if not isinstance(batch, Exception) for item in batch]
        issue_items = [item for batch in batches[len(code_tasks):] if not isinstance(batch, Exception) for item in batch]
        code_items = list({item.get("html_url"): item for item in code_items if item.get("html_url")}.values())[:limit]
        issue_items = list({item.get("html_url"): item for item in issue_items if item.get("html_url")}.values())[:limit]

        passage_count = passages or 1
        code_passage_tasks = [github_code_passages(client, item, passage_count) for item in code_items[:50]]
        passage_batches = await asyncio.gather(*code_passage_tasks, return_exceptions=True)

    results = []
    for item, batch in zip(code_items[:50], passage_batches):
        if isinstance(batch, Exception):
            batch = []
        repository = item.get("repository") or {}
        results.append({
            "id": item.get("html_url") or f"{repository.get('full_name', '')}:{item.get('path', '')}",
            "url": item.get("html_url") or "",
            "title": f"{repository.get('full_name', '')}/{item.get('path', '')}".strip("/"),
            "passages": batch,
            "license": github_license(repository),
        })
    for item in issue_items:
        is_pr = "pull_request" in item
        if is_pr and not want_prs or not is_pr and not want_issues:
            continue
        repo = github_repo_name(item)
        text = (item.get("body") or item.get("title") or "").strip()[:20000]
        results.append({
            "id": item.get("html_url") or f"{repo}#{item.get('number')}",
            "url": item.get("html_url") or "",
            "title": item.get("title") or "",
            "passages": [{"text": text, "citation_url": item.get("html_url", "")}] if text else [],
            "license": github_license(item.get("repository") or {}),
        })

    response: dict[str, Any] = {"success": True, "results": results[:limit]}
    if repos:
        known = {((item.get("repository") or {}).get("full_name") or "").lower() for item in code_items + issue_items}
        response["repos"] = [
            {"repo": repo, "indexed": repo.lower() in known, "types": {"issue": repo.lower() in known, "pullRequest": repo.lower() in known, "readme": repo.lower() in known}}
            for repo in repos
        ]
    if sources:
        response["sources"] = [{"source": source, "indexed": any(source.lower() in str(item.get("path", "")).lower() for item in code_items)} for source in sources]
    return response


async def find_passages(result: dict, work: dict, question: str, num_passages: int) -> list:
    arxiv_id = get_arxiv_id_from_ids(result.get("ids", {}))
    pdf_url = None

    open_access = work.get("open_access") or {}
    oa_url = open_access.get("oa_url")
    if oa_url and "arxiv.org" in oa_url:
        pdf_url = oa_url.replace("/abs/", "/pdf/") + ".pdf"

    if not pdf_url and arxiv_id:
        pdf_url = f"https://arxiv.org/pdf/{arxiv_id}.pdf"

    # Try Europe PMC full-text XML if PMCID is available
    pmcid = None
    ids = result.get("ids", {})
    raw_ids = work.get("ids", {}) if work else {}
    if raw_ids.get("pmcid"):
        pmcid = raw_ids["pmcid"]
    elif ids.get("pmcid"):
        pmcid = ids["pmcid"][0]
    elif ids.get("PMCID"):
        pmcid = ids["PMCID"][0]

    if pmcid and not pdf_url:
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=True) as client:
                resp = await client.get(f"{EUROPEPMC_BASE}/{pmcid}/fullTextXML")
            if resp.status_code == 200 and resp.text:
                text = re.sub(r"<[^>]+>", " ", resp.text)
                text = re.sub(r"\s+", " ", text)
                if text.strip():
                    passages = split_into_passages(text)
                    ranked = rank_passages(passages, question)
                    top = ranked[:num_passages]
                    return [{"text": p, "score": score} for score, p in top]
        except Exception as e:
            print(f"Europe PMC full-text error: {e}")

    # Try OpenAlex best_oa_location or locations PDFs
    if not pdf_url:
        locations = work.get("locations") or []
        for loc in locations:
            pdf = loc.get("pdf_url")
            if pdf and pdf.endswith(".pdf"):
                pdf_url = pdf
                break

    # Try Semantic Scholar openAccessPdf
    if not pdf_url:
        paper_id_for_s2 = result.get("primaryId", "")
        if paper_id_for_s2:
            try:
                async with httpx.AsyncClient(timeout=TIMEOUT) as client:
                    s2_resp = await client.get(
                        f"{S2_BASE}/paper/{quote(s2_api_id(paper_id_for_s2), safe=':')}",
                        params={"fields": "openAccessPdf"},
                        headers=s2_headers(),
                    )
                if s2_resp.status_code == 200:
                    oa_pdf = s2_resp.json().get("openAccessPdf")
                    if oa_pdf and oa_pdf.get("url"):
                        pdf_url = oa_pdf["url"]
            except Exception:
                pass

    if not pdf_url:
        return []

    try:
        async with httpx.AsyncClient(timeout=300.0, follow_redirects=True) as client:
            resp = await client.get(pdf_url, headers={"User-Agent": BROWSER_UA})
        if resp.status_code != 200:
            return []

        from PyPDF2 import PdfReader
        reader = PdfReader(io.BytesIO(resp.content))
        full_text = ""
        for page in reader.pages:
            text = page.extract_text()
            if text:
                full_text += text + "\n"

        if not full_text.strip():
            return []

        passages = split_into_passages(full_text)
        ranked = rank_passages(passages, question)
        top = ranked[:num_passages]
        return [{"text": p, "score": score} for score, p in top]
    except Exception as e:
        print(f"Error extracting passages: {e}")
        return []


def split_into_passages(text: str, min_words: int = 50, max_words: int = 300) -> list:
    paragraphs = re.split(r"\n\s*\n", text)
    passages = []
    for para in paragraphs:
        para = para.strip()
        if not para:
            continue
        words = para.split()
        if len(words) < min_words:
            continue
        if len(words) > max_words:
            for i in range(0, len(words), max_words):
                chunk = " ".join(words[i:i + max_words])
                passages.append(chunk)
        else:
            passages.append(para)
    return passages


def rank_passages(passages: list, query: str) -> list:
    query_words = set(re.findall(r"\w+", query.lower()))
    if not query_words:
        return [(0.0, passage) for passage in passages]
    scored = []
    for p in passages:
        p_words = set(re.findall(r"\w+", p.lower()))
        overlap = len(query_words & p_words)
        scored.append((overlap / len(query_words), p))
    scored.sort(key=lambda x: x[0], reverse=True)
    # Return all passages sorted by relevance, filtering only zero-overlap if there ARE overlaps
    if scored and scored[0][0] > 0:
        return [(score, p) for score, p in scored if score > 0]
    return [(0.0, p) for p in passages]


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
