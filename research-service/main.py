from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse
import httpx
import re
import io
import os
import asyncio
import xml.etree.ElementTree as ET
from typing import Optional, List
from urllib.parse import quote

app = FastAPI(title="Firecrawl Research Proxy")

OPENALEX_BASE = "https://api.openalex.org"
ARXIV_BASE = "https://export.arxiv.org/api"
GITHUB_BASE = "https://api.github.com"
S2_BASE = "https://api.semanticscholar.org/graph/v1"
MAILTO = os.environ.get("MAILTO", "research@firecrawl.local")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
S2_API_KEY = os.environ.get("S2_API_KEY", "")

TIMEOUT = 300.0

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


@app.get("/v2/research/papers/{paper_id}")
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
        return JSONResponse(status_code=404, content={"success": False, "error": "Paper not found"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"success": False, "error": f"OpenAlex error: {resp.text}"})

    work = resp.json()
    result = oa_to_result(work)

    if query is not None:
        passages = await find_passages(result, work, query, k or 4)
        return {"success": True, "passages": passages}

    return {"success": True, "paper": result}


@app.get("/v2/research/papers/{paper_id}/similar")
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
    lower_pid = paper_id.lower()
    is_arxiv = lower_pid.startswith("arxiv:")
    arxiv_id = paper_id[len("arxiv:"):] if is_arxiv else None

    oa_id = None
    if is_arxiv:
        oa_id = await arxiv_to_openalex_id(arxiv_id)
    if not oa_id:
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

        params_lookup = oa_params({"select": "id"})
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp_lookup = await client.get(f"{OPENALEX_BASE}/works/{oa_lookup}", params=params_lookup)
        if resp_lookup.status_code == 200:
            oa_id = resp_lookup.json().get("id", "").rsplit("/", 1)[-1]
    else:
        oa_lookup = oa_id

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

    results = []
    pool_size = 0

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        if mode == "references":
            ref_ids = work.get("referenced_works") or []
            pool_size = len(ref_ids)
            batch = ref_ids[:limit]
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
                    "per_page": limit,
                    "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations",
                    "sort": "cited_by_count:desc",
                }),
            )
            if resp2.status_code == 200:
                data2 = resp2.json()
                for w in data2.get("results", []):
                    results.append(oa_to_result(w))
                pool_size = data2.get("meta", {}).get("count", len(results))

        else:
            related = work.get("referenced_works") or []
            pool_size = len(related)

            resp2 = await client.get(
                f"{OPENALEX_BASE}/works",
                params=oa_params({
                    "filter": f"cites:{oa_id}",
                    "per_page": limit,
                    "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations",
                    "sort": "cited_by_count:desc",
                }),
            )
            if resp2.status_code == 200:
                for w in resp2.json().get("results", []):
                    results.append(oa_to_result(w))

            if len(results) < limit and related:
                batch = related[:limit - len(results)]
                ids_param = "|".join(r.rsplit("/", 1)[-1] for r in batch)
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

        if anchors:
            for anchor in anchors:
                a_raw = normalize_paper_id(anchor)
                if a_raw.startswith("doi:"):
                    a_lookup = f"doi:{a_raw[4:]}"
                elif a_raw.startswith("W"):
                    a_lookup = a_raw
                else:
                    a_lookup = a_raw
                a_resp = await client.get(f"{OPENALEX_BASE}/works/{a_lookup}", params=params)
                if a_resp.status_code != 200:
                    continue
                a_work = a_resp.json()
                a_oa_id = a_work.get("id", "").rsplit("/", 1)[-1]
                if mode == "references":
                    a_refs = a_work.get("referenced_works") or []
                    pool_size += len(a_refs)
                    batch = a_refs[:limit]
                    if batch:
                        ids_param = "|".join(r.rsplit("/", 1)[-1] for r in batch)
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
                elif mode == "citers":
                    r2 = await client.get(
                        f"{OPENALEX_BASE}/works",
                        params=oa_params({
                            "filter": f"cites:{a_oa_id}",
                            "per_page": limit,
                            "select": "id,doi,title,abstract_inverted_index,authorships,concepts,publication_date,ids,locations",
                            "sort": "cited_by_count:desc",
                        }),
                    )
                    if r2.status_code == 200:
                        d2 = r2.json()
                        for w in d2.get("results", []):
                            results.append(oa_to_result(w))
                        pool_size += d2.get("meta", {}).get("count", 0)
                else:
                    a_refs = a_work.get("referenced_works") or []
                    pool_size += len(a_refs)
                    batch = a_refs[:limit]
                    if batch:
                        ids_param = "|".join(r.rsplit("/", 1)[-1] for r in batch)
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

    seen = set()
    deduped = []
    for r in results:
        pid = r.get("paperId")
        if pid and pid not in seen:
            seen.add(pid)
            deduped.append(r)
    results = deduped

    if k:
        results = results[:k]

    return {"success": True, "results": results, "poolSize": pool_size}


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


def developer_github_query(
    query: str,
    repos: Optional[List[str]],
    language: Optional[str],
    topics: Optional[List[str]],
    license_name: Optional[str],
    min_stars: Optional[int],
    max_stars: Optional[int],
    archived: Optional[bool],
    fork: Optional[bool],
    skills: Optional[str],
) -> str:
    parts = [query.strip()]
    for repo in repos or []:
        if repo.strip():
            parts.append(f"repo:{repo.strip()}")
    if language:
        parts.append(f"language:{language}")
    for topic in topics or []:
        if topic.strip():
            parts.append(f"topic:{topic.strip()}")
    if license_name:
        parts.append(f"license:{license_name}")
    if min_stars is not None:
        parts.append(f"stars:>={min_stars}")
    if max_stars is not None:
        parts.append(f"stars:<={max_stars}")
    if archived is not None:
        parts.append(f"archived:{str(archived).lower()}")
    if fork is not None:
        parts.append(f"fork:{str(fork).lower()}")
    if skills == "only":
        parts.append("path:skills")
    return " ".join(parts)


async def github_json(client: httpx.AsyncClient, path: str, params: dict) -> dict:
    try:
        response = await client.get(
            f"{GITHUB_BASE}{path}",
            params=params,
            headers=gh_headers(),
        )
        if response.status_code == 200:
            return response.json()
    except Exception:
        pass
    return {}


async def code_passage(client: httpx.AsyncClient, item: dict) -> str:
    repository = (item.get("repository") or {}).get("full_name", "")
    path = item.get("path", "")
    if repository and path:
        try:
            response = await client.get(
                f"{GITHUB_BASE}/repos/{repository}/contents/{quote(path, safe='/')}",
                headers={**gh_headers(), "Accept": "application/vnd.github.raw"},
            )
            if response.status_code == 200 and response.text.strip():
                return response.text[:2400]
        except Exception:
            pass
    return f"{repository}/{path}".strip("/")


@app.get("/v2/code/search")
async def search_developer(
    query: str = Query(..., min_length=1),
    k: Optional[int] = Query(None, ge=1, le=100),
    types: Optional[List[str]] = Query(None),
    repos: Optional[List[str]] = Query(None),
    sources: Optional[List[str]] = Query(None),
    passages: Optional[int] = Query(None, ge=1, le=5),
    language: Optional[str] = Query(None, min_length=1),
    topic: Optional[List[str]] = Query(None),
    license: Optional[str] = Query(None, min_length=1),
    min_stars: Optional[int] = Query(None, ge=0),
    max_stars: Optional[int] = Query(None, ge=0),
    archived: Optional[bool] = Query(None),
    fork: Optional[bool] = Query(None),
    skills: Optional[str] = Query(None),
):
    """Provide a local developer-search surface using the GitHub API."""
    limit = min(k or 10, 100)
    requested_types = {value.lower() for value in (types or [])}
    source_values = {value.lower() for value in (sources or [])}
    github_requested = not source_values or "github" in source_values
    include_code = not requested_types or "code" in requested_types
    include_issues = not requested_types or bool(
        requested_types & {"issue", "issues", "pull_request", "pr"}
    )
    include_repositories = not requested_types or bool(
        requested_types & {"repository", "repo", "readme", "docs"}
    )
    if not github_requested:
        return {"success": True, "results": []}

    github_query = developer_github_query(
        query,
        repos,
        language,
        topic,
        license,
        min_stars,
        max_stars,
        archived,
        fork,
        skills,
    )
    search_limit = min(max(limit, 10), 100)
    search_tasks = []
    search_kinds = []
    if include_code:
        search_tasks.append(
            ("code", "/search/code", {"q": github_query, "per_page": search_limit})
        )
        search_kinds.append("code")
    if include_issues:
        search_tasks.append(
            ("issues", "/search/issues", {"q": github_query, "per_page": search_limit})
        )
        search_kinds.append("issues")
    if include_repositories:
        search_tasks.append(
            (
                "repositories",
                "/search/repositories",
                {"q": github_query, "per_page": search_limit},
            )
        )
        search_kinds.append("repositories")

    results = []
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        payloads = await asyncio.gather(
            *(github_json(client, path, params) for _, path, params in search_tasks)
        )
        for kind, payload in zip(search_kinds, payloads):
            items = payload.get("items", []) if isinstance(payload, dict) else []
            if kind == "code":
                passages_text = await asyncio.gather(
                    *(code_passage(client, item) for item in items[:limit])
                )
                for item, passage in zip(items[:limit], passages_text):
                    repository = (item.get("repository") or {}).get("full_name", "")
                    path = item.get("path", "")
                    results.append(
                        {
                            "id": f"github:code:{repository}:{path}",
                            "type": "code",
                            "title": f"{repository}/{path}".strip("/"),
                            "url": item.get("html_url", ""),
                            "passages": [{"text": passage}],
                        }
                    )
            elif kind == "issues":
                for item in items[:limit]:
                    is_pr = "pull_request" in item
                    body = (item.get("body") or item.get("title") or "").strip()
                    results.append(
                        {
                            "id": f"github:{'pr' if is_pr else 'issue'}:{item.get('id', '')}",
                            "type": "pull_request" if is_pr else "issue",
                            "title": item.get("title", ""),
                            "url": item.get("html_url", ""),
                            "passages": [{"text": body[:2400]}],
                        }
                    )
            else:
                for item in items[:limit]:
                    description = (item.get("description") or "").strip()
                    results.append(
                        {
                            "id": f"github:repo:{item.get('id', '')}",
                            "type": "repository",
                            "title": item.get("full_name", ""),
                            "url": item.get("html_url", ""),
                            "passages": [{"text": description or item.get("name", "")}],
                        }
                    )

    return {"success": True, "results": results[:limit]}


async def find_passages(result: dict, work: dict, question: str, num_passages: int) -> list:
    arxiv_id = get_arxiv_id_from_ids(result.get("ids", {}))
    pdf_url = None

    open_access = work.get("open_access") or {}
    oa_url = open_access.get("oa_url")
    if oa_url and "arxiv.org" in oa_url:
        pdf_url = oa_url.replace("/abs/", "/pdf/") + ".pdf"

    if not pdf_url and arxiv_id:
        pdf_url = f"https://arxiv.org/pdf/{arxiv_id}.pdf"

    if not pdf_url:
        locations = work.get("locations") or []
        for loc in locations:
            pdf = loc.get("pdf_url")
            if pdf and pdf.endswith(".pdf"):
                pdf_url = pdf
                break

    if not pdf_url:
        return []

    try:
        async with httpx.AsyncClient(timeout=300.0, follow_redirects=True) as client:
            resp = await client.get(pdf_url)
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
    return [p for _, p in scored if scored[0][0] > 0] or passages


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
