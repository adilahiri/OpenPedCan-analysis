#!/bin/bash
# C. Savonen
# CCDL for ALSF 2019

# Purpose: Run a consensus analysis for PBTA of SNV callers

# Set this so the whole loop stops if there is an error
set -e
set -o pipefail

# Usage: project acronym to use as prefix for input out files 
usage(){ echo "Usage: $0 [-h] [-p <project acronyn>]" 1>&2; exit 1; }

while getopts ":hp:" opt; do
    case "${opt}" in
	h)
	    usage
	    ;;
	p)
	    project_acronym=$OPTARG
	    ;;
	:)
	    printf "missing argument for -%s\n" "$OPTARG" 1>&2
	    usage
	    ;;
	\?)
	    printf "illegal option: -%s\n" "$OPTARG" 1>&2
	    usage
	    ;;
    esac
done
shift $((OPTIND - 1))

if [ -z "${project_acronym}" ]; then
    usage
fi

# The sqlite database made from the callers will be called:
dbfile=scratch/snv_db.sqlite

# Designate output file
consensus_file=analyses/snv-callers/results/consensus/${project_acronym}-consensus-mutation.maf.tsv

# BED and GTF file paths
cds_file=scratch/gencode.v27.primary_assembly.annotation.bed
wgs_bed=scratch/intersect_strelka_mutect_WGS.bed

# Set a default for the VAF filter if none is specified
vaf_cutoff=${OPENPBTA_VAF_CUTOFF:-0}

# Unless told to run the plots, the default is to skip them
# To run plots, set OPENPBTA_PLOTS to 1 or more
run_plots_nb=${OPENPBTA_PLOTS:-0}

################################ Set Up Database ################################
python3 analyses/snv-callers/scripts/01-setup_db.py \
  --db-file $dbfile \
  --strelka-file data/${project_acronym}-snv-strelka2.vep.maf.gz \
  --mutect-file data/${project_acronym}-snv-mutect2.vep.maf.gz \
  --lancet-file data/${project_acronym}-snv-lancet.vep.maf.gz \
  --vardict-file data/${project_acronym}-snv-vardict.vep.maf.gz \
  --meta-file data/${project_acronym}-histologies.tsv

##################### Merge callers' files into total files ####################
Rscript analyses/snv-callers/scripts/02-merge_callers.R \
  --db_file $dbfile \
  --output_file $consensus_file \
  --vaf_filter $vaf_cutoff \
  --overwrite

########################## Add consensus to db ################################
python3 analyses/snv-callers/scripts/01-setup_db.py \
  --db-file $dbfile \
  --consensus-file $consensus_file

############# Create intersection BED files for TMB calculations ###############
# Make All mutations BED files
bedtools intersect \
  -a data/WGS.hg38.strelka2.unpadded.bed \
  -b data/WGS.hg38.mutect2.vardict.unpadded.bed \
  > $wgs_bed

#################### Make coding regions file
# Convert GTF to BED file for use in bedtools
# Here we are only extracting lines with as a CDS i.e. are coded in protein
gunzip -c data/gencode.v27.primary_assembly.annotation.gtf.gz \
  | awk '$3 ~ /CDS/' \
  | convert2bed --do-not-sort --input=gtf - \
  | sort -k 1,1 -k 2,2n \
  | bedtools merge  \
  > $cds_file

######################### Calculate consensus TMB ##############################
Rscript analyses/snv-callers/scripts/03-calculate_tmb.R \
  --db_file $dbfile \
  --output analyses/snv-callers/results/consensus \
  --metadata data/${project_acronym}-histologies.tsv \
  --coding_regions $cds_file \
  --overwrite \
  --nonsynfilter_maf \
  --project_acronym ${project_acronym}

########################## Compress consensus file #############################

gzip $consensus_file

############################# Comparison Plots #################################
if [ "$run_plots_nb" -gt "0" ]
then
    Rscript -e "rmarkdown::render('analyses/snv-callers/compare_snv_callers_plots.Rmd', output_file = paste0('compare_snv_callers_plots-', '${project_acronym}'), params = list(project_acronym = '${project_acronym}'), clean = TRUE)"
fi
