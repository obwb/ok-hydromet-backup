# ok-hydromet-backup — Cloud Run job image (R ETL).
# Uses Posit Public Package Manager (P3M) Linux binaries for fast, cache-free builds
# (Cloud Build uses legacy non-BuildKit Docker — keep this Dockerfile plain).
FROM rocker/r-ver:4.4

RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq-dev libssl-dev libcurl4-openssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Most packages as fast jammy binaries...
RUN Rscript -e 'options(repos=c(CRAN="https://p3m.dev/cran/__linux__/jammy/latest")); \
      install.packages(c("DBI","httr2","jsonlite","dplyr"))'
# ...but build RPostgres FROM SOURCE against this image's libpq. The prebuilt binary
# throws "bad_weak_ptr" on first query in this runtime (ABI mismatch).
RUN Rscript -e 'install.packages("RPostgres", repos="https://cloud.r-project.org", type="source")'

WORKDIR /app
COPY R/ /app/R/
ENTRYPOINT ["Rscript", "R/run.R"]
