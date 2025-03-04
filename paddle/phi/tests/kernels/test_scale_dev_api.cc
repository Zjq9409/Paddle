/* Copyright (c) 2021 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include <gtest/gtest.h>

#include <memory>

#include "paddle/fluid/memory/allocation/allocator_facade.h"
#include "paddle/phi/api/lib/utils/allocator.h"
#include "paddle/phi/core/dense_tensor.h"
#include "paddle/phi/core/kernel_registry.h"
#include "paddle/phi/kernels/scale_kernel.h"

namespace phi {
namespace tests {

namespace framework = paddle::framework;
using DDim = phi::DDim;

TEST(DEV_API, scale) {
  // 1. create tensor
  const auto alloc = std::make_unique<paddle::experimental::DefaultAllocator>(
      paddle::platform::CPUPlace());
  phi::DenseTensor dense_x(alloc.get(),
                           phi::DenseTensorMeta(phi::DataType::FLOAT32,
                                                phi::make_ddim({3, 4}),
                                                phi::DataLayout::NCHW));

  auto* dense_x_data =
      dense_x.mutable_data<float>(paddle::platform::CPUPlace());
  for (size_t i = 0; i < 12; ++i) {
    dense_x_data[i] = i * 1.0;
  }
  float scale = 2;
  float bias = 1;
  bool bias_after_scale = true;

  // 2. test API
  phi::CPUContext dev_ctx;
  dev_ctx.SetAllocator(paddle::memory::allocation::AllocatorFacade::Instance()
                           .GetAllocator(paddle::platform::CPUPlace())
                           .get());
  dev_ctx.Init();

  auto out = phi::Scale<float>(dev_ctx, dense_x, scale, bias, bias_after_scale);

  // 3. check result
  ASSERT_EQ(out.dims().size(), 2);
  ASSERT_EQ(out.numel(), 12);
  ASSERT_EQ(out.meta().dtype, phi::DataType::FLOAT32);
  ASSERT_EQ(out.meta().layout, phi::DataLayout::NCHW);

  auto expect_result = 23;
  auto actual_result = out.data<float>()[11];
  ASSERT_NEAR(expect_result, actual_result, 1e-6f);
}

TEST(DEV_API, scale_host) {
  // 1. create tensor
  const auto alloc = std::make_unique<paddle::experimental::DefaultAllocator>(
      paddle::platform::CPUPlace());
  phi::DenseTensor dense_x(alloc.get(),
                           phi::DenseTensorMeta(phi::DataType::FLOAT32,
                                                phi::make_ddim({3, 4}),
                                                phi::DataLayout::NCHW));
  auto* dense_x_data =
      dense_x.mutable_data<float>(paddle::platform::CPUPlace());
  for (size_t i = 0; i < 12; ++i) {
    dense_x_data[i] = i * 1.0;
  }

  phi::DenseTensor scale(
      alloc.get(),
      phi::DenseTensorMeta(
          phi::DataType::FLOAT32, phi::make_ddim({1}), phi::DataLayout::NCHW));
  scale.data<float>()[0] = 2;
  float bias = 1;
  bool bias_after_scale = true;

  // 2. test API
  phi::CPUContext dev_ctx;
  dev_ctx.SetAllocator(paddle::memory::allocation::AllocatorFacade::Instance()
                           .GetAllocator(paddle::platform::CPUPlace())
                           .get());
  dev_ctx.Init();

  auto out = phi::Scale<float>(dev_ctx, dense_x, scale, bias, bias_after_scale);

  // 3. check result
  ASSERT_EQ(out.dims().size(), 2);
  ASSERT_EQ(out.numel(), 12);
  ASSERT_EQ(out.meta().dtype, phi::DataType::FLOAT32);
  ASSERT_EQ(out.meta().layout, phi::DataLayout::NCHW);

  auto expect_result = 23;
  auto actual_result = out.data<float>()[11];
  ASSERT_NEAR(expect_result, actual_result, 1e-6f);
}

}  // namespace tests
}  // namespace phi
