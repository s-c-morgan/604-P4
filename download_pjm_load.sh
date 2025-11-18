#!/bin/bash

# Download PJM load data from OSF
# Source: https://files.osf.io/v1/resources/Py3u6/providers/osfstorage/?zip=
# Output: rawdata/load/

set -e

echo "========================================================================"
echo "Downloading PJM Load Data from OSF"
echo "========================================================================"
echo ""

# Create output directory
mkdir -p rawdata/load

# Download URL
url="https://files.osf.io/v1/resources/Py3u6/providers/osfstorage/?zip="
zip_file="rawdata/load/pjm_data.zip"

echo "Downloading PJM data archive..."
if curl -L "$url" -o "$zip_file"; then
    echo "✓ Downloaded to $zip_file"
    echo ""

    # Check file size
    size=$(ls -lh "$zip_file" | awk '{print $5}')
    echo "File size: $size"
    echo ""

    # Extract the zip file
    echo "Extracting archive..."
    cd rawdata/load
    unzip -o pjm_data.zip
    cd ../..
    echo "✓ Extracted"
    echo ""

    # List contents
    echo "Contents of rawdata/load/:"
    ls -lh rawdata/load/
else
    echo "✗ Failed to download PJM data"
    exit 1
fi

echo ""
echo "========================================================================"
echo "PJM load data downloaded successfully"
echo "========================================================================"
