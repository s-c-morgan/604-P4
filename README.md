# PJM Load Forecasting

Forecasting electrical load for the PJM power grid using optimized seasonal weights and temporal decay.

## Model Performance

- **R² = 0.97** (97% variance explained)
- **RMSE = 188.84 MW**
- Linear regression with lag-1 load and temperature features

## Quick Start

### Build Docker Image

```bash
# Build for linux/amd64 platform (required by project specifications)
docker build --platform linux/amd64 -t scmorgan777/604-p4:latest .

# Alternative: Use buildx for cross-platform builds
docker buildx build --platform linux/amd64 -t scmorgan777/604-p4:latest .
```

### Interactive Bash Terminal

To explore and reproduce the analysis:

```bash
# Start interactive bash session
docker run -it --rm scmorgan777/604-p4:latest

# Then run commands interactively:
# make          # Verify/train models
# make clean    # Clean intermediate files
# make rawdata  # View raw data info
# make predictions  # Make predictions
```

### Run Analysis

```bash
# Train models (if needed - models are pre-trained in Docker)
docker run --rm scmorgan777/604-p4:latest make

# Make predictions
docker run --rm scmorgan777/604-p4:latest make predictions
```

### Daily Workflow

```bash
# Append predictions to CSV file
docker run --rm scmorgan777/604-p4:latest make predictions >> predictions.csv

# Then commit to git
git add predictions.csv
git commit -m "Add predictions for $(date +%Y-%m-%d)"
git push
```

## File Structure

### Core Prediction Scripts
- `fit_optimized_models.R` - Train models with calibrated seasonal weights
- `make_predictions_optimized.R` - Generate daily predictions
- `fetch_weather_forecast.R` - Get weather forecast data
- `fetch_10day_forecast.R` - Fetch 10-day weather forecast for peak analysis
- `predict_10day_loads.R` - Predict loads for 10-day period
- `identify_peak_days.R` - Identify peak days from 10-day predictions

### Data Files
- `weather_station_mapping_final.csv` - Maps PJM zones to weather stations
- `data/load_with_weather.csv` - Preprocessed historical data (91MB)
- `data/optimized_models.rds` - Trained models (370MB)

### Raw Data Scripts (for `make rawdata`)
- `download_noaa_weather.sh` - Download NOAA ISD weather data (2016-2025)
- `download_pjm_load.sh` - Download PJM load data from OSF
- `merge_raw_data.R` - Merge raw weather and load data

### Build Files
- `Makefile` - Build automation
- `dockerfile` - Docker image configuration

## Make Targets

All required make targets as specified in project requirements:

```bash
make              # Default: verify/train models (runs all analyses except downloading raw data and predictions)
make clean        # Delete intermediate files (forecasts, predictions), keeps code and models
make predictions  # Make current predictions and output to screen
make rawdata      # Download raw data from NOAA and OSF, then merge (WARNING: large download)
make peak_days    # Manually recalculate peak days from 10-day forecast (optional)
```

## Prediction Workflow

**Prediction Period**: November 20-29, 2025 (10 days)

**First prediction** (Nov 19 → predicting Nov 20):
```bash
make predictions
# 1. Fetches 10-day weather forecast (Nov 20-29, 2025)
# 2. Predicts loads for all 10 days
# 3. Identifies 2 peak days for each zone (FIXED for entire period)
# 4. Makes prediction for Nov 20 with peak day flags
```

**Subsequent predictions** (Nov 20-28 → predicting Nov 21-29):
```bash
make predictions
# 1. Reuses peak day analysis from first run (Nov 20-29)
# 2. Fetches updated weather for tomorrow
# 3. Makes prediction with correct peak day flags
```

**Note**: Peak days are determined once based on the 10-day forecast (Nov 20-29) and remain fixed throughout the prediction period.

## Requirements

- Docker with linux/amd64 platform support
- 4GB RAM (8GB recommended for training)
- Internet connection for weather data

## Model Details

The model uses:
- **Temporal decay**: Half-life = 0.45 years
- **Seasonal weights**: Optimized for November predictions
- **Features**: Temperature, day of week, hour, lag-1 load

Peak predictive months: March, April, October, November (full weight)
