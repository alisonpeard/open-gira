"""
To create raw input files:
>>> cd ~/Local/github/open-gira
>>> conda activate open-gira
>>> snakemake --cores 6 -- fathom_all

Mods to repo:
    1. Add fathom-pluvial to hazard_types and hazard datasets in config.yaml
    2. Define a new class, FathomFlood in src/open-gira/direct_damages.py
    3. Add new class to get_rp_map() in src/open-gira/direct_damages.py

To do flood damage calculations:
>>> snakemake --cores 6 -- results/direct_damages/somalia-latest_filter-{road-primary,road-secondary,road-tertiary,road-residential}/hazard-fathom-pluvial/EAD_and_cost_per_RP/slice-{0..63}.geoparquet
"""

rule mosaic_fathom_old:
    input:
        indir=lambda wildcards: "/Users/alison/Downloads/fathom/{floodtype}/{epoch}/{scenario}/1in{rp}/".format(
            floodtype=wildcards.FLOODTYPE,
            epoch=wildcards.EPOCH,
            scenario=wildcards.SCENARIO.replace("p", "."),
            rp=wildcards.RP
        )
    output:
        tiff="results/input/hazard-fathom-{FLOODTYPE}/raw/{FLOODTYPE}_{SCENARIO}_{EPOCH}_{RP}.tif"
    shell:
        """
        mkdir -p $(dirname {output.tiff})
        ls -1 {input.indir}/*.tif > tiles.txt
        gdal_merge -o {output.tiff} --optfile tiles.txt
        """


rule mosaic_fathom:
    input:
        indir=lambda wildcards: "/Users/alison/Downloads/fathom/{floodtype}/{epoch}/{scenario}/1in{rp}/".format(
            floodtype=wildcards.FLOODTYPE,
            epoch=wildcards.EPOCH,
            scenario=wildcards.SCENARIO.replace("p", "."),
            rp=wildcards.RP
        )
    output:
        tiff="results/input/hazard-fathom-{FLOODTYPE}/raw/{FLOODTYPE}_{SCENARIO}_{EPOCH}_{RP}.tif"
    shell:
        """
        mkdir -p $(dirname {output.tiff})
        ls -1 {input.indir}/*.tif > tiles.txt
        
        # Create a VRT file first to handle the mosaic
        gdalbuildvrt temp_mosaic.vrt -input_file_list tiles.txt
        
        # Use gdal_calc to:
        # 1. Set permanent water (-32,767) to zero
        # 2. Keep no data values (-32,768) as no data
        # 3. Divide all other values by 100 to convert cm to m
        gdal_calc.py --calc="(A==-32767)*0 + (A>-32767)*(A<9999)*(A/100)" \
            --format=GTiff \
            --type=Float32 \
            -A temp_mosaic.vrt \
            --outfile={output.tiff} \
            --NoDataValue=-32768
            
        # Clean up temporary files
        rm temp_mosaic.vrt tiles.txt
        """


rule fathom_all:
    input:
        tiffs = expand(
            "results/input/hazard-fathom-{FLOODTYPE}/raw/{FLOODTYPE}_{SCENARIO}_{EPOCH}_{RP}.tif",
            FLOODTYPE=["pluvial"],
            SCENARIO=["SSP2_4p5"],
            EPOCH=["2050", "2080"],
            RP=["10", "50", "100", "500"],
        )