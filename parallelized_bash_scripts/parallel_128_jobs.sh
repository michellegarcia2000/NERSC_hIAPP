#!/bin/bash
#SBATCH --image=docker:nersc/gromacs:24.04
#SBATCH -C gpu
#SBATCH -t 03:58:00
#SBATCH -J Gromacs_GPU
#SBATCH -o Gromacs_GPU.o%j
#SBATCH -N 128
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
#SBATCH --gpus-per-task=1
#SBATCH -c 32
#SBATCH --mail-user=michelle.garcia.gr@dartmouth.edu
#SBATCH --mail-type=ALL
#SBATCH -q regular
#SBATCH --account=m5201
#SBATCH --requeue
#SBATCH --open-mode=append

# usage: sbatch parallel_128_jobs.sh workdir_list.txt
#
# One simulation per NODE. Each simulation gets 4 MPI ranks / 4 GPUs,
# launched by its own top-level `srun -N 1 -n 4` from payload.sh.
#
# NOTE: `parallel` is NOT wrapped in srun here. That is deliberate — it runs
# on the batch node so that each payload's srun is a normal job step rather
# than a nested one. This follows the NERSC "Grouping Many One-Node MPI Jobs
# Into a Larger Job" pattern.

set -uo pipefail

workdir_file=${1:?usage: sbatch $0 <workdir_list.txt>}
cd "$SLURM_SUBMIT_DIR" || exit 1

if [[ ! -r $workdir_file ]]; then
    echo "ERROR: cannot read '$workdir_file' from $PWD" >&2
    exit 1
fi

# Strip CRLF, blank lines and comments into a clean list. Pass it to parallel
# as a FILE (::::) rather than a pipe — NERSC recommends this to avoid
# exhausting the open-file-handle ulimit at larger task counts.
tasklist="tasklist_${SLURM_JOB_ID}.txt"
tr -d '\r' < "$workdir_file" | sed '/^[[:space:]]*$/d;/^#/d' > "$tasklist"

ntasks=$(wc -l < "$tasklist")
if (( ntasks == 0 )); then
    echo "ERROR: no work directories parsed out of '$workdir_file'" >&2
    exit 1
fi

chmod +x ./payload.sh

echo "=== job $SLURM_JOB_ID ==="
echo "workdirs    : $ntasks"
echo "nodes       : $SLURM_NNODES"
echo "concurrency : $SLURM_NNODES  (1 simulation per node, 4 GPUs each)"
echo "started     : $(date '+%F %T')"
echo

module load parallel 2>/dev/null || true

# --jobs = number of nodes, so exactly one simulation occupies each node.
# Extra workdirs beyond $SLURM_NNODES queue up and start as nodes free.
parallel --will-cite \
         --jobs "$SLURM_NNODES" \
         --line-buffer \
         --joblog "parallel_${SLURM_JOB_ID}.log" \
         ./payload.sh {} \
         :::: "$tasklist"
rc=$?

echo
echo "=== parallel exited $rc at $(date '+%F %T') ==="
echo "per-task results: parallel_${SLURM_JOB_ID}.log"
exit $rc
