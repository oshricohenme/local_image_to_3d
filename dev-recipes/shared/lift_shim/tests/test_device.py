import threading

import pytest
import torch

import lift_shim

pytestmark = pytest.mark.skipif(torch.cuda.is_available(), reason="real CUDA present; shim is a no-op")
TARGET = "mps" if torch.backends.mps.is_available() else "cpu"


@pytest.fixture(scope="module", autouse=True)
def shim():
    assert lift_shim.install() == TARGET


def test_install_is_idempotent():
    assert lift_shim.install() == TARGET


def test_tensor_cuda():
    assert torch.zeros(2).cuda().device.type == TARGET
    assert torch.zeros(2).cuda(0).device.type == TARGET


@pytest.mark.parametrize("dev", ["cuda", "cuda:0", torch.device("cuda"), torch.device("cuda", 0)])
def test_tensor_to(dev):
    assert torch.zeros(2).to(dev).device.type == TARGET


def test_tensor_to_kwargs_keep_dtype():
    t = torch.zeros(2).to(device="cuda", dtype=torch.float16)
    assert t.device.type == TARGET and t.dtype == torch.float16


@pytest.mark.parametrize("factory", [
    lambda: torch.ones(3, device="cuda"),
    lambda: torch.randn(2, device=torch.device("cuda", 0)),
    lambda: torch.tensor([1.0], device="cuda"),
    lambda: torch.arange(4, device="cuda:0"),
    lambda: torch.zeros_like(torch.zeros(2), device="cuda"),
])
def test_factories(factory):
    assert factory().device.type == TARGET


def test_module_cuda_and_to():
    assert all(p.device.type == TARGET for p in torch.nn.Linear(2, 2).cuda().parameters())
    assert all(p.device.type == TARGET for p in torch.nn.Linear(2, 2).to("cuda").parameters())


def test_non_cuda_untouched():
    assert torch.zeros(2).to("cpu").device.type == "cpu"
    assert torch.zeros(2, device="cpu").device.type == "cpu"


def test_cuda_helpers_do_not_raise():
    torch.cuda.empty_cache()
    torch.cuda.synchronize()
    torch.cuda.manual_seed(1)
    torch.cuda.manual_seed_all(1)
    assert torch.cuda.current_device() == 0


def test_autocast_cuda():
    with torch.autocast("cuda", dtype=torch.bfloat16):
        out = torch.ones(2, 2, device="cuda") @ torch.ones(2, 2, device="cuda")
    assert out.device.type == TARGET


def test_new_thread_redirected():
    result = {}

    def work():
        try:
            result["dev"] = torch.zeros(1).cuda().device.type
        except Exception as e:  # noqa: BLE001 - surface any failure to the assert
            result["err"] = repr(e)

    t = threading.Thread(target=work)
    t.start()
    t.join()
    assert result == {"dev": TARGET}


def _device_or_error():
    try:
        return {"dev": torch.zeros(1).cuda().device.type}
    except Exception as e:  # noqa: BLE001 - surface any failure to the assert
        return {"err": repr(e)}


def test_thread_subclass_overriding_run_redirected():
    class Worker(threading.Thread):
        def run(self):
            self.result = _device_or_error()

    t = Worker()
    t.start()
    t.join()
    assert t.result == {"dev": TARGET}


def test_timer_redirected():
    result = {}
    t = threading.Timer(0, lambda: result.update(_device_or_error()))
    t.start()
    t.join()
    assert result == {"dev": TARGET}
