"""The seven tools, called the way a practitioner's assistant calls them.

Everything here goes through a real MCP client to the mounted server, and from
there over loopback to dairy-api. That is the whole delivery path issue #56
exists to prove, so nothing is stubbed.

The two prediction tools run a real simulation, so they are slow. Their mapping
and their response reshaping are covered without R in test_mcp_facility.py and
test_mcp_response.py; what is left for here is that the two halves meet over the
wire. The runs below are deliberately tiny for that reason.
"""

import json

import jsonschema
import pytest
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

FULL_SAMPLE = {
    "spc_d7": 2.1, "spc_d14": 4.7, "spc_d21": 6.4,
    "tgn_d7": 1.0, "tgn_d14": 3.7, "tgn_d21": 5.3,
}

# Small enough to keep the suite usable, and a horizon short enough that the
# shipped 8.25-day supply chain still finishes inside it. n_units = 3 is
# deliberate: a lot's percentage is 100 * spoiled / n_units, so a divisor of 100
# always terminates and would hide a rounding mismatch between daily_spoilage and
# the retail-exit figure.
TINY_RUN = {"seed": 42, "lots": 2, "containers_per_lot": 3, "days": 12}


async def call(base_url: str, tool: str, arguments: dict | None = None):
    async with streamable_http_client(f"{base_url}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool, arguments or {})
    assert not result.isError, result.content
    return result


def text_of(result) -> str:
    return result.content[0].text


def data_of(result) -> dict:
    return result.structuredContent or json.loads(text_of(result))


# ---------------------------------------------------------------------------
# The schema every tool presents before it is called
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_every_tool_declares_itself_read_only(live_server):
    """Annotations are a Directory review requirement, and they drive auto-approve.

    Nothing here writes, deletes or stores anything -- the two tools that POST
    are running inference. A host that cannot see that asks the practitioner to
    approve every call.
    """
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()

    for tool in listed.tools:
        assert tool.annotations is not None, f"{tool.name} carries no annotations"
        assert tool.annotations.readOnlyHint is True, tool.name
        assert tool.annotations.destructiveHint is False, tool.name
        assert tool.title, f"{tool.name} carries no title"


@pytest.mark.anyio
async def test_no_tool_description_instructs_the_model(live_server):
    """Review criteria treat "you must call X first" in a description as injection.

    The instruction is not lost: ADR 011 puts it in the router, which is read on
    every question, and in the server's own `instructions` field. A tool
    description says what the tool returns.
    """
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()

    imperatives = ("call this first", "you must", "always call", "before you answer")
    for tool in listed.tools:
        lowered = (tool.description or "").lower()
        found = [phrase for phrase in imperatives if phrase in lowered]
        assert not found, f"{tool.name} instructs the model: {found}"


@pytest.mark.anyio
async def test_a_plate_count_is_bounded_to_a_log10_figure(live_server):
    """A raw CFU count is rejected here, before it reaches /classify at all.

    The endpoint bounds the same field to the same constant now (issue #60
    finding 1), so this is the outer of two gates rather than the only one. It
    is still the gate worth having: rejecting at the schema names the field to
    the agent, and costs no HTTP call.
    """
    raw_counts = {name: value * 1e6 for name, value in FULL_SAMPLE.items()}
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool("type_one_sample", raw_counts)
    assert result.isError
    assert "spc_d7" in str(result.content)


# The two tools that serve prose. FastMCP wraps a `str` return as
# `{"result": {"type": "string"}}`, which is an honest description of a tool
# that returns a document -- so these are held to that shape rather than to the
# field-by-field one below.
TEXT_TOOLS = {"read_guidance", "explain_calculations"}


@pytest.mark.anyio
async def test_every_structured_tool_describes_what_it_returns(live_server):
    """Declaring a schema is not the bar. Declaring an informative one is.

    A tool annotated `-> dict[str, Any]` does emit an outputSchema, so presence
    proves nothing: it emits `{"type": "object", "additionalProperties": true}`,
    which validates any object whatsoever. A client can no more check a response
    against that than against no schema at all. Issue #60 finding 2 was that the
    three typing tools declared exactly that.
    """
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()

    for tool in listed.tools:
        schema = tool.outputSchema
        assert schema, f"{tool.name} declares no outputSchema"
        assert schema["type"] == "object", tool.name
        if tool.name in TEXT_TOOLS:
            assert schema["properties"]["result"]["type"] == "string", tool.name
            continue
        fields = schema.get("properties") or {}
        assert fields, f"{tool.name} declares an object with no fields"
        assert list(fields) != ["result"], (
            f"{tool.name} is wrapped rather than typed -- return a single model, "
            "not a union or a bare list"
        )
        assert not schema.get("additionalProperties"), (
            f"{tool.name} still returns dict[str, Any]"
        )


@pytest.mark.anyio
async def test_what_a_tool_returns_validates_against_what_it_declared(live_server):
    """The schema is only worth declaring if the response actually conforms.

    Covers the tools that answer in under a second. The two prediction tools
    run a real simulation and are typed by test_mcp_response.py.
    """
    exercise = {
        "list_classifier_models": {},
        "type_one_sample": FULL_SAMPLE,
        "type_lot_samples": {"lot_id": "L-schema", "samples": [FULL_SAMPLE]},
    }
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            declared = {t.name: t.outputSchema for t in (await session.list_tools()).tools}
            for name, arguments in exercise.items():
                result = await session.call_tool(name, arguments)
                assert not result.isError, result.content
                assert result.structuredContent is not None, name
                jsonschema.validate(result.structuredContent, declared[name])


@pytest.mark.anyio
async def test_a_tool_that_could_not_classify_still_matches_its_schema(live_server):
    """The no-variant branch is a different shape, and it is the one that drifts.

    It is returned rather than raised, so nothing else would catch it going out
    of shape.
    """
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            declared = {t.name: t.outputSchema for t in (await session.list_tools()).tools}
            one = await session.call_tool("type_one_sample", {"spc_d7": 2.1})
            lot = await session.call_tool(
                "type_lot_samples", {"lot_id": "L-4", "samples": [{"spc_d7": 2.1}]}
            )

    jsonschema.validate(one.structuredContent, declared["type_one_sample"])
    jsonschema.validate(lot.structuredContent, declared["type_lot_samples"])
    assert one.structuredContent["classified"] is False
    assert lot.structuredContent["classified"] is False


@pytest.mark.anyio
async def test_the_schema_names_the_unit_a_plate_count_is_in(live_server):
    """The bound is the backstop. The description is what prevents the call."""
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()

    by_name = {tool.name: tool for tool in listed.tools}
    spc_d7 = by_name["type_one_sample"].inputSchema["properties"]["spc_d7"]
    assert "log10 CFU/mL" in json.dumps(spc_d7)

    route = by_name["read_guidance"].inputSchema["properties"]["route"]
    assert "spoilage typing" in json.dumps(route)


# ---------------------------------------------------------------------------
# read_guidance — bundled files, no API call
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_read_guidance_returns_a_route_file(live_server):
    assert text_of(await call(live_server, "read_guidance", {"route": 1})).startswith(
        "# Route 1"
    )


@pytest.mark.anyio
async def test_read_guidance_returns_a_reference_document(live_server):
    assert "VSL" in text_of(
        await call(live_server, "read_guidance", {"document": "vsl-program"})
    )


@pytest.mark.anyio
async def test_read_guidance_with_no_argument_indexes_what_it_serves(live_server):
    index = text_of(await call(live_server, "read_guidance"))
    assert "route=1" in index
    assert "document=vsl-program" in index


# ---------------------------------------------------------------------------
# list_classifier_models — the only source of an accuracy figure
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_list_classifier_models_returns_ten_sorted_by_accuracy(live_server):
    data = data_of(await call(live_server, "list_classifier_models"))
    assert data["total_variants"] == 10
    accuracies = [v["test_accuracy"] for v in data["variants"]]
    assert accuracies == sorted(accuracies, reverse=True)


@pytest.mark.anyio
async def test_list_classifier_models_carries_the_published_comparison(live_server):
    """ADR 013's two figures, both reachable. Issue #42 was these going missing."""
    top = data_of(await call(live_server, "list_classifier_models"))["variants"][0]
    assert top["published_test_accuracy"] is not None
    assert "unresolved" in top["accuracy_note"]


# ---------------------------------------------------------------------------
# type_one_sample — the walk, end to end
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_a_full_measurement_set_uses_the_top_variant(live_server):
    data = data_of(await call(live_server, "type_one_sample", FULL_SAMPLE))
    assert data["classified"] is True
    assert data["variant"]["variant_id"] == "baseline"
    assert data["prediction"] in ("PPC", "no spoilage", "spore spoilage")
    assert 0.0 <= data["confidence"] <= 1.0
    assert len(data["probabilities"]) == 3
    # Nothing sits above the top-ranked variant, so there is no comparison to make.
    assert data["next_best_variant"] is None


@pytest.mark.anyio
async def test_a_thinner_set_prices_the_missing_measurement(live_server):
    data = data_of(
        await call(live_server, "type_one_sample", {"spc_d7": 2.1, "spc_d14": 4.7})
    )
    assert data["classified"] is True
    assert data["variant"]["variant_id"] == "scenario_8_spc_7_14"
    above = data["next_best_variant"]
    assert above["variant_id"] == "scenario_6_spc_all"
    assert above["needs"] == ["SPC at day 21"]


@pytest.mark.anyio
async def test_the_accuracy_reported_is_the_one_variants_returned(live_server):
    """Read from the call, never written into the tool. ADR 013."""
    served = {
        v["variant_id"]: v["test_accuracy"]
        for v in data_of(await call(live_server, "list_classifier_models"))["variants"]
    }
    data = data_of(await call(live_server, "type_one_sample", FULL_SAMPLE))
    assert data["variant"]["test_accuracy"] == served["baseline"]

    thin = data_of(
        await call(live_server, "type_one_sample", {"spc_d7": 2.1, "spc_d14": 4.7})
    )
    assert thin["variant"]["test_accuracy"] == served["scenario_8_spc_7_14"]
    assert thin["next_best_variant"]["test_accuracy"] == served["scenario_6_spc_all"]


@pytest.mark.anyio
async def test_no_variant_fits_names_the_missing_measurement_and_does_not_error(
    live_server,
):
    """SPC at day 7 alone reaches no shipped model.

    Classifying anyway returns a 400 from /classify, which turns a clear answer
    into an error. The useful answer is the one measurement in the way.
    """
    data = data_of(await call(live_server, "type_one_sample", {"spc_d7": 2.1}))
    assert data["classified"] is False
    assert data["missing_measurements"] == ["SPC at day 14"]
    assert data["nearest_variant"]["variant_id"] == "scenario_8_spc_7_14"
    assert "SPC at day 14" in data["reason"]


# ---------------------------------------------------------------------------
# type_lot_samples — prevalence stays a per-lot figure
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_a_lot_is_classified_in_one_call(live_server):
    data = data_of(
        await call(
            live_server,
            "type_lot_samples",
            {
                "lot_id": "L-2026-08-12",
                "samples": [
                    FULL_SAMPLE,
                    {**FULL_SAMPLE, "spc_d21": 3.0, "tgn_d21": 1.5},
                    {**FULL_SAMPLE, "spc_d14": 6.9, "tgn_d14": 6.1},
                ],
            },
        )
    )
    assert data["lot_id"] == "L-2026-08-12"
    assert data["classified"] is True
    assert data["n_samples"] == 3
    assert len(data["predictions"]) == 3
    assert data["ppc_count"] + data["non_ppc_count"] == 3
    assert data["ppc_prevalence"] == pytest.approx(data["ppc_count"] / 3)
    assert data["variant"]["variant_id"] == "baseline"


@pytest.mark.anyio
async def test_the_lot_runs_the_variant_its_thinnest_sample_supports(live_server):
    """One variant runs over the whole lot, so a gap in one sample binds them all."""
    data = data_of(
        await call(
            live_server,
            "type_lot_samples",
            {
                "lot_id": "L-1",
                "samples": [
                    FULL_SAMPLE,
                    {"spc_d7": 2.0, "spc_d14": 4.4, "tgn_d7": 0.9, "tgn_d14": 3.1},
                ],
            },
        )
    )
    assert data["classified"] is True
    assert data["variant"]["variant_id"] == "scenario_4_day14"


@pytest.mark.anyio
async def test_a_lot_that_reaches_no_variant_names_the_gap(live_server):
    data = data_of(
        await call(
            live_server,
            "type_lot_samples",
            {"lot_id": "L-2", "samples": [{"spc_d7": 2.1}, FULL_SAMPLE]},
        )
    )
    assert data["lot_id"] == "L-2"
    assert data["classified"] is False
    assert data["missing_measurements"] == ["SPC at day 14"]


@pytest.mark.anyio
async def test_an_unclassified_lot_reports_no_prevalence_rather_than_zero(live_server):
    """A prevalence of 0.0 here would be a claim about clean product.

    `ppc_prevalence` is what shelf-life prediction consumes as a per-lot input,
    so a placeholder zero does not read as "unknown" -- it reads as a lot with
    no PPC in it. Null is the only honest value when nothing was classified.
    The sample count still comes back, because the lot does have samples.
    """
    data = data_of(
        await call(
            live_server,
            "type_lot_samples",
            {"lot_id": "L-5", "samples": [{"spc_d7": 2.1}, {"spc_d7": 3.4}]},
        )
    )
    assert data["classified"] is False
    assert data["ppc_prevalence"] is None
    assert data["ppc_count"] is None
    assert data["non_ppc_count"] is None
    # The one count that is known, and reporting 0 would describe an empty lot --
    # a state this tool raises on rather than returns.
    assert data["n_samples"] == 2
    assert "no prevalence" in data["predictions_note"]


def _lot(n: int) -> list[dict]:
    """n distinguishable samples, drifting upwards so the calls are not all equal."""
    return [
        {name: value + i * 0.01 for name, value in FULL_SAMPLE.items()}
        for i in range(n)
    ]


@pytest.mark.anyio
async def test_a_hundred_sample_lot_truncates_its_predictions(live_server):
    """100 prediction objects into a context window, for a per-lot figure.

    What route 2 consumes from this tool is `ppc_prevalence`. The per-sample
    predictions matter for a handful and are noise for a hundred. Issue #60
    finding 3.
    """
    data = data_of(
        await call(
            live_server, "type_lot_samples", {"lot_id": "L-100", "samples": _lot(100)}
        )
    )
    assert data["predictions_truncated"] is True
    assert len(data["predictions"]) == 10
    assert data["predictions_returned"] == 10
    assert "10 of 100" in data["predictions_note"]


@pytest.mark.anyio
async def test_a_truncated_lot_still_counts_every_sample(live_server):
    """The cap hides predictions. It must not touch the counts or the prevalence."""
    data = data_of(
        await call(
            live_server, "type_lot_samples", {"lot_id": "L-100", "samples": _lot(100)}
        )
    )
    assert data["n_samples"] == 100
    assert data["ppc_count"] + data["non_ppc_count"] == 100
    assert data["ppc_prevalence"] == pytest.approx(data["ppc_count"] / 100)
    # The prevalence is over the lot, not over the ten predictions shown.
    shown = sum(1 for p in data["predictions"] if p["prediction"] == "PPC")
    assert data["ppc_count"] >= shown


@pytest.mark.anyio
async def test_a_prediction_carries_the_index_of_the_sample_it_describes(live_server):
    """Truncation makes position meaningless, so the position has to be stated.

    Without it "showing 10 of 100" cannot be mapped back to a worksheet row.
    """
    data = data_of(
        await call(
            live_server, "type_lot_samples", {"lot_id": "L-100", "samples": _lot(100)}
        )
    )
    assert [p["sample_index"] for p in data["predictions"]] == list(range(10))


@pytest.mark.anyio
async def test_the_prediction_cap_can_be_raised(live_server):
    """A processor asking which samples came back PPC gets an answer."""
    data = data_of(
        await call(
            live_server,
            "type_lot_samples",
            {"lot_id": "L-40", "samples": _lot(40), "max_predictions": 40},
        )
    )
    assert data["predictions_truncated"] is False
    assert len(data["predictions"]) == 40
    assert data["predictions_returned"] == 40


@pytest.mark.anyio
async def test_a_lot_inside_the_cap_is_not_reported_as_truncated(live_server):
    """The common case -- a handful of samples -- is unchanged and says so."""
    data = data_of(
        await call(
            live_server, "type_lot_samples", {"lot_id": "L-3", "samples": _lot(3)}
        )
    )
    assert data["predictions_truncated"] is False
    assert data["predictions_returned"] == 3
    assert len(data["predictions"]) == 3
    assert "3 of 3" not in data["predictions_note"]


@pytest.mark.anyio
async def test_an_empty_lot_is_an_error(live_server):
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(
                "type_lot_samples", {"lot_id": "L-3", "samples": []}
            )
    assert result.isError


# ---------------------------------------------------------------------------
# predict_default — intent 2, on the shipped cold chain
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_predict_default_answers_from_a_two_argument_call(live_server):
    """A plant manager with temperature logs and no laboratory data, answered."""
    data = data_of(await call(live_server, "predict_default", {"run": TINY_RUN}))

    assert data["scenario"]["seed"] == 42
    assert data["scenario"]["lots"] == 2
    assert data["scenario"]["horizon_days"] == 12
    # Medium is the shipped default, and the response states the two numbers
    # rather than only the name -- ADR 012.
    assert data["scenario"]["ppc_frequency_range"] == [0.40, 0.625]
    assert "medium" in data["scenario"]["ppc_frequency_source"]

    assert [row["day"] for row in data["daily_spoilage"]] == list(range(0, 13))
    assert data["shelf_life"]["threshold_pct"] == 25
    assert data["shelf_life"]["horizon_days"] == 12
    # 40 KB of base64 an agent cannot display, dropped from every call.
    assert "plot" not in data


@pytest.mark.anyio
async def test_the_retail_exit_figure_comes_back_with_its_day(live_server):
    """Inside the horizon the run reads it off daily_spoilage, so the two agree."""
    data = data_of(await call(live_server, "predict_default", {"run": TINY_RUN}))
    retail = data["economics"]["pct_spoiled_at_retail"]

    assert retail["measured"] is True
    assert retail["evaluated_on_day"] == data["shelf_life"]["pre_consumer_day"]
    row = next(r for r in data["daily_spoilage"] if r["day"] == retail["evaluated_on_day"])
    assert row["median_pct"] == retail["percent"]


@pytest.mark.anyio
async def test_economics_returns_per_container_figures_beside_the_totals(live_server):
    data = data_of(await call(live_server, "predict_default", {"run": TINY_RUN}))
    economics = data["economics"]
    assert economics["containers_priced"] == 3
    assert economics["shelf_life_value_usd_per_container"] == pytest.approx(
        economics["shelf_life_value_usd"] / 3
    )
    assert economics["co2e_kg_per_container"] == pytest.approx(economics["co2e_kg"] / 3)


@pytest.mark.anyio
async def test_a_named_plant_category_resolves_to_a_published_band(live_server):
    data = data_of(
        await call(
            live_server,
            "predict_default",
            {"run": TINY_RUN, "plant_category": "long"},
        )
    )
    assert data["scenario"]["plant_category"] == "long"
    assert data["scenario"]["ppc_frequency_range"] == [0.125, 0.294]


@pytest.mark.anyio
async def test_a_shelf_life_past_the_horizon_returns_a_bound_not_minus_one(live_server):
    """A four-day horizon cannot reach the criterion, so both figures are bounds.

    The two bounds are different numbers: total shelf life is bounded by the
    horizon, consumer shelf life by the horizon less the supply-chain window.
    """
    data = data_of(
        await call(
            live_server, "predict_default", {"run": {**TINY_RUN, "days": 4}}
        )
    )
    assert data["shelf_life"]["truncated"] is True
    assert data["shelf_life"]["total_days"]["more_than_days"] == 4
    assert data["shelf_life"]["consumer_days"]["more_than_days"] < 4
    assert any("0" in note and "horizon" in note for note in data["notes"])


@pytest.mark.anyio
async def test_the_output_schema_types_a_shelf_life_as_a_number_or_a_bound(live_server):
    """#60 finding 2. A client can validate the two shapes rather than guess."""
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()

    for name in ("predict_default", "predict_customize"):
        tool = next(t for t in listed.tools if t.name == name)
        assert tool.outputSchema, name
        shelf_life = tool.outputSchema["$defs"]["ShelfLife"]
        assert len(shelf_life["properties"]["total_days"]["anyOf"]) == 2
        assert "Bound" in tool.outputSchema["$defs"]


# ---------------------------------------------------------------------------
# predict_customize — intent 2, on the processor's own cold chain
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_predict_customize_states_a_colder_stage_as_an_offset(live_server):
    """The worked failure: "our retail cases run at 4, not the 6.5 you assume".

    `temp_mean: 4.0` would replace the New York baseline's measured trace with a flat line. The
    run's own record has to show the offset instead.
    """
    data = data_of(
        await call(
            live_server,
            "predict_customize",
            {
                "run": TINY_RUN,
                "facility": {"stage_temperatures": {"retail": {"shift": -2.5}}},
            },
        )
    )
    applied = data["scenario"]["interventions_applied"]["stage_temp_overrides"]["retail"]
    assert applied == {"temp_delta": -2.5}
    assert any("within-stage" in note for note in data["notes"])


@pytest.mark.anyio
async def test_an_extra_leg_lands_in_the_runs_disruption_record_and_says_so(live_server):
    """A distribution centre is the processor's normal chain, not an incident."""
    data = data_of(
        await call(
            live_server,
            "predict_customize",
            {
                "run": TINY_RUN,
                "facility": {
                    "extra_legs": [
                        {
                            "after": "transportation_facility_to_retail",
                            "celsius": 5.0,
                            "days": 1.5,
                        }
                    ]
                },
            },
        )
    )
    applied = data["scenario"]["disruptions_applied"]
    assert applied["transportation_facility_to_retail"]["type"] == "delay"
    assert applied["transportation_facility_to_retail"]["temp"] == 5.0
    assert any("not an incident" in note for note in data["notes"])

    # The leg lengthened a pre-consumer stage, so this run evaluates retail exit
    # on its own day and the figure cannot be differenced against a baseline.
    assert data["comparability"]["pct_spoiled_at_retail_comparable"] is False
    assert data["comparability"]["stages_changed"] == [
        "transportation_facility_to_retail"
    ]


@pytest.mark.anyio
async def test_a_measured_leg_folds_at_its_growth_equivalent_temperature(live_server):
    data = data_of(
        await call(
            live_server,
            "predict_customize",
            {
                "run": TINY_RUN,
                "facility": {
                    "extra_legs": [
                        {
                            "after": "retail",
                            "readings": [
                                {"hours": 0, "celsius": 2.0},
                                {"hours": 6, "celsius": 20.0},
                                {"hours": 12, "celsius": 2.0},
                            ],
                        }
                    ]
                },
            },
        )
    )
    folded = data["scenario"]["disruptions_applied"]["retail"]
    assert folded["duration_delta"] == pytest.approx(0.5)
    assert folded["temp"] > 11.0  # the arithmetic mean of the three readings
    assert any("growth-equivalent" in note for note in data["notes"])


@pytest.mark.anyio
async def test_a_stage_needing_two_disruptions_is_rejected_with_both_named(live_server):
    """The API takes one disruption per stage, and a silent overwrite is worse."""
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(
                "predict_customize",
                {
                    "run": TINY_RUN,
                    "facility": {
                        "stage_temperatures": {"retail": {"shift": 2.0}},
                        "stage_durations": {"retail": 8.0},
                    },
                },
            )
    assert result.isError
    assert "one disruption" in str(result.content)


@pytest.mark.anyio
async def test_a_run_larger_than_the_call_will_wait_for_is_rejected(live_server):
    """A timeout names nothing. The bound names the size and the limit."""
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(
                "predict_default",
                {"run": {"seed": 1, "lots": 100, "containers_per_lot": 1000, "days": 120}},
            )
    assert result.isError
    assert "seconds" in str(result.content)


# ---------------------------------------------------------------------------
# model_an_intervention — intent 4
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_a_named_intervention_comes_back_with_the_level_it_resolved_to(
    live_server,
):
    """ADR 012: the response states the number rather than hiding it behind a name."""
    data = data_of(
        await call(
            live_server,
            "model_an_intervention",
            {
                "run": TINY_RUN,
                "intervention": {"named": ["increase_equipment_cleaning"]},
            },
        )
    )
    resolved = data["scenario"]["resolved_levels"][0]
    assert resolved["named"] == "increase_equipment_cleaning"
    assert resolved["parameter"] == "ppc_frequency_factor"
    assert resolved["level"] == 0.5
    assert "Lau" in resolved["source"]
    assert data["scenario"]["interventions_applied"]["ppc_frequency_factor"] == 0.5


@pytest.mark.anyio
async def test_an_intervention_reuses_the_facility_which_stays_optional(live_server):
    """Intent 4 always carries a change, so the plant description is optional."""
    data = data_of(
        await call(
            live_server,
            "model_an_intervention",
            {
                "run": TINY_RUN,
                "intervention": {"cool_stage": {"retail": {"by": 1.0}}},
                "facility": {"stage_temperatures": {"retail": {"shift": -2.5}}},
            },
        )
    )
    # Their retail runs at 4.0, so one degree colder is 3.0 -- a shift of -3.5
    # against the shipped baseline, not the -1.0 a naive reading would send.
    applied = data["scenario"]["interventions_applied"]["stage_temp_overrides"]
    assert applied["retail"]["temp_delta"] == pytest.approx(-3.5)


@pytest.mark.anyio
async def test_an_intervention_that_would_warm_a_stage_is_rejected(live_server):
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(
                "model_an_intervention",
                {
                    "run": TINY_RUN,
                    "intervention": {"cool_stage": {"retail": {"to": 9.0}}},
                },
            )
    assert result.isError
    assert "model_a_disruption" in str(result.content)


# ---------------------------------------------------------------------------
# model_a_disruption — intent 5
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_a_thermal_event_and_a_delay_on_two_stages_are_one_run(live_server):
    """The chiller tripping, then the load waiting for a truck. One scenario."""
    data = data_of(
        await call(
            live_server,
            "model_a_disruption",
            {
                "run": TINY_RUN,
                "disruption": {
                    "thermal_events": [
                        {"stage": "processing_facility", "celsius": 18.0, "days": 0.3}
                    ],
                    "delays": [
                        {
                            "stage": "transportation_facility_to_retail",
                            "days": 0.5,
                            "celsius": 12.0,
                        }
                    ],
                },
            },
        )
    )
    applied = data["scenario"]["disruptions_applied"]
    assert applied["processing_facility"]["type"] == "temp_spike"
    assert applied["processing_facility"]["temp"] == 18.0
    assert applied["transportation_facility_to_retail"]["type"] == "delay"
    assert applied["transportation_facility_to_retail"]["temp"] == 12.0

    # Both lengthen a pre-consumer stage, so retail exit moved and the figure
    # cannot be differenced against a baseline arm.
    assert data["comparability"]["pct_spoiled_at_retail_comparable"] is False
    assert any("lengthens it" in note for note in data["notes"])
    assert any("exact" in note for note in data["notes"])


@pytest.mark.anyio
async def test_two_events_on_one_stage_are_rejected_with_the_ranking(live_server):
    """The rejection carries the arithmetic, so the agent has nothing to skip."""
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(
                "model_a_disruption",
                {
                    "run": TINY_RUN,
                    "disruption": {
                        "thermal_events": [
                            {"stage": "retail", "celsius": 20.0, "days": 0.25}
                        ],
                        "delays": [
                            {"stage": "retail", "days": 1.0, "celsius": 6.0}
                        ],
                    },
                },
            )
    assert result.isError
    message = str(result.content)
    assert "-4.15" in message and "-3.62" in message
    assert "dominant event" in message
    assert "lower bound" in message and "upper bound" in message


@pytest.mark.anyio
async def test_the_two_change_tools_carry_an_output_schema_too(live_server):
    """Same typed response as the prediction tools -- #60 finding 2."""
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()

    for name in ("model_an_intervention", "model_a_disruption"):
        tool = next(t for t in listed.tools if t.name == name)
        assert tool.outputSchema, name
        assert "Resolved" in tool.outputSchema["$defs"], name


# ---------------------------------------------------------------------------
# explain_calculations
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_explain_calculations_returns_the_methods(live_server):
    methods = text_of(await call(live_server, "explain_calculations"))
    assert "shelf_life_value_usd" in methods
    assert "co2e_kg" in methods
