"""Simple math utilities."""


def add(a: float, b: float) -> float:
    """Return the sum of a and b."""
    return a + b


def divide(a: float, b: float) -> float:
    """Return a divided by b.

    Raises:
        ValueError: if b is 0.
    """
    if b == 0:
        raise ValueError("cannot divide by zero")
    return a / b
