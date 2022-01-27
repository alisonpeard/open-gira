FROM ubuntu:20.04

# Silence interactive installations
ENV DEBIAN_FRONTEND=noninteractive

# Install required software tools
RUN apt update
RUN apt install -y \
    build-essential \
    cmake \
    git \
    libboost-program-options-dev \
    libexpat1-dev \
    libbz2-dev \
    python3 \
    python3-pip \
    unzip \
    wget \
    zlib1g-dev

# git install remaining tools
RUN git clone https://github.com/mapbox/protozero && \
    git clone --branch v2.17.1 --depth 1 https://github.com/osmcode/libosmium && \
    git clone --branch v1.13.2 --depth 1 https://github.com/osmcode/osmium-tool

# Build osmium
RUN cd osmium-tool && \
    mkdir build && \
    cd build && \
    cmake .. && \
    make && \
    cd ../..
# Create a symlink so we can access it from anywhere on the command line
RUN cp -s /osmium-tool/build/osmium /usr/bin/osmium

# Clone the repository
RUN git clone https://github.com/nismod/open-gira.git
RUN mkdir open-gira/data && \
    mkdir open-gira/data/aqueduct

# Install Python requirements with pip
RUN pip install -r open-gira/requirements.txt

# Download datafile (around 500MB)
RUN wget https://download.geofabrik.de/africa/tanzania-latest.osm.pbf \
    --output-document=open-gira/data/tanzania-latest.osm.pbf

# Download hazard data (about 200MB)
RUN wget https://zenodo.org/record/5887564/files/aqueduct_TZA.zip?download=1 \
    --output-document=/aqueduct_TZA.zip && \
    unzip /aqueduct_TZA.zip -d open-gira/data/aqueduct && \
    mv -f open-gira/data/aqueduct/aqueduct_TZA/* open-gira/data/aqueduct

# Create the extracts file
RUN echo '{"directory":"./data","extracts":\
    [{"bbox": [29.24395,-11.775945,40.69487,-0.974988],\
    "output": "tanzania-latest.osm.pbf"}]}' >> open-gira/tanzania-latest.json

# Prep the extracts
RUN cd open-gira && \
    python3 prepare-extracts.py tanzania-latest.json 3

# Showtime
RUN cd open-gira && snakemake --cores all -R slice
RUN cd open-gira && snakemake --cores all -R filter_osm_data
RUN cd open-gira && snakemake --cores all -R convert_to_geoparquet
RUN cd open-gira && snakemake --cores all -R network_hazard_intersection
RUN cd open-gira && snakemake --cores all -R join_data
RUN cd open-gira && snakemake --cores all -R all
RUN cd open-gira && snakemake --cores all -R clean
