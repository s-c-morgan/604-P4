# PJM Load Forecasting

> **IMPORTANT DISCLAIMER**: This project was developed using **Claude Code** (Anthropic's AI-powered coding assistant). Claude Code was extensively used for:
> - Writing and debugging all R scripts and shell scripts as well as creating assisting documentation (code comments)
> - Navigating NOAA and PJM data APIs
> - Implementing the forecasting model architecture
> - Setting up the Docker containerization
> - Optimizing the Makefile workflow
> - Troubleshooting data merging and model training issues

---

## Quick Start

### 1. Pull Docker Image

```bash
docker pull scmorgan/pjm-load-forecast:latest
```

### 2. Make Predictions

```bash
# Output predictions to screen
docker run --rm scmorgan/pjm-load-forecast:latest make predictions

# Append to predictions.csv file
docker run --rm scmorgan/pjm-load-forecast:latest make predictions >> predictions.csv
```

### 3. Interactive Exploration

```bash
# Start bash session to explore the model
docker run -it --rm scmorgan/pjm-load-forecast:latest

# Inside the container, try:
make              # Verify models are ready
make predictions  # Make a prediction
ls -lh data/      # View data files
```

---

## Available Commands

All required make targets as specified in project requirements:

```bash
make              # Verify/train models (if needed)
make predictions  # Make current predictions and output to screen
make clean        # Delete intermediate files (keeps code and rawdata/)
make rawdata      # Re-download raw data from NOAA and OSF
```

---

## Daily Prediction Workflow

**Prediction Schedule**: November 19-28, 2025 (making predictions for Nov 20-29)

Each day at noon:

```bash
# Run prediction and append to CSV
docker run --rm scmorgan/pjm-load-forecast:latest make predictions >> predictions.csv

# Commit to git
git add predictions.csv
git commit -m "Add predictions for $(date +%Y-%m-%d)"
git push
```

**Output format**:
```
"YYYY-MM-DD", L1_00, L1_01, ..., L29_23, PH_1, ..., PH_29, PD_1, ..., PD_29
```
- Date: Current date (when prediction was made)
- 696 hourly load predictions (29 zones × 24 hours)
- 29 peak hour predictions (00-23 format)
- 29 peak day predictions (0 or 1)

---

## Building from Source

If you want to rebuild the Docker image:

```bash
# Clone repository
git clone https://github.com/scmorgan/604-P4.git
cd 604-P4

# Build for linux/amd64 platform (required)
docker build --platform linux/amd64 -t scmorgan/pjm-load-forecast:latest .

# Push to Docker Hub (optional)
docker push scmorgan/pjm-load-forecast:latest
```

---

## Model Performance

- **R² = 0.97** (97% variance explained)
- **RMSE = 188.84 MW**
- **Model**: Linear regression with optimized seasonal weights and temporal decay
- **Features**: Temperature, day of week, hour, lag-1 load, Thanksgiving week indicator

**Temporal decay**: Half-life = 0.45 years
**Seasonal weights**: Optimized for November predictions via 3-round cross-validation

Peak predictive months: March, April, October, November (full weight)

---

## System Requirements

- Docker with linux/amd64 platform support
- 4GB RAM (for `make predictions`)
- Internet connection (for fetching weather forecasts)

---

## Troubleshooting

**Models not found**: Pre-trained models are included in the Docker image. If missing, run:
```bash
docker run --rm scmorgan/pjm-load-forecast:latest make
```

**Weather forecast fails**: Requires internet connection to fetch from NOAA API. Check network connectivity.

**Wrong platform error**: Make sure to build with `--platform linux/amd64` flag.

---

## Project Structure

```
604-P4/
├── Makefile                              # Build automation
├── dockerfile                            # Docker configuration
├── weather_station_mapping_final.csv     # Zone-to-station mappings
├── fit_optimized_models.R                # Model training
├── make_predictions_optimized.R          # Daily predictions
├── fetch_weather_forecast.R              # Weather API integration
├── fetch_10day_forecast.R                # 10-day weather forecast
├── predict_10day_loads.R                 # 10-day load predictions
├── identify_peak_days.R                  # Peak day identification
├── download_noaa_weather.sh              # NOAA data download
├── download_pjm_load.sh                  # PJM data download
├── merge_raw_data.R                      # Data preprocessing
└── data/
    ├── load_with_weather.csv             # Preprocessed data (91MB)
    └── optimized_models.rds              # Trained models (451MB)
```

