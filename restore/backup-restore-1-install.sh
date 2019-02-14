#!/bin/bash
set -eo pipefail
set -x

install restic

restic restore from all

