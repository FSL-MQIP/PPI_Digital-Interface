# Agent Instructions — PPI Digital Interface

## Project Overview

R/Shiny web application that predicts milk spoilage via Monte Carlo simulation across the dairy supply chain. Developed by Cornell University's Milk Quality Improvement Program (MQIP).

### Tech Stack
- **Language**: R
- **Framework**: Shiny + shinydashboard
- **Deployment**: shinyapps.io
- **Key packages**: tidyverse, furrr (parallel processing), deSolve (ODE solver), fitdistrplus, truncnorm, MCMCpack

### Key Files
| File | Purpose |
|---|---|
| `App.R` | Main Shiny app (UI + server) |
| `model/run_model.R` | Model execution for Shiny app |
| `model/Model.R` | Standalone model script |
| `utils/model_helpers.R` | Growth model functions (Buchanan, Baranyi, Ratkowsky, etc.) |
| `utils/helpers.R` | Data processing & CSV parsing utilities |
| `config/default_parameters.R` | Default temp/time for 5 supply chain stages |
| `input_data/*.csv` | Pre-built simulation data |

### Branch Strategy
- `main` — production
- `dev` — active development

## Documentation Rules

**Every time you make a change to the app, you MUST update the following docs:**

### 1. Development Log (`docs/development.md`)
- Append a dated entry describing what changed and why
- Include reasoning and context, not just what files were touched
- Note any trade-offs or open questions for future work

### 2. Kanban Board (`docs/kanban.md`)
- Move tasks between columns as work progresses
- Add new tasks discovered during development to Backlog
- Remove completed items only after they are verified working
- Columns: `Backlog` → `In Progress` → `Done`

### 3. Architecture Decision Records (`docs/adr/`)
- Create a new ADR **only** when a model or app design decision is made
- Scope: simulation parameters, growth models, data handling, UI workflow, output format
- Out of scope: tooling, CI/CD, agent workflow decisions
- Use MADR format (lightweight): Status, Context, Decision, Consequences
- Number sequentially: `001-topic.md`, `002-topic.md`, etc.
- Update `docs/adr/README.md` index when adding a new ADR
