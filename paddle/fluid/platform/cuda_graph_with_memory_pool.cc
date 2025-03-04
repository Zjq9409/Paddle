// Copyright (c) 2021 PaddlePaddle Authors. All Rights Reserved.
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

#include "paddle/fluid/platform/cuda_graph_with_memory_pool.h"

#include "paddle/fluid/memory/allocation/allocator_facade.h"
#include "paddle/fluid/platform/device_context.h"

DECLARE_bool(use_stream_safe_cuda_allocator);

namespace paddle {
namespace platform {

#ifdef PADDLE_WITH_CUDA
void BeginCUDAGraphCapture(platform::CUDAPlace place,
                           cudaStreamCaptureMode mode, int64_t pool_id) {
  auto *dev_ctx = platform::DeviceContextPool::Instance().GetByPlace(place);
  dev_ctx->cudnn_workspace_handle().ResetWorkspace();

  auto stream = dev_ctx->stream();
  CUDAGraph::BeginCapture(place, stream, mode);

  auto old_value = FLAGS_use_stream_safe_cuda_allocator;
  if (old_value) {
    FLAGS_use_stream_safe_cuda_allocator = false;
  }
  pool_id = CUDAGraph::SetMemoryPoolID(pool_id);
  memory::allocation::AllocatorFacade::Instance().PrepareMemoryPoolForCUDAGraph(
      pool_id);
  if (old_value) {
    FLAGS_use_stream_safe_cuda_allocator = true;
  }
  AddResetCallbackIfCapturingCUDAGraph([pool_id] {
    memory::allocation::AllocatorFacade::Instance().RemoveMemoryPoolOfCUDAGraph(
        pool_id);
  });
}

std::unique_ptr<CUDAGraph> EndCUDAGraphCapture() {
  auto place = CUDAGraph::CapturingPlace();
  auto *dev_ctx = platform::DeviceContextPool::Instance().GetByPlace(place);
  dev_ctx->cudnn_workspace_handle().ResetWorkspace();
  return CUDAGraph::EndCapture();
}
#endif

}  // namespace platform
}  // namespace paddle
