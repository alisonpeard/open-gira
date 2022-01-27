"""Takes a region and finds the box box_ids within it, exports as a list."""

#!/usr/bin/env python
# coding: utf-8


import numpy as np
import pandas as pd
import json
import netCDF4 as nc4
import sys
import geopandas as gpd
import os
from shapely.geometry import box

# TODO: remove below lines once testing complete and solely on linux
if "linux" not in sys.platform:
    path = """C:\\Users\\maxor\\Documents\\PYTHON\\GIT\\open-gira"""
    os.chdir(path)
    region = "SP"

else:
    region = sys.argv[1]


gdf_box = gpd.read_file(os.path.join("data", "processed", "world_boxes.gpkg"))
fn = os.path.join("data", "stormtracks", "fixed", f"STORM_FIXED_RETURN_PERIODS_{region}.nc")
ds = nc4.Dataset(fn)
lon_min, lat_min, lon_max, lat_max = min(ds['lon']), min(ds['lat']), max(ds['lon']), max(ds['lat'])
region_box = box(lon_min, lat_min, lon_max, lat_max)
gdf_boxes_in_region = gdf_box.overlay(gpd.GeoDataFrame({'geometry':[region_box]}, crs="EPSG:4326"), how='intersection')
boxes_in_region = list(gdf_boxes_in_region['box_id'])

with open(os.path.join('data', 'processed', 'world_boxes_metadata.txt'), 'r') as filejson:
    box_country_dict = json.load(filejson)['box_country_dict']

boxes_in_region_copy = boxes_in_region.copy()
for box_id in boxes_in_region_copy:
    if not box_country_dict[box_id]:  # no countries in box
        boxes_in_region.remove(box_id)
        continue
    gridfinder_box = gpd.read_file(os.path.join("data", "processed", "all_boxes", box_id, f"gridfinder_{box_id}.gpkg"))
    if len(gridfinder_box) == 1 and gridfinder_box['geometry'].iloc[0] == None:  # no infrastructure in box
        boxes_in_region.remove(box_id)
        print(f"{box_id} contains land but is empty")

region_path = os.path.join('data', 'intersection', 'regions')
if not os.path.exists(region_path):
    os.makedirs(region_path)

with open(os.path.join(region_path, f'{region}_boxes.txt'), 'w') as jsondump:
    json.dump(boxes_in_region, jsondump)




