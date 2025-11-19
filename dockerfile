# ==============================================================================
# PJM Load Forecasting - Docker Image
# ==============================================================================
# Base: r-base (official R Docker image)
# Purpose: Forecast electrical load for PJM power grid (29 zones, 10 days)
# Platform: linux/amd64 (required by project specifications)
# ==============================================================================

FROM r-base:4.3.1

# ==============================================================================
# System Dependencies
# ==============================================================================

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        make \
        wget \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ==============================================================================
# R Package Dependencies
# ==============================================================================

RUN R -e "install.packages(c( \
    'dplyr',     \
    'readr',     \
    'tidyr',     \
    'httr',      \
    'jsonlite',  \
    'lubridate', \
    'zoo'        \
), repos='https://cran.rstudio.com/', Ncpus=4)"

# ==============================================================================
# Working Directory
# ==============================================================================

RUN mkdir -p /app/data
WORKDIR /app

# ==============================================================================
# Project Files
# ==============================================================================

# Core prediction scripts
COPY fetch_weather_forecast.R       ./
COPY make_predictions_optimized.R   ./

# Peak day analysis scripts
COPY fetch_10day_forecast.R         ./
COPY predict_10day_loads.R          ./
COPY identify_peak_days.R           ./

# Model training script
COPY fit_optimized_models.R         ./

# Raw data download scripts
COPY download_noaa_weather.sh       ./
COPY download_pjm_load.sh           ./
COPY merge_raw_data.R               ./

# Make scripts executable
RUN chmod +x download_noaa_weather.sh download_pjm_load.sh

# Configuration and data
COPY Makefile                              ./
COPY weather_station_mapping_final.csv     ./

# ==============================================================================
# Preprocessed Data
# ==============================================================================

COPY data/load_with_weather.csv     ./data/
COPY data/optimized_models.rds      ./data/

# ==============================================================================
# Runtime Configuration
# ==============================================================================

# Default command: bash shell for interactive use
CMD ["/bin/bash"]
