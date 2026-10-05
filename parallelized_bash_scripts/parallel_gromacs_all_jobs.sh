#!/bin/bash
#SBATCH --image=docker:nersc/gromacs:24.04
#SBATCH -C gpu
#SBATCH -t 16:00:00
#SBATCH -J Gromacs_GPU
#SBATCH -o Gromacs_GPU.o%j
#SBATCH -N 40
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
#SBATCH -c 32
#SBATCH --mail-user=michelle.garcia.gr@dartmouth.edu
#SBATCH --mail-type=ALL
#SBATCH -q regular
#SBATCH --account=m5201
#SBATCH --requeue
#SBATCH --open-mode=append

# usage: sbatch submit_gromacs.sh [frame_counts.tsv] [cpi_name]
#
# ONE SIMULATION PER GPU (4 per node), not one per node.
#
# Sized for ONE submission at 240 ns/GPU/day (measured).
# 454 of 500 sims unfinished; 600001 frames = 120 ns (0.2 ps/frame).
# 24.2 us remaining = 2417 GPU-hours = 604 node-hours.
#
#   nodes  GPUs  wall     margin/24h   node-hours
#     26   104   23.2 h    0.3 h       604   minimum, no room for error
#     40   160   15.1 h    8.4 h       604   <- chosen
#     60   240   10.1 h   13.4 h       604   floor: dir 57 = 99.6 ns serial
#
# Node-hours are FLAT to ~60 nodes (N x total/4N is constant), so extra nodes
# buy schedule margin for free. Past 60 they idle: dir 57 is 10 h of serial
# work no node count can split. The job exits when parallel drains, so it is
# billed for elapsed time, not the 24 h request.
#
# 454 sims >> 160 slots is intended: parallel queues them through the GPUs.
#
# `parallel` is NOT wrapped in srun: it runs on the batch node so each
# payload's srun is a normal job step, per the NERSC "grouping many small
# jobs" pattern. Each step subsets the node via --gres/--mem/--exact.

set -uo pipefail

tsv=${1:-frame_counts.tsv}
cpi_name=${2:-production}

cd "$SLURM_SUBMIT_DIR" || exit 1

if [[ ! -r $tsv ]]; then
    echo "ERROR: cannot read '$tsv' from $PWD" >&2
    exit 1
fi

gpus_per_node=4
slots=$(( SLURM_NNODES * gpus_per_node ))

# Memory per simulation: node RealMemory split gpus_per_node ways, with headroom.
# Check with: scontrol show node <nid> | grep RealMemory
mem_per_sim=${MEM_PER_SIM:-56G}

export CPI_NAME="$cpi_name"
export MEM_PER_SIM="$mem_per_sim"
export NTOMP=16          # 1 rank x -c 32 logical CPUs = 16 physical cores
export MAXH=15.8         # < the 16:00:00 wall time, so mdrun checkpoints and exits cleanly.
                         # Only a cap: a sim that reaches 600001 frames stops early
                         # and hands its GPU to the next queued sim.

# Unfinished = frames != 600001. Column 4 is the absolute realpath.
# tr -d '\r' guards against CRLF sneaking in from a Windows-side edit.
#
# Sorted LONGEST-REMAINING FIRST (LPT). In file order the biggest jobs (dirs
# 332-500, ~79 ns each) sit at the bottom and would start last, leaving a
# ragged 8 h tail. Longest-first keeps the tail made of short jobs.
tasklist="tasklist_${SLURM_JOB_ID}.txt"
tr -d '\r' < "$tsv" \
  | awk -F'\t' 'NR>1 && $2 != 600001 && $4 != "" {print (600001 - $2) "\t" $4}' \
  | sort -k1,1nr \
  | cut -f2 \
  > "$tasklist"

ntasks=$(wc -l < "$tasklist")
if (( ntasks == 0 )); then
    echo "ERROR: no unfinished simulations parsed out of '$tsv'" >&2
    exit 1
fi

mkdir -p logs

echo "=== job $SLURM_JOB_ID ==="
echo "tsv          : $tsv"
echo "unfinished   : $ntasks"
echo "nodes        : $SLURM_NNODES"
echo "gpu slots    : $slots  (${gpus_per_node}/node)"
echo "concurrency  : $slots  (1 simulation per GPU)"
echo "mem per sim  : $mem_per_sim"
echo "cpi          : $cpi_name"
echo "started      : $(date '+%F %T')"
if (( ntasks > slots )); then
    echo "NOTE: $ntasks sims > $slots GPU slots; $(( ntasks - slots )) queue until a GPU frees."
    echo "      This is intended -- see the node-count comment in the header."
fi
echo

chmod +x ./payload.sh
module load parallel 2>/dev/null || true

parallel --will-cite \
         --jobs "$slots" \
         --line-buffer \
         --joblog "parallel_${SLURM_JOB_ID}.log" \
         ./payload.sh {} \
         :::: "$tasklist"
rc=$?

echo
echo "=== parallel exited $rc at $(date '+%F %T') ==="
echo "per-task results : parallel_${SLURM_JOB_ID}.log"
echo "per-sim logs     : logs/run_<dir>.log"
exit $rc
