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


def test_float32_autocast_inside_half_autocast_runs_in_float32():
    # MoGe-2 forces its output projection to fp32 this way. MPS rejects a float32 autocast and turns
    # autocast off instead, so the half activations met float weights: "Input type (c10::Half) and bias
    # type (float) should be the same".
    conv = torch.nn.Conv2d(4, 2, 1).to("cuda")
    x = torch.randn(1, 4, 8, 8, device="cuda")
    with torch.autocast("cuda", dtype=torch.float16):
        outer = conv(x).dtype
        with torch.autocast("cuda", dtype=torch.float32):
            assert conv(x.half()).dtype == torch.float32
        assert conv(x).dtype == outer  # the half region resumes
    assert conv(x.half().float()).dtype == torch.float32


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


@pytest.fixture
def cuda_checkpoint(tmp_path, monkeypatch):
    # No CUDA here to save from, so tag the CPU storages 'cuda:0' at save time, as a CUDA box would.
    t = torch.arange(6, dtype=torch.float32)
    p = tmp_path / "ckpt.pt"
    with monkeypatch.context() as m:
        m.setattr(torch.serialization, "location_tag", lambda storage: "cuda:0")
        torch.save({"w": t}, p)
    return p, t


@pytest.mark.parametrize("kw", [{}, {"map_location": "cuda"}, {"map_location": "cuda:0"},
                                {"map_location": torch.device("cuda")}, {"map_location": {"cpu": "cuda:0"}},
                                {"map_location": lambda storage, loc: None}])
def test_load_cuda_checkpoint(cuda_checkpoint, kw):
    p, t = cuda_checkpoint
    w = torch.load(p, **kw)["w"]
    assert w.device.type == TARGET and torch.equal(w.cpu(), t)


def test_load_cuda_checkpoint_explicit_cpu_stays_cpu(cuda_checkpoint):
    p, t = cuda_checkpoint
    assert torch.load(p, map_location="cpu")["w"].device.type == "cpu"
