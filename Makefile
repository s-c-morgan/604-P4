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

# Delete intermediate outputs
clean:
	@echo "Cleaning intermediate outputs..."
	@rm -f data/forecast_*.csv
	@rm -f data/predictions_*_detail.csv
	@rm -f data/predictions_10day.csv
	@rm -f data/peak_days.csv
	@echo "Cleaned intermediate files"

# Clean predictions.csv file (use with caution!)
clean_predictions:
	@echo "WARNING: This will delete all predictions in predictions.csv"
	@rm -f predictions.csv
	@echo "predictions.csv cleaned"

# Raw data handling - downloads and processes raw data from scratch
rawdata:
	@echo "========================================================================"
	@echo "Downloading and Processing Raw Data"
	@echo "========================================================================"
	@echo ""
	@echo "This will:"
	@echo "  1. Delete existing rawdata/ directory"
	@echo "  2. Download NOAA ISD weather data (2016-2025)"
	@echo "  3. Download PJM load data from OSF"
	@echo "  4. Merge into data/load_with_weather.csv"
	@echo ""
	@rm -rf rawdata/
	@mkdir -p rawdata/weather rawdata/load
	@echo "Step 1/3: Downloading NOAA weather data..."
	@./download_noaa_weather.sh
	@echo ""
	@echo "Step 2/3: Downloading PJM load data..."
	@./download_pjm_load.sh
	@echo ""
	@echo "Step 3/3: Merging raw data..."
	@Rscript merge_raw_data.R
	@echo ""
	@echo "========================================================================"
	@echo "✓ Raw data downloaded and processed"
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

# Train models with optimized seasonal weights
data/optimized_models.rds: data/load_with_weather.csv
	@echo "========================================================================"
	@echo "Training models with optimized seasonal weights..."
	@echo "========================================================================"
	@Rscript fit_optimized_models.R
	@echo "✓ Models trained and saved"
