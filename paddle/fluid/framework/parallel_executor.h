/* Copyright (c) 2016 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#pragma once

#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "paddle/fluid/framework/details/build_strategy.h"
#include "paddle/fluid/framework/details/execution_strategy.h"
#include "paddle/fluid/framework/details/op_handle_base.h"
#include "paddle/fluid/framework/details/scope_buffered_ssa_graph_executor.h"
#include "paddle/fluid/framework/executor.h"
#include "paddle/fluid/framework/feed_fetch_type.h"
#include "paddle/fluid/framework/op_info.h"
#include "paddle/fluid/framework/program_desc.h"
#include "paddle/fluid/framework/scope.h"
#include "paddle/fluid/framework/tensor.h"
#include "paddle/fluid/platform/device_context.h"

#if defined(PADDLE_WITH_NCCL) || defined(PADDLE_WITH_RCCL)
#include "paddle/fluid/platform/device/gpu/nccl_helper.h"
#endif

namespace paddle {
namespace framework {

class ParallelExecutorPrivate;

using details::BuildStrategy;
using details::ExecutionStrategy;
using details::VariableInfo;
namespace p = paddle::platform;
using DeviceType = paddle::platform::DeviceType;

class ParallelExecutor {
  DISABLE_COPY_AND_ASSIGN(ParallelExecutor);

 public:
  explicit ParallelExecutor(const std::vector<platform::Place> &places,
                            const std::vector<std::string> &bcast_vars,
                            const std::string &loss_var_name, Scope *scope,
                            const std::vector<Scope *> &local_scopes,
                            const ExecutionStrategy &exec_strategy,
                            const BuildStrategy &build_strategy,
                            ir::Graph *graph);

  // NOTE(Aurelius84): Construct a PE running on single device for @to_static
  explicit ParallelExecutor(const platform::Place &place, Scope *scope,
                            const ExecutionStrategy &exec_strategy,
                            const BuildStrategy &build_strategy,
                            ir::Graph *graph);

  ~ParallelExecutor();

  size_t DeviceCount() const;

  std::vector<Scope *> &GetLocalScopes();

  void DropLocalExeScopes();

  // This API is used to check whether DropLocalExeScopes work.
  bool NeedCreateLocalExeScope();

  /**
   * Feed tensors to local scopes. The size of tensors should be equal to the
   * size of local scopes.
   */
  void FeedTensorsIntoLocalScopes(
      const std::vector<std::unordered_map<std::string, LoDTensor>> &tensors);

  void FeedAndSplitTensorIntoLocalScopes(
      const std::unordered_map<std::string, LoDTensor> &tensors);

  FetchResultType Run(const std::vector<std::string> &fetch_tensors,
                      bool return_merged = true);

  void RunWithoutFetch(const std::vector<std::string> &skip_eager_vars);

  void ResetOpHandleScopeMapOfGraphs(
      const std::unordered_map<Scope *, Scope *> &scope_map);

  const ir::Graph &Graph() const;
  void PrepareVariables(Scope *scope);

  void SkipMemoryReuse(size_t scope_idx,
                       const std::vector<std::string> &skip_vars);

 private:
  // broadcast the parameters from the 0th device.
  // trainer_id the trainer index in nccl distributed training.
  void BCastParamsToDevices(const std::vector<std::string> &vars,
                            int trainer_id = 0) const;
  bool EnableParallelGraphExecution(const ir::Graph &graph,
                                    const ExecutionStrategy &exec_strategy,
                                    const BuildStrategy &build_strategy) const;

  void InitExecutorPrivateMemberInfo(const ExecutionStrategy &exec_strategy,
                                     const BuildStrategy &build_strategy,
                                     size_t device_count,
                                     const ir::Graph &graph);

  void CreateLocalScopes(Scope *global_scope,
                         const std::vector<Scope *> &local_scopes,
                         bool create_new);

  std::unordered_map<Scope *, Scope *> CreateLocalExecScopes(
      const std::vector<Scope *> &local_scopes, bool create_new);

  std::vector<ir::Graph *> CloneGraphToMultiDevices(ir::Graph *graph);

  void PrepareNCCLCommunicator(Scope *global_scope);

  std::vector<ir::Graph *> CompileGraphWithBuildStrategy(
      ir::Graph *graph, std::vector<ir::Graph *> *graphs,
      const std::string &loss_var_name);

  void CreateVariableInfos(std::vector<VariableInfo> *var_infos,
                           ir::Graph *graph);

  std::vector<ir::Graph *> CreateSSAGraphExecutor(
      const ExecutionStrategy &exec_strategy,
      std::vector<ir::Graph *> *async_graphs, ir::Graph *graph);

  void ResetOpHandleScopeMapOfGraphs(
      const std::vector<ir::Graph *> &final_graphs,
      const std::unordered_map<Scope *, Scope *> &scope_map);

  void SetReaderOpDeviceInfoOfGraphs(
      const std::vector<ir::Graph *> &final_graphs);

  void PrepareForCUDAGraphCapture(ir::Graph *graph);

  ParallelExecutorPrivate *member_;
  std::vector<std::unique_ptr<ir::Graph>> async_graphs_;
  std::vector<VariableInfo> var_infos_;
};
}  // namespace framework
}  // namespace paddle
