"""Tests for math_utils."""
import pytest

from math_utils import add, divide


def test_add_positive_numbers():
    assert add(2, 3) == 5


def test_add_negative_numbers():
    assert add(-2, -3) == -5


def test_divide_normal_case():
    assert divide(10, 2) == 5


def test_divide_by_zero_raises_value_error():
    with pytest.raises(ValueError, match="cannot divide by zero"):
        divide(1, 0)
