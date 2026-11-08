import pytest

from app.services.fx import FXRateUnavailable, convert


class FakeProvider:
    def get_rate(self, base, quote):
        return 0.72  # CAD -> USD

def test_convert_uses_provider_rate():
    assert convert(1000.0, "CAD", "USD", FakeProvider()) == 720.0

def test_convert_same_currency_skips_provider():
    class ExplodingProvider:
        def get_rate(self, base, quote):
            raise AssertionError("should not be called")
    assert convert(50.0, "USD", "USD", ExplodingProvider()) == 50.0

def test_unavailable_pair_raises():
    class EmptyProvider:
        def get_rate(self, base, quote):
            raise FXRateUnavailable(base, quote)
    with pytest.raises(FXRateUnavailable):
        convert(10.0, "XYZ", "USD", EmptyProvider())
