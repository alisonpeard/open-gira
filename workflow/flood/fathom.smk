"""Rules to incorporate get Fathom data into OpenGIRA raw/ folder and add to pipeline.

Note the tiny grid (1 arcsec) size of the Fathom data makes this very slow with 64 slices
(e.g., 8 edges --> 9126 slices). Better to use 128, 256 or more slices.

Made the following changes to the rest of the repo:
    1. `touch "config/hazard_resource_locations/fathom.txt"`
    2. config/config.yaml
        a. hazard_datasets: fathom-pluvial: "config/hazard_resource_locations/fathom-pluvial.txt"
        b. hazard_types: fathom-pluvial: "flood"
    3. src/open-gira/direct_damages.py
        a. define class FathomFlood(ReturnPeriodMap):
            - FathomFlood.attrs: name, scenario, year, model, return_period_type, PREFIX
        b. get_rp_map():
            - append FathomFlood.PlUVIAL = FathomFlood to prefix_class_map
            - append FathomFlood.FLUVIAL = FathomFlood to prefix_class_map
            - append FathomFlood.COASTAL = FathomFlood to prefix_class_map

To create raw input files:
>>> cd ~/Local/github/open-gira
>>> conda activate open-gira
>>> snakemake --rerun-incomplete --cores 8 -- fathom_all_historical

To do flood damage calculations:
>>> snakemake --rerun-incomplete --cores 4 -- results/direct_damages/somalia-latest_filter-{road-primary,road-secondary,road-tertiary,road-residential}/hazard-fathom-fluvial/EAD_and_cost_per_RP/slice-{0..64}.geoparquet
>>> snakemake --cores 4 -- results/direct_damages/somalia-latest_filter-{road-primary,road-secondary,road-tertiary,road-residential}/hazard-fathom-pluvial/EAD_and_cost_per_RP/slice-{0..127}.geoparquet
>>> snakemake --cores 4 -- results/direct_damages/somalia-latest_filter-{road-primary,road-secondary,road-tertiary,road-residential}/hazard-fathom-coastal/EAD_and_cost_per_RP/slice-{0..127}.geoparquet

To test run with one slice for fluvial:
>>> snakemake --cores 4 -- results/direct_damages/somalia-latest_filter-{road-primary,road-secondary,road-tertiary,road-residential}/hazard-fathom-fluvial/EAD_and_cost_per_RP/slice-0.geoparquet
"""

def format_scenario(scenario):
    if scenario.startswith("SSP"):
        return scenario.replace("p", ".").replace("-", "_")
    elif scenario == "hist":
        return "historical"

rule mosaic_fathom_old:
    input:
        indir=lambda wildcards: "/Users/alison/Downloads/fathom/{floodtype}/{epoch}/{scenario}/1in{rp}/".format(
            floodtype=wildcards.FLOODTYPE,
            epoch=wildcards.EPOCH,
            scenario=format_scenario(wildcards.SCENARIO),
            rp=int(wildcards.RP)
        )
    # output:
    #     tiff="results/input/hazard-fathom-{FLOODTYPE}/raw/{FLOODTYPE}_{SCENARIO}_{EPOCH}_rp{RP}.tif"
    shell:
        """
        TEMP_DIR=$(mktemp -d)

        mkdir -p $(dirname {output.tiff})
        ls -1 {input.indir}/*.tif > $TEMP_DIR/tiles.txt
        
        gdalbuildvrt $TEMP_DIR/temp_mosaic.vrt -input_file_list $TEMP_DIR/tiles.txt
        
        # files are big, add compression methods
        # gdal_calc.py --calc="(A==-32767)*(-999) + (A>-32767)*(A<9999)*(A/100)" \
        #     --format=GTiff \
        #     --type=Float32 \
        #     -A $TEMP_DIR/temp_mosaic.vrt \
        #     --outfile={output.tiff} \
        #     --NoDataValue=-32768 \
        #     --co COMPRESS=LZW \
        #     --co PREDICTOR=3 \
        #     --co TILED=YES \
        #     --co BIGTIFF=IF_SAFER \
        #     --config GDAL_CACHEMAX 50%

        # Resample to approximately 90m resolution (0.000833 degrees ≈ 3 arc-seconds)
        gdalwarp -tr 0.000833 0.000833 -r bilinear $TEMP_DIR/temp_mosaic.vrt $TEMP_DIR/resampled_mosaic.vrt

        # retrying to see if fixes the issue with trimming
        gdal_calc.py --calc="(A==-32768)*(-32768) + (A==-32767)*(-32767) + (A>-32767)*(A/100)" \
            --format=GTiff \
            --type=Float32 \
            -A $TEMP_DIR/resampled_mosaic.vrt \
            --outfile={output.tiff} \
            --NoDataValue=-32768 \
            --co COMPRESS=LZW \
            --co BIGTIFF=IF_SAFER \
            --config GDAL_CACHEMAX 50%
        
        # rm -rf $TEMP_DIR
        """


rule mosaic_fathom:
    input:
        indir=lambda wildcards: "/Users/alison/Downloads/fathom/{floodtype}/{epoch}/{scenario}/1in{rp}/".format(
            floodtype=wildcards.FLOODTYPE,
            epoch=wildcards.EPOCH,
            scenario=format_scenario(wildcards.SCENARIO),
            rp=int(wildcards.RP)
        )
    output:
        tiff="results/input/hazard-fathom-{FLOODTYPE}/raw/{FLOODTYPE}_{SCENARIO}_{EPOCH}_rp{RP}.tif"
    shell:
        """
        TEMP_DIR=$(mktemp -d)

        mkdir -p $(dirname {output.tiff})
        trap "rm -rf $TEMP_DIR" EXIT
        echo "Working in temporary directory: $TEMP_DIR"

        ls -1 {input.indir}/*.tif > $TEMP_DIR/tiles.txt

        echo "Creating VRT from tiles..."
        gdalbuildvrt $TEMP_DIR/temp_mosaic.vrt -input_file_list $TEMP_DIR/tiles.txt

        echo "Normalizing NoData values..."
        gdal_calc.py --calc="(A==-32767)*(-32768) + (A!=-32767)*(A)" \
            --format=GTiff \
            -A $TEMP_DIR/temp_mosaic.vrt \
            --outfile=$TEMP_DIR/normalized_mosaic.tif \
            --NoDataValue=-32768 \
            --co BLOCKXSIZE=2048 \
            --co BLOCKYSIZE=2048 \
            --co SPARSE_OK=YES \
            --config GDAL_CACHEMAX 50%

        echo "Resampling to 90 m resolution..."
        gdalwarp -tr 0.000833 0.000833 \
            -r bilinear \
            -srcnodata -32768 \
            -dstnodata -32768 \
            -wo INIT_DEST=NO_DATA \
            $TEMP_DIR/normalized_mosaic.tif $TEMP_DIR/resampled_mosaic.tif

        echo "Calculating final output..."
        gdal_calc.py --calc="(A==-32768)*(-32768) + (A>-32767)*(A/100)" \
            --format=GTiff \
            --type=Float32 \
            -A $TEMP_DIR/resampled_mosaic.tif \
            --outfile={output.tiff} \
            --NoDataValue=-32768 \
            --co COMPRESS=LZW \
            --co BIGTIFF=IF_SAFER \
            --config GDAL_CACHEMAX 50%

        # rm -rf $TEMP_DIR
        """


rule fathom_all_scenario:
    input:
        tiffs = expand(
            "results/input/hazard-fathom-{FLOODTYPE}/raw/{FLOODTYPE}_{SCENARIO}_{EPOCH}_rp{RP}.tif",
            FLOODTYPE=["pluvial"], # ["fluvial", "coastal"],   # ["pluvial", "fluvial", "coastal"]
            SCENARIO=["SSP2-4p5", "SSP5-8p5"],   # ["historical", "SSP2_4p5", "SSP5_8p5"]
            EPOCH=["2050", "2080"],          # ["2020", "2050", "2080"]
            RP=["00005", "00010", "00100", "00200", "00500", "01000"],
        )

rule fathom_all_historical:
    input:
        tiffs = expand(
            "results/input/hazard-fathom-{FLOODTYPE}/raw/{FLOODTYPE}_{SCENARIO}_{EPOCH}_rp{RP}.tif",
            FLOODTYPE=["pluvial"], # ["fluvial", "coastal"],   # ["pluvial", "fluvial", "coastal"]
            SCENARIO=["hist"],   # ["historical", "SSP2_4p5", "SSP5_8p5"]
            EPOCH=["2020"],          # ["2020", "2050", "2080"]
            RP=["00005", "00010", "00100", "00200", "00500", "01000"],
        )