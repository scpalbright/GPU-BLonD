# coding: utf-8
# Copyright 2017 CERN. This software is distributed under the
# terms of the GNU General Public Licence version 3 (GPL Version 3),
# copied verbatim in the file LICENCE.md.
# In applying this licence, CERN does not waive the privileges and immunities
# granted to it by virtue of its status as an Intergovernmental Organization or
# submit itself to any jurisdiction.
# Project website: http://blond.web.cern.ch/

"""Module containing the fundamental beam class with methods to compute beam
statistics

:Authors: **Danilo Quartullo**, **Helga Timko**, **ALexandre Lasheen**

"""

from __future__ import division
# from builtins import object
import numpy as np
# from time import sleep
# import traceback
from ..utils import bmath as bm
from pycuda.compiler import SourceModule
# import pycuda.reduction as reduce
from pycuda import gpuarray
# , driver as drv, tools
from types import MethodType
from ..gpu.gpu_butils_wrap import stdKernel, sum_non_zeros, mean_non_zeros
from ..gpu import grid_size, block_size

from ..beam.beam import Beam

# def funcs_update(obj):
#         if (bm.gpuMode()):
#             obj.losses_longitudinal_cut = MethodType(
#                 gpu_losses_longitudinal_cut, obj)
#             obj.losses_energy_cut = MethodType(gpu_losses_energy_cut, obj)
#             obj.losses_below_energy = MethodType(gpu_losses_below_energy, obj)
#             obj.statistics = MethodType(gpu_statistics, obj)
#             setattr(type(obj), "n_macroparticles_lost", gpu_n_macroparticles_lost)
#         obj.dev_id = gpuarray.to_gpu(obj.id.astype(np.float64))

class gpu_Beam(Beam):

    ## dE property

    @property
    def dE(self):
        return self.dE_obj.my_array

    @dE.setter
    def dE(self, value):
        self.dE_obj.my_array = value


    @property
    def dev_dE(self):
        return self.dE_obj.dev_my_array


    @dev_dE.setter
    def dev_dE(self, value):
        self.dE_obj.dev_my_array = value
        
    ## dt property

    @property
    def dt(self):
        return self.dt_obj.my_array

    @dt.setter
    def dt(self, value):
        self.dt_obj.my_array = value


    @property
    def dev_dt(self):
        return self.dt_obj.dev_my_array


    @dev_dt.setter
    def dev_dt(self, value):
        self.dt_obj.dev_my_array = value

    ## id property
    
    @property
    def id(self):
        return self.id_obj.my_array

    @id.setter
    def id(self, value):
        self.id_obj.my_array = value


    @property
    def dev_id(self):
        return self.id_obj.dev_my_array


    @dev_id.setter
    def dev_id(self, value):
        self.id_obj.dev_my_array = value
        

    @property
    def n_macroparticles_lost(self):
        return self.n_macroparticles - int(gpuarray.sum(self.dev_id).get())


    def losses_longitudinal_cut(self, dt_min, dt_max):

        beam_ker = SourceModule("""
        __global__ void gpu_losses_longitudinal_cut(
                        double *dt, 
                        double *dev_id, 
                        const int size,
                        const double min_dt,
                        const double max_dt)
        {
                int tid = threadIdx.x + blockDim.x*blockIdx.x;
                for (int i = tid; i<size; i += blockDim.x*gridDim.x)
                    if ((dt[i]-min_dt)*(max_dt-dt[i])<0)
                        dev_id[i]=0;
        }   

        """)
        gllc = beam_ker.get_function("gpu_losses_longitudinal_cut")
        gllc(self.dev_dt, self.dev_id, np.int32(self.n_macroparticles), np.float64(dt_min), np.float64(dt_max),
            grid=grid_size, block=block_size)
        self.id_obj.invalidate_cpu()


    def losses_energy_cut(self, dE_min, dE_max):

        beam_ker = SourceModule("""
        __global__ void gpu_losses_energy_cut(
                        double *dE, 
                        double *dev_id, 
                        const int size,
                        const double min_dE,
                        const double max_dE)
        {
                int tid = threadIdx.x + blockDim.x*blockIdx.x;
                for (int i = tid; i<size; i += blockDim.x*gridDim.x)
                    if ((dE[i]-min_dE)*(max_dE-dE[i])<0)
                        dev_id[i]=0;
        }   

        """)
        glec = beam_ker.get_function("gpu_losses_energy_cut")
        glec(self.dev_dE, self.dev_id, np.int32(self.n_macroparticles), np.float64(dE_min), np.float64(dE_max),
            grid=grid_size, block=block_size)
        self.id_obj.invalidate_cpu()


    def losses_below_energy(self, dE_min):

        beam_ker = SourceModule("""
        __global__ void gpu_losses_below_energy(
                        double *dE, 
                        double *dev_id, 
                        const int size,
                        const double min_dE)
        {
                int tid = threadIdx.x + blockDim.x*blockIdx.x;
                for (int i = tid; i<size; i += blockDim.x*gridDim.x)
                    if (dE[i]-min_dE < 0)
                        dev_id[i]=0;
        }   

        """)
        glbe = beam_ker.get_function("gpu_losses_energy_cut")
        glbe(self.dev_dE, self.dev_id, np.int32(self.n_macroparticles), np.float64(dE_min),
            grid=grid_size, block=block_size)
        self.id_obj.invalidate_cpu()


    def statistics(self):
        ones_sum = sum_non_zeros(self.dev_id).get()
        # print(self.dev_id.dtype)
        self.ones_sum = ones_sum
        self.mean_dt = np.float64(mean_non_zeros(
            self.dev_dt, self.dev_id).get()/ones_sum)
        self.mean_dE = np.float64(mean_non_zeros(
            self.dev_dE, self.dev_id).get()/ones_sum)

        self.sigma_dt = np.float64(
            np.sqrt(stdKernel(self.dev_dt, self.dev_id, self.mean_dt).get()/ones_sum))
        self.sigma_dE = np.float64(
            np.sqrt(stdKernel(self.dev_dE, self.dev_id, self.mean_dE).get()/ones_sum))

        self.epsn_rms_l = np.pi*self.sigma_dE*self.sigma_dt  # in eVs

