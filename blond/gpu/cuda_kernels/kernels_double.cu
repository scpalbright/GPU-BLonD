#include <pycuda-complex.hpp>
#include <curand_kernel.h>
#define REDUCE(a, b) (a+b)
#define BLOCK_SIZE 512
#define PI 3.141592653589793238462643383279502884197169399375105820974944592307816406286
#define PI_DIV_2 3.141592653589793238462643383279502884197169399375105820974944592307816406286/2

// Note that any atomic operation can be implemented based on atomicCAS() (Compare And Swap). 
// For example, atomicAdd() for double-precision floating-point numbers is not 
// available on devices with compute capability lower than 6.0 but it can be implemented 
// as follows: 
#if __CUDA_ARCH__ < 600
__device__ double atomicAdd(double* address, double val)
{
    unsigned long long int* address_as_ull =
                              (unsigned long long int*)address;
    unsigned long long int old = *address_as_ull, assumed;

    do {
        assumed = old;
        old = atomicCAS(address_as_ull, assumed,
                        __double_as_longlong(val +
                               __longlong_as_double(assumed)));

    // Note: uses integer comparison to avoid hang in case of NaN (since NaN != NaN)
    } while (assumed != old);

    return __longlong_as_double(old);
}
#endif


extern "C"
__global__ void gpu_losses_longitudinal_cut(
    double *dt,
    double *dev_id,
    const int size,
    const double min_dt,
    const double max_dt)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    for (int i = tid; i < size; i += blockDim.x * gridDim.x)
        if ((dt[i] - min_dt) * (max_dt - dt[i]) < 0)
            dev_id[i] = 0;
}

extern "C"
__global__ void gpu_losses_energy_cut(
    double *dE,
    double *dev_id,
    const int size,
    const double min_dE,
    const double max_dE)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    for (int i = tid; i < size; i += blockDim.x * gridDim.x)
        if ((dE[i] - min_dE) * (max_dE - dE[i]) < 0)
            dev_id[i] = 0;
}

extern "C"
__global__ void gpu_losses_below_energy(
    double *dE,
    double *dev_id,
    const int size,
    const double min_dE)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    for (int i = tid; i < size; i += blockDim.x * gridDim.x)
        if (dE[i] - min_dE < 0)
            dev_id[i] = 0;
}

extern "C"
__global__ void cuinterp(double *x,
                         int x_size,
                         double *xp,
                         int xp_size,
                         double *yp,
                         double *y,
                         double left,
                         double right)
{
    if (left == 0.12345)
        left = yp[0];
    if (right == 0.12345)
        right = yp[xp_size - 1];
    double curr;
    int lo;
    int mid;
    int hi;
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    for (int i = tid; i < x_size; i += blockDim.x * gridDim.x) {
        //need to find the right bin with binary search
        // looks like bisect_left
        curr = x[i];
        hi = xp_size;
        lo = 0;
        while (lo < hi) {
            mid = (lo + hi) / 2;
            if (xp[mid] < curr)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo == xp_size)
            y[i] = right;
        else if (xp[lo - 1] == curr)
            y[i] = yp[i];
        else if (lo <= 1)
            y[i] = left;
        else {
            y[i] = yp[lo - 1] +
                   (yp[lo] - yp[lo - 1]) * (x[i] - xp[lo - 1]) /
                   (xp[lo] - xp[lo - 1]);
        }

    }
}

extern "C"
__global__ void cugradient(
    double x,
    int *y,
    double *g,
    int size)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    for (int i = tid + 1; i < size - 1; i += blockDim.x * gridDim.x) {

        g[i] = (y[i + 1] - y[i - 1]) / (2 * x);
        // g[i] = (hs*hs*fd + (hd*hd-hs*hs)*fx - hd*hd*fs)/
        //     (hs*hd*(hd+hs));
    }
    if (tid == 0)
        g[0] = (y[1] - y[0]) / x;
    if (tid == 32)
        g[size - 1] = (y[size - 1] - y[size - 2]) / x;
}


extern "C"
__global__ void gpu_beam_fb_track_other(double *omega_rf,
                                        double *harmonic,
                                        double *dphi_rf,
                                        double *omega_rf_d,
                                        double *phi_rf,
                                        // double pi,
                                        double domega_rf,
                                        int size,
                                        int counter,
                                        int n_rf)
{
    double a, b, c;
    for (int i = threadIdx.x; i < n_rf; i += blockDim.x) {
        a = domega_rf * harmonic[i * size + counter] / harmonic[counter];
        b =  2.0 * PI * harmonic[size * i + counter] * (a + omega_rf[i * size + counter] - omega_rf_d[size * i + counter]) / omega_rf_d[size * i + counter];
        c = dphi_rf[i] +  b;
        omega_rf[i * size + counter] += a;
        dphi_rf[i] +=  b;
        phi_rf[size * i + counter] += c;
    }
}

extern "C"
__global__ void gpu_rf_voltage_calc_mem_ops(double *new_voltages,
        double *new_omega_rf,
        double *new_phi_rf,
        double *voltages,
        double *omega_rf,
        double *phi_rf,
        int start,
        int end,
        int step)
{
    int idx = 0;
    for (int i = threadIdx.x * step + start; i < end; i += blockDim.x * step) {
        new_voltages[idx] = voltages[i];
        new_omega_rf[idx] = omega_rf[i];
        new_phi_rf[idx] = phi_rf[i];
        idx++;
    }
} 

extern "C"
__global__ void halve_edges(double *my_array, int size) {
    //__shared__ my_sum;
    int tid = threadIdx.x;
    if (tid == 0) {
        my_array[0] = my_array[0] / 2.;
    }
    if (tid == 32) {
        my_array[size - 1] = my_array[size - 1] / 2.;
    }
}

extern "C"
__global__ void simple_kick(
    const double  *beam_dt,
    double        *beam_dE,
    const int n_rf,
    const double  *voltage,
    const double  *omega_RF,
    const double  *phi_RF,
    const int n_macroparticles,
    const double acc_kick
)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    double my_beam_dt;
    double sin_res;
    double dummy;
    for (int i = tid; i < n_macroparticles; i += blockDim.x * gridDim.x) {
        my_beam_dt = beam_dt[i];
        for (int j = 0; j < n_rf; j++) {
            sincos(omega_RF[j]*my_beam_dt + phi_RF[j], &sin_res, &dummy);
            beam_dE[i] += voltage[j] * sin_res;
        }
        beam_dE[i] += acc_kick;
    }
}

extern "C"
__global__ void rf_volt_comp(double *voltage,
                             double *omega_rf,
                             double *phi_rf,
                             double *bin_centers,
                             int n_rf,
                             int n_bins,
                             int f_rf,
                             double *rf_voltage)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    extern __shared__ double s[];
    if (threadIdx.x == 0){
        for (int j = 0; j < n_rf; j++) {
            s[j] = voltage[j];
            s[j + n_rf] = omega_rf[j];
            s[j + 2 * n_rf] = phi_rf[j];
        }
    }

    __syncthreads();
    for (int i = tid; i < n_bins; i += blockDim.x * gridDim.x) {
        for (int j = 0; j < n_rf; j++)
            // rf_voltage[i] = voltage[j] * sin(omega_rf[j] * bin_centers[i] + phi_rf[j]);
            rf_voltage[i] = s[j] * sin(s[j+n_rf] * bin_centers[i] + s[j+2*n_rf]);
    }
}

extern "C"
__global__ void drift(double *beam_dt,
        const double  *beam_dE,
        const int solver,
        const double T0, const double length_ratio,
        const double alpha_order, const double eta_zero,
        const double eta_one, const double eta_two,
        const double alpha_zero, const double alpha_one,
        const double alpha_two,
        const double beta, const double energy,
        const int n_macroparticles)
{
    double T = T0 * length_ratio;
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    if ( solver == 0 )
    {
        double coeff = eta_zero / (beta * beta * energy);
        for (int i=tid; i<n_macroparticles; i=i+blockDim.x*gridDim.x)
            beam_dt[i] += T * coeff * beam_dE[i];
    }

    else if ( solver == 1 )
    {
        const double coeff = 1. / (beta * beta * energy);
        const double eta0 = eta_zero * coeff;
        const double eta1 = eta_one * coeff * coeff;
        const double eta2 = eta_two * coeff * coeff * coeff;

        if (alpha_order == 0)
            for (int i=tid; i<n_macroparticles; i=i+blockDim.x*gridDim.x)
                beam_dt[i] += T * (1. / (1. - eta0 * beam_dE[i]) - 1.);
        else if (alpha_order == 1)
            for (int i=tid; i<n_macroparticles; i=i+blockDim.x*gridDim.x)
                beam_dt[i] += T * (1. / (1. - eta0 * beam_dE[i]
                                         - eta1 * beam_dE[i] * beam_dE[i]) - 1.);
        else
            for (int i=tid; i<n_macroparticles; i=i+blockDim.x*gridDim.x)
                beam_dt[i] += T * (1. / (1. - eta0 * beam_dE[i]
                                         - eta1 * beam_dE[i] * beam_dE[i]
                                         - eta2 * beam_dE[i] * beam_dE[i] * beam_dE[i]) - 1.);
    }

    else
    {

        const double invbetasq = 1 / (beta * beta);
        const double invenesq = 1 / (energy * energy);
        // double beam_delta;

        
        for (int i=tid; i<n_macroparticles; i=i+blockDim.x*gridDim.x)

        {

            double beam_delta = sqrt(1. + invbetasq *
                              (beam_dE[i] * beam_dE[i] * invenesq + 2.*beam_dE[i] / energy)) - 1.;

            beam_dt[i] += T * (
                              (1. + alpha_zero * beam_delta +
                               alpha_one * (beam_delta * beam_delta) +
                               alpha_two * (beam_delta * beam_delta * beam_delta)) *
                              (1. + beam_dE[i] / energy) / (1. + beam_delta) - 1.);

        }

    }    
    
}   



extern "C"
__global__ void histogram(double * input,
                          int * output, const double cut_left,
                          const double cut_right, const int n_slices,
                          const int n_macroparticles)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    int target_bin;
    double const inv_bin_width = n_slices / (cut_right - cut_left);
    for (int i = tid; i < n_macroparticles; i = i + blockDim.x * gridDim.x) {
        target_bin = floor((input[i] - cut_left) * inv_bin_width);
        if (target_bin < 0 || target_bin >= n_slices)
            continue;
        atomicAdd(&(output[target_bin]), 1);
    }
}

extern "C"
__global__ void hybrid_histogram(double * input,
                                 int * output, const double cut_left,
                                 const double cut_right, const unsigned int n_slices,
                                 const int n_macroparticles, const int capacity)
{
    extern __shared__ int block_hist[];
    //reset shared memory
    for (int i = threadIdx.x; i < capacity; i += blockDim.x)
        block_hist[i] = 0;
    __syncthreads();
    int const tid = threadIdx.x + blockDim.x * blockIdx.x;
    int target_bin;
    double const inv_bin_width = n_slices / (cut_right - cut_left);

    const int low_tbin = (n_slices / 2) - (capacity / 2);
    const int high_tbin = low_tbin + capacity;


    for (int i = tid; i < n_macroparticles; i += blockDim.x * gridDim.x) {
        target_bin = floor((input[i] - cut_left) * inv_bin_width);
        if (target_bin < 0 || target_bin >= n_slices)
            continue;
        if (target_bin >= low_tbin && target_bin < high_tbin)
            atomicAdd(&(block_hist[target_bin - low_tbin]), 1);
        else
            atomicAdd(&(output[target_bin]), 1);

    }
    __syncthreads();
    for (int i = threadIdx.x; i < capacity; i += blockDim.x)
        atomicAdd(&output[low_tbin + i], block_hist[i]);
}


extern "C"
__global__ void sm_histogram(double * input,
                             int * output, const double cut_left,
                             const double cut_right, const unsigned int n_slices,
                             const int n_macroparticles)
{
    extern __shared__ int block_hist[];
    for (int i = threadIdx.x; i < n_slices; i += blockDim.x)
        block_hist[i] = 0;
    __syncthreads();
    int const tid = threadIdx.x + blockDim.x * blockIdx.x;
    int target_bin;
    double const inv_bin_width = n_slices / (cut_right - cut_left);
    for (int i = tid; i < n_macroparticles; i += blockDim.x * gridDim.x) {
        target_bin = floor((input[i] - cut_left) * inv_bin_width);
        if (target_bin < 0 || target_bin >= n_slices)
            continue;
        atomicAdd(&(block_hist[target_bin]), 1);
    }
    __syncthreads();
    for (int i = threadIdx.x; i < n_slices; i += blockDim.x)
        atomicAdd(&output[i], block_hist[i]);
}


extern "C"
__global__ void lik_only_gm_copy(
    double *beam_dt,
    double *beam_dE,
    const double *voltage_array,
    const double *bin_centers,
    const double charge,
    const int n_slices,
    const int n_macroparticles,
    const double acc_kick,
    double *glob_voltageKick,
    double *glob_factor
)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    double const inv_bin_width = (n_slices - 1)
                                 / (bin_centers[n_slices - 1] - bin_centers[0]);


    for (int i = tid; i < n_slices - 1; i += gridDim.x * blockDim.x) {
        glob_voltageKick[i] = charge * (voltage_array[i + 1] - voltage_array[i])
                              * inv_bin_width;
        glob_factor[i] = (charge * voltage_array[i] - bin_centers[i] * glob_voltageKick[i])
                         + acc_kick;
    }
}


extern "C"
__global__ void lik_only_gm_comp(
    double *beam_dt,
    double *beam_dE,
    const double *voltage_array,
    const double *bin_centers,
    const double charge,
    const int n_slices,
    const int n_macroparticles,
    const double acc_kick,
    double *glob_voltageKick,
    double *glob_factor
)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    double const inv_bin_width = (n_slices - 1)
                                 / (bin_centers[n_slices - 1] - bin_centers[0]);
    int fbin;
    const double bin0 = bin_centers[0];
    for (int i = tid; i < n_macroparticles; i += blockDim.x * gridDim.x) {
        fbin = floor((beam_dt[i] - bin0) * inv_bin_width);
        if ((fbin < n_slices - 1) && (fbin >= 0))
            beam_dE[i] += beam_dt[i] * glob_voltageKick[fbin] + glob_factor[fbin];
    }
}


extern "C"
__global__ void lik_drift_only_gm_comp(
    double *beam_dt,
    double *beam_dE,
    const double *voltage_array,
    const double *bin_centers,
    const double charge,
    const int n_slices,
    const int n_macroparticles,
    const double acc_kick,
    double *glob_voltageKick,
    double *glob_factor,
    const double T0, const double length_ratio,
    const double eta0, const double beta, const double energy
)
{
    const double T = T0 * length_ratio * eta0 / (beta * beta * energy);

    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    double const inv_bin_width = (n_slices - 1)
                                 / (bin_centers[n_slices - 1] - bin_centers[0]);
    unsigned fbin;
    const double bin0 = bin_centers[0];
    for (int i = tid; i < n_macroparticles; i += blockDim.x * gridDim.x) {
        fbin = (unsigned) floor((beam_dt[i] - bin0) * inv_bin_width);
        if ((fbin < n_slices - 1))
            beam_dE[i] += beam_dt[i] * glob_voltageKick[fbin] + glob_factor[fbin];
        // beam_dt[i] += T * (1. / (1. - eta0 * beam_dE[i]) -1.);
        beam_dt[i] += T * beam_dE[i];
    }
}

extern "C"
__global__ void beam_phase_v2(
    const double *bin_centers,
    const int *profile,
    const double alpha,
    const double *omega_rf_ar,
    const double *phi_rf_ar,
    const int ind,
    const double bin_size,
    double *array1,
    double *array2,
    const int n_bins)
{
    double omega_rf = omega_rf_ar[ind];
    double phi_rf = phi_rf_ar[ind];
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    double a, b;
    double sin_res, cos_res;
    for (int i = tid; i < n_bins; i += gridDim.x * blockDim.x) {
        a = omega_rf * bin_centers[i] + phi_rf;
        sincos(a, &sin_res, &cos_res);
        b = exp(alpha * bin_centers[i]) * profile[i];
        array1[i] = b * sin_res;
        array2[i] = b * cos_res;
    }
} 

extern "C" 
__global__ void beam_phase_sum(
    const double *ar1,
    const double *ar2,
    double *scoeff,
    double *coeff,
    int n_bins)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;

    if (tid == 0) {
        scoeff[0] = 0;
        coeff[0] = 0;
    }
    double my_sum_1 = 0;
    double my_sum_2 = 0;
    if (tid == 0) {
        my_sum_1 += ar1[0] / 2 + ar1[n_bins - 1] / 2;
        my_sum_2 += ar2[0] / 2 + ar2[n_bins - 1] / 2;
    }
    for (int i = tid + 1; i < n_bins - 1; i += gridDim.x * blockDim.x) {
        my_sum_1 += ar1[i];
        my_sum_2 += ar2[i];
    }
    atomicAdd(&(scoeff[0]), my_sum_1);
    atomicAdd(&(coeff[0]), my_sum_2);
    __syncthreads();
    if (tid == 0)
        scoeff[0] = scoeff[0] / coeff[0];

} 

extern "C"
__global__ void gpu_trapz_custom(
    double *y,
    double x,
    int sz,
    double *res)
{
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    double my_sum = 0;
    for (int i = tid; i < sz - 1; i += gridDim.x * blockDim.x)
        my_sum += (y[i] + y[i + 1]) * x / 2.0;

    atomicAdd(&(res[0]), my_sum);
}


extern "C" 
__global__ void gpu_trapz_stage1(double *out, double *y, double x, int sz,
                      unsigned int seq_count, unsigned int n)
{
    // Needs to be variable-size to prevent the braindead CUDA compiler from
    // running constructors on this array. Grrrr.
    extern __shared__ double sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * 512 * seq_count + tid;
    double acc = 0;
    for (unsigned s = 0; s < seq_count; ++s)
    {
        if (i >= n)
            break;
        acc = acc + ((i < sz - 1) ? x * (y[i] + y[i + 1]) / 2.0 : 0.0);
        i += 512;
    }
    sdata[tid] = acc;
    __syncthreads();
#if (512 >= 512)
    if (tid < 256) { sdata[tid] = sdata[tid] + sdata[tid + 256]; }
    __syncthreads();
#endif
#if (512 >= 256)
    if (tid < 128) { sdata[tid] = sdata[tid] + sdata[tid + 128]; }
    __syncthreads();
#endif
#if (512 >= 128)
    if (tid < 64) { sdata[tid] = sdata[tid] + sdata[tid + 64]; }
    __syncthreads();
#endif
    if (tid < 32)
    {
        // 'volatile' required according to Fermi compatibility guide 1.2.2
        volatile double *smem = sdata;
        if (512 >= 64) smem[tid] = smem[tid] + smem[tid + 32];
        if (512 >= 32) smem[tid] = smem[tid] + smem[tid + 16];
        if (512 >= 16) smem[tid] = smem[tid] + smem[tid + 8];
        if (512 >= 8)  smem[tid] = smem[tid] + smem[tid + 4];
        if (512 >= 4)  smem[tid] = smem[tid] + smem[tid + 2];
        if (512 >= 2)  smem[tid] = smem[tid] + smem[tid + 1];
    }
    if (tid == 0) out[blockIdx.x] = sdata[0];
}



extern "C" 
__global__ void gpu_trapz_stage2(double *out, const double *pycuda_reduction_inp, double *y, double x, int sz,
                      unsigned int seq_count, unsigned int n)
{
    // Needs to be variable-size to prevent the braindead CUDA compiler from
    // running constructors on this array. Grrrr.
    extern __shared__ double sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * 512 * seq_count + tid;
    double acc = 0;
    for (unsigned s = 0; s < seq_count; ++s)
    {
        if (i >= n)
            break;
        acc = acc + (pycuda_reduction_inp[i]);
        i = 512;
    }
    sdata[tid] = acc;
    __syncthreads();
#if (512 >= 512)
    if (tid < 256) { sdata[tid] = sdata[tid] + sdata[tid + 256]; }
    __syncthreads();
#endif
#if (512 >= 256)
    if (tid < 128) { sdata[tid] = sdata[tid] + sdata[tid + 128]; }
    __syncthreads();
#endif
#if (512 >= 128)
    if (tid < 64) { sdata[tid] = sdata[tid] + sdata[tid + 64]; }
    __syncthreads();
#endif
    if (tid < 32)
    {
        // 'volatile' required according to Fermi compatibility guide 1.2.2
        volatile double *smem = sdata;
        if (512 >= 64) smem[tid] = smem[tid] + smem[tid + 32];
        if (512 >= 32) smem[tid] = smem[tid] + smem[tid + 16];
        if (512 >= 16) smem[tid] = smem[tid] + smem[tid + 8];
        if (512 >= 8)  smem[tid] = smem[tid] + smem[tid + 4];
        if (512 >= 4)  smem[tid] = smem[tid] + smem[tid + 2];
        if (512 >= 2)  smem[tid] = smem[tid] + smem[tid + 1];
    }
    if (tid == 0) out[blockIdx.x] = sdata[0];
}


extern "C"
__global__ void mean_non_zeros_stage1(double *out, double *x, double *id,
                           unsigned int seq_count, unsigned int n)
{
    // Needs to be variable-size to prevent the braindead CUDA compiler from
    // running constructors on this array. Grrrr.
    extern __shared__ double sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * 512 * seq_count + tid;
    double acc = 0;
    for (unsigned s = 0; s < seq_count; ++s)
    {
        if (i >= n)
            break;
        acc = acc + ((id[i] != 0) * x[i]);
        i += 512;
    }
    sdata[tid] = acc;
    __syncthreads();
#if (512 >= 512)
    if (tid < 256) { sdata[tid] = sdata[tid] + sdata[tid + 256]; }
    __syncthreads();
#endif
#if (512 >= 256)
    if (tid < 128) { sdata[tid] = sdata[tid] + sdata[tid + 128]; }
    __syncthreads();
#endif
#if (512 >= 128)
    if (tid < 64) { sdata[tid] = sdata[tid] + sdata[tid + 64]; }
    __syncthreads();
#endif
    if (tid < 32)
    {
        // 'volatile' required according to Fermi compatibility guide 1.2.2
        volatile double *smem = sdata;
        if (512 >= 64) smem[tid] = smem[tid] + smem[tid + 32];
        if (512 >= 32) smem[tid] = smem[tid] + smem[tid + 16];
        if (512 >= 16) smem[tid] = smem[tid] + smem[tid + 8];
        if (512 >= 8)  smem[tid] = smem[tid] + smem[tid + 4];
        if (512 >= 4)  smem[tid] = smem[tid] + smem[tid + 2];
        if (512 >= 2)  smem[tid] = smem[tid] + smem[tid + 1];
    }
    if (tid == 0) out[blockIdx.x] = sdata[0];
}




extern "C"
__global__ void mean_non_zeros_stage2(double *out, const double *pycuda_reduction_inp, double *x, double *id,
                           unsigned int seq_count, unsigned int n)
{
    // Needs to be variable-size to prevent the braindead CUDA compiler from
    // running constructors on this array. Grrrr.
    extern __shared__ double sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * 512 * seq_count + tid;
    double acc = 0;
    for (unsigned s = 0; s < seq_count; ++s)
    {
        if (i >= n)
            break;
        acc = REDUCE(acc, (pycuda_reduction_inp[i]));
        i += 512;
    }
    sdata[tid] = acc;
    __syncthreads();
#if (512 >= 512)
    if (tid < 256) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 256]); }
    __syncthreads();
#endif
#if (512 >= 256)
    if (tid < 128) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 128]); }
    __syncthreads();
#endif
#if (512 >= 128)
    if (tid < 64) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 64]); }
    __syncthreads();
#endif
    if (tid < 32)
    {
        // 'volatile' required according to Fermi compatibility guide 1.2.2
        volatile double *smem = sdata;
        if (512 >= 64) smem[tid] = REDUCE(smem[tid], smem[tid + 32]);
        if (512 >= 32) smem[tid] = REDUCE(smem[tid], smem[tid + 16]);
        if (512 >= 16) smem[tid] = REDUCE(smem[tid], smem[tid + 8]);
        if (512 >= 8)  smem[tid] = REDUCE(smem[tid], smem[tid + 4]);
        if (512 >= 4)  smem[tid] = REDUCE(smem[tid], smem[tid + 2]);
        if (512 >= 2)  smem[tid] = REDUCE(smem[tid], smem[tid + 1]);
    }
    if (tid == 0) out[blockIdx.x] = sdata[0];
}




extern "C"
__global__ void stdKernel_stage1(double *out, double *x, double *y, double m,
                      unsigned int seq_count, unsigned int n)
{
    // Needs to be variable-size to prevent the braindead CUDA compiler from
    // running constructors on this array. Grrrr.
    extern __shared__ double sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * BLOCK_SIZE * seq_count + tid;
    double acc = 0;
    for (unsigned s = 0; s < seq_count; ++s)
    {
        if (i >= n)
            break;
        acc = REDUCE(acc, ((y[i] != 0) * (x[i] - m) * (x[i] - m)));
        i += BLOCK_SIZE;
    }
    sdata[tid] = acc;
    __syncthreads();
#if (BLOCK_SIZE >= 512)
    if (tid < 256) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 256]); }
    __syncthreads();
#endif
#if (BLOCK_SIZE >= 256)
    if (tid < 128) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 128]); }
    __syncthreads();
#endif
#if (BLOCK_SIZE >= 128)
    if (tid < 64) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 64]); }
    __syncthreads();
#endif
    if (tid < 32)
    {
        // 'volatile' required according to Fermi compatibility guide 1.2.2
        volatile double *smem = sdata;
        if (BLOCK_SIZE >= 64) smem[tid] = REDUCE(smem[tid], smem[tid + 32]);
        if (BLOCK_SIZE >= 32) smem[tid] = REDUCE(smem[tid], smem[tid + 16]);
        if (BLOCK_SIZE >= 16) smem[tid] = REDUCE(smem[tid], smem[tid + 8]);
        if (BLOCK_SIZE >= 8)  smem[tid] = REDUCE(smem[tid], smem[tid + 4]);
        if (BLOCK_SIZE >= 4)  smem[tid] = REDUCE(smem[tid], smem[tid + 2]);
        if (BLOCK_SIZE >= 2)  smem[tid] = REDUCE(smem[tid], smem[tid + 1]);
    }
    if (tid == 0) out[blockIdx.x] = sdata[0];
}




extern "C"
__global__ void stdKernel_stage2(double *out, const double *pycuda_reduction_inp, double *x, double *y, double m,
                      unsigned int seq_count, unsigned int n)
{
    // Needs to be variable-size to prevent the braindead CUDA compiler from
    // running constructors on this array. Grrrr.
    extern __shared__ double sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * BLOCK_SIZE * seq_count + tid;
    double acc = 0;
    for (unsigned s = 0; s < seq_count; ++s)
    {
        if (i >= n)
            break;
        acc = REDUCE(acc, (pycuda_reduction_inp[i]));
        i += BLOCK_SIZE;
    }
    sdata[tid] = acc;
    __syncthreads();
#if (BLOCK_SIZE >= 512)
    if (tid < 256) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 256]); }
    __syncthreads();
#endif
#if (BLOCK_SIZE >= 256)
    if (tid < 128) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 128]); }
    __syncthreads();
#endif
#if (BLOCK_SIZE >= 128)
    if (tid < 64) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 64]); }
    __syncthreads();
#endif
    if (tid < 32)
    {
        // 'volatile' required according to Fermi compatibility guide 1.2.2
        volatile double *smem = sdata;
        if (BLOCK_SIZE >= 64) smem[tid] = REDUCE(smem[tid], smem[tid + 32]);
        if (BLOCK_SIZE >= 32) smem[tid] = REDUCE(smem[tid], smem[tid + 16]);
        if (BLOCK_SIZE >= 16) smem[tid] = REDUCE(smem[tid], smem[tid + 8]);
        if (BLOCK_SIZE >= 8)  smem[tid] = REDUCE(smem[tid], smem[tid + 4]);
        if (BLOCK_SIZE >= 4)  smem[tid] = REDUCE(smem[tid], smem[tid + 2]);
        if (BLOCK_SIZE >= 2)  smem[tid] = REDUCE(smem[tid], smem[tid + 1]);
    }
    if (tid == 0) out[blockIdx.x] = sdata[0];
}




extern "C"
__global__ void sum_non_zeros_stage1(double *out, double *x,
                          unsigned int seq_count, unsigned int n)
{
    // Needs to be variable-size to prevent the braindead CUDA compiler from
    // running constructors on this array. Grrrr.
    extern __shared__ double sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * BLOCK_SIZE * seq_count + tid;
    double acc = 0;
    for (unsigned s = 0; s < seq_count; ++s)
    {
        if (i >= n)
            break;
        acc = REDUCE(acc, ((x[i] != 0)));
        i += BLOCK_SIZE;
    }
    sdata[tid] = acc;
    __syncthreads();
#if (BLOCK_SIZE >= 512)
    if (tid < 256) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 256]); }
    __syncthreads();
#endif
#if (BLOCK_SIZE >= 256)
    if (tid < 128) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 128]); }
    __syncthreads();
#endif
#if (BLOCK_SIZE >= 128)
    if (tid < 64) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 64]); }
    __syncthreads();
#endif
    if (tid < 32)
    {
        // 'volatile' required according to Fermi compatibility guide 1.2.2
        volatile double *smem = sdata;
        if (BLOCK_SIZE >= 64) smem[tid] = REDUCE(smem[tid], smem[tid + 32]);
        if (BLOCK_SIZE >= 32) smem[tid] = REDUCE(smem[tid], smem[tid + 16]);
        if (BLOCK_SIZE >= 16) smem[tid] = REDUCE(smem[tid], smem[tid + 8]);
        if (BLOCK_SIZE >= 8)  smem[tid] = REDUCE(smem[tid], smem[tid + 4]);
        if (BLOCK_SIZE >= 4)  smem[tid] = REDUCE(smem[tid], smem[tid + 2]);
        if (BLOCK_SIZE >= 2)  smem[tid] = REDUCE(smem[tid], smem[tid + 1]);
    }
    if (tid == 0) out[blockIdx.x] = sdata[0];
}




extern "C"
__global__ void sum_non_zeros_stage2(double *out, const double *pycuda_reduction_inp, double *x,
                          unsigned int seq_count, unsigned int n)
{
    // Needs to be variable-size to prevent the braindead CUDA compiler from
    // running constructors on this array. Grrrr.
    extern __shared__ double sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * BLOCK_SIZE * seq_count + tid;
    double acc = 0;
    for (unsigned s = 0; s < seq_count; ++s)
    {
        if (i >= n)
            break;
        acc = REDUCE(acc, (pycuda_reduction_inp[i]));
        i += BLOCK_SIZE;
    }
    sdata[tid] = acc;
    __syncthreads();
#if (BLOCK_SIZE >= 512)
    if (tid < 256) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 256]); }
    __syncthreads();
#endif
#if (BLOCK_SIZE >= 256)
    if (tid < 128) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 128]); }
    __syncthreads();
#endif
#if (BLOCK_SIZE >= 128)
    if (tid < 64) { sdata[tid] = REDUCE(sdata[tid], sdata[tid + 64]); }
    __syncthreads();
#endif
    if (tid < 32)
    {
        // 'volatile' required according to Fermi compatibility guide 1.2.2
        volatile double *smem = sdata;
        if (BLOCK_SIZE >= 64) smem[tid] = REDUCE(smem[tid], smem[tid + 32]);
        if (BLOCK_SIZE >= 32) smem[tid] = REDUCE(smem[tid], smem[tid + 16]);
        if (BLOCK_SIZE >= 16) smem[tid] = REDUCE(smem[tid], smem[tid + 8]);
        if (BLOCK_SIZE >= 8)  smem[tid] = REDUCE(smem[tid], smem[tid + 4]);
        if (BLOCK_SIZE >= 4)  smem[tid] = REDUCE(smem[tid], smem[tid + 2]);
        if (BLOCK_SIZE >= 2)  smem[tid] = REDUCE(smem[tid], smem[tid + 1]);
    }
    if (tid == 0) out[blockIdx.x] = sdata[0];
}



extern "C"
__global__ void gpu_copy_i2d(double *x, int *y, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = (double) y[i] * 1.0;
    }
    ;
}



extern "C"
__global__ void gpu_copy_d2d(double *x, double *y, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = y[i];
    }
    ;
}



extern "C"
__global__ void gpu_complex_copy(pycuda::complex<double> *x, pycuda::complex<double> *y, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = y[i];
    }
    ;
}



extern "C"
__global__ void gpu_diff(int *a, double *b, double c, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        b[i] = (a[i + 1] - a[i]) / c;
    }
    ;
}



extern "C"
__global__ void set_zero_double(double *x, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = 0;
    }
    ;
}

extern "C"
__global__ void set_zero_float(float *x, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = 0;
    }
    ;
}


extern "C"
__global__ void set_zero_int(int *x, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = 0;
    }
    ;
}



extern "C"
__global__ void set_zero_complex64(pycuda::complex<float> *x, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = 0;
    }
    ;
}


extern "C"
__global__ void set_zero_complex128(pycuda::complex<double> *x, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = 0;
    }
    ;
}


extern "C"
__global__ void increase_by_value(double *x, double a, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] += a;
    }
    ;
}



extern "C"
__global__ void add_array(double *x, double *y, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] += y[i];
    }
    ;
}



extern "C"
__global__ void complex_mul(pycuda::complex<double> *x, pycuda::complex<double> *y, pycuda::complex<double> *z, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        z[i] = x[i] * y[i];
    }
    ;
}



extern "C"
__global__ void gpu_mul(double *x, double *y, double a, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = a * y[i];
    }
    ;
}



extern "C"
__global__ void gpu_copy_one(double *x, double *y, int ind, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = y[ind];
    }
    ;
}



extern "C"
__global__ void first_kernel_x(double *omega_rf, double *harmonic,  double domega_rf, int size, int counter, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        omega_rf[i * size + counter] += domega_rf * harmonic[i * size + counter] / harmonic[counter];
    }
    ;
}



extern "C"
__global__ void second_kernel_x(double *dphi_rf, double *harmonic, double *omega_rf, double *omega_rf_d, int size, int counter, double pi, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        dphi_rf[i] +=  2.0 * pi * harmonic[size * i + counter] * (omega_rf[size * i + counter] - omega_rf_d[size * i + counter]) / omega_rf_d[size * i + counter];
    }
    ;
}



extern "C"
__global__ void third_kernel_x(double *x, double *y, int size_0, int counter, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i * size_0 + counter] += y[i];
    }
    ;
}



extern "C"
__global__ void indexing_double(double *out, double *in, int *ind, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        out[i] = in[ind[i]];
    }
    ;
}

// extern "C"
// __global__ void indexing_float(float *out, float *in, int *ind, long n)
// {
//     unsigned tid = threadIdx.x;
//     unsigned total_threads = gridDim.x * blockDim.x;
//     unsigned cta_start = blockDim.x * blockIdx.x;
//     unsigned i;
//     ;
//     for (i = cta_start + tid; i < n; i += total_threads)
//     {
//         out[i] = in[ind[i]];
//     }
//     ;
// }


extern "C"
__global__ void indexing_int(double *out, int *in, int *ind, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        out[i] = in[ind[i]];
    }
    ;
}



extern "C"
__global__ void sincos_mul_add(double *ar, double a, double b, double *s, double *c, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        sincos(a * ar[i] + b, &s[i], &c[i]);
    }
    ;
}



extern "C"
__global__ void sincos_mul_add_2(double *ar, double a, double b, double *s, double *c, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        s[i] = cos(a * ar[i] + b - PI_DIV_2); c[i] = cos(a * ar[i] + b);
    }
    ;
}



extern "C"
__global__ void mul_d(double *a1, double *a2, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        a1[i] *= a2[i];
    }
    ;
}



extern "C"
__global__ void add_kernel(double *a, double *b, double *c, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        a[i] = b[i] + c[i];
    }
    ;
}



extern "C"
__global__ void first_kernel_tracker(double *phi_rf, double x, double *phi_noise, int len, int turn, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        phi_rf[len * i + turn] += x * phi_noise[len * i + turn];
    }
    ;
}



extern "C"
__global__ void second_kernel_tracker(double *phi_rf, double *omega_rf, double *phi_mod0, double *phi_mod1, int size, int turn, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        phi_rf[i * size + turn] += phi_mod0[i * size + turn]; omega_rf[i * size + turn] += phi_mod1[i * size + turn];
    }
    ;
}



extern "C"
__global__ void copy_column(double *x, double *y, int size, int column, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = y[i * size + column];
    }
    ;
}



extern "C"
__global__ void rf_voltage_calculation_kernel(double *x, double *y, int size, int column, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        x[i] = y[i * size + column];
    }
    ;
}



extern "C"
__global__ void cavityFB_case(double *rf_voltage, double *voltage, double *omega_rf, double *phi_rf, double *bin_centers, double V_corr, double phi_corr, int size, int column, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        rf_voltage[i] = voltage[0] * V_corr * sin(omega_rf[0] * bin_centers[i] + phi_rf[0] + phi_corr);
    }
    ;
}



extern "C"
__global__ void bm_phase_exp_times_scalar(double *a, double *b, double c, int *d, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        a[i] = exp(c * b[i]) * d[i];
    }
    ;
}



extern "C"
__global__ void bm_phase_mul_add(double *a, double b, double *c, double d, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        a[i] = b * c[i] + d;
    }
    ;
}



extern "C"
__global__ void bm_sin_cos(double *a, double *b, double *c, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        sincos(a[i], &b[i], &c[i]);
    }
    ;
}



extern "C"
__global__ void d_multiply(double *a, double *b, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        a[i] *= b[i];
    }
    ;
}



extern "C"
__global__ void d_multscalar(double *a, double *b, double c, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        a[i] = c * b[i];
    }
    ;
}


extern "C"
__global__ void d_mul_int_by_scalar(int *a, double c, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        a[i] *= c;
    }
    ;
}



extern "C"
__global__ void scale_kernel_int(int a, int *b, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        b[i] /= a ;
    }
    ;
}



extern "C"
__global__ void scale_kernel_double(double a, double *b, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        b[i] /= a ;
    }
    ;
}

extern "C"
__global__ void scale_kernel_float(float a, float *b, long n)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    unsigned i;
    ;
    for (i = cta_start + tid; i < n; i += total_threads)
    {
        b[i] /= a ;
    }
    ;
}


extern "C"
__global__ void gpu_copy_i2d_range(double *x, int *y , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = (double) y[i] * 1.0;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = (double) y[i] * 1.0;
        }
    }
    ;
}



extern "C"
__global__ void gpu_copy_d2d_range(double *x, double *y , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = y[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = y[i];
        }
    }
    ;
}



extern "C"
__global__ void gpu_complex_copy_range(pycuda::complex<double> *x, pycuda::complex<double> *y , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = y[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = y[i];
        }
    }
    ;
}



extern "C"
__global__ void gpu_diff_range(int *a, double *b, double c , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            b[i] = (a[i + 1] - a[i]) / c;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            b[i] = (a[i + 1] - a[i]) / c;
        }
    }
    ;
}


extern "C"
__global__ void set_zero_float_range(float *x , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    ;
}

extern "C"
__global__ void set_zero_double_range(double *x , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    ;
}



extern "C"
__global__ void set_zero_int_range(int *x , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    ;
}


extern "C"
__global__ void set_zero_complex64_range(pycuda::complex<float> *x , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    ;
}


extern "C"
__global__ void set_zero_complex128_range(pycuda::complex<double> *x , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = 0;
        }
    }
    ;
}



extern "C"
__global__ void increase_by_value_range(double *x, double a , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] += a;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] += a;
        }
    }
    ;
}



extern "C"
__global__ void add_array_range(double *x, double *y , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] += y[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] += y[i];
        }
    }
    ;
}



extern "C"
__global__ void complex_mul_range(pycuda::complex<double> *x, pycuda::complex<double> *y, pycuda::complex<double> *z , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            z[i] = x[i] * y[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            z[i] = x[i] * y[i];
        }
    }
    ;
}



extern "C"
__global__ void gpu_mul_range(double *x, double *y, double a , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = a * y[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = a * y[i];
        }
    }
    ;
}



extern "C"
__global__ void gpu_copy_one_range(double *x, double *y, int ind , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = y[ind];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = y[ind];
        }
    }
    ;
}



extern "C"
__global__ void first_kernel_x_range(double *omega_rf, double *harmonic,  double domega_rf, int size, int counter , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            omega_rf[i * size + counter] += domega_rf * harmonic[i * size + counter] / harmonic[counter];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            omega_rf[i * size + counter] += domega_rf * harmonic[i * size + counter] / harmonic[counter];
        }
    }
    ;
}



extern "C"
__global__ void second_kernel_x_range(double *dphi_rf, double *harmonic, double *omega_rf, double *omega_rf_d, int size, int counter, double pi , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            dphi_rf[i] +=  2.0 * pi * harmonic[size * i + counter] * (omega_rf[size * i + counter] - omega_rf_d[size * i + counter]) / omega_rf_d[size * i + counter];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            dphi_rf[i] +=  2.0 * pi * harmonic[size * i + counter] * (omega_rf[size * i + counter] - omega_rf_d[size * i + counter]) / omega_rf_d[size * i + counter];
        }
    }
    ;
}



extern "C"
__global__ void third_kernel_x_range(double *x, double *y, int size_0, int counter , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i * size_0 + counter] += y[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i * size_0 + counter] += y[i];
        }
    }
    ;
}



extern "C"
__global__ void indexing_double_range(double *out, double *in, int *ind , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            out[i] = in[ind[i]];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            out[i] = in[ind[i]];
        }
    }
    ;
}



extern "C"
__global__ void indexing_int_range(double *out, int *in, int *ind , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            out[i] = in[ind[i]];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            out[i] = in[ind[i]];
        }
    }
    ;
}



extern "C"
__global__ void sincos_mul_add_range(double *ar, double a, double b, double *s, double *c , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            sincos(a * ar[i] + b, &s[i], &c[i]);
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            sincos(a * ar[i] + b, &s[i], &c[i]);
        }
    }
    ;
}



extern "C"
__global__ void sincos_mul_add_2_range(double *ar, double a, double b, double *s, double *c , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            s[i] = cos(a * ar[i] + b - PI_DIV_2); c[i] = cos(a * ar[i] + b);
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            s[i] = cos(a * ar[i] + b - PI_DIV_2); c[i] = cos(a * ar[i] + b);
        }
    }
    ;
}



extern "C"
__global__ void mul_d_range(double *a1, double *a2 , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            a1[i] *= a2[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            a1[i] *= a2[i];
        }
    }
    ;
}



extern "C"
__global__ void add_kernel_range(double *a, double *b, double *c , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            a[i] = b[i] + c[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            a[i] = b[i] + c[i];
        }
    }
    ;
}



extern "C"
__global__ void first_kernel_tracker_range(double *phi_rf, double x, double *phi_noise, int len, int turn , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            phi_rf[len * i + turn] += x * phi_noise[len * i + turn];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            phi_rf[len * i + turn] += x * phi_noise[len * i + turn];
        }
    }
    ;
}



extern "C"
__global__ void second_kernel_tracker_range(double *phi_rf, double *omega_rf, double *phi_mod0, double *phi_mod1, int size, int turn , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            phi_rf[i * size + turn] += phi_mod0[i * size + turn]; omega_rf[i * size + turn] += phi_mod1[i * size + turn];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            phi_rf[i * size + turn] += phi_mod0[i * size + turn]; omega_rf[i * size + turn] += phi_mod1[i * size + turn];
        }
    }
    ;
}



extern "C"
__global__ void copy_column_range(double *x, double *y, int size, int column , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = y[i * size + column];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = y[i * size + column];
        }
    }
    ;
}



extern "C"
__global__ void rf_voltage_calculation_kernel_range(double *x, double *y, int size, int column , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            x[i] = y[i * size + column];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            x[i] = y[i * size + column];
        }
    }
    ;
}



extern "C"
__global__ void cavityFB_case_range(double *rf_voltage, double *voltage, double *omega_rf, double *phi_rf, double *bin_centers, double V_corr, double phi_corr, int size, int column , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            rf_voltage[i] = voltage[0] * V_corr * sin(omega_rf[0] * bin_centers[i] + phi_rf[0] + phi_corr);
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            rf_voltage[i] = voltage[0] * V_corr * sin(omega_rf[0] * bin_centers[i] + phi_rf[0] + phi_corr);
        }
    }
    ;
}



extern "C"
__global__ void bm_phase_exp_times_scalar_range(double *a, double *b, double c, int *d , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            a[i] = exp(c * b[i]) * d[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            a[i] = exp(c * b[i]) * d[i];
        }
    }
    ;
}



extern "C"
__global__ void bm_phase_mul_add_range(double *a, double b, double *c, double d , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            a[i] = b * c[i] + d;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            a[i] = b * c[i] + d;
        }
    }
    ;
}



extern "C"
__global__ void bm_sin_cos_range(double *a, double *b, double *c , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            sincos(a[i], &b[i], &c[i]);
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            sincos(a[i], &b[i], &c[i]);
        }
    }
    ;
}



extern "C"
__global__ void d_multiply_range(double *a, double *b , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            a[i] *= b[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            a[i] *= b[i];
        }
    }
    ;
}



extern "C"
__global__ void d_multscalar_range(double *a, double *b, double c , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            a[i] = c * b[i];
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            a[i] = c * b[i];
        }
    }
    ;
}



extern "C"
__global__ void scale_kernel_int_range(int a, int *b , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            b[i] /= a ;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            b[i] /= a ;
        }
    }
    ;
}



extern "C"
__global__ void scale_kernel_double_range(double a, double *b , long start, long stop, long step)
{
    unsigned tid = threadIdx.x;
    unsigned total_threads = gridDim.x * blockDim.x;
    unsigned cta_start = blockDim.x * blockIdx.x;
    long i;
    ;
    if (step < 0)
    {
        for (i = start + (cta_start + tid) * step;
                i > stop; i += total_threads * step)
        {
            b[i] /= a ;
        }
    }
    else
    {
        for (i = start + (cta_start + tid) * step;
                i < stop; i += total_threads * step)
        {
            b[i] /= a ;
        }
    }
    ;
}

extern "C"
__global__ void synchrotron_radiation(
    double *  beam_dE,
    const double U0,
    const int n_macroparticles,
    const double tau_z,
    const int n_kicks)
{

    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    const double const_synch_rad = 2.0 / tau_z;

    for (int j = 0; j < n_kicks; j++) {
        for (int i = tid; i < n_macroparticles; i += blockDim.x * gridDim.x)
            beam_dE[i] -= const_synch_rad * beam_dE[i] + U0;
    }
}

extern "C"
__global__ void synchrotron_radiation_full(
    double *  beam_dE,
    const double U0,
    const int n_macroparticles,
    const double sigma_dE,
    const double tau_z,
    const double energy,
    const int n_kicks
)
{   unsigned int seed = 0;
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    const double const_quantum_exc = 2.0 * sigma_dE / sqrt(tau_z) * energy;
    curandState_t state;
    curand_init(seed, tid, 0, &state);
    const double const_synch_rad = 2.0 / tau_z;
    for (int j = 0; j < n_kicks; j++) {
        for (int i = tid; i < n_macroparticles; i += blockDim.x * gridDim.x)
            beam_dE[i] -= const_synch_rad * beam_dE[i] + U0 - const_quantum_exc * curand_normal_double(&state);
    }
}
