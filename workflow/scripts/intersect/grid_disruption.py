"""
For each maximum wind field associated with a storm:
    1) Fail edge segments who experience a wind speed greater than given threshold
    2) Attempt to allocate power from sources to sinks over degraded network
    3) Calculate ratio of nominal power to degraded power, the 'supply factor'
    4) Estimate number of customers affected
"""

import logging
import multiprocessing
import os
from typing import Optional
import sys

import geopandas as gpd
import numpy as np
import pandas as pd
import xarray as xr

from open_gira import fields
from open_gira.grid import weighted_allocation
import snkit


# coordinates that the exposure variables can be indexed by
EXPOSURE_COORDS: dict[str, type] = {
    "event_id": str,
    "threshold": float,
    "target": int,
}


def process_storm(
    storm_id: xr.DataArray,
    wind_fields: xr.DataArray,
    splits: pd.DataFrame,
    speed_thresholds: list,
    network: snkit.network.Network,
    damages_dir: str,
) -> None:
    """
    Wrapper for degrade_grid_with_storm, handles writing files.
    """

    exposure = degrade_grid_with_storm(storm_id, wind_fields, splits, speed_thresholds, network)

    if exposure is not None:
        filename = f"{str(storm_id.values)}.nc"
        exposure.to_netcdf(
            os.path.join(damages_dir, filename),
            encoding={variable: {"zlib": True, "complevel": 9} for variable in exposure.keys()}
        )


def degrade_grid_with_storm(
    storm_id: xr.DataArray,
    wind_fields: xr.DataArray,
    splits: pd.DataFrame,
    speed_thresholds: list,
    network: snkit.network.Network
) -> Optional[xr.Dataset]:
    """
    Use a maximum wind speed field and a electricity grid representation,
    degrade the network for a set of damage speed thresholds. Estimate the
    reduction in available supply and number of customers affected.

    Args:
        storm_id: String ID of storm to simulate
        wind_fields: Maximum wind speeds experienced in gridded domain.
        splits: Electricity grid split over raster grid. Note that `splits`
            should contain two columns to positionally index `wind_fields`
        speed_thresholds: List of wind speeds to fail network edges at. Should
            be in the same units as `wind_fields`.
        network: Network representation of electricity grid. Edges should have
            topology. Nodes should have an `asset_type` and where `asset_type`
            is 'target', there should be a nominal power consumption allocated.

    Returns:
        Dataset containing supply_factor and customers_affected variables on
            event_id, threshold and target dimensions. In the case where the
            network is not damaged at any threshold, return `None`.
    """

    # rank 1, length of splits DataFrame
    # N.B. to index at points rather than the cross-product of indicies, index with DataArrays
    # https://docs.xarray.dev/en/stable/user-guide/indexing.html#vectorized-indexing
    max_wind_speeds: xr.DataArray = wind_fields.sel(event_id=storm_id).isel(
        longitude=splits[fields.RASTER_I].to_xarray(),
        latitude=splits[fields.RASTER_J].to_xarray()
    )

    # build coordinates for results object
    # N.B. we have a generic node 'id' but also a 'target_id' which should only
    # be set for target nodes -- it is globally unique and corresponds to the
    # global targets file (which contains their vector geometry)
    target_ids = network.nodes[network.nodes.asset_type == "target"].target_id.astype(int).values
    return_shape = (1, len(speed_thresholds), len(target_ids))
    # object for collating results from each damage threshold
    exposure = xr.Dataset(
        data_vars=dict(
            supply_factor=(EXPOSURE_COORDS.keys(), np.full(return_shape, np.nan)),
            customers_affected=(EXPOSURE_COORDS.keys(), np.full(return_shape, np.nan))
        ),
        coords=dict(
            # scalar dimensions result in ValueError, use atleast_1d as workaround
            # https://stackoverflow.com/a/58858160
            event_id=np.atleast_1d(storm_id),
            threshold=np.atleast_1d(speed_thresholds),
            target=np.atleast_1d(target_ids)
        )
    )

    # sort into ascending order; if no damage at a given threshold,
    # more resilient thresholds are guaranteed to be safe
    for threshold in sorted(speed_thresholds):
        survival_mask: pd.Series = (max_wind_speeds < threshold).to_pandas()

        try:
            n_failed: int = survival_mask.value_counts()[False]
        except KeyError:
            # at the lowest threshold there is no damage, return None
            if threshold == min(speed_thresholds):
                return None
            # some damage has occured, but not at this threshold, return exposure as it stands
            else:
                return exposure

        surviving_edge_ids = set(splits.loc[survival_mask, "id"])
        surviving_edges: pd.DataFrame = network.edges.loc[network.edges.id.isin(surviving_edge_ids), :]
        surviving_network = snkit.network.Network(
            edges=surviving_edges.copy(),
            nodes=network.nodes.copy()
        )

        # check topology of degraded network
        surviving_network = snkit.network.add_component_ids(surviving_network)
        c_nominal = len(set(network.nodes.component_id))
        c_surviving = len(set(surviving_network.nodes.component_id))

        fraction_failed: float = n_failed / len(survival_mask)
        failure_str = "{:s} -> {:.2f}% edges failed @ {:.1f} [m/s] threshold, {:d} -> {:d} components"
        logging.info(failure_str.format(str(storm_id.values), 100 * fraction_failed, threshold, c_nominal, c_surviving))

        # about to mutate power_mw column, make a copy first
        surviving_network.nodes["power_nominal_mw"] = surviving_network.nodes["power_mw"]

        # allocate power within components, from sources to targets, weighted by gdp of targets
        targets: pd.DataFrame = weighted_allocation(
            surviving_network.nodes,
            variable_col="power_mw",
            weight_col="gdp",
            component_col="component_id",
            asset_col="asset_type",
            source_name="source",
            sink_name="target",
        )

        # calculate ratio of degraded power supply to nominal power supply
        targets["supply_factor"] = targets.power_mw / targets.power_nominal_mw

        # calculate the number of customers affect in each target
        # N.B. supply factor can be > 1, so clip to zero to prevent negative customers_affected in areas with 'oversupply'
        targets["customers_affected"] = np.clip(1 - targets.supply_factor, 0, None) * targets.population

        # assign data to dataset
        indicies = dict(event_id=storm_id, threshold=threshold, target=targets.target_id.astype(int).values)
        exposure.supply_factor.loc[indicies] = targets.supply_factor
        exposure.customers_affected.loc[indicies] = targets.customers_affected

    return exposure


if __name__ == "__main__":

    edges_path: str = snakemake.input.grid_edges
    nodes_path: str = snakemake.input.grid_nodes
    splits_path: str = snakemake.input.grid_splits
    wind_speeds_path: str = snakemake.input.wind_speeds
    speed_thresholds: list[float] = snakemake.config["transmission_windspeed_failure"]
    n_proc: int = snakemake.config["processes_per_parallel_job"]
    damages_dir_path: str = snakemake.output.damages

    logging.basicConfig(format="%(asctime)s %(process)d %(filename)s %(message)s", level=logging.INFO)

    logging.info("Loading wind speed data")
    wind_fields: xr.Dataset = xr.open_dataset(wind_speeds_path)
    if len(wind_fields.variables) == 0:
        logging.info("Empty wind speed file, writing empty directory to disk.")
        os.makedirs(damages_dir_path)
        sys.exit(0)

    logging.info(wind_fields.max_wind_speed)  # use xarray repr

    logging.info("Loading network data")
    network = snkit.network.Network(
        edges=gpd.read_parquet(edges_path),
        nodes=gpd.read_parquet(nodes_path)
    )
    splits: pd.DataFrame = pd.read_parquet(splits_path)
    logging.info(f"{len(network.edges)} network edges")
    logging.info(f"{len(network.nodes)} network nodes")

    logging.info(f"Using damage thresholds: {speed_thresholds} [m/s]")

    logging.info("Simulating electricity network failure due to wind damage...")

    # directory for per-event output files
    os.makedirs(damages_dir_path)

    args = (
        (storm_id, wind_fields.max_wind_speed, splits, speed_thresholds, network, damages_dir_path)
        for storm_id in wind_fields.event_id
    )
    exposure_by_storm: list[Optional[xr.Dataset]] = []
    if n_proc > 1:
        with multiprocessing.Pool(processes=n_proc) as pool:
            exposure_by_storm = pool.starmap(process_storm, args)
    else:
        for arg in args:
            exposure_by_storm.append(process_storm(*arg))
