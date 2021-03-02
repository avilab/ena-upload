import pandas as pd
from snakemake.utils import validate
import os
import re


# Upload config.
configfile: "data/config.yaml"


# Path to snakemake wrappers repository.
WRAPPER_PREFIX = "https://raw.githubusercontent.com/avilab/virome-wrappers"

# Path to indexed host genome. Set HOST_GENOME environment variable or use path directly.
HOST_GENOME = os.environ["HOST_GENOME"]

# Text file with full paths to raw reads, one per line. Specify path in data/config.yaml.
with open(config["batches"], "r") as h:
    batches = h.read().splitlines()

# Parse run names. Adjust regex '_R[1,2]_001.fastq.gz' to match your file pattern if required.
RUNS = list(
    set([re.sub("_R[1,2]_001.fastq.gz", "", e.split("/")[-1:][0]) for e in batches])
)

# Function to match read pair to run.
def get_reads(wildcards):
    pair = [e for e in batches if wildcards.run in e]
    input = {}
    for e in pair:
        input.update({"in1": e} if re.search("_R1", e) else {"in2": e})
    return input


# Workflow target.
rule all:
    input:
        "output/upload.done",


# Generate study and sample metadata excel spreadsheet.
rule form:
    input:
        samples="data/sample_metadata.csv",
        batches="data/batches.txt",
        config="data/config.yaml",
    output:
        xlsx="output/ena_submission.xlsx",
        data="output/data.txt",
    log:
        "logs/form.log",
    shell:
        """
        (Rscript scripts/submission-metadata-excel.R -s {input.samples} -b {input.batches} -c {input.config} -x {output.xlsx} -d {output.data}) 2> {log}
        """


# Generate metadata files from excel spreadsheets.
rule parse_form:
    input:
        rules.form.output.xlsx,
    output:
        study="output/studies.tsv",
        sample="output/samples.tsv",
        experiment="output/experiments.tsv",
        run="output/runs.tsv",
    log:
        "logs/parse_form.log",
    params:
        extra="--action add --vir",
    shell:
        """
        (python scripts/process_xlsx.py --form {input[0]} --out_dir output {params.extra}) 2> {log}
        """


# Quality trimming.
rule trim:
    input:
        unpack(get_reads),
    output:
        out1=temp("output/data/{run}_R1_trimmed.fastq.gz"),
        out2=temp("output/data/{run}_R2_trimmed.fastq.gz"),
    log:
        "logs/{run}_trim.log",
    params:
        extra=(
            "ref=adapters ktrim=r k=23 mink=11 hdist=1 tpe tbo qtrim=r trimq=10 ordered"
        ),
    resources:
        runtime=lambda wildcards, attempt: 180 + (attempt * 60),
        mem_mb=16000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/bbduk"


# Remove host sequences.
rule maphost:
    input:
        in1=rules.trim.output.out1,
        in2=rules.trim.output.out2,
        ref=HOST_GENOME,
    output:
        outu=temp("output/data/{run}_interleaved_clean.fastq.gz"),
        statsfile="output/data/{run}_maphost.txt",
    log:
        "logs/{run}_maphost.log",
    params:
        extra="minid=0.95 maxindel=3 bwr=0.16 bw=12 quickmatch fast minhits=2 qtrim=rl trimq=10 untrim usemodulo",
    resources:
        runtime=lambda wildcards, attempt: attempt * 360,
        mem_mb=16000,
    threads: 8
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/bbwrap"


# Convert PE interleaved reads to pair.
rule reformat:
    input:
        rules.maphost.output.outu,
    output:
        out="output/data/{run}_R1_clean.fastq.gz",
        out2="output/data/{run}_R2_clean.fastq.gz",
    log:
        "logs/{run}_reformat.log",
    params:
        extra="",
    resources:
        runtime=360,
        mem_mb=4000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/reformat"


# Upload new study or samples to ENA. When adding new samples to study, omit study table.
rule upload:
    input:
        expand("output/data/{run}_R{pair}_clean.fastq.gz", run=RUNS, pair=[1, 2]),
        study=rules.parse_form.output.study,
        sample=rules.parse_form.output.sample,
        experiment=rules.parse_form.output.experiment,
        run=rules.parse_form.output.run,
        data=rules.form.output.data,
    output:
        "output/upload.done",
    log:
        "logs/upload.log",
    params:
        action="add",
        data="/Users/taavi/Projects/sarscov2-upload/.tests/reads/projects/covid/*/*fastq.gz",
        center=config["center"],
        secret=".secret.yml",
        extra="--dev --vir",
    resources:
        runtime=360,
        mem_mb=4000,
    shell:
        """
        (/Users/taavi/miniconda3/envs/ena_upload/bin/ena-upload-cli --action {params.action} \
        --sample {input.sample} \
        --experiment {input.experiment} \
        --run {input.run} \
        --data {params.data} \
        --center {params.center} \
        --secret {params.secret} \
        {params.extra} \
        && touch {output[0]}) > {log}       
        """
