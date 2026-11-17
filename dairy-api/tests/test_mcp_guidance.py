"""read_guidance reads bundled files — the one tool that makes no API call."""

import pytest

from mcp_server import guidance


def test_every_intent_has_a_route_file():
    assert sorted(guidance.route_numbers()) == [0, 1, 2, 3, 4, 5]


def test_reading_a_route_returns_that_route_file():
    text = guidance.read_route(1)
    assert text.startswith("# Route 1")
    assert "spoilage typing" in text.lower()


def test_reading_a_document_returns_that_reference_file():
    text = guidance.read_document("vsl-program")
    assert "VSL" in text


def test_a_document_may_be_named_with_or_without_its_extension():
    assert guidance.read_document("vsl-program.md") == guidance.read_document("vsl-program")


def test_the_eleven_reference_documents_are_all_reachable():
    names = guidance.document_names()
    assert "spoilage-classification-model" in names
    assert "shelf-life-economics" in names
    # Eleven reference documents plus the README that records their provenance.
    assert len(names) == 12


def test_an_unknown_route_names_the_routes_that_exist():
    with pytest.raises(ValueError) as exc:
        guidance.read_route(9)
    assert "0" in str(exc.value) and "5" in str(exc.value)


def test_an_unknown_document_names_the_documents_that_exist():
    with pytest.raises(ValueError) as exc:
        guidance.read_document("no-such-thing")
    assert "vsl-program" in str(exc.value)


def test_the_index_lists_both_kinds():
    index = guidance.index()
    assert "1-spoilage-typing" in index
    assert "vsl-program" in index
