// Copyright (c) 2018 PaddlePaddle Authors. All Rights Reserved.
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

#include <cuda_runtime.h>
#include <stdio.h>

#include <cassert>
#include <cub/cub.cuh>  // NOLINT
#include <vector>

#include "glog/logging.h"
#include "paddle/fluid/inference/tensorrt/plugin/slice_op_plugin.h"

namespace paddle {
namespace inference {
namespace tensorrt {
namespace plugin {

template <typename T>
__global__ void SliceKernel(int num, int dims, const T *input,
                            const int *offsets_info, T *output) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  extern __shared__ int shared_data[];

  for (int i = threadIdx.x; i < dims * 3; i += blockDim.x) {
    shared_data[i] = offsets_info[i];
  }
  __syncthreads();

  if (idx < num) {
    int t_idx = idx;
    int in_idx = 0;
    for (int i = dims - 1; i >= 0; i--) {
      // output_shape
      auto t = t_idx % shared_data[i * 3 + 1];
      // out offset
      auto s = t + shared_data[i * 3];
      // input_seg_offset
      in_idx = in_idx + shared_data[i * 3 + 2] * s;
      t_idx = t_idx / shared_data[i * 3 + 1];
    }
    output[idx] = input[in_idx];
  }
}

SlicePlugin::SlicePlugin(std::vector<int> starts, std::vector<int> ends,
                         std::vector<int> axes, bool with_fp16)
    : starts_(starts), ends_(ends), axes_(axes) {
  with_fp16_ = with_fp16;
}

SlicePlugin::SlicePlugin(void const *serial_data, size_t serial_length) {
  deserializeBase(serial_data, serial_length);
  DeserializeValue(&serial_data, &serial_length, &starts_);
  DeserializeValue(&serial_data, &serial_length, &ends_);
  DeserializeValue(&serial_data, &serial_length, &axes_);
  DeserializeValue(&serial_data, &serial_length, &with_fp16_);
  DeserializeValue(&serial_data, &serial_length, &offset_info_);
}

SlicePlugin::~SlicePlugin() { cudaFree(offset_temp_data_); }

SlicePlugin *SlicePlugin::clone() const TRT_NOEXCEPT {
  return new SlicePlugin(starts_, ends_, axes_, with_fp16_);
}

bool SlicePlugin::supportsFormat(
    nvinfer1::DataType type, nvinfer1::PluginFormat format) const TRT_NOEXCEPT {
  if (with_fp16_) {
    return ((type == nvinfer1::DataType::kFLOAT ||
             type == nvinfer1::DataType::kHALF) &&
            (format == nvinfer1::PluginFormat::kLINEAR));
  } else {
    return ((type == nvinfer1::DataType::kFLOAT) &&
            (format == nvinfer1::PluginFormat::kLINEAR));
  }
}

nvinfer1::Dims SlicePlugin::getOutputDimensions(
    int index, const nvinfer1::Dims *inputs, int nb_input_dims) TRT_NOEXCEPT {
  auto in_dims = inputs[0];
  nvinfer1::Dims out_dims = in_dims;
  for (size_t i = 0; i < axes_.size(); i++) {
    int start = starts_[i];
    int end = ends_[i];
    out_dims.d[axes_[i] - 1] = end - start;
  }
  return out_dims;
}

int SlicePlugin::enqueue(int batch_size, const void *const *inputs,
#if IS_TRT_VERSION_LT(8000)
                         void **outputs, void *workspace, cudaStream_t stream) {
#else
                         void *const *outputs, void *workspace,
                         cudaStream_t stream) TRT_NOEXCEPT {
#endif
  auto input_dims = getInputDims(0);

  // notice input dims is [C, H, W], add input batch dim here
  auto out_dims = getOutputDimensions(0, &input_dims, 1);
  input_dims.nbDims += 1;
  out_dims.nbDims += 1;
  for (auto i = input_dims.nbDims; i > 0; --i) {
    input_dims.d[i] = input_dims.d[i - 1];
    out_dims.d[i] = out_dims.d[i - 1];
  }
  input_dims.d[0] = batch_size;
  out_dims.d[0] = batch_size;

  auto num_dims = input_dims.nbDims;
  size_t out_num = ProductDim(out_dims);

  std::vector<int> seg_offsets;
  std::vector<int> offsets;
  std::vector<int> extends;

  offsets.resize(num_dims);
  extends.resize(num_dims);
  seg_offsets.resize(num_dims);

  seg_offsets[num_dims - 1] = 1;
  for (int i = num_dims - 2; i >= 0; i--) {
    seg_offsets[i] = input_dims.d[i + 1] * seg_offsets[i + 1];
  }
  for (size_t i = 0; i < num_dims; ++i) {
    offsets[i] = 0;
    extends[i] = out_dims.d[i];
  }
  for (size_t i = 0; i < axes_.size(); ++i) {
    offsets[axes_[i]] = starts_[i];
  }

  std::vector<int> offset_info;
  for (size_t i = 0; i < num_dims; ++i) {
    offset_info.push_back(offsets[i]);
    offset_info.push_back(extends[i]);
    offset_info.push_back(seg_offsets[i]);
  }

  if (offset_temp_data_ == nullptr) {
    cudaMalloc(&offset_temp_data_, 3 * num_dims * sizeof(int));
  }

  cudaMemcpyAsync(offset_temp_data_, offset_info.data(),
                  sizeof(int) * 3 * num_dims, cudaMemcpyHostToDevice, stream);

  int threads = 256;
  int blocks = (out_num + threads - 1) / threads;
  auto input_type = getDataType();
  if (input_type == nvinfer1::DataType::kFLOAT) {
    VLOG(1) << "TRT Plugin DataType selected. Slice-->fp32";
    const float *input1 = static_cast<const float *>(inputs[0]);
    float *output = static_cast<float *>(outputs[0]);
    SliceKernel<float><<<blocks, threads, 3 * num_dims * sizeof(int), stream>>>(
        out_num, num_dims, input1, offset_temp_data_, output);
  } else if (input_type == nvinfer1::DataType::kHALF) {
    VLOG(1) << "TRT Plugin DataType selected. Slice-->fp16";
    const half *input1 = static_cast<const half *>(inputs[0]);
    half *output = static_cast<half *>(outputs[0]);
    SliceKernel<half><<<blocks, threads, 3 * num_dims * sizeof(int), stream>>>(
        out_num, num_dims, input1, offset_temp_data_, output);
  } else {
    PADDLE_THROW(platform::errors::Fatal(
        "The Slice TRT Plugin's input type should be float or half."));
  }
  return cudaGetLastError() != cudaSuccess;
}

size_t SlicePlugin::getSerializationSize() const TRT_NOEXCEPT {
  return getBaseSerializationSize() + SerializedSize(starts_) +
         SerializedSize(ends_) + SerializedSize(axes_) +
         SerializedSize(with_fp16_) + SerializedSize(offset_info_);
}

void SlicePlugin::serialize(void *buffer) const TRT_NOEXCEPT {
  serializeBase(buffer);
  SerializeValue(&buffer, starts_);
  SerializeValue(&buffer, ends_);
  SerializeValue(&buffer, axes_);
  SerializeValue(&buffer, with_fp16_);
  SerializeValue(&buffer, offset_info_);
}

// Dynamic Plugin below.
#if IS_TRT_VERSION_GE(6000)
SlicePluginDynamic::SlicePluginDynamic(std::vector<int> starts,
                                       std::vector<int> ends,
                                       std::vector<int> axes, int decrease_axis,
                                       bool with_fp16)
    : starts_(starts), ends_(ends), axes_(axes), decrease_axis_(decrease_axis) {
  with_fp16_ = with_fp16;
}

SlicePluginDynamic::SlicePluginDynamic(void const *serialData,
                                       size_t serialLength) {
  DeserializeValue(&serialData, &serialLength, &starts_);
  DeserializeValue(&serialData, &serialLength, &ends_);
  DeserializeValue(&serialData, &serialLength, &axes_);
  DeserializeValue(&serialData, &serialLength, &decrease_axis_);
  DeserializeValue(&serialData, &serialLength, &with_fp16_);
  DeserializeValue(&serialData, &serialLength, &offset_info_);
}

void SlicePluginDynamic::destroy() TRT_NOEXCEPT {
  cudaFree(offset_temp_data_);
  delete this;
}

int SlicePluginDynamic::initialize() TRT_NOEXCEPT { return 0; }

size_t SlicePluginDynamic::getSerializationSize() const TRT_NOEXCEPT {
  size_t size = SerializedSize(starts_) + SerializedSize(ends_) +
                SerializedSize(axes_) + SerializedSize(decrease_axis_) +
                SerializedSize(with_fp16_) + SerializedSize(offset_info_);

  return size;
}

void SlicePluginDynamic::serialize(void *buffer) const TRT_NOEXCEPT {
  SerializeValue(&buffer, starts_);
  SerializeValue(&buffer, ends_);
  SerializeValue(&buffer, axes_);
  SerializeValue(&buffer, decrease_axis_);
  SerializeValue(&buffer, with_fp16_);
  SerializeValue(&buffer, offset_info_);
}

nvinfer1::DimsExprs SlicePluginDynamic::getOutputDimensions(
    int output_index, const nvinfer1::DimsExprs *inputs, int nb_inputs,
    nvinfer1::IExprBuilder &expr_builder) TRT_NOEXCEPT {
  auto in_dims = inputs[0];
  nvinfer1::DimsExprs ret = in_dims;
  // start, ends should greater 0
  for (size_t i = 0; i < axes_.size(); i++) {
    int start = starts_[i];
    int end = ends_[i];
#if IS_TRT_VERSION_GE(7200)
    ret.d[axes_[i]] = expr_builder.operation(
        nvinfer1::DimensionOperation::kSUB,
        *expr_builder.operation(nvinfer1::DimensionOperation::kMIN,
                                *expr_builder.constant(ends_[i]),
                                *in_dims.d[axes_[i]]),
        *expr_builder.constant(start));
#else
    ret.d[axes_[i]] = expr_builder.constant(end - start);
#endif
  }
  if (decrease_axis_ != -1) {
    nvinfer1::DimsExprs res;
    res.nbDims = ret.nbDims - 1;
    int j = 0;
    for (size_t i = 0; i < in_dims.nbDims; i++) {
      if (decrease_axis_ == i) continue;
      res.d[j++] = expr_builder.operation(nvinfer1::DimensionOperation::kMAX,
                                          *expr_builder.constant(0), *ret.d[i]);
    }
    return res;
  }
  return ret;
}

bool SlicePluginDynamic::supportsFormatCombination(
    int pos, const nvinfer1::PluginTensorDesc *in_out, int nb_inputs,
    int nb_outputs) TRT_NOEXCEPT {
  PADDLE_ENFORCE_NOT_NULL(
      in_out, platform::errors::InvalidArgument(
                  "The input of swish plugin shoule not be nullptr."));

  PADDLE_ENFORCE_LT(
      pos, nb_inputs + nb_outputs,
      platform::errors::InvalidArgument("The pos(%d) should be less than the "
                                        "num(%d) of the input and the output.",
                                        pos, nb_inputs + nb_outputs));

  const nvinfer1::PluginTensorDesc &in = in_out[pos];
  if (pos == 0) {
    if (with_fp16_) {
      return (in.type == nvinfer1::DataType::kFLOAT ||
              in.type == nvinfer1::DataType::kHALF) &&
             (in.format == nvinfer1::TensorFormat::kLINEAR);
    } else {
      return (in.type == nvinfer1::DataType::kFLOAT) &&
             (in.format == nvinfer1::TensorFormat::kLINEAR);
    }
  }
  const nvinfer1::PluginTensorDesc &prev = in_out[pos - 1];
  // output
  return in.type == prev.type && in.format == prev.format;
}

nvinfer1::DataType SlicePluginDynamic::getOutputDataType(
    int index, const nvinfer1::DataType *input_types,
    int nb_inputs) const TRT_NOEXCEPT {
  PADDLE_ENFORCE_EQ(index, 0,
                    platform::errors::InvalidArgument(
                        "The Slice Plugin only has one input, so the "
                        "index value should be 0, but get %d.",
                        index));
  PADDLE_ENFORCE_EQ((input_types[0] == nvinfer1::DataType::kFLOAT ||
                     input_types[0] == nvinfer1::DataType::kHALF),
                    true,
                    platform::errors::InvalidArgument(
                        "The input type should be half or float"));
  return input_types[0];
}

int SlicePluginDynamic::enqueue(const nvinfer1::PluginTensorDesc *input_desc,
                                const nvinfer1::PluginTensorDesc *output_desc,
                                const void *const *inputs, void *const *outputs,
                                void *workspace,
                                cudaStream_t stream) TRT_NOEXCEPT {
  auto input_dims = input_desc[0].dims;
  auto out_dims = output_desc[0].dims;
  if (decrease_axis_ != -1) {
    out_dims = input_dims;
    out_dims.d[decrease_axis_] = 1;
  }
  auto num_dims = input_dims.nbDims;
  size_t out_num = ProductDim(out_dims);

  std::vector<int> seg_offsets;
  std::vector<int> offsets;
  std::vector<int> extends;

  offsets.resize(num_dims);
  extends.resize(num_dims);
  seg_offsets.resize(num_dims);

  seg_offsets[num_dims - 1] = 1;
  for (int i = num_dims - 2; i >= 0; i--) {
    seg_offsets[i] = input_dims.d[i + 1] * seg_offsets[i + 1];
  }

  for (size_t i = 0; i < num_dims; ++i) {
    offsets[i] = 0;
    extends[i] = out_dims.d[i];
  }
  for (size_t i = 0; i < axes_.size(); ++i) {
    offsets[axes_[i]] = starts_[i];
  }

  offset_info_.resize(num_dims * 3);
  for (size_t i = 0; i < num_dims; ++i) {
    offset_info_[i * 3 + 0] = offsets[i];
    offset_info_[i * 3 + 1] = extends[i];
    offset_info_[i * 3 + 2] = seg_offsets[i];
  }

  if (offset_temp_data_ == nullptr) {
    cudaMalloc(&offset_temp_data_, 3 * num_dims * sizeof(int));
  }

  cudaMemcpyAsync(offset_temp_data_, offset_info_.data(),
                  sizeof(int) * 3 * num_dims, cudaMemcpyHostToDevice, stream);

  int threads = 256;
  int blocks = (out_num + threads - 1) / threads;
  auto input_type = input_desc[0].type;
  if (input_type == nvinfer1::DataType::kFLOAT) {
    VLOG(1) << "TRT Plugin DataType selected. Slice-->fp32";
    const float *input1 = static_cast<const float *>(inputs[0]);
    float *output = static_cast<float *>(outputs[0]);
    SliceKernel<float><<<blocks, threads, 3 * num_dims * sizeof(int), stream>>>(
        out_num, num_dims, input1, offset_temp_data_, output);
  } else if (input_type == nvinfer1::DataType::kHALF) {
    VLOG(1) << "TRT Plugin DataType selected. Slice-->fp16";
    const half *input1 = static_cast<const half *>(inputs[0]);
    half *output = static_cast<half *>(outputs[0]);
    SliceKernel<half><<<blocks, threads, 3 * num_dims * sizeof(int), stream>>>(
        out_num, num_dims, input1, offset_temp_data_, output);
  } else {
    PADDLE_THROW(platform::errors::Fatal(
        "The Slice TRT Plugin's input type should be float or half."));
  }
  return cudaGetLastError() != cudaSuccess;
}
#endif

}  // namespace plugin
}  // namespace tensorrt
}  // namespace inference
}  // namespace paddle
