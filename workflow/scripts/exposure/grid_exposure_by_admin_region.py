"""
For a given country and storm set, aggregate storm exposure estimates to some
administrative level.

Write out expected annual exposure (fraction of region's grid edges total
length exposed to winds in excess of a threshold).
"""


import logging
import sys

import geopandas as gpd
import pandas as pd


if __name__ == "__main__":

    logging.basicConfig(format="%(asctime)s %(process)d %(filename)s %(message)s", level=logging.INFO)

    # load network edges
    logging.info("Loading edges")
    edges: gpd.GeoDataFrame = gpd.read_parquet(snakemake.input.grid_edges)
    if edges.empty is True:
        logging.info("No grid representation, write out empty exposure")
        gpd.GeoDataFrame({"geometry": []}, crs=4326).to_parquet(snakemake.output.total_exposure_by_region)
        sys.exit(0)

    edges = edges[["id", "geometry"]]
    edges = edges.rename(columns={"id": "edge"}).set_index("edge")
    edges = edges.set_crs(epsg=4326)
    # calculate length of each edge (transmission and distribution lines)
    edges["nominal_length_m"] = edges.to_crs(edges.estimate_utm_crs()).geometry.length

    # load aggregation regions for level and country in question
    logging.info("Loading regions")
    admin: gpd.GeoDataFrame = gpd.read_parquet(snakemake.input.admin_areas)
    admin_level = int(snakemake.wildcards.ADMIN_SLUG.split("-")[-1])
    regions: gpd.GeoDataFrame = \
        admin[admin.GID_0 == snakemake.wildcards.COUNTRY_ISO_A3][[f"NAME_{admin_level}", f"GID_{admin_level}", "geometry"]]

    # load tracks (we will lookup storm dates from here)
    logging.info("Loading tracks")
    tracks: pd.DataFrame = pd.read_parquet(snakemake.input.tracks, columns=["track_id", "year"])
    track_year: pd.DataFrame = tracks.drop_duplicates("track_id").set_index("track_id")

    logging.info("Reading exposure by storm by edge")
    # storm-edge rows (repeated edges), threshold value columns, values are exposed length in meters for a given storm
    exposure_all_storms: pd.DataFrame = pd.read_parquet(snakemake.input.exposure_by_edge_by_event)
    if exposure_all_storms.empty is True:
        logging.info("No exposure data, write out empty exposure")
        gpd.GeoDataFrame({"geometry": []}, crs=4326).to_parquet(snakemake.output.total_exposure_by_region)
        sys.exit(0)

    # calculate number of years between first and last storm event, necessary for expected annual exposure
    event_ids: list[str] = list(set(exposure_all_storms.event_id))
    years: set[int] = set(track_year.loc[event_ids, "year"])
    span_years: int = max([1, max(years) - min(years)])  # with a minimum of one

    # create a lookup between edge id and the region to which the edge's representative point lies within
    logging.info("Creating edge to region mapping")
    # filter out edges that are never exposed, we don't need to do an expensive sjoin on them
    edge_rep_points: gpd.GeoDataFrame = edges.loc[edges.reset_index().edge.isin(exposure_all_storms.index)].copy()
    edge_rep_points.geometry = edge_rep_points.geometry.representative_point()
    edge_to_region_mapping: pd.DataFrame = edge_rep_points.sjoin(regions, how="left").drop(columns=["geometry", "index_right"])

    # TODO: per region event distributions?

    exposure_all_storms = exposure_all_storms.reset_index().drop(columns="event_id").set_index("edge")

    logging.info("Aggregating to region level")
    # edge rows, threshold value columns, values are exposed length in meters as a result of all storms
    exposure_total = exposure_all_storms.groupby("edge").sum()
    # merge with regions and sum edges across regions
    exposure_by_region = \
        edge_to_region_mapping.drop(columns=[f"NAME_{admin_level}"]).merge(exposure_total, on="edge").groupby(f"GID_{admin_level}").sum()
    # take the exposure lengths and divide by the product of original, undamaged lengths and years passing between first and last storm
    # this division is aligned on the indicies (both set to edge ids)
    # we now have an expected annual exposure
    logging.info("Calculating expected annual exposure")
    exposure_fraction_by_region = \
        exposure_by_region.drop(columns=["nominal_length_m"]).divide(exposure_by_region["nominal_length_m"] * span_years, axis=0)
    # merge geometry and name columns back in
    exposure_with_geometry = \
        exposure_fraction_by_region.merge(regions[[f"NAME_{admin_level}", f"GID_{admin_level}", "geometry"]], on=f"GID_{admin_level}", how="right")
    # merge nominal lengths by region back in, too
    exposure_with_length = exposure_with_geometry.merge(exposure_by_region[["nominal_length_m"]], on=f"GID_{admin_level}")
    # write out to disk
    logging.info("Writing out with region geometry")
    gpd.GeoDataFrame(exposure_with_length).to_parquet(snakemake.output.total_exposure_by_region)
