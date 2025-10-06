#!/bin/bash
#SBATCH --image=docker:nersc/gromacs:24.04
#SBATCH -C gpu
#SBATCH -t 2-00:00:00
#SBATCH -J Gromacs_GPU
#SBATCH -o Gromacs_GPU.o%j
#SBATCH -N 1
#SBATCH -c 32
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-task=1
#SBATCH --mail-user=michelle.garcia.gr@dartmouth.edu
#SBATCH --mail-type=ALL
#SBATCH -q regular
#SBATCH --account=m1266
#SBATCH --requeue

# ===== Runtime/threading best practice for 4 MPI ranks x 1 GPU each =====
# With -c 32 and 4 ranks per node, use 8 threads per rank:
export OMP_NUM_THREADS=8
export OMP_PROC_BIND=spread
export OMP_PLACES=threads
export GMX_ENABLE_DIRECT_GPU_COMM=true

gmx_exe="gmx_mpi"

# Fixed basename for continuation:
deffnm="production"

# --- Step 1: Preprocessing (only if TPR doesn't exist yet) ---
if [[ ! -f ${deffnm}.tpr ]]; then
  grompp_args="grompp -maxwarn 2 -c 1.new.gro -o ${deffnm}.tpr -f production_2.mdp -p topol.top"
  command="srun --cpu-bind=cores --module cuda-mpich shifter $gmx_exe $grompp_args"
  echo "$command"
  $command || { echo "grompp failed"; exit 1; }
fi

# --- Step 2: Run MD (continue if checkpoint exists) ---
# -maxh 47.5 ensures a clean stop before Slurm walltime (48h), writing a fresh .cpt
if [[ ! -f ${deffnm}.log ]]; then
	mdrun_args="mdrun -deffnm ${deffnm} -maxh 47.5 \
  	-bonded gpu -nb gpu -pme gpu -npme 1 -pin on -ntomp ${OMP_NUM_THREADS}"
	else 
	mdrun_args="mdrun -deffnm ${deffnm} -cpi -append -maxh 47.5 \
        -bonded gpu -nb gpu -pme gpu -npme 1 -pin on -ntomp ${OMP_NUM_THREADS}"
fi
command="srun --cpu-bind=cores --gpu-bind=none --module cuda-mpich shifter $gmx_exe $mdrun_args"
echo "$command"
$command
rc=$?

# Requeue the same job to continue from the checkpoint
echo "Requeuing job to continue from checkpoint..."
scontrol requeue $SLURM_JOB_ID
exit 0

