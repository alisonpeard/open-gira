"""
Process gridfinder elements for each box
"""

GENERATORS_LINES_CONSUMERS_ALL_BOXES = (
    expand(
        [
            os.path.join(
                config["output_dir"],
                "power_processed",
                "all_boxes",
                "{box_id}",
                "plants_{box_id}.gpkg",
            ),
            os.path.join(
                config["output_dir"],
                "power_processed",
                "all_boxes",
                "{box_id}",
                "network_{box_id}.gpkg",
            ),
            os.path.join(
                config["output_dir"],
                "power_processed",
                "all_boxes",
                "{box_id}",
                "targets_{box_id}.gpkg",
            ),
        ],
        box_id=ALL_BOXES,
    ),
)


rule process_network:
    conda: "../../../environment.yml"
    input:
        os.path.join(
            config["output_dir"],
            "power_processed",
            "all_boxes",
            "{box_id}",
            "powerplants_{box_id}.csv",
        ),
        os.path.join(
            config["output_dir"],
            "power_processed",
            "all_boxes",
            "{box_id}",
            "targets_{box_id}.csv",
        ),
        os.path.join(
            config["output_dir"],
            "power_processed",
            "all_boxes",
            "{box_id}",
            "gridfinder_{box_id}.gpkg",
        ),
        rules.world_splitter.output.global_metadata,
    output:
        os.path.join(
            config["output_dir"],
            "power_processed",
            "all_boxes",
            "{box_id}",
            "plants_{box_id}.gpkg",
        ),
        os.path.join(
            config["output_dir"],
            "power_processed",
            "all_boxes",
            "{box_id}",
            "network_{box_id}.gpkg",
        ),
        os.path.join(
            config["output_dir"],
            "power_processed",
            "all_boxes",
            "{box_id}",
            "targets_{box_id}.gpkg",
        ),
    params:
        box_id="{box_id}",
        output_dir=config["output_dir"],
    script:
        os.path.join("..", "..", "scripts", "process", "process_power_4_network.py")
