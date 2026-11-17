# Regenerate the combined-model regression baseline
#
# Writes verification/scenario_baselines/milk_model_baseline.csv, the reference
# that verify_scenarios.R and test_run_model_function.R seed-match against.
#
# This is a SELF-regression: the reference comes from run_model() itself, so it
# detects change, not correctness. Regenerate it deliberately, after a change to
# model behaviour has been verified some other way -- verify_structure.R for
# container assembly and scenario reach, compare_distributions.R for the growth
# mathematics. Regenerating to make a red check go green just re-pins whatever
# the model now does.
#
# Run from the repo root:
#   Rscript verification/generate_model_baseline.R

args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
script_dir <- if (length(script_path) > 0) {
  dirname(normalizePath(script_path))
} else {
  getwd()
}

outfile <- file.path(script_dir, "scenario_baselines", "milk_model_baseline.csv")

setwd(file.path(script_dir, "..", "milk-spoilage-model"))
source("run_model.R")

set.seed(42)
result <- run_model()

if (file.exists(outfile)) {
  cat("Previous baseline:\n")
  print(read.csv(outfile))
  cat("\n")
}

write.csv(result$spoilage_summary, outfile, row.names = FALSE)

cat("New baseline written to", outfile, "\n\n")
print(result$spoilage_summary)
cat(sprintf("\nshelf life: total=%s d, consumer=%.1f d, pre-consumer=%.3f d\n",
            format(result$shelf_life$total_days),
            result$shelf_life$consumer_days,
            result$shelf_life$pre_consumer_days))

plan(sequential)
