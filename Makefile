.PHONY: all clean predictions models peak_days rawdata

# Default target - trains models if needed
all: data/optimized_models.rds
	@echo ""
	@echo "========================================================================"
	@echo "Models ready for predictions!"
	@echo "========================================================================"
	@echo ""
	@echo "To make predictions:"
	@echo "  make predictions"
	@echo ""

# Delete everything except code and raw data
clean:
	@echo "========================================================================"
	@echo "Cleaning all generated files (keeping code and rawdata/)..."
	@echo "========================================================================"
	@echo ""
	@echo "Deleting:"
	@echo "  - data/ directory (all processed data and models)"
	@echo "  - predictions.csv"
	@echo ""
	@rm -rf data/
	@rm -f predictions.csv
	@echo "✓ Cleaned - only code and rawdata/ remain"
	@echo ""

# Clean predictions.csv file (use with caution!)
clean_predictions:
	@echo "WARNING: This will delete all predictions in predictions.csv"
	@rm -f predictions.csv
	@echo "predictions.csv cleaned"

# Raw data handling - downloads raw data only (no merging)
rawdata:
	@echo "========================================================================"
	@echo "Downloading Raw Data"
	@echo "========================================================================"
	@echo ""
	@echo "This will:"
	@echo "  1. Delete existing rawdata/ directory"
	@echo "  2. Download NOAA ISD weather data (2016-2025)"
	@echo "  3. Download PJM load data from OSF"
	@echo ""
	@rm -rf rawdata/
	@mkdir -p rawdata/weather rawdata/load
	@echo "Step 1/2: Downloading NOAA weather data..."
	@./download_noaa_weather.sh
	@echo ""
	@echo "Step 2/2: Downloading PJM load data..."
	@./download_pjm_load.sh
	@echo ""
	@echo "========================================================================"
	@echo "✓ Raw data downloaded"
	@echo "========================================================================"
	@echo ""

# Analyze 10-day forecast to identify peak days (run once, or manually with 'make peak_days')
peak_days: data/optimized_models.rds
	@Rscript fetch_10day_forecast.R >/dev/null 2>&1
	@Rscript predict_10day_loads.R >/dev/null 2>&1
	@Rscript identify_peak_days.R >/dev/null 2>&1

# Make current predictions (with peak day analysis)
predictions: data/optimized_models.rds data/peak_days.csv
	@Rscript fetch_weather_forecast.R >/dev/null 2>&1
	@Rscript make_predictions_optimized.R 2>/dev/null

# Ensure peak days are calculated before first prediction
data/peak_days.csv: data/optimized_models.rds
	@$(MAKE) --no-print-directory peak_days

# Merge raw data into processed format
data/load_with_weather.csv:
	@echo "========================================================================"
	@echo "Merging raw weather and load data..."
	@echo "========================================================================"
	@Rscript merge_raw_data.R
	@echo "✓ Data merged and saved"

# Train models with optimized seasonal weights
data/optimized_models.rds: data/load_with_weather.csv
	@echo "========================================================================"
	@echo "Training models with optimized seasonal weights..."
	@echo "========================================================================"
	@Rscript fit_optimized_models.R
	@echo "✓ Models trained and saved"
