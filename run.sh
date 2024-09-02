#!/bin/bash

# make the script stop when error (non-true exit code) is occured
set -e

############################################################
# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('conda' 'shell.bash' 'hook' 2> /dev/null)"
eval "$__conda_setup"
unset __conda_setup
# <<< conda initialize <<<
############################################################

echo "file_id: $file_id"
echo "INPUT_S3_URI: $INPUT_S3_URI"
echo "OUTPUT_S3_URI: $OUTPUT_S3_URI"

SCRIPT=`realpath -s $0`
SCRIPTDIR=`dirname $SCRIPT`
WDIR=$SCRIPTDIR
DATA_DIR="/fsx/dataset"

# CPU="8"  # number of CPUs to use
# MEM="64" # max memory (in GB)

# replace CPU/MEM to get batch env
CPU=$[$(curl -s $ECS_CONTAINER_METADATA_URI | jq '.Limits.CPU')/1024]
MEM=$[$(curl -s $ECS_CONTAINER_METADATA_URI | jq '.Limits.MEM')/1024]

echo "CPU: $CPU"
echo "MEM: $MEM"
# Inputs:

IN=$WDIR/input.fa     # input.fasta
echo "start downloading"
aws s3 cp $INPUT_S3_URI $IN --region $REGION

echo "ls WDIR"
ls $WDIR

echo "ls DATA_DIR"
ls $DATA_DIR

# mkdir -p $WDIR/log

conda activate RoseTTAFold
############################################################
# 1. generate MSAs
############################################################
MSA_START="$(date +%s)"
if [ ! -s $WDIR/t000_.msa0.a3m ]
then
    echo "Running HHblits"
    $SCRIPTDIR/input_prep/make_msa.sh $IN $WDIR $CPU $MEM $DBDIR
fi

MSA_DURATION=$[ $(date +%s) - ${MSA_START} ]
echo "MSA duration: ${MSA_DURATION} sec"

############################################################
# 2. predict secondary structure for HHsearch run
############################################################
SS_START="$(date +%s)"
if [ ! -s $WDIR/t000_.ss2 ]
then
    echo "Running PSIPRED"
    $SCRIPTDIR/input_prep/make_ss.sh $WDIR/t000_.msa0.a3m $WDIR/t000_.ss2
fi
SS_DURATION=$[ $(date +%s) - ${SS_START} ]
echo "SS duration: ${SS_DURATION} sec"

############################################################
# 3. search for templates
############################################################
TEMPLATE_START="$(date +%s)"
DB="$DBDIR/pdb100_2021Mar03/pdb100_2021Mar03"
if [ ! -s $WDIR/t000_.hhr ]
then
    echo "Running hhsearch"
    HH="hhsearch -b 50 -B 500 -z 50 -Z 500 -mact 0.05 -cpu $CPU -maxmem $MEM -aliw 100000 -e 100 -p 5.0 -d $DB"
    cat $WDIR/t000_.ss2 $WDIR/t000_.msa0.a3m > $WDIR/t000_.msa0.ss2.a3m
    $HH -i $WDIR/t000_.msa0.ss2.a3m -o $WDIR/t000_.hhr -atab $WDIR/t000_.atab -v 0
fi

TEMPLATE_DURATION=$[ $(date +%s) - ${TEMPLATE_START} ]
echo " template search duration: ${TEMPLATE_DURATION} sec"



TOTAL_DATA_PREP_DURATION=$[ $(date +%s) - ${START} ]
echo "total data prep duration: ${TOTAL_DATA_PREP_DURATION} sec"


############################################################
# 4. predict distances and orientations
############################################################
if [ ! -s $WDIR/t000_.3track.npz ]
then
    echo "Predicting distance and orientations"
    python $PIPEDIR/network/predict_pyRosetta.py \
        -m $PIPEDIR/weights \
        -i $WDIR/t000_.msa0.a3m \
        -o $WDIR/t000_.3track \
        --hhr $WDIR/t000_.hhr \
        --atab $WDIR/t000_.atab \
        --db $DB
fi


############################################################
# End-to-end prediction
############################################################
PREDICT_START="$(date +%s)"
if [ ! -s $WDIR/t000_.3track.npz ]
then
    echo "Running end-to-end prediction"    
    DB="$DBDIR/pdb100_2021Mar03/pdb100_2021Mar03"

    python $SCRIPTDIR/network/predict_e2e.py \
        -m $MODEL_WEIGHTS_DIR/weights \
        -i $WDIR/t000_.msa0.a3m \
        -o $WDIR/t000_.e2e \
        --hhr $WDIR/t000_.hhr \
        --atab $WDIR/t000_.atab \
        --db $DB
fi

aws s3 cp $WDIR/t000_.e2e.pdb $OUTPUT_S3_FOLDER/$UUID.e2e.pdb
aws s3 cp $WDIR/t000_.e2e_init.pdb $OUTPUT_S3_FOLDER/$UUID.e2e_init.pdb
aws s3 cp $WDIR/t000_.e2e.npz $OUTPUT_S3_FOLDER/$UUID.e2e.npz

TOTAL_PREDICT_DURATION=$[ $(date +%s) - ${PREDICT_START} ]
echo " prediction duration: ${TOTAL_PREDICT_DURATION} sec"

tar -czf "$WDIR/output.tar.gz" "$WDIR/t000_.e2e.pdb" "$WDIR/t000_.e2e_init.pdb" "$WDIR/t000_.e2e.npz"

aws s3 cp $WDIR/output.tar.gz $OUTPUT_S3_URI  --metadata {'"id"':'"'$file_id'"'} --region $REGION

echo "all done"