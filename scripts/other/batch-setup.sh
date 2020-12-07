#!/bin/bash -l

####################################
#     ARIS slurm script template   #
#                                  #
# Submit script: sbatch filename   #
#                                  #
####################################

#SBATCH --job-name=compile    # Job name
#SBATCH --output=compile.out # Stdout (%j expands to jobId)
#SBATCH --error=compile.err # Stderr (%j expands to jobId)
#SBATCH --ntasks=1     # Number of tasks(processes)
#SBATCH --nodes=1     # Number of nodes requested
#SBATCH --ntasks-per-node=1     # Tasks per node
#SBATCH --cpus-per-task=1     # Threads per task
#SBATCH --time=00:05:00   # walltime
#SBATCH --mem=56G   # memory per NODE
#SBATCH --partition=gpu    # Partition
#SBATCH --account=pa200702    # Replace with your system project

if [ x$SLURM_CPUS_PER_TASK == x ]; then
  export OMP_NUM_THREADS=1
else
  export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
fi


# module purge		# clean up loaded modules 
## LOAD MODULES ##
source $HOME/.bashrc

# # load necessary modules
# module load gnu/4.9.2
# module load intel/15.0.3
# module load intelmpi/5.0.3
# module load cuda/8.0.61

# ## RUN YOUR PROGRAM ##
# srun <EXECUTABLE> <EXECUTABLE ARGUMENTS> 

# locate features.h
# ls /usr/lib/x86_64-redhat-linux5E/include
# ls /usr/*
# ls /usr/
# ls /usr/local/

INSTALL_DIR=$HOME/install
# cd $HOME/git/GPU-BLonD

python blond/compile.py --with-fftw --with-fftw-threads --with-fftw-lib=$INSTALL_DIR/lib/ --with-fftw-header=$INSTALL_DIR/include/ -p --gpu
