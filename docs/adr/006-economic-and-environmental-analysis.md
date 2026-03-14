# ADR-006: Economic loss and environmental emission analysis

## Status
Accepted

## Context
With disruption scenarios (S1–S4) implemented, users can see how spoilage changes under different cold chain disruptions. However, the microbiological output alone (spoilage %, shelf-life days) doesn't communicate the practical impact. Stakeholders need to understand the economic cost and environmental footprint of these disruptions to justify investments in cold chain reliability.

## Decision
Add economic and environmental impact calculations that compare a disruption scenario against the precomputed baseline (default parameters, no scenarios). Results are displayed as callout boxes in the UI alongside the existing spoilage metrics.

### Economic loss

The economic impact is based on the difference in consumer shelf life between baseline and scenario:

```
delta_days = baseline_days_to_25pct_consumer - scenario_days_to_25pct_consumer
economic_loss = delta_days × $0.03/unit × containers_per_lot
```

The **$0.03 per unit per day** figure comes from Lau et al. (2023), which estimated the added value of one additional day of fluid milk shelf life.

> Lau, S., Wiedmann, M., & Ivanek, R. (2023). *The value of extending the shelf life of fluid milk*. Journal of Dairy Science.

Both the baseline and scenario absolute economic values are displayed alongside the delta, so users see the full picture: `Baseline: $X | Scenario: $Y | Loss: $Z`.

### Environmental emission

Environmental impact is measured in kg CO₂e per lot, based on the volume of milk wasted and the disposal pathway:

1. **Reference day**: The baseline's overall shelf-life day — interpolated from `SpoilStats_all` as the day when `Median_Proportion` crosses 25%.

2. **Waste volume at reference day** (computed for both baseline and scenario):
   - Retail waste (liters) = `pct_spoiled_at_retail / 100 × containers × 1.893`
   - Total spoilage = `Median_Proportion` at reference day (interpolated from `SpoilStats_all`)
   - Consumer waste (liters) = `(total_spoilage - retail_spoilage) × containers × 1.893`

3. **CO₂e calculation**:
   - Retail waste → landfill: **0.55 kg CO₂e per liter**
   - Consumer waste → wastewater: **0.2 kg CO₂e per liter**
   - Total CO₂e = `retail_waste_L × 0.55 + consumer_waste_L × 0.2`

The emission factors are derived from EPA's WARM model (U.S. EPA, 2020):
- Landfilling dairy products: ~0.50 metric tons CO₂e per short ton of waste, corresponding to ~0.55 kg CO₂e per liter of milk
- Wastewater disposal: ~0.2 kg CO₂e per liter of milk

> U.S. Environmental Protection Agency. (2020). *Waste Reduction Model (WARM)*.

The disposal pathway is differentiated by stage of waste generation: retail-stage spoilage is assumed to go to landfill, while consumer-stage spoilage is assumed to go to wastewater treatment.

### Container volume

Half-gallon containers = **1.893 liters**. The default lot size is 1000 containers, configurable via a numeric input in the UI.

### Baseline precomputation

The baseline model result is precomputed to `input_data/baseline_result.rds` and loaded at app startup via `readRDS()` to avoid slow initialization. If default parameters or input data change, regenerate with:

```
Rscript scripts/precompute_baseline.R
```

## Consequences
- Economic and environmental callout boxes only appear when a disruption scenario is active (both dropdowns default to "None")
- The baseline is always the pure default configuration — user-modified inputs do not change the stored baseline
- If the baseline never reaches 25% spoilage (unlikely with current defaults), the environmental box shows "N/A"
- If either baseline or scenario `days_to_25pct_consumer` is NA, the economic box shows "N/A"
- Future intervention strategies (planned) can reuse this same comparison framework
