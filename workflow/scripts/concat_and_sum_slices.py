"""
Combine damage slices aggregated by administrative area and write out as a
single file.

Some administrative areas may straddle several slices. Group by admin area and
sum the damages such that exactly one row per admin area is output.
"""

import logging
import os
import re
import warnings

import geopandas as gpd
import pandas as pd
from tqdm import tqdm

from transport.utils import NO_GEOM_ERROR_MSG
from network_components import natural_sort


if __name__ == "__main__":
    try:
        slice_files = snakemake.input["slices"]
        columns_to_aggregate_regex = snakemake.params["columns_to_aggregate_regex"]
        admin_level_slug = snakemake.wildcards.ADMIN_SLUG
        output_file = snakemake.output["joined"]
    except NameError:
        raise RuntimeError("Must be run via snakemake.")

    logging.basicConfig(format="%(asctime)s %(message)s", level=logging.INFO)
    warnings.filterwarnings("ignore", message=".*initial implementation of Parquet.*")

    logging.info(f"Reading {len(slice_files)} slice files")

    slice_files = natural_sort(slice_files)

    dataframes: list[gpd.GeoDataFrame] = []
    for i, slice_path in tqdm(enumerate(slice_files)):

        try:
            gdf = gpd.read_parquet(slice_path)

        except ValueError as error:
            if NO_GEOM_ERROR_MSG in str(error):
                # if the input parquet file does not contain a geometry column,
                # geopandas will raise a ValueError rather than try to procede. we
                # catch that here, but check the error message - to be more
                # specific than catching and suppressing any ValueError

                # use an empty geodataframe to append instead
                gdf = gpd.GeoDataFrame([])

        dataframes.append(gdf)

    logging.info("Concatenating files")

    # pandas concat of iterable containing GeoDataFrames will return a GeoDataFrame
    concatenated: gpd.GeoDataFrame = pd.concat(dataframes)

    admin_level = int(admin_level_slug.replace("admin-level-", ""))
    area_unique_id_col = f"GID_{admin_level}"
    logging.info(f"Grouping on {area_unique_id_col=}")
    columns_to_aggregate = [col for col in concatenated.columns if re.match(columns_to_aggregate_regex, col)]
    grouped = concatenated.groupby(by=area_unique_id_col)[columns_to_aggregate].sum()
    # after grouping area_unique_id_col is the index -- now move it back to being a non-index column
    grouped = grouped.reset_index(drop=False)
    logging.info(f"Summed to {len(grouped)} areas")

    logging.info("Reattach geometry and admin area names")
    area_name_col = f"NAME_{admin_level}"
    non_hazard_columns = list(set(concatenated.columns) - set(columns_to_aggregate))
    # the concatenated dataframe may have had multiple instances of a given area, drop any duplicates
    admin_areas = concatenated[non_hazard_columns].drop_duplicates()
    grouped_with_geometry = admin_areas.merge(grouped, on=area_unique_id_col)

    folder_path = os.path.dirname(os.path.abspath(output_file))
    if not os.path.exists(folder_path):
        os.path.makedirs(folder_path)

    logging.info(f"Writing {grouped_with_geometry.shape=} to {output_file}")

    grouped_with_geometry.to_parquet(output_file)
