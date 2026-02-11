"""Windows-native Dayflow implementation."""

__version__ = "0.1.0"


def main(*args, **kwargs):
    from .app import main as _main
    return _main(*args, **kwargs)


__all__ = ["main", "__version__"]
