"""Run one deterministic slice of the controller contract suite."""

import argparse
import unittest

from controller_contract import ControllerContract


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("index", type=int)
    parser.add_argument("count", type=int)
    args = parser.parse_args()
    if not 0 <= args.index < args.count:
        parser.error("expected 0 <= index < count")
    loader = unittest.TestLoader()
    names = loader.getTestCaseNames(ControllerContract)
    selected = names[args.index :: args.count]
    if not selected:
        parser.error("shard has no tests")
    suite = unittest.TestSuite(ControllerContract(name) for name in selected)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
