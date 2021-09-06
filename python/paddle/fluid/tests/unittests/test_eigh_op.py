#   Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.
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

import unittest
import numpy as np
import paddle
from op_test import OpTest, skip_check_grad_ci
import paddle.fluid as fluid
from paddle.fluid import compiler, Program, program_guard
import paddle.fluid.core as core
import paddle.fluid.layers as layers
from gradient_checker import grad_check
from decorator_helper import prog_scope
paddle.enable_static()


class TestEighOp(OpTest):
    def setUp(self):
        self.op_type = "eigh"
        self.init_input()
        self.init_config()
        np.random.seed(123)
        out_w, out_v = np.linalg.eigh(self.x_np, self.UPLO)
        self.init_param()
        out_v = out_v * self.param
        self.inputs = {"X": self.x_np}
        self.attrs = {"UPLO": self.UPLO}
        self.outputs = {'OutValue': out_w, "OutVector": out_v}

    def init_config(self):
        self.UPLO = 'L'

    def init_input(self):
        self.x_shape = (10, 10)
        self.x_type = np.float64
        self.x_np = np.random.random(self.x_shape).astype(self.x_type)

    def init_param(self):
        self.param = np.ones(self.x_shape)
        self.param[:, 0] = -1
        self.param[:, 4] = -1
        self.param[:, 8] = -1
        self.param[:, 9] = -1

    def test_check_output(self):
        self.check_output_with_place(place=core.CPUPlace())

    def test_grad(self):
        self.check_grad(["X"], ["OutValue"])


class TestEighUPLOCase(TestEighOp):
    def init_param(self):
        self.param = np.ones(self.x_shape)
        self.param[:, 3] = -1
        self.param[:, 4] = -1
        self.param[:, 6] = -1
        self.param[:, 7] = -1

    def init_config(self):
        self.UPLO = 'U'


class TestEighGPUCase(unittest.TestCase):
    def setUp(self):
        self.x_shape = [32, 32]
        self.dtype = "float32"
        np.random.seed(123)
        self.x_np = np.random.random(self.x_shape).astype(self.dtype)
        self.rtol = 1e-5
        self.atol = 1e-5

    def test_output_gpu_place(self):
        with fluid.dygraph.guard(core.CUDAPlace(0)):
            input_real_data = fluid.dygraph.to_variable(self.x_np)
            expected_w, expected_v = np.linalg.eigh(self.x_np)
            actual_w, actual_v = paddle.linalg.eigh(input_real_data)
            np.testing.assert_allclose(
                actual_w, expected_w, rtol=self.rtol, atol=self.atol)
            np.testing.assert_allclose(
                abs(actual_v.numpy()),
                abs(expected_v),
                rtol=self.rtol,
                atol=self.atol)


class TestEighAPI(unittest.TestCase):
    def setUp(self):
        self.x_shape = [5, 5]
        self.dtype = "float32"
        self.UPLO = 'L'
        self.rtol = 1e-6
        self.atol = 1e-6
        self.places = [fluid.CPUPlace()]
        if core.is_compiled_with_cuda() and (not core.is_compiled_with_rocm()):
            self.places.append(fluid.CUDAPlace(0))
        np.random.seed(123)
        self.real_data = np.random.random(self.x_shape).astype(self.dtype)
        self.complex_data = np.random.random(self.x_shape).astype(
            self.dtype) + 1J * np.random.random(self.x_shape).astype(self.dtype)

    def compare_result(self, actual_w, actual_v, expected_w, expected_v):
        np.testing.assert_allclose(
            actual_w, expected_w, rtol=self.rtol, atol=self.atol)
        np.testing.assert_allclose(
            abs(actual_v), abs(expected_v), rtol=self.rtol, atol=self.atol)

    def check_static_result(self, place):
        with fluid.program_guard(fluid.Program(), fluid.Program()):
            input_x = fluid.layers.data(
                'input_x', shape=self.x_shape, dtype=self.dtype)
            output_w, output_v = paddle.linalg.eigh(input_x)
            exe = fluid.Executor(place)
            expected_w, expected_v = exe.run(fluid.default_main_program(),
                                             feed={"input_x": self.real_data},
                                             fetch_list=[output_w, output_v])

            actual_w, actual_v = np.linalg.eigh(self.real_data)
            self.compare_result(actual_w, actual_v, expected_w, expected_v)

            input_x = fluid.layers.data(
                'input_x', shape=self.x_shape, dtype=self.dtype)
            output_w, output_v = paddle.linalg.eigh(input_x)
            exe = fluid.Executor(place)
            expected_w, expected_v = exe.run(
                fluid.default_main_program(),
                feed={"input_x": self.complex_data},
                fetch_list=[output_w, output_v])
            actual_w, actual_v = np.linalg.eigh(self.complex_data)
            self.compare_result(actual_w, actual_v, expected_w, expected_v)

    def test_in_static_mode(self):
        paddle.enable_static()
        for place in self.places:
            self.check_static_result(place=place)

    def test_in_dynamic_mode(self):
        for place in self.places:
            with fluid.dygraph.guard(place):
                input_real_data = fluid.dygraph.to_variable(self.real_data)
                expected_w, expected_v = np.linalg.eigh(self.real_data)
                actual_w, actual_v = paddle.linalg.eigh(input_real_data)
                self.compare_result(actual_w,
                                    actual_v.numpy(), expected_w, expected_v)

                input_complex_data = fluid.dygraph.to_variable(
                    self.complex_data)
                input_complex_data = paddle.to_tensor(self.complex_data)
                expected_w, expected_v = np.linalg.eigh(self.complex_data)
                actual_w, actual_v = paddle.linalg.eigh(input_complex_data)
                self.compare_result(actual_w,
                                    actual_v.numpy(), expected_w, expected_v)

            def test_eigh_grad(self):
                def run_test(uplo):
                    paddle.disable_static()
                    for place in self.places:
                        x = paddle.to_tensor(
                            self.complex_data, stop_gradient=False)
                        w, v = paddle.linalg.eigh(x)
                        (w.sum() + paddle.abs(v).sum()).backward()
                        np.testing.assert_allclose(
                            abs(x.grad.numpy()),
                            abs(x.grad.numpy().conj().transpose(-1, -2)),
                            rtol=self.rtol,
                            atol=self.atol)

                for uplo in ["L", "U"]:
                    run_test(uplo)


class TestEighAPIError(unittest.TestCase):
    def test_error(self):
        with program_guard(Program(), Program()):
            #input maxtrix must greater than 2 dimensions
            input_x = fluid.data(name='x_1', shape=[12], dtype='float32')
            self.assertRaises(ValueError, paddle.linalg.eigh, input_x)

            #input matrix must be square matrix
            input_x = fluid.data(name='x_2', shape=[12, 32], dtype='float32')
            self.assertRaises(ValueError, paddle.linalg.eigh, input_x)

            #uplo must be in 'L' or 'U'
            input_x = fluid.data(name='x_3', shape=[4, 4], dtype="float32")
            uplo = 'R'
            self.assertRaises(ValueError, paddle.linalg.eigh, input_x, uplo)

            #x_data cannot be integer
            input_x = fluid.data(name='x_4', shape=[4, 4], dtype="int32")
            self.assertRaises(TypeError, paddle.linalg.eigh, input_x)


if __name__ == "__main__":
    paddle.enable_static()
    unittest.main()
