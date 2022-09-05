rule intersect_region_with_boxes:
    """
    Determine the boxes within a given region
    """
    input:
        global_boxes_metadata = rules.world_splitter.output.global_metadata,
        global_boxes = rules.world_splitter.output.global_boxes,
        basin_geometry = rules.download_storm_basin_geometry.output.geometry
    params:
        # to use wildcards in params, pass function which can be later evaluated
        region_name = lambda wildcards: wildcards.STORM_BASIN,
        output_dir = config["output_dir"]
    output:
        boxes_in_region = "{OUTPUT_DIR}/power_intersection/regions/{STORM_BASIN}_boxes.json",
        boxes_in_region_with_assets = "{OUTPUT_DIR}/power_intersection/regions/{STORM_BASIN}_boxes_with_assets.json"
    script:
        os.path.join("..", "..", "scripts", "intersect", "intersect_1_regions.py")
