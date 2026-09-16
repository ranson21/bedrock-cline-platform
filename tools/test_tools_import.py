import importlib.util
import pathlib


def test_tools_parse():
    """Every tool must at least compile; catches syntax errors in CI without AWS."""
    root = pathlib.Path(__file__).parent
    for p in root.rglob("*.py"):
        if "mcp-kb-server" in p.parts:
            continue
        spec = importlib.util.spec_from_file_location(p.stem, p)
        assert spec is not None
        compile(p.read_text(), str(p), "exec")
