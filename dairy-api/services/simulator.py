"""Run R spoilage simulation via subprocess."""

import json
import subprocess
from pathlib import Path
from typing import Optional


def _find_rscript() -> str:
    """Find Rscript executable, checking PATH and common install locations."""
    import shutil
    rscript = shutil.which("Rscript")
    if rscript:
        return rscript
    # Common Windows locations
    for version_dir in sorted(Path("C:/Program Files/R").glob("R-*"), reverse=True):
        candidate = version_dir / "bin" / "Rscript.exe"
        if candidate.exists():
            return str(candidate)
    return "Rscript"  # fallback, will fail with clear error on subprocess call


class SimulatorService:
    def __init__(self, r_executable: Optional[str] = None,
                 model_dir: Optional[Path] = None,
                 bridge_script: Optional[Path] = None):
        self.r_executable = r_executable or _find_rscript()

        if model_dir is None:
            candidates = [
                Path(__file__).parent.parent.parent / "milk-spoilage-model",
                Path("/app/milk-spoilage-model"),
            ]
            for p in candidates:
                if (p / "run_model.R").exists():
                    model_dir = p
                    break
            if model_dir is None:
                raise FileNotFoundError("milk-spoilage-model/run_model.R not found")

        if bridge_script is None:
            candidates = [
                Path(__file__).parent.parent / "r_bridge" / "run_simulation.R",
                Path("/app/r_bridge/run_simulation.R"),
            ]
            for p in candidates:
                if p.exists():
                    bridge_script = p
                    break
            if bridge_script is None:
                raise FileNotFoundError("r_bridge/run_simulation.R not found")

        self.model_dir = model_dir
        self.bridge_script = bridge_script

    def run(self, config: Optional[dict] = None,
            interventions: Optional[dict] = None,
            disruptions: Optional[dict] = None,
            seed: Optional[int] = None) -> dict:
        request = {}
        if config:
            request["config"] = config
        if interventions:
            request["interventions"] = interventions
        if disruptions:
            request["disruptions"] = disruptions
        if seed is not None:
            request["seed"] = seed

        input_json = json.dumps(request)

        proc = subprocess.run(
            [self.r_executable, str(self.bridge_script)],
            input=input_json,
            capture_output=True,
            text=True,
            cwd=str(self.model_dir),
            timeout=300,
        )

        if proc.returncode != 0:
            # Extract last 500 chars of stderr for error message
            err_msg = proc.stderr[-500:] if proc.stderr else "Unknown R error"
            raise RuntimeError(f"R simulation failed: {err_msg}")

        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as e:
            raise RuntimeError(
                f"Failed to parse R output as JSON: {e}. "
                f"stdout (last 200 chars): {proc.stdout[-200:]}"
            )

    # Mirrors the install list in the Dockerfile; keep them in step.
    _REQUIRED_R_PACKAGES = (
        "dplyr", "tidyr", "tibble", "purrr", "deSolve", "lamW",
        "formula.tools", "truncnorm", "furrr", "future",
        "jsonlite", "ggplot2", "base64enc",
    )

    def check_r_runtime(self) -> bool:
        # Checks that the packages the simulation needs are present, not merely
        # that R starts. The old check ran `cat('ok')`, so /health reported
        # r_runtime: true on an image built without lamW, and the first
        # /simulate call was what discovered it.
        # find.package() resolves without attaching, so this stays fast enough
        # for a health endpoint.
        probe = (
            "invisible(lapply(c(%s), find.package)); cat('ok')"
            % ",".join("'%s'" % p for p in self._REQUIRED_R_PACKAGES)
        )
        try:
            proc = subprocess.run(
                [self.r_executable, "-e", probe],
                capture_output=True, text=True, timeout=30,
            )
            return proc.returncode == 0 and "ok" in proc.stdout
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False

    def list_scenarios(self) -> dict:
        return {
            "interventions": {
                "spore_reduction": {
                    "type": "enum_or_number",
                    "options": ["microfiltration", "microfiltration_low",
                                "bactofugation_single", "bactofugation_double", "none"],
                    "log_reductions": {
                        "microfiltration": 2.2,
                        "microfiltration_low": 0.6,
                        "bactofugation_single": 1.4,
                        "bactofugation_double": 2.0,
                        "none": 0,
                    },
                    "numeric_override": {
                        "type": "number",
                        "minimum": 0,
                        "description": (
                            "A measured log reduction, supplied instead of a preset "
                            "name. Negative values are rejected: interventions are "
                            "improvements only."
                        ),
                    },
                    "description": (
                        "Spore log reduction for non-PPC pathways. Reduces the initial "
                        "load of spore-forming genera (Bacillus, Paenibacillus) only. "
                        "The presets are published estimates and achieved reduction "
                        "varies with equipment and processing conditions, so pass a "
                        "number instead when the processor has measured their own."
                    ),
                },
                "ppc_frequency_factor": {
                    "type": "number", "range": [0, 1],
                    "description": "Multiply PPC frequency range (0.5 = halve PPC prevalence)",
                },
                "ppc_initial_reduction_log": {
                    "type": "number", "range": [0, 5],
                    "description": "Subtract from mean initial PPC concentration (log10)",
                },
                "ppc_remove_st": {
                    "type": "array", "item_type": "string",
                    "description": "Remove sequence types from PPC sampling pool",
                },
                "stage_temp_overrides": {
                    "type": "object",
                    "stages": [
                        "processing_facility",
                        "transportation_facility_to_retail",
                        "retail",
                        "transportation_retail_to_home",
                        "consumer",
                    ],
                    "per_stage_options": {
                        "temp_delta": "Shift temperature (C)",
                        "temp_mean": "Replace mean temperature (C)",
                        "temp_sd": "Replace temperature SD (C)",
                        "temp_max": "Clamp maximum temperature (C)",
                        "duration_delta": "Extend/shorten duration (days)",
                    },
                },
            },
            "disruptions": {
                "types": {
                    "temp_spike": {
                        "params": {"temp": "C", "duration": "days"},
                        "description": "Temperature jumps for a period then returns",
                    },
                    "delay": {
                        "params": {"duration_delta": "days", "temp": "C"},
                        "description": "Stage takes longer at specified temp",
                    },
                    "temp_shift": {
                        "params": {"temp_delta": "C"},
                        "description": "Entire stage runs warmer/cooler",
                    },
                    "preset": {
                        "params": {"name": "string"},
                        "description": "Named preset scenario",
                    },
                },
                "presets": {
                    "s1_cooling_failure": {
                        "stage": "processing_facility",
                        "description": "Storage cooling system disruption",
                    },
                    "s2_delivery_delay": {
                        "stage": "processing_facility",
                        "description": "Delivery delay at facility",
                    },
                    "s3_trunk_opening": {
                        "stage": "transportation_facility_to_retail",
                        "description": "Trunk opening during transport",
                    },
                    "s4_cooling_disruption": {
                        "stage": "transportation_facility_to_retail",
                        "description": "Delivery cooling system disruption",
                    },
                },
                "stages": [
                    "processing_facility",
                    "transportation_facility_to_retail",
                    "retail",
                    "transportation_retail_to_home",
                    "consumer",
                ],
            },
        }
