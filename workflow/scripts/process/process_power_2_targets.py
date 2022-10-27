"""This file processes the target data
"""
import geopandas
import numpy as np
import pandas
import rasterio
import rasterio.features
import rasterio.mask
import xarray as xr
from pyproj import Geod
from rasterstats import gen_zonal_stats
from shapely.geometry import shape


def get_target_areas(targets_file, box_geom):
    geod = Geod(ellps="WGS84")
    geoms = []
    areas_km2 = []

    # Targets: Binary raster showing locations predicted to be connected to distribution grid.
    with rasterio.open(targets_file) as dataset:
        # Read the dataset's valid data mask as a ndarray.
        box_dataset, box_transform = rasterio.mask.mask(dataset, [box_geom], crop=True)

        # Extract feature shapes and values from the array.
        for geom, val in rasterio.features.shapes(box_dataset, transform=box_transform):
            if val > 0:
                feature = shape(geom)
                geoms.append(feature)
                area_m2, _ = geod.geometry_area_perimeter(feature)
                areas_km2.append(area_m2 / 1e6)

    return geopandas.GeoDataFrame({
        "area_km2": areas_km2,
        "geometry": geoms
    })


def get_population(targets, population_file):
    stats = gen_zonal_stats(
        targets.set_crs("epsg:4326").to_crs("esri:54009").geometry,  # reprojected for raster
        population_file,
        stats=[],
        add_stats={"nansum": np.nansum},  # count NaN as zero for summation
        all_touched=True,  # possible overestimate, but targets grid is narrower than pop
    )
    populations = [d["nansum"] for d in stats]

    return populations


def get_gdp_pc(targets, gdp_file):
    gdp = xr.open_dataset(gdp_file)
    centroids = targets.geometry.centroid
    df = pandas.DataFrame({"x": centroids.x, "y": centroids.y})
    df["gdp_pc"] = df.apply(
        lambda row: float(gdp.GDP_per_capita_PPP.sel(
                longitude=row.x,
                latitude=row.y,
                time=2015,
                method="nearest"
            ).data),
        axis=1
    )
    return df.gdp_pc


if __name__ == '__main__':
    population_file = snakemake.input.population  # type: ignore
    gdp_file = snakemake.input.gdp  # type: ignore
    targets_file = snakemake.input.targets  # type: ignore
    output_file = snakemake.output.targets  # type: ignore
    global_boxes_path = snakemake.input.global_boxes  # type: ignore
    box_id = snakemake.wildcards.BOX  # type: ignore

    boxes = geopandas.read_file(global_boxes_path) \
        .set_index("box_id")
    box_geom = boxes.loc[f"box_{box_id}", "geometry"]

    targets = get_target_areas(targets_file, box_geom)
    targets["type"] = "target"
    if len(targets):
        targets["population"] = get_population(targets, population_file)
        targets["gdp_pc"] = get_gdp_pc(targets, gdp_file)
        targets["gdp"] = targets.population * targets.gdp_pc
    else:
        targets["population"] = 0
        targets["gdp_pc"] = 0
        targets["gdp"] = 0

    targets.to_parquet(output_file)
