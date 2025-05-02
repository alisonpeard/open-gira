"""
>>> cd ~/Local/github/open-gira
>>> conda activate open-gira
>>> snakemake --cores 6 -- fathom_all

Then add fathom-pluvial to hazard_types and hazard datasets in config.yaml

snakemake --cores 6 -- results/direct_damages/somalia-latest_filter-{road-primary,road-secondary,road-tertiary,road-residential}/hazard-fathom-pluvial/EAD_and_cost_per_RP/slice-{0..63}.geoparquet
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
        tiff="results/input/hazard-fathom-{FLOODTYPE}/raw/fathom_{SCENARIO}_{EPOCH}_{RP}.tif"
    shell:
        """
        mkdir -p $(dirname {output.tiff})
        ls -1 {input.indir}/*.tif > tiles.txt
        gdal_merge -o {output.tiff} --optfile tiles.txt
        """


rule fathom_all:
    input:
        tiffs = expand(
            "results/input/hazard-fathom-{FLOODTYPE}/raw/fathom_{SCENARIO}_{EPOCH}_{RP}.tif",
            FLOODTYPE=["pluvial"],
            SCENARIO=["SSP2_4p5"],
            EPOCH=["2050", "2080"],
            RP=["10", "50", "100", "500"],
        )