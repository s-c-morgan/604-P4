#!/bin/bash

# Download NOAA ISD weather data for all stations (2016-2025)
# Data source: NOAA Integrated Surface Database (ISD)
# Output: rawdata/weather/*.gz

set -e

echo "========================================================================"
echo "Downloading NOAA ISD Weather Data"
echo "========================================================================"
echo ""

# Create output directory
mkdir -p rawdata/weather

# Read station mapping and extract USAF-WBAN codes
stations=$(tail -n +2 weather_station_mapping_final.csv | cut -d',' -f3 | sort -u)

# Years to download
years="2016 2017 2018 2019 2020 2021 2022 2023 2024 2025"

echo "Stations to download: $(echo "$stations" | wc -l | tr -d ' ')"
echo "Years: $years"
echo ""

# Download each station-year combination
total=0
success=0
failed=0

for station in $stations; do
    # Remove hyphen from USAF-WBAN code for NOAA URL
    station_id=$(echo "$station" | tr -d '-')

    for year in $years; do
        total=$((total + 1))
        filename="${station}-${year}.csv"
        url="https://www.ncei.noaa.gov/data/global-hourly/access/${year}/${station_id}.csv"
        output="rawdata/weather/${filename}"

        # Skip if already exists
        if [ -f "$output" ]; then
            echo "  [$total] ✓ $filename (already exists)"
            success=$((success + 1))
            continue
        fi

        # Download
        echo -n "  [$total] Downloading $filename ... "
        if curl -f -s -S "$url" -o "$output" 2>/dev/null; then
            echo "✓"
            success=$((success + 1))
        else
            echo "✗ (not found or error)"
            failed=$((failed + 1))
            rm -f "$output"
        fi

        # Rate limiting
        sleep 0.5
    done
done

echo ""
echo "========================================================================"
echo "SUMMARY"
echo "========================================================================"
echo "Total attempts: $total"
echo "Downloaded: $success"
echo "Failed: $failed"
echo ""
echo "Downloaded files saved to: rawdata/weather/"
echo "========================================================================"
