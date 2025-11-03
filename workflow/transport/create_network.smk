"""
Generic network creation rules.
"""


import logging

import geopandas as gpd
import pandas as pd

import snkit


rule create_transport_network:
    """
    Take .geoparquet OSM files and output files of cleaned network nodes and edges
    """
    input:
        nodes="{OUTPUT_DIR}/geoparquet/{DATASET}_{FILTER_SLUG}/raw/{SLICE_SLUG}_nodes.geoparquet",
        edges="{OUTPUT_DIR}/geoparquet/{DATASET}_{FILTER_SLUG}/raw/{SLICE_SLUG}_edges.geoparquet",
        admin="{OUTPUT_DIR}/input/admin-boundaries/gadm36_levels.gpkg",
        highway_surface_mapping = "config/highway_surface_to_paved.csv"
    output:
        nodes="{OUTPUT_DIR}/geoparquet/{DATASET}_{FILTER_SLUG}/processed/{SLICE_SLUG}_nodes.geoparquet",
        edges="{OUTPUT_DIR}/geoparquet/{DATASET}_{FILTER_SLUG}/processed/{SLICE_SLUG}_edges.geoparquet"
    params:
        # determine the network type from the filter, e.g. road, rail
        # example FILTER_SLUG values might be 'filter-road-tertiary' or 'filter-rail'
        network_type=lambda wildcards: wildcards.FILTER_SLUG.split('-')[1],
        # pass in the slice number so we can label edges and nodes with their slice
        # edge and node IDs should be unique across all slices
        slice_number=lambda wildcards: int(wildcards.SLICE_SLUG.replace('slice-', ''))
    script:
        # template the path string with a value from params (can't execute .replace in `script` context)
        "./create_{params.network_type}_network.py"

"""
Test with:
snakemake --cores all results/geoparquet/tanzania-mini_filter-road/processed/slice-0_edges.geoparquet
"""


def transport_network_paths_from_file(wildcards) -> list[str]:
    """
    Lookup composite network components from file and return list of paths to
    their edge files.
    """
    df = pd.read_csv(
        config["composite_network"][wildcards.COMPOSITE],
        comment="#",
    )
    edge_paths = df.apply(
        lambda row:
        f"{wildcards.OUTPUT_DIR}/{row.infrastructure_dataset}_filter-{row.network_filter}/edges.gpq",
        axis=1
    )
    node_paths = [path.replace("edges.gpq", "nodes.gpq") for path in edge_paths]
    return {"component_nodes": node_paths, "component_edges": edge_paths}


rule create_composite_transport_network:
    """
    Stitch together a set of transport networks into one file. These should be
    the same transport mode. May be used for creating networks of spatially
    varying density.
    """
    input:
        unpack(transport_network_paths_from_file)
    output:
        composite_nodes = "{OUTPUT_DIR}/composite_network/{COMPOSITE}/nodes.gpq",
        composite_edges = "{OUTPUT_DIR}/composite_network/{COMPOSITE}/edges.gpq"
    run:
        logging.basicConfig(format="%(asctime)s %(process)d %(filename)s %(message)s", level=logging.INFO)

        logging.info("Concatenate nodes and edges")

        # f"{wildcards.OUTPUT_DIR}/{row.infrastructure_dataset}_filter-{row.network_filter}/edges.gpq",
        def extract_filter_and_dataset(node_path:str):
            slug = node_path.split("/")[-2]
            dataset, filt = slug.split("_filter-")
            return dataset, filt

        def check_edges_in_nodes(edges, nodes):
            """
            Check that all edges have a corresponding node.
            """
            edge_ids = set(edges["from_id"].unique()).union(set(edges["to_id"].unique()))
            node_ids = set(nodes["id"].unique())
            missing_edges = edge_ids - node_ids
            if missing_edges:
                raise ValueError(f"{len(missing_edges)=} do not have corresponding nodes.")
            else:
                print("All edges have corresponding nodes.")

        def process_id_cols(row, id_col="id"):
            id_str = row[id_col]
            filt_str = row["filter"]
            dataset = row["dataset"]
            combined = f"{dataset}_{filt_str}"
            id_str = id_str.replace(dataset, combined)
            return id_str

        nodes = []
        for node_path in input.component_nodes:
            node_tmp = gpd.read_parquet(node_path)
            # dataset, filt = extract_filter_and_dataset(node_path)
            # node_tmp["dataset"] = dataset
            # node_tmp["filter"] = filt
            # node_tmp["id"] = node_tmp.apply(process_id_cols, axis=1)
            # print(f"{dataset=}, {filt=}")
            nodes.append(node_tmp)
        
        edges = []
        for edge_path in input.component_edges:
            edge_tmp = gpd.read_parquet(edge_path)
            dataset, filt = extract_filter_and_dataset(edge_path)
            # edge_tmp["dataset"] = dataset
            # edge_tmp["filter"] = filt
            # edge_tmp["from_id"] = edge_tmp.apply(lambda row: process_id_cols(row, id_col="from_id"), axis=1)
            # edge_tmp["to_id"] = edge_tmp.apply(lambda row: process_id_cols(row, id_col="to_id"), axis=1)
            # print(f"{dataset=}, {filt=}")
            edges.append(edge_tmp)

        for edges_tmp, nodes_tmp in zip(edges, nodes):
            check_edges_in_nodes(edges_tmp, nodes_tmp)

        network = snkit.network.Network(
            nodes=pd.concat(nodes).reset_index(drop=True),
            edges=pd.concat(edges).reset_index(drop=True),
        )

        check_edges_in_nodes(network.edges, network.nodes)

        # ! maybe the issue is here
        logging.info("Labelling edge ends with from/to node ids")
        network = snkit.network.add_topology(network)
        check_edges_in_nodes(network.edges, network.nodes)

        logging.info("Labelling edges and nodes with network component ids")
        network = snkit.network.add_component_ids(network)
        check_edges_in_nodes(network.edges, network.nodes)

        logging.info("Writing network to disk")
        network.nodes.to_parquet(output.composite_nodes)
        network.edges.to_parquet(output.composite_edges)

"""
Test with:
snakemake -c1 -- results/composite_network/south-east-asia-road/edges.gpq
"""
