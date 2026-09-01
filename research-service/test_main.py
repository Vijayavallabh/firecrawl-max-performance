import os
import sys
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).parent))

import main  # noqa: E402

from main import (  # noqa: E402
    ARXIV_STOP_WORDS,
    build_github_code_query,
    arxiv_entry_to_result,
    bounded_env_number,
    normalize_title,
    normalize_developer_types,
    oa_to_result,
    parse_paper_reference,
    rank_passages,
    similarity_semantic_score,
)


class ResearchHelpersTest(unittest.TestCase):
    def test_related_paper_semantics_reject_unrelated_syndrome_noise(self):
        intent = "causal genes and mechanisms of mosaic variegated aneuploidy syndrome"
        relevant = {
            "title": "Biallelic TRIP13 mutations predispose to chromosome missegregation",
            "abstract": "Mosaic variegated aneuploidy caused by a spindle checkpoint defect.",
        }
        unrelated = {
            "title": "A novel ZNF699 mutation in DEGCAGS syndrome",
            "abstract": "An immunological characterization of B cell depletion.",
        }
        self.assertGreater(similarity_semantic_score(relevant, intent), 1)
        self.assertEqual(similarity_semantic_score(unrelated, intent), 0)

    def test_identifier_parser_accepts_supported_reference_forms(self):
        cases = {
            "arxiv:1706.03762v1": "arxiv:1706.03762v1",
            "1706.03762": "arxiv:1706.03762",
            "https://arxiv.org/pdf/1706.03762v1.pdf": "arxiv:1706.03762v1",
            "doi:10.1000/a/b": "doi:10.1000/a/b",
            "10.1000/a/b": "doi:10.1000/a/b",
            "PMCID:PMC123": "pmcid:PMC123",
            "https://pubmed.ncbi.nlm.nih.gov/12345/": "pmid:12345",
            "OpenAlex:W123": "openalex:W123",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(parse_paper_reference(value)["canonical"], expected)

    def test_openalex_result_has_canonical_and_lowercase_ids(self):
        result = oa_to_result(
            {
                "id": "https://openalex.org/W123",
                "doi": "https://doi.org/10.1000/a/b",
                "title": "A paper",
                "abstract_inverted_index": {"attention": [0], "works": [1]},
                "ids": {"openalex": "https://openalex.org/W123"},
                "locations": [],
                "authorships": [],
                "concepts": [],
                "cited_by_count": 3,
            }
        )
        self.assertEqual(result["paperId"], "openalex:W123")
        self.assertEqual(result["primaryId"], "doi:10.1000/a/b")
        self.assertEqual(result["ids"]["doi"], ["10.1000/a/b"])
        self.assertEqual(result["score"], 0)

    def test_passage_scores_are_normalized(self):
        ranked = rank_passages(
            ["attention works here with useful detail " * 12, "unrelated text " * 30],
            "attention detail",
        )
        self.assertEqual(ranked[0][1].split()[0], "attention")
        self.assertEqual(ranked[0][0], 1.0)

    def test_github_query_uses_only_code_search_qualifiers(self):
        query = build_github_code_query(
            "browser",
            language="python",
            repos=["owner/repo"],
            topic=[f"topic{i}" for i in range(8)],
        )
        self.assertEqual(query, "browser repo:owner/repo language:python")
        with self.assertRaises(ValueError):
            build_github_code_query("browser", repos=["owner/one", "owner/two"])
        self.assertEqual(normalize_title("A/B: Paper!"), "a b paper")

    def test_developer_type_aliases_normalize_to_public_contract(self):
        self.assertEqual(
            normalize_developer_types(["docs", "issues", "prs", "repo_readme", "code"]),
            {"doc", "issue", "pull_request", "readme", "code"},
        )

    def test_arxiv_entry_conversion_preserves_canonical_identifiers(self):
        entry = ET.fromstring(
            """<entry xmlns=\"http://www.w3.org/2005/Atom\"><id>http://arxiv.org/abs/1706.03762</id><title> Attention Is All You Need </title><summary> Transformer architecture </summary><published>2017-06-12T00:00:00Z</published><updated>2017-06-12T00:00:00Z</updated><author><name>A. Author</name></author><category term=\"cs.CL\" /></entry>"""
        )
        result = arxiv_entry_to_result(entry)
        self.assertEqual(result["paperId"], "arxiv:1706.03762")
        self.assertEqual(result["title"], "Attention Is All You Need")

    def test_invalid_paper_search_limits_fall_back_to_defaults(self):
        with patch.dict(os.environ, {"TEST_BAD_LIMIT": "not-a-number"}):
            self.assertEqual(bounded_env_number("TEST_BAD_LIMIT", 10, 1, 50, int), 10)

    def test_arxiv_fallback_keeps_meaningful_query_terms(self):
        terms = [
            term.lower()
            for term in "API tool use benchmark for large language model agents".split()
            if len(term) > 2 and term.lower() not in ARXIV_STOP_WORDS
        ]
        self.assertEqual(terms, ["api", "tool", "language", "agents"])


class InstitutionalFullTextTests(unittest.TestCase):
    def setUp(self):
        self.original_domains = main.INSTITUTIONAL_ALLOWED_DOMAINS
        main.INSTITUTIONAL_ALLOWED_DOMAINS = {"nature.com", "academic.oup.com"}

    def tearDown(self):
        main.INSTITUTIONAL_ALLOWED_DOMAINS = self.original_domains

    def test_credentials_are_limited_to_allowlisted_publishers(self):
        self.assertTrue(main.institutional_domain_allowed("https://www.nature.com/articles/example"))
        self.assertTrue(main.institutional_domain_allowed("https://academic.oup.com/paper.pdf"))
        self.assertFalse(main.institutional_domain_allowed("https://nature.com.attacker.test/paper"))
        self.assertFalse(main.institutional_domain_allowed("https://doi.org/10.1/example"))

    def test_discovers_standard_citation_pdf_metadata(self):
        html = '<meta name="citation_pdf_url" content="/content/paper.pdf"><a href="supplement.txt">x</a>'
        self.assertEqual(
            main.publisher_pdf_links(html, "https://www.nature.com/article"),
            ["https://www.nature.com/content/paper.pdf"],
        )

    def test_rejects_login_html_masquerading_as_a_pdf(self):
        self.assertFalse(main.looks_like_pdf(b"<html>institutional login</html>", "text/html"))
        self.assertTrue(main.looks_like_pdf(b"%PDF-1.7 fixture", "application/pdf"))


class BoundedFetchTests(unittest.IsolatedAsyncioTestCase):
    async def test_cookie_is_sent_only_to_allowlisted_domain(self):
        original_domains = main.INSTITUTIONAL_ALLOWED_DOMAINS
        main.INSTITUTIONAL_ALLOWED_DOMAINS = {"nature.com"}
        seen = []

        async def handler(request):
            seen.append((request.url.host, request.headers.get("cookie")))
            return httpx.Response(200, content=b"%PDF-fixture", headers={"content-type": "application/pdf"})

        cookies = httpx.Cookies()
        cookies.set("session", "fixture", domain="nature.com", path="/")
        try:
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                with patch.object(main, "institutional_cookies", return_value=cookies):
                    await main.bounded_get(client, "https://nature.com/paper", use_institutional_cookies=True)
                    await main.bounded_get(client, "https://attacker.test/paper", use_institutional_cookies=True)
        finally:
            main.INSTITUTIONAL_ALLOWED_DOMAINS = original_domains

        self.assertEqual(seen, [("nature.com", "session=fixture"), ("attacker.test", None)])

    async def test_declared_oversize_response_is_not_downloaded(self):
        async def handler(request):
            return httpx.Response(
                200,
                content=b"not consumed",
                headers={"content-length": str(main.INSTITUTIONAL_MAX_DOWNLOAD_BYTES + 1)},
            )

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            content, _, _ = await main.bounded_get(client, "https://example.org/large.pdf")
        self.assertEqual(content, b"")


if __name__ == "__main__":
    unittest.main()
