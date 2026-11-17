"""ClassifierService — loads scikit-learn model variants and runs 3-class inference."""

import json
from pathlib import Path
from typing import Any

import joblib
import numpy as np

# All possible features in canonical (uppercase) order
ALL_FEATURES = ["SPC_D7", "SPC_D14", "SPC_D21", "TGN_D7", "TGN_D14", "TGN_D21"]

# The variant every endpoint falls back to when the caller names none. Defined
# once and imported, rather than written literally at each default: /health has
# to know which variant is load-bearing, and a health check that disagrees with
# the routers about what "default" means is worse than no check at all.
DEFAULT_VARIANT = "baseline"

# A plate count above this is not a log10 figure. Defined here, beside the
# `10 **` that makes it load-bearing, and imported by every surface that takes a
# measurement -- the /classify schema and the MCP tools both. Two literals would
# drift, and the drift is invisible: the tool would go on rejecting a raw count
# while the endpoint behind it went back to answering one.
#
# The addressee is a QA manager reading a plate-count worksheet, so entering the
# count rather than its logarithm is the obvious mistake to make. Unbounded, that
# mistake landed in one of three regimes, measured against this service:
#
#   <= 38          200, and a confident prediction on nonsense
#   39 to 308      400, naming float32 rather than the field
#   >= 309         OverflowError, which no caller catches -- HTTP 500
#
# The 500 is the loud tip of it. The silent 200 is the same mistake one order of
# magnitude down, and it is the worse of the two, because a QA manager acts on it.
#
# 12 separates a log10 figure from a raw count without rejecting anything a lab
# can measure: the spoilage threshold is 6, and 12 is 10^12 CFU/mL.
MAX_LOG10_COUNT = 12.0

# Testing accuracy as PUBLISHED, from Table 1 of:
#   Jung, Qian, Trmcic, Martin et al. (2026). Developing machine learning models
#   for fluid milk spoilage classification. J. Dairy Sci.
#   https://doi.org/10.3168/jds.2025-28070
#
# Reported for comparison ONLY. Do not present it as this model's accuracy.
#
# What was measured, 2026-08-09: every shipped joblib was re-scored against the
# shipped test set (MilkSpoilageClassifier/data/test_df.csv, filtered per variant
# to rows carrying all its features). Every variant reproduced
# variants_config.json exactly, and none matched the paper except
# scenario_7_tgn_all, where the two coincide at 69.9%.
#
# What that establishes: variants_config.json honestly records what THIS model
# scores on THIS test set. That is why test_accuracy reports it -- it is the
# figure the caller's own request will produce.
#
# What it does NOT establish: whether the served model is the model the paper
# reports. The same model can score differently on two different test sets, and
# the paper publishes sample counts rather than sample membership, so a
# same-sized split is not a same split. The discrepancy is consistent with a
# different fit, a different test split, or both.
#
# So the question at docs/research/2026-08-08-related-work-and-references.md:203
# stays OPEN. It is narrowed, not answered, and cannot be closed from the
# artifacts alone -- it needs the authors.
PUBLISHED_TEST_ACCURACY = {
    "baseline": 0.964,
    "scenario_1_days14_21": 0.942,
    "scenario_2_days7_14": 0.863,
    "scenario_3_day21": 0.942,
    "scenario_4_day14": 0.899,
    "scenario_5_day7": 0.605,
    "scenario_6_spc_all": 0.771,
    "scenario_7_tgn_all": 0.699,
    "scenario_8_spc_7_14": 0.728,
    "scenario_9_tgn_7_14": 0.739,
}

ACCURACY_CITATION = (
    "Jung, Qian, Trmcic, Martin et al. (2026). Developing machine learning models "
    "for fluid milk spoilage classification. J. Dairy Sci. Table 1. "
    "https://doi.org/10.3168/jds.2025-28070"
)


class ClassifierService:
    """Loads 10 RandomForest variants and exposes classify / batch / list APIs."""

    def __init__(self) -> None:
        variants_dir = self._resolve_variants_dir()
        config_path = variants_dir / "variants_config.json"
        if not config_path.exists():
            raise FileNotFoundError(
                f"variants_config.json not found at {config_path}"
            )

        with open(config_path) as f:
            self._config: dict = json.load(f)

        self._models: dict = {}
        for variant_id in self._config["variants"]:
            model_path = variants_dir / f"{variant_id}.joblib"
            if model_path.exists():
                self._models[variant_id] = joblib.load(model_path)
            else:
                print(f"Warning: model file not found for variant {variant_id}")

        print(
            f"ClassifierService: loaded {len(self._models)} variants "
            f"({', '.join(self._models.keys())})"
        )

    def health(self) -> dict:
        """What loaded, against what the config declared.

        /health reads this. It reports the declared set rather than only what
        loaded, because "loaded 10" is not evidence of anything on its own --
        a service that declared 10 and loaded 10 and one that declared 2 and
        loaded 2 both report a number, and only the comparison distinguishes a
        healthy classifier from a half-assembled one. __init__ warns to stdout
        for a variant whose file is absent and carries on, so without this the
        omission is visible only in the container log.
        """
        declared = list(self._config.get("variants", {}))
        return {
            "declared": len(declared),
            "loaded": len(self._models),
            "missing": [v for v in declared if v not in self._models],
            # Reported separately from `missing`, because a config that never
            # declares the default is internally consistent -- declared equals
            # loaded, nothing missing -- while every /classify call that names
            # no variant returns 400. Consistency is not the same as usable.
            "default_variant": DEFAULT_VARIANT,
            "default_loaded": DEFAULT_VARIANT in self._models,
        }

    # ------------------------------------------------------------------
    # Path resolution
    # ------------------------------------------------------------------
    @staticmethod
    def _resolve_variants_dir() -> Path:
        here = Path(__file__).resolve().parent  # dairy-api/services

        candidates = [
            # Dev clone of the classifier repo, at the repository root. Not
            # tracked here -- it is a separate Hugging Face model repo -- so a
            # clean checkout does not have it.
            here.parent.parent / "MilkSpoilageClassifier" / "model" / "variants",
            # What build.sh assembles. This is also the in-image location: the
            # Dockerfile copies services/ and models/ under /app, so `here` is
            # /app/services there and this resolves to /app/models/variants.
            # Without this entry the documented `cd dairy-api && uvicorn app:app`
            # raised FileNotFoundError on a clean checkout even with the build
            # context complete, because neither path below existed.
            here.parent / "models" / "variants",
            Path("/app/models/variants"),
        ]
        for path in candidates:
            if path.exists():
                return path

        raise FileNotFoundError(
            "Cannot locate model variants directory. Run `bash dairy-api/build.sh` "
            "to assemble them. Tried: "
            + ", ".join(str(p) for p in candidates)
        )

    # ------------------------------------------------------------------
    # Single-sample classification
    # ------------------------------------------------------------------
    def classify_sample(self, features: dict[str, float], variant: str = DEFAULT_VARIANT) -> dict[str, Any]:
        """Classify a single sample.

        Parameters
        ----------
        features : dict
            Keys are uppercase feature names (SPC_D7, etc.), values are log CFU/mL.
        variant : str
            Model variant id.

        Returns
        -------
        dict with prediction, probabilities (3-class), confidence.
        """
        model, meta = self._get_model_and_meta(variant)
        required = meta["features"]

        missing = [f for f in required if f not in features or features[f] is None]
        if missing:
            raise ValueError(
                f"Missing required features for variant '{variant}': {', '.join(missing)}"
            )

        # Convert log CFU/mL -> raw CFU/mL
        X = np.array([[10 ** features[f] for f in required]])

        prediction = model.predict(X)[0]
        probabilities = model.predict_proba(X)[0]
        prob_dict = {
            str(cls): round(float(p), 6)
            for cls, p in zip(model.classes_, probabilities)
        }

        return {
            "prediction": str(prediction),
            "probabilities": prob_dict,
            "confidence": round(float(probabilities.max()), 6),
        }

    # ------------------------------------------------------------------
    # Batch classification
    # ------------------------------------------------------------------
    def classify_batch(
        self, samples: list[dict[str, float]], variant: str = DEFAULT_VARIANT
    ) -> dict[str, Any]:
        """Classify multiple samples.

        Returns dict with predictions list and summary (total, ppc_count,
        non_ppc_count, ppc_prevalence).
        """
        predictions = [self.classify_sample(s, variant) for s in samples]

        ppc_count = sum(1 for p in predictions if p["prediction"] == "PPC")
        total = len(predictions)

        return {
            "predictions": predictions,
            "summary": {
                "total": total,
                "ppc_count": ppc_count,
                "non_ppc_count": total - ppc_count,
                "ppc_prevalence": round(ppc_count / total, 6) if total else 0.0,
            },
        }

    # ------------------------------------------------------------------
    # List variants
    # ------------------------------------------------------------------
    def list_variants(self) -> list[dict[str, Any]]:
        """Return variant metadata sorted by test accuracy descending."""
        variants = []
        for variant_id, meta in self._config["variants"].items():
            published = PUBLISHED_TEST_ACCURACY.get(variant_id)
            variants.append(
                {
                    "variant_id": variant_id,
                    "name": meta["name"],
                    "description": meta["description"],
                    "features": meta["features"],
                    # This model's own measured accuracy on the shipped test set,
                    # confirmed by re-scoring the joblib. Quote this one.
                    "test_accuracy": meta["test_accuracy"],
                    # The paper's figure for the same variant name, on the paper's
                    # own test split. Comparison only.
                    "published_test_accuracy": published,
                    "published_source": ACCURACY_CITATION,
                    "accuracy_note": (
                        "test_accuracy is what this artifact scores on the shipped "
                        "test set, confirmed by re-scoring. published_test_accuracy "
                        "is the paper's figure on the paper's own split. Where they "
                        "differ, whether the cause is a different fit or a different "
                        "test split is unresolved: the paper publishes sample counts, "
                        "not sample membership. Report test_accuracy as this model's "
                        "accuracy and the published figure as a separate comparison."
                    ),
                    "n_features": len(meta["features"]),
                }
            )
        variants.sort(key=lambda v: v["test_accuracy"], reverse=True)
        return variants

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------
    def _get_model_and_meta(self, variant: str):
        if variant not in self._models:
            raise ValueError(
                f"Unknown variant '{variant}'. "
                f"Available: {', '.join(self._models.keys())}"
            )
        return self._models[variant], self._config["variants"][variant]
