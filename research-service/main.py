from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse
import httpx
import re
import io
import os
import asyncio
import xml.etree.ElementTree as ET
from typing import Optional, List

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

def oa_to_result(work: dict) -> dict:
    work_id = work.get("id", "")
    oa_id = work_id.rsplit("/", 1)[-1] if work_id else ""

    doi = work.get("doi")
    doi_val = doi.replace("https://doi.org/", "") if doi else None

    ids = {}
    if doi_val:
        ids["DOI"] = [doi_val]
    if oa_id:
        ids["OpenAlex"] = [oa_id]

    locations = work.get("locations") or []
    for loc in locations:
        landing = loc.get("landing_url") or ""
        if "arxiv.org" in landing:
            arxiv_match = re.search(r"arxiv\.org/(?:abs|pdf)/(\d+\.\d+)", landing)
            if arxiv_match:
                ids["ArXiv"] = [arxiv_match.group(1)]
                break
        pdf = loc.get("pdf_url") or ""
        if "arxiv.org" in pdf:
            arxiv_match = re.search(r"arxiv\.org/(?:pdf|abs)/(\d+\.\d+)", pdf)
            if arxiv_match:
                ids["ArXiv"] = [arxiv_match.group(1)]
                break

    raw_ids = work.get("ids") or {}
    if raw_ids.get("openalex"):
        ids["OpenAlex"] = [raw_ids["openalex"].rsplit("/", 1)[-1]]
    if raw_ids.get("doi"):
        ids["DOI"] = [raw_ids["doi"].replace("https://doi.org/", "")]
    if raw_ids.get("mag"):
        ids["MAG"] = [str(raw_ids["mag"])]
    if raw_ids.get("pmid"):
        ids["PMID"] = [str(raw_ids["pmid"])]
    if raw_ids.get("pmcid"):
        ids["PMCID"] = [raw_ids["pmcid"]]

    primary = None
    for ns in ("ArXiv", "DOI", "PMCID", "PMID", "OpenAlex"):
        if ids.get(ns):
            ns_lower = ns.lower() if ns != "OpenAlex" else "openalex"
            primary = f"{ns_lower}:{ids[ns][0]}"
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
        "paperId": oa_id or work_id,
        "primaryId": primary,
        "title": work.get("title"),
        "authors": authors,
        "abstract": reconstruct_abstract(work.get("abstract_inverted_index")),
        "categories": concepts,
        "createdDate": pub_date,
        "updateDate": pub_date,
        "ids": ids,
        "openAlexId": oa_id,
    }

def normalize_paper_id(paper_id: str) -> str:
    pid = paper_id.strip()
    lower = pid.lower()
    if lower.startswith("arxiv:"):
        arxiv_num = pid[len("arxiv:"):]
        return f"doi:10.48550/arxiv.{arxiv_num}"
    if lower.startswith("doi:"):
        return "doi:" + pid[len("doi:"):]
    if lower.startswith("pmid:"):
        return "pmid:" + pid[len("pmid:"):]
    if lower.startswith("pmcid:"):
        return "pmcid:" + pid[len("pmcid:"):]
    if lower.startswith("openalex:"):
        return pid[len("openalex:"):]
    if lower.startswith("corpusid:"):
        return pid[len("corpusid:"):]
    return pid

def get_arxiv_id_from_ids(ids: dict) -> Optional[str]:
    arxiv = ids.get("ArXiv")
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
        ids = {"ArXiv": [arxiv_id]}
        if doi_val:
            ids["DOI"] = [doi_val]
        return {
            "paperId": f"arxiv:{arxiv_id}",
            "primaryId": f"arxiv:{arxiv_id}",
            "title": title_text,
            "authors": authors,
            "abstract": abstract_text,
            "categories": categories,
            "createdDate": pub_date,
            "updateDate": up_date,
            "ids": ids,
            "openAlexId": None,
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
        for w in results:
            locations = w.get("locations") or []
            for loc in locations:
                url = loc.get("landing_page_url") or ""
                if f"arxiv.org/abs/{arxiv_id}" in url:
                    return w.get("id", "").rsplit("/", 1)[-1]
            raw_ids = w.get("ids") or {}
            for v in (raw_ids.get("doi") or "").split(","):
                v = v.strip()
                if v and arxiv_id in v:
                    return w.get("id", "").rsplit("/", 1)[-1]
        if results:
            return results[0].get("id", "").rsplit("/", 1)[-1]
    except Exception:
        pass
    return None


async def crossref_lookup(doi: str) -> Optional[dict]:
    """Fallback: look up a DOI via Crossref when OpenAlex 404s."""
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(f"{CROSSREF_BASE}/works/{doi}")
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
            "paperId": doi,
            "primaryId": f"doi:{doi}",
            "title": title,
            "authors": authors,
            "abstract": abstract,
            "categories": [c for c in msg.get("subject") or []],
            "createdDate": pub_date,
            "updateDate": pub_date,
            "ids": {"DOI": [doi]},
            "openAlexId": None,
        }
    except Exception as e:
        print(f"Crossref lookup error: {e}")
        return None


def s2_api_id(paper_id: str) -> str:
    """Normalize a paper ID to Semantic Scholar's namespace (ArXiv:, DOI:, PMCID:, PMID:)."""
    lower = paper_id.lower()
    if lower.startswith("arxiv:"):
        return "ArXiv:" + paper_id[6:]
    if lower.startswith("pmcid:"):
        return "PMCID:" + paper_id[6:]
    if lower.startswith("pmid:"):
        return "PMID:" + paper_id[5:]
    if lower.startswith("doi:"):
        return "DOI:" + paper_id[4:]
    return paper_id


async def s2_lookup(paper_id: str) -> Optional[dict]:
    """Fallback: look up a paper via Semantic Scholar Graph API."""
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(
                f"{S2_BASE}/paper/{s2_api_id(paper_id)}",
                params={"fields": "paperId,title,abstract,authors,year,venue,externalIds,openAccessPdf,citationCount,referenceCount"},
                headers=s2_headers(),
            )
        if resp.status_code != 200:
            return None
        p = resp.json()
        ext = p.get("externalIds") or {}
        ids = {}
        if ext.get("DOI"):
            ids["DOI"] = [ext["DOI"]]
        if ext.get("ArXiv"):
            ids["ArXiv"] = [ext["ArXiv"]]
        if ext.get("PubMed"):
            ids["PMID"] = [str(ext["PubMed"])]
        if ext.get("PubMedCentral"):
            ids["PMCID"] = [ext["PubMedCentral"]]
        ids["CorpusId"] = [str(p.get("paperId", ""))]
        authors = [{"name": a.get("name", "")} for a in p.get("authors") or []]
        primary = None
        for ns in ("ArXiv", "DOI", "PMCID", "PMID"):
            if ids.get(ns):
                primary = f"{ns.lower()}:{ids[ns][0]}"
                break
        if not primary:
            primary = f"corpusid:{p.get('paperId', '')}"
        return {
            "paperId": str(p.get("paperId", "")),
            "primaryId": primary,
            "title": p.get("title"),
            "authors": authors,
            "abstract": p.get("abstract"),
            "categories": [p.get("venue")] if p.get("venue") else [],
            "createdDate": str(p.get("year", "")),
            "updateDate": str(p.get("year", "")),
            "ids": ids,
            "openAlexId": None,
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
            ids["DOI"] = [p["doi"]]
        if p.get("pmcid"):
            ids["PMCID"] = [p["pmcid"]]
        if p.get("pmid"):
            ids["PMID"] = [str(p["pmid"])]
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
        for ns in ("DOI", "ArXiv", "PMCID", "PMID"):
            if ids.get(ns):
                primary = f"{ns.lower()}:{ids[ns][0]}"
                break
        return {
            "paperId": (p.get("pmcid") or str(p.get("pmid") or "")),
            "primaryId": primary or f"{id_type}:{ident}",
            "title": p.get("title"),
            "authors": authors,
            "abstract": abstract,
            "categories": [p["journalTitle"]] if p.get("journalTitle") else [],
            "createdDate": str(p.get("firstPublicationDate") or p.get("pubYear") or ""),
            "updateDate": str(p.get("firstPublicationDate") or ""),
            "ids": ids,
            "openAlexId": None,
        }
    except Exception as e:
        print(f"Europe PMC metadata lookup error: {e}")
        return None


async def s2_recommendations(paper_id: str, limit: int = 20) -> list:
    """Get similar papers from Semantic Scholar recommendations API."""
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(
                f"{S2_RECOMMENDATIONS_BASE}/papers/forpaper/{paper_id}",
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
                ids["DOI"] = [ext["DOI"]]
            if ext.get("ArXiv"):
                ids["ArXiv"] = [ext["ArXiv"]]
            if ext.get("PubMed"):
                ids["PMID"] = [str(ext["PubMed"])]
            authors = [{"name": a.get("name", "")} for a in p.get("authors") or []]
            primary = None
            for ns in ("ArXiv", "DOI", "PMID"):
                if ids.get(ns):
                    primary = f"{ns.lower()}:{ids[ns][0]}"
                    break
            if not primary:
                primary = f"corpusid:{p.get('paperId', '')}"
            results.append({
                "paperId": str(p.get("paperId", "")),
                "primaryId": primary,
                "title": p.get("title"),
                "authors": authors,
                "abstract": p.get("abstract"),
                "categories": [p.get("venue")] if p.get("venue") else [],
                "createdDate": str(p.get("year", "")),
                "updateDate": str(p.get("year", "")),
                "ids": ids,
                "openAlexId": None,
            })
        return results
    except Exception as e:
        print(f"S2 recommendations error: {e}")
        return []


async def resolve_oa_id(paper_id: str) -> Optional[str]:
    """Resolve any paper ID format to an OpenAlex work ID."""
    lower = paper_id.lower()
    if lower.startswith("arxiv:"):
        return await arxiv_to_openalex_id(paper_id[len("arxiv:"):])
    oa_id_raw = normalize_paper_id(paper_id)
    if oa_id_raw.startswith("doi:"):
        oa_lookup = f"doi:{oa_id_raw[4:]}"
    elif oa_id_raw.startswith("pmid:"):
        oa_lookup = f"pmid:{oa_id_raw[5:]}"
    elif oa_id_raw.startswith("pmcid:"):
        oa_lookup = f"pmcid:{oa_id_raw[6:]}"
    elif oa_id_raw.startswith("W"):
        oa_lookup = oa_id_raw
    else:
        oa_lookup = oa_id_raw
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(f"{OPENALEX_BASE}/works/{oa_lookup}", params=oa_params({"select": "id"}))
        if resp.status_code == 200:
            return resp.json().get("id", "").rsplit("/", 1)[-1]
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
    limit = min(k or 40, 200)
    params = oa_params({
        "search": query,
        "per_page": limit,
        "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations,referenced_works,cited_by_count",
    })

    filters = []
    from_date = request.query_params.get("from")
    to_date = request.query_params.get("to")
    if from_date:
        filters.append(f"publication_date:{from_date}")
    if to_date:
        filters.append(f"publication_date:{to_date}")
    if filters:
        params["filter"] = ",".join(filters)

    all_results = []
    page = 1
    per_page = 200
    target = k or 40
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        while len(all_results) < target:
            p = dict(params)
            p["per_page"] = min(per_page, target - len(all_results))
            p["page"] = page
            resp = await client.get(f"{OPENALEX_BASE}/works", params=p)
            if resp.status_code != 200:
                break
            data = resp.json()
            page_results = data.get("results", [])
            if not page_results:
                break
            all_results.extend(page_results)
            total = data.get("meta", {}).get("count", len(all_results))
            if len(all_results) >= total:
                break
            page += 1
            if page > 50:
                break

    results = [oa_to_result(w) for w in all_results]

    if authors:
        filtered = []
        for r in results:
            r_names = " ".join(a.get("name", "").lower() for a in r.get("authors", []))
            if all(a.lower() in r_names for a in authors):
                filtered.append(r)
        results = filtered

    if k:
        results = results[:k]

    return {"success": True, "results": results, "total": len(all_results)}


# ── Route order matters: register /similar BEFORE /{paper_id} ──
# because {paper_id:path} is greedy and would swallow "X/similar" as paper_id.

@app.get("/v2/research/papers/{paper_id:path}/similar")
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

    return {"success": True, "results": results, "poolSize": pool_size}


@app.get("/v2/research/papers/{paper_id:path}")
async def get_paper(
    paper_id: str,
    request: Request,
    query: Optional[str] = Query(None),
    k: Optional[int] = Query(None, ge=1, le=500),
    origin: Optional[str] = Query(None),
    integration: Optional[str] = Query(None),
):
    lower = paper_id.lower()
    is_arxiv = lower.startswith("arxiv:")
    arxiv_id = paper_id[len("arxiv:"):] if is_arxiv else None

    if is_arxiv:
        arxiv_result = await arxiv_lookup(arxiv_id)
        if arxiv_result:
            oa_id = await arxiv_to_openalex_id(arxiv_id)
            if oa_id:
                arxiv_result["openAlexId"] = oa_id

            if query is not None:
                passages = await find_passages(arxiv_result, {}, query, k or 4)
                return {"success": True, "passages": passages}

            return {"success": True, "paper": arxiv_result}

    # Try OpenAlex first
    oa_id_raw = normalize_paper_id(paper_id)
    if oa_id_raw.startswith("doi:"):
        oa_lookup = f"doi:{oa_id_raw[4:]}"
    elif oa_id_raw.startswith("pmid:"):
        oa_lookup = f"pmid:{oa_id_raw[5:]}"
    elif oa_id_raw.startswith("pmcid:"):
        oa_lookup = f"pmcid:{oa_id_raw[6:]}"
    elif oa_id_raw.startswith("W"):
        oa_lookup = oa_id_raw
    else:
        oa_lookup = oa_id_raw

    params = oa_params({
        "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations,referenced_works,cited_by_count,open_access",
    })

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        resp = await client.get(f"{OPENALEX_BASE}/works/{oa_lookup}", params=params)

    if resp.status_code == 404:
        # Fallback: try Crossref for DOI lookups
        if oa_id_raw.startswith("doi:"):
            crossref_result = await crossref_lookup(oa_id_raw[4:])
            if crossref_result:
                if query is not None:
                    passages = await find_passages(crossref_result, {}, query, k or 4)
                    return {"success": True, "passages": passages}
                return {"success": True, "paper": crossref_result}
        # Fallback: try Semantic Scholar
        s2_result = await s2_lookup(paper_id)
        if s2_result:
            if query is not None:
                passages = await find_passages(s2_result, {}, query, k or 4)
                return {"success": True, "passages": passages}
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
                    return {"success": True, "passages": passages}
                return {"success": True, "paper": epmc_result}
        return JSONResponse(status_code=404, content={"success": False, "error": "Paper not found"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"success": False, "error": f"OpenAlex error: {resp.text}"})

    work = resp.json()
    result = oa_to_result(work)

    if query is not None:
        passages = await find_passages(result, work, query, k or 4)
        return {"success": True, "passages": passages}

    return {"success": True, "paper": result}


@app.get("/v2/research/github")
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
                        readme_content = rd_resp.text[:10000]
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
                body = (item.get("body") or "").strip()[:10000]
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
    for r in (repos or [])[:5]:
        parts.append(f"repo:{r.strip()}")
    if language:
        parts.append(f"language:{language}")
    for t in (topic or [])[:3]:
        parts.append(f"topic:{t.strip()}")
    if license:
        parts.append(f"license:{license}")
    if min_stars is not None and max_stars is not None:
        parts.append(f"stars:{min_stars}..{max_stars}")
    elif min_stars is not None:
        parts.append(f"stars:>={min_stars}")
    elif max_stars is not None:
        parts.append(f"stars:<={max_stars}")
    if archived is not None:
        parts.append("archived:true" if archived else "archived:false")
    if fork is not None:
        parts.append("fork:true" if fork else "fork:false")
    return " ".join(parts)


@app.get("/v2/code/search")
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
                        readme_content = rd_resp.text[:10000]
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
                body = (item.get("body") or "").strip()[:10000]
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
                    return [{"text": p} for p in top]
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
                        f"{S2_BASE}/paper/{paper_id_for_s2}",
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
        return [{"text": p} for p in top]
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
        return passages
    scored = []
    for p in passages:
        p_words = set(re.findall(r"\w+", p.lower()))
        overlap = len(query_words & p_words)
        scored.append((overlap, p))
    scored.sort(key=lambda x: x[0], reverse=True)
    # Return all passages sorted by relevance, filtering only zero-overlap if there ARE overlaps
    if scored and scored[0][0] > 0:
        return [p for _, p in scored if _ > 0]
    return passages


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
