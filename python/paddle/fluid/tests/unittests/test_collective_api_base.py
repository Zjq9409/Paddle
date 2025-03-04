# Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from __future__ import print_function
import numpy as np
import unittest
import time
import argparse
import os
import sys
import subprocess
import traceback
import functools
import pickle
from contextlib import closing
import paddle
import paddle.fluid as fluid
import paddle.fluid.unique_name as nameGen
from paddle.fluid import core


class TestCollectiveAPIRunnerBase(object):

    def get_model(self, train_prog, startup_prog, rank, indata=None):
        raise NotImplementedError(
            "get model should be implemented by child class.")

    def run_trainer(self, args):
        train_prog = fluid.Program()
        startup_prog = fluid.Program()
        endpoints = args["endpoints"].split(",")
        rank = args["trainerid"]
        current_endpoint = args["currentendpoint"]
        nranks = 2
        paddle.distributed.init_parallel_env()
        if args['backend'] == 'nccl':
            device_id = int(os.getenv("FLAGS_selected_gpus", "0"))
            place = fluid.CUDAPlace(
                device_id)  #if args.use_gpu else fluid.CPUPlace()
        elif args['backend'] == 'bkcl':
            device_id = int(os.getenv("FLAGS_selected_xpus", "0"))
            place = fluid.XPUPlace(device_id)
        else:
            place = fluid.CPUPlace()
        np.random.seed(os.getpid())
        indata = np.random.random((10, 1000)).astype("float32")
        if args['static_mode']:
            result = self.get_model(train_prog, startup_prog, rank)
            exe = fluid.Executor(place)
            exe.run(startup_prog)
            fetch_list = []
            for elem in result:
                fetch_list.append(elem.name)
            out = exe.run(train_prog,
                          feed={'tindata': indata},
                          fetch_list=fetch_list)
        else:
            out = self.get_model(train_prog, startup_prog, rank, indata)
            #print(out, sys.stderr)
        sys.stdout.buffer.write(pickle.dumps(out))


def runtime_main(test_class, col_type):
    args = {}
    model = test_class()
    args["trainerid"] = int(os.getenv("PADDLE_TRAINER_ID"))
    args["trainernum"] = int(os.getenv("PADDLE_TRAINERS_NUM"))
    args["endpoints"] = os.getenv('PADDLE_TRAINER_ENDPOINTS')
    args["currentendpoint"] = os.getenv("PADDLE_CURRENT_ENDPOINT")
    args["col_type"] = col_type
    args["backend"] = os.getenv("BACKEND")
    args["path_id"] = int(os.getenv("PATH_ID"))
    args["static_mode"] = int(os.getenv("STATIC_MODE"))
    model.run_trainer(args)


import paddle.compat as cpt
import socket
from contextlib import closing


class TestDistBase(unittest.TestCase):

    def setUp(self):
        self._port_set = set()
        self._trainers = 2
        self._ps_endpoints = "127.0.0.1:%s,127.0.0.1:%s" % (
            self._find_free_port(), self._find_free_port())
        self._python_interp = sys.executable

    def _find_free_port(self):

        def __free_port():
            with closing(socket.socket(socket.AF_INET,
                                       socket.SOCK_STREAM)) as s:
                s.bind(('', 0))
                return s.getsockname()[1]

        while True:
            port = __free_port()
            if port not in self._port_set:
                self._port_set.add(port)
                return port

    def _run_cluster(self, model_file, envs):
        worker_endpoints = self._ps_endpoints.split(",")
        w0_ep, w1_ep = worker_endpoints
        #print("w0_ep:",w0_ep," w1_ep:",w1_ep)
        if core.is_compiled_with_cuda():
            env0 = {
                "FLAGS_selected_gpus": "0",
                "PADDLE_TRAINER_ID": "0",
                "PADDLE_TRAINERS_NUM": "2",
                "PADDLE_TRAINER_ENDPOINTS": self._ps_endpoints,
                "PADDLE_CURRENT_ENDPOINT": w0_ep
            }

            env1 = {
                "FLAGS_selected_gpus": "1",
                "PADDLE_TRAINER_ID": "1",
                "PADDLE_TRAINERS_NUM": "2",
                "PADDLE_TRAINER_ENDPOINTS": self._ps_endpoints,
                "PADDLE_CURRENT_ENDPOINT": w1_ep
            }
        elif core.is_compiled_with_xpu():
            env0 = {
                "FLAGS_selected_xpus": "0",
                "PADDLE_TRAINER_ID": "0",
                "PADDLE_TRAINERS_NUM": "2",
                "PADDLE_TRAINER_ENDPOINTS": self._ps_endpoints,
                "PADDLE_CURRENT_ENDPOINT": w0_ep
            }

            env1 = {
                "FLAGS_selected_xpus": "1",
                "PADDLE_TRAINER_ID": "1",
                "PADDLE_TRAINERS_NUM": "2",
                "PADDLE_TRAINER_ENDPOINTS": self._ps_endpoints,
                "PADDLE_CURRENT_ENDPOINT": w1_ep
            }
        #update environment
        env0.update(envs)
        env1.update(envs)
        if os.getenv('WITH_COVERAGE', 'OFF') == 'ON':
            tr_cmd = "%s -m coverage run --branch -p %s"
        else:
            tr_cmd = "%s %s"
        tr0_cmd = tr_cmd % (self._python_interp, model_file)
        tr1_cmd = tr_cmd % (self._python_interp, model_file)
        tr0_pipe = open("/tmp/tr0_err_%d.log" % os.getpid(), "w")
        tr1_pipe = open("/tmp/tr1_err_%d.log" % os.getpid(), "w")
        #print(tr0_cmd)
        tr0_proc = subprocess.Popen(tr0_cmd.strip().split(),
                                    stdout=subprocess.PIPE,
                                    stderr=tr0_pipe,
                                    env=env0)

        tr1_proc = subprocess.Popen(tr0_cmd.strip().split(),
                                    stdout=subprocess.PIPE,
                                    stderr=tr1_pipe,
                                    env=env1)

        tr0_out, tr0_err = tr0_proc.communicate()
        tr1_out, tr1_err = tr1_proc.communicate()
        sys.stderr.write('trainer 0 stderr: %s\n' % tr0_err)
        sys.stderr.write('trainer 1 stderr: %s\n' % tr1_err)
        # close trainer file
        tr0_pipe.close()
        tr1_pipe.close()
        with open("/tmp/tr0_err_%d.log" % os.getpid(), "r") as f:
            sys.stderr.write('trainer 0 stderr file: %s\n' % f.read())
        with open("/tmp/tr1_err_%d.log" % os.getpid(), "r") as f:
            sys.stderr.write('trainer 1 stderr file: %s\n' % f.read())
        return pickle.loads(tr0_out), pickle.loads(
            tr1_out), tr0_proc.pid, tr1_proc.pid

    def check_with_place(self,
                         model_file,
                         col_type,
                         backend="nccl",
                         path_id="0",
                         static_mode="1",
                         check_error_log=False,
                         need_envs={},
                         eager_mode=True):
        if backend == "nccl" or backend == "bkcl":
            with_gloo = '0'
        else:
            with_gloo = '1'
        required_envs = {
            "FLAGS_fraction_of_gpu_memory_to_use": "0.15",
            "FLAGS_eager_delete_tensor_gb": "0.0",
            "PATH": os.getenv("PATH"),
            "PYTHONPATH": os.getenv("PYTHONPATH", ""),
            "LD_LIBRARY_PATH": os.getenv("LD_LIBRARY_PATH", ""),
            "LD_PRELOAD": os.getenv("LD_PRELOAD", ""),
            "FLAGS_call_stack_level": "2",
            "GLOG_v": "3",
            "NCCL_P2P_DISABLE": "1",
            "STATIC_MODE": static_mode,
            "PADDLE_WITH_GLOO": with_gloo,
            "BACKEND": backend,
            "PATH_ID": path_id
        }
        required_envs.update(need_envs)
        if check_error_log:
            required_envs["GLOG_v"] = "3"
            required_envs["GLOG_logtostderr"] = "1"
            required_envs["GLOO_LOG_LEVEL"] = "TRACE"

        if eager_mode:
            required_envs["FLAGS_enable_eager_mode"] = "%d" % 1
        else:
            required_envs["FLAGS_enable_eager_mode"] = "%d" % 0

        tr0_out, tr1_out, pid0, pid1 = self._run_cluster(
            model_file, required_envs)
        np.random.seed(pid0)
        input1 = np.random.random((10, 1000))
        np.random.seed(pid1)
        input2 = np.random.random((10, 1000))
        if col_type == "allgather":
            need_result = np.vstack((input1, input2))
            tr_out0 = np.vstack((tr0_out[0], tr0_out[1]))
            tr_out1 = np.vstack((tr1_out[0], tr1_out[1]))
            self.assertTrue(np.allclose(tr_out0, need_result))
            self.assertTrue(np.allclose(tr_out1, need_result))
        elif col_type == "broadcast":
            need_result = input2
            self.assertTrue(np.allclose(tr0_out, need_result))
            self.assertTrue(np.allclose(tr1_out, need_result))
        elif col_type == "reduce":
            need_result = input1 + input2
            self.assertTrue(np.allclose(tr0_out, need_result))
        elif col_type == "scatter":
            need_result = input2
            need_result1 = need_result[0:need_result.shape[0] // 2]
            need_result2 = need_result[need_result.shape[0] // 2:]
            self.assertTrue(np.allclose(tr0_out, need_result1))
            self.assertTrue(np.allclose(tr1_out, need_result2))
        elif col_type == "allreduce":
            need_result = input1 + input2
            self.assertTrue(
                np.allclose(tr0_out, need_result, rtol=1e-05, atol=1e-05))
            self.assertTrue(
                np.allclose(tr1_out, need_result, rtol=1e-05, atol=1e-05))
        elif col_type == "parallel_embedding":
            result_data = tr0_out[0]
            np.random.seed(2020)
            need_result = np.random.rand(12, 8)
            for i in range(result_data.shape[0]):
                for j in range(result_data.shape[1]):
                    data = result_data[i][j]
                    assert np.allclose(tr0_out[1][i][j],
                                       need_result[data],
                                       atol=1e-08)
        elif col_type == "row_parallel_linear":
            result_data = tr0_out[0]
            np.random.seed(2020)
            weight = np.random.rand(1000, 16)
            need_result = np.matmul(input1, weight)
            self.assertTrue(
                np.allclose(result_data, need_result, rtol=1e-05, atol=1e-05))
        elif col_type == "column_parallel_linear":
            result_data = tr0_out[0]
            np.random.seed(2020)
            weight = np.random.rand(1000, 16)
            need_result = np.matmul(input1, weight)
            self.assertTrue(
                np.allclose(result_data, need_result, rtol=1e-05, atol=1e-05))
        elif col_type == "alltoall":
            need_result1 = np.vstack((input1[0:input1.shape[0] // 2, :],
                                      input2[0:input2.shape[0] // 2, :]))
            need_result2 = np.vstack((input1[input1.shape[0] // 2:, :],
                                      input2[input2.shape[0] // 2:, :]))
            tr0_out = np.vstack(tr0_out)
            tr1_out = np.vstack(tr1_out)
            self.assertTrue(
                np.allclose(tr0_out, need_result1, rtol=1e-05, atol=1e-05))
            self.assertTrue(
                np.allclose(tr1_out, need_result2, rtol=1e-05, atol=1e-05))
        elif col_type == "sendrecv":
            result_data = tr1_out[0]
            self.assertTrue(
                np.allclose(input1, result_data, rtol=1e-05, atol=1e-05))
        elif col_type == "global_gather":
            in_feat = 2
            n_expert = 2
            world_size = 2
            tot_expert = n_expert * world_size

            np.random.seed(pid0)
            local_expert_count1 = np.random.randint(
                1, 4, size=tot_expert).astype("int")
            expert_ptr1 = np.ones(tot_expert, dtype=np.int32)
            expert_ptr1[0] = 0
            for i in range(1, tot_expert):
                expert_ptr1[i] = expert_ptr1[i - 1] + local_expert_count1[i - 1]

            np.random.seed(pid1)
            local_expert_count2 = np.random.randint(
                1, 4, size=tot_expert).astype("int")
            expert_ptr2 = np.ones(tot_expert, dtype=np.int32)
            expert_ptr2[0] = 0
            for i in range(1, tot_expert):
                expert_ptr2[i] = expert_ptr2[i - 1] + local_expert_count2[i - 1]

            global_expert_count1 = np.zeros(tot_expert).astype("int")
            global_expert_count2 = np.zeros(tot_expert).astype("int")
            global_expert_count1[0:n_expert] = local_expert_count1[0:n_expert]
            global_expert_count1[n_expert:] = local_expert_count2[0:n_expert]
            global_expert_count2[0:n_expert] = local_expert_count1[n_expert:]
            global_expert_count2[n_expert:] = local_expert_count2[n_expert:]

            np.random.seed(pid0)
            fwd_expert_count = sum(global_expert_count1).astype("int")
            local_input_buf1 = np.random.rand(fwd_expert_count,
                                              in_feat).astype("float32")
            np.random.seed(pid1)
            fwd_expert_count = sum(global_expert_count2).astype("int")
            local_input_buf2 = np.random.rand(fwd_expert_count,
                                              in_feat).astype("float32")
            output1 = [[], [], [], []]
            output2 = [[], [], [], []]
            send_ptr1 = 0
            send_ptr2 = 0

            for i in range(n_expert):
                for j in range(world_size):
                    idx = j * n_expert + i
                    if j == 0:
                        output1_part1 = local_input_buf1[send_ptr1: \
                            send_ptr1 + global_expert_count1[idx], :]
                        output1_part2 = local_input_buf2[send_ptr2: \
                            send_ptr2 + global_expert_count2[idx], :]
                        output1[i].extend(output1_part1)
                        output1[i + n_expert].extend(output1_part2)
                    else:
                        output2_part1 = local_input_buf1[send_ptr1: \
                            send_ptr1 + global_expert_count1[idx]]
                        output2_part2 = local_input_buf2[send_ptr2: \
                            send_ptr2 + global_expert_count2[idx]]
                        output2[i].extend(output2_part1)
                        output2[i + n_expert].extend(output2_part2)
                    send_ptr1 = send_ptr1 + global_expert_count1[idx]
                    send_ptr2 = send_ptr2 + global_expert_count2[idx]
            result1 = []
            result2 = []
            for i in range(tot_expert):
                for arr in output1[i]:
                    if arr == []:
                        continue
                    result1.append(arr)
            for i in range(tot_expert):
                for arr in output2[i]:
                    if arr == []:
                        continue
                    result2.append(arr)
            if result1 == []:
                output1 = np.array([])
            else:
                output1 = np.concatenate(result1, axis=0).reshape(
                    sum(local_expert_count1), in_feat)
            if result2 == []:
                output2 = np.array([])
            else:
                output2 = np.concatenate(result2, axis=0).reshape(
                    sum(local_expert_count2), in_feat)

            if tr0_out[0] is None or tr0_out[0].shape[0] == 0:
                tr0_out[0] = np.array([])

            if tr1_out[0] is None or tr1_out[0].shape[0] == 0:
                tr1_out[0] = np.array([])

            self.assertTrue(
                np.allclose(tr0_out[0], output1, rtol=1e-05, atol=1e-05))
            self.assertTrue(
                np.allclose(tr1_out[0], output2, rtol=1e-05, atol=1e-05))
            if static_mode == 0:
                self.assertTrue(
                    np.allclose(tr0_out[1],
                                2 * local_input_buf1,
                                rtol=1e-05,
                                atol=1e-05))
                self.assertTrue(
                    np.allclose(tr1_out[1],
                                2 * local_input_buf2,
                                rtol=1e-05,
                                atol=1e-05))

        elif col_type == "global_scatter":
            np.random.seed(pid0)
            local_expert_count1 = np.random.randint(1, 4, size=4).astype("int")
            fwd_expert_count = sum(local_expert_count1)
            local_input_buf1 = np.random.rand(fwd_expert_count,
                                              2).astype("float32")
            expert_ptr1 = np.ones(4, dtype=np.int32)
            expert_ptr1[0] = 0
            for i in range(1, 4):
                expert_ptr1[i] = expert_ptr1[i - 1] + local_expert_count1[i - 1]
            np.random.seed(pid1)
            local_expert_count2 = np.random.randint(1, 4, size=4).astype("int")
            fwd_expert_count = sum(local_expert_count2)
            local_input_buf2 = np.random.rand(fwd_expert_count,
                                              2).astype("float32")
            expert_ptr2 = np.ones(4, dtype=np.int32)
            expert_ptr2[0] = 0
            for i in range(1, 4):
                expert_ptr2[i] = expert_ptr2[i - 1] + local_expert_count2[i - 1]

            output1 = []
            output2 = []
            for i in range(2):
                for j in range(2):
                    idx = j * 2 + i
                    if j == 0:
                        # send data to 0 card
                        output1.append(local_input_buf1[expert_ptr1[idx]: \
                            expert_ptr1[idx]+local_expert_count1[idx]])
                        output1.append(local_input_buf2[expert_ptr2[idx]:\
                            expert_ptr2[idx]+local_expert_count2[idx]])
                    else:
                        output2.append(local_input_buf1[expert_ptr1[idx]: \
                            expert_ptr1[idx]+local_expert_count1[idx]])
                        output2.append(local_input_buf2[expert_ptr2[idx]:\
                            expert_ptr2[idx]+local_expert_count2[idx]])
            if output1 == []:
                output1 = np.array([])
            else:
                output1 = np.concatenate(output1)
            if output2 == []:
                output2 = np.array([])
            else:
                output2 = np.concatenate(output2)

            if tr0_out[0] is None or tr0_out[0].shape[0] == 0:
                tr0_out[0] = np.array([])

            if tr1_out[0] is None or tr1_out[0].shape[0] == 0:
                tr1_out[0] = np.array([])

            self.assertTrue(
                np.allclose(tr0_out[0], output1, rtol=1e-05, atol=1e-05))
            self.assertTrue(
                np.allclose(tr1_out[0], output2, rtol=1e-05, atol=1e-05))
            if static_mode == 0:
                self.assertTrue(
                    np.allclose(tr0_out[1],
                                2 * local_input_buf1,
                                rtol=1e-05,
                                atol=1e-05))
                self.assertTrue(
                    np.allclose(tr1_out[1],
                                2 * local_input_buf2,
                                rtol=1e-05,
                                atol=1e-05))
        else:
            pass
