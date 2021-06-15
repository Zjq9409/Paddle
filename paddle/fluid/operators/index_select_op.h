
// Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
#pragma once
#include <vector>
#include "paddle/fluid/framework/op_registry.h"
#include "paddle/fluid/operators/jit/kernels.h"
#include "paddle/fluid/platform/cpu_info.h"

namespace paddle {
namespace operators {
using Tensor = framework::Tensor;
using LoDTensor = framework::LoDTensor;
using DDim = framework::DDim;
template <typename T, typename IndexT = int>
void IndexSelectInner(const framework::ExecutionContext& context,
                      const LoDTensor& input, const LoDTensor& index,
                      LoDTensor* output, int dim) {
  auto input_dim = input.dims();
  auto input_dim_size = input_dim.size();
  auto output_dim = output->dims();
  auto slice_size = 1;
  for (auto i = dim + 1; i < input_dim_size; i++) {
    slice_size *= input_dim[i];
  }
  auto input_width = slice_size * input_dim[dim];
  auto output_width = slice_size * output_dim[dim];
  auto outer_nums = 1;
  for (auto i = 0; i < dim; i++) {
    outer_nums *= input_dim[i];
  }
  auto index_size = index.dims()[0];
  std::vector<T> input_vec;
  std::vector<IndexT> index_vec;
  TensorToVector(input, context.device_context(), &input_vec);
  TensorToVector(index, context.device_context(), &index_vec);
  std::vector<T> out_vec(output->numel());
  for (int i = 0; i < index_size; i++) {
    PADDLE_ENFORCE_GE(
        index_vec[i], 0,
        platform::errors::InvalidArgument(
            "Variable value (index) of OP(index_select) "
            "expected >= 0 and < %ld, but got %ld. Please check input "
            "value.",
            input_dim[dim], index_vec[i]));
    PADDLE_ENFORCE_LT(
        index_vec[i], input_dim[dim],
        platform::errors::InvalidArgument(
            "Variable value (index) of OP(index_select) "
            "expected >= 0 and < %ld, but got %ld. Please check input "
            "value.",
            input_dim[dim], index_vec[i]));
  }
  VLOG(3) << "Index_Select_Debug; outer_nums: " << outer_nums
          << "; slice_size: " << slice_size << "; input_width: " << input_width
          << "; output_width: " << output_width
          << "; index_size: " << index_size;
  for (auto i = 0; i < outer_nums; i++) {
    auto input_start_offset = i * input_width;
    auto output_start_offset = i * output_width;
    for (auto j = 0; j < index_size; j++) {
      IndexT index_value = index_vec[j];
      for (auto k = 0; k < slice_size; k++) {
        out_vec[output_start_offset + j * slice_size + k] =
            input_vec[input_start_offset + index_value * slice_size + k];
      }
    }
  }
  output->mutable_data<T>(context.GetPlace());
  framework::TensorFromVector(out_vec, context.device_context(), output);
  output->Resize(output_dim);
}

template <typename DeviceContext, typename T>
class IndexSelectKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& context) const override {
    auto* inputs_var = context.InputVar("X");
    auto* index_var = context.InputVar("Index");
    auto* output_var = context.OutputVar("Out");
    auto& inputs = inputs_var->Get<LoDTensor>();
    auto& index = index_var->Get<LoDTensor>();
    auto* output = output_var->GetMutable<framework::LoDTensor>();
    int dim = context.Attr<int>("dim");
    if (dim < 0) {
      dim += inputs.dims().size();
    }
    const auto& index_type = index.type();
    bool index_type_match = index_type == framework::proto::VarType::INT32 ||
                            index_type == framework::proto::VarType::INT64;
    PADDLE_ENFORCE_EQ(index_type_match, true,
                      platform::errors::InvalidArgument(
                          "Input(Index) holds the wrong type, it holds %s, but "
                          "desires to be %s or %s",
                          paddle::framework::DataTypeToString(index_type),
                          paddle::framework::DataTypeToString(
                              framework::proto::VarType::INT32),
                          paddle::framework::DataTypeToString(
                              framework::proto::VarType::INT64)));
    if (index_type == framework::proto::VarType::INT32) {
      IndexSelectInner<T, int>(context, inputs, index, output, dim);
    } else if (index_type == framework::proto::VarType::INT64) {
      IndexSelectInner<T, int64_t>(context, inputs, index, output, dim);
    }
  }
};

#if ((!defined __NVCC__) && (!defined __HIPCC__))
template <typename platform::cpu_isa_t isa, typename T, class Enable = void>
struct IndexSelectAdd {
  void operator()(int n, const T* src, T* dst) {
    for (int i = 0; i < n; i++) {
      dst[i] += src[i];
    }
  }
};

template <typename T>
struct IndexSelectAdd<
    platform::avx, T,
    typename std::enable_if<!std::is_floating_point<T>::value>::type> {
  void operator()(const int n, const T* src, T* dst) {
    for (int i = 0; i < n; i++) {
      dst[i] += src[i];
    }
  }
};

template <typename T>
struct IndexSelectAdd<
    platform::avx, T,
    typename std::enable_if<std::is_floating_point<T>::value>::type> {
  void operator()(const int n, const T* src, T* dst) {
#ifdef __AVX__
    int block = 0;
    if (std::is_same<T, float>::value) {
      block = YMM_FLOAT_BLOCK;
    } else if (std::is_same<T, double>::value) {
      block = XMM_FLOAT_BLOCK;
    }
    int i = 0;
    int end = n & ~(block - 1);
    if (std::is_same<T, float>::value) {
      for (i = 0; i < end; i += block) {
        _mm256_storeu_ps(reinterpret_cast<float*>(dst) + i,
                         _mm256_add_ps(_mm256_loadu_ps((const float*)dst + i),
                                       _mm256_loadu_ps((const float*)src + i)));
      }
    } else if (std::is_same<T, double>::value) {
      for (i = 0; i < end; i += block) {
        _mm256_storeu_pd(
            reinterpret_cast<double*>(dst) + i,
            _mm256_add_pd(_mm256_loadu_pd((const double*)dst + i),
                          _mm256_loadu_pd((const double*)src + i)));
      }
    }
    for (; i < n; i++) {
      dst[i] += src[i];
    }
#else
    IndexSelectAdd<platform::isa_any, T> index_select_add_any;
    index_select_add_any(n, src, dst);
#endif
  }
};
#endif

template <typename T, typename IndexT = int>
void IndexSelectGradInner(const framework::ExecutionContext& context,
                          const LoDTensor& out_grad, const LoDTensor& index,
                          LoDTensor* x_grad, int dim) {
  const T* input_data = out_grad.data<T>();
  const IndexT* index_data = index.data<IndexT>();
  T* out_data = x_grad->mutable_data<T>(context.GetPlace());
  auto input_dim = out_grad.dims();
  auto input_dim_size = input_dim.size();
  auto output_dim = x_grad->dims();
  std::memset(out_data, 0.0, x_grad->numel() * sizeof(T));

  auto slice_size = 1;
  for (auto i = dim + 1; i < input_dim_size; i++) {
    slice_size *= input_dim[i];
  }
  auto input_width = slice_size * input_dim[dim];
  auto output_width = slice_size * output_dim[dim];
  auto outer_nums = 1;
  for (auto i = 0; i < dim; i++) {
    outer_nums *= input_dim[i];
  }
  auto index_size = index.dims()[0];
  VLOG(3) << "Index_Select_Grad_Debug; outer_nums: " << outer_nums
          << "; slice_size: " << slice_size << "; input_width: " << input_width
          << "; output_width: " << output_width
          << "; index_size: " << index_size;
  for (auto i = 0; i < outer_nums; i++) {
    auto input_start_offset = i * input_width;
    auto output_start_offset = i * output_width;
    for (auto j = 0; j < index_size; j++) {
      IndexT index_value = index_data[j];
      auto src = input_data + input_start_offset + j * slice_size;
      auto dst = out_data + output_start_offset + index_value * slice_size;

#if ((!defined __NVCC__) && (!defined __HIPCC__))

#ifdef __AVX__
      IndexSelectAdd<platform::avx, T> index_select_add_avx;
      index_select_add_avx(slice_size, src, dst);
#else
      IndexSelectAdd<platform::isa_any, T> index_select_add_any;
      index_select_add_any(slice_size, src, dst);
#endif
#endif
    }
  }
  x_grad->Resize(output_dim);
}

template <typename DeviceContext, typename T>
class IndexSelectGradKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& context) const override {
    auto* index_var = context.InputVar("Index");
    auto* x_grad_var = context.OutputVar(framework::GradVarName("X"));
    auto* out_grad_var = context.InputVar(framework::GradVarName("Out"));
    auto& index = index_var->Get<LoDTensor>();
    auto& out_grad = out_grad_var->Get<LoDTensor>();
    auto* x_grad = x_grad_var->GetMutable<framework::LoDTensor>();
    int dim = context.Attr<int>("dim");
    if (dim < 0) {
      dim += out_grad.dims().size();
    }
    const auto& index_type = index.type();
    bool index_type_match = index_type == framework::proto::VarType::INT32 ||
                            index_type == framework::proto::VarType::INT64;
    PADDLE_ENFORCE_EQ(index_type_match, true,
                      platform::errors::InvalidArgument(
                          "Input(Index) holds the wrong type, it holds %s, but "
                          "desires to be %s or %s",
                          paddle::framework::DataTypeToString(index_type),
                          paddle::framework::DataTypeToString(
                              framework::proto::VarType::INT32),
                          paddle::framework::DataTypeToString(
                              framework::proto::VarType::INT64)));
    if (index_type == framework::proto::VarType::INT32) {
      IndexSelectGradInner<T, int>(context, out_grad, index, x_grad, dim);
    } else if (index_type == framework::proto::VarType::INT64) {
      IndexSelectGradInner<T, int64_t>(context, out_grad, index, x_grad, dim);
    }
  }
};
}  // namespace operators
}  // namespace paddle
