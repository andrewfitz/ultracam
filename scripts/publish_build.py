#!/usr/bin/env python3
"""Publish the validated app and symbols from one build."""
import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def publish(product, artifacts, local_development=False):
    dsym = product.with_name(product.name + '.dSYM')
    stable_product = artifacts / product.name
    stable_dsym = artifacts / dsym.name
    directory = os.open(artifacts, os.O_RDONLY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX)
        for alias in (stable_product, stable_dsym):
            if alias.exists() and not alias.is_symlink():
                raise ValueError(f'Refusing to replace existing non-symlink: {alias}')
        with tempfile.TemporaryDirectory(prefix='.publish-', dir=artifacts) as work:
            next_product = Path(work) / product.name
            next_dsym = Path(work) / dsym.name
            previous_product = Path(work) / 'previous.app'
            next_product.symlink_to(product)
            if dsym.is_dir():
                next_dsym.symlink_to(dsym)
            if stable_product.is_symlink():
                previous_product.symlink_to(stable_product.readlink())
            if local_development:
                stage = Path(__file__).with_name('prepare_local_build.py')
                destination = artifacts / 'local-development' / product.name
                if destination.parent.is_symlink():
                    raise ValueError(f'Refusing a symlink staging directory: {destination.parent}')
                subprocess.run([sys.executable, str(stage), str(product), str(destination)], check=True)
            next_product.replace(stable_product)
            try:
                if next_dsym.is_symlink():
                    next_dsym.replace(stable_dsym)
                else:
                    stable_dsym.unlink(missing_ok=True)
            except OSError:
                if previous_product.is_symlink():
                    previous_product.replace(stable_product)
                else:
                    stable_product.unlink()
                raise
    finally:
        os.close(directory)
    if not local_development:
        print(f'Built: {stable_product}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('product', type=Path)
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('--local-development', action='store_true')
    args = parser.parse_args()
    try:
        publish(args.product.absolute(), args.artifacts.absolute(), args.local_development)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'publish_build: {error}\n')


if __name__ == '__main__':
    main()
