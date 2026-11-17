# 3.11, not 3.10: scikit-learn 1.8.0 declares Requires-Python >=3.11, and the
# classifier artifacts were pickled by 1.8.0. On 3.10 pip refuses the pin and
# the dependency layer fails before the image exists.
FROM python:3.11-slim

# Install R and system dependencies.
# cmake is required: lamW depends on RcppParallel, whose configure step aborts
# with "RcppParallel requires cmake (>= 3.5); cmake was not found". Without it
# both packages fail and the PPC pathway cannot run.
RUN apt-get update && apt-get install -y --no-install-recommends \
    r-base \
    r-base-dev \
    cmake \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

# Install R packages, and FAIL THE BUILD if any of them did not install.
# install.packages() reports a failure as a warning, so `R -e` still exits 0 --
# which is how an image shipped without lamW and only broke when /simulate was
# first called. The explicit check turns that into a build failure.
# services/simulator.py mirrors this list for its health check; keep them in step.
RUN R -e "pkgs <- c( \
    'dplyr','tidyr','tibble','purrr','deSolve','lamW', \
    'formula.tools','truncnorm','furrr','future', \
    'jsonlite','ggplot2','base64enc'); \
    install.packages(pkgs, repos='https://cloud.r-project.org', Ncpus=4); \
    missing <- pkgs[!pkgs %in% rownames(installed.packages())]; \
    if (length(missing)) stop('R packages failed to install: ', \
                              paste(missing, collapse=', '))"

WORKDIR /app

# Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy API code
COPY app.py .
COPY build_info.py .
COPY routers/ routers/
COPY services/ services/
COPY r_bridge/ r_bridge/

# Copy the MCP server and the guidance it serves (ADR 016)
COPY mcp_server/ mcp_server/
COPY guidance/ guidance/

# build.sh writes this with nulls and deploy_space.py overwrites it with the
# digest of the payload it uploads, so it is always in the context and this COPY
# needs no wildcard to tolerate its absence.
COPY build_info.json .

# Copy ML model artifacts (from build context)
COPY models/ models/

# Copy R model code (from build context)
COPY milk-spoilage-model/ milk-spoilage-model/

# Hugging Face Spaces runs the container as uid 1000. Switch after the COPYs so
# the R and Python packages still install system-wide as root; the app only ever
# writes to /tmp (render_plot.R's tempfile), which every user can write.
RUN useradd -m -u 1000 user
USER user

# 7860 is the port a Docker Space expects, and it must match `app_port` in the
# README front matter. Railway overrides this through railway.toml's
# startCommand, and a local run maps whatever it likes onto it.
ENV PORT=7860
EXPOSE 7860

# Shell form, so ${PORT} expands. `exec` so uvicorn replaces the shell and
# becomes PID 1 -- without it SIGTERM stops at /bin/sh and the container waits
# out its kill timeout on every restart.
CMD exec uvicorn app:app --host 0.0.0.0 --port ${PORT}
