/* Copyright (c) 2018 PaddlePaddle Authors. All Rights Reserved.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#ifdef __NVCC__
#include "cub/cub.cuh"
#endif
#ifdef __HIPCC__
#include <hipcub/hipcub.hpp>
namespace cub = hipcub;
#endif

#include "paddle/fluid/operators/group_norm_op.h"
#include "paddle/fluid/platform/device/gpu/gpu_device_function.h"
#include "paddle/fluid/platform/device/gpu/gpu_primitives.h"

namespace paddle {
namespace operators {

using DataLayout = framework::DataLayout;
enum GroupNormKernelFlags { kHasScale = 1, kHasBias = 2 };
#define ALIGN_BYTES 16

#define CHECK_CASE(i, flags, kernel_name, ...)                              \
  if (i == flags) {                                                         \
    kernel_name<T, i><<<grid, threads, 0, dev_ctx.stream()>>>(__VA_ARGS__); \
  }

// 0 for no scale, no bias
// 1 for has scale, no bias
// 2 for no scale, has bias
// 3 for has scale, has bias
#define UNROLL_ALL_CASES(flags, kernel_name, ...) \
  CHECK_CASE(0, flags, kernel_name, __VA_ARGS__)  \
  CHECK_CASE(1, flags, kernel_name, __VA_ARGS__)  \
  CHECK_CASE(2, flags, kernel_name, __VA_ARGS__)  \
  CHECK_CASE(3, flags, kernel_name, __VA_ARGS__)

template <typename T>
__device__ __inline__ void CudaAtomicAddWithWarp(T* sum, T value) {
  typedef cub::WarpReduce<T> WarpReduce;
  typename WarpReduce::TempStorage temp_storage;
  value = WarpReduce(temp_storage).Sum(value);
  if (cub::LaneId() == 0) platform::CudaAtomicAdd(sum, value);
}

template <typename T>
__global__ void GroupNormForwardGetMeanAndVar(const T* x, int N, int C, int W,
                                              int imsize, int groups,
                                              int group_size, T* mean, T* var,
                                              const DataLayout data_layout) {
  int gid = blockIdx.y;
  int cid = blockIdx.x;
  int bid = blockIdx.z;
  int H = imsize / W;
  int number = min(group_size, static_cast<int>(C - gid * group_size));
  int ccid = gid * group_size + cid;
  if (ccid >= C) return;
  T x_mean = 0, x_var = 0;
  for (int imid = threadIdx.x; imid < imsize; imid += blockDim.x) {
    T val;
    int hid = imid / W;
    int wid = imid % W;
    val = x[(bid * H + hid) * W * C + wid * C + ccid];

    x_mean += val;
    x_var += val * val;
  }
  x_mean /= number * imsize;
  x_var /= number * imsize;
  CudaAtomicAddWithWarp(&mean[bid * groups + gid], x_mean);
  CudaAtomicAddWithWarp(&var[bid * groups + gid], x_var);
}

template <typename T, typename AccT, int VecSize>
__device__ __forceinline__ void ThreadReduce(const T* input, int size,
                                             const int offset, AccT* mean,
                                             AccT* var) {
  using VecT = kps::details::VectorType<T, VecSize>;
  int tid = threadIdx.x;

  if (offset > 0) {
    input -= offset;
    size += offset;
    if (tid >= offset) {
      AccT temp = input[tid];
      *mean += temp;
      *var += temp * temp;
    }
    size -= blockDim.x;
    input += blockDim.x;
  }
  int remain = size % (VecSize * blockDim.x);

  T ins[VecSize];
  VecT* ins_vec = reinterpret_cast<VecT*>(&ins);

  // vector part
  for (; VecSize * tid < (size - remain); tid += blockDim.x) {
    *ins_vec = reinterpret_cast<const VecT*>(input)[tid];

#pragma unroll
    for (int i = 0; i < VecSize; ++i) {
      AccT temp = ins[i];
      *mean += temp;
      *var += temp * temp;
    }
  }

  // scalar part
  tid = size - remain + threadIdx.x;
  for (; tid < size; tid += blockDim.x) {
    AccT temp = input[tid];
    *mean += temp;
    *var += temp * temp;
  }
}

template <typename T, typename AccT, int VecSize, int BlockDim>
__global__ void GroupNormForwardGetMeanAndVarNCHW(
    const T* x, int N, int C, int W, int imsize, int groups, int group_size,
    T* mean, T* var, const DataLayout data_layout) {
  // each block deal with one batch
  x += blockIdx.x * group_size * imsize;
  const int input_offset = ((uint64_t)x) % ALIGN_BYTES / sizeof(T);

  AccT x_mean = static_cast<AccT>(0);
  AccT x_var = static_cast<AccT>(0);
  ThreadReduce<T, AccT, VecSize>(x, group_size * imsize, input_offset, &x_mean,
                                 &x_var);

  x_mean /= group_size * imsize;
  x_var /= group_size * imsize;
  if (blockDim.x <= 32) {
    CudaAtomicAddWithWarp(&mean[blockIdx.x], x_mean);
    CudaAtomicAddWithWarp(&var[blockIdx.x], x_var);
  } else {
    typedef cub::BlockReduce<T, BlockDim> BlockReduce;

    __shared__ typename BlockReduce::TempStorage mean_storage;
    __shared__ typename BlockReduce::TempStorage var_storage;

    __syncthreads();
    auto mean_out = BlockReduce(mean_storage).Reduce(x_mean, cub::Sum());
    auto var_out = BlockReduce(var_storage).Reduce(x_var, cub::Sum());
    __syncthreads();
    if (threadIdx.x == 0) {
      mean[blockIdx.x] = mean_out;
      var[blockIdx.x] = var_out;
    }
  }
}

template <typename T, int flags>
__global__ void GroupNormForward(const T* x, const T* mean, const T* var,
                                 const T* scale, const T* bias, int N, int C,
                                 int W, int imsize, int groups, int group_size,
                                 T epsilon, T* y, T* real_var,
                                 const DataLayout data_layout) {
  int gid = blockIdx.y;
  int cid = blockIdx.x;
  int bid = blockIdx.z;
  int H = imsize / W;
  int ccid = gid * group_size + cid;
  if (ccid >= C) return;
  T x_mean = mean[bid * groups + gid];
  T x_var = var[bid * groups + gid];
  x_var = x_var - x_mean * x_mean;
  T var_inv = 1.0 / sqrt(x_var + epsilon);
  if (cid == 0 && threadIdx.x == 0) real_var[bid * groups + gid] = x_var;
  for (int imid = threadIdx.x; imid < imsize; imid += blockDim.x) {
    T val;
    int hid, wid;
    if (data_layout == DataLayout::kNCHW) {
      val = x[(bid * C + ccid) * imsize + imid];
    } else {
      hid = imid / W;
      wid = imid % W;
      val = x[(bid * H + hid) * W * C + wid * C + ccid];
    }
    val = (val - x_mean) * var_inv;
    if (flags & kHasScale) val *= scale[gid * group_size + cid];
    if (flags & kHasBias) val += bias[gid * group_size + cid];
    if (data_layout == DataLayout::kNCHW) {
      y[(bid * C + ccid) * imsize + imid] = val;
    } else {
      y[(bid * H + hid) * W * C + wid * C + ccid] = val;
    }
  }
}

template <typename T>
class GroupNormKernel<platform::CUDADeviceContext, T>
    : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& ctx) const override {
    const std::string data_layout_str = ctx.Attr<std::string>("data_layout");
    const DataLayout data_layout =
        framework::StringToDataLayout(data_layout_str);
    const float epsilon = ctx.Attr<float>("epsilon");
    auto* scale = ctx.Input<Tensor>("Scale");
    auto* bias = ctx.Input<Tensor>("Bias");
    auto* x = ctx.Input<Tensor>("X");

    auto* y = ctx.Output<Tensor>("Y");
    auto* mean = ctx.Output<Tensor>("Mean");
    auto* var = ctx.Output<Tensor>("Variance");
    const auto groups = ctx.Attr<int>("groups");

    const auto x_dims = x->dims();
    const int C =
        (data_layout == DataLayout::kNCHW ? x_dims[1]
                                          : x_dims[x_dims.size() - 1]);
    const int group_size = C / groups;

    const int W =
        (data_layout == DataLayout::kNCHW ? x_dims[x_dims.size() - 1]
                                          : x_dims[x_dims.size() - 2]);

    y->mutable_data<T>(ctx.GetPlace());
    mean->mutable_data<T>(ctx.GetPlace());
    var->mutable_data<T>(ctx.GetPlace());
    phi::funcs::SetConstant<platform::CUDADeviceContext, T> set_zero;
    auto& dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();
    Tensor temp_var;
    temp_var.mutable_data<T>(var->dims(), ctx.GetPlace());

    set_zero(dev_ctx, mean, static_cast<T>(0));
    set_zero(dev_ctx, &temp_var, static_cast<T>(0));

    auto* x_data = x->data<T>();
    auto* y_data = y->data<T>();
    auto* mean_data = mean->data<T>();
    auto* var_data = var->data<T>();
    auto* temp_var_data = temp_var.data<T>();

    const T* scale_data = nullptr;
    if (scale) scale_data = scale->data<T>();
    const T* bias_data = nullptr;
    if (bias) bias_data = bias->data<T>();

    int imsize = 1;
    if (data_layout == DataLayout::kNCHW) {
      for (int i = 2; i < x_dims.size(); ++i) {
        imsize *= x_dims[i];
      }
    } else {
      for (int i = 1; i < x_dims.size() - 1; ++i) {
        imsize *= x_dims[i];
      }
    }

#ifdef __HIPCC__
    int block_size = std::max(std::min(256, imsize), 64);
    const int block_dim = 256;
#else
    int block_size = std::min(1024, imsize);
    const int block_dim = 1024;
#endif

    dim3 grid(group_size, groups, x_dims[0]);
    dim3 threads(block_size, 1, 1);
    if (data_layout == DataLayout::kNCHW) {
      using AccT = typename details::MPTypeTrait<T>::Type;
      constexpr int vec_size = sizeof(float4) / sizeof(T);
      const int max_num_threads = 1024;
      int max_block_size =
          std::min(group_size * imsize / vec_size, max_num_threads);

      int block_size_nchw = 1;
      while (block_size_nchw < max_block_size) {
        block_size_nchw *= 2;
      }
      block_size_nchw = std::max(max_block_size, kps::details::kWarpSize);
      dim3 grids(x_dims[0] * groups);
      dim3 blocks(block_size_nchw);
      GroupNormForwardGetMeanAndVarNCHW<
          T, AccT, vec_size, block_dim><<<grids, blocks, 0, dev_ctx.stream()>>>(
          x_data, x_dims[0], C, W, imsize, groups, group_size, mean_data,
          temp_var_data, data_layout);
    } else {
      GroupNormForwardGetMeanAndVar<T><<<grid, threads, 0, dev_ctx.stream()>>>(
          x_data, x_dims[0], C, W, imsize, groups, group_size, mean_data,
          temp_var_data, data_layout);
    }

    int flags =
        (scale_data != nullptr) * kHasScale + (bias_data != nullptr) * kHasBias;
    UNROLL_ALL_CASES(flags, GroupNormForward, x_data, mean_data, temp_var_data,
                     scale_data, bias_data, x_dims[0], C, W, imsize, groups,
                     group_size, epsilon, y_data, var_data, data_layout);
  }
};

template <typename T, int flags>
__global__ void GroupNormBackwardGetMeanAndVar(
    const T* x, const T* scale, const T* bias, const T* d_y, int N, int C,
    int W, int imsize, int groups, int group_size, T epsilon, T* d_mean,
    T* d_var, T* d_scale, T* d_bias, const DataLayout data_layout) {
  int gid = blockIdx.y;
  int cid = blockIdx.x;
  int bid = blockIdx.z;
  int H = imsize / W;
  int number = min(group_size, static_cast<int>(C - gid * group_size));
  int ccid = gid * group_size + cid;
  if (ccid >= C) return;
  T x_scale = (flags & kHasScale) ? scale[ccid] : 1;
  T x_bias = (flags & kHasBias) ? bias[ccid] : 0;
  T x_scale_inv = 0;
  if (x_scale != 0) x_scale_inv = 1.0 / x_scale;
  T d_mean_data = 0, d_var_data = 0, d_scale_data = 0, d_bias_data = 0;

  for (int imid = threadIdx.x; imid < imsize; imid += blockDim.x) {
    T val, dval;
    int index = (bid * C + ccid) * imsize + imid;
    if (data_layout == DataLayout::kNCHW) {
      val = x[index] - x_bias;
      dval = d_y[index];
    } else {
      int hid = imid / W;
      int wid = imid % W;
      val = x[(bid * H + hid) * W * C + wid * C + ccid] - x_bias;
      dval = d_y[(bid * H + hid) * W * C + wid * C + ccid];
    }

    d_var_data += val * dval;
    d_mean_data += dval * x_scale;

    if (flags & kHasBias) {
      d_bias_data += dval;
    }
    if (flags & kHasScale) {
      val = val * x_scale_inv;
      d_scale_data += val * dval;
    }
  }

  if (blockDim.x <= 32) {
    CudaAtomicAddWithWarp(&(d_mean[bid * groups + gid]), d_mean_data);
    CudaAtomicAddWithWarp(&(d_var[bid * groups + gid]), d_var_data);
  } else {
    auto mean_out = kps::details::BlockXReduce<T, kps::AddFunctor<T>>(
        d_mean_data, kps::AddFunctor<T>());
    auto var_out = kps::details::BlockXReduce<T, kps::AddFunctor<T>>(
        d_var_data, kps::AddFunctor<T>());
    if (threadIdx.x == 0) {
      platform::CudaAtomicAdd(&(d_mean[bid * groups + gid]), mean_out);
      platform::CudaAtomicAdd(&(d_var[bid * groups + gid]), var_out);
    }
  }
  if (flags & kHasScale) {
    if (blockDim.x <= 32) {
      CudaAtomicAddWithWarp(&(d_scale[ccid]), d_scale_data);
    } else {
      auto d_scale_out = kps::details::BlockXReduce<T, kps::AddFunctor<T>>(
          d_scale_data, kps::AddFunctor<T>());
      if (threadIdx.x == 0) {
        platform::CudaAtomicAdd(&(d_scale[ccid]), d_scale_out);
      }
    }
  }

  if (flags & kHasBias) {
    if (blockDim.x <= 32) {
      CudaAtomicAddWithWarp(&(d_bias[ccid]), d_bias_data);
    } else {
      auto d_bias_out = kps::details::BlockXReduce<T, kps::AddFunctor<T>>(
          d_bias_data, kps::AddFunctor<T>());
      if (threadIdx.x == 0) {
        platform::CudaAtomicAdd(&(d_bias[ccid]), d_bias_out);
      }
    }
  }
  // if (flags & kHasScale) CudaAtomicAddWithWarp(&(d_scale[ccid]),
  // d_scale_data);
  // if (flags & kHasBias) CudaAtomicAddWithWarp(&(d_bias[ccid]), d_bias_data);
}

template <typename T, int flags>
__global__ void GroupNormBackward(const T* x, const T* d_y, const T* scale,
                                  const T* bias, const T* var, const T* d_mean,
                                  const T* d_var, int N, int C, int W,
                                  int imsize, int groups, int group_size,
                                  T epsilon, T* d_x,
                                  const DataLayout data_layout) {
  int gid = blockIdx.y;
  int cid = blockIdx.x;
  int bid = blockIdx.z;
  int H = imsize / W;
  int number = min(group_size, static_cast<int>(C - gid * group_size));
  int ccid = gid * group_size + cid;
  if (ccid >= C) return;
  int ng = bid * groups + gid;
  T x_var = var[ng];
  T d_x_mean = d_mean[ng];
  T d_x_var = d_var[ng];

  T x_var_inv = rsqrt(x_var + epsilon);
  T number_inv = 1.0 / (number * imsize);

  T x_scale = (flags & kHasScale) ? scale[ccid] : 1;
  T x_bias = (flags & kHasBias) ? bias[ccid] : 0;
  T x_scale_inv = 0;
  if (x_scale != 0) x_scale_inv = 1.0 / x_scale;

  for (int imid = threadIdx.x; imid < imsize; imid += blockDim.x) {
    if (data_layout == DataLayout::kNCHW) {
      int index = (bid * C + ccid) * imsize + imid;
      T tmp = x[index];
      T v_y = (tmp - x_bias) * x_scale_inv;
      T dly = d_y[index];
      d_x[index] = x_var_inv * (dly * x_scale - number_inv * d_x_var * v_y -
                                number_inv * d_x_mean);
    } else {
      int hid = imid / W;
      int wid = imid % W;
      T tmp = x[(bid * H + hid) * W * C + wid * C + ccid];
      T v_y = (tmp - x_bias) * x_scale_inv;
      T dly = d_y[(bid * H + hid) * W * C + wid * C + ccid];
      d_x[(bid * H + hid) * W * C + wid * C + ccid] =
          x_var_inv *
          (dly * x_scale - number_inv * d_x_var * v_y - number_inv * d_x_mean);
    }
  }
}

template <typename T>
class GroupNormGradKernel<platform::CUDADeviceContext, T>
    : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& ctx) const override {
    const std::string data_layout_str = ctx.Attr<std::string>("data_layout");
    const DataLayout data_layout =
        framework::StringToDataLayout(data_layout_str);
    const float epsilon = ctx.Attr<float>("epsilon");
    auto* x = ctx.Input<Tensor>("Y");
    auto* var = ctx.Input<Tensor>("Variance");
    auto* scale = ctx.Input<Tensor>("Scale");
    auto* bias = ctx.Input<Tensor>("Bias");
    auto* d_y = ctx.Input<Tensor>(framework::GradVarName("Y"));
    const auto groups = ctx.Attr<int>("groups");

    // init output
    auto* d_x = ctx.Output<Tensor>(framework::GradVarName("X"));
    auto* d_scale = ctx.Output<Tensor>(framework::GradVarName("Scale"));
    auto* d_bias = ctx.Output<Tensor>(framework::GradVarName("Bias"));

    const auto& x_dims = x->dims();
    const int C =
        (data_layout == DataLayout::kNCHW ? x_dims[1]
                                          : x_dims[x_dims.size() - 1]);
    const int group_size = C / groups;
    const int W =
        (data_layout == DataLayout::kNCHW ? x_dims[x_dims.size() - 1]
                                          : x_dims[x_dims.size() - 2]);

    d_x->mutable_data<T>(ctx.GetPlace());
    pten::funcs::SetConstant<platform::CUDADeviceContext, T> set_zero;
    auto& dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();

    Tensor temp_var;
    temp_var.mutable_data<T>(var->dims(), ctx.GetPlace());
    set_zero(dev_ctx, &temp_var, static_cast<T>(0));
    T* temp_var_data = temp_var.data<T>();

    Tensor temp_mean;
    temp_mean.mutable_data<T>(var->dims(), ctx.GetPlace());
    set_zero(dev_ctx, &temp_mean, static_cast<T>(0));
    T* temp_mean_data = temp_mean.data<T>();

    auto* x_data = x->data<T>();
    T* d_x_data = nullptr;
    if (d_x) d_x_data = d_x->data<T>();
    auto* y_data = d_y->data<T>();
    auto* var_data = var->data<T>();
    T* d_scale_data = nullptr;
    if (d_scale) {
      d_scale->mutable_data<T>(ctx.GetPlace());
      set_zero(dev_ctx, d_scale, static_cast<T>(0));
      d_scale_data = d_scale->data<T>();
    }
    T* d_bias_data = nullptr;
    if (d_bias) {
      d_bias->mutable_data<T>(ctx.GetPlace());
      set_zero(dev_ctx, d_bias, static_cast<T>(0));
      d_bias_data = d_bias->data<T>();
    }

    const T* scale_data = nullptr;
    if (scale) scale_data = scale->data<T>();
    const T* bias_data = nullptr;
    if (bias) bias_data = bias->data<T>();

    int imsize = 1;
    if (data_layout == DataLayout::kNCHW) {
      for (int i = 2; i < x_dims.size(); ++i) {
        imsize *= x_dims[i];
      }
    } else {
      for (int i = 1; i < x_dims.size() - 1; ++i) {
        imsize *= x_dims[i];
      }
    }

#ifdef __HIPCC__
    int block_size = std::max(std::min(256, imsize), 64);
#else
    int block_size = std::min(1024, imsize);
#endif
    dim3 grid(group_size, groups, x_dims[0]);
    dim3 threads(block_size, 1, 1);
    int flags =
        (scale_data != nullptr) * kHasScale + (bias_data != nullptr) * kHasBias;
    UNROLL_ALL_CASES(flags, GroupNormBackwardGetMeanAndVar, x_data, scale_data,
                     bias_data, y_data, x_dims[0], C, W, imsize, groups,
                     group_size, epsilon, temp_mean_data, temp_var_data,
                     d_scale_data, d_bias_data, data_layout);
    if (d_x_data != nullptr) {
      UNROLL_ALL_CASES(flags, GroupNormBackward, x_data, y_data, scale_data,
                       bias_data, var_data, temp_mean_data, temp_var_data,
                       x_dims[0], C, W, imsize, groups, group_size, epsilon,
                       d_x_data, data_layout);
    }
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
REGISTER_OP_CUDA_KERNEL(
    group_norm,
    ops::GroupNormKernel<paddle::platform::CUDADeviceContext, float>,
    ops::GroupNormKernel<paddle::platform::CUDADeviceContext, double>);
REGISTER_OP_CUDA_KERNEL(
    group_norm_grad,
    ops::GroupNormGradKernel<paddle::platform::CUDADeviceContext, float>,
    ops::GroupNormGradKernel<paddle::platform::CUDADeviceContext, double>);
