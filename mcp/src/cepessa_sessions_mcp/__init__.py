"""Read-only MCP server for Cepessa Sessions transcripts."""

import asyncio
import logging
import sys

import click

from .__about__ import __version__
from .server import serve


@click.command()
@click.option("-v", "--verbose", count=True, help="Log to stderr: -v info, -vv debug.")
@click.version_option(__version__, prog_name="cepessa-sessions-mcp")
def main(verbose: int) -> None:
    """Serve Cepessa Sessions transcripts over MCP (stdio), read-only."""
    level = logging.WARNING
    if verbose == 1:
        level = logging.INFO
    elif verbose >= 2:
        level = logging.DEBUG
    logging.basicConfig(level=level, stream=sys.stderr)
    asyncio.run(serve())


if __name__ == "__main__":
    main()
