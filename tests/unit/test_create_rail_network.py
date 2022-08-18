import os
import sys

from . import runner


def test_create_rail_network():
    """
    N.B. this test requires country geometry data to annotate nodes and edges
    the data is stored in the input gadm36_levels.gpkg file. This has been
    manually subsetted from the global file to Djibouti and the three
    neighbouring countries: Eritrea, Somalia and Ethiopia.
    """
    runner.run_test(
        "create_rail_network",
        (
            "snakemake results/geoparquet/djibouti-latest_filter-rail/processed/slice-0_nodes.geoparquet "
            "results/geoparquet/djibouti-latest_filter-rail/processed/slice-0_edges.geoparquet "
            "-j1 --keep-target-files"
        ),
    )
