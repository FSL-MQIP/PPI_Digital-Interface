"""The milk-spoilage MCP server: intent-shaped tools over dairy-api.

ADR 015 names the tools for what a processor says rather than for the HTTP
endpoints behind them, and all nine are served here. Two endpoints deliberately
get none: /scenarios is redundant once three simulation tools carry narrow
schemas, because the schemas are the option list, and /health is operational
rather than processor-facing.

Mounted inside the dairy-api FastAPI app (ADR 016), so the host application's
lifespan has to enter `mcp.session_manager` -- see app.py. Without that the
first request fails, because a mounted ASGI app's own lifespan never runs.
"""

from __future__ import annotations

from typing import Any, Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from pydantic import BaseModel, Field

from mcp_server import api, guidance
from mcp_server.classification import (
    DEFAULT_MAX_PREDICTIONS,
    ClassifierModels,
    LotSamples,
    NearestVariant,
    OneSample,
    SampleType,
    predictions_note,
)
from mcp_server.disruption import Disruption
from mcp_server.facility import Facility, Run, plan
from mcp_server.intervention import Intervention
from mcp_server.response import Prediction, reshape
from mcp_server.supply_chain import PlantCategory
from mcp_server.variants import (
    measurement_label,
    nearest_miss,
    next_best,
    pick_variant,
    to_features,
)
# The bound lives beside the `10 **` that makes it load-bearing, and the
# /classify schema imports the same one. The tool is not the only surface a
# measurement arrives on, and a second literal here would drift silently.
from services.classifier import MAX_LOG10_COUNT

INSTRUCTIONS = """\
Decision support for fluid milk spoilage, from the milk-spoilage plugin.

Triage the question to an intent, then call read_guidance for that intent's
route file before answering. The route file holds the procedure, the parameters
and the limits. None of that is in these tool schemas.
"""

mcp = FastMCP(
    "milk-spoilage",
    instructions=INSTRUCTIONS,
    # Stateless: a free-tier Space sleeps and restarts, and a client holding a
    # session id across a restart would get a 404 mid-conversation. Nothing here
    # is server-initiated, so there is no session state worth keeping.
    stateless_http=True,
    # The path the route this builds carries, and the path the plugin's
    # .mcp.json points a client to. The two are the same string on purpose; see
    # the note in app.py on why the route is registered rather than mounted.
    streamable_http_path="/mcp",
    # DNS rebinding protection off, deliberately.
    #
    # FastMCP turns it on whenever its `host` setting is 127.0.0.1, which is the
    # default and which describes where FastMCP would bind if it ran on its own.
    # It says nothing about where this server is mounted. The allow-list it
    # builds is localhost-only, so the Space answered every request to /mcp with
    # "421 Invalid Host header" while every test here passed -- the tests reach
    # 127.0.0.1, which is on that list.
    #
    # The guard defends a server bound to a user's own machine against a browser
    # that an attacker's page tricked into calling it. ADR 016 puts this server
    # somewhere else: public by requirement, because Claude reaches it from
    # Anthropic's cloud rather than from the practitioner's device;
    # unauthenticated by decision; and holding nothing secret, since the tools
    # call a public API over a published model. There is no local network to
    # pivot into and no credential to take.
    #
    # Turn it back on, with allowed_hosts naming the deployment, if this endpoint
    # ever gains authentication or reaches data that is not already public.
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=False
    ),
)


# Every tool here reads. None writes, deletes or changes anything, and the two
# that POST are running inference rather than storing a sample. Stated so a host
# can auto-approve them instead of asking on every call.
READS = ToolAnnotations(
    readOnlyHint=True,
    destructiveHint=False,
    idempotentHint=True,
    # The tools reach one internal API over a published model, plus files
    # bundled beside them. Nothing open-ended.
    openWorldHint=False,
)


def _count(analyte: str, day: int) -> Any:
    """A plate-count field, described in the unit the model actually needs."""
    return Field(
        None,
        ge=0,
        le=MAX_LOG10_COUNT,
        description=(
            f"{analyte} at day {day}, in log10 CFU/mL. Convert before sending: a "
            f"plate count of 4,700,000 CFU/mL is 6.67. Omit when the lab did not "
            f"run this measurement."
        ),
    )


class Sample(BaseModel):
    """One sample's plate counts, in log10 CFU/mL. Omit what the lab did not run."""

    spc_d7: Optional[float] = _count("Standard Plate Count", 7)
    spc_d14: Optional[float] = _count("Standard Plate Count", 14)
    spc_d21: Optional[float] = _count("Standard Plate Count", 21)
    tgn_d7: Optional[float] = _count("Total Gram-Negative count", 7)
    tgn_d14: Optional[float] = _count("Total Gram-Negative count", 14)
    tgn_d21: Optional[float] = _count("Total Gram-Negative count", 21)


def _supplied(measurements: dict[str, Optional[float]]) -> dict[str, float]:
    return {name: value for name, value in measurements.items() if value is not None}


def _describe(entry: Optional[dict[str, Any]]) -> Optional[NearestVariant]:
    """A variant the lab cannot reach yet, and the measurements that would reach it.

    `test_accuracy` is copied out of the /variants response this call just made.
    No accuracy figure is written into this module -- ADR 013.
    """
    if entry is None:
        return None
    return NearestVariant(
        variant_id=entry["variant"]["variant_id"],
        name=entry["variant"]["name"],
        test_accuracy=entry["variant"]["test_accuracy"],
        needs=[measurement_label(f) for f in entry["missing"]],
    )


@mcp.tool(title="Read guidance", annotations=READS)
def read_guidance(
    route: Optional[int] = Field(
        None,
        ge=0,
        le=5,
        description=(
            "Intent number. 0 general information, 1 spoilage typing, 2 "
            "shelf-life prediction, 3 economics and environment, 4 prevention "
            "strategies, 5 disruption scenarios."
        ),
    ),
    document: Optional[str] = Field(
        None,
        description=(
            "Reference document name, with or without the .md suffix. Calling "
            "with no argument returns the list of names."
        ),
    ),
) -> str:
    """Return one route file or one reference document, as text.

    A route file holds the procedure for one intent: what to ask a processor
    for, which tool to call, which parameters carry their answer, and how to
    read the result. A reference document holds the published evidence behind
    one claim. With neither argument, returns the index of both.

    Serves bundled files. Reaches no model and no API.
    """
    if route is not None and document is not None:
        raise ValueError("Name a route or a document, not both.")
    if route is not None:
        return guidance.read_route(route)
    if document is not None:
        return guidance.read_document(document)
    return guidance.index()


@mcp.tool(title="List classifier models", annotations=READS)
async def list_classifier_models() -> ClassifierModels:
    """Return the ten shipped classifier variants, sorted by test accuracy.

    Highest first. Each variant carries the measurements it requires, the
    accuracy this artifact scores on the shipped test set, the paper's figure
    for the same variant name, and a note on why the two can differ. Every
    accuracy figure the plugin reports originates here; none is written into
    the tools or the skill.

    Does not classify anything. type_one_sample and type_lot_samples select a
    variant from this list themselves.
    """
    return ClassifierModels(**await api.get("/variants"))


@mcp.tool(title="Type one sample", annotations=READS)
async def type_one_sample(
    spc_d7: Optional[float] = _count("Standard Plate Count", 7),
    spc_d14: Optional[float] = _count("Standard Plate Count", 14),
    spc_d21: Optional[float] = _count("Standard Plate Count", 21),
    tgn_d7: Optional[float] = _count("Total Gram-Negative count", 7),
    tgn_d14: Optional[float] = _count("Total Gram-Negative count", 14),
    tgn_d21: Optional[float] = _count("Total Gram-Negative count", 21),
) -> OneSample:
    """Classify the spoilage type of a single milk sample from its plate counts.

    Three classes: PPC, spore spoilage, no spoilage. Takes only the measurements
    the lab ran, and selects the model from them -- it walks the variants from
    the most accurate down and uses the first whose every feature is present.

    Returns the predicted class, the three class probabilities, the confidence,
    the variant used with its accuracy, and the next variant up with the
    measurements that would reach it. When the measurements reach no variant,
    returns `classified: false` with the missing measurement named, rather than
    an error.

    Covers one sample. type_lot_samples covers a lot and returns its prevalence.
    """
    measurements = _supplied(
        {
            "spc_d7": spc_d7, "spc_d14": spc_d14, "spc_d21": spc_d21,
            "tgn_d7": tgn_d7, "tgn_d14": tgn_d14, "tgn_d21": tgn_d21,
        }
    )
    variants = (await api.get("/variants"))["variants"]
    have = to_features(measurements)

    selected = pick_variant(variants, have)
    if selected is None:
        return OneSample(**_no_variant_fits(variants, have))

    result = await api.post(
        "/classify", {**measurements, "model_variant": selected["variant_id"]}
    )
    return OneSample(
        classified=True,
        prediction=result["prediction"],
        probabilities=result["probabilities"],
        confidence=result["confidence"],
        variant=result["variant_used"],
        measurements_used=measurements,
        next_best_variant=_describe(next_best(variants, selected, have)),
    )


@mcp.tool(title="Type a lot's samples", annotations=READS)
async def type_lot_samples(
    lot_id: str = Field(
        description="The production batch these samples came from, as the processor names it."
    ),
    samples: list[Sample] = Field(
        description="Every sample from that one lot. Samples from a second lot are a second call."
    ),
    max_predictions: int = Field(
        DEFAULT_MAX_PREDICTIONS,
        ge=1,
        description=(
            "How many per-sample predictions to return, from the start of the "
            "lot. The counts and the prevalence always cover every sample "
            "whatever this is set to. Raise it when the processor asks about "
            "individual samples rather than about the lot."
        ),
    ),
) -> LotSamples:
    """Classify every sample from one lot, and return that lot's PPC prevalence.

    The prevalence returned describes the lot named in `lot_id`, and shelf-life
    prediction consumes it as a per-lot figure. A call carrying two lots would
    return a prevalence belonging to neither.

    One variant runs over the whole lot, selected from the measurements every
    sample carries, so a gap in one sample binds them all. Returns the lot's
    prevalence, its PPC and non-PPC counts, the variant used, and the per-sample
    predictions.

    Every sample is classified and counted. The per-sample predictions are
    capped by `max_predictions`, and the response says how many of how many it
    is showing.
    """
    if not samples:
        raise ValueError(f"Lot {lot_id!r} carries no samples.")

    measurements = [_supplied(sample.model_dump()) for sample in samples]
    variants = (await api.get("/variants"))["variants"]
    # A variant must run on every sample in the lot, so the lot has whatever its
    # thinnest sample has.
    have = set.intersection(*(set(to_features(m)) for m in measurements))

    selected = pick_variant(variants, have)
    if selected is None:
        # n_samples is carried across even though nothing classified: the lot has
        # the samples the caller sent, and reporting zero there would describe an
        # empty lot -- which is a state this tool raises on rather than returns.
        return LotSamples(
            lot_id=lot_id,
            n_samples=len(samples),
            predictions_note=predictions_note(0, 0),
            **_no_variant_fits(variants, have),
        )

    result = await api.post(
        "/classify/batch",
        {"samples": measurements, "model_variant": selected["variant_id"]},
    )
    summary = result["summary"]
    shown = [
        SampleType(sample_index=index, **prediction)
        for index, prediction in enumerate(result["predictions"][:max_predictions])
    ]
    return LotSamples(
        lot_id=lot_id,
        classified=True,
        n_samples=summary["total"],
        ppc_count=summary["ppc_count"],
        non_ppc_count=summary["non_ppc_count"],
        ppc_prevalence=summary["ppc_prevalence"],
        predictions=shown,
        predictions_returned=len(shown),
        predictions_truncated=len(shown) < summary["total"],
        predictions_note=predictions_note(len(shown), summary["total"]),
        variant=selected,
        next_best_variant=_describe(next_best(variants, selected, have)),
    )


@mcp.tool(title="Predict shelf life on the shipped cold chain", annotations=READS)
async def predict_default(
    run: Run,
    plant_category: Optional[PlantCategory] = Field(
        None,
        description=(
            "The processor's own shelf-life history, as one of the three "
            "categories Su et al. fitted PPC frequency bands to. Omitted, the run "
            "uses the medium band, which is the shipped default. The response "
            "states the two numbers whichever category is used."
        ),
    ),
) -> Prediction:
    """Predict shelf life on the measured New York cold chain, with no laboratory data.

    Runs the simulation over the five shipped stages at their measured
    temperatures and durations, and returns shelf life, the daily spoilage curve,
    the lot-to-lot spread, the shelf-life value and the emissions. Needs no plate
    counts: a plant manager with temperature logs and no laboratory work gets a
    full answer.

    Shelf life comes back as a number, or as a bound object when the lot never
    crossed the spoilage criterion inside the simulated horizon. Both economics
    figures describe one simulated lot and come with a per-container figure
    beside them.

    Answers on the shipped cold chain only. predict_customize takes a processor's
    own stage temperatures, stage durations and extra legs.

    Takes about 40 seconds at the default run size.
    """
    request = plan(run, Facility(plant_category=plant_category))
    return reshape(await api.post("/simulate", request.body), request)


@mcp.tool(title="Predict shelf life on the processor's own cold chain", annotations=READS)
async def predict_customize(facility: Facility, run: Run) -> Prediction:
    """Predict shelf life on a cold chain the processor describes themselves.

    Same simulation and same response as predict_default, over a chain stated as
    absolutes -- the temperature a stage runs at, the days product spends in it,
    the legs the five shipped stages do not have, and the PPC frequency the
    facility's own samples measured. Each statement is turned into the parameter
    that carries it: a stage colder or shorter than the baseline reaches the
    simulation one way and a stage warmer or longer the other, and the response
    records which.

    Returns what predict_default returns, plus what answering had to assume:
    which published band the PPC bounds came from, at what temperature a measured
    leg folded, and which parts of the answer remain the New York baseline's
    rather than the processor's.

    predict_default is the two-argument call for the shipped chain.

    Takes about 40 seconds at the default run size.
    """
    request = plan(run, facility)
    return reshape(await api.post("/simulate", request.body), request)


@mcp.tool(title="Model an intervention", annotations=READS)
async def model_an_intervention(
    run: Run, intervention: Intervention, facility: Optional[Facility] = None
) -> Prediction:
    """Predict shelf life under a change for the better, to weigh against the baseline.

    Interventions are improvements only: spore removal, PPC frequency and load
    reductions, removing a sequence type, and running a stage colder or under a
    ceiling. A change that makes an outcome worse is model_a_disruption, and how
    the plant already runs is `facility` rather than an intervention.

    Named levers resolve to the level Lau et al. (2022) fitted, and the response
    states that level, the plant action behind it and the publication, in
    `scenario.resolved_levels`. A level the processor measured themselves can be
    passed directly and outranks any published one.

    Returns what predict_default returns, over the intervention run only. Pricing
    a change takes two runs -- this one and a baseline at the same seed -- and
    the response carries the seed and the comparability verdict for that
    comparison.

    Takes about 40 seconds at the default run size.
    """
    request = plan(run, facility, intervention=intervention)
    return reshape(await api.post("/simulate", request.body), request)


@mcp.tool(title="Model a disruption", annotations=READS)
async def model_a_disruption(
    run: Run, disruption: Disruption, facility: Optional[Facility] = None
) -> Prediction:
    """Predict shelf life under an adverse event, to weigh against the baseline.

    Takes temperature abuse and delays together, on the stages they happened in,
    so a chiller tripping in one stage and a load then waiting for a truck in
    another is one run rather than two. A change for the better is
    model_an_intervention, and a plant that simply runs warm all the time is a
    `facility` statement rather than an event.

    A stage takes one event. A second event on the same stage is rejected with
    both ranked by `duration x (T - Tmin)^2` at the model's two reference
    temperatures, because merging them at their mean understates growth every
    time -- the growth rate squares the temperature displacement.

    Returns what predict_default returns, over the disruption run only, plus what
    the encoding approximated: temperature abuse appended to a stage lengthens
    it rather than replacing time inside it, while added delay time is exact.

    Takes about 40 seconds at the default run size.
    """
    request = plan(run, facility, disruption=disruption)
    return reshape(await api.post("/simulate", request.body), request)


@mcp.tool(title="Explain the calculations", annotations=READS)
async def explain_calculations() -> str:
    """Return how the shelf-life value and the CO2e figures are calculated.

    The formulas, the published source behind each constant, and a statement of
    which parts of the construction are this API's own rather than a cited
    result. Covers the economics only; it runs no simulation.
    """
    return (await api.get("/simulate/methods"))["methods"]


def _no_variant_fits(
    variants: list[dict[str, Any]], have: set[str]
) -> dict[str, Any]:
    """What to say when the walk found nothing.

    Not an error. Every variant raises on a missing feature, so classifying
    anyway would turn a clear answer into a 400 -- while the useful answer is
    the single measurement standing between the lab and a model.
    """
    near = _describe(nearest_miss(variants, have))
    reason = "These measurements reach no shipped model."
    if near:
        reason += (
            f" The nearest is {near.variant_id}, which also needs "
            + " and ".join(near.needs)
            + "."
        )
    return {
        "classified": False,
        "reason": reason,
        "missing_measurements": near.needs if near else [],
        "nearest_variant": near,
    }


# Built at import, for two reasons. The session manager is created lazily on the
# first call to streamable_http_app(), and app.py's lifespan has to enter it --
# so it must exist before the application starts. And this is where the route
# app.py registers comes from.
mcp_app = mcp.streamable_http_app()
