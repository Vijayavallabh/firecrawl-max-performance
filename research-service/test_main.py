import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from main import (  # noqa: E402
    build_github_code_query,
    normalize_title,
    oa_to_result,
    parse_paper_reference,
    rank_passages,
)


class ResearchHelpersTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
